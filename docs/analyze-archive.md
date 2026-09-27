# analyze-archive.sh

Computes the SHA-256 digest of every regular file inside an archive **without
extracting anything to disk**, and writes a sorted manifest next to the
archive. The manifests are the input for `find-duplicate-sha256.sh`, which
detects identical payloads across archives.

Supported inputs: `.7z` (including `.7z.001` split volumes), `.zip`
(including `.zip.001`/`.z01`), `.rar` (including `.partN.rar` volumes and
`.rar.001`), `.tar`, `.tar.gz/.tgz/.taz`, `.tar.xz/.txz/.tlz`,
`.tar.bz2/.tbz/.tbz2`, `.tar.zst/.tzst`.

## Usage

```
analyze-archive.sh [options] ARCHIVE
```

| Option | Description |
| --- | --- |
| `-o`, `--output FILE` | Target manifest path (default: `ARCHIVE` minus archive suffixes + `.sha256`, next to the archive). |
| `-q`, `--quiet` | Suppress progress logs (digest lines are still printed to stdout). |
| `--overwrite` | Overwrite an existing manifest (default: refuse). |
| `-p`, `--password PWD` | Password for encrypted archives (default: `INVALID_PASSWORD`; may also be supplied via the `ARCHIVE_PASSWORD` environment variable). |
| `-h`, `--help` | Show help. |

## How it works

- **Tarballs** (all compression flavors) stream through
  `tar --to-command` in a single decompression pass: each member's bytes are
  piped to `sha256sum` while `wc -c` captures the exact size. Entries are fed
  to tar via `--files-from` with NUL separation, so unusual names survive.
- **7z / ZIP / RAR** are also processed in a single pass: the archive's own
  listing provides each file's uncompressed size, the archiver streams all
  payloads to stdout in the same order (`7z x -so` / `unrar p`), and each
  entry is framed out of the stream with `head -c <size>` for hashing. Solid
  7z archives are therefore decompressed exactly once, not once per file.
- **Split volumes**: only the first chunk is accepted (`.001`, `.part1.rar`,
  `.part01.rar`, `.part001.rar`); other chunks are rejected so manifests are
  not generated twice. For multi-volume RAR archives, `unrar lt` only lists
  entries that *begin* in the first volume — the manifest covers those
  entries, and entries stored in later volumes are streamed but reported as
  beyond-the-listing in a log note.
- **Manifest format**: `SHA256␣␣path␣␣size`, sorted by path (`LC_ALL=C`).
  Digest lines are also echoed live to stdout. Empty archives produce no
  output file at all.
- **Failures**: a truncated stream, a wrong password, or a listing/stream
  disagreement aborts the run with a non-zero exit; no partial manifest is
  kept in the target location when processing fails mid-stream.

## Password handling

`-p` and `ARCHIVE_PASSWORD` are forwarded to the archiver's command line
(`-p<password>` for `7z`/`unrar`), which means the password can appear in
process listings while the tool runs. `ARCHIVE_PASSWORD` avoids putting the
password on *this script's* command line (shell history, wrappers), but not
on the child's — treat it as a convenience, not a secrecy boundary.

## Batch mode

Pair with GNU `parallel` to fingerprint an entire tree:

```bash
find /data -type f \( -name '*.tar*' -o -name '*.7z' -o -name '*.zip' -o -name '*.rar' \) -print0 |
  parallel -0 -j8 --eta ./analyze-archive.sh {}
```

## Requirements

- `7z` or `7zr` for `.7z`/`.zip`, `unrar` for `.rar`, `tar` + the matching
  decompressor (`pigz`, `pixz`, `pbzip2`, `pzstd`) for tarballs, `sha256sum`.

## See also

- [find-duplicate-sha256.md](find-duplicate-sha256.md) — consumes these manifests.
- [convert-to-tarzst.md](convert-to-tarzst.md) — produces the same manifest
  inline with `--sha256`.
- [WORKFLOW.md](WORKFLOW.md) — the fingerprint/dedupe pipeline.
