# hash-folder.sh

Computes the SHA-256 of every file under a directory recursively and writes a
manifest compatible with `find-duplicate-sha256.sh`. Uses `hashdeep` when
installed (faster), otherwise falls back to `find` + `sha256sum`.

## Usage

```
hash-folder.sh [options] DIRECTORY [OUTPUT_FILE]
```

| Argument / option | Description |
| --- | --- |
| `DIRECTORY` | Directory to hash (required). |
| `OUTPUT_FILE` | Manifest destination (default: `DIRECTORY` name + `.sha256`, next to the directory). It is excluded from its own scan when placed inside `DIRECTORY`. |
| `-q`, `--quiet` | Suppress progress logs. |
| `-h`, `--help` | Show help. |

## Output format

One line per file:

```
SHA256␣␣relative/path␣␣size
```

Paths are relative to the hashed directory (a leading `./` is stripped). The
manifest drops straight into `find-duplicate-sha256.sh` alongside archive
manifests — useful for checking whether a directory is already contained in an
archive, or vice versa.

## Behavior details

- With `hashdeep`, CSV output is parsed by splitting on the first two commas
  only, and quoted fields are unwrapped — filenames containing commas (and
  escaped quotes) survive intact.
- The fallback path lists files with `find -print0` + `sha256sum` + `stat`,
  sorted by path — NUL-safe for whitespace filenames.
- The manifest is staged in a temp file in the target directory and moved
  into place only after a fully successful scan: an existing manifest is
  replaced atomically, and nothing is published when files could not be
  read (hashdeep exits 0 on unreadable subtrees, so its stderr — empty on
  a clean run — decides; find errors fail the fallback path outright).
- An output file inside the scanned directory (as well as the staging file)
  is excluded from its own manifest.

## Examples

```bash
./hash-folder.sh /data/exports                  # -> /data/exports.sha256
./hash-folder.sh ./staging /tmp/staging.sha256 -q
./find-duplicate-sha256.sh /data/manifests /tmp # now staging is checked too
```

## Requirements

`hashdeep` (optional, preferred), `find`, `sha256sum`, `stat`, `sort`, `awk`.

## See also

- [find-duplicate-sha256.md](find-duplicate-sha256.md) — consumes the manifest.
- [analyze-archive.md](analyze-archive.md) — the same manifest format for
  archives.
