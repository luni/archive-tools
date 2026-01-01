#!/usr/bin/env bash

# Shared helpers for archive-tools scripts. This file is meant to be sourced.
if [[ -n ${ARCHIVE_TOOLS_COMMON_SOURCED:-} ]]; then
  return 0
fi
ARCHIVE_TOOLS_COMMON_SOURCED=1

# shellcheck shell=bash

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' is not on PATH."
}

prepare_file_for_write() {
  local file="$1" append_flag="${2:-0}"
  [[ -z "$file" ]] && return 0
  mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || true
  if [[ "$append_flag" -eq 1 ]]; then
    : >>"$file"
  else
    : >"$file"
  fi
}

write_sha256_manifest() {
  local root="$1" dest="$2" file rel hash
  [[ -z "$dest" ]] && return 0

  while IFS= read -r -d '' file; do
    rel="${file#$root/}"
    if [[ "$rel" == "$file" ]]; then
      rel="$(basename -- "$file")"
    fi
    hash="$(sha256sum -- "$file" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$rel" >>"$dest"
  done < <(LC_ALL=C find "$root" -type f -print0 | LC_ALL=C sort -z)
}
