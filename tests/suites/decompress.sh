#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

require_cmd python3
require_cmd xz
require_cmd zstd
require_cmd 7z

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

run_error_handling_test() {
  log "Running decompress.sh error handling test"
  run_test_with_tmpdir _run_error_handling_test
}

_run_error_handling_test() {
  local tmpdir="$1"

  # Create a valid compressed file
  local valid_file="$tmpdir/valid.txt"
  generate_test_file "$valid_file" 1024 "valid content"
  xz -c -- "$valid_file" >"$valid_file.xz"
  rm -f -- "$valid_file"

  # Create a corrupted compressed file
  local corrupt_file="$tmpdir/corrupt.txt"
  echo "this is not valid xz data" >"$corrupt_file.xz"

  # Run decompress script - should continue despite corruption
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1

  # Valid file should be decompressed
  if [[ ! -f "$valid_file" ]]; then
    echo "Valid file was not decompressed due to error handling" >&2
    return 1
  fi

  # Corrupted file should not be decompressed (no .txt file created)
  if [[ -f "$corrupt_file" ]]; then
    echo "Corrupted file was unexpectedly processed" >&2
    return 1
  fi
}

run_comprehensive_magic_detection_test() {
  log "Running comprehensive magic format detection test"
  run_test_with_tmpdir _run_comprehensive_magic_detection_test
}

_run_comprehensive_magic_detection_test() {
  local tmpdir="$1"

  # Test data
  local test_content="magic detection test content $(date)"

  # Test all compression format misnaming scenarios
  local test_scenarios=(
    "tar:gz:tar"
    "tar:xz:tar"
    "tar:bz2:tar"
    "tar:zst:tar"
    "tar:zip:tar"
    "tar:rar:tar"
    "tar:7z:tar"
    "gz:bz2:gz"
    "xz:gz:xz"
    "bz2:xz:bz2"
    "zst:bz2:zst"
    "zip:gz:zip"
    "zip:xz:zip"
    "rar:gz:rar"
    "7z:bz2:7z"
  )

  for scenario in "${test_scenarios[@]}"; do
    IFS=':' read -r actual_format wrong_ext correct_ext <<< "$scenario"

    # Create test file with actual format
    local original_file
    case "$actual_format" in
      tar)
        mkdir -p "$tmpdir/content_$actual_format"
        echo "$test_content" >"$tmpdir/content_$actual_format/file.txt"
        tar -C "$tmpdir" -cf "$tmpdir/test_$actual_format.tar" "content_$actual_format/"
        rm -rf "$tmpdir/content_$actual_format"
        original_file="$tmpdir/test_$actual_format.tar"
        ;;
      gz|xz|bz2|zst)
        echo "$test_content" >"$tmpdir/test_$actual_format.txt"
        case "$actual_format" in
          gz) gzip -c "$tmpdir/test_$actual_format.txt" >"$tmpdir/test_$actual_format.$actual_format" ;;
          xz) xz -c "$tmpdir/test_$actual_format.txt" >"$tmpdir/test_$actual_format.$actual_format" ;;
          bz2) bzip2 -c "$tmpdir/test_$actual_format.txt" >"$tmpdir/test_$actual_format.$actual_format" ;;
          zst) zstd -c "$tmpdir/test_$actual_format.txt" >"$tmpdir/test_$actual_format.$actual_format" ;;
        esac
        rm -f "$tmpdir/test_$actual_format.txt"
        original_file="$tmpdir/test_$actual_format.$actual_format"
        ;;
      zip)
        local zip_input="$tmpdir/test_${actual_format}_content.txt"
        echo "$test_content" >"$zip_input"
        python3 - "$tmpdir/test_$actual_format.zip" "$zip_input" <<'PY'
import sys, zipfile
zip_path, input_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, 'w') as zf:
    zf.write(input_path, arcname='file.txt')
PY
        rm -f "$zip_input"
        original_file="$tmpdir/test_$actual_format.zip"
        ;;
      7z)
        local seven_input="$tmpdir/test_${actual_format}_content.txt"
        echo "$test_content" >"$seven_input"
        7z a -bd -y "$tmpdir/test_$actual_format.7z" "$seven_input" >/dev/null
        rm -f "$seven_input"
        original_file="$tmpdir/test_$actual_format.7z"
        ;;
      rar)
        original_file="$tmpdir/test_$actual_format.rar"
        printf 'Rar!\x1A\x07\x00\x00\x00\x00\x00' >"$original_file"
        ;;
    esac

    # Rename to wrong extension
    local misnamed_file="$tmpdir/test_$actual_format.$wrong_ext"
    mv "$original_file" "$misnamed_file"

    # Run decompress script
    "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1

    # Verify renaming happened correctly
    local expected_file="$tmpdir/test_$actual_format.$correct_ext"
    if [[ "$actual_format" == "tar" ]]; then
      expected_file="$tmpdir/test_$actual_format.tar"
    fi

    if [[ ! -f "$expected_file" ]]; then
      echo "Magic detection failed: $actual_format misnamed as $wrong_ext should be renamed to $correct_ext" >&2
      echo "Expected file: $expected_file not found" >&2
      return 1
    fi

    if [[ -f "$misnamed_file" ]]; then
      echo "Original misnamed file still exists: $misnamed_file" >&2
      return 1
    fi

    # Clean up for next iteration
    rm -f "$expected_file"
  done
}

run_all_compressors_error_test() {
  log "Running error handling test for all compressors"
  run_test_with_tmpdir _run_all_compressors_error_test
}

_run_all_compressors_error_test() {
  local tmpdir="$1"

  # Test error handling for each supported compressor
  local compressors=(pixz pzstd pigz pbzip2)
  local extensions=(xz zst gz bz2)

  for i in "${!compressors[@]}"; do
    local comp="${compressors[$i]}"
    local ext="${extensions[$i]}"

    # Create a valid file for this compressor
    local valid_file="$tmpdir/valid_$comp.txt"
    generate_test_file "$valid_file" 1024 "valid content for $comp"

    case "$comp" in
      pixz) xz -c -- "$valid_file" >"$valid_file.$ext" ;;
      pzstd) zstd -c -- "$valid_file" >"$valid_file.$ext" ;;
      pigz) gzip -c -- "$valid_file" >"$valid_file.$ext" ;;
      pbzip2) bzip2 -c -- "$valid_file" >"$valid_file.$ext" ;;
    esac
    rm -f -- "$valid_file"

    # Create a corrupted file for this compressor
    local corrupt_file="$tmpdir/corrupt_$comp.txt"
    echo "this is not valid $ext data" >"$corrupt_file.$ext"

    # Run decompress script - should continue despite corruption
    "$DECOMPRESS_SCRIPT" --dir "$tmpdir" --compressor "$comp" >/dev/null 2>&1

    # Valid file should be decompressed
    if [[ ! -f "$valid_file" ]]; then
      echo "Valid file for $comp was not decompressed due to error handling" >&2
      return 1
    fi

    # Corrupted file should not be decompressed (no .txt file created)
    if [[ -f "$corrupt_file" ]]; then
      echo "Corrupted file for $comp was unexpectedly processed" >&2
      return 1
    fi

    # Clean up
    rm -f -- "$valid_file" "$corrupt_file.$ext"
  done
}

run_edge_cases_test() {
  log "Running edge cases test"
  run_test_with_tmpdir _run_edge_cases_test
}

_run_edge_cases_test() {
  local tmpdir="$1"

  # Test case 1: File with no extension
  echo "no extension content" >"$tmpdir/noext"
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1
  # Should be skipped without error

  # Test case 2: File with unknown extension
  echo "unknown extension content" >"$tmpdir/file.unknown"
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1
  # Should be skipped without error

  # Test case 3: Empty compressed file
  touch "$tmpdir/empty.gz"
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1
  # Should handle gracefully without crashing

  # Test case 4: Target file already exists
  echo "original content" >"$tmpdir/exists.txt"
  echo "new content" >"$tmpdir/exists_new.txt"
  gzip -c "$tmpdir/exists_new.txt" >"$tmpdir/exists.txt.gz"
  rm "$tmpdir/exists_new.txt"
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1
  # Should skip decompression since target exists

  # Verify original content unchanged
  if [[ "$(cat "$tmpdir/exists.txt")" != "original content" ]]; then
    echo "Target file was overwritten when it should have been skipped" >&2
    return 1
  fi

  # Test case 5: Magic detection target file already exists
  mkdir -p "$tmpdir/test_content"
  echo "test content" >"$tmpdir/test_content/file.txt"
  tar -C "$tmpdir" -cf "$tmpdir/existing.tar" test_content/
  rm -rf "$tmpdir/test_content"

  # Create misnamed file that would conflict with existing file
  mkdir -p "$tmpdir/test_content2"
  echo "different content" >"$tmpdir/test_content2/file.txt"
  tar -C "$tmpdir" -cf "$tmpdir/conflict.tar" test_content2/
  rm -rf "$tmpdir/test_content2"
  mv "$tmpdir/conflict.tar" "$tmpdir/existing.tar.gz"

  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1

  # Should skip rename and keep original file unchanged
  if [[ ! -f "$tmpdir/existing.tar" ]]; then
    echo "Existing target file was removed during magic rename" >&2
    return 1
  fi

  # Original misnamed file should still exist (rename was skipped)
  if [[ ! -f "$tmpdir/existing.tar.gz" ]]; then
    echo "Original misnamed file was removed when rename should have been skipped" >&2
    return 1
  fi
}

run_magic_format_detection_test() {
  log "Running decompress.sh magic format detection test"
  run_test_with_tmpdir _run_magic_format_detection_test
}

_run_magic_format_detection_test() {
  local tmpdir="$1"

  # Test case 1: tar archive with .gz extension (like the user's example)
  local test_dir="$tmpdir/test_content"
  mkdir -p "$test_dir"
  echo "test file content" >"$test_dir/test.txt"

  # Create a tar archive
  local tar_file="$tmpdir/chatbot.tar"
  tar -C "$tmpdir" -cf "$tar_file" test_content/

  # Rename it to have wrong extension (.gz)
  local misnamed_file="$tmpdir/chatbot.tar.gz"
  mv "$tar_file" "$misnamed_file"

  # Run decompress script - should detect and rename
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1

  # File should be renamed to .tar
  if [[ ! -f "$tar_file" ]]; then
    echo "Misnamed tar archive was not renamed to .tar" >&2
    return 1
  fi

  # Misnamed file should no longer exist
  if [[ -f "$misnamed_file" ]]; then
    echo "Original misnamed file still exists after rename" >&2
    return 1
  fi

  # Test case 2: gz file with wrong extension
  local gz_content="$tmpdir/actual_gz.txt"
  echo "gz content" >"$gz_content"
  gzip -c "$gz_content" >"$tmpdir/wrong_ext.bz2"
  rm -f "$gz_content"

  # Run decompress script again
  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" >/dev/null 2>&1

  # Should be renamed to .gz and decompressed
  if [[ ! -f "$tmpdir/wrong_ext.gz" ]]; then
    echo "Wrong extension file was not renamed to correct extension" >&2
    return 1
  fi

  if [[ ! -f "$tmpdir/wrong_ext" ]]; then
    echo "Renamed file was not decompressed" >&2
    return 1
  fi
}

run_decompress_suite() {
  run_single_decompress_test false "keep-compressed"
  run_single_decompress_test true "remove-compressed"
  run_error_handling_test
  run_all_compressors_error_test
  run_magic_format_detection_test
  run_comprehensive_magic_detection_test
  run_edge_cases_test
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_decompress_suite "$@"
fi
