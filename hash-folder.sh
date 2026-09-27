#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  hash-folder.sh [options] DIRECTORY [OUTPUT_FILE]

Description:
  Computes SHA-256 hashes for all files in a directory recursively.
  Uses hashdeep if available, falls back to find+sha256sum.

Options:
  -q, --quiet    Suppress progress logs
  -h, --help     Show this help message
EOF
}

QUIET=0
DIRECTORY=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  -q | --quiet)
    QUIET=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    die "Unknown option: $1"
    ;;
  *)
    if [[ -z "$DIRECTORY" ]]; then
      DIRECTORY="$1"
    elif [[ -z "$OUTPUT_FILE" ]]; then
      OUTPUT_FILE="$1"
    else
      die "Too many arguments"
    fi
    shift
    ;;
  esac
done

# Positional args may also follow a literal "--".
for arg in "$@"; do
  if [[ -z "$DIRECTORY" ]]; then
    DIRECTORY="$arg"
  elif [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$arg"
  else
    die "Too many arguments"
  fi
done

[[ -n "$DIRECTORY" ]] || die "Directory path is required."
validate_dir_exists "$DIRECTORY"

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$(default_sha256_path "$DIRECTORY")"
fi

mkdir -p -- "$(dirname -- "$OUTPUT_FILE")"

# Stage the manifest in a temp file in the target directory and publish it
# with mv only after a fully successful scan, so a mid-run failure cannot
# leave a truncated manifest that later dedupe passes would trust.
tmp_manifest="$(mktemp -p "$(dirname -- "$OUTPUT_FILE")" ".$(basename -- "$OUTPUT_FILE").tmp.XXXXXX")"
hd_err=""
trap '[[ -n "$tmp_manifest" ]] && rm -f -- "$tmp_manifest"; [[ -n "$hd_err" ]] && rm -f -- "$hd_err"' EXIT

# Both the output path (a pre-existing manifest inside the scan root) and the
# staging file itself must be excluded from the scan.
out_rel=""
tmp_rel=""
if command -v realpath >/dev/null 2>&1; then
  abs_dir="$(realpath -m -- "$DIRECTORY")"
  for p in "$OUTPUT_FILE" "$tmp_manifest"; do
    rel="$(realpath -m --relative-to="$abs_dir" -- "$p")"
    [[ "$rel" == ".." || "$rel" == ../* || "$rel" == /* || "$rel" == "." ]] && continue
    if [[ "$p" == "$OUTPUT_FILE" ]]; then
      out_rel="$rel"
    else
      tmp_rel="$rel"
    fi
  done
fi

# hashdeep emits filenames raw — a newline inside a name splits its CSV record
# into a valid-looking fragment plus a silently skipped continuation. Detect
# such names up front and take the find+sha256sum path, which escapes them.
nl_names=""
if command -v hashdeep >/dev/null 2>&1; then
  nl_names="$(find "$DIRECTORY" -type f -name "*"$'\n'"*" -print -quit 2>/dev/null)"
fi
if command -v hashdeep >/dev/null 2>&1 && [[ -z "$nl_names" ]]; then
  log "Using hashdeep for faster hashing"
  # hashdeep exits 0 even when parts of the tree are unreadable; its stderr is
  # empty on a clean run, so any output there means the manifest is incomplete.
  hd_err="$(mktemp)"
  if ! hashdeep -l -c sha256 -r "$DIRECTORY" 2>"$hd_err" | awk -v dir="$DIRECTORY" -v excl="$out_rel" -v excl2="$tmp_rel" '
    /^#/ || /^%/ || /^sha256[[:space:]]+filename$/ || /^$/ { next }
    {
      # CSV row: size,hash,filename — the filename may be quoted and may
      # itself contain commas, so split on the first two commas only.
      p1 = index($0, ",")
      if (!p1) next
      p2 = index(substr($0, p1 + 1), ",")
      if (!p2) next
      p2 += p1
      size = substr($0, 1, p1 - 1)
      hash = substr($0, p1 + 1, p2 - p1 - 1)
      path = substr($0, p2 + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", size)
      # An unbalanced quote means an embedded newline split the hashdeep
      # CSV record across two lines — the path would be silently truncated.
      if ((substr(path, 1, 1) == "\"") != (substr(path, length(path), 1) == "\"")) {
        print "hash-folder: unparseable filename (embedded newline?) in: " path > "/dev/stderr"
        bad = 1
        next
      }
      # Strip surrounding quotes and unescape doubled quotes
      if (substr(path, 1, 1) == "\"" && substr(path, length(path), 1) == "\"") {
        path = substr(path, 2, length(path) - 2)
        gsub(/""/, "\"", path)
      }
      # Remove directory prefix if present
      if (index(path, dir "/") == 1) {
        path = substr(path, length(dir) + 2)
      }
      # Remove leading ./ if present
      gsub(/^\.\//, "", path)
      if ((excl != "" && path == excl) || (excl2 != "" && path == excl2)) next
      # Escape control chars so the record stays on one line (see
      # escape_manifest_path in common.sh).
      gsub(/\\/, "\\\\", path)
      gsub(/\t/, "\\t", path)
      gsub(/\r/, "\\r", path)
      print hash "  " path "  " size
    }
    END { if (bad) exit 1 }
  ' >"$tmp_manifest"; then
    cat "$hd_err" >&2
    die "hashdeep manifest generation failed; refusing to publish"
  fi
  if [[ -s "$hd_err" ]]; then
    cat "$hd_err" >&2
    rm -f "$hd_err"
    die "hashdeep reported scan errors; refusing to publish an incomplete manifest"
  fi
  rm -f "$hd_err"
else
  log "Using find+sha256sum (hashdeep not available)"
  write_sha256_manifest "$DIRECTORY" "$tmp_manifest" "$out_rel" "$tmp_rel"
fi

chmod_like_new_file "$tmp_manifest"
mv -f -- "$tmp_manifest" "$OUTPUT_FILE"
tmp_manifest=""

log "SHA-256 manifest written to: $OUTPUT_FILE"
