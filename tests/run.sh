#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITES_DIR="$TESTS_DIR/suites"

log() {
  printf '\n==> %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: tests/run.sh [options]

Options:
  --list               Show the test plan after filtering and exit
  --only <suite>       Run only the named suite (can be repeated)
  --skip <suite>       Skip the named suite (can be repeated)
  --help               Show this message

Suites are referenced by their file name (with or without .sh). Examples:
  --only compress
  --only find_duplicate.sh --skip convert_to_tarzst
EOF
}

declare -a SUITES=(
  "compress.sh::Compression pipelines"
  "decompress.sh::Decompression pipelines"
  "analyze_archive.sh::Archive analyzer"
  "find_duplicate.sh::Duplicate detector"
  "convert_to_tarzst.sh::7z ➜ seekable tar.zst converter"
  "create_tarzst.sh::Directory ➜ seekable tar.zst creator"
  "hash_folder.sh::SHA-256 folder hasher"
)

plan() {
  local -n suites_ref=$1
  printf 'Test plan (%d total):\n' "${#suites_ref[@]}"
  for idx in "${!suites_ref[@]}"; do
    local entry="${suites_ref[$idx]}"
    local label="${entry#*::}"
    local name="${entry%%::*}"
    printf '  [%d/%d] %s -> %s\n' "$((idx + 1))" "${#suites_ref[@]}" "$name" "$label"
  done
}

normalize_suite_name() {
  local candidate="$1"
  candidate="${candidate##*/}"
  candidate="${candidate%.sh}"
  printf '%s\n' "$candidate"
}

filter_suites() {
  local -n dest_ref=$1
  shift

  local -a only_names=()
  local -a skip_names=()
  local list_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only)
        [[ $# -ge 2 ]] || { echo "--only requires an argument" >&2; return 2; }
        only_names+=("$(normalize_suite_name "$2")")
        shift 2
        ;;
      --skip)
        [[ $# -ge 2 ]] || { echo "--skip requires an argument" >&2; return 2; }
        skip_names+=("$(normalize_suite_name "$2")")
        shift 2
        ;;
      --list)
        list_only=true
        shift
        ;;
      --help|-h)
        usage
        return 1
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  declare -A include_lookup=()
  declare -A include_seen=()
  declare -A skip_lookup=()

  for name in "${only_names[@]}"; do
    include_lookup["$name"]=1
  done
  for name in "${skip_names[@]}"; do
    skip_lookup["$name"]=1
  done

  for entry in "${SUITES[@]}"; do
    local script_name="${entry%%::*}"
    local base_name
    base_name="$(normalize_suite_name "$script_name")"

    if ((${#include_lookup[@]})) && [[ -z "${include_lookup[$base_name]:-}" ]]; then
      continue
    fi
    if [[ -n "${skip_lookup[$base_name]:-}" ]]; then
      continue
    fi

    include_seen["$base_name"]=1
    dest_ref+=("$entry")
  done

  if ((${#dest_ref[@]} == 0)); then
    echo "No suites selected to run." >&2
    return 3
  fi

  for name in "${!include_lookup[@]}"; do
    if [[ -z "${include_seen[$name]:-}" ]]; then
      echo "Requested suite not found: $name" >&2
      return 3
    fi
  done

  $list_only && return 10
  return 0
}

run_suites() {
  local -n suites_ref=$1
  for idx in "${!suites_ref[@]}"; do
    local entry="${suites_ref[$idx]}"
    local script_name="${entry%%::*}"
    local label="${entry#*::}"
    local script_path="$SUITES_DIR/$script_name"
    local seq=$((idx + 1))
    local total="${#suites_ref[@]}"
    if [[ ! -x "$script_path" ]]; then
      echo "Test suite not found or not executable: $script_path" >&2
      return 1
    fi
    log "[${seq}/${total}] $label"
    "$script_path"
  done
}

main() {
  local -a selected_suites=()
  local filter_status=0
  filter_suites selected_suites "$@" || filter_status=$?

  if ((filter_status == 1)); then
    exit 0
  elif ((filter_status == 10)); then
    plan selected_suites
    exit 0
  elif ((filter_status != 0)); then
    exit "$filter_status"
  fi

  plan selected_suites
  run_suites selected_suites
  log "All tests passed"
}

main "$@"
