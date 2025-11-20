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
#   -h, --help         Show help
#
# Environment Variables:
#   DF_QUEUE=true      Enable queue mode (add URLs to queue file instead of downloading)
#   DF_QUEUE_FILE      Path to queue file (defaults to $HOME/.df_queue)
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
  if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
    if gum confirm --no-spin --placeholder "$prompt"; then
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
  -h, --help         Show this help and exit

Environment Variables:
  DF_QUEUE=true      Enable queue mode (add URLs to queue file instead of downloading)
  DF_QUEUE_FILE      Path to queue file (defaults to \$HOME/.df_queue)

Examples:
  DF_DOWNLOAD_DIR=\$PWD/downloads $(basename "$0") -f \"https://example.com/video.mp4?secure=...\"
  $(basename "$0") -  # read URLs from stdin
  DF_QUEUE=true $(basename "$0") \"https://example.com/video.mp4?secure=...\"  # add to queue
  $(basename "$0") --processor  # process queue"
  else
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [URL]...
Download one or more URLs to DF_DOWNLOAD_DIR (defaults to \$HOME/Downloads).
The script strips the query string when creating the local filename and never prints
the full URL (including query) to stdout.

Options:
  -f, --foreground   Show wget progress in foreground (do not background)
  --processor        Process the queue file (download queued videos)
  -h, --help         Show this help and exit

Environment Variables:
  DF_QUEUE=true      Enable queue mode (add URLs to queue file instead of downloading)
  DF_QUEUE_FILE      Path to queue file (defaults to \$HOME/.df_queue)

Examples:
  DF_DOWNLOAD_DIR=\$PWD/downloads $(basename "$0") -f "https://example.com/video.mp4?secure=..."
  $(basename "$0") -  # read URLs from stdin
  DF_QUEUE=true $(basename "$0") "https://example.com/video.mp4?secure=..."  # add to queue
  $(basename "$0") --processor  # process queue
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

# Check if a destination file already exists and if user wants to redownload.
# Returns:
#   0 = proceed with download (either file doesn't exist, or user chose to redownload)
#   1 = skip download (user chose not to redownload)
check_existing_and_prompt() {
  local dest="$1"

  if [[ -e "$dest" ]]; then
    # File exists: ask user if they want to re-download (redownload) it.
    # We avoid printing any URL or other sensitive info; only filename/path is shown.
    if gum_confirm "File already exists: $dest. Redownload (overwrite) it?"; then
      # User wants to redownload: remove the existing file first to ensure a fresh download.
      # We remove the file before downloading so wget doesn't attempt to resume.
      rm -f -- "$dest"
      gum_info "Existing file removed; will redownload -> $dest"
      return 0
    else
      gum_info "Skipping (file exists) -> $dest"
      return 1
    fi
  fi

  # File doesn't exist; proceed
  return 0
}

# Global option: foreground or background
FOREGROUND=0
PROCESSOR_MODE=0

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
      first="$(gum input --placeholder 'https://example.com/video.mp4?secure=...')"
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

  # Build destination path (unique)
  local dest
  dest="$(unique_path "$DF_DOWNLOAD_DIR" "$sanitized")"

  gum_info "Destination: $dest"

  # If file exists (unique_path ensures non-collision) — but in rare case unique_path may append suffix,
  # we still check for the specific dest since unique_path checks for existing files.
  # Ask user whether to redownload if it exists.
  if ! check_existing_and_prompt "$dest"; then
    # User chose not to redownload
    return 0
  fi

  # Start wget either in foreground or background
  if [[ "$FOREGROUND" -eq 1 ]]; then
    gum_info "Downloading (foreground) -> $dest"
    if command -v wget >/dev/null 2>&1; then
      # Show progress; wget will output progress to terminal.
      wget -c --show-progress -O "$dest" -- "$url"
      local rc=$?
      if [[ $rc -ne 0 ]]; then
        gum_error "wget failed for: $dest (exit $rc)"
        return 1
      fi
      gum_info "Completed -> $dest"
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
    exit 1
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
