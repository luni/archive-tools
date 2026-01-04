#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ARCHIVE=""
OUTPUT=""
QUIET=0
FORCE=0
KEEP_WORKDIR=0
REMOVE_SOURCE=0
TEMP_PARENT=""
SHA256_FILE=""
SHA256_ENABLED=0
SHA256_APPEND=0
ARCHIVE_TYPE=""
INPUT_STREAM_DESC=""
PZSTD_LEVEL="$DEFAULT_PZSTD_LEVEL"
declare -a INPUT_STREAM_CMD=()

usage() {
  cat <<'EOF'
Usage:
  convert-to-tarzst.sh [options] ARCHIVE

Description:
  - For *.7z inputs: extracts the archive into a temporary directory, repacks
    its contents into an uncompressed tar stream, and compresses that stream
    with pzstd to produce a seekable .tar.zst file.
  - For *.tar.gz/*.tgz, *.tar.xz/*.txz, or *.tar.bz2/*.tbz* inputs: streams the
    tarball through the appropriate decompressor directly into pzstd without
    creating a temporary workspace.
  - For *.zip inputs: extracts the archive into a temporary directory, repacks
    its contents into an uncompressed tar stream, and compresses that stream
    with pzstd to produce a seekable .tar.zst file.

Options:
  -o, --output FILE       Target .tar.zst path (default: ARCHIVE basename + .tar.zst)
      --pzstd-level -#    Override pzstd compression level (default: -10)
      --temp-dir DIR      Create the temporary extraction directory under DIR
                           (only applies to .7z inputs)
      --sha256            Emit SHA-256 manifest (defaults to ARCHIVE basename + .sha256)
      --sha256-file FILE  Emit SHA-256 manifest to FILE
      --sha256-append     Append to the SHA-256 file instead of truncating
  -f, --force             Overwrite the output file if it already exists
  -r, --remove-source     Delete the original archive after a successful conversion
  -q, --quiet             Suppress progress logs
  -k, --keep-temp         Keep the temporary extraction directory (printed on success;
                           only useful for .7z and .zip inputs)
  -h, --help              Show this help message
EOF
}


tar_list_entries() {
  local archive="$1" dest="$2" compression="$3"

  run_tar_list() {
    local tar_base=(tar --quoting-style=literal --show-transformed-names -tf)
    case "$compression" in
      gz)
        require_cmd gzip
        gzip -dc -- "$archive" | "${tar_base[@]}" -
        ;;
      bz2)
        require_cmd bzip2
        bzip2 -dc -- "$archive" | "${tar_base[@]}" -
        ;;
      xz)
        require_cmd xz
        xz -dc -- "$archive" | "${tar_base[@]}" -
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

write_sha256_manifest_tar() {
  local archive="$1" dest="$2" compression="$3"
  [[ -z "$dest" ]] && return 0

  local tmp_entries tmp_command
  tmp_entries="$(mktemp)"
  tmp_command="$(mktemp)"

  tar_list_entries "$archive" "$tmp_entries" "$compression"

  # Filter out directories
  local tmp_files
  tmp_files="$(mktemp)"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == */ ]] && continue
    printf '%s\0' "$entry"
  done <"$tmp_entries" >"$tmp_files"
  rm -f "$tmp_entries"

  cat >"$tmp_command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
f="${TAR_FILENAME:-}"
if [[ -z "$f" || "$f" == */ ]]; then
  exit 0
fi
hash="$(sha256sum | awk '{print $1}')"
manifest_line="$(printf '%s\t%s\n' "$hash" "$f")"
if [[ -n "${TMP_MANIFEST:-}" ]]; then
  printf '%s\n' "$manifest_line" >>"$TMP_MANIFEST"
fi
printf '%s  %s\n' "$hash" "$f"
EOF
  chmod +x "$tmp_command"

  local tmp_manifest
  tmp_manifest="$(mktemp)"
  export TMP_MANIFEST="$tmp_manifest"

  case "$compression" in
    gz)
      gzip -dc -- "$archive" | tar --null --files-from="$tmp_files" --to-command="$tmp_command" -xf - 2>/dev/null || true
      ;;
    bz2)
      bzip2 -dc -- "$archive" | tar --null --files-from="$tmp_files" --to-command="$tmp_command" -xf - 2>/dev/null || true
      ;;
    xz)
      xz -dc -- "$archive" | tar --null --files-from="$tmp_files" --to-command="$tmp_command" -xf - 2>/dev/null || true
      ;;
    none)
      tar --null --files-from="$tmp_files" --to-command="$tmp_command" -xf "$archive" 2>/dev/null || true
      ;;
  esac

  LC_ALL=C sort -t $'\t' -k2,2 "$tmp_manifest" | awk -F $'\t' '{printf "%s  %s\n", $1, $2}' >>"$dest"

  rm -f "$tmp_files" "$tmp_command" "$tmp_manifest"
}


setup_stream_input() {
  case "$ARCHIVE_TYPE" in
    tar.gz)
      require_cmd pigz
      INPUT_STREAM_CMD=(pigz -dc -- "$ARCHIVE")
      INPUT_STREAM_DESC="pigz -dc"
      ;;
    tar.xz)
      require_cmd pixz
      INPUT_STREAM_CMD=(pixz -k -d -- "$ARCHIVE" /dev/stdout)
      INPUT_STREAM_DESC="pixz -d"
      ;;
    tar.bz2)
      require_cmd pbzip2
      INPUT_STREAM_CMD=(pbzip2 -dc -- "$ARCHIVE")
      INPUT_STREAM_DESC="pbzip2 -dc"
      ;;
    *)
      die "Streaming conversion is not supported for archive type '$ARCHIVE_TYPE'"
      ;;
  esac
}

WORKDIR=""
TMP_OUTPUT=""
cleanup() {
  if [[ "$KEEP_WORKDIR" -eq 0 && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR" || true
  elif [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    log "Temporary directory kept at: $WORKDIR"
  fi
  if [[ -n "$TMP_OUTPUT" && -f "$TMP_OUTPUT" ]]; then
    rm -f -- "$TMP_OUTPUT" || true
  fi
}
trap cleanup EXIT INT TERM

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
    --temp-dir)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      TEMP_PARENT="$2"
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
    -r|--remove-source)
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
    -k|--keep-temp)
      KEEP_WORKDIR=1
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
      else
        die "Only one archive can be converted at a time."
      fi
      shift
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  die "Unexpected positional arguments: $*"
fi

[[ -n "$ARCHIVE" ]] || die "Archive path is required."
[[ -f "$ARCHIVE" ]] || die "Archive not found: $ARCHIVE"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$(default_basename_path "$ARCHIVE").tar.zst"
fi

if [[ -e "$OUTPUT" && "$FORCE" -ne 1 ]]; then
  die "Output already exists: $OUTPUT (use --force to overwrite)"
fi

ARCHIVE_TYPE="$(detect_archive_type "$ARCHIVE")"

if [[ "$SHA256_ENABLED" -eq 1 && -z "$SHA256_FILE" ]]; then
  SHA256_FILE="$(default_sha256_path "$ARCHIVE")"
fi

if [[ "$ARCHIVE_TYPE" == "7z" ]]; then
  require_cmd 7z
  require_cmd tar
elif [[ "$ARCHIVE_TYPE" == "zip" ]]; then
  require_cmd 7z
  require_cmd tar
else
  setup_stream_input
fi

require_cmd pzstd

if [[ "$SHA256_ENABLED" -eq 1 ]]; then
  require_cmd sha256sum
  prepare_file_for_write "$SHA256_FILE" "$SHA256_APPEND"
fi

if [[ -n "$TEMP_PARENT" ]]; then
  mkdir -p -- "$TEMP_PARENT" || die "Failed to create temp directory parent: $TEMP_PARENT"
fi

if [[ "$ARCHIVE_TYPE" == "7z" ]]; then
  WORKDIR="$(create_temp_dir "convert-to-tarzst" "$TEMP_PARENT")"
  log "Extracting $ARCHIVE into $WORKDIR ..."
  if [[ "$QUIET" -eq 1 ]]; then
    7z x -y -bso0 -bsp0 -o"$WORKDIR" -- "$ARCHIVE" >/dev/null
  else
    7z x -y -bso0 -bsp1 -o"$WORKDIR" -- "$ARCHIVE"
  fi
elif [[ "$ARCHIVE_TYPE" == "zip" ]]; then
  WORKDIR="$(create_temp_dir "convert-to-tarzst" "$TEMP_PARENT")"
  log "Extracting $ARCHIVE into $WORKDIR ..."
  if [[ "$QUIET" -eq 1 ]]; then
    7z x -y -bso0 -bsp0 -o"$WORKDIR" -- "$ARCHIVE" >/dev/null
  else
    7z x -y -bso0 -bsp1 -o"$WORKDIR" -- "$ARCHIVE"
  fi
fi

mkdir -p -- "$(dirname -- "$OUTPUT")"
TMP_OUTPUT="$(mktemp -p "$(dirname -- "$OUTPUT")" "$(basename -- "$OUTPUT").tmp.XXXXXX")"
# mktemp creates the destination path as a file; remove it so pzstd can create it.
rm -f -- "$TMP_OUTPUT"

tar_stream() {
  if [[ -z "$(find "$WORKDIR" -mindepth 1 -print -quit)" ]]; then
    tar --numeric-owner -C "$WORKDIR" -cf - --files-from /dev/null
  else
    tar --numeric-owner -C "$WORKDIR" -cf - .
  fi
}

if [[ "$SHA256_ENABLED" -eq 1 ]]; then
  case "$ARCHIVE_TYPE" in
    tar.gz|tar.xz|tar.bz2)
      TAR_COMPRESSION="$(detect_tar_compression "$ARCHIVE")"
      log "Computing SHA-256 manifest for tar archive..."
      write_sha256_manifest_tar "$ARCHIVE" "$SHA256_FILE" "$TAR_COMPRESSION"
      ;;
  esac
fi

log "Creating tar.zst at $OUTPUT ..."
if [[ "$ARCHIVE_TYPE" == "7z" || "$ARCHIVE_TYPE" == "zip" ]]; then
  if ! tar_stream | pzstd "$PZSTD_LEVEL" -q -o "$TMP_OUTPUT"; then
    die "pzstd compression failed"
  fi
else
  log "Streaming $ARCHIVE via $INPUT_STREAM_DESC ..."
  if ! "${INPUT_STREAM_CMD[@]}" | pzstd "$PZSTD_LEVEL" -q -o "$TMP_OUTPUT"; then
    die "pzstd compression failed"
  fi
fi

if [[ -e "$OUTPUT" && "$FORCE" -eq 1 ]]; then
  rm -f -- "$OUTPUT"
fi
mv -f -- "$TMP_OUTPUT" "$OUTPUT"
TMP_OUTPUT=""

if ! touch -r "$ARCHIVE" "$OUTPUT"; then
  die "Failed to copy modification time to $OUTPUT"
fi

if [[ "$REMOVE_SOURCE" -eq 1 ]]; then
  log "Removing source archive: $ARCHIVE"
  rm -f -- "$ARCHIVE"
fi

if [[ "$SHA256_ENABLED" -eq 1 ]]; then
  case "$ARCHIVE_TYPE" in
    7z|zip)
      if ! write_sha256_manifest "$WORKDIR" "$SHA256_FILE"; then
        die "Failed to write SHA256 manifest"
      fi
      ;;
  esac
fi

log "Conversion complete: $OUTPUT"
