#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPRESS_SCRIPT="$REPO_ROOT/compress.sh"
DECOMPRESS_SCRIPT="$REPO_ROOT/decompress.sh"

generate_test_file() {
  local path="$1" size_bytes="$2" seed="${3:-CascadeData}"
  python3 - "$path" "$size_bytes" "$seed" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
size = int(sys.argv[2])
seed = (sys.argv[3] + "\n").encode("utf-8")

with path.open("wb") as fh:
    written = 0
    while written < size:
        to_write = seed
        remaining = size - written
        if len(to_write) > remaining:
            to_write = seed[:remaining]
        fh.write(to_write)
        written += len(to_write)
PY
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

require_cmd parallel
require_cmd xz
require_cmd python3
require_cmd zstd
require_cmd sha1sum
require_cmd sha256sum

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
    # shaXsum outputs: "<hash>  <path>"
    local hash path
    hash="${line%% *}"
    path="${line#*  }"
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

TMP_DIRS=()
cleanup_tmpdirs() {
  for d in "${TMP_DIRS[@]}"; do
    [[ -d "$d" ]] && rm -rf -- "$d"
  done
}
trap cleanup_tmpdirs EXIT

run_single_compress_test() {
  local small_comp="$1" big_comp="$2" label="$3"
  log "Running compress.sh test (${label})"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local threshold_bytes=$((2 * 1024))
  local sha1_file="$tmpdir/checksums.sha1"
  local sha256_file="$tmpdir/checksums.sha256"

  local fixture_paths=(
    "$tmpdir/small.txt"
    "$tmpdir/sub dir/medium file.txt"
    "$tmpdir/big data/bigfile.sql"
    "$tmpdir/special chars/über@Data!.txt"
  )
  local fixture_sizes=(
    512
    1536
    $((64 * 1024))
    $((96 * 1024))
  )

  declare -A expected_paths sha1_map sha256_map size_map
  for idx in "${!fixture_paths[@]}"; do
    local path="${fixture_paths[$idx]}"
    local size="${fixture_sizes[$idx]}"
    mkdir -p -- "$(dirname -- "$path")"
    generate_test_file "$path" "$size" "Compression fixture $idx ($label)"
    expected_paths["$path"]="${path}.expected"
    size_map["$path"]="$size"
    cp -- "$path" "${expected_paths[$path]}"
    sha1_map["$path"]="$(sha1sum -- "$path" | awk '{print $1}')"
    sha256_map["$path"]="$(sha256sum -- "$path" | awk '{print $1}')"
  done

  local output
  if ! output="$("$COMPRESS_SCRIPT" \
      --dir "$tmpdir" \
      --jobs 2 \
      --small "$small_comp" \
      --big "$big_comp" \
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
    if [[ -f "$path" ]]; then
      echo "Expected original file to be removed after compression: $path" >&2
      return 1
    fi

    local size="${size_map[$path]}"
    local compressor="$small_comp"
    if [[ "$size" -ge "$threshold_bytes" ]]; then
      compressor="$big_comp"
    fi

    local compressed
    compressed="$(compressed_name_for "$path" "$compressor")"

    if [[ ! -f "$compressed" ]]; then
      echo "Compressed file not created: $compressed" >&2
      return 1
    fi

    local decompressed="${path}.dec"
    decompress_with "$compressor" "$compressed" "$decompressed"
    if ! cmp -s "${expected_paths[$path]}" "$decompressed"; then
      echo "Compressed file contents mismatch for $path (${compressor})" >&2
      return 1
    fi

    sha1_args+=("$path" "${sha1_map[$path]}")
    sha256_args+=("$path" "${sha256_map[$path]}")
  done

  verify_checksum_file "$sha1_file" "${sha1_args[@]}"
  verify_checksum_file "$sha256_file" "${sha256_args[@]}"
}

run_compress_test() {
  run_single_compress_test xz xz "xz-only"
  run_single_compress_test zstd zstd "zstd-only"
}

run_decompress_test() {
  log "Running decompress.sh test"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local files=(
    "$tmpdir/source.txt"
    "$tmpdir/nested folder/bravo.sql"
    "$tmpdir/special chars/Ωmega (final).txt"
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

  declare -A expected_paths
  for idx in "${!files[@]}"; do
    local path="${files[$idx]}"
    local compressor="${compressors[$idx]}"
    mkdir -p -- "$(dirname -- "$path")"
    generate_test_file "$path" "${sizes[$idx]}" "Decompression payload $idx"
    expected_paths["$path"]="${path}.expected"
    cp -- "$path" "${expected_paths[$path]}"

    local compressed
    compressed="$(compressed_name_for "$path" "$compressor")"
    case "$compressor" in
      xz) xz -c -- "$path" >"$compressed" ;;
      zstd) zstd -q -c -- "$path" >"$compressed" ;;
    esac
    rm -f -- "$path"
  done

  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null

  for path in "${files[@]}"; do
    if [[ ! -f "$path" ]]; then
      echo "decompress.sh did not recreate original file: $path" >&2
      return 1
    fi
    if ! cmp -s "${expected_paths[$path]}" "$path"; then
      echo "Decompressed contents differ for $path" >&2
      return 1
    fi
  done
}

main() {
  run_compress_test
  run_decompress_test
  log "All tests passed"
}

main "$@"
