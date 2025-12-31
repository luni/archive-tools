#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  analyze-archive.sh [options] ARCHIVE

Description:
  Streams every regular file contained in the provided archive (7z, tar, or
  zip), computes its SHA-256 digest without writing the extracted data to disk,
  and saves the list of hashes to an output file sorted by path.

Options:
  -o, --output FILE   Target SHA-256 manifest (default: ARCHIVE basename + .sha256)
  -q, --quiet         Suppress progress logs
  -h, --help          Show this help message
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

log() {
  [[ "$QUIET" -eq 1 ]] && return 0
  printf '%s\n' "$*" >&2
}

default_output_path() {
  local archive="$1" dir base
  dir="$(dirname -- "$archive")"
  base="$(basename -- "$archive")"
  if [[ "$base" == *.* ]]; then
    base="${base%.*}"
  fi
  printf '%s/%s.sha256\n' "$dir" "$base"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' is not on PATH."
}

detect_archive_type() {
  local archive="$1"
  case "${archive,,}" in
    *.7z) echo "7z" ;;
    *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.tlz|*.taz|*.tar.gz|*.tar.xz|*.tar.zst|*.tar.bz2|*.tzst) echo "tar" ;;
    *.zip) echo "zip" ;;
    *) echo "unknown" ;;
  esac
}

list_archive_files_7z() {
  local archive="$1"
  local line path attrs started=0

  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" == "----------" ]]; then
      if [[ "$started" -eq 0 ]]; then
        started=1
      else
        if [[ -n "$path" && "$attrs" != *D* ]]; then
          printf '%s\0' "$path"
        fi
      fi
      path=""
      attrs=""
      continue
    fi

    [[ "$started" -eq 0 ]] && continue

    if [[ "$line" == Path\ =\ * ]]; then
      path="${line#Path = }"
    elif [[ "$line" == Attributes\ =\ * ]]; then
      attrs="${line#Attributes = }"
    fi
  done < <("$SEVENZ_BIN" l -slt -- "$archive")

  if [[ -n "$path" && "$attrs" != *D* ]]; then
    printf '%s\0' "$path"
  fi
}

detect_tar_compression() {
  local archive="${1,,}"
  case "$archive" in
    *.tar.gz|*.tgz|*.taz) echo "gz" ;;
    *.tar.bz2|*.tbz|*.tbz2) echo "bz2" ;;
    *.tar.xz|*.txz|*.tlz) echo "xz" ;;
    *.tar.zst|*.tzst) echo "zst" ;;
    *) echo "none" ;;
  esac
}

require_tar_filter_tool() {
  case "$TAR_COMPRESSION" in
    gz) require_tool pigz ;;
    bz2) require_tool pbzip2 ;;
    xz) require_tool pixz ;;
    zst) require_tool pzstd ;;
  esac
}

tar_list_entries() {
  local archive="$1"
  case "$TAR_COMPRESSION" in
    gz) pigz -dc -- "$archive" | tar -tf - ;;
    bz2) pbzip2 -dc -- "$archive" | tar -tf - ;;
    xz) pixz -d -c -- "$archive" | tar -tf - ;;
    zst) pzstd -d -q -c -- "$archive" | tar -tf - ;;
    none) tar -tf -- "$archive" ;;
  esac
}

tar_extract_entry() {
  local archive="$1" entry="$2"
  case "$TAR_COMPRESSION" in
    gz) pigz -dc -- "$archive" | tar -xOf - -- "$entry" ;;
    bz2) pbzip2 -dc -- "$archive" | tar -xOf - -- "$entry" ;;
    xz) pixz -d -c -- "$archive" | tar -xOf - -- "$entry" ;;
    zst) pzstd -d -q -c -- "$archive" | tar -xOf - -- "$entry" ;;
    none) tar -xOf -- "$archive" -- "$entry" ;;
  esac
}

list_archive_files_tar() {
  local archive="$1" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == */ ]] && continue
    printf '%s\0' "$entry"
  done < <(tar_list_entries "$archive")
}

list_archive_files_zip() {
  local archive="$1" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == */ ]] && continue
    printf '%s\0' "$entry"
  done < <(unzip -Z1 -- "$archive")
}

list_archive_files() {
  case "$ARCHIVE_TYPE" in
    7z) list_archive_files_7z "$ARCHIVE" ;;
    tar) list_archive_files_tar "$ARCHIVE" ;;
    zip) list_archive_files_zip "$ARCHIVE" ;;
    *)
      die "Unsupported archive type for $ARCHIVE"
      ;;
  esac
}

stream_entry() {
  local archive="$1" entry="$2"
  case "$ARCHIVE_TYPE" in
    7z)
      "$SEVENZ_BIN" x -so -- "$archive" "$entry"
      ;;
    tar)
      tar_extract_entry "$archive" "$entry"
      ;;
    zip)
      unzip -p -- "$archive" "$entry"
      ;;
    *)
      die "Unsupported archive type for streaming: $ARCHIVE_TYPE"
      ;;
  esac
}

compute_sha256() {
  local archive="$1" entry="$2"
  stream_entry "$archive" "$entry" | sha256sum | awk '{print $1}'
}

ARCHIVE=""
OUTPUT_FILE=""
QUIET=0
ARCHIVE_TYPE="7z"
SEVENZ_BIN="7z"
TAR_COMPRESSION="none"

select_7z_tool() {
  if command -v 7z >/dev/null 2>&1; then
    SEVENZ_BIN="7z"
    return 0
  elif command -v 7zr >/dev/null 2>&1; then
    SEVENZ_BIN="7zr"
    return 0
  else
    die "Neither '7z' nor '7zr' is available on PATH."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      OUTPUT_FILE="$2"
      shift 2
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
      if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="$1"
        shift
      else
        die "Only one archive can be processed at a time."
      fi
      ;;
  esac
done

if [[ -z "$ARCHIVE" ]]; then
  die "Archive path is required."
fi

if [[ ! -f "$ARCHIVE" ]]; then
  die "Archive not found: $ARCHIVE"
fi

ARCHIVE_TYPE="$(detect_archive_type "$ARCHIVE")"
if [[ "$ARCHIVE_TYPE" == "unknown" ]]; then
  log "Archive type not recognized; defaulting to 7z handlers."
  ARCHIVE_TYPE="7z"
fi

case "$ARCHIVE_TYPE" in
  zip)
    require_tool unzip
    ;;
  tar)
    require_tool tar
    TAR_COMPRESSION="$(detect_tar_compression "$ARCHIVE")"
    require_tar_filter_tool
    ;;
  7z)
    select_7z_tool
    ;;
  *)
    die "Archive type '$ARCHIVE_TYPE' is not supported."
    ;;
esac
require_tool sha256sum

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$(default_output_path "$ARCHIVE")"
fi

mkdir -p -- "$(dirname -- "$OUTPUT_FILE")"
: >"$OUTPUT_FILE"
tmp_manifest="$(mktemp)"
trap 'rm -f "$tmp_manifest"' EXIT

log "Writing SHA-256 manifest to $OUTPUT_FILE"

files_processed=0
while IFS= read -r -d '' entry; do
  files_processed=$((files_processed + 1))
  log "processing: $entry"
  if ! hash="$(compute_sha256 "$ARCHIVE" "$entry")"; then
    die "Failed to compute SHA-256 for $entry"
  fi
  printf '%s\t%s\n' "$hash" "$entry" | tee -a "$tmp_manifest"
done < <(list_archive_files "$ARCHIVE")

if [[ "$files_processed" -eq 0 ]]; then
  log "No files found inside archive."
  : >"$OUTPUT_FILE"
else
  LC_ALL=C sort -t $'\t' -k2,2 "$tmp_manifest" | awk -F $'\t' '{printf "%s  %s\n",$1,$2}' >"$OUTPUT_FILE"
  log "Processed $files_processed file(s)."
fi
