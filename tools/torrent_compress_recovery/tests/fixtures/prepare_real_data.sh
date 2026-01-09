#!/bin/bash
# Prepare realistic test data for torrent-compress-recovery

set -e

HERE="$(dirname "$0")"
DATA_DIR="$(realpath "$HERE/real_data")"
RAW_DIR="$DATA_DIR/raw"
PARTIAL_DIR="$DATA_DIR/partial"

# Create directories
mkdir -p "$RAW_DIR" "$PARTIAL_DIR"

# Create raw files
echo "This is a readme file." > "$RAW_DIR/readme.txt"
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)))" > "$RAW_DIR/data.bin"
echo '{"key": "value", "number": 42}' > "$RAW_DIR/config.json"

# Gzip them with deterministic settings (gzip -n -6)
for name in readme.txt data.bin config.json; do
    gzip -n -6 -c "$RAW_DIR/$name" > "$DATA_DIR/$name.gz"
done

# Create pigz-compressed versions with different settings
if command -v pigz >/dev/null 2>&1; then
    for name in readme.txt data.bin config.json; do
        # pigz with different compression levels and options
        pigz -1 -c "$RAW_DIR/$name" > "$DATA_DIR/${name}.pigz1.gz"
        pigz -6 -c "$RAW_DIR/$name" > "$DATA_DIR/${name}.pigz6.gz"
        pigz -9 -c "$RAW_DIR/$name" > "$DATA_DIR/${name}.pigz9.gz"
        pigz -6 --rsyncable -c "$RAW_DIR/$name" > "$DATA_DIR/${name}.pigz_rsync.gz"
    done
    echo "Created pigz compressed files"
else
    echo "pigz not available, skipping pigz test data"
fi

# Create truncated partial copies (first half)
mkdir -p "$PARTIAL_DIR"
for gz_file in "$DATA_DIR"/*.gz; do
    if [ -f "$gz_file" ]; then
        partial_file="$PARTIAL_DIR/$(basename "$gz_file")"
        head -c "$(($(wc -c < "$gz_file") / 2))" "$gz_file" > "$partial_file"
    fi
done

# Create torrent using torrentfile CLI (supports v1, v2, and hybrid)
cd "$(dirname "$0")/../.."

# Create a temporary directory with only the gz files for torrentfile
GZ_ONLY_DIR="$DATA_DIR/gz_only_temp"
mkdir -p "$GZ_ONLY_DIR"
cp "$DATA_DIR"/*.gz "$GZ_ONLY_DIR/" 2>/dev/null || true

uv run torrentfile create \
    --announce "http://localhost:6969/announce" \
    --piece-length 20 \
    --comment "torrent-compress-recovery-test-generator" \
    --out "$DATA_DIR/sample.torrent" \
    "$GZ_ONLY_DIR"

# Clean up the temporary directory
rm -rf "$GZ_ONLY_DIR"

echo "Prepared realistic test data in $DATA_DIR"
echo "Raw files: $(ls -1 "$RAW_DIR" 2>/dev/null | tr '\n' ' ' || echo "none")"
echo "Gz files: $(ls -1 "$DATA_DIR"/*.gz 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || echo "none")"
echo "Partial files: $(ls -1 "$PARTIAL_DIR" 2>/dev/null | tr '\n' ' ' || echo "none")"
echo "Torrent: $DATA_DIR/sample.torrent"
