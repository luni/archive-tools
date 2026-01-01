# Archiving Compression Tools ![CI status badge](https://github.com/luni/archive-tools/actions/workflows/tests.yml/badge.svg)

`compress.sh` scans a directory for large text-ish artifacts (tar/sql/txt/csv/ibd) and
compresses them using sensible defaults. Smaller files are processed in
parallel, while bigger blobs are streamed sequentially with progress output.
`decompress.sh` reverses the process for `.xz`/`.txz` and `.zst`/`.tzst`
artifacts while restoring the original modification time.
`analyze-archive.sh` inspects `.7z`, `.tar*`, or `.zip` archives and produces a
sorted manifest with the SHA-256 of every file inside without touching disk.
`find-duplicate-sha256.sh` scans directories for those manifests, reports when
the same digest appears in multiple archives, can skip intra-manifest duplicates
if you only care about cross-archive collisions, and can list archives whose
entire manifest contents are identical to another.
`convert-to-tarzst.sh` rebuilds a `.7z` archive as a seekable `.tar.zst`
payload using [`pzstd`](https://github.com/facebook/zstd/tree/dev/contrib/pzstd)
and can also re-compress `.tar.gz/.tgz`, `.tar.xz/.txz`, and `.tar.bz2/.tbz*`
archives into `.tar.zst` streams without touching disk.
`create-tarzst.sh` tars any directory (numeric owners) and compresses it with
`pzstd` into a seekable `.tar.zst`.

## Test chain

Every pull request runs `tests/run.sh` via the GitHub Actions workflow in
`.github/workflows/tests.yml`, ensuring the compression, conversion, analysis,
and install helpers keep working end-to-end. The badge above reflects the
current status of that workflow on the `main` branch.

## Required tools

| Tool | Why |
| --- | --- |
| `bash` (4+) | Script language features such as `${var,,}` and `[[ … ]]`. |
| GNU coreutils (`find`, `stat`, `sha1sum`, `sha256sum`, `mktemp`, `touch`, etc.) | File discovery and bookkeeping. |
| `pv` | Streams large files with progress bars when compressing “big” inputs. |
| `xz` | Default compressor for “small” files and for `pixz`/`xz` outputs. |
| `pixz` | Default compressor for “big” files; enables parallel xz for large archives. |
| `7z` **or** `7zr` | Required for `analyze-archive.sh` when inspecting `.7z` archives. |
| `unzip` | Required for `analyze-archive.sh` when inspecting `.zip` archives. |
| GNU `parallel` | Runs many small compression jobs concurrently. |
| `pzstd` | Required to emit seekable `.tar.zst` outputs (`convert-to-tarzst.sh`, `create-tarzst.sh`). Provided by the `zstd` package. |

These tools must be on `$PATH`; the script will exit early when a required tool
is missing. On Debian/Ubuntu systems you can install the full toolset with:

```
sudo apt install bash coreutils pv xz-utils pixz parallel p7zip-full pigz pbzip2 pixz unzip zstd
```

## Optional tools

Install the tools below only if you intend to select the corresponding flags:

| Tool | When it is needed |
| --- | --- |
| `zstd` | Use `--small zstd` for small files or `--big zstd` for large files (also needed by `decompress.sh`). |
| `pzstd` | Use `--big pzstd` for threaded Zstandard compression and for streaming `.tar.zst/.tzst` archives in `analyze-archive.sh`. |
| `pigz` | Required by `analyze-archive.sh` to stream `.tar.gz/.tgz` archives. |
| `pbzip2` | Required by `analyze-archive.sh` to stream `.tar.bz2/.tbz` archives. |
| `pixz` | Required by `analyze-archive.sh` to stream `.tar.xz/.txz/.tlz` archives when the default `pixz` binary is not already present. |

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

By default the script targets `*.tar`, `*.sql`, `*.txt`, `*.csv`, `*.ibd`,
`*.xlsx`, and `*.docx`.
Use `--ext EXT` (repeatable, accepts comma-separated values) to provide your own
extension list. The first `--ext` invocation replaces the defaults; subsequent
ones append.

## Archive inspection (7z / tar / zip)

Run `./analyze-archive.sh ARCHIVE` to compute the SHA-256 of every entry inside a
7z, tar (including `.tar.gz/.tgz`, `.tar.bz2/.tbz`, `.tar.xz/.txz`, `.tar.zst/.tzst`),
or zip file without extracting it to disk. Each digest is streamed to stdout for
live progress and also written to `ARCHIVE.sha256`, which is sorted by path
before being saved; override the destination with `--output FILE`. Add `--quiet`
to suppress the progress logs if desired. Existing manifests are skipped unless
`--overwrite` is supplied, and empty archives do not leave behind an empty
output file. The script automatically picks the
available `7z`/`7zr` binary and uses parallel decompressors (`pigz`, `pbzip2`,
`pixz`, `pzstd`) to handle compressed tarballs efficiently.

When you need to analyze every archive within a directory tree, pair the script
with GNU `parallel`:

```
find /data/archives -type f \( -name '*.tar*' -o -name '*.7z' -o -name '*.zip' \) -print0 |
  parallel -0 -j8 --eta ./analyze-archive.sh {}
```

The example above scans `/data/archives`, sends each archive path to
`analyze-archive.sh` using eight concurrent workers, and keeps a progress bar
(`--eta`). Adjust the `find` predicate, job count (`-j`), or output location
(`--output`) as needed for your environment.

### Detect duplicate payloads across manifests

Once you have a collection of `.sha256` manifests you can identify archives that
contain identical files (same SHA-256 digest) by scanning the directory tree:

```
./find-duplicate-sha256.sh /data/archives/manifests
```

Every repeated digest is printed alongside the manifest file that referenced it
and the original path inside the archive, helping you prune redundant backups or
cross-check data integrity.

Add `--skip-intra-manifest` to ignore duplicates that only occur within the same
manifest (useful when archives contain repeated files internally but you only
care about overlaps between archives).

Add `--identical-archives` when you only care about archives that contain the
exact same set of files/hashes (i.e., perfect duplicates). In that mode the
script groups manifests with identical contents and prints each group so you can
remove redundant archives quickly.

## Convert `.7z`/`.zip`/`.tar.*` to seekable `.tar.zst`

1. Convert `.7z` **or** `.zip` archives (extracted to a temp dir with `7z` or
   `unzip`) or `.tar.{gz,xz,bz2}` inputs (streamed via pipes) to seekable
   `.tar.zst`:
   ```
   ./convert-to-tarzst.sh backups.7z
   ./convert-to-tarzst.sh reports.zip
   ./convert-to-tarzst.sh backups.tar.gz
   ```

The script extracts `.7z` sources with `7z` and `.zip` sources with `unzip` into
temporary directories, streams the contents through `tar`, and pipes them into
`pzstd` to produce `backups.tar.zst` alongside the original. `.tar.gz/.xz/.bz2`
inputs skip the extraction step entirely; they are decompressed via
`pigz/gzip`, `pixz/xz`, or `pbzip2/bzip2` pipelines directly into `pzstd` so no
temporary workspace is needed.

Key flags:

- `--output FILE` – override the output location.
- `--temp-dir DIR` / `--keep-temp` – control where extracted files live and
  whether to preserve the workspace (useful when debugging ZIP/7z contents).
- `--remove-source` – delete the original archive after a successful conversion.
- `--pzstd-level -#` – tweak the compression level passed to `pzstd`.
- `--sha256` / `--sha256-file FILE` / `--sha256-append` – emit manifests for the
  reconstructed payload (works for `.7z`, `.zip`, and streamed tarballs).
- `--force` / `--quiet` – overwrite existing outputs or reduce logging noise.

The resulting `.tar.zst` inherits the original archive’s modification time.

## Create seekable `.tar.zst` from a directory

Run:

```
./create-tarzst.sh /path/to/directory
```

This streams the given directory through `tar --numeric-owner` and compresses it
with `pzstd --quiet --level -10`, yielding `directory.tar.zst`. Supply `-o FILE`
to customize the destination, use `--pzstd-level -#` to tweak compression, or
pass `--quiet` / `--force` for less logging and overwriting existing outputs.

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
