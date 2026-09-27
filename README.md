# Archiving Compression Tools ![CI status badge](https://github.com/luni/archive-tools/actions/workflows/tests.yml/badge.svg)

`compress.sh` scans a directory for large text-ish artifacts (tar/sql/txt/csv/ibd)
and compresses them using sensible defaults. Smaller files are processed in
parallel, while bigger blobs are streamed sequentially with progress output.
`decompress.sh` restores `.xz/.txz`, `.zst/.tzst`, `.gz/.tgz`, `.bz2/.tbz*`,
`.tlz`/`.lzma`, and `.taz`/`.Z` artifacts via `pixz`, `pzstd`, `pigz`,
`pbzip2`, `xz`, and `gzip`, writing the expanded file next to the source and
preserving mtimes (optionally removing the original).
`analyze-archive.sh` inspects `.7z`, `.rar`, `.tar*`, or `.zip` archives and produces a
sorted manifest with the SHA-256 of every file inside without touching disk.
`find-duplicate-sha256.sh` scans directories for those manifests, reports when
the same digest appears in multiple archives, can skip intra-manifest duplicates
if you only care about cross-archive collisions, and can list archives whose
entire manifest contents are identical to another.
`convert-to-tarzst.sh` rebuilds `.7z` or `.zip` archives (via temporary
workspaces), `.tar*` streams (via pipes), and plain `.tar` files as seekable
`.tar.zst` payloads using [`pzstd`](https://github.com/facebook/zstd/tree/dev/contrib/pzstd).
`create-tarzst.sh` tars any directory (numeric owners), compresses it with
`pzstd` into a seekable `.tar.zst`, and can emit a SHA-256 manifest of the source
tree in the same pass.

## Documentation

Full per-tool documentation lives in [`docs/`](docs/), including a pipeline
overview with a diagram and decision guide:

| Page | Covers |
| --- | --- |
| [docs/WORKFLOW.md](docs/WORKFLOW.md) | The end-to-end workflow: normalize → fingerprint → dedupe, with a diagram and a "which tool for what" cheat sheet. |
| [docs/compress.md](docs/compress.md) | `compress.sh` — in-place compression of loose files. |
| [docs/decompress.md](docs/decompress.md) | `decompress.sh` — restores compressed files, parallel mode. |
| [docs/analyze-archive.md](docs/analyze-archive.md) | `analyze-archive.sh` — single-pass SHA-256 manifests for archives. |
| [docs/convert-to-tarzst.md](docs/convert-to-tarzst.md) | `convert-to-tarzst.sh` — archive → seekable `.tar.zst`. |
| [docs/create-tarzst.md](docs/create-tarzst.md) | `create-tarzst.sh` — directory → seekable `.tar.zst`. |
| [docs/find-duplicate-sha256.md](docs/find-duplicate-sha256.md) | `find-duplicate-sha256.sh` — cross-archive dedupe + deletion. |
| [docs/hash-folder.md](docs/hash-folder.md) | `hash-folder.sh` — directory → SHA-256 manifest. |
| [docs/common.md](docs/common.md) | `common.sh` — shared library sourced by every script. |

## Quick start

```bash
# Compress loose files in place (xz by default, remove originals)
./compress.sh -d /data/dumps --sha256 originals.sha256

# Fingerprint every archive in a tree
find /data -type f \( -name '*.tar*' -o -name '*.7z' -o -name '*.zip' -o -name '*.rar' \) -print0 |
  parallel -0 -j8 --eta ./analyze-archive.sh {}

# Normalize a legacy archive and fingerprint it in one pass
./convert-to-tarzst.sh backups.7z --sha256

# Find (and optionally delete) redundant archives
./find-duplicate-sha256.sh -A -D /data

# Restore compressed files
./decompress.sh -d /data/dumps -j 8
```

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
| `file` | Detects real file formats: skips already-compressed inputs in `compress.sh` and repairs misnamed extensions in `decompress.sh`. |
| `xz` | Default compressor for “small” files and for `pixz`/`xz` outputs. |
| `pixz` | Default compressor for “big” files; enables parallel xz for large archives and is used by `decompress.sh`. |
| `pigz` | Parallel gzip implementation used by `decompress.sh`, `convert-to-tarzst.sh`, and `analyze-archive.sh`. |
| `pbzip2` | Parallel bzip2 implementation used by `decompress.sh`, `convert-to-tarzst.sh`, and `analyze-archive.sh`. |
| `7z` **or** `7zr` | Required for `analyze-archive.sh` when inspecting `.7z` and `.zip` archives, and for `convert-to-tarzst.sh` extraction. |
| `unrar` | Required for `analyze-archive.sh` when inspecting `.rar` archives. |
| GNU `parallel` | Runs many small compression jobs concurrently, and powers `decompress.sh --jobs`. |
| `pzstd` | Required to emit or read seekable `.tar.zst` outputs (`convert-to-tarzst.sh`, `create-tarzst.sh`, `decompress.sh`, `analyze-archive.sh`). Provided by the `zstd` package. |

These tools must be on `$PATH`; the script will exit early when a required tool
is missing. On Debian/Ubuntu systems you can install the full toolset with:

```
sudo apt install bash coreutils pv file xz-utils pixz pigz pbzip2 parallel p7zip-full unrar zstd fzf
```

## Optional tools

Install the tools below only if you intend to select the corresponding flags:

| Tool | When it is needed |
| --- | --- |
| `zstd` | Use `--small zstd` for small files or `--big zstd` for large files in `compress.sh`. |
| `fzf` | Optional fuzzy finder that powers the multi-select UI when removing identical archives in `find-duplicate-sha256.sh`; falls back to a simple numeric prompt if missing. |
| `hashdeep` | Faster hashing for `hash-folder.sh`; falls back to `find` + `sha256sum` if absent. |
| `rar` | Only needed to *create* `.rar` fixtures in the test suite (inspection uses `unrar`). |

## Usage

Each script ships a `--help` flag with its full option list, and has a
dedicated page under [`docs/`](docs/). Highlights:

- `compress.sh`: `--threshold` splits small/big files, `--jobs`/`--big-jobs`
  control parallelism, `--sha1`/`--sha256` capture original digests, `-k`
  keeps originals.
- `analyze-archive.sh`: streams `.7z`/`.zip`/`.rar`/`.tar*` in a single pass;
  `-o`, `--overwrite`, `-p`/`ARCHIVE_PASSWORD` for encrypted inputs.
- `find-duplicate-sha256.sh`: plain duplicates report by default,
  `--identical-archives` for whole-archive matches, `--delete-identical`
  (`-y` to auto-confirm) removes manifest + archive + same-stem siblings
  while always keeping one member of each group.
- `convert-to-tarzst.sh`: `-o`, `--temp-dir`, `--keep-temp`, `--remove-source`,
  `--force`, `--sha256*`. `.tar.zst` output is written atomically and refuses
  to overwrite its own input.
- `create-tarzst.sh`: `-o`, `--pzstd-level`, `--sha256*`, `--force`,
  `--remove-source` (deletes the input directory after success).
- `decompress.sh`: `--compressor` filters, `-j/--jobs` for parallel restore,
  `--remove-compressed`, `--overwrite`.
- `hash-folder.sh`: `hash-folder.sh DIRECTORY [OUTPUT]` — manifest compatible
  with `find-duplicate-sha256.sh`.
