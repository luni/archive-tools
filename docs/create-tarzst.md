# create-tarzst.sh

Streams a directory through `tar --numeric-owner` and compresses the stream
with `pzstd`, producing a **seekable** `.tar.zst` archive (pzstd embeds a seek
table, so readers can jump to an offset without decompressing from the start).
Optionally emits a SHA-256 manifest of the source tree.

## Usage

```
create-tarzst.sh [options] DIRECTORY
```

| Option | Description |
| --- | --- |
| `-o`, `--output FILE` | Destination `.tar.zst` path (default: `DIRECTORY` basename + `.tar.zst`, relative to the current directory). |
| `--pzstd-level -#` | pzstd compression level (default: `-10`). |
| `--sha256` | Write a `hash  path  size` manifest of the source tree (default: `DIRECTORY` + `.sha256`, next to the directory). |
| `--sha256-file FILE` | Write the manifest to FILE instead. |
| `--sha256-append` | Append to the manifest file instead of truncating. |
| `-f`, `--force` | Overwrite an existing output file. |
| `-r`, `--remove-source` | Delete the source **directory** (`rm -rf`) after a successful archive. |
| `-q`, `--quiet` | Suppress progress logs. |
| `-h`, `--help` | Show help. |

## Behavior details

- **Atomic output**: the archive is written to a temporary file in the
  destination directory first and `mv`'d into place only after `pzstd`
  finishes, so an interrupted run cannot leave a partial `.tar.zst` behind.
- **Tar layout**: contents are stored as `./`-relative paths from inside
  DIRECTORY with `--numeric-owner`; an empty directory still produces a valid
  (empty) tar stream.
- **mtime**: the output file's modification time is copied from DIRECTORY.
- **Manifest**: generated with `find` + `sha256sum`, one
  `SHA256␣␣path␣␣size` line per file sorted by path — the same format used by
  `analyze-archive.sh`, `hash-folder.sh`, and `find-duplicate-sha256.sh`.
- **`--remove-source` is destructive**: it recursively deletes the input
  directory once the archive exists; make sure the archive verified first.

## Examples

```bash
./create-tarzst.sh /var/backups/site                    # -> site.tar.zst
./create-tarzst.sh /var/backups/site -o /out/site.tar.zst --sha256
./create-tarzst.sh ./scratch --force --remove-source    # archive + delete dir
```

## Requirements

`tar`, `pzstd`, and `sha256sum` when `--sha256*` is used.

## See also

- [convert-to-tarzst.md](convert-to-tarzst.md) — same output format from
  existing archives.
- [decompress.md](decompress.md) — `pzstd` restores `.tzst`/`.zst` back to tar.
- [WORKFLOW.md](WORKFLOW.md) — the normalized archive format.
