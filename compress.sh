#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Defaults
SCAN_DIR="."
SHA1_FILE=""
SHA1_APPEND=0
SHA256_FILE=""
SHA256_APPEND=0
CHECKSUM_DELIM=$'\x1f'

THRESHOLD_BYTES=$((100 * 1024 * 1024))   # 100 MiB
SMALL_JOBS=8

SMALL_COMPRESSOR="xz"   # xz | zstd
BIG_COMPRESSOR="pixz"   # pixz | xz | pzstd | zstd

XZ_LEVEL="$DEFAULT_XZ_LEVEL"
ZSTD_LEVEL="$DEFAULT_ZSTD_LEVEL"
PZSTD_LEVEL="$DEFAULT_PZSTD_LEVEL"

QUIET=0
EXTENSIONS=(tar sql txt csv ibd xlsx docx log)
EXTENSIONS_CUSTOMIZED=0

usage() {
  cat >&2 <<'EOF'
Usage:
  compress.sh [options]

Options:
  -d, --dir DIR           Directory to scan (default: .)
  -s, --sha1 FILE         Create/truncate FILE and write SHA1 of originals (before compression per file)
      --sha1-append       Append to FILE instead of truncating
      --sha256 FILE       Create/truncate FILE and write SHA256 of originals (before compression per file)
      --sha256-append     Append to FILE instead of truncating
  -t, --threshold SIZE    Small/Big split (default: 100MiB). Examples: 100M, 200MiB, 50000000
  -j, --jobs N            Parallel jobs for small files (default: 8)

      --small TOOL        Small-file compressor: xz or zstd (default: xz)
      --big TOOL          Big-file compressor: pixz, xz, pzstd, or zstd (default: pixz)

      --xz-level  -#      xz/pixz level (default: -5)
      --zstd-level -#     zstd level (default: -6)
      --pzstd-level -#    pzstd level (default: -10)

      --ext EXT           Add an extension (without leading dot) to the scan list.
                          May be repeated; first use replaces the defaults.

  -q, --quiet             Less logging
  -h, --help              Show help
EOF
}

parse_size() {
  local s="${1,,}" n unit
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    echo "$s"; return 0
  fi
  if [[ "$s" =~ ^([0-9]+)(k|kb|kib)$ ]]; then n="${BASH_REMATCH[1]}"; echo $((n*1024)); return 0; fi
  if [[ "$s" =~ ^([0-9]+)(m|mb|mib)$ ]]; then n="${BASH_REMATCH[1]}"; echo $((n*1024*1024)); return 0; fi
  if [[ "$s" =~ ^([0-9]+)(g|gb|gib)$ ]]; then n="${BASH_REMATCH[1]}"; echo $((n*1024*1024*1024)); return 0; fi
  echo "Invalid size: $1" >&2
  exit 2
}

emit_checksum_lines() {
  local sha1_line="${1-}" sha256_line="${2-}"
  if [[ -n "$sha1_line" ]]; then
    printf 'sha1%s%s\n' "$CHECKSUM_DELIM" "$sha1_line"
  fi
  if [[ -n "$sha256_line" ]]; then
    printf 'sha256%s%s\n' "$CHECKSUM_DELIM" "$sha256_line"
  fi
}

append_checksum_line() {
  local algo="$1" line="$2"
  case "$algo" in
    sha1)
      [[ -n "$SHA1_FILE" ]] && printf '%s\n' "$line" >>"$SHA1_FILE"
      ;;
    sha256)
      [[ -n "$SHA256_FILE" ]] && printf '%s\n' "$line" >>"$SHA256_FILE"
      ;;
  esac
}

fanout_checksums() {
  local line algo payload
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=$CHECKSUM_DELIM read -r algo payload <<<"$line"
    append_checksum_line "$algo" "$payload"
  done
}

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir) SCAN_DIR="$2"; shift 2 ;;
    -s|--sha1) SHA1_FILE="$2"; shift 2 ;;
    --sha1-append) SHA1_APPEND=1; shift ;;
    --sha256) SHA256_FILE="$2"; shift 2 ;;
    --sha256-append) SHA256_APPEND=1; shift ;;
    -t|--threshold) THRESHOLD_BYTES="$(parse_size "$2")"; shift 2 ;;
    -j|--jobs) SMALL_JOBS="$2"; shift 2 ;;
    --small) SMALL_COMPRESSOR="$2"; shift 2 ;;
    --big) BIG_COMPRESSOR="$2"; shift 2 ;;
    --xz-level) XZ_LEVEL="$2"; shift 2 ;;
    --zstd-level) ZSTD_LEVEL="$2"; shift 2 ;;
    --pzstd-level) PZSTD_LEVEL="$2"; shift 2 ;;
    --ext)
      if [[ "$EXTENSIONS_CUSTOMIZED" -eq 0 ]]; then
        EXTENSIONS=()
        EXTENSIONS_CUSTOMIZED=1
      fi
      IFS=',' read -r -a _ext_parts <<<"${2// /,}"
      for part in "${_ext_parts[@]}"; do
        part="${part,,}"
        part="${part#.}"
        [[ -z "$part" ]] && continue
        EXTENSIONS+=("$part")
      done
      shift 2
      ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# Create/truncate checksum files up front (if requested)
if [[ -n "$SHA256_FILE" && "$SHA256_APPEND" -eq 1 && -e "$SHA256_FILE" && ! -s "$SHA256_FILE" ]]; then
  log "Detected empty SHA-256 manifest; overwriting $SHA256_FILE"
  SHA256_APPEND=0
fi
prepare_file_for_write "$SHA1_FILE" "$SHA1_APPEND"
prepare_file_for_write "$SHA256_FILE" "$SHA256_APPEND"

fsize() {
  stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1"
}

out_name() {
  local f="$1" algo="$2"
  case "$algo" in
    xz|pixz)
      [[ "$f" == *.tar ]] && printf '%s\n' "${f%.tar}.txz" || printf '%s\n' "${f}.xz"
      ;;
    zstd|pzstd)
      [[ "$f" == *.tar ]] && printf '%s\n' "${f%.tar}.tzst" || printf '%s\n' "${f}.zst"
      ;;
    *)
      echo "Unknown compressor: $algo" >&2
      return 2
      ;;
  esac
}

compress_small() {
  local f="$1" out tmp sha1_line="" sha256_line=""
  out="$(out_name "$f" "$SMALL_COMPRESSOR")"
  [[ -e "$out" ]] && { log "skip: $f"; return 0; }

  tmp="${out}.tmp.${PARALLEL_SEQ:-$$}"
  rm -f -- "$tmp"

  # compute checksums BEFORE compression (only written out if compression succeeds)
  if [[ -n "${SHA1_FILE:-}" ]]; then
    sha1_line="$(sha1sum -- "$f")"
  fi
  if [[ -n "${SHA256_FILE:-}" ]]; then
    sha256_line="$(sha256sum -- "$f")"
  fi

  log "small(${SMALL_COMPRESSOR}): $f -> $out"

  case "$SMALL_COMPRESSOR" in
    xz)
      if xz "$XZ_LEVEL" -T1 -c -- "$f" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    zstd)
      if zstd "$ZSTD_LEVEL" -T1 -q -c -- "$f" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    *)
      echo "SMALL_COMPRESSOR must be xz or zstd" >&2
      rm -f -- "$tmp"
      return 2
      ;;
  esac

  touch -r "$f" "$tmp"
  mv -f -- "$tmp" "$out"
  rm -f -- "$f"

  emit_checksum_lines "$sha1_line" "$sha256_line"
}

compress_big_seq() {
  local f="$1" out tmp sha1_line="" sha256_line=""
  out="$(out_name "$f" "$BIG_COMPRESSOR")"
  [[ -e "$out" ]] && { log "skip: $f"; return 0; }

  tmp="${out}.tmp.$$"
  rm -f -- "$tmp"

  if [[ -n "$SHA1_FILE" ]]; then
    sha1_line="$(sha1sum -- "$f")"
  fi
  if [[ -n "$SHA256_FILE" ]]; then
    sha256_line="$(sha256sum -- "$f")"
  fi

  log "big(${BIG_COMPRESSOR}): $f -> $out"

  case "$BIG_COMPRESSOR" in
    pixz)
      if pv -ptebar -- "$f" | pixz "$XZ_LEVEL" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    xz)
      if pv -ptebar -- "$f" | xz "$XZ_LEVEL" -c >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    pzstd)
      if pv -ptebar -- "$f" | pzstd "$PZSTD_LEVEL" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    zstd)
      if pv -ptebar -- "$f" | zstd "$ZSTD_LEVEL" -q -c >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    *)
      echo "BIG_COMPRESSOR must be pixz, xz, pzstd, or zstd" >&2
      rm -f -- "$tmp"
      return 2
      ;;
  esac

  touch -r "$f" "$tmp"
  mv -f -- "$tmp" "$out"
  rm -f -- "$f"

  [[ -n "$sha1_line" ]] && append_checksum_line sha1 "$sha1_line"
  [[ -n "$sha256_line" ]] && append_checksum_line sha256 "$sha256_line"
}

export -f compress_small out_name emit_checksum_lines log
export SMALL_COMPRESSOR XZ_LEVEL ZSTD_LEVEL QUIET SHA1_FILE SHA256_FILE CHECKSUM_DELIM REMOVE_SOURCE

small_list="$(mktemp)"
big_list="$(mktemp)"
trap 'rm -f "$small_list" "$big_list"' EXIT

# collect + split
if [[ "${#EXTENSIONS[@]}" -eq 0 ]]; then
  echo "No extensions configured; nothing to do." >&2
  exit 0
fi

ext_pred=()
for i in "${!EXTENSIONS[@]}"; do
  ext="${EXTENSIONS[$i]}"
  [[ -z "$ext" ]] && continue
  if [[ "$i" -gt 0 ]]; then
    ext_pred+=("-o")
  fi
  ext_pred+=("-name" "*.${ext}")
done

if [[ "${#ext_pred[@]}" -eq 0 ]]; then
  echo "No valid extensions configured; nothing to do." >&2
  exit 0
fi

find "$SCAN_DIR" -type f \( "${ext_pred[@]}" \) \
  ! -name '*.zst' ! -name '*.tzst' ! -name '*.xz' ! -name '*.txz' -print0 |
while IFS= read -r -d '' f; do
  if [[ "$(fsize "$f")" -lt "$THRESHOLD_BYTES" ]]; then
    printf '%s\0' "$f" >>"$small_list"
  else
    printf '%s\0' "$f" >>"$big_list"
  fi
done || true

# small files in parallel
if [[ -n "$SHA1_FILE" || -n "$SHA256_FILE" ]]; then
  parallel -0 --no-run-if-empty --bar --lb -j "$SMALL_JOBS" compress_small {} :::: "$small_list" | fanout_checksums
else
  parallel -0 --no-run-if-empty --bar -j "$SMALL_JOBS" compress_small {} :::: "$small_list"
fi

# big files sequential
if [[ -s "$big_list" ]]; then
  while IFS= read -r -d '' f; do
    compress_big_seq "$f"
  done <"$big_list" || true
fi

exit 0
