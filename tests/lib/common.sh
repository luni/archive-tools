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
    if [[ "$line" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})[[:space:]][[:space:]]+(.+)$ ]]; then
      local hash="${BASH_REMATCH[1]}"
      local path="${BASH_REMATCH[2]}"
      if [[ -n "${expected[$path]:-}" ]]; then
        if [[ "$hash" != "${expected[$path]}" ]]; then
          echo "Checksum mismatch for $path in $file" >&2
          echo " expected: ${expected[$path]}" >&2
          echo " actual  : $hash" >&2
          return 1
        fi
        seen["$path"]=1
      fi
    fi
  done <"$file"

  for path in "${!expected[@]}"; do
    if [[ -z "${seen[$path]:-}" ]]; then
      echo "Missing checksum entry for $path in $file" >&2
      return 1
    fi
  done
}

create_test_fixture() {
  local base_dir="$1"
  local -n paths_ref="$2"
  local -n sizes_ref="$3"
  local seed_prefix="$4"

  declare -A hashes
  for idx in "${!paths_ref[@]}"; do
    local path="${paths_ref[$idx]}"
    local size="${sizes_ref[$idx]}"
    local full_path="$base_dir/$path"
    mkdir -p -- "$(dirname -- "$full_path")"
    generate_test_file "$full_path" "$size" "$seed_prefix $idx"
    hashes["$path"]="$(sha256sum -- "$full_path" | awk '{print $1}')"
  done

  for path in "${!hashes[@]}"; do
    printf '%s\n' "${hashes[$path]}"
  done
}

verify_extracted_files() {
  local original_dir="$1"
  local extracted_dir="$2"
  shift 2
  local rel_paths=("$@")

  for rel in "${rel_paths[@]}"; do
    local original="$original_dir/$rel"
    local restored="$extracted_dir/$rel"
    if [[ ! -f "$restored" ]]; then
      echo "Missing file in extracted archive: $rel" >&2
      return 1
    fi
    if ! cmp -s "$original" "$restored"; then
      echo "File mismatch for $rel" >&2
      return 1
    fi
  done
}

extract_and_verify_tarzst() {
  local tarzst_file="$1"
  local original_dir="$2"
  local tmpdir="$3"
  shift 3
  local rel_paths=("$@")

  local reconstructed_tar="$tmpdir/reconstructed.tar"
  zstd -d -q -c -- "$tarzst_file" >"$reconstructed_tar"

  local extract_dir="$tmpdir/extracted"
  mkdir -p "$extract_dir"
  tar -C "$extract_dir" -xf "$reconstructed_tar"

  verify_extracted_files "$original_dir" "$extract_dir" "${rel_paths[@]}"
}

run_test_with_tmpdir() {
  local test_function="$1"
  shift

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  "$test_function" "$tmpdir" "$@"
}
