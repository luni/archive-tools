#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPRESS_SCRIPT="$REPO_ROOT/compress.sh"
DECOMPRESS_SCRIPT="$REPO_ROOT/decompress.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd parallel
require_cmd xz

TMP_DIRS=()
cleanup_tmpdirs() {
  for d in "${TMP_DIRS[@]}"; do
    [[ -d "$d" ]] && rm -rf -- "$d"
  done
}
trap cleanup_tmpdirs EXIT

run_compress_test() {
  log "Running compress.sh test"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local sample_content="Sample payload for compression"
  printf '%s\n' "$sample_content" >"$tmpdir/data.txt"

  "$COMPRESS_SCRIPT" --dir "$tmpdir" --jobs 1 --small xz --big xz >/dev/null

  if [[ -f "$tmpdir/data.txt" ]]; then
    echo "Expected original file to be removed after compression" >&2
    return 1
  fi

  local compressed="$tmpdir/data.txt.xz"
  if [[ ! -f "$compressed" ]]; then
    echo "Compressed file not created: $compressed" >&2
    return 1
  fi

  local expected="$tmpdir/expected.txt"
  local decompressed="$tmpdir/decompressed.txt"
  printf '%s\n' "$sample_content" >"$expected"
  xz -dc -- "$compressed" >"$decompressed"
  if ! cmp -s "$expected" "$decompressed"; then
    echo "Compressed file does not contain expected contents" >&2
    return 1
  fi
}

run_decompress_test() {
  log "Running decompress.sh test"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TMP_DIRS+=("$tmpdir")

  local sample_content="Another payload for decompression"
  local source_file="$tmpdir/source.txt"
  printf '%s\n' "$sample_content" >"$source_file"

  local compressed="$source_file.xz"
  xz -c -- "$source_file" >"$compressed"
  rm -f -- "$source_file"

  "$DECOMPRESS_SCRIPT" --dir "$tmpdir" --compressor xz >/dev/null

  if [[ ! -f "$source_file" ]]; then
    echo "decompress.sh did not recreate original file" >&2
    return 1
  fi

  local expected="$tmpdir/expected.txt"
  printf '%s\n' "$sample_content" >"$expected"
  if ! cmp -s "$expected" "$source_file"; then
    echo "Decompressed file contents differ from expected" >&2
    return 1
  fi
}

main() {
  run_compress_test
  run_decompress_test
  log "All tests passed"
}

main "$@"
