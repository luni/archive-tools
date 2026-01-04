#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

require_cmd tar
require_cmd pzstd
require_cmd python3
require_cmd sha256sum

run_create_tarzst_basic_test() {
  log "Testing create-tarzst.sh basic functionality"

  run_test_with_tmpdir _run_create_tarzst_basic_test
}

_run_create_tarzst_basic_test() {
  local tmpdir="$1"
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
    generate_test_file "$abs" "${sizes[$idx]}" "Create tarzst payload $idx"
    expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  local output_tar_zst="$tmpdir/input.tar.zst"
  local script="$REPO_ROOT/create-tarzst.sh"

  (
    cd "$tmpdir"
    if ! "$script" "$input_dir" >/dev/null; then
      echo "create-tarzst.sh failed to create archive" >&2
      return 1
    fi
  )

  [[ -f "$output_tar_zst" ]] || { echo "Output tar.zst not created" >&2; return 1; }

  extract_and_verify_tarzst "$output_tar_zst" "$input_dir" "$tmpdir" "${rel_paths[@]}"
}

run_create_tarzst_force_test() {
  log "Testing create-tarzst.sh --force option"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local input_dir="$tmpdir/input"
  mkdir -p "$input_dir"

  # Create initial test file
  echo "original content" > "$input_dir/test.txt"

  local output_tar_zst="$tmpdir/input.tar.zst"
  local script="$REPO_ROOT/create-tarzst.sh"

  # Create initial archive
  (
    cd "$tmpdir"
    if ! "$script" "$input_dir" >/dev/null; then
      echo "create-tarzst.sh failed to create initial archive" >&2
      return 1
    fi
  )

  if [[ ! -f "$output_tar_zst" ]]; then
    echo "Initial archive not created" >&2
    return 1
  fi

  local original_size=$(stat -c%s "$output_tar_zst")

  # Try to create again without force - should fail
  if (
    cd "$tmpdir"
    "$script" "$input_dir" >/dev/null 2>&1
  ); then
    echo "create-tarzst.sh should have failed without --force" >&2
    return 1
  fi

  # Verify original file is unchanged
  local size_after_fail=$(stat -c%s "$output_tar_zst")
  if [[ "$original_size" != "$size_after_fail" ]]; then
    echo "Archive size changed after failed overwrite attempt" >&2
    return 1
  fi

  # Modify input and create again with force
  echo "modified content" > "$input_dir/test.txt"
  echo "new file" > "$input_dir/new.txt"

  if ! (
    cd "$tmpdir"
    "$script" --force "$input_dir" >/dev/null
  ); then
    echo "create-tarzst.sh failed with --force option" >&2
    return 1
  fi

  if [[ ! -f "$output_tar_zst" ]]; then
    echo "Archive not created with --force" >&2
    return 1
  fi

  local size_after_force=$(stat -c%s "$output_tar_zst")
  if [[ "$original_size" == "$size_after_force" ]]; then
    echo "Archive size unchanged after --force overwrite" >&2
    return 1
  fi

  # Verify new contents
  local reconstructed_tar="$tmpdir/output.tar"
  zstd -d -q -c -- "$output_tar_zst" >"$reconstructed_tar"

  local extract_dir="$tmpdir/extracted"
  mkdir -p "$extract_dir"
  tar -C "$extract_dir" -xf "$reconstructed_tar"

  if [[ ! -f "$extract_dir/test.txt" ]]; then
    echo "Missing test.txt in extracted archive" >&2
    return 1
  fi

  if [[ ! -f "$extract_dir/new.txt" ]]; then
    echo "Missing new.txt in extracted archive" >&2
    return 1
  fi

  if [[ "$(cat "$extract_dir/test.txt")" != "modified content" ]]; then
    echo "test.txt content not updated" >&2
    return 1
  fi

  if [[ "$(cat "$extract_dir/new.txt")" != "new file" ]]; then
    echo "new.txt content incorrect" >&2
    return 1
  fi

  # Test short form -f flag
  echo "short form test" > "$input_dir/short.txt"
  local short_size=$(stat -c%s "$output_tar_zst")

  if ! (
    cd "$tmpdir"
    "$script" -f "$input_dir" >/dev/null
  ); then
    echo "create-tarzst.sh failed with -f option" >&2
    return 1
  fi

  local size_after_short=$(stat -c%s "$output_tar_zst")
  if [[ "$short_size" == "$size_after_short" ]]; then
    echo "Archive size unchanged after -f overwrite" >&2
    return 1
  fi

  # Verify short form worked
  zstd -d -q -c -- "$output_tar_zst" >"$reconstructed_tar"
  tar -C "$extract_dir" -xf "$reconstructed_tar"

  if [[ ! -f "$extract_dir/short.txt" ]]; then
    echo "Missing short.txt in extracted archive" >&2
    return 1
  fi

  if [[ "$(cat "$extract_dir/short.txt")" != "short form test" ]]; then
    echo "short.txt content incorrect" >&2
    return 1
  fi
}

run_create_tarzst_sha256_test() {
  log "Testing create-tarzst.sh with SHA256 manifest"

  run_test_with_tmpdir _run_create_tarzst_sha256_test
}

_run_create_tarzst_sha256_test() {
  local tmpdir="$1"
  local input_dir="$tmpdir/input"
  mkdir -p "$input_dir"

  local rel_paths=(
    "file1.txt"
    "subdir/file2.bin"
  )
  local sizes=(
    256
    768
  )

  declare -A expected_hashes
  for idx in "${!rel_paths[@]}"; do
    local rel="${rel_paths[$idx]}"
    local abs="$input_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" "${sizes[$idx]}" "SHA256 payload $idx"
    expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
  done

  local output_tar_zst="$tmpdir/output.tar.zst"
  local manifest="$tmpdir/output.sha256"
  local script="$REPO_ROOT/create-tarzst.sh"

  if ! (
    cd "$tmpdir"
    "$script" \
        --output "$output_tar_zst" \
        --sha256-file "$manifest" \
        "$input_dir" >/dev/null
  ); then
    echo "create-tarzst.sh failed with SHA256" >&2
    return 1
  fi

  [[ -f "$output_tar_zst" ]] || { echo "Output tar.zst not created" >&2; return 1; }
  [[ -f "$manifest" ]] || { echo "SHA256 manifest not created" >&2; return 1; }

  local verify_args=()
  for rel in "${rel_paths[@]}"; do
    verify_args+=("$rel" "${expected_hashes[$rel]}")
  done
  verify_checksum_file "$manifest" "${verify_args[@]}"
}

run_create_tarzst_suite() {
  run_create_tarzst_basic_test
  run_create_tarzst_force_test
  run_create_tarzst_sha256_test
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_create_tarzst_suite "$@"
fi
