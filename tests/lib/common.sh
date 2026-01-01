#!/usr/bin/env bash

# Shared helpers for test suites

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${TEST_ROOT:-$(cd "$COMMON_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
PYTHON_HELPERS_DIR="${PYTHON_HELPERS_DIR:-$COMMON_DIR/python}"
COMPRESS_SCRIPT="${COMPRESS_SCRIPT:-$REPO_ROOT/compress.sh}"
DECOMPRESS_SCRIPT="${DECOMPRESS_SCRIPT:-$REPO_ROOT/decompress.sh}"

TMP_DIRS=()
cleanup_tmpdirs() {
  for d in "${TMP_DIRS[@]}"; do
    [[ -d "$d" ]] && rm -rf -- "$d"
  done
}

generate_test_file() {
  local path="$1" size_bytes="$2" seed="${3:-CascadeData}"
  python3 "$PYTHON_HELPERS_DIR/generate_test_file.py" "$path" "$size_bytes" "$seed"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

log() {
  printf '\n==> %s\n' "$*"
}

compressed_name_for() {
  local path="$1" compressor="$2"
  case "$compressor" in
    xz)
      if [[ "$path" == *.tar ]]; then
        printf '%s\n' "${path%.tar}.txz"
      else
        printf '%s\n' "${path}.xz"
      fi
      ;;
    zstd)
      if [[ "$path" == *.tar ]]; then
        printf '%s\n' "${path%.tar}.tzst"
      else
        printf '%s\n' "${path}.zst"
      fi
      ;;
    *)
      echo "Unknown compressor: $compressor" >&2
      return 2
      ;;
  esac
}

decompress_with() {
  local compressor="$1" src="$2" dest="$3"
  case "$compressor" in
    xz)
      xz -dc -- "$src" >"$dest"
      ;;
    zstd)
      zstd -dc -q -- "$src" >"$dest"
      ;;
    *)
      echo "Unknown compressor for decompression: $compressor" >&2
      return 2
      ;;
  esac
}

verify_checksum_file() {
  local file="$1"; shift
  [[ -f "$file" ]] || { echo "Checksum file missing: $file" >&2; return 1; }

  declare -A expected seen
  while [[ $# -ge 2 ]]; do
    local path="$1" hash="$2"
    expected["$path"]="$hash"
    shift 2
  done

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    local hash="${line%% *}"
    local path="${line#*  }"
    path="${path#"${path%%[! ]*}"}"
    [[ -z "$path" ]] && continue
    if [[ -n "${expected[$path]:-}" ]]; then
      if [[ "$hash" != "${expected[$path]}" ]]; then
        echo "Checksum mismatch for $path in $file" >&2
        echo " expected: ${expected[$path]}" >&2
        echo " actual  : $hash" >&2
        return 1
      fi
      seen["$path"]=1
    fi
  done <"$file"

  for path in "${!expected[@]}"; do
    if [[ -z "${seen[$path]:-}" ]]; then
      echo "Missing checksum entry for $path in $file" >&2
      return 1
    fi
  done
}
