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
      local rest="${BASH_REMATCH[2]}"
      local path="$rest"
      local size=""
      if [[ "$rest" =~ ^(.*[^[:space:]])[[:space:]][[:space:]]+([0-9]+)$ ]]; then
        path="${BASH_REMATCH[1]}"
        size="${BASH_REMATCH[2]}"
      fi
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

# Standard test fixture configurations
declare -A BASIC_FIXTURE=(
  ["paths"]="alpha.txt|sub dir/bravo.bin|spaces/charlie data.csv"
  ["sizes"]="512|1024|2048"
)

declare -A UNICODE_FIXTURE=(
  ["paths"]="alpha.txt|unicode set ♫/資料セット №1/emoji_файл 😀.txt"
  ["sizes"]="1024|4096"
)

declare -A COMPRESSION_FIXTURE=(
  ["paths"]="small.txt|sub dir/medium file.txt|big data/bigfile.sql|special chars/über@Data!.txt"
  ["sizes"]="512|1536|65536|98304"
)

declare -A LARGE_FIXTURE=(
  ["paths"]="file1.txt|subdir/file2.bin|bigdata/archive.sql"
  ["sizes"]="256|768|131072"
)

# Convert pipe-separated string to array (handles spaces in paths)
_to_array() {
  local string="$1"
  local -n array_ref="$2"
  IFS='|' read -ra array_ref <<<"$string"
}

# Create standard test fixture and return hash mapping
create_standard_fixture() {
  local base_dir="$1" fixture_type="$2" seed_prefix="$3"
  local -n fixture_ref="${fixture_type}_FIXTURE"

  local paths_string="${fixture_ref[paths]}"
  local sizes_string="${fixture_ref[sizes]}"

  local -a paths sizes
  _to_array "$paths_string" paths
  _to_array "$sizes_string" sizes

  if ((${#paths[@]} != ${#sizes[@]})); then
    echo "Fixture $fixture_type has mismatched paths and sizes" >&2
    return 1
  fi

  declare -A hashes
  for idx in "${!paths[@]}"; do
    local path="${paths[$idx]}"
    local size="${sizes[$idx]}"
    local full_path="$base_dir/$path"
    mkdir -p -- "$(dirname -- "$full_path")"
    generate_test_file "$full_path" "$size" "$seed_prefix $idx"
    hashes["$path"]="$(sha256sum -- "$full_path" | awk '{print $1}')"
  done

  # Output hash mapping for caller to capture
  for path in "${!hashes[@]}"; do
    printf '%s=%s\n' "$path" "${hashes[$path]}"
  done
}

# Command group requirements
require_basic_commands() {
  require_cmd python3
  require_cmd sha256sum
}

require_archive_commands() {
  require_cmd tar
  require_cmd 7z
  require_cmd zip
  require_cmd unrar
}

require_compression_commands() {
  require_cmd xz
  require_cmd zstd
}

require_parallel_commands() {
  require_cmd parallel
  require_cmd pzstd
}

# Generic test runner template
run_standard_test() {
  local test_name="$1"
  local test_function="$2"
  shift 2

  log "Running ${test_name}"
  run_test_with_tmpdir "$test_function" "$@"
}

# A/B testing framework
run_ab_test() {
  local old_function="$1" new_function="$2" test_name="$3"
  shift 3

  log "Running A/B test for ${test_name}"

  local old_result new_result
  local old_tmpdir new_tmpdir

  old_tmpdir="$(mktemp -d)"
  new_tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$old_tmpdir" "$new_tmpdir")

  # Run old implementation
  if "$old_function" "$old_tmpdir" "$@"; then
    old_result="PASS"
  else
    old_result="FAIL"
  fi

  # Run new implementation
  if "$new_function" "$new_tmpdir" "$@"; then
    new_result="PASS"
  else
    new_result="FAIL"
  fi

  printf 'A/B Test Results for %s:\n' "$test_name"
  printf '  Old implementation: %s\n' "$old_result"
  printf '  New implementation: %s\n' "$new_result"

  if [[ "$old_result" == "$new_result" ]]; then
    printf '  ✓ Results match\n'
    return 0
  else
    printf '  ✗ Results differ - investigation needed\n'
    return 1
  fi
}
