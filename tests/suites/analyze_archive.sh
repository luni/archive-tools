#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

require_cmd python3
require_cmd tar
require_cmd 7z
require_cmd zip
require_cmd unzip
require_cmd sha256sum

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
      ;;
    zip)
      archive="$tmpdir/sample.zip"
      (
        cd "$input_dir"
        zip -q "$archive" "${rel_paths[@]}"
      )
      ;;
    *)
      echo "Unknown archive type for analyze-archive test: $archive_type" >&2
      return 1
      ;;
  esac

  local output
  if ! output="$("$REPO_ROOT/analyze-archive.sh" "$archive" 2>&1)"; then
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

run_analyze_archive_suite() {
  run_analyze_archive_case tar
  run_analyze_archive_case 7z
  run_analyze_archive_case zip
  run_analyze_archive_invalid_cases
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_analyze_archive_suite "$@"
fi
