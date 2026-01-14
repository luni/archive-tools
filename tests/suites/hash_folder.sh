#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

# Use new command group requirements
require_basic_commands

run_hash_folder_test() {
  local method="$1"
  run_standard_test "hash-folder.sh test (${method})" _run_hash_folder_test "$method"
}

_run_hash_folder_test() {
  local tmpdir="$1"
  local method="$2"
  local test_dir="$tmpdir/test_data"
  local output_file="$tmpdir/hashes.sha256"

  # Use COMPRESSION fixture and add empty file manually
  local hash_output
  hash_output="$(create_standard_fixture "$test_dir" "COMPRESSION" "Hash folder fixture")"

  # Parse hash output and create expected hashes
  declare -A expected_hashes
  while IFS='=' read -r path hash; do
    expected_hashes["$path"]="$hash"
  done <<<"$hash_output"

  # Add empty file manually
  touch "$test_dir/empty file.txt"
  expected_hashes["empty file.txt"]="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # Run hash-folder.sh
  local hash_script="$REPO_ROOT/hash-folder.sh"
  if [[ "$method" == "quiet" ]]; then
    "$hash_script" -q "$test_dir" "$output_file"
  else
    "$hash_script" "$test_dir" "$output_file"
  fi

  # Verify output file exists and contains expected hashes
  [[ -f "$output_file" ]] || { echo "Output file not created: $output_file" >&2; return 1; }

  # Verify all expected files are hashed correctly
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([[:xdigit:]]{64})[[:space:]][[:space:]]+(.+)[[:space:]][[:space:]]+([0-9]+)$ ]]; then
      local hash="${BASH_REMATCH[1]}"
      local path="${BASH_REMATCH[2]}"
      # Remove ./ prefix if present
      path="${path#./}"
      [[ -z "$path" ]] && continue

      if [[ -n "${expected_hashes[$path]:-}" ]]; then
        if [[ "$hash" != "${expected_hashes[$path]}" ]]; then
          echo "Hash mismatch for $path" >&2
          echo " expected: ${expected_hashes[$path]}" >&2
          echo " actual  : $hash" >&2
          return 1
        fi
        unset expected_hashes["$path"]
      fi
    else
      echo "Unexpected manifest line: $line" >&2
      return 1
    fi
  done <"$output_file"

  # Check if any expected files are missing
  for path in "${!expected_hashes[@]}"; do
    echo "Missing hash entry for $path" >&2
    return 1
  done

  log "Hash folder test (${method}) passed"
}

run_default_output_test() {
  run_standard_test "hash-folder.sh default output test" _run_default_output_test
}

_run_default_output_test() {
  local tmpdir="$1"
  local test_dir="$tmpdir/test_data"
  mkdir -p "$test_dir"
  echo "test content" >"$test_dir/test.txt"

  local hash_script="$REPO_ROOT/hash-folder.sh"
  "$hash_script" "$test_dir"

  local expected_output="$test_dir.sha256"
  [[ -f "$expected_output" ]] || { echo "Default output file not created: $expected_output" >&2; return 1; }

  # Verify content
  local expected_hash="$(sha256sum "$test_dir/test.txt" | awk '{print $1}')"
  local actual_hash="$(awk '/test\.txt/ {print $1}' "$expected_output")"
  [[ "$expected_hash" == "$actual_hash" ]] || { echo "Default output hash mismatch" >&2; return 1; }

  log "Default output test passed"
}

run_help_test() {
  run_standard_test "hash-folder.sh help test" _run_help_test
}

_run_help_test() {
  local hash_script="$REPO_ROOT/hash-folder.sh"
  local output
  output="$("$hash_script" --help 2>&1)"

  [[ "$output" =~ Usage: ]] || { echo "Help output doesn't contain Usage" >&2; return 1; }
  [[ "$output" =~ Computes\ SHA-256\ hashes ]] || { echo "Help output doesn't contain description" >&2; return 1; }
  [[ "$output" =~ -q,\ --quiet ]] || { echo "Help output doesn't contain quiet option" >&2; return 1; }

  log "Help test passed"
}

run_error_tests() {
  run_standard_test "hash-folder.sh error tests" _run_error_tests
}

_run_error_tests() {
  local tmpdir="$1"
  local hash_script="$REPO_ROOT/hash-folder.sh"

  # Test missing directory argument
  if "$hash_script" 2>/dev/null; then
    echo "Expected failure with missing directory argument" >&2
    return 1
  fi

  # Test non-existent directory
  if "$hash_script" "$tmpdir/nonexistent" 2>/dev/null; then
    echo "Expected failure with non-existent directory" >&2
    return 1
  fi

  # Test unknown option
  if "$hash_script" --unknown-option 2>/dev/null; then
    echo "Expected failure with unknown option" >&2
    return 1
  fi

  log "Error tests passed"
}

main() {
  run_hash_folder_test "normal"
  run_hash_folder_test "quiet"
  run_default_output_test
  run_help_test
  run_error_tests
}

main "$@"
