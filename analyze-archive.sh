#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

tmp_manifest=""
tmp_tar_entries=""
tmp_tar_command=""


cleanup() {
  if [[ -n "$tmp_manifest" && -f "$tmp_manifest" ]]; then
    rm -f "$tmp_manifest"
  fi
  if [[ -n "$tmp_tar_entries" && -f "$tmp_tar_entries" ]]; then
    rm -f "$tmp_tar_entries"
  fi
  if [[ -n "$tmp_tar_command" && -f "$tmp_tar_command" ]]; then
    rm -f "$tmp_tar_command"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  analyze-archive.sh [options] ARCHIVE

Description:
  Streams every regular file contained in the provided archive (7z, rar, tar, or
  zip), computes its SHA-256 digest without writing the extracted data to disk,
  and saves the list of hashes to an output file sorted by path.

Options:
  -o, --output FILE   Target SHA-256 manifest (default: ARCHIVE basename + .sha256)
  -q, --quiet         Suppress progress logs
      --overwrite     Overwrite existing manifest if present
  -p, --password PWD  Password for encrypted archives (default: INVALID_PASSWORD)
  -h, --help          Show this help message
EOF
}


parse_7z_listing() {
  local listing_tmp="$1"
  local line path attrs started=0

  flush_entry() {
    if [[ -n "$path" && "$attrs" != *D* ]]; then
      printf '%s\0' "$path"
    fi
    path=""
    attrs=""
  }

  while IFS= read -r line; do
    line="${line%$'\r'}"

    if [[ "$line" == "----------" ]]; then
      if [[ "$started" -eq 0 ]]; then
        started=1
      else
        flush_entry
      fi
      continue
    fi

    [[ "$started" -eq 0 ]] && continue

    if [[ -z "$line" ]]; then
      flush_entry
      continue
    fi

    if [[ "$line" == Path\ =\ * ]]; then
      path="${line#Path = }"
    elif [[ "$line" == Attributes\ =\ * ]]; then
      attrs="${line#Attributes = }"
    fi
  done <"$listing_tmp"

  rm -f "$listing_tmp"
  flush_entry
}

list_archive_files_7z() {
  local archive="$1"
  local listing_tmp listing_output

  listing_tmp="$(mktemp)"
  if ! "$SEVENZ_BIN" l -slt -- "$archive" >"$listing_tmp" 2>&1; then
    listing_output="$(cat "$listing_tmp")"
    rm -f "$listing_tmp"
    if [[ -n "$listing_output" ]]; then
      printf '%s\n' "$listing_output" >&2
    fi
    die "Failed to list entries for $archive"
  fi

  parse_7z_listing "$listing_tmp"
}


process_tar_archive() {
  local archive="$1" entries_file="$2" command_file="$3"
  local compression_cmd
  compression_cmd="$(get_decompression_command "$TAR_COMPRESSION")"
  if [[ "$compression_cmd" == "unknown" ]]; then
    compression_cmd="cat"
  fi

  if [[ "$TAR_COMPRESSION" == "none" ]]; then
    if ! tar --null --files-from="$entries_file" --to-command="$command_file" -xf "$archive"; then
      die "Failed to process tar entries"
    fi
  else
    if ! cat "$archive" | $compression_cmd | tar --null --files-from="$entries_file" --to-command="$command_file" -xf -; then
      die "Failed to process tar entries"
    fi
  fi
}

tar_list_entries() {
  local archive="$1" dest="$2"

  run_tar_list() {
    local tar_base=(tar --quoting-style=literal --show-transformed-names -tf)
    case "$TAR_COMPRESSION" in
      gz)
        pigz -dc -- "$archive" | "${tar_base[@]}" -
        ;;
      bz2)
        pbzip2 -dc -- "$archive" | "${tar_base[@]}" -
        ;;
      xz)
        pixz -d -c -- "$archive" | "${tar_base[@]}" -
        ;;
      zst)
        pzstd -d -q -c -- "$archive" | "${tar_base[@]}" -
        ;;
      none)
        "${tar_base[@]}" "$archive"
        ;;
    esac
  }

  if ! run_tar_list >"$dest" 2>&1; then
    cat "$dest" >&2
    rm -f "$dest"
    die "Failed to list tar entries for $archive"
  fi
}

tar_extract_entry() {
  local archive="$1" entry="$2"
  case "$TAR_COMPRESSION" in
    gz) pigz -dc -- "$archive" | tar -xOf - -- "$entry" ;;
    bz2) pbzip2 -dc -- "$archive" | tar -xOf - -- "$entry" ;;
    xz) pixz -d -c -- "$archive" | tar -xOf - -- "$entry" ;;
    zst) pzstd -d -q -c -- "$archive" | tar -xOf - -- "$entry" ;;
    none) tar -xOf "$archive" -- "$entry" ;;
  esac
}

list_archive_files_tar() {
  local archive="$1" entry listing_tmp
  listing_tmp="$(mktemp)"
  tar_list_entries "$archive" "$listing_tmp"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == */ ]] && continue
    printf '%s\0' "$entry"
  done <"$listing_tmp"
  rm -f "$listing_tmp"
}

list_archive_files_zip() {
  local archive="$1"
  local listing_tmp

  listing_tmp="$(mktemp)"
  if ! "$SEVENZ_BIN" l -slt -- "$archive" >"$listing_tmp" 2>&1; then
    cat "$listing_tmp" >&2
    rm -f "$listing_tmp"
    die "Failed to list zip entries for $archive"
  fi

  parse_7z_listing "$listing_tmp"
}

list_archive_files_rar() {
  local archive="$1" entry line entry_type
  local listing_tmp
  listing_tmp="$(mktemp)"
  if ! unrar lt -- "$archive" >"$listing_tmp" 2>&1; then
    cat "$listing_tmp" >&2
    rm -f "$listing_tmp"
    die "Failed to list rar entries for $archive"
  fi

  # Check if the output contains an error message about not being a RAR archive
  if grep -q "is not RAR archive" "$listing_tmp"; then
    cat "$listing_tmp" >&2
    rm -f "$listing_tmp"
    die "Failed to list rar entries for $archive"
  fi

  # Parse unrar lt output which has a clean key: value format
  # We need to track both Name and Type fields for each entry
  while IFS= read -r line; do
    # Look for lines that start with "Name:" and extract the filename
    if [[ "$line" =~ ^[[:space:]]*Name:[[:space:]]*(.+)$ ]]; then
      entry="${BASH_REMATCH[1]}"
      continue
    fi

    # Look for lines that start with "Type:" to determine if it's a file
    if [[ "$line" =~ ^[[:space:]]*Type:[[:space:]]*(.+)$ ]]; then
      entry_type="${BASH_REMATCH[1]}"

      # Only process if we have a name and it's a file (not directory)
      if [[ -n "$entry" && "$entry_type" == "File" ]]; then
        printf '%s\0' "$entry"
      fi

      # Reset entry for next iteration
      entry=""
    fi
  done <"$listing_tmp"
  rm -f "$listing_tmp"
}

list_archive_files() {
  case "$ARCHIVE_TYPE" in
    7z) list_archive_files_7z "$ARCHIVE" ;;
    tar|tar.gz|tar.xz|tar.bz2) list_archive_files_tar "$ARCHIVE" ;;
    zip) list_archive_files_zip "$ARCHIVE" ;;
    rar) list_archive_files_rar "$ARCHIVE" ;;
    *)
      die "Unsupported archive type for $ARCHIVE"
      ;;
  esac
}



stream_entry() {
  local archive="$1" entry="$2"
  case "$ARCHIVE_TYPE" in
    7z)
      "$SEVENZ_BIN" x -so -p"$ARCHIVE_PASSWORD" -- "$archive" "$entry"
      ;;
    tar|tar.gz|tar.xz|tar.bz2)
      tar_extract_entry "$archive" "$entry"
      ;;
    zip)
      "$SEVENZ_BIN" x -so -p"$ARCHIVE_PASSWORD" -- "$archive" "$entry"
      ;;
    rar)
      unrar p -idq -p"$ARCHIVE_PASSWORD" -- "$archive" "$entry"
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
OVERWRITE=0
ARCHIVE_TYPE="7z"
SEVENZ_BIN="7z"
TAR_COMPRESSION="none"
ARCHIVE_PASSWORD="INVALID_PASSWORD"

setup_archive_tools() {
  case "$ARCHIVE_TYPE" in
    zip|7z)
      select_7z_tool
      ;;
    rar)
      require_cmd unrar
      ;;
    tar|tar.gz|tar.xz|tar.bz2)
      require_cmd tar
      TAR_COMPRESSION="$(detect_tar_compression "$ARCHIVE")"
      local filter_tool
      filter_tool="$(get_decompression_command "$TAR_COMPRESSION")"
      if [[ "$filter_tool" == "unknown" ]]; then
        filter_tool="cat"
      fi
      filter_tool="$(echo "$filter_tool" | awk '{print $1}')"
      if [[ "$filter_tool" != "cat" ]]; then
        require_cmd "$filter_tool"
      fi
      ;;
    *)
      die "Archive type '$ARCHIVE_TYPE' is not supported."
      ;;
  esac
}

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
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    -p|--password)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      ARCHIVE_PASSWORD="$2"
      shift 2
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

if is_split_archive "$ARCHIVE" && ! is_first_chunk "$ARCHIVE"; then
  die "Failed to list entries for $ARCHIVE"
fi

ARCHIVE_TYPE="$(detect_archive_type "$ARCHIVE")"
if [[ "$ARCHIVE_TYPE" == "unknown" ]]; then
  log "Archive type not recognized; defaulting to 7z handlers."
  ARCHIVE_TYPE="7z"
fi

setup_archive_tools
require_cmd sha256sum

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$(default_sha256_path "$ARCHIVE")"
fi

if [[ -e "$OUTPUT_FILE" && "$OVERWRITE" -ne 1 ]]; then
  log "skip (manifest exists): $OUTPUT_FILE"
  exit 0
fi

mkdir -p -- "$(dirname -- "$OUTPUT_FILE")"
tmp_manifest="$(mktemp)"
TMP_MANIFEST="$tmp_manifest"
export TMP_MANIFEST
trap cleanup EXIT

log "Writing SHA-256 manifest to $OUTPUT_FILE"

# Optimization for tar files - process all entries in a single decompression pass
if [[ "$ARCHIVE_TYPE" == "tar" || "$ARCHIVE_TYPE" == "tar.gz" || "$ARCHIVE_TYPE" == "tar.xz" || "$ARCHIVE_TYPE" == "tar.bz2" ]]; then
  files_processed=0
  log "Using optimized tar processing"
  tmp_tar_entries="$(mktemp)"
  if ! list_archive_files "$ARCHIVE" >"$tmp_tar_entries"; then
    die "Failed to enumerate archive entries for $ARCHIVE"
  fi
  while IFS= read -r -d '' entry; do
    files_processed=$((files_processed + 1))
  done <"$tmp_tar_entries"

  if [[ "$files_processed" -gt 0 ]]; then
    tmp_tar_command="$(mktemp)"
    cat >"$tmp_tar_command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
f="${TAR_FILENAME:-}"
if [[ -z "$f" || "$f" == */ ]]; then
  exit 0
fi
printf 'processing: %s\n' "$f" >&2
hash="$(sha256sum | awk '{print $1}')"
if [[ -n "${TMP_MANIFEST:-}" ]]; then
  printf '%s\t%s\n' "$hash" "$f" >>"$TMP_MANIFEST"
fi
printf '%s  %s\n' "$hash" "$f"
EOF
    chmod +x "$tmp_tar_command"

    log "Processing $files_processed file(s) in a single pass"
    process_tar_archive "$ARCHIVE" "$tmp_tar_entries" "$tmp_tar_command"
  fi
else
  # Fallback processing for archive types without streaming optimizations
  files_processed=0
  tmp_entries_list="$(mktemp)"
  if ! list_archive_files "$ARCHIVE" >"$tmp_entries_list"; then
    rm -f "$tmp_entries_list"
    die "Failed to enumerate archive entries for $ARCHIVE"
  fi

  while IFS= read -r -d '' entry; do
    files_processed=$((files_processed + 1))
    log "processing: $entry"
    if ! hash="$(compute_sha256 "$ARCHIVE" "$entry")"; then
      rm -f "$tmp_entries_list"
      die "Failed to compute SHA-256 for $entry"
    fi
    printf '%s\t%s\n' "$hash" "$entry" >>"$tmp_manifest"
    printf '%s  %s\n' "$hash" "$entry"
  done <"$tmp_entries_list"
  rm -f "$tmp_entries_list"
fi

if [[ "$files_processed" -eq 0 ]]; then
  log "No files found inside archive."
  rm -f -- "$OUTPUT_FILE"
else
  LC_ALL=C sort -t $'\t' -k2,2 "$tmp_manifest" | awk -F $'\t' '{printf "%s  %s\n", $1, $2}' >"$OUTPUT_FILE"
  log "Processed $files_processed file(s)."
fi
