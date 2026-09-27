#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

# Use new command group requirements
require_parallel_commands
require_compression_commands
require_basic_commands
require_cmd sha1sum

run_single_compress_test() {
  local small_comp="$1" big_comp="$2" label="$3" big_jobs="${4:-1}"
  run_standard_test "compress.sh test (${label})" _run_single_compress_test "$small_comp" "$big_comp" "$label" "$big_jobs"
}

_run_single_compress_test() {
  local tmpdir="$1"
  local small_comp="$2"
  local big_comp="$3"
  local label="$4"
  local big_jobs="$5"
  local threshold_bytes=$((2 * 1024))
  local sha1_file="$tmpdir/checksums.sha1"
  local sha256_file="$tmpdir/checksums.sha256"

  # Use standard fixture - this is the main refactoring benefit
  local hash_output
  hash_output="$(create_standard_fixture "$tmpdir" "COMPRESSION" "Compression fixture ($label)")"

  # Parse hash output and create test data
  local -a fixture_paths
  local -A expected_paths sha1_map sha256_map source_paths size_map

  # Define sizes for COMPRESSION fixture
  declare -A compression_sizes=(
    ["small.txt"]=512
    ["sub dir/medium file.txt"]=1536
    ["big data/bigfile.sql"]=65536
    ["special chars/über@Data!.txt"]=98304
  )

  while IFS='=' read -r path hash; do
    fixture_paths+=("$path")
    expected_paths["$path"]="$tmpdir/${path}.expected"
    source_paths["$path"]="$tmpdir/$path"
    size_map["$path"]="${compression_sizes[$path]}"
    sha1_map["$path"]="$(sha1sum -- "$tmpdir/$path" | awk '{print $1}')"
    sha256_map["$path"]="$(sha256sum -- "$tmpdir/$path" | awk '{print $1}')"
    cp -- "$tmpdir/$path" "${expected_paths[$path]}"
  done <<<"$hash_output"

  local output
  if ! output="$("$COMPRESS_SCRIPT" \
      --dir "$tmpdir" \
      --jobs 2 \
      --small "$small_comp" \
      --big "$big_comp" \
      --big-jobs "$big_jobs" \
      --threshold "$threshold_bytes" \
      --sha1 "$sha1_file" \
      --sha256 "$sha256_file" 2>&1)"; then
    echo "compress.sh failed (${label})" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"big(${big_comp})"* ]]; then
    echo "Expected big-file compression path (${big_comp}) to run" >&2
    echo "$output" >&2
    return 1
  fi

  local sha1_args=()
  local sha256_args=()

  for path in "${fixture_paths[@]}"; do
    local original_path="${source_paths[$path]}"
    if [[ -f "$original_path" ]]; then
      echo "Expected original file to be removed after compression: $path" >&2
      return 1
    fi

    local size="${size_map[$path]}"
    local compressor="$small_comp"
    if [[ "$size" -ge "$threshold_bytes" ]]; then
      compressor="$big_comp"
    fi

    local compressed_rel
    compressed_rel="$(compressed_name_for "$path" "$compressor")"
    local compressed="$tmpdir/$compressed_rel"

    if [[ ! -f "$compressed" ]]; then
      echo "Compressed file not created: $compressed" >&2
      return 1
    fi

    local decompressed="$tmpdir/${path}.dec"
    decompress_with "$compressor" "$compressed" "$decompressed"
    if ! cmp -s "${expected_paths[$path]}" "$decompressed"; then
      echo "Compressed file contents mismatch for $path (${compressor})" >&2
      return 1
    fi

    sha1_args+=("${source_paths[$path]}" "${sha1_map[$path]}")
    sha256_args+=("${source_paths[$path]}" "${sha256_map[$path]}")
  done

  verify_checksum_file "$sha1_file" "${sha1_args[@]}"
  verify_checksum_file "$sha256_file" "${sha256_args[@]}"
}

run_big_no_checksum_test() {
  run_standard_test "compress.sh big path without checksums exits 0" _run_big_no_checksum_test
}

# Regression: compress_big_seq must return 0 after successful compression
# even when no checksum lines were emitted (bare && chain used to end
# the function with status 1).
_run_big_no_checksum_test() {
  local tmpdir="$1"
  generate_test_file "$tmpdir/big.sql" 4096 "big-no-checksum"

  local output
  if ! output="$("$COMPRESS_SCRIPT" --dir "$tmpdir" --big xz --threshold 2048 -q </dev/null 2>&1)"; then
    echo "compress.sh failed without checksum options" >&2
    echo "$output" >&2
    return 1
  fi
  [[ -f "$tmpdir/big.sql.xz" ]] || {
    echo "Expected big.sql.xz output" >&2
    return 1
  }
}

run_checksum_self_exclusion_test() {
  run_standard_test "compress.sh excludes its own checksum output" _run_checksum_self_exclusion_test
}

# Regression: a checksum file inside the scan dir must not be picked up as
# input (it used to be compressed, deleted, then recreated containing an
# empty-file hash for itself).
_run_checksum_self_exclusion_test() {
  local tmpdir="$1"
  local sha256_file="$tmpdir/checksums.txt"

  echo x >"$tmpdir/a.txt"
  echo y >"$tmpdir/b.txt"
  : >"$sha256_file"

  local output
  if ! output="$("$COMPRESS_SCRIPT" --dir "$tmpdir" --ext txt --sha256 "$sha256_file" -q </dev/null 2>&1)"; then
    echo "compress.sh failed" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ -e "$tmpdir/checksums.txt.xz" ]]; then
    echo "Checksum output file was itself compressed" >&2
    return 1
  fi
  [[ -f "$sha256_file" ]] || {
    echo "Checksum output file missing: $sha256_file" >&2
    return 1
  }
  if grep -q 'checksums\.txt' "$sha256_file"; then
    echo "Checksum file must not contain an entry for itself" >&2
    return 1
  fi
  grep -q 'a\.txt' "$sha256_file" || {
    echo "Missing entry for a.txt in $sha256_file" >&2
    cat "$sha256_file" >&2
    return 1
  }
}

run_unreadable_source_test() {
  run_standard_test "compress.sh fails loudly on unreadable input" _run_unreadable_source_test
}

# Regression: job shells under `parallel` run without pipefail/errexit, so a
# failed pv used to produce a valid-looking empty archive and delete the
# source. The job must now fail and leave the source untouched.
_run_unreadable_source_test() {
  local tmpdir="$1"
  generate_test_file "$tmpdir/big.sql" 4096 "unreadable-source"
  chmod 000 "$tmpdir/big.sql"

  local output rc=0
  output="$("$COMPRESS_SCRIPT" --dir "$tmpdir" --ext sql --threshold 1024 --big pzstd -q </dev/null 2>&1)" || rc=$?

  chmod 644 "$tmpdir/big.sql"
  if [[ "$rc" -eq 0 ]]; then
    echo "compress.sh succeeded on unreadable input" >&2
    echo "$output" >&2
    return 1
  fi
  if [[ ! -f "$tmpdir/big.sql" ]]; then
    echo "Source file was deleted despite failed compression" >&2
    return 1
  fi
  if [[ -e "$tmpdir/big.sql.zst" ]]; then
    echo "Partial/garbage compressed output was left behind" >&2
    return 1
  fi
}

run_compress_suite() {
  run_single_compress_test xz xz "xz-only"
  run_single_compress_test zstd zstd "zstd-only"
  run_single_compress_test zstd zstd "zstd-big-parallel" 2
  run_big_no_checksum_test
  run_checksum_self_exclusion_test
  run_unreadable_source_test
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_compress_suite "$@"
fi
