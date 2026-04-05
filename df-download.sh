#!/usr/bin/env bash
#
# Downloader that strips URL query strings from the output filename,
# queues background downloads with wget, optionally shows foreground progress,
# and prompts (using gum if available) to redownload if the file already exists.
#
# Usage:
#   DF_DOWNLOAD_DIR=/path/to/dir ./df-download.sh [OPTIONS] [URL]...
#
# Options:
#   -f, --foreground   Show wget progress in the foreground (no backgrounding)
#   --processor        Process the queue file (download queued videos)
#   --dedup            Scan download directory and hardlink duplicate files
#   -h, --help         Show help
#
# Environment Variables:
#   DF_QUEUE=true      Enable queue mode (add URLs to queue file instead of downloading)
#   DF_QUEUE_FILE      Path to queue file (defaults to $HOME/.df_queue)
#   DF_HASH_FILE       Path to hash registry file (defaults to $HOME/.df_hash_registry)
#
set -euo pipefail

# Detect gum availability
GUM_AVAILABLE=0
if command -v gum >/dev/null 2>&1; then
  GUM_AVAILABLE=1
fi

# Helpers to print styled messages if gum is present, otherwise fallback to echo.
gum_info() {
  if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
    gum style --foreground 212 "$1"
  else
    echo "$1"
  fi
}

gum_error() {
  if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
    gum style --foreground 196 --bold "$1"
  else
    echo "$1" >&2
  fi
}

gum_confirm() {
  # Usage: gum_confirm "Question?"
  # Returns 0 on yes, 1 on no.
  local prompt="$1"

  if [[ "${PROCESSOR_MODE:-0}" -eq 1 ]]; then
    printf '%s\n' "Processor mode: skipping interactive confirmation (default: no)" >&2
    return 0
  fi

  if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
    if gum confirm "$prompt"; then
      return 0
    else
      return 1
    fi
  else
    # Fallback prompt
    while true; do
      read -r -p "$prompt [y/N]: " yn
      case "${yn:-n}" in
        [Yy]*) return 0 ;;
        [Nn]*|'') return 1 ;;
      esac
    done
  fi
}

# Default download directory (can be overridden by DF_DOWNLOAD_DIR env var)
DF_DOWNLOAD_DIR="${DF_DOWNLOAD_DIR:-${HOME:-.}/Downloads}"

# Queue configuration
DF_QUEUE="${DF_QUEUE:-false}"
DF_QUEUE_FILE="${DF_QUEUE_FILE:-${HOME:-.}/.df_queue}"

# Hash registry configuration
DF_HASH_FILE="${DF_HASH_FILE:-${HOME:-.}/df_hash_registry}"

# Ensure download dir exists
mkdir -p -- "$DF_DOWNLOAD_DIR"

# Print usage/help
usage() {
  if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
    gum style --foreground 63 --bold "Usage: $(basename "$0") [OPTIONS] [URL]..."
    gum style "Download one or more URLs to DF_DOWNLOAD_DIR (defaults to \$HOME/Downloads).
The script strips the query string when creating the local filename and never prints
the full URL (including query) to stdout.

Options:
  -f, --foreground   Show wget progress in foreground (do not background)
  --processor        Process the queue file (download queued videos)
  --dedup            Scan download directory and hardlink duplicate files
  -h, --help         Show this help and exit

Environment Variables:
  DF_QUEUE=true      Enable queue mode (add URLs to queue file instead of downloading)
  DF_QUEUE_FILE      Path to queue file (defaults to \$HOME/.df_queue)
  DF_HASH_FILE       Path to hash registry file (defaults to \$HOME/.df_hash_registry)

Examples:
  DF_DOWNLOAD_DIR=\$PWD/downloads $(basename "$0") -f \"https://example.com/video.mp4?secure=...\"
  $(basename "$0") -  # read URLs from stdin
  DF_QUEUE=true $(basename "$0") \"https://example.com/video.mp4?secure=...\"  # add to queue
  $(basename "$0") --processor  # process queue
  $(basename "$0") --dedup  # find and hardlink duplicates"
  else
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [URL]...
Download one or more URLs to DF_DOWNLOAD_DIR (defaults to \$HOME/Downloads).
The script strips the query string when creating the local filename and never prints
the full URL (including query) to stdout.

Options:
  -f, --foreground   Show wget progress in foreground (do not background)
  --processor        Process the queue file (download queued videos)
  --dedup            Scan download directory and hardlink duplicate files
  -h, --help         Show this help and exit

Environment Variables:
  DF_QUEUE=true      Enable queue mode (add URLs to queue file instead of downloading)
  DF_QUEUE_FILE      Path to queue file (defaults to \$HOME/.df_queue)
  DF_HASH_FILE       Path to hash registry file (defaults to \$HOME/.df_hash_registry)

Examples:
  DF_DOWNLOAD_DIR=\$PWD/downloads $(basename "$0") -f "https://example.com/video.mp4?secure=..."
  $(basename "$0") -  # read URLs from stdin
  DF_QUEUE=true $(basename "$0") "https://example.com/video.mp4?secure=..."  # add to queue
  $(basename "$0") --processor  # process queue
  $(basename "$0") --dedup  # find and hardlink duplicates
EOF
  fi
}

# URL-decode percent-encoding (simple)
urldecode() {
  local s="$1"
  s="${s//+/ }"
  # shellcheck disable=SC2059
  printf '%b' "${s//%/\\x}"
}

# Sanitize filename: remove path chars, replace spaces, remove unsafe chars
sanitize_filename() {
  local name="$1"
  # trim
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  name="${name//\//_}"
  name="${name// /_}"
  # replace non-alnum and not in . _ - with underscore
  name="$(echo "$name" | sed -E 's/[^A-Za-z0-9._-]/_/g')"
  # collapse underscores
  name="$(echo "$name" | sed -E 's/_+/_/g')"
  if [[ -z "$name" ]]; then
    name="download"
  fi
  printf '%s' "$name"
}

# Normalize URL: strip expiring tokens, sort query params for consistent comparison
normalize_url() {
  local url="$1"
  local base="${url%%\?*}"
  local query="${url#*\?}"

  if [[ "$url" == "$base" ]]; then
    printf '%s' "$url"
    return
  fi

  local normalized_query=""
  if [[ -n "$query" ]]; then
    local -a params=()
    local old_ifs="$IFS"
    IFS='&'
    read -ra params <<< "$query"
    IFS="$old_ifs"
    local -a kept_params=()
    for param in "${params[@]}"; do
      local key="${param%%=*}"
      case "$key" in
        signature|token|auth|session|sid|expires|exp|timestamp|ts|nonce)
          continue
          ;;
        *)
          kept_params+=("$param")
          ;;
      esac
    done

    if [[ ${#kept_params[@]} -gt 0 ]]; then
      local -a sorted=()
      while IFS= read -r line; do
        sorted+=("$line")
      done < <(printf '%s\n' "${kept_params[@]}" | sort)
      normalized_query="?${sorted[*]}"
      normalized_query="${normalized_query// /}"
    fi
  fi

  printf '%s' "${base}${normalized_query}"
}

# Compute SHA-256 hash of a file
compute_hash() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

# Initialize hash registry file
init_hash_registry() {
  if [[ ! -f "$DF_HASH_FILE" ]]; then
    local registry_dir
    registry_dir="$(dirname "$DF_HASH_FILE")"
    mkdir -p -- "$registry_dir"
    touch "$DF_HASH_FILE"
  fi
}

# Lookup hash in registry, returns filepath if found
lookup_hash() {
  local hash="$1"
  init_hash_registry
  grep "^${hash}|" "$DF_HASH_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

# Lookup URL in registry, returns hash if found
lookup_url() {
  local url="$1"
  init_hash_registry
  grep "|${url}$" "$DF_HASH_FILE" 2>/dev/null | head -1 | cut -d'|' -f1
}

# Store hash-to-filepath and hash-to-URL mapping in registry
store_hash() {
  local hash="$1"
  local filepath="$2"
  local url="$3"
  init_hash_registry

  local normalized_url
  normalized_url="$(normalize_url "$url")"

  grep -v "^${hash}|" "$DF_HASH_FILE" > "${DF_HASH_FILE}.tmp" 2>/dev/null || true
  mv "${DF_HASH_FILE}.tmp" "$DF_HASH_FILE"

  echo "${hash}|${filepath}|${normalized_url}|$(date +%s)" >> "$DF_HASH_FILE"
}

# Ensure unique filename (append _N suffix if needed)
unique_path() {
  local dir="$1"
  local name="$2"
  local base="$name"
  local ext=""
  if [[ "$name" == *.* ]]; then
    base="${name%.*}"
    ext=".${name##*.}"
  fi

  local candidate="$dir/$name"
  local i=1
  while [[ -e "$candidate" ]]; do
    candidate="$dir/${base}_$i${ext}"
    ((i++))
  done
  printf '%s' "$candidate"
}

# Global option: foreground or background
FOREGROUND=0
PROCESSOR_MODE=0
DEDUP_MODE=0

# Parse leading CLI options (-f/--foreground, --processor, -h/--help)
while [[ ${1-} == -* ]]; do
  case "$1" in
    -f|--foreground)
      FOREGROUND=1
      shift
      ;;
    --processor)
      PROCESSOR_MODE=1
      shift
      ;;
    --dedup)
      DEDUP_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      gum_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Collect URLs from positional args or stdin (skip if in processor mode)
urls=()
if [[ "$PROCESSOR_MODE" -eq 0 ]] && [[ $# -gt 0 ]]; then
  # remaining args are URLs
  for a in "$@"; do
    urls+=("$a")
  done
elif [[ "$PROCESSOR_MODE" -eq 0 ]]; then
  # If nothing provided as args, try reading stdin (pipe)
  if ! [[ -t 0 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      urls+=("$line")
    done
  else
    # Interactive and no URLs: prompt once if gum available
    if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
      gum_info "Enter a URL to download (or leave empty to cancel):"
      first="$(gum input 'https://example.com/video.mp4?secure=...')"
      if [[ -n "$first" ]]; then
        urls+=("$first")
      else
        gum_error "No URL entered. Exiting."
        exit 1
      fi
    else
      usage
      exit 1
    fi
  fi
fi

if [[ "$PROCESSOR_MODE" -eq 0 ]] && [[ ${#urls[@]} -eq 0 ]]; then
  gum_error "No URLs to download. Exiting."
  exit 1
fi

# Ensure download dir exists (again)
mkdir -p -- "$DF_DOWNLOAD_DIR"

# Add URL to queue file
add_to_queue() {
  local url="$1"

  # Basic validation
  if [[ ! "$url" =~ ^https?:// ]]; then
    gum_error "Skipping invalid URL: <redacted>"
    return 1
  fi

  # Normalize URL for deduplication
  local normalized_url
  normalized_url="$(normalize_url "$url")"

  # Check if URL already exists in queue (normalized comparison)
  if [[ -f "$DF_QUEUE_FILE" ]]; then
    while IFS= read -r queued_url || [[ -n "$queued_url" ]]; do
      queued_url="${queued_url#"${queued_url%%[![:space:]]*}"}"
      queued_url="${queued_url%"${queued_url##*[![:space:]]}"}"
      [[ -z "$queued_url" ]] && continue
      local normalized_queued
      normalized_queued="$(normalize_url "$queued_url")"
      if [[ "$normalized_url" == "$normalized_queued" ]]; then
        gum_info "URL already in queue (duplicate skipped)."
        return 0
      fi
    done < "$DF_QUEUE_FILE"
  fi

  # Check if already downloaded (hash registry lookup)
  local existing_hash
  existing_hash="$(lookup_url "$url")"
  if [[ -n "$existing_hash" ]]; then
    local existing_file
    existing_file="$(lookup_hash "$existing_hash")"
    if [[ -n "$existing_file" && -f "$existing_file" ]]; then
      gum_info "Already downloaded: $existing_file"
      return 0
    fi
  fi

  # Ensure queue file directory exists
  local queue_dir
  queue_dir="$(dirname "$DF_QUEUE_FILE")"
  mkdir -p -- "$queue_dir"

  # Append URL to queue file
  echo "$url" >> "$DF_QUEUE_FILE"
  gum_info "Added to queue: $DF_QUEUE_FILE"
  return 0
}

# Main per-URL processing
download_one() {
  local url="$1"

  # If queue mode is enabled (and not in processor mode), add to queue instead of downloading
  if [[ "$DF_QUEUE" == "true" && "$PROCESSOR_MODE" -eq 0 ]]; then
    add_to_queue "$url"
    return $?
  fi

  # Basic validation
  if [[ ! "$url" =~ ^https?:// ]]; then
    gum_error "Skipping invalid URL: <redacted>"
    return 1
  fi

  # Strip query portion to derive filename
  local url_no_query="${url%%\?*}"
  local raw_name="${url_no_query##*/}"
  if [[ -z "$raw_name" ]]; then
    raw_name="download"
  fi

  # Decode and sanitize
  local decoded
  decoded="$(urldecode "$raw_name" 2>/dev/null || echo "$raw_name")"
  local sanitized
  sanitized="$(sanitize_filename "$decoded")"

  # Ensure extension; default to .mp4 if none
  if [[ "$sanitized" != *.* ]]; then
    sanitized="${sanitized}.mp4"
  fi

  # Determine the canonical destination path (preserve original filename if possible)
  local candidate="$DF_DOWNLOAD_DIR/$sanitized"
  local dest

  if [[ -e "$candidate" ]]; then
    gum_info "Found existing file: $candidate"
    dest="$candidate"
  else
    # No existing file with the canonical name; pick a unique path to avoid collisions
    dest="$(unique_path "$DF_DOWNLOAD_DIR" "$sanitized")"
  fi

  # Check if this URL was already downloaded (hash registry lookup)
  local existing_hash
  existing_hash="$(lookup_url "$url")"
  if [[ -n "$existing_hash" ]]; then
    local existing_file
    existing_file="$(lookup_hash "$existing_hash")"
    if [[ -n "$existing_file" && -f "$existing_file" ]]; then
      # Verify the existing file still has the same hash
      local current_hash
      current_hash="$(compute_hash "$existing_file")"
      if [[ "$current_hash" == "$existing_hash" ]]; then
        gum_info "Already downloaded (hash match): $existing_file"
        # Create hardlink if destination differs
        if [[ "$dest" != "$existing_file" ]]; then
          rm -f "$dest"
          ln "$existing_file" "$dest"
          gum_info "Created hardlink: $dest"
        fi
        return 0
      fi
    fi
  fi

  gum_info "Destination: $dest"

  # Start wget either in foreground or background
  if [[ "$FOREGROUND" -eq 1 ]]; then
    gum_info "Downloading (foreground) -> $dest"
    if command -v wget >/dev/null 2>&1; then
      # Show progress; wget will output progress to terminal.
      # In processor mode, suppress verbose output
      if [[ "$PROCESSOR_MODE" -eq 1 ]]; then
        wget -q -c -O "$dest" -- "$url"
      else
        wget -c --show-progress -O "$dest" -- "$url"
      fi
      local rc=$?
      if [[ $rc -ne 0 ]]; then
        gum_error "wget failed for: $dest (exit $rc)"
        return 1
      fi
      gum_info "Completed -> $dest"

      # Compute and store hash for deduplication
      local file_hash
      file_hash="$(compute_hash "$dest")"
      if [[ -n "$file_hash" ]]; then
        store_hash "$file_hash" "$dest" "$url"
      fi

      return 0
    else
      gum_error "wget not found on PATH"
      return 1
    fi
  else
    gum_info "Queuing (background) -> $dest"
    wget -c -b -O "$dest" -- "$url" >/dev/null 2>&1 || {
      gum_error "Failed to start wget for destination: $dest"
      return 1
    }
    gum_info "Queued -> $dest"
    return 0
  fi
}

# Process queue mode
if [[ "$PROCESSOR_MODE" -eq 1 ]]; then
  if [[ ! -f "$DF_QUEUE_FILE" ]]; then
    gum_error "Queue file not found: $DF_QUEUE_FILE"
    exit 0
  fi

  if [[ ! -s "$DF_QUEUE_FILE" ]]; then
    gum_info "Queue is empty."
    exit 0
  fi

  gum_info "Processing queue from: $DF_QUEUE_FILE"

  # Create a temporary file for the updated queue
  temp_queue="$(mktemp)"
  trap 'rm -f "$temp_queue"' EXIT

  # Process each URL in the queue
  while IFS= read -r url || [[ -n "$url" ]]; do
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    [[ -z "$url" ]] && continue

    gum_info "Processing from queue: <URL redacted>"

    # Download this URL (always in foreground for processor mode)
    FOREGROUND=1
    DF_QUEUE=false  # Disable queue mode to actually download
    if download_one "$url"; then
      gum_info "Successfully downloaded from queue."
      # Don't add to temp file (remove from queue)
    else
      gum_error "Failed to download. Keeping in queue."
      # Keep in queue by writing to temp file
      echo "$url" >> "$temp_queue"
    fi
  done < "$DF_QUEUE_FILE"

  # Replace the queue file with the updated version
  if [[ -s "$temp_queue" ]]; then
    mv "$temp_queue" "$DF_QUEUE_FILE"
    gum_info "Queue processing complete. Remaining items in queue."
  else
    rm -f "$DF_QUEUE_FILE" "$temp_queue"
    gum_info "Queue processing complete. Queue is now empty."
  fi

  exit 0
fi

# Deduplication mode: scan directory and hardlink duplicates
if [[ "$DEDUP_MODE" -eq 1 ]]; then
  gum_info "Scanning for duplicates in: $DF_DOWNLOAD_DIR"

  init_hash_registry

  declare -A hash_to_file
  duplicates_found=0
  space_saved=0

  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue

    file_hash="$(compute_hash "$file")"
    [[ -z "$file_hash" ]] && continue

    if [[ -n "${hash_to_file[$file_hash]+x}" ]]; then
      original="${hash_to_file[$file_hash]}"
      file_size="$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)"

      rm -f "$file"
      ln "$original" "$file"
      store_hash "$file_hash" "$file" ""

      ((duplicates_found++)) || true
      ((space_saved += file_size)) || true
      gum_info "Linked duplicate: $file -> $original"
    else
      hash_to_file[$file_hash]="$file"
      store_hash "$file_hash" "$file" ""
    fi
  done < <(find "$DF_DOWNLOAD_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

  if [[ $duplicates_found -gt 0 ]]; then
    gum_info "Found $duplicates_found duplicate(s), saved $((space_saved / 1024 / 1024))MB"
  else
    gum_info "No duplicates found."
  fi

  exit 0
fi

# Iterate over URLs
for u in "${urls[@]}"; do
  download_one "$u" || gum_error "Warning: failed to queue or download (redacted)."
done

if [[ "$DF_QUEUE" == "true" ]]; then
  gum_info "All URLs queued to: $DF_QUEUE_FILE"
  gum_info "Run with --processor to process the queue."
else
  gum_info "All requests processed. For background downloads check wget-log*; foreground downloads printed above."
fi
