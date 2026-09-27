# find-duplicate-sha256.sh

Scans one or more directory trees for `*.sha256` manifests — produced by
`analyze-archive.sh`, `convert-to-tarzst.sh --sha256`, `create-tarzst.sh
--sha256`, or `hash-folder.sh` — and reports every SHA-256 digest that appears
more than once. This is how you find archives that contain the same payload
(or payload subsets) without extracting anything.

## Usage

```
find-duplicate-sha256.sh [OPTIONS] [DIRECTORY...]
```

Directories default to `.` when none are given.

| Option | Description |
| --- | --- |
| `-A`, `--identical-archives` | Report only groups of manifests whose *entire* contents are identical (same set of hashes and paths). |
| `-D`, `--delete-identical` | With `-A`: interactively choose which redundant archives/manifests to delete. |
| `-y`, `--yes` | Auto-confirm deletions — keeps the first archive of each identical group (sorted order) and deletes the rest. |
| `-S`, `--skip-intra-manifest` | Count duplicates only when the same hash appears in *different* manifests; repeated entries inside one manifest are ignored. |
| `-h`, `--help` | Show help. |

## Manifest parsing

The parser accepts the standard layout `SHA256␣␣path␣␣size` produced by this
toolset, plus looser variants: `hash path` (single space) and lines without a
size column. Entry paths are taken verbatim — even a leading `*` is kept.
Blank lines,
`#` comments, and `%%`/`%%%%` hashdeep headers are ignored; anything else is
warned about on stderr and counted in the summary. Aggregation is done with a
sorted record stream rather than in-memory tables, so very large manifest
collections stay practical.

## Duplicate report (default mode)

```
Scanned 3 manifest(s); 1204 total entries (1189 unique hashes). Skipped 0 line(s).

Duplicate SHA-256 digests:

SHA256 f953bbd2... (2 occurrences):
  - ./a.sha256 :: data/export.csv
  - ./b.sha256 :: export.csv
```

Each duplicate lists the manifest file and the path *inside* the archive.

## Identical-archive mode (`-A`)

Manifests are fingerprinted by the sorted set of `hash+path` pairs; groups
with two or more identical manifests are printed. With `-D`, each group is
presented for selection — `fzf` multi-select when available, otherwise a
numbered prompt — and choosing a manifest deletes:

- the `.sha256` manifest itself,
- the archive it describes: the manifest path minus `.sha256` (with the
  current naming convention `foo.tar.zst.sha256` describes `foo.tar.zst`;
  for legacy `foo.sha256` manifests that is the plain file `foo`),
- allowlisted siblings sharing the stem: archive payloads (`*.tar*`,
  `*.7z`, `*.zip`, `*.rar`), split-volume chunks (`*.7z.NNN`, `*.zNN`,
  `*.rNN`, `*.partN.rar`), and checksum/meta sidecars (`*.sha1`, `*.md5`,
  `*.sfv`, `*.sig`, `*.meta`, `*.torrent`, `*.nfo`, `*.info`).

Files outside that allowlist (notes, logs, documents, other data) are never
deleted, and names containing glob metacharacters are matched literally.

Safety rails: the tool never deletes *every* member of a group (at least one
must stay), `-y` keeps the alphabetically-first manifest, and the per-file
confirmation lists all targets before anything is removed.

## Examples

```bash
./find-duplicate-sha256.sh /data/manifests          # report duplicates
./find-duplicate-sha256.sh -S /data/manifests       # only cross-archive dupes
./find-duplicate-sha256.sh -A /data/manifests       # identical archives only
./find-duplicate-sha256.sh -A -D /data/manifests    # pick redundancies to delete
./find-duplicate-sha256.sh -A -D -y /data           # non-interactive cleanup
```

## Requirements

`awk`, `sort`, `sha256sum` (for `-A` signatures); `fzf` optional for the
deletion UI.

## See also

- [analyze-archive.md](analyze-archive.md) — produces archive manifests.
- [hash-folder.md](hash-folder.md) — produces directory manifests.
- [WORKFLOW.md](WORKFLOW.md) — the dedupe step of the pipeline.
