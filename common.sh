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

log() {
  [[ "${QUIET:-0}" -eq 1 ]] && return 0
  printf '%s\n' "$*" >&2
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

restore_mtime() {
  local src="$1" dst="$2"
  touch -r "$src" "$dst"
}

# Archive type detection
detect_archive_type() {
  local archive="$1"
  local lowered="${archive,,}"
  case "$lowered" in
    *.7z)
      printf '7z'
      ;;
    *.tar.gz|*.tgz)
      printf 'tar.gz'
      ;;
    *.tar.xz|*.txz)
      printf 'tar.xz'
      ;;
    *.tar.bz2|*.tbz|*.tbz2)
      printf 'tar.bz2'
      ;;
    *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.tlz|*.taz|*.tar.gz|*.tar.xz|*.tar.zst|*.tar.bz2|*.tzst)
      printf 'tar'
      ;;
    *.zip)
      printf 'zip'
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

detect_tar_compression() {
  local archive="$1"
  local lowered="${archive,,}"
  case "$lowered" in
    *.tar.gz|*.tgz|*.taz) echo "gz" ;;
    *.tar.bz2|*.tbz|*.tbz2) echo "bz2" ;;
    *.tar.xz|*.txz|*.tlz) echo "xz" ;;
    *.tar.zst|*.tzst) echo "zst" ;;
    *) echo "none" ;;
  esac
}

# File path manipulation
default_basename_path() {
  local archive="$1" dir base
  dir="$(dirname -- "$archive")"
  base="$(basename -- "$archive")"
  local lowered="${base,,}"
  case "$lowered" in
    *.tar.gz|*.tar.xz|*.tar.bz2)
      base="${base%.*}"
      base="${base%.*}"
      ;;
    *.tgz|*.txz|*.tbz|*.tbz2)
      base="${base%.*}"
      ;;
    *.7z|*.zip)
      base="${base%.*}"
      ;;
  esac
  printf '%s/%s\n' "$dir" "$base"
}

default_sha256_path() {
  local archive="$1"
  printf '%s.sha256\n' "$(default_basename_path "$archive")"
}

# Compression level defaults
DEFAULT_XZ_LEVEL="-5"
DEFAULT_ZSTD_LEVEL="-6"
DEFAULT_PZSTD_LEVEL="-10"

# Common compressor mappings
declare -A COMPRESSOR_EXTS=(
  [pixz]="xz txz"
  [pzstd]="zst tzst"
  [pigz]="gz tgz"
  [pbzip2]="bz2 tbz tbz2"
)

# Temp directory management
create_temp_dir() {
  local prefix="${1:-archive-tools}"
  local parent="${2:-}"

  if [[ -n "$parent" ]]; then
    mkdir -p -- "$parent" || die "Failed to create temp directory parent: $parent"
    mktemp -d -p "$parent" "${prefix}.XXXXXX" || die "Failed to create temporary directory under $parent"
  else
    mktemp -d "${prefix}.XXXXXX" || die "Failed to create temporary directory"
  fi
}

cleanup_temp_file() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] && rm -f -- "$file"
}

cleanup_temp_dir() {
  local dir="$1" keep="${2:-0}"
  if [[ "$keep" -eq 0 && -n "$dir" && -d "$dir" ]]; then
    rm -rf -- "$dir" || log "Warning: Failed to remove temp directory: $dir"
  elif [[ -n "$dir" && -d "$dir" ]]; then
    log "Temporary directory kept at: $dir"
  fi
}

# Common script setup
setup_script_environment() {
  local script_name="$1"
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=common.sh
  source "${SCRIPT_DIR}/common.sh"
}

# Common argument parsing helpers
parse_flag() {
  local var_name="$1"
  declare -g "$var_name=1"
}

parse_option() {
  local var_name="$1" value="$2"
  [[ $# -lt 2 ]] && die "Missing value for $1"
  declare -g "$var_name=$value"
}

validate_file_exists() {
  local file="$1"
  [[ -f "$file" ]] || die "File not found: $file"
}

validate_dir_exists() {
  local dir="$1"
  [[ -d "$dir" ]] || die "Directory not found: $dir"
}
