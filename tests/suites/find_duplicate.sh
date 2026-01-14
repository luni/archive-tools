#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

# Use new command group requirements
require_basic_commands

_run_find_duplicate_sha256_test() {
  local tmpdir="$1"
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
$HASH_A  alpha/path-one.txt  111
$HASH_DUP  alpha/path-two.bin  222
$HASH_INTRA  alpha/path-three.bin  333
$HASH_INTRA  alpha/path-four.bin  444
EOF

  cat >"$bravo" <<EOF
$HASH_DUP  bravo/shared.bin  555
$HASH_UNIQUE  bravo/only.txt  666
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
  local redundant_extra="$manifest_dir/charlie.meta"
  cp -- "$bravo" "$charlie"
  : >"$redundant_archive"
  : >"$redundant_extra"
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

  if [[ -e "$charlie" || -e "$redundant_archive" || -e "$redundant_extra" ]]; then
    echo "Redundant manifest/archive/related files not removed under --delete-identical" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_standard_test "find-duplicate-sha256.sh test" _run_find_duplicate_sha256_test
fi
