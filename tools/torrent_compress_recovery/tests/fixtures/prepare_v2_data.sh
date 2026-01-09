#!/bin/bash
# Prepare realistic v2 torrent test data for torrent-compress-recovery

set -e

HERE="$(dirname "$0")"
DATA_DIR="$(realpath "$HERE/real_data_v2")"
RAW_DIR="$DATA_DIR/raw"
PARTIAL_DIR="$DATA_DIR/partial"

# Create directories
mkdir -p "$RAW_DIR" "$PARTIAL_DIR"

# Create raw files using standard Linux tools
echo "This is a readme file for v2 torrent testing." > "$RAW_DIR/readme.txt"

# Create a large data file using dd (more realistic than Python)
dd if=/dev/urandom of="$RAW_DIR/data.bin" bs=1M count=10 2>/dev/null

# Create a large config file using /dev/urandom and some structure
{
    echo '{"key":"value","number":42,"data":"'
    dd if=/dev/urandom bs=1 count=2000000 2>/dev/null | base64 -w 0 | head -c 1900000
    echo '"}'
} > "$RAW_DIR/config.json"

# Create a subdirectory with additional files
mkdir -p "$RAW_DIR/documents"
echo "Important notes here." > "$RAW_DIR/documents/notes.txt"
# Make it larger to be more realistic
for i in {1..100}; do
    echo "Note line $i with some content that makes the file bigger." >> "$RAW_DIR/documents/notes.txt"
done

# Gzip them with deterministic settings (gzip -n -6)
for name in readme.txt data.bin config.json; do
    gzip -n -6 -c "$RAW_DIR/$name" > "$DATA_DIR/$name.gz"
done

# Gzip files in subdirectory
for name in documents/notes.txt; do
    mkdir -p "$DATA_DIR/documents"
    gzip -n -6 -c "$RAW_DIR/$name" > "$DATA_DIR/$name.gz"
done

# Create truncated partial copies (first half)
mkdir -p "$PARTIAL_DIR/documents"
for gz_file in "$DATA_DIR"/*.gz "$DATA_DIR/documents"/*.gz; do
    if [ -f "$gz_file" ]; then
        # Get relative path and create corresponding partial path
        rel_path="${gz_file#$DATA_DIR/}"
        partial_file="$PARTIAL_DIR/$rel_path"
        mkdir -p "$(dirname "$partial_file")"
        head -c "$(($(wc -c < "$gz_file") / 2))" "$gz_file" > "$partial_file"
    fi
done

# Create v2 torrent using torrentfile CLI (supports v1, v2, and hybrid)
cd "$(dirname "$0")/../.."

# Create a temporary directory with all gz files for torrentfile
GZ_ONLY_DIR="$DATA_DIR/gz_only_temp"
mkdir -p "$GZ_ONLY_DIR"
cp "$DATA_DIR"/*.gz "$GZ_ONLY_DIR/" 2>/dev/null || true
cp "$DATA_DIR/documents"/*.gz "$GZ_ONLY_DIR/" 2>/dev/null || true

# Create v2 torrent
uv run torrentfile create \
    --announce "http://localhost:6969/announce" \
    --piece-length 14 \
    --meta-version 2 \
    --comment "torrent-compress-recovery-test-generator" \
    --out "$DATA_DIR/sample_v2.torrent" \
    "$GZ_ONLY_DIR"

# Create hybrid torrent
uv run torrentfile create \
    --announce "http://localhost:6969/announce" \
    --piece-length 14 \
    --meta-version 3 \
    --comment "torrent-compress-recovery-test-generator" \
    --out "$DATA_DIR/sample_hybrid.torrent" \
    "$GZ_ONLY_DIR"

# Clean up the temporary directory
rm -rf "$GZ_ONLY_DIR"

echo "Prepared realistic v2 test data in $DATA_DIR"
echo "Raw files: $(ls -1 "$RAW_DIR" 2>/dev/null | tr '\n' ' ' || echo "none")"
echo "Gz files: $(ls -1 "$DATA_DIR"/*.gz "$DATA_DIR/documents"/*.gz 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || echo "none")"
echo "Partial files: $(find "$PARTIAL_DIR" -name "*.gz" -printf "%f " 2>/dev/null || echo "none")"
echo "V2 Torrent: $DATA_DIR/sample_v2.torrent"
echo "Hybrid Torrent: $DATA_DIR/sample_hybrid.torrent"
