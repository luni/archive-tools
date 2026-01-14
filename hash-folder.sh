#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  hash-folder.sh [options] DIRECTORY [OUTPUT_FILE]

Description:
  Computes SHA-256 hashes for all files in a directory recursively.
  Uses hashdeep if available, falls back to find+sha256sum.

Options:
  -q, --quiet    Suppress progress logs
  -h, --help     Show this help message
EOF
}

QUIET=0
DIRECTORY=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  -q | --quiet)
    QUIET=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    die "Unknown option: $1"
    ;;
  *)
    if [[ -z "$DIRECTORY" ]]; then
      DIRECTORY="$1"
    elif [[ -z "$OUTPUT_FILE" ]]; then
      OUTPUT_FILE="$1"
    else
      die "Too many arguments"
    fi
    shift
    ;;
  esac
done

[[ -n "$DIRECTORY" ]] || die "Directory path is required."
validate_dir_exists "$DIRECTORY"

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$(default_sha256_path "$DIRECTORY")"
fi

prepare_file_for_write "$OUTPUT_FILE"

if command -v hashdeep >/dev/null 2>&1; then
  log "Using hashdeep for faster hashing"
  hashdeep -l -c sha256 -r "$DIRECTORY" | awk -F, -v dir="$DIRECTORY" '
    /^#/ || /^%%%%/ || /^sha256[[:space:]]+filename$/ || /^$/ { next }
    {
      size = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", size)
      path = $3
      # Remove directory prefix if present
      if (index(path, dir "/") == 1) {
        path = substr(path, length(dir) + 2)
      }
      # Remove leading ./ if present
      gsub(/^\.\//, "", path)
      print $2 "  " path "  " size
    }
  ' >"$OUTPUT_FILE"
else
  log "Using find+sha256sum (hashdeep not available)"
  write_sha256_manifest "$DIRECTORY" "$OUTPUT_FILE"
fi

log "SHA-256 manifest written to: $OUTPUT_FILE"
