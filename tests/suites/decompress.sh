#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

require_cmd python3
require_cmd xz
require_cmd zstd

run_single_decompress_test() {
  local remove_flag="$1" label="$2"
  log "Running decompress.sh test (${label})"

  run_test_with_tmpdir _run_single_decompress_test "$remove_flag" "$label"
}

_run_single_decompress_test() {
  local tmpdir="$1"
  local remove_flag="$2"
  local label="$3"

  local files=(
    "source.txt"
    "nested folder/bravo.sql"
    "special chars/Ωmega (final).txt"
  )
  local sizes=(
    $((96 * 1024))
    $((48 * 1024))
    $((32 * 1024))
  )
  local compressors=(
    xz
    zstd
    zstd
  )

  declare -A expected_paths compressed_paths
  for idx in "${!files[@]}"; do
    local path="${files[$idx]}"
    local compressor="${compressors[$idx]}"
    local full_path="$tmpdir/$path"
    mkdir -p -- "$(dirname -- "$full_path")"
    generate_test_file "$full_path" "${sizes[$idx]}" "Decompression payload $idx (${label})"
    expected_paths["$path"]="${full_path}.expected"
    cp -- "$full_path" "${expected_paths[$path]}"

    local compressed
    compressed="$(compressed_name_for "$full_path" "$compressor")"
    case "$compressor" in
      xz) xz -c -- "$full_path" >"$compressed" ;;
      zstd) zstd -q -c -- "$full_path" >"$compressed" ;;
    esac
    compressed_paths["$path"]="$compressed"
    rm -f -- "$full_path"
  done

  local args=(--dir "$tmpdir")
  if [[ "$remove_flag" == "true" ]]; then
    args+=(--remove-compressed)
  fi
  "$DECOMPRESS_SCRIPT" "${args[@]}" >/dev/null

  for path in "${files[@]}"; do
    local restored="$tmpdir/$path"
    if [[ ! -f "$restored" ]]; then
      echo "decompress.sh did not recreate original file: $path (${label})" >&2
      return 1
    fi
    if ! cmp -s "${expected_paths[$path]}" "$restored"; then
      echo "Decompressed contents differ for $path (${label})" >&2
      return 1
    fi

    local compressed="${compressed_paths[$path]}"
    if [[ "$remove_flag" == "true" ]]; then
      if [[ -e "$compressed" ]]; then
        echo "Compressed file was not removed (${label}): $compressed" >&2
        return 1
      fi
    else
      if [[ ! -e "$compressed" ]]; then
        echo "Compressed file unexpectedly removed (${label}): $compressed" >&2
        return 1
      fi
    fi
  done
}

run_decompress_suite() {
  run_single_decompress_test false "keep-compressed"
  run_single_decompress_test true "remove-compressed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_decompress_suite "$@"
fi
