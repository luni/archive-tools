#!/usr/bin/env bash

create_zip_with_compression() {
  local archive="$1"
  local base_dir="$2"
  local compression="$3"
  shift 3
  python3 "$PYTHON_HELPERS_DIR/create_zip_with_compression.py" "$archive" "$base_dir" "$compression" "$@"
}
