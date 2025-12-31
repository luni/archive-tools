#!/usr/bin/env bash
set -euo pipefail

SCAN_DIR="."
LOG=1
REMOVE_COMPRESSED=0
CUSTOM_COMPRESSORS=0
SUPPORTED_COMPRESSORS=(xz zstd)

usage() {
  cat >&2 <<'EOF'
Usage:
  decompress.sh [options]

Options:
  -d, --dir DIR             Directory to scan for compressed files (default: .)
  -c, --compressor NAME     Limit to a compressor (xz or zstd). May be repeated or
                            receive a comma-separated list. First use replaces defaults.
      --remove-compressed   Delete the compressed file after a successful restore.
  -q, --quiet               Suppress info logs.
  -h, --help                Show this help text.
EOF
}

log() { [[ "$LOG" == "1" ]] && printf '%s\n' "$*" >&2; }

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

compressor_enabled() {
  local needle="$1"
  for c in "${SUPPORTED_COMPRESSORS[@]}"; do
    [[ "$c" == "$needle" ]] && return 0
  done
  return 1
}

add_compressors() {
  local raw="$1" part
  IFS=',' read -r -a _parts <<<"${raw// /,}"
  for part in "${_parts[@]}"; do
    part="${part,,}"
    [[ -z "$part" ]] && continue
    case "$part" in
      xz|zstd)
        SUPPORTED_COMPRESSORS+=("$part")
        ;;
      *)
        die "Unsupported compressor: $part"
        ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir) SCAN_DIR="$2"; shift 2 ;;
    -c|--compressor)
      if [[ "$CUSTOM_COMPRESSORS" -eq 0 ]]; then
        SUPPORTED_COMPRESSORS=()
        CUSTOM_COMPRESSORS=1
      fi
      add_compressors "$2"
      shift 2
      ;;
    --remove-compressed) REMOVE_COMPRESSED=1; shift ;;
    -q|--quiet) LOG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "${#SUPPORTED_COMPRESSORS[@]}" -eq 0 ]]; then
  die "At least one compressor must be enabled (xz or zstd)."
fi

for comp in "${SUPPORTED_COMPRESSORS[@]}"; do
  command -v "$comp" >/dev/null 2>&1 || die "Required tool '$comp' is not on PATH."
done

declare -A COMPRESSOR_EXTS=(
  [xz]="xz txz"
  [zstd]="zst tzst"
)

ext_pred=()
add_predicate() {
  local ext="$1"
  if [[ "${#ext_pred[@]}" -gt 0 ]]; then
    ext_pred+=("-o")
  fi
  ext_pred+=("-name" "*.${ext}")
}

for comp in "${SUPPORTED_COMPRESSORS[@]}"; do
  for ext in ${COMPRESSOR_EXTS[$comp]}; do
    add_predicate "$ext"
  done
done

if [[ "${#ext_pred[@]}" -eq 0 ]]; then
  log "No file patterns configured; exiting."
  exit 0
fi

restore_mtime() {
  local src="$1" dst="$2"
  touch -r "$src" "$dst"
}

decompress_file() {
  local f="$1" compressor out tmp
  case "$f" in
    *.txz) compressor="xz"; out="${f%.txz}.tar" ;;
    *.xz)  compressor="xz"; out="${f%.xz}" ;;
    *.tzst) compressor="zstd"; out="${f%.tzst}.tar" ;;
    *.zst) compressor="zstd"; out="${f%.zst}" ;;
    *) log "skip (unknown extension): $f"; return 0 ;;
  esac

  if ! compressor_enabled "$compressor"; then
    log "skip ($compressor disabled): $f"
    return 0
  fi

  if [[ -e "$out" ]]; then
    log "skip (target exists): $out"
    return 0
  fi

  tmp="${out}.tmp.$$"
  rm -f -- "$tmp"

  log "decompress(${compressor}): $f -> $out"
  case "$compressor" in
    xz)
      if xz -dc -- "$f" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    zstd)
      if zstd -dc -q -- "$f" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
  esac

  restore_mtime "$f" "$tmp"
  mv -f -- "$tmp" "$out"

  if [[ "$REMOVE_COMPRESSED" -eq 1 ]]; then
    rm -f -- "$f"
  fi
}

found_any=0
while IFS= read -r -d '' file; do
  found_any=1
  decompress_file "$file"
done < <(find "$SCAN_DIR" -type f \( "${ext_pred[@]}" \) -print0)

if [[ "$found_any" -eq 0 ]]; then
  log "No matching compressed files under $SCAN_DIR"
fi
