#!/usr/bin/env bash
#
# Simple downloader that strips URL query strings from the output filename
# and queues background downloads with wget.
#
# Usage:
#   DF_DOWNLOAD_DIR=/path/to/dir ./df-download.sh "https://example.com/path/My%20Video.mp4?token=XXXXX"
#   ./df-download.sh url1 url2 ...
#
# Notes:
# - The script strips everything after the first '?' when deriving the local filename.
# - The original URL (including any query string) is passed to wget so the download works.
# - Do NOT commit or log sensitive query tokens anywhere. This script avoids putting
#   the full URL (with its query) into logs, messages, or output filenames.
#
# Environment:
# - DF_DOWNLOAD_DIR: directory to save downloads. Defaults to "$HOME/Downloads" then current directory.
#
set -euo pipefail

# Check for gum for nicer UI. If not present, fall back to plain output.
GUM_AVAILABLE=0
if command -v gum >/dev/null 2>&1; then
  GUM_AVAILABLE=1
fi

# Convenience helpers that use gum if available
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

# Default download directory
DF_DOWNLOAD_DIR="${DF_DOWNLOAD_DIR:-${HOME:-.}/Downloads}"

# Create download dir if necessary
mkdir -p -- "$DF_DOWNLOAD_DIR"

# Print usage
usage() {
  if [[ "$GUM_AVAILABLE" -eq 1 ]]; then
    gum style --foreground 63 --bold "Usage: $(basename "$0") [URL]..."
    gum style "Download one or more URLs to the directory specified by DF_DOWNLOAD_DIR.
If DF_DOWNLOAD_DIR is not set, defaults to \$HOME/Downloads.

The script strips the query string (the part after '?') when creating the output filename
and replaces unsafe characters with underscores. The full URL (including query) is used
for the actual download so the request succeeds.

Examples:
  DF_DOWNLOAD_DIR=\$PWD/downloads $(basename \"$0\") \"https://example.com/path/Video%20Name.mp4?secure=...\"
  $(basename \"$0\") -     # read URLs from stdin, one per line

IMPORTANT: do NOT paste sensitive query tokens into logs or commit them to source control."
  else
    cat <<EOF
Usage: $(basename "$0") [URL]...
Download one or more URLs to the directory specified by DF_DOWNLOAD_DIR.
If DF_DOWNLOAD_DIR is not set, defaults to \$HOME/Downloads.

The script strips the query string (the part after '?') when creating the output filename
and replaces unsafe characters with underscores. The full URL (including query) is used
for the actual download so the request succeeds.

Examples:
  DF_DOWNLOAD_DIR=\$PWD/downloads $(basename "$0") "https://example.com/path/Video%20Name.mp4?secure=..."
  $(basename "$0") -     # read URLs from stdin, one per line

IMPORTANT: do NOT paste sensitive query tokens into logs or commit them to source control.
EOF
  fi
}

# URL-decode a percent-encoded string
urldecode() {
  local s="$1"
  # Replace + with space
  s="${s//+/ }"
  # Convert %XX to characters. printf with \x escapes.
  # shellcheck disable=SC2059
  printf '%b' "${s//%/\\x}"
}

# Sanitize a filename to remove or replace unsafe characters
sanitize_filename() {
  local name="$1"
  # Trim leading/trailing whitespace
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  # Replace path separators with underscores
  name="${name//\//_}"
  # Replace spaces with underscores
  name="${name// /_}"
  # Replace any character that is not alnum, dot, dash, or underscore with underscore
  name="$(echo "$name" | sed -E 's/[^A-Za-z0-9._-]/_/g')"
  # Collapse multiple underscores
  name="$(echo "$name" | sed -E 's/_+/_/g')"
  # Prevent empty filename
  if [[ -z "$name" ]]; then
    name="download"
  fi
  printf '%s' "$name"
}

# Ensure filename doesn't overwrite an existing file: add suffix if necessary
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

# Process a single URL
download_one() {
  local url="$1"

  # Minimal URL validation
  if [[ ! "$url" =~ ^https?:// ]]; then
    gum_error "Skipping invalid URL: <redacted>"
    return 1
  fi

  # Derive the filename by stripping the query string and taking the last path segment.
  # We intentionally do not log or echo the full URL with its query string.
  local url_no_query="${url%%\?*}"
  local raw_name="${url_no_query##*/}"

  # If the URL path ends with a slash, use a default name
  if [[ -z "$raw_name" ]]; then
    raw_name="download"
  fi

  # URL-decode the raw name, then sanitize
  local decoded
  decoded="$(urldecode "$raw_name" 2>/dev/null || echo "$raw_name")"
  local sanitized
  sanitized="$(sanitize_filename "$decoded")"

  # Ensure an extension (if none, assume .mp4 as requested)
  if [[ "$sanitized" != *.* ]]; then
    sanitized="${sanitized}.mp4"
  fi

  # Build unique destination path
  local dest
  dest="$(unique_path "$DF_DOWNLOAD_DIR" "$sanitized")"

  # Start background wget. Use -c to continue, -b to background, and -O to write to our sanitized filename.
  # We put the URL at the end; we avoid echoing the URL (with query) to stdout or logs.
  gum_info "Starting download into: $dest"
  # Start wget in background. We intentionally do not print the URL to avoid leaking sensitive query tokens.
  # The command below will create a wget log file in the current working directory (wget-log or wget-log.N).
  # Quoting the URL so any special characters are handled by wget.
  wget -c -b -O "$dest" -- "$url" >/dev/null 2>&1 || {
    gum_error "Failed to start wget for destination: $dest"
    return 1
  }

  # Provide the wget log filename for user's reference (wget writes to wget-log by default).
  # We do not include the URL in our messages.
  gum_info "Queued (background) -> $dest"
  return 0
}

# If no args, read from stdin (one URL per line)
if [[ "${#@}" -eq 0 ]]; then
  # If user passed '-' as single arg it means read stdin; handle that case earlier.
  if [[ -t 0 ]]; then
    usage
    exit 1
  fi
fi

# Accept '-' for reading stdin URLs
urls=()
if [[ "${#@}" -eq 1 ]] && [[ "$1" == "-" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    urls+=("$line")
  done
else
  for a in "$@"; do
    urls+=("$a")
  done
fi

# Iterate and download
for u in "${urls[@]}"; do
  # Avoid echoing the full URL with query to stdout. We only show the sanitized no-query form.
  # But still pass the full URL to wget so downloads that require query tokens succeed.
  download_one "$u" || gum_error "Warning: failed to queue URL (redacted) for download."
done

gum_info "All URLs processed. Check wget logs (wget-log*) for background download progress."
