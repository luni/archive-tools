# compress.sh

Scans a directory recursively for files with compressible extensions
(`tar sql txt csv ibd xlsx docx log` by default) and compresses them in place.
Small files are compressed concurrently with GNU `parallel`; large files are
streamed sequentially through `pv` so progress stays visible. The original file
is removed once its compressed output is in place unless `--keep` is given.

## Usage

```
compress.sh [options]
```

| Option | Description |
| --- | --- |
| `-d`, `--dir DIR` | Directory to scan (default: `.`). |
| `-t`, `--threshold SIZE` | Small/big split (default: `100MiB`). Accepts `100M`, `200MiB`, `50000000`, ... |
| `-j`, `--jobs N` | Parallel jobs for small files (default: `8`; joined `-jN` form also works). |
| `--big-jobs N` | Parallel jobs for big files (default: `1`). |
| `--small TOOL` | Compressor for small files: `xz` or `zstd` (default: `xz`). |
| `--big TOOL` | Compressor for big files: `pixz`, `xz`, `pzstd`, or `zstd` (default: `pixz`). |
| `--xz-level -#` | Compression level for `xz`/`pixz` (default: `-5`). |
| `--zstd-level -#` | Compression level for `zstd` (default: `-6`). |
| `--pzstd-level -#` | Compression level for `pzstd` (default: `-10`). |
| `--ext EXT` | Add an extension (without leading dot) to the scan list. Repeatable, accepts comma-separated values; the first use replaces the default list. |
| `-s`, `--sha1 FILE` | Write the SHA-1 of each original file (captured before compression) to FILE. |
| `--sha1-append` | Append to the SHA-1 file instead of truncating it. |
| `--sha256 FILE` | Write the SHA-256 of each original file to FILE. |
| `--sha256-append` | Append to the SHA-256 file instead of truncating it. |
| `-k`, `--keep`, `--keep-source` | Keep original files after successful compression. |
| `-q`, `--quiet` | Less logging. |
| `-h`, `--help` | Show help. |

## Behavior details

- **File discovery** is case-insensitive (`FOO.TXT` matches `--ext txt`) and
  already-compressed outputs (`*.zst/.tzst/.xz/.txz/.gz/.tgz/.bz2/.tbz/.tbz2`)
  are excluded by name. Files whose *content* is already compressed are
  additionally skipped via `file` magic detection (`skip (already-compressed)`).
- **Output naming** is `FILE` + compressor extension: `xz`/`pixz` → `.xz`,
  `zstd`/`pzstd` → `.zst`. Existing outputs are skipped unless the same path is
  regenerated (there is no `--force`; delete the output first to recompress).
- **Small files** run through GNU `parallel -j N`; **big files** are piped
  through `pv -ptebar` into the compressor, so every big file shows a live
  progress bar. `--big xz`/`--big zstd` use the multithreaded variants
  (`-T0`). The `parallel --bar` progress display is enabled only when a
  controlling tty exists, so non-interactive runs stay quiet.
- **Atomicity**: each file is compressed to a temporary sibling (`FILE.ext.tmp.$$`),
  `mv`'d into place, and gets the original's mtime via `touch -r`. The original
  is deleted only after the new file exists (or kept with `-k`).
- **Checksum capture**: `--sha1`/`--sha256` lines are written before compression
  starts for each file, so a manifest of *originals* can be kept. Manifest lines
  use the sha256sum layout `hash  path`. The checksum files themselves are
  excluded from the scan even when their name matches an active `--ext`.
- **Required tools**: `parallel`, `file`, `pv`, `stat`, plus the selected
  compressors. The script validates them up front and exits early with a
  clear error.

## Examples

```bash
# Defaults: scan ., split at 100MiB, xz for small / pixz for big
./compress.sh

# Custom scan dir, 8 small workers, zstd for everything, keep originals
./compress.sh -d /data/logs --ext log,txt --small zstd --big pzstd -j 8 -k

# Capture SHA-256 of originals before removal
./compress.sh -d /data/backups --sha256 originals.sha256 --sha256-append
```

## See also

- [decompress.md](decompress.md) — restores the files this tool produces.
- [WORKFLOW.md](WORKFLOW.md) — where compression fits in the overall pipeline.
