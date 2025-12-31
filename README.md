# compress-tool
small shell script to do some compression of files in bulk

`compress.sh` scans a directory for large text-ish artifacts (tar/sql/txt/csv/ibd) and
compresses them using sensible defaults. Smaller files are processed in
parallel, while bigger blobs are streamed sequentially with progress output.
`decompress.sh` reverses the process for `.xz`/`.txz` and `.zst`/`.tzst`
artifacts while restoring the original modification time.
`analyze-archive.sh` inspects `.7z`, `.tar*`, or `.zip` archives and produces a
sorted manifest with the SHA-256 of every file inside without touching disk.

## Required tools

| Tool | Why |
| --- | --- |
| `bash` (4+) | Script language features such as `${var,,}` and `[[ … ]]`. |
| GNU coreutils (`find`, `stat`, `sha1sum`, `sha256sum`, `mktemp`, `touch`, etc.) | File discovery and bookkeeping. |
| `pv` | Streams large files with progress bars when compressing “big” inputs. |
| `xz` | Default compressor for “small” files and for `pixz`/`xz` outputs. |
| `pixz` | Default compressor for “big” files; enables parallel xz for large archives. |
| GNU `parallel` | Runs many small compression jobs concurrently. |

These tools must be on `$PATH`; the script will exit early when a required tool
is missing. On Debian/Ubuntu systems you can install the full toolset with:

```
sudo apt install bash coreutils pv xz-utils pixz parallel
```

## Optional tools

Install the tools below only if you intend to select the corresponding flags:

| Tool | When it is needed |
| --- | --- |
| `zstd` | Use `--small zstd` for small files or `--big zstd` for large files. |
| `pzstd` | Use `--big pzstd` for threaded Zstandard compression. |

## Usage

Run `./compress.sh --help` for the exhaustive flag list. Key options:

```
./compress.sh \
  --dir /data/backups \
  --threshold 200MiB \
  --jobs 12 \
  --small xz \
  --big pixz \
  --sha256 checksums.txt
```

- Files smaller than `--threshold` are compressed in parallel (`--jobs` workers).
- Files at or above the threshold are streamed sequentially with progress bars.
- When `--sha1 FILE` or `--sha256 FILE` is provided the corresponding digest of
  each original file is captured before removal; add the matching `--*-append`
  flag to keep existing checksums.

See `compress.sh` for all advanced tweaks (compression levels, quiet mode, etc.).

### File matching

By default the script targets `*.tar`, `*.sql`, `*.txt`, `*.csv`, and `*.ibd`.
Use `--ext EXT` (repeatable, accepts comma-separated values) to provide your own
extension list. The first `--ext` invocation replaces the defaults; subsequent
ones append.

## Archive inspection (7z / tar / zip)

Run `./analyze-archive.sh ARCHIVE` to compute the SHA-256 of every entry inside a
7z, tar, or zip file without extracting it. The script writes each digest and
path to `ARCHIVE.sha256` by default, sorted by path; override the destination
with `--output FILE`. Add `--quiet` to suppress progress logs.

## Decompression

Run `./decompress.sh --help` to list every flag. Key toggles:

```
./decompress.sh \
  --dir /data/backups \
  --compressor zstd \
  --remove-compressed
```

- Scans the target directory recursively for `.xz`/`.txz` or `.zst`/`.tzst`
  files (limit to specific codecs with `--compressor`).
- Restores each archive beside the compressed input and reapplies the original
  modification time to the restored file.
- Add `--remove-compressed` to delete the compressed artifact once restoration
  succeeds.
