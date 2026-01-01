#!/usr/bin/env bash
set -euo pipefail

ARCHIVE=""
OUTPUT=""
QUIET=0
FORCE=0
KEEP_WORKDIR=0
REMOVE_SOURCE=0
TEMP_PARENT=""
SHA256_FILE=""
SHA256_APPEND=0
AUTO_SHA256_SENTINEL="__auto_sha256__"
ZEEKSTD_BIN_FROM_FLAG=0
ZEEKSTD_BIN="${ZEEKSTD_BIN:-${HOME}/.cargo/bin/zeekstd}"
declare -a ZEEKSTD_ARGS
ZEEKSTD_ARGS=(--force --level 10)

usage() {
  cat <<'EOF'
Usage:
  convert-7z-to-tarzst.sh [options] ARCHIVE.7z

Description:
  Extracts the provided *.7z archive into a temporary directory, repacks its
  contents into an uncompressed tar stream, and compresses that stream with the
  zeekstd CLI to produce a seekable .tar.zst file.

Options:
  -o, --output FILE       Target .tar.zst path (default: ARCHIVE basename + .tar.zst)
      --zeekstd PATH      Override zeekstd binary (default: ${HOME}/.cargo/bin/zeekstd)
      --zeekstd-arg ARG   Additional argument to pass to zeekstd (repeatable)
      --temp-dir DIR      Create the temporary extraction directory under DIR
      --sha256 [FILE]     Write/overwrite FILE with SHA-256 of every file inside the archive
                          (defaults to ARCHIVE basename + .sha256 when FILE omitted)
      --sha256-append     Append to the SHA-256 file instead of truncating
  -f, --force             Overwrite the output file if it already exists
      --remove-source     Delete the original .7z archive after a successful conversion
  -q, --quiet             Suppress progress logs
  -k, --keep-temp         Keep the temporary extraction directory (printed on success)
  -h, --help              Show this help message
EOF
}

log() {
  [[ "$QUIET" -eq 1 ]] && return 0
  printf '%s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

default_basename_path() {
  local archive="$1" dir base
  dir="$(dirname -- "$archive")"
  base="$(basename -- "$archive")"
  if [[ "$base" == *.* ]]; then
    base="${base%.*}"
  fi
  printf '%s/%s\n' "$dir" "$base"
}

default_sha256_path() {
  local archive="$1"
  printf '%s.sha256\n' "$(default_basename_path "$archive")"
}

prepare_sha256_file() {
  local file="$1" append_flag="$2"
  [[ -z "$file" ]] && return 0
  mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || true
  if [[ "$append_flag" -eq 1 ]]; then
    : >>"$file"
  else
    : >"$file"
  fi
}

write_sha256_manifest() {
  local root="$1" dest="$2" file rel hash
  [[ -z "$dest" ]] && return 0

  # Sort paths for deterministic output
  while IFS= read -r -d '' file; do
    rel="${file#$root/}"
    if [[ "$rel" == "$file" ]]; then
      rel="$(basename -- "$file")"
    fi
    hash="$(sha256sum -- "$file" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$rel" >>"$dest"
  done < <(LC_ALL=C find "$root" -type f -print0 | LC_ALL=C sort -z)
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' is not on PATH."
}

WORKDIR=""
TMP_OUTPUT=""
cleanup() {
  if [[ "$KEEP_WORKDIR" -eq 0 && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  elif [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    log "Temporary directory kept at: $WORKDIR"
  fi
  if [[ -n "$TMP_OUTPUT" && -f "$TMP_OUTPUT" ]]; then
    rm -f -- "$TMP_OUTPUT"
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
    --zeekstd)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      ZEEKSTD_BIN="$2"
      ZEEKSTD_BIN_FROM_FLAG=1
      shift 2
      ;;
    --zeekstd-arg)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      ZEEKSTD_ARGS+=("$2")
      shift 2
      ;;
    --temp-dir)
      [[ $# -lt 2 ]] && die "Missing value for $1"
      TEMP_PARENT="$2"
      shift 2
      ;;
    --sha256)
      if [[ $# -ge 2 && "$2" != -* ]]; then
        SHA256_FILE="$2"
        shift 2
      else
        SHA256_FILE="$AUTO_SHA256_SENTINEL"
        shift
      fi
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

if [[ "$SHA256_FILE" == "$AUTO_SHA256_SENTINEL" ]]; then
  SHA256_FILE="$(default_sha256_path "$ARCHIVE")"
fi

if [[ -n "$SHA256_FILE" ]]; then
  prepare_sha256_file "$SHA256_FILE" "$SHA256_APPEND"
fi

require_cmd 7z
require_cmd tar
if [[ -n "$SHA256_FILE" ]]; then
  require_cmd sha256sum
fi

if [[ -n "$TEMP_PARENT" ]]; then
  mkdir -p -- "$TEMP_PARENT" || die "Failed to create temp directory parent: $TEMP_PARENT"
fi

if [[ ! -x "$ZEEKSTD_BIN" ]]; then
  if [[ "$ZEEKSTD_BIN_FROM_FLAG" -eq 0 ]]; then
    if command -v zeekstd >/dev/null 2>&1; then
      ZEEKSTD_BIN="$(command -v zeekstd)"
    else
      die "zeekstd binary not found at ${HOME}/.cargo/bin/zeekstd (run ./install-zeekstd.sh)."
    fi
  else
    die "zeekstd binary is not executable: $ZEEKSTD_BIN"
  fi
fi

template="convert-7z-to-tarzst.XXXXXX"
if [[ -n "$TEMP_PARENT" ]]; then
  WORKDIR="$(mktemp -d -p "$TEMP_PARENT" "$template")" || die "Failed to create temporary directory under $TEMP_PARENT"
else
  WORKDIR="$(mktemp -d)" || die "Failed to create temporary directory"
fi
log "Extracting $ARCHIVE into $WORKDIR ..."
if [[ "$QUIET" -eq 1 ]]; then
  7z x -y -bso0 -bsp0 -o"$WORKDIR" -- "$ARCHIVE" >/dev/null
else
  7z x -y -bso0 -bsp1 -o"$WORKDIR" -- "$ARCHIVE"
fi

mkdir -p -- "$(dirname -- "$OUTPUT")"
TMP_OUTPUT="$(mktemp -p "$(dirname -- "$OUTPUT")" "$(basename -- "$OUTPUT").tmp.XXXXXX")"

tar_stream() {
  if [[ -z "$(find "$WORKDIR" -mindepth 1 -print -quit)" ]]; then
    tar -C "$WORKDIR" -cf - --files-from /dev/null
  else
    tar -C "$WORKDIR" -cf - .
  fi
}

log "Creating tar.zst at $OUTPUT ..."
if ! tar_stream | "$ZEEKSTD_BIN" "${ZEEKSTD_ARGS[@]}" -o "$TMP_OUTPUT"; then
  die "zeekstd compression failed"
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

if [[ -n "$SHA256_FILE" ]]; then
  write_sha256_manifest "$WORKDIR" "$SHA256_FILE"
fi

log "Conversion complete: $OUTPUT"
