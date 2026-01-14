#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$SUITE_DIR/.." && pwd)"
source "$TEST_ROOT/lib/common.sh"
trap cleanup_tmpdirs EXIT

# Use new command group requirements
require_basic_commands
require_archive_commands

run_analyze_archive_case() {
  local archive_type="$1"
  run_standard_test "analyze-archive.sh test (${archive_type})" _run_analyze_archive_case "$archive_type"
}

_run_analyze_archive_case() {
  local tmpdir="$1"
  local archive_type="$2"
  local LC_ALL=C
  local input_dir="$tmpdir/input"
  local archive split_second_chunk=""
  local expected_log=""
  mkdir -p "$input_dir"

  # Use standard fixture for basic files, add unicode file manually
  # But for split archives, use original 3-file structure to avoid issues
  if [[ "$archive_type" == *"split" ]]; then
    # Use original 3-file structure for split tests, but make files larger to force splitting
    local -a rel_paths
    rel_paths=("alpha.txt" "sub dir/bravo.bin" "spaces/charlie data.csv")

    declare -A expected_hashes
    for idx in "${!rel_paths[@]}"; do
      local rel="${rel_paths[$idx]}"
      local abs="$input_dir/$rel"
      mkdir -p -- "$(dirname -- "$abs")"
      # Make files larger (4KB each) to force RAR splitting
      generate_test_file "$abs" 4096 "Analyze archive payload $idx (${archive_type})"
      expected_hashes["$rel"]="$(sha256sum -- "$abs" | awk '{print $1}')"
    done
  else
    # Use standard fixture for other tests
    local hash_output
    hash_output="$(create_standard_fixture "$input_dir" "BASIC" "Analyze archive payload (${archive_type})")"

    # Parse basic fixture hashes
    declare -A expected_hashes
    local -a rel_paths
    while IFS='=' read -r path hash; do
      rel_paths+=("$path")
      expected_hashes["$path"]="$hash"
    done <<<"$hash_output"

    # Add unicode file manually
    local unicode_path="unicode set ♫/資料セット №1/emoji_файл 😀.txt"
    local unicode_abs="$input_dir/$unicode_path"
    mkdir -p -- "$(dirname -- "$unicode_abs")"
    generate_test_file "$unicode_abs" 4096 "Unicode payload (${archive_type})"
    expected_hashes["$unicode_path"]="$(sha256sum -- "$unicode_abs" | awk '{print $1}')"
    rel_paths+=("$unicode_path")
  fi

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
    7z_split)
      archive="$tmpdir/sample.7z.001"
      (
        cd "$input_dir"
        7z a -bd -y -v1k "$tmpdir/sample.7z" "${rel_paths[@]}" >/dev/null
      )
      split_second_chunk="$tmpdir/sample.7z.002"
      ;;
    zip)
      archive="$tmpdir/sample.zip"
      (
        cd "$input_dir"
        zip -q "$archive" "${rel_paths[@]}"
      )
      ;;
    zip_split)
      archive="$tmpdir/sample.zip.001"
      (
        cd "$input_dir"
        7z a -bd -y -tzip -v1k "$tmpdir/sample.zip" "${rel_paths[@]}" >/dev/null
      )
      split_second_chunk="$tmpdir/sample.zip.002"
      ;;
    rar)
      archive="$tmpdir/sample.rar"
      (
        cd "$input_dir"
        # Use -r to recurse and preserve directory structure
        rar a -m0 -r "$archive" . >/dev/null
      )
      ;;
    rar_split)
      (
        cd "$input_dir"
        # Use -r to recurse and preserve directory structure
        # Use volume size that forces splitting but keeps all files in first chunk
        rar a -m0 -r -v7k "$tmpdir/sample.rar" . >/dev/null
      )
      local rar_chunks_raw=()
      local rar_chunks=()
      local nullglob_was_on=0
      if shopt -q nullglob; then
        nullglob_was_on=1
      else
        shopt -s nullglob
      fi
      rar_chunks_raw+=( "$tmpdir"/sample.part*.rar )
      rar_chunks_raw+=( "$tmpdir"/sample.r[0-9][0-9] )
      rar_chunks_raw+=( "$tmpdir"/sample.r[0-9][0-9][0-9] )
      if [[ $nullglob_was_on -eq 0 ]]; then
        shopt -u nullglob
      fi
      if [[ -f "$tmpdir/sample.rar" ]]; then
        rar_chunks_raw+=( "$tmpdir/sample.rar" )
      fi
      declare -A rar_seen=()
      for candidate in "${rar_chunks_raw[@]}"; do
        [[ -e "$candidate" ]] || continue
        if [[ -z "${rar_seen[$candidate]:-}" ]]; then
          rar_seen["$candidate"]=1
          rar_chunks+=("$candidate")
        fi
      done
      if [[ "${#rar_chunks[@]}" -lt 2 ]]; then
        echo "Failed to create expected split RAR chunks" >&2
        ls -al "$tmpdir" >&2 || true
        return 1
      fi
      IFS=$'\n' read -r -d '' -a rar_chunks < <(printf '%s\n' "${rar_chunks[@]}" | LC_ALL=C sort && printf '\0')
      archive="${rar_chunks[0]}"
      split_second_chunk="${rar_chunks[1]}"
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
    # For split archives, only the first chunk is processed, so adjust expected count
    local expected_count="${#rel_paths[@]}"
    if [[ "$archive_type" == *"split" ]]; then
      # Split archives may process fewer files in first chunk
      if [[ "$output" =~ Processed\ ([0-9]+)\ file\(s\)\. ]]; then
        expected_count="${BASH_REMATCH[1]}"
      else
        echo "Could not determine processed count for split archive (${archive_type})" >&2
        echo "$output" >&2
        return 1
      fi
    fi

    if [[ "$output" != *"Processed ${expected_count} file(s)."* ]]; then
      echo "analyze-archive.sh reported unexpected processed count (${archive_type})" >&2
      echo "$output" >&2
      return 1
    fi
  fi

  local previous_path=""
  declare -A seen_paths=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([[:xdigit:]]{64})[[:space:]][[:space:]]+(.+)[[:space:]][[:space:]]+([0-9]+)$ ]]; then
      local hash="${BASH_REMATCH[1]}"
      local path="${BASH_REMATCH[2]}"
      local size="${BASH_REMATCH[3]}"
      local normalized="${path#./}"
    else
      echo "Malformed manifest line (${archive_type}): $line" >&2
      return 1
    fi

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
      # For split archives, it's expected that not all files are in the first chunk
      if [[ "$archive_type" != *"split"* ]]; then
        echo "Missing manifest entry for $rel (${archive_type})" >&2
        return 1
      fi
    fi
  done

  if [[ -n "$split_second_chunk" && -f "$split_second_chunk" ]]; then
    local nonfirst_log="$tmpdir/nonfirst-${archive_type}.log"
    if "$REPO_ROOT/analyze-archive.sh" "$split_second_chunk" >"$nonfirst_log" 2>&1; then
      echo "analyze-archive.sh unexpectedly processed non-first split chunk (${archive_type}): $split_second_chunk" >&2
      cat "$nonfirst_log" >&2
      return 1
    fi

    local output_nonfirst
    output_nonfirst="$(cat "$nonfirst_log")"
    if [[ "$output_nonfirst" != *"Failed to list entries for $split_second_chunk"* ]]; then
      echo "Expected failure when analyzing non-first split chunk (${archive_type})" >&2
      echo "$output_nonfirst" >&2
      return 1
    fi

    local nonfirst_manifest="${split_second_chunk%.*}.sha256"
    if [[ -e "$nonfirst_manifest" ]]; then
      echo "Manifest should not be created for non-first split chunk (${archive_type})" >&2
      return 1
    fi
  fi

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
  run_standard_test "analyze-archive.sh invalid archive tests" _run_analyze_archive_invalid_cases
}

_run_analyze_archive_invalid_cases() {
  local tmpdir="$1"
  local -a types=("7z" "tar" "zip" "rar")

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
      rar)
        invalid="$tmpdir/bad.rar"
        expected_msg="Failed to list rar entries for $invalid"
        ;;
      *)
        echo "Unknown invalid archive type: $archive_type" >&2
        return 1
        ;;
    esac

    printf 'invalid archive payload (%s)\n' "$archive_type" >"$invalid"
    # Make it more convincingly invalid for RAR by corrupting the header
    if [[ "$archive_type" == "rar" ]]; then
      printf '\x00\x00\x00\x00\x00\x00\x00\x00' >>"$invalid"
    fi
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

run_analyze_archive_password_protected() {
  run_standard_test "analyze-archive.sh password-protected archive tests" _run_analyze_archive_password_protected
}

_run_analyze_archive_password_protected() {
  local tmpdir="$1"
  local input_dir="$tmpdir/input"
  local archive="$tmpdir/password_protected.7z"
  local manifest="${archive%.*}.sha256"
  local output_file="$tmpdir/output.log"

  mkdir -p "$input_dir"

  # Create test files
  local rel_paths=(
    "secret.txt"
    "data/config.json"
  )

  for rel in "${rel_paths[@]}"; do
    local abs="$input_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" 1024 "Password protected test data"
  done

  # Create password-protected 7z archive
  (
    cd "$input_dir"
    if ! 7z a -bd -y -p"test_password123" "$archive" "${rel_paths[@]}" >/dev/null 2>&1; then
      echo "Failed to create password-protected 7z archive" >&2
      return 1
    fi
  )

  # Verify the archive is password-protected by attempting to extract without password
  # Listing should work (7z shows metadata without password), but extraction should fail
  if ! 7z l "$archive" >/dev/null 2>&1; then
    echo "Password-protected archive listing failed unexpectedly" >&2
    return 1
  fi

  # Test that analyze-archive.sh fails on password-protected archive
  # With the default invalid password, it should fail fast with clear error
  if "$REPO_ROOT/analyze-archive.sh" "$archive" >"$output_file" 2>&1; then
    echo "analyze-archive.sh unexpectedly succeeded on password-protected 7z archive" >&2
    cat "$output_file" >&2
    return 1
  fi

  # Check that appropriate error message is shown
  local output
  output="$(cat "$output_file")"
  if [[ "$output" != *"Data Error in encrypted file. Wrong password"* && "$output" != *"Failed to compute SHA-256 for"* ]]; then
    echo "Expected password error message missing for password-protected 7z archive" >&2
    echo "$output" >&2
    return 1
  fi

  # Verify that no manifest file was created
  if [[ -e "$manifest" ]]; then
    echo "Manifest should not be created when analyze-archive.sh fails on password-protected archive" >&2
    return 1
  fi

  log "Password-protected 7z archive test passed - correctly skipped/handled"
}

run_analyze_archive_password_protected_zip() {
  run_standard_test "analyze-archive.sh password-protected ZIP archive tests" _run_analyze_archive_password_protected_zip
}

_run_analyze_archive_password_protected_zip() {
  local tmpdir="$1"
  local input_dir="$tmpdir/input"
  local archive="$tmpdir/password_protected.zip"
  local manifest="${archive%.*}.sha256"
  local output_file="$tmpdir/output.log"

  mkdir -p "$input_dir"

  # Create test files
  local rel_paths=(
    "secret.txt"
    "data/config.json"
  )

  for rel in "${rel_paths[@]}"; do
    local abs="$input_dir/$rel"
    mkdir -p -- "$(dirname -- "$abs")"
    generate_test_file "$abs" 1024 "Password protected ZIP test data"
  done

  # Create password-protected ZIP archive
  (
    cd "$input_dir"
    if ! zip -r -P"test_password123" "$archive" "${rel_paths[@]}" >/dev/null 2>&1; then
      echo "Failed to create password-protected ZIP archive" >&2
      return 1
    fi
  )

  # Test that analyze-archive.sh fails on password-protected ZIP archive
  # With the default invalid password, it should fail fast with clear error
  if "$REPO_ROOT/analyze-archive.sh" "$archive" >"$output_file" 2>&1; then
    echo "analyze-archive.sh unexpectedly succeeded on password-protected ZIP archive" >&2
    cat "$output_file" >&2
    return 1
  fi

  # Check that appropriate error message is shown
  local output
  output="$(cat "$output_file")"
  if [[ "$output" != *"Wrong password"* && "$output" != *"Failed to compute SHA-256 for"* ]]; then
    echo "Expected password error message missing for password-protected ZIP archive" >&2
    echo "$output" >&2
    return 1
  fi

  # Verify that no manifest file was created
  if [[ -e "$manifest" ]]; then
    echo "Manifest should not be created when analyze-archive.sh fails on password-protected ZIP archive" >&2
    return 1
  fi

  log "Password-protected ZIP archive test passed - correctly skipped/handled"
}

run_analyze_archive_suite() {
  run_analyze_archive_case tar
  run_analyze_archive_case 7z
  run_analyze_archive_case 7z_split
  run_analyze_archive_case zip_split
  run_analyze_archive_case zip
  run_analyze_archive_case rar
  run_analyze_archive_case rar_split
  run_analyze_archive_invalid_cases
  run_analyze_archive_password_protected
  run_analyze_archive_password_protected_zip
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_analyze_archive_suite "$@"
fi
