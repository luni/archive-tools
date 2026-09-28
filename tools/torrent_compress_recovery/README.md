# torrent-compress-recovery

Recover compressed files referenced by a `.torrent` by searching for matching files in two input folders.

- **Folder structure in inputs is ignored**; files are matched by basename.
- Output folder structure mirrors the torrent.
- Supports multiple compression formats: `gzip`, `bzip2`, `xz`, `zstd`.
- Multi-step workflow for verification and recovery.

## Install / Run with uv

```bash
uv run torrent-compress-recovery --torrent your.torrent --raw-dir /path/to/raw --partial-dir /path/to/partial [--target-dir /path/to/target] --dry-run
```

## Usage

### Step-by-step workflow

The tool provides a three-step workflow for recovery:

#### Step A: Analyze headers (optional)
```bash
uv run torrent-compress-recovery --torrent your.torrent --raw-dir /path/to/raw --partial-dir /path/to/partial --header-info
```
Shows gzip header information for files in the partial directory.

#### Step B: Verify raw files (optional)
```bash
uv run torrent-compress-recovery --torrent your.torrent --raw-dir /path/to/raw --partial-dir /path/to/partial --verify-only
```
Verifies raw files against gzip trailers (last piece validation).

#### Step C: Full recovery
```bash
uv run torrent-compress-recovery \
    --torrent your.torrent \
    --raw-dir /path/to/raw \
    --partial-dir /path/to/partial \
    --target-dir /path/to/target \
    --raw-fallback \
    --overwrite
```

#### Step C: In-place recovery (no target directory)
```bash
uv run torrent-compress-recovery \
    --torrent your.torrent \
    --raw-dir /path/to/raw \
    --partial-dir /path/to/partial \
    --raw-fallback \
    --overwrite
```

#### Process specific file only
```bash
uv run torrent-compress-recovery \
    --torrent your.torrent \
    --raw-dir /path/to/raw \
    --partial-dir /path/to/partial \
    [--target-dir /path/to/target] \
    --filename "example.txt.gz"
```

### Options

- `--raw-fallback`: If a required compressed file is not found in `partial_dir`, try compressing the corresponding raw file (basename without extension).
- `--overwrite`: Overwrite existing output files.
- `--dry-run`: Show what would be done without writing anything.
- `--header-info`: Show gzip header info for partial files and exit.
- `--verify-only`: Verify raw files against gzip trailers and exit.
- `--brute-force` / `--no-brute-force`: Enable/disable the tool × compression-level candidate matrix when recompressing raw files (default: enabled; `--no-brute-force` limits fallback to the header-guided candidate).
- `--filename`: Process only this specific filename (basename match).
- `--target-dir`: Output folder (optional - if not specified, files will be recovered in-place in partial-dir).

## Supported compression formats

The tool supports multiple compression formats for fallback compression:

- **gzip** (`.gz`) - Built-in Python implementation
- **bzip2** (`.bz2`) - Built-in Python implementation
- **xz** (`.xz`) - Requires `xz` or `pixz` command-line tools
- **zstd** (`.zst`) - Requires `zstd` or `pzstd` command-line tools