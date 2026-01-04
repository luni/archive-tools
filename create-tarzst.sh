#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SOURCE_DIR=""
OUTPUT=""
QUIET=0
FORCE=0
REMOVE_SOURCE=0
SHA256_FILE=""
SHA256_ENABLED=0
SHA256_APPEND=0
PZSTD_LEVEL="-10"

usage() {
  cat <<'EOF'
Usage:
  create-tarzst.sh [options] DIRECTORY

Description:
  Streams DIRECTORY into tar (numeric owners) and compresses the tar stream
  with the pzstd CLI to produce a seekable .tar.zst archive.

Options:
  -o, --output FILE   Destination tar.zst path (default: DIRECTORY basename + .tar.zst)
      --pzstd-level -#
                      Override pzstd compression level (default: -10)
      --sha256        Emit SHA-256 manifest (default: DIRECTORY basename + .sha256)
      --sha256-file FILE
                      Emit SHA-256 manifest to FILE
      --sha256-append Append to the SHA-256 file instead of truncating
      --remove-source Delete DIRECTORY after a successful archive
  -f, --force         Overwrite existing output file
  -r, --remove-source Delete DIRECTORY after a successful archive
  -q, --quiet         Suppress progress logs
  -h, --help          Show this help message
EOF
}

default_output_path() {
  local dir="$1" base
  base="$(basename -- "$dir")"
  printf '%s.tar.zst\n' "$base"
}

default_sha256_path() {
  local dir="$1" base
  base="$(basename -- "$dir")"
  printf '%s.sha256\n' "$base"
}

write_sha256_manifest() {
  local root="$1" dest="$2" file rel hash
  [[ -z "$dest" ]] && return 0
  while IFS= read -r -d '' file; do
    rel="${file#$root/}"
    if [[ "$rel" == "$file" ]]; then
      rel="$(basename -- "$file")"
    fi
    hash="$(sha256sum -- "$file" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$rel" >>"$dest"
  done < <(LC_ALL=C find "$root" -type f -print0 | LC_ALL=C sort -z)
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      OUTPUT="$2"
      shift 2
      ;;
    --pzstd-level)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      PZSTD_LEVEL="$2"
      shift 2
      ;;
    --sha256)
      SHA256_ENABLED=1
      shift
      ;;
    --sha256-file)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      SHA256_ENABLED=1
      SHA256_FILE="$2"
      shift 2
      ;;
    --sha256-append)
      SHA256_APPEND=1
      shift
      ;;
    --remove-source)
      REMOVE_SOURCE=1
      shift
      ;;
    -f|--force)
      FORCE=1
      shift
      ;;
    -q|--quiet)
      QUIET=1
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
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$SOURCE_DIR" ]]; then
        SOURCE_DIR="$1"
        shift
      else
        die "Only one directory can be compressed at a time."
      fi
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  die "Unexpected positional arguments: $*"
fi

[[ -n "$SOURCE_DIR" ]] || die "Directory path is required."
[[ -d "$SOURCE_DIR" ]] || die "Directory not found: $SOURCE_DIR"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$(default_output_path "$SOURCE_DIR")"
fi

if [[ -e "$OUTPUT" && "$FORCE" -ne 1 ]]; then
  die "Output already exists: $OUTPUT (use --force to overwrite)"
fi

require_cmd tar
require_cmd pzstd
if [[ "$SHA256_ENABLED" -eq 1 ]]; then
  require_cmd sha256sum
fi

mkdir -p -- "$(dirname -- "$OUTPUT")"

if [[ "$SHA256_ENABLED" -eq 1 && -z "$SHA256_FILE" ]]; then
  SHA256_FILE="$(default_sha256_path "$SOURCE_DIR")"
fi

if [[ "$SHA256_ENABLED" -eq 1 ]]; then
  prepare_file_for_write "$SHA256_FILE" "$SHA256_APPEND"
fi

log "Creating tar.zst at $OUTPUT from $SOURCE_DIR ..."
(
  cd "$SOURCE_DIR"
  if [[ -z "$(find . -mindepth 1 -print -quit)" ]]; then
    tar --numeric-owner -cf - --files-from /dev/null
  else
    tar --numeric-owner -cf - .
  fi
) | pzstd "$PZSTD_LEVEL" -q -o "$OUTPUT"

if [[ "$SHA256_ENABLED" -eq 1 ]]; then
  write_sha256_manifest "$SOURCE_DIR" "$SHA256_FILE"
fi

if [[ "$REMOVE_SOURCE" -eq 1 ]]; then
  log "Removing source directory: $SOURCE_DIR"
  rm -rf -- "$SOURCE_DIR"
fi

log "Done: $OUTPUT"
