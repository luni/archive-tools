# Archiving Compression Tools ![CI status badge](https://github.com/luni/archive-tools/actions/workflows/tests.yml/badge.svg)

`compress.sh` scans a directory for large text-ish artifacts (tar/sql/txt/csv/ibd)
and compresses them using sensible defaults. Smaller files are processed in
parallel, while bigger blobs are streamed sequentially with progress output.
`decompress.sh` restores `.xz/.txz`, `.zst/.tzst`, `.gz/.tgz`, and `.bz2/.tbz*`
artifacts via the parallel decompressors `pixz`, `pzstd`, `pigz`, and `pbzip2`,
writing the expanded file next to the source and preserving mtimes (optionally
removing the original).
`analyze-archive.sh` inspects `.7z`, `.rar`, `.tar*`, or `.zip` archives and produces a
sorted manifest with the SHA-256 of every file inside without touching disk.
`find-duplicate-sha256.sh` scans directories for those manifests, reports when
the same digest appears in multiple archives, can skip intra-manifest duplicates
if you only care about cross-archive collisions, and can list archives whose
entire manifest contents are identical to another.
`convert-to-tarzst.sh` rebuilds `.7z` or `.zip` archives (via temporary
workspaces) and `.tar.gz/.xz/.bz2` streams (via pipes) as seekable `.tar.zst`
payloads using [`pzstd`](https://github.com/facebook/zstd/tree/dev/contrib/pzstd).
`create-tarzst.sh` tars any directory (numeric owners), compresses it with
`pzstd` into a seekable `.tar.zst`, and can emit a SHA-256 manifest of the source
tree in the same pass.

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
| `pixz` | Default compressor for “big” files; enables parallel xz for large archives and is used by `decompress.sh`. |
| `pigz` | Parallel gzip implementation used by `decompress.sh`, `convert-to-tarzst.sh`, and `analyze-archive.sh`. |
| `pbzip2` | Parallel bzip2 implementation used by `decompress.sh`, `convert-to-tarzst.sh`, and `analyze-archive.sh`. |
| `7z` **or** `7zr` | Required for `analyze-archive.sh` when inspecting `.7z` and `.zip` archives. |
| `unrar` | Required for `analyze-archive.sh` when inspecting `.rar` archives. |
| GNU `parallel` | Runs many small compression jobs concurrently. |
| `pzstd` | Required to emit or read seekable `.tar.zst` outputs (`convert-to-tarzst.sh`, `create-tarzst.sh`, `decompress.sh`, `analyze-archive.sh`). Provided by the `zstd` package. |

These tools must be on `$PATH`; the script will exit early when a required tool
is missing. On Debian/Ubuntu systems you can install the full toolset with:

```
sudo apt install bash coreutils pv xz-utils pixz pigz pbzip2 parallel p7zip-full unrar zstd fzf
```

## Optional tools

Install the tools below only if you intend to select the corresponding flags:

| Tool | When it is needed |
| --- | --- |
| `zstd` | Use `--small zstd` for small files or `--big zstd` for large files in `compress.sh`. |
| `fzf` | Optional fuzzy finder that powers the multi-select UI when removing identical archives in `find-duplicate-sha256.sh`; falls back to a simple numeric prompt if missing. |

## Usage

Run `./compress.sh --help` for the exhaustive flag list. Key options:

```(bash)
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

## Archive inspection (7z / rar / tar / zip)

Run `./analyze-archive.sh ARCHIVE` to compute the SHA-256 of every entry inside a
7z, rar, tar (including `.tar.gz/.tgz/.taz`, `.tar.bz2/.tbz/.tbz2`, `.tar.xz/.txz/.tlz`,
`.tar.zst/.tzst`), or zip file without extracting it to disk. Each digest is
streamed to stdout for live progress and also written to `ARCHIVE.sha256`, which
is sorted by path before being saved; override the destination with
`--output FILE`. Add `--quiet` to suppress the progress logs if desired.
Existing manifests are skipped unless `--overwrite` is supplied, and empty
archives do not leave behind an empty output file. The script automatically
chooses `7z`/`7zr`, `unrar`, detects tar compression, and uses the parallel decompressors
`pigz`, `pbzip2`, `pixz`, or `pzstd` where appropriate.

When you need to analyze every archive within a directory tree, pair the script
with GNU `parallel`:

```(bash)
find . -type f \( -name '*.tar*' -o -name '*.7z' -o -name '*.zip' -o -name '*.rar' \) -print0 |
  parallel -0 -j8 --eta ./analyze-archive.sh {}
```

The example above scans the current directory, sends each archive path to
`analyze-archive.sh` using eight concurrent workers, and keeps a progress bar
(`--eta`). Adjust the `find` predicate, job count (`-j`), or output location
(`--output`) as needed for your environment.

### Detect duplicate payloads across manifests

Once you have a collection of `.sha256` manifests you can identify archives that
contain identical files (same SHA-256 digest) by scanning the directory tree:

```(bash)
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
remove redundant archives quickly. When paired with `--delete-identical`, the
script prompts you to choose which manifests (and their matching archives +
similarly named artifacts) to remove. If [`fzf`](https://github.com/junegunn/fzf)
is installed you get a full-screen multi-select dialog; otherwise a numbered
prompt is shown so you can still pick the targets interactively.

## Convert `.7z`/`.zip`/`.tar.*` to seekable `.tar.zst`

1. Convert `.7z` **or** `.zip` archives (extracted to a temp dir with `7z`) or `.tar.{gz,xz,bz2}` inputs (streamed via pipes) to seekable
   `.tar.zst`:

   ```(bash)
   ./convert-to-tarzst.sh backups.7z
   ./convert-to-tarzst.sh reports.zip
   ./convert-to-tarzst.sh backups.tar.gz
   ```

The script extracts `.7z` and `.zip` sources with `7z` into
temporary directories, streams the contents through `tar`, and pipes them into
`pzstd` to produce `backups.tar.zst` alongside the original. `.tar.gz/.tgz`,
`.tar.xz/.txz`, and `.tar.bz2/.tbz*` inputs skip the extraction step entirely;
they are decompressed via `pigz`, `pixz`, or `pbzip2` pipelines directly into
`pzstd` so no temporary workspace is needed.

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

```(bash)
./create-tarzst.sh /path/to/directory
```

This streams the given directory through `tar --numeric-owner` and compresses it
with `pzstd --quiet --level -10`, yielding `directory.tar.zst`. Supply `-o FILE`
to customize the destination, use `--pzstd-level -#` to tweak compression, or
pass `--quiet` / `--force` for less logging and overwriting existing outputs.

## Decompression

Run `./decompress.sh --help` to list every flag. Key toggles:

```(bash)
./decompress.sh \
  --dir /data/backups \
  --compressor pigz \
  --compressor pzstd \
  --remove-compressed
```

- Scans the target directory recursively for `.xz/.txz`, `.zst/.tzst`,
  `.gz/.tgz`, and `.bz2/.tbz*` files (limit to specific codecs with one or more
  `--compressor` flags). Aliases like `xz`, `zstd`, `gzip`, or `bzip2` map to the
  parallel implementations automatically.
- Restores each archive beside the compressed input and reapplies the original
  modification time to the restored file.
- Add `--remove-compressed` to delete the compressed artifact once restoration
  succeeds.
