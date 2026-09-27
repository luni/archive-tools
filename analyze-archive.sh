#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

tmp_manifest=""
tmp_tar_entries=""
tmp_entries_list=""
tmp_output=""
tmp_size=""

cleanup() {
  if [[ -n "$tmp_manifest" && -f "$tmp_manifest" ]]; then
    rm -f "$tmp_manifest"
  fi
  if [[ -n "$tmp_size" && -f "$tmp_size" ]]; then
    rm -f "$tmp_size"
  fi
  if [[ -n "$tmp_tar_entries" && -f "$tmp_tar_entries" ]]; then
    rm -f "$tmp_tar_entries"
  fi
  if [[ -n "$tmp_entries_list" && -f "$tmp_entries_list" ]]; then
    rm -f "$tmp_entries_list"
  fi
  if [[ -n "$tmp_output" && -f "$tmp_output" ]]; then
    rm -f "$tmp_output"
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
  -o, --output FILE   Target SHA-256 manifest (default: ARCHIVE + .sha256)
  -q, --quiet         Suppress progress logs
      --overwrite     Overwrite existing manifest if present
  -p, --password PWD  Password for encrypted archives (default: INVALID_PASSWORD,
                        or set the ARCHIVE_PASSWORD environment variable). The
                        password is passed to the archiver's command line and may
                        be visible in process listings.
  -h, --help          Show this help message
EOF
}


parse_7z_listing() {
  local listing_tmp="$1"
  local line="" path="" attrs="" size="" folder="" started=0

  flush_entry() {
    if [[ -n "$path" && "$attrs" != *D* && "$folder" != "+" && "$path" != */ ]]; then
      # size first: a path containing a tab still lands intact in the last field
      printf '%s\t%s\0' "$size" "$path"
    fi
    path=""
    attrs=""
    size=""
    folder=""
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
    elif [[ "$line" == Size\ =\ * ]]; then
      size="${line#Size = }"
    elif [[ "$line" == Folder\ =\ * ]]; then
      folder="${line#Folder = }"
    elif [[ "$line" != *" = "* ]]; then
      # Every -slt line inside the entry block is "Key = Value"; a bare line
      # is the continuation of a member name split by an embedded newline,
      # which would silently truncate that entry's path.
      die "Malformed listing line (embedded newline in member name?): $line"
    fi
  done <"$listing_tmp"

  rm -f "$listing_tmp"
  flush_entry
}

list_archive_files_7z() {
  local archive="$1"
  local listing_tmp listing_output

  listing_tmp="$(mktemp)"
  if ! "$SEVENZ_BIN" l -slt -p"$ARCHIVE_PASSWORD" -- "$archive" >"$listing_tmp" 2>&1; then
    listing_output="$(cat "$listing_tmp")"
    rm -f "$listing_tmp"
    if [[ -n "$listing_output" ]]; then
      printf '%s\n' "$listing_output" >&2
    fi
    die "Failed to list entries for $archive"
  fi

  parse_7z_listing "$listing_tmp"
}


list_archive_files_tar() {
  local archive="$1" entry listing_tmp
  listing_tmp="$(mktemp)"
  tar_list_entries "$archive" "$listing_tmp" "$TAR_COMPRESSION"
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
  if ! "$SEVENZ_BIN" l -slt -p"$ARCHIVE_PASSWORD" -- "$archive" >"$listing_tmp" 2>&1; then
    cat "$listing_tmp" >&2
    rm -f "$listing_tmp"
    die "Failed to list zip entries for $archive"
  fi

  parse_7z_listing "$listing_tmp"
}

list_archive_files_rar() {
  local archive="$1" entry="" entry_type="" entry_size="" line
  local listing_tmp
  listing_tmp="$(mktemp)"
  if ! unrar lt -p"$ARCHIVE_PASSWORD" -- "$archive" >"$listing_tmp" 2>&1; then
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
  # Track Name, Type and Size for each entry and emit "size\tname" per file
  flush_entry() {
    if [[ -n "$entry" && "$entry_type" == "File" ]]; then
      printf '%s\t%s\0' "$entry_size" "$entry"
    fi
    entry=""
    entry_type=""
    entry_size=""
  }

  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*Name:[[:space:]]*(.+)$ ]]; then
      flush_entry
      entry="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*Type:[[:space:]]*(.+)$ ]]; then
      entry_type="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*Size:[[:space:]]*([0-9]+) ]]; then
      entry_size="${BASH_REMATCH[1]}"
    elif [[ -z "$line" ]]; then
      flush_entry
    fi
  done <"$listing_tmp"
  rm -f "$listing_tmp"
  flush_entry
}

list_archive_files() {
  case "$ARCHIVE_TYPE" in
    7z) list_archive_files_7z "$ARCHIVE" ;;
    tar|tar.gz|tar.xz|tar.bz2|tar.zst) list_archive_files_tar "$ARCHIVE" ;;
    zip) list_archive_files_zip "$ARCHIVE" ;;
    rar) list_archive_files_rar "$ARCHIVE" ;;
    *)
      die "Unsupported archive type for $ARCHIVE"
      ;;
  esac
}

# Stream every file's contents in archive order in a single pass. Pairs with
# the ordered "size<TAB>path" listings produced by the list_archive_files_*
# helpers; each entry is framed from the stream with head -c <size>.
stream_all_entries() {
  local archive="$1"
  case "$ARCHIVE_TYPE" in
    7z|zip)
      "$SEVENZ_BIN" x -so -p"$ARCHIVE_PASSWORD" -- "$archive"
      ;;
    rar)
      unrar p -idq -p"$ARCHIVE_PASSWORD" -- "$archive"
      ;;
    *)
      die "Unsupported archive type for streaming: $ARCHIVE_TYPE"
      ;;
  esac
}

ARCHIVE=""
OUTPUT_FILE=""
QUIET=0
OVERWRITE=0
ARCHIVE_TYPE="7z"
SEVENZ_BIN="7z"
TAR_COMPRESSION="none"
ARCHIVE_PASSWORD="${ARCHIVE_PASSWORD:-INVALID_PASSWORD}"

setup_archive_tools() {
  case "$ARCHIVE_TYPE" in
    zip|7z)
      select_7z_tool
      ;;
    rar)
      require_cmd unrar
      ;;
    tar|tar.gz|tar.xz|tar.bz2|tar.zst)
      require_cmd tar
      require_cmd file
      # Sniff the payload too: a misnamed archive (e.g. gzip bytes named
      # *.tar) is corrected to its real decompressor.
      TAR_COMPRESSION="$(resolve_tar_compression "$ARCHIVE")"
      case "$TAR_COMPRESSION" in
        gz) require_cmd pigz ;;
        bz2) require_cmd pbzip2 ;;
        xz) require_cmd pixz ;;
        lzma) require_cmd xz ;;
        Z) require_cmd gzip ;;
        zst) require_cmd pzstd ;;
        none) ;;
        *) die "Unsupported tar compression '$TAR_COMPRESSION'" ;;
      esac
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

# Positional args may also follow a literal "--".
for arg in "$@"; do
  if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE="$arg"
  else
    die "Only one archive can be processed at a time."
  fi
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
tmp_output="$(mktemp)"
trap cleanup EXIT

log "Writing SHA-256 manifest to $OUTPUT_FILE"

# Optimization for tar files - process all entries in a single decompression pass
if [[ "$ARCHIVE_TYPE" == "tar" || "$ARCHIVE_TYPE" == tar.* ]]; then
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
    log "Processing $files_processed archive entries in a single pass"
    export TAR_CMD_VERBOSE=1
    # Stage the manifest in a temp file and publish it atomically: a failure
    # mid-pass must not leave a truncated manifest that later runs would skip.
    if ! write_tar_manifest "$ARCHIVE" "$TAR_COMPRESSION" "$tmp_output"; then
      die "Failed to process tar entries"
    fi
    # Report the number of regular files actually hashed; the pre-listing
    # count above can include links/dirs that carry no member data.
    files_processed="$(wc -l <"$tmp_output")"
    if [[ "$files_processed" -gt 0 ]]; then
      chmod_like_new_file "$tmp_output"
      mv -- "$tmp_output" "$OUTPUT_FILE"
      tmp_output=""
    fi
  fi
else
  # 7z/zip/rar: stream the whole archive once and frame each entry out of the
  # stream with head -c using the sizes captured in the archive listing.
  files_processed=0
  tmp_entries_list="$(mktemp)"
  if ! list_archive_files "$ARCHIVE" >"$tmp_entries_list"; then
    rm -f "$tmp_entries_list"
    die "Failed to enumerate archive entries for $ARCHIVE"
  fi

  log "Streaming archive contents in a single pass"
  exec {DATA_FD}< <(stream_all_entries "$ARCHIVE")
  stream_pid=$!

  while IFS=$'\t' read -r -d '' entry_size entry; do
    files_processed=$((files_processed + 1))
    log "processing: $entry"
    if [[ ! "$entry_size" =~ ^[0-9]+$ ]]; then
      die "Failed to determine entry size for '$entry' in $ARCHIVE"
    fi
    tmp_size="$(mktemp)"
    # tee writes the size reference synchronously — no process substitution,
    # so the byte count is complete when the pipeline returns.
    if ! hash="$(head -c "$entry_size" <&"$DATA_FD" | tee -- "$tmp_size" | sha256sum | awk '{print $1}')"; then
      rm -f "$tmp_size"
      die "Failed to compute SHA-256 for $entry"
    fi
    actual_size="$(stat -c '%s' -- "$tmp_size")"
    rm -f "$tmp_size"
    if [[ "$actual_size" != "$entry_size" ]]; then
      die "Failed to compute SHA-256 for $entry (expected $entry_size bytes, read $actual_size)"
    fi
    entry_esc="$(escape_manifest_path "$entry")"
    printf '%s\t%s\t%s\n' "$hash" "$entry_esc" "$entry_size" >>"$tmp_manifest"
    printf '%s  %s  %s\n' "$hash" "$entry_esc" "$entry_size"
  done <"$tmp_entries_list"
  rm -f "$tmp_entries_list"
  tmp_entries_list=""

  # Leftover bytes are expected for split RAR volumes: `unrar lt` only lists
  # entries that begin in the queried volume, while `unrar p` streams them all.
  leftover_bytes="$(head -c 1 <&"$DATA_FD" | wc -c)"
  exec {DATA_FD}<&-
  stream_rc=0
  wait "$stream_pid" 2>/dev/null || stream_rc=$?
  if [[ "$leftover_bytes" -gt 0 ]]; then
    log "note: archive stream contained entries beyond the listing (split archive?)"
  elif [[ "$stream_rc" -ne 0 ]]; then
    die "Streaming archive contents failed for $ARCHIVE"
  fi

  if [[ "$files_processed" -gt 0 ]]; then
    LC_ALL=C sort -t $'\t' -k2,2 "$tmp_manifest" | awk -F $'\t' '{printf "%s  %s  %s\n", $1, $2, $3}' >"$tmp_output"
    chmod_like_new_file "$tmp_output"
    mv -- "$tmp_output" "$OUTPUT_FILE"
    tmp_output=""
  fi
fi

if [[ "$files_processed" -eq 0 ]]; then
  log "No files found inside archive."
  rm -f -- "$OUTPUT_FILE"
else
  log "Processed $files_processed file(s)."
fi
