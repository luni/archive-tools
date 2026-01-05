#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SCAN_DIR="."
QUIET=0
REMOVE_COMPRESSED=0
CUSTOM_COMPRESSORS=0
SUPPORTED_COMPRESSORS=(pixz pzstd pigz pbzip2)

usage() {
  cat >&2 <<'EOF'
Usage:
  decompress.sh [options]

Options:
  -d, --dir DIR             Directory to scan for compressed files (default: .)
  -c, --compressor NAME     Limit to a decompressor (pixz, pzstd, pigz, pbzip2).
                            May be repeated or receive a comma-separated list.
                            First use replaces defaults.
  -r, --remove-source       Delete the compressed file after a successful restore.
  -q, --quiet               Suppress info logs.
  -h, --help                Show this help text.
EOF
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
      pixz|pzstd|pigz|pbzip2)
        SUPPORTED_COMPRESSORS+=("$part")
        ;;
      xz)
        SUPPORTED_COMPRESSORS+=("pixz")
        ;;
      zstd|pzstd)
        SUPPORTED_COMPRESSORS+=("pzstd")
        ;;
      gzip|pigz)
        SUPPORTED_COMPRESSORS+=("pigz")
        ;;
      bzip2|pbzip2)
        SUPPORTED_COMPRESSORS+=("pbzip2")
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
    -r|--remove-source|--remove-compressed) REMOVE_COMPRESSED=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "${#SUPPORTED_COMPRESSORS[@]}" -eq 0 ]]; then
  die "At least one decompressor must be enabled (pixz, pzstd, pigz, or pbzip2)."
fi

for comp in "${SUPPORTED_COMPRESSORS[@]}"; do
  command -v "$comp" >/dev/null 2>&1 || die "Required tool '$comp' is not on PATH."
done


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

decompress_file() {
  local f="$1" compressor out tmp

  # First check if file is misnamed and rename if needed
  local new_f
  if new_f="$(rename_misnamed_file "$f" 2>/dev/null)"; then
    # Rename succeeded, use the new filename
    if [[ -n "$new_f" && "$new_f" != "$f" ]]; then
      f="$new_f"
    fi
  else
    # Rename failed (likely target exists), continue with original filename
    # The rename function already logged the reason
    :
  fi

  case "$f" in
    *.txz)  compressor="pixz"; out="${f%.txz}.tar" ;;
    *.xz)   compressor="pixz"; out="${f%.xz}" ;;
    *.tzst) compressor="pzstd"; out="${f%.tzst}.tar" ;;
    *.zst)  compressor="pzstd"; out="${f%.zst}" ;;
    *.tgz)  compressor="pigz"; out="${f%.tgz}.tar" ;;
    *.gz)   compressor="pigz"; out="${f%.gz}" ;;
    *.tbz|*.tbz2) compressor="pbzip2"; out="${f%.*}.tar" ;;
    *.bz2)  compressor="pbzip2"; out="${f%.bz2}" ;;
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
    pixz)
      if pixz -dk "$f" "$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    pzstd)
      if pzstd -dqo "$tmp" "$f"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    pigz)
      if pigz -dck "$f" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
      ;;
    pbzip2)
      if pbzip2 -dck "$f" >"$tmp"; then :; else rm -f -- "$tmp"; return 1; fi
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
  if ! decompress_file "$file"; then
    log "error: failed to decompress $file (continuing...)"
  fi
done < <(find "$SCAN_DIR" -type f \( "${ext_pred[@]}" \) -print0)

if [[ "$found_any" -eq 0 ]]; then
  log "No matching compressed files under $SCAN_DIR"
fi
