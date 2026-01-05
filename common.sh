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

# Archive type detection
is_split_archive() {
	local archive="$1"
	local lowered="${archive,,}"
	[[ "$lowered" =~ \.(7z|zip|rar)\.[0-9]+$ ]] ||
		[[ "$lowered" =~ \.part[0-9]+\.rar$ ]] ||
		[[ "$lowered" =~ \.r[0-9]+$ ]]
}

is_first_chunk() {
	local archive="$1"
	local lowered="${archive,,}"
	case "$lowered" in
	*.001 | *.part01.rar | *.part1.rar | *.r01) return 0 ;;
	*) return 1 ;;
	esac
}

detect_archive_type() {
	local archive="$1"
	local lowered="${archive,,}"
	case "$lowered" in
	*.7z | *.7z.001)
		printf '7z'
		;;
	*.tar.gz | *.tgz)
		printf 'tar.gz'
		;;
	*.tar.xz | *.txz)
		printf 'tar.xz'
		;;
	*.tar.bz2 | *.tbz | *.tbz2)
		printf 'tar.bz2'
		;;
	*.tar | *.tar.* | *.tgz | *.tbz | *.tbz2 | *.txz | *.tlz | *.taz | *.tar.gz | *.tar.xz | *.tar.zst | *.tar.bz2 | *.tzst)
		printf 'tar'
		;;
	*.zip | *.zip.001 | *.z01)
		printf 'zip'
		;;
	*.rar | *.rar.001 | *.part[0-9][0-9].rar | *.part[0-9][0-9][0-9].rar)
		printf 'rar'
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
	*.tar.gz | *.tgz | *.taz) echo "gz" ;;
	*.tar.bz2 | *.tbz | *.tbz2) echo "bz2" ;;
	*.tar.xz | *.txz | *.tlz) echo "xz" ;;
	*.tar.zst | *.tzst) echo "zst" ;;
	*) echo "none" ;;
	esac
}

get_compression_extension() {
	local algo="$1"
	case "$algo" in
	xz | pixz) echo "xz" ;;
	zstd | pzstd) echo "zst" ;;
	*) echo "unknown" ;;
	esac
}

get_decompression_command() {
	local compressor="$1"
	case "$compressor" in
	gz)
		echo "pigz -dc"
		;;
	bz2)
		echo "pbzip2 -dc"
		;;
	xz)
		echo "pixz -d"
		;;
	zst)
		echo "pzstd -d -q -c"
		;;
	cat)
		echo "cat"
		;;
	*)
		echo "unknown"
		;;
	esac
}

get_compressor_command() {
	local compressor="$1"
	case "$compressor" in
	xz)
		echo "xz $XZ_LEVEL -T1 -c --"
		;;
	zstd)
		echo "zstd $ZSTD_LEVEL -T1 -q -c --"
		;;
	pixz)
		echo "pixz $XZ_LEVEL"
		;;
	xz_big)
		echo "xz $XZ_LEVEL -c"
		;;
	pzstd)
		echo "pzstd $PZSTD_LEVEL"
		;;
	zstd_big)
		echo "zstd $ZSTD_LEVEL -q -c"
		;;
	*)
		echo "unknown"
		;;
	esac
}

basename_without_extension() {
	local path="$1" mode="${2:-last}"
	local name trimmed
	name="$(basename -- "$path")"

	case "$mode" in
	last)
		trimmed="${name%.*}"
		;;
	any)
		trimmed="${name%%.*}"
		;;
	*)
		die "Invalid mode for basename_without_extension: $mode"
		;;
	esac

	if [[ "$trimmed" == "$name" || -z "$trimmed" ]]; then
		printf '%s\n' "$name"
	else
		printf '%s\n' "$trimmed"
	fi
}

confirm_action() {
	local prompt="$1" auto_confirm="$2" shift 2
	local -a items=("$@")

	if ((auto_confirm)); then
		printf 'Auto-confirmed: %s\n' "$prompt"
		for item in "${items[@]}"; do
			printf '  - %s\n' "$item"
		done
		return 0
	fi

	printf '%s\n' "$prompt"
	printf 'The following %d item(s) will be affected:\n' "${#items[@]}"
	for item in "${items[@]}"; do
		printf '  - %s\n' "$item"
	done
	printf 'Proceed? [y/N]: '
	local reply
	if ! read -r reply; then
		return 1
	fi
	case "${reply,,}" in
	y | yes)
		return 0
		;;
	*)
		printf 'Action cancelled.\n'
		return 1
		;;
	esac
}

detect_actual_format() {
	local file="$1" file_output
	file_output="$(file --brief --mime-type "$file" 2>/dev/null || file --brief "$file" 2>/dev/null || echo "unknown")"

	case "$file_output" in
	*gzip* | *application/gzip*)
		echo "gz"
		;;
	*bzip2* | *application/bzip2*)
		echo "bz2"
		;;
	*xz* | *application/x-xz*)
		echo "xz"
		;;
	*zstd* | *application/zstd*)
		echo "zst"
		;;
	*"POSIX tar archive"* | *"tar archive"* | *application/x-tar*)
		echo "tar"
		;;
	*"compress'd data"* | *application/x-compress*)
		echo "Z"
		;;
	*"Zip archive data"* | *application/zip*)
		echo "zip"
		;;
	*"RAR archive data"* | *application/x-rar*)
		echo "rar"
		;;
	*"7-zip archive data"* | *application/x-7z-compressed*)
		echo "7z"
		;;
	*)
		echo "unknown"
		;;
	esac
}

get_expected_extension() {
	local file="$1"
	case "$file" in
	*.gz) echo "gz" ;;
	*.bz2) echo "bz2" ;;
	*.xz) echo "xz" ;;
	*.zst) echo "zst" ;;
	*.tgz) echo "gz" ;;
	*.txz) echo "xz" ;;
	*.tzst) echo "zst" ;;
	*.tbz | *.tbz2) echo "bz2" ;;
	*.zip | *.zip.001 | *.z01) echo "zip" ;;
	*.rar | *.rar.001 | *.part[0-9][0-9].rar | *.part[0-9][0-9][0-9].rar) echo "rar" ;;
	*.7z | *.7z.001) echo "7z" ;;
	*) echo "unknown" ;;
	esac
}

rename_misnamed_file() {
	local file="$1" actual_ext expected_ext new_name
	actual_ext="$(detect_actual_format "$file")"
	expected_ext="$(get_expected_extension "$file")"

	# Skip if actual format matches expected or is unknown
	if [[ "$actual_ext" == "unknown" || "$actual_ext" == "$expected_ext" ]]; then
		return 0
	fi

	# Handle special case: file is actually a tar archive but has compression extension
	if [[ "$actual_ext" == "tar" ]]; then
		# Handle compound extensions like .tar.gz, .tgz, etc.
		case "$file" in
		*.tar.gz | *.tar.xz | *.tar.bz2 | *.tar.zst | *.tar.zip | *.tar.rar | *.tar.7z)
			new_name="${file%.*.*}.tar" # Remove both extensions and add .tar
			;;
		*.tgz | *.txz | *.tbz | *.tbz2 | *.tzst)
			new_name="${file%.*}.tar" # Remove compound extension and add .tar
			;;
		*.gz | *.xz | *.bz2 | *.zst | *.zip | *.rar | *.7z)
			new_name="${file%.*}.tar" # Remove compression extension and add .tar
			;;
		*)
			new_name="${file}.tar" # Just add .tar
			;;
		esac

		# Check if target file already exists
		if [[ -e "$new_name" ]]; then
			log "magic: skipping rename $file -> $new_name (target already exists)"
			return 1
		fi

		log "magic: DEBUG - target $new_name does not exist, proceeding with rename"

		log "magic: renaming misnamed file $file -> $new_name (actual format: tar archive)"
		mv -- "$file" "$new_name"
		echo "$new_name"
		return 0
	fi

	# Rename to correct compression extension
	case "$file" in
	*.tgz | *.txz | *.tzst | *.tbz | *.tbz2)
		# For compound extensions, replace the compression part
		new_name="${file%.*}.$actual_ext"
		;;
	*)
		# For simple extensions, just replace
		new_name="${file%.*}.$actual_ext"
		;;
	esac

	# Check if target file already exists
	if [[ -e "$new_name" ]]; then
		log "magic: skipping rename $file -> $new_name (target already exists)"
		return 1
	fi

	log "magic: renaming misnamed file $file -> $new_name (actual format: $actual_ext)"
	mv -- "$file" "$new_name"
	echo "$new_name"
}

# File path manipulation
strip_archive_suffixes() {
	local name="$1" lowered
	while :; do
		lowered="${name,,}"
		case "$lowered" in
		*.tar.gz | *.tar.bz2 | *.tar.xz | *.tar.zst)
			name="${name%.*}"
			name="${name%.*}"
			;;
		*.tar)
			name="${name%.tar}"
			;;
		*.tgz | *.txz | *.tbz | *.tbz2 | *.tzst | *.tlz | *.taz)
			name="${name%.*}"
			;;
		*.7z.0[0-9][0-9])
			name="${name%.*}"
			;;
		*.zip.0[0-9][0-9])
			name="${name%.*}"
			;;
		*.z[0-9][0-9])
			name="${name%.*}"
			;;
		*.rar.0[0-9][0-9])
			name="${name%.*}"
			;;
		*.r[0-9][0-9])
			name="${name%.*}"
			;;
		*.part[0-9].rar | *.part[0-9][0-9].rar | *.part[0-9][0-9][0-9].rar)
			name="${name%.part[0-9].rar}"
			name="${name%.part[0-9][0-9].rar}"
			name="${name%.part[0-9][0-9][0-9].rar}"
			;;
		*.7z | *.zip | *.rar)
			name="${name%.*}"
			;;
		*)
			break
			;;
		esac
	done
	printf '%s\n' "$name"
}

default_basename_path() {
	local archive="$1" dir base
	dir="$(dirname -- "$archive")"
	base="$(basename -- "$archive")"
	base="$(strip_archive_suffixes "$base")"
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
