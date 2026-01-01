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
require_cmd tar
require_cmd 7z
require_cmd zip
require_cmd unzip

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

ensure_zeekstd() {
  if command -v zeekstd >/dev/null 2>&1; then
    ZEEKSTD_BIN_PATH="$(command -v zeekstd)"
    return 0
  fi

  if [[ -x "${HOME}/.cargo/bin/zeekstd" ]]; then
    ZEEKSTD_BIN_PATH="${HOME}/.cargo/bin/zeekstd"
    return 0
  fi

  echo "Missing zeekstd binary. Please run ./install-zeekstd.sh first." >&2
  exit 1
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

run_single_decompress_test() {
  local remove_flag="$1" label="$2"
  log "Running decompress.sh test (${label})"

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

  declare -A expected_paths compressed_paths
  for idx in "${!files[@]}"; do
    local path="${files[$idx]}"
    local compressor="${compressors[$idx]}"
    mkdir -p -- "$(dirname -- "$path")"
    generate_test_file "$path" "${sizes[$idx]}" "Decompression payload $idx (${label})"
    expected_paths["$path"]="${path}.expected"
    cp -- "$path" "${expected_paths[$path]}"

    local compressed
    compressed="$(compressed_name_for "$path" "$compressor")"
    case "$compressor" in
      xz) xz -c -- "$path" >"$compressed" ;;
      zstd) zstd -q -c -- "$path" >"$compressed" ;;
    esac
    compressed_paths["$path"]="$compressed"
    rm -f -- "$path"
  done

  local args=(--dir "$tmpdir")
  if [[ "$remove_flag" == "true" ]]; then
    args+=(--remove-compressed)
  fi
  "$DECOMPRESS_SCRIPT" "${args[@]}" >/dev/null

  for path in "${files[@]}"; do
    if [[ ! -f "$path" ]]; then
      echo "decompress.sh did not recreate original file: $path (${label})" >&2
      return 1
    fi
    if ! cmp -s "${expected_paths[$path]}" "$path"; then
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

run_decompress_test() {
  run_single_decompress_test false "keep-compressed"
  run_single_decompress_test true "remove-compressed"
}

run_analyze_archive_case() {
  local archive_type="$1"
  log "Running analyze-archive.sh test (${archive_type})"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local input_dir="$tmpdir/input"
  local archive
  local expected_log=""
  mkdir -p "$input_dir"

  local rel_paths=(
    "alpha.txt"
    "sub dir/bravo.bin"
    "spaces/charlie data.csv"
  )
  local sizes=(
    1024
    2048
    512
  )

  declare -A expected_hashes
  for idx in "${!rel_paths[@]}"; do
    local rel="${rel_paths[$idx]}"
    local abs="$input_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" "${sizes[$idx]}" "Analyze archive payload $idx (${archive_type})"
    expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  case "$archive_type" in
    tar)
      archive="$tmpdir/sample.tar"
      tar -C "$input_dir" -cf "$archive" "${rel_paths[@]}"
      expected_log="Using optimized tar processing"
      ;;
    7z)
      archive="$tmpdir/sample.7z"
      (
        cd "$input_dir"
        7z a -bd -y "$archive" "${rel_paths[@]}" >/dev/null
      )
      expected_log=""
      ;;
    zip)
      archive="$tmpdir/sample.zip"
      (
        cd "$input_dir"
        zip -q "$archive" "${rel_paths[@]}"
      )
      expected_log=""
      ;;
    *)
      echo "Unknown archive type for analyze-archive test: $archive_type" >&2
      return 1
      ;;
  esac

  local output
  if ! output="$("$REPO_ROOT/analyze-archive.sh" "$archive" 2>&1)"; then
    echo "analyze-archive.sh failed during manifest generation (${archive_type})" >&2
    echo "$output" >&2
    return 1
  fi

  local manifest="$tmpdir/sample.sha256"
  if [[ ! -f "$manifest" ]]; then
    echo "Manifest not created at expected path (${archive_type}): $manifest" >&2
    return 1
  fi

  if [[ -n "$expected_log" && "$output" != *"$expected_log"* ]]; then
    echo "analyze-archive.sh did not use optimized ${archive_type} processing path" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"Processed ${#rel_paths[@]} file(s)."* ]]; then
    echo "analyze-archive.sh reported unexpected processed count (${archive_type})" >&2
    echo "$output" >&2
    return 1
  fi

  local previous_path=""
  declare -A seen_paths=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    local hash="${line%%  *}"
    local path="${line#*  }"
    local normalized="${path#./}"

    if [[ -n "$previous_path" && "$path" < "$previous_path" ]]; then
      echo "Manifest entries are not sorted lexicographically (${archive_type})" >&2
      return 1
    fi
    previous_path="$path"

    if [[ -z "${expected_hashes[$normalized]:-}" ]]; then
      echo "Unexpected entry found in manifest (${archive_type}): $path" >&2
      return 1
    fi

    if [[ "${expected_hashes[$normalized]}" != "$hash" ]]; then
      echo "Hash mismatch for $path (${archive_type})" >&2
      echo " expected: ${expected_hashes[$normalized]}" >&2
      echo " actual  : $hash" >&2
      return 1
    fi

    seen_paths["$normalized"]=1
  done <"$manifest"

  for rel in "${!expected_hashes[@]}"; do
    if [[ -z "${seen_paths[$rel]:-}" ]]; then
      echo "Missing manifest entry for $rel (${archive_type})" >&2
      return 1
    fi
  done

  local manifest_backup="$tmpdir/sample.sha256.expected"
  cp -- "$manifest" "$manifest_backup"

  printf 'out-of-date manifest\n' >"$manifest"
  local skip_output
  if ! skip_output="$("$REPO_ROOT/analyze-archive.sh" "$archive" 2>&1)"; then
    echo "analyze-archive.sh failed when manifest already existed (${archive_type})" >&2
    echo "$skip_output" >&2
    return 1
  fi

  if [[ "$skip_output" != *"skip (manifest exists): $manifest"* ]]; then
    echo "analyze-archive.sh did not report skip when manifest existed (${archive_type})" >&2
    echo "$skip_output" >&2
    return 1
  fi

  if [[ "$(cat "$manifest")" != "out-of-date manifest" ]]; then
    echo "Manifest was unexpectedly rewritten without --overwrite (${archive_type})" >&2
    return 1
  fi

  if ! "$REPO_ROOT/analyze-archive.sh" --overwrite "$archive" >/dev/null 2>&1; then
    echo "analyze-archive.sh failed when invoked with --overwrite (${archive_type})" >&2
    return 1
  fi

  if ! cmp -s "$manifest" "$manifest_backup"; then
    echo "Manifest contents did not refresh after --overwrite run (${archive_type})" >&2
    return 1
  fi
}

run_analyze_archive_test() {
  log "Running analyze-archive.sh test"
  run_analyze_archive_case tar
  run_analyze_archive_case 7z
  run_analyze_archive_case zip
  run_analyze_archive_invalid_cases
}

run_analyze_archive_invalid_cases() {
  log "Running analyze-archive.sh invalid archive tests"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local -a types=("7z" "tar" "zip")

  for archive_type in "${types[@]}"; do
    local invalid expected_msg
    case "$archive_type" in
      7z)
        invalid="$tmpdir/bad.7z"
        expected_msg="Failed to list entries for $invalid"
        ;;
      tar)
        invalid="$tmpdir/bad.tar"
        expected_msg="Failed to list tar entries for $invalid"
        ;;
      zip)
        invalid="$tmpdir/bad.zip"
        expected_msg="Failed to list zip entries for $invalid"
        ;;
      *)
        echo "Unknown invalid archive type: $archive_type" >&2
        return 1
        ;;
    esac

    printf 'invalid archive payload (%s)\n' "$archive_type" >"$invalid"
    local manifest="${invalid%.*}.sha256"
    local output_file="$tmpdir/output-${archive_type}.log"

    if "$REPO_ROOT/analyze-archive.sh" "$invalid" >"$output_file" 2>&1; then
      echo "analyze-archive.sh unexpectedly succeeded on invalid $archive_type archive" >&2
      cat "$output_file" >&2
      return 1
    fi

    local output
    output="$(cat "$output_file")"
    if [[ "$output" != *"$expected_msg"* ]]; then
      echo "Expected failure message missing for invalid $archive_type archive" >&2
      echo "$output" >&2
      return 1
    fi

    if [[ -e "$manifest" ]]; then
      echo "Manifest should not be created when analyze-archive.sh fails ($archive_type)" >&2
      return 1
    fi
  done
}

run_find_duplicate_sha256_test() {
  log "Running find-duplicate-sha256.sh test"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local manifest_dir="$tmpdir/manifests"
  mkdir -p "$manifest_dir"

  local alpha="$manifest_dir/alpha.sha256"
  local bravo="$manifest_dir/bravo.sha256"
  local charlie="$manifest_dir/charlie.sha256"

  local HASH_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local HASH_DUP="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local HASH_INTRA="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  local HASH_UNIQUE="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

  cat >"$alpha" <<EOF
$HASH_A  alpha/path-one.txt
$HASH_DUP  alpha/path-two.bin
$HASH_INTRA  alpha/path-three.bin
$HASH_INTRA  alpha/path-four.bin
EOF

  cat >"$bravo" <<EOF
$HASH_DUP  bravo/shared.bin
$HASH_UNIQUE  bravo/only.txt
EOF

  local output
  if ! output="$("$REPO_ROOT/find-duplicate-sha256.sh" "$manifest_dir" 2>&1)"; then
    echo "find-duplicate-sha256.sh failed (default invocation)" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"Scanned 2 manifest(s); 6 total entries (4 unique hashes). Skipped 0 line(s)."* ]]; then
    echo "Unexpected scan summary for find-duplicate-sha256.sh" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"SHA256 $HASH_DUP (2 occurrences):"* ]]; then
    echo "Cross-manifest duplicate hash was not reported" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"$alpha :: alpha/path-two.bin"* || "$output" != *"$bravo :: bravo/shared.bin"* ]]; then
    echo "Locations for cross-manifest duplicate were missing" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"SHA256 $HASH_INTRA (2 occurrences):"* ]]; then
    echo "Intra-manifest duplicate hash was not reported" >&2
    echo "$output" >&2
    return 1
  fi

  if [[ "$output" != *"$alpha :: alpha/path-three.bin"* || "$output" != *"$alpha :: alpha/path-four.bin"* ]]; then
    echo "Intra-manifest duplicate locations missing from report" >&2
    echo "$output" >&2
    return 1
  fi

  local skip_output
  if ! skip_output="$("$REPO_ROOT/find-duplicate-sha256.sh" --skip-intra-manifest "$manifest_dir" 2>&1)"; then
    echo "find-duplicate-sha256.sh failed with --skip-intra-manifest" >&2
    echo "$skip_output" >&2
    return 1
  fi

  if [[ "$skip_output" == *"$HASH_INTRA"* ]]; then
    echo "Intra-manifest duplicates were not filtered out" >&2
    echo "$skip_output" >&2
    return 1
  fi

  if [[ "$skip_output" != *"SHA256 $HASH_DUP (2 occurrences):"* ]]; then
    echo "Cross-manifest duplicate missing when skipping intra-manifest entries" >&2
    echo "$skip_output" >&2
    return 1
  fi

  if [[ "$skip_output" != *"$alpha :: alpha/path-two.bin"* || "$skip_output" != *"$bravo :: bravo/shared.bin"* ]]; then
    echo "Cross-manifest duplicate locations missing under --skip-intra-manifest" >&2
    echo "$skip_output" >&2
    return 1
  fi

  cp -- "$bravo" "$charlie"
  local identical_output
  if ! identical_output="$("$REPO_ROOT/find-duplicate-sha256.sh" --identical-archives "$manifest_dir" 2>&1)"; then
    echo "find-duplicate-sha256.sh failed with --identical-archives" >&2
    echo "$identical_output" >&2
    return 1
  fi

  if [[ "$identical_output" != *"Scanned 3 manifest(s); 8 total entries (4 unique hashes). Skipped 0 line(s)."* ]]; then
    echo "Unexpected scan summary under --identical-archives" >&2
    echo "$identical_output" >&2
    return 1
  fi

  if [[ "$identical_output" != *"Archives with identical contents (2 entries):"* ]]; then
    echo "Identical archives report missing" >&2
    echo "$identical_output" >&2
    return 1
  fi

  if [[ "$identical_output" != *"$bravo"* || "$identical_output" != *"$charlie"* ]]; then
    echo "Expected identical manifests were not listed together" >&2
    echo "$identical_output" >&2
    return 1
  fi

  local redundant_archive="${charlie%.sha256}"
  cp -- "$bravo" "$charlie"
  : >"$redundant_archive"
  local delete_output
  if ! delete_output="$("$REPO_ROOT/find-duplicate-sha256.sh" \
      --identical-archives \
      --delete-identical \
      --yes \
      "$manifest_dir" 2>&1)"; then
    echo "find-duplicate-sha256.sh failed with deletion flags" >&2
    echo "$delete_output" >&2
    return 1
  fi

  if [[ "$delete_output" != *"Deletion pass complete."* ]]; then
    echo "Deletion summary missing from --delete-identical run" >&2
    echo "$delete_output" >&2
    return 1
  fi

  if [[ -e "$charlie" || -e "$redundant_archive" ]]; then
    echo "Redundant manifest/archive not removed under --delete-identical" >&2
    return 1
  fi
}

run_convert_7z_to_tarzst_test() {
  log "Running convert-7z-to-tarzst.sh test"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local input_dir="$tmpdir/input"
  mkdir -p "$input_dir"

  local rel_paths=(
    "alpha.txt"
    "nested/bravo.bin"
    "spaces/charlie data.csv"
  )
  local sizes=(
    128
    512
    1024
  )

  declare -A expected_hashes
  for idx in "${!rel_paths[@]}"; do
    local rel="${rel_paths[$idx]}"
    local abs="$input_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" "${sizes[$idx]}" "Convert 7z payload $idx"
    expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  local archive="$tmpdir/sample.7z"
  (
    cd "$input_dir"
    7z a -bd -y "$archive" "${rel_paths[@]}" >/dev/null
  )

  ensure_zeekstd

  local output_tar_zst="$tmpdir/output.tar.zst"
  local manifest="$tmpdir/output.sha256"

  local convert_script="$REPO_ROOT/convert-7z-to-tarzst.sh"
  if ! ZEEKSTD_BIN="$ZEEKSTD_BIN_PATH" "$convert_script" \
      --output "$output_tar_zst" \
      --sha256-file "$manifest" \
      --remove-source \
      "$archive" >/dev/null; then
    echo "convert-7z-to-tarzst.sh failed to convert sample archive" >&2
    return 1
  fi

  if [[ -e "$archive" ]]; then
    echo "Source archive was not removed despite --remove-source" >&2
    return 1
  fi

  if [[ ! -f "$output_tar_zst" ]]; then
    echo "Output tar.zst not created" >&2
    return 1
  fi

  if [[ ! -f "$manifest" ]]; then
    echo "SHA-256 manifest not created" >&2
    return 1
  fi

  local verify_args=()
  for rel in "${rel_paths[@]}"; do
    verify_args+=("$rel" "${expected_hashes[$rel]}")
  done
  verify_checksum_file "$manifest" "${verify_args[@]}"

  local reconstructed_tar="$tmpdir/output.tar"
  zstd -d -q -c -- "$output_tar_zst" >"$reconstructed_tar"

  local extract_dir="$tmpdir/extracted"
  mkdir -p "$extract_dir"
  tar -C "$extract_dir" -xf "$reconstructed_tar"

  for rel in "${rel_paths[@]}"; do
    local original="$input_dir/$rel"
    local restored="$extract_dir/$rel"
    if [[ ! -f "$restored" ]]; then
      echo "Missing file in reconstructed tar: $rel" >&2
      return 1
    fi
    if ! cmp -s "$original" "$restored"; then
      echo "Restored file mismatch for $rel" >&2
      return 1
    fi
  done
}

main() {
  local tests=(
    "run_compress_test::Compression pipelines"
    "run_decompress_test::Decompression pipelines"
    "run_analyze_archive_test::Archive analyzer"
    "run_find_duplicate_sha256_test::Duplicate detector"
    "run_convert_7z_to_tarzst_test::7z ➜ seekable tar.zst converter"
  )

  printf 'Test plan (%d total):\n' "${#tests[@]}"
  for idx in "${!tests[@]}"; do
    local entry="${tests[$idx]}"
    local fn="${entry%%::*}"
    local label="${entry#*::}"
    printf '  [%d/%d] %s -> %s\n' "$((idx + 1))" "${#tests[@]}" "$fn" "$label"
  done

  for idx in "${!tests[@]}"; do
    local entry="${tests[$idx]}"
    local fn="${entry%%::*}"
    local label="${entry#*::}"
    local seq=$((idx + 1))
    log "[${seq}/${#tests[@]}] $label"
    "$fn"
  done

  log "All tests passed"
}

main "$@"
