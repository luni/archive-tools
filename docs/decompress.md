# decompress.sh

Recursively scans a directory for `xz`, `zstd`, `gzip`, `bzip2`, `lzma`
(`.tlz`, `.lzma`) and LZW/`compress` (`.taz`, `.Z`, `.z`) compressed files
(including the compound tar extensions `.txz`, `.tzst`, `.tgz`, `.tbz*`)
and restores each one next to the compressed source, preserving mtimes.
Files whose extension does not match their actual content are repaired first
using `file` magic detection — e.g. a `.zip` that is really xz-compressed data
is renamed to `.xz` and then decompressed.

## Usage

```
decompress.sh [options]
```

| Option | Description |
| --- | --- |
| `-d`, `--dir DIR` | Directory to scan (default: `.`). |
| `-c`, `--compressor NAME` | Restrict to a decompressor: `pixz`, `pzstd`, `pigz`, `pbzip2`, `lzma`, `lzw`. Repeatable or comma-separated; aliases `xz`→`pixz`, `zstd`/`pzstd`, `gzip`→`pigz`, `bzip2`→`pbzip2`, `z`/`compress`/`uncompress`→`lzw`. First use replaces the default set (all six). |
| `-j`, `--jobs N` | Decompress up to N files concurrently via GNU `parallel` (default: `1`, sequential). |
| `-r`, `--remove-source`, `--remove-compressed` | Delete the compressed file after a successful restore. |
| `--overwrite` | Overwrite an existing output instead of skipping. |
| `-q`, `--quiet` | Suppress info logs. |
| `-h`, `--help` | Show help. |

## Behavior details

- **Magic repair**: before decompressing, `.zip`/`.rar`/`.7z` files (extensions
  this tool does not handle) and misnamed compressed files are checked with
  `file`; a mismatch is renamed to the correct extension (`f.zip` containing xz
  data → `f.xz`) unless the target name already exists.
- **Output naming**: `.txz`→`.tar`, `.tzst`→`.tar`, `.tgz`→`.tar`,
  `.tbz`/`.tbz2`→`.tar`, `.tlz`→`.tar`, `.taz`→`.tar`, otherwise the
  compression suffix is stripped (`f.xz`→`f`, `f.lzma`→`f`, `f.Z`→`f`).
- **Atomicity**: decompressed data goes to `OUT.tmp.$$`, is `mv`'d into place,
  and receives the source's mtime. A partial output is removed on failure.
- **Existing outputs** are skipped unless `--overwrite` is passed.
- **Unsupported-but-valid archives** (real `.zip`/`.rar`/`.7z` content) and
  already-uncompressed `.tar` files are skipped with a clear log line.
- **Parallel mode** (`-j N>1`) exports the decompression functions to GNU
  `parallel` workers; failures are logged per file and do not stop the run.
  Sequential mode (`-j 1`) is the default and needs no `parallel`.

## Examples

```bash
# Restore everything under ./backups, sequentially
./decompress.sh -d backups

# Only zstd/xz artifacts, 4 at a time, remove compressed sources afterwards
./decompress.sh -d backups -c zstd,xz -j 4 --remove-compressed

# Overwrite an existing restore
./decompress.sh -d backups --overwrite
```

## See also

- [compress.md](compress.md) — the producer of most files this tool restores.
- [WORKFLOW.md](WORKFLOW.md) — where decompression fits in the pipeline.
