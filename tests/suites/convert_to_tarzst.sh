#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
source "$TEST_ROOT/lib/zip.sh"
trap cleanup_tmpdirs EXIT

# Use new command group requirements
require_basic_commands
require_archive_commands
require_compression_commands
require_parallel_commands
require_cmd pigz
require_cmd pixz
require_cmd pbzip2

_run_convert_to_tarzst_suite() {
  local tmpdir="$1"
  local input_dir="$tmpdir/input"
  mkdir -p "$input_dir"

  # Use standard fixture for conversion testing
  local hash_output
  hash_output="$(create_standard_fixture "$input_dir" "BASIC" "Convert 7z payload")"

  # Parse hash output
  declare -A expected_hashes
  local -a rel_paths
  while IFS='=' read -r path hash; do
    rel_paths+=("$path")
    expected_hashes["$path"]="$hash"
  done <<<"$hash_output"

  local archive="$tmpdir/sample.7z"
  (
    cd "$input_dir"
    7z a -bd -y "$archive" "${rel_paths[@]}" >/dev/null
  )

  local output_tar_zst="$tmpdir/output.tar.zst"
  local manifest="$tmpdir/output.sha256"

  local script="$REPO_ROOT/convert-to-tarzst.sh"
  if ! "$script" \
      --output "$output_tar_zst" \
      --sha256-file "$manifest" \
      --remove-source \
      "$archive" >/dev/null; then
    echo "convert-to-tarzst.sh failed to convert sample archive" >&2
    return 1
  fi

  [[ -e "$archive" ]] && { echo "Source archive was not removed despite --remove-source" >&2; return 1; }
  [[ -f "$output_tar_zst" ]] || { echo "Output tar.zst not created" >&2; return 1; }
  [[ -f "$manifest" ]] || { echo "SHA256 manifest not created" >&2; return 1; }

  local verify_args=()
  for rel in "${rel_paths[@]}"; do
    verify_args+=("$rel" "${expected_hashes[$rel]}")
  done
  verify_checksum_file "$manifest" "${verify_args[@]}"

  extract_and_verify_tarzst "$output_tar_zst" "$input_dir" "$tmpdir" "${rel_paths[@]}"

  log "Testing tar.gz/tar.xz/tar.bz2 conversion with SHA256"
  local tar_test_dir="$tmpdir/tar_test"
  mkdir -p "$tar_test_dir"

  local tar_rel_paths=(
    "file1.txt"
    "subdir/file2.bin"
  )
  local tar_sizes=(
    256
    768
  )

  declare -A tar_expected_hashes
  for idx in "${!tar_rel_paths[@]}"; do
    local rel="${tar_rel_paths[$idx]}"
    local abs="$tar_test_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" "${tar_sizes[$idx]}" "Tar payload $idx"
    tar_expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  local base_tar="$tmpdir/test.tar"
  tar -C "$tar_test_dir" -cf "$base_tar" "${tar_rel_paths[@]}"

  local gz_tar="$tmpdir/test.tar.gz"
  local xz_tar="$tmpdir/test.tar.xz"
  local bz2_tar="$tmpdir/test.tar.bz2"

  gzip -c "$base_tar" >"$gz_tar"
  xz -c "$base_tar" >"$xz_tar"
  bzip2 -c "$base_tar" >"$bz2_tar"

  for tarball in "$gz_tar" "$xz_tar" "$bz2_tar"; do
    local converted="${tarball%.tar.*}.tar.zst"
    local tar_manifest="${tarball%.tar.*}.sha256"

    if ! "$script" \
        --sha256-file "$tar_manifest" \
        "$tarball" >/dev/null; then
      echo "convert-to-tarzst.sh failed on $tarball" >&2
      return 1
    fi

    if [[ ! -f "$converted" ]]; then
      echo "convert-to-tarzst.sh did not create $converted" >&2
      return 1
    fi

    if [[ ! -f "$tar_manifest" ]]; then
      echo "SHA256 manifest not created for $tarball" >&2
      return 1
    fi

    local tar_verify_args=()
    for rel in "${tar_rel_paths[@]}"; do
      tar_verify_args+=("$rel" "${tar_expected_hashes[$rel]}")
    done
    verify_checksum_file "$tar_manifest" "${tar_verify_args[@]}"

    rm -f -- "$converted" "$tar_manifest"
  done

  log "Testing ZIP archive conversion with SHA256 (all compressors)"
  local zip_test_dir="$tmpdir/zip_test"
  mkdir -p "$zip_test_dir"

  local zip_rel_paths=(
    "zipfile1.txt"
    "zipdir/zipfile2.bin"
  )
  local zip_sizes=(
    384
    896
  )

  declare -A zip_expected_hashes
  for idx in "${!zip_rel_paths[@]}"; do
    local rel="${zip_rel_paths[$idx]}"
    local abs="$zip_test_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" "${zip_sizes[$idx]}" "ZIP payload $idx"
    zip_expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  local -a zip_compressors=("store" "deflate" "bzip2" "lzma")

  for compression in "${zip_compressors[@]}"; do
    log "  -> ZIP compressor: $compression"
    local zip_archive="$tmpdir/test-${compression}.zip"
    if ! create_zip_with_compression "$zip_archive" "$zip_test_dir" "$compression" "${zip_rel_paths[@]}"; then
      echo "Failed to build ZIP archive with $compression compression" >&2
      return 1
    fi

    local zip_converted="$tmpdir/test-${compression}.tar.zst"
    local zip_manifest="$tmpdir/test-${compression}.sha256"

    if ! "$script" \
        --output "$zip_converted" \
        --sha256-file "$zip_manifest" \
        "$zip_archive" >/dev/null; then
      echo "convert-to-tarzst.sh failed on ZIP archive ($compression)" >&2
      return 1
    fi

    if [[ ! -f "$zip_converted" ]]; then
      echo "convert-to-tarzst.sh did not create output for ZIP ($compression)" >&2
      return 1
    fi

    if [[ ! -f "$zip_manifest" ]]; then
      echo "SHA256 manifest not created for ZIP archive ($compression)" >&2
      return 1
    fi

    local zip_verify_args=()
    for rel in "${zip_rel_paths[@]}"; do
      zip_verify_args+=("$rel" "${zip_expected_hashes[$rel]}")
    done
    verify_checksum_file "$zip_manifest" "${zip_verify_args[@]}"

    local zip_reconstructed_tar="$tmpdir/zip_output_${compression}.tar"
    zstd -d -q -c -- "$zip_converted" >"$zip_reconstructed_tar"

    local zip_extract_dir="$tmpdir/zip_extracted_${compression}"
    mkdir -p "$zip_extract_dir"
    tar -C "$zip_extract_dir" -xf "$zip_reconstructed_tar"

    for rel in "${zip_rel_paths[@]}"; do
      local original="$zip_test_dir/$rel"
      local restored="$zip_extract_dir/$rel"
      if [[ ! -f "$restored" ]]; then
        echo "Missing file in reconstructed ZIP tar ($compression): $rel" >&2
        return 1
      fi
      if ! cmp -s "$original" "$restored"; then
        echo "Restored file mismatch for ZIP ($compression) $rel" >&2
        return 1
      fi
    done

    rm -f -- "$zip_converted" "$zip_manifest" "$zip_reconstructed_tar"
    rm -rf -- "$zip_extract_dir"
  done
}

_run_convert_to_tarzst_spaces_test() {
  local tmpdir="$1"
  local input_dir="$tmpdir/input"
  mkdir -p "$input_dir"

  # Create custom fixture with spaces for testing
  local -a rel_paths sizes
  rel_paths=("simple file.txt" "folder with spaces/nested file.txt" "deeply nested path with spaces/another file.dat")
  sizes=(128 256 512)

  declare -A expected_hashes
  for idx in "${!rel_paths[@]}"; do
    local rel="${rel_paths[$idx]}"
    local size="${sizes[$idx]}"
    local abs="$input_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" "$size" "Spaces test payload $idx"
    expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  # Test with different archive types
  local archive_types=("7z" "zip" "tar.gz")

  for archive_type in "${archive_types[@]}"; do
    log "  Testing spaces with $archive_type archive"

    local archive="$tmpdir/spaces_test.$archive_type"
    case "$archive_type" in
      7z)
        (
          cd "$input_dir"
          7z a -bd -y "$archive" "${rel_paths[@]}" >/dev/null
        )
        ;;
      zip)
        (
          cd "$input_dir"
          zip -q "$archive" "${rel_paths[@]}"
        )
        ;;
      tar.gz)
        tar -C "$input_dir" -cf - "${rel_paths[@]}" | gzip -c >"$archive"
        ;;
    esac

    local output_tar_zst="$tmpdir/spaces_output_${archive_type//./_}.tar.zst"
    local manifest="$tmpdir/spaces_manifest_${archive_type//./_}.sha256"

    local script="$REPO_ROOT/convert-to-tarzst.sh"
    if ! "$script" \
        --output "$output_tar_zst" \
        --sha256-file "$manifest" \
        "$archive" >/dev/null 2>&1; then
      echo "convert-to-tarzst.sh failed with spaces test for $archive_type" >&2
      return 1
    fi

    [[ -f "$output_tar_zst" ]] || { echo "Output tar.zst not created for spaces test ($archive_type)" >&2; return 1; }
    [[ -f "$manifest" ]] || { echo "SHA256 manifest not created for spaces test ($archive_type)" >&2; return 1; }

    # Verify all entries are in the manifest with correct hashes
    local verify_args=()
    for rel in "${rel_paths[@]}"; do
      verify_args+=("$rel" "${expected_hashes[$rel]}")
    done
    verify_checksum_file "$manifest" "${verify_args[@]}"

    # Verify the archive can be extracted correctly
    extract_and_verify_tarzst "$output_tar_zst" "$input_dir" "$tmpdir" "${rel_paths[@]}"

    rm -f -- "$output_tar_zst" "$manifest" "$archive"
  done
}

_run_convert_to_tarzst_misnamed_test() {
  local tmpdir="$1"
  local script="$REPO_ROOT/convert-to-tarzst.sh"

  mkdir -p "$tmpdir/wd"
  echo data >"$tmpdir/wd/f.txt"
  tar -C "$tmpdir/wd" -cf "$tmpdir/f.tar" .

  # Regression: gzip bytes disguised as *.tar must be repaired via content
  # sniffing — previously they were streamed through cat and wrapped raw.
  gzip -c "$tmpdir/f.tar" >"$tmpdir/misnamed.tar"
  if ! "$script" -o "$tmpdir/misnamed.tar.zst" "$tmpdir/misnamed.tar" >/dev/null 2>&1; then
    echo "convert-to-tarzst.sh failed on gzip payload named .tar" >&2
    return 1
  fi
  if ! pzstd -d -c "$tmpdir/misnamed.tar.zst" | tar -tf - | grep -q 'f\.txt'; then
    echo "Converted output is not a real tar stream" >&2
    return 1
  fi

  # Unrecognizable bytes named .tar must be rejected, not silently wrapped.
  echo garbage >"$tmpdir/junk.tar"
  if "$script" -o "$tmpdir/junk.tar.zst" "$tmpdir/junk.tar" >/dev/null 2>&1; then
    echo "convert-to-tarzst.sh silently wrapped non-tar garbage" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_standard_test "convert-to-tarzst.sh with SHA256 manifests" _run_convert_to_tarzst_suite
  run_standard_test "convert-to-tarzst.sh with spaces" _run_convert_to_tarzst_spaces_test
  run_standard_test "convert-to-tarzst.sh misnamed input handling" _run_convert_to_tarzst_misnamed_test
fi
