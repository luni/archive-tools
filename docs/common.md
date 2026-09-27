# common.sh — shared library

Not a standalone tool: every script in this repository does
`source common.sh`. It centralizes archive detection, magic-based file
repair, compressor mappings, manifest writers, and misc helpers so the
behavior stays consistent across the suite.

## Archive detection

| Function | Purpose |
| --- | --- |
| `is_split_archive FILE` | True for split volumes: `*.7z.NNN`, `*.zip.NNN`/`.zNN`, `*.rar.NNN`, `*.partN.rar`, `*.rNN`, `.zNN`. |
| `is_first_chunk FILE` | True only for the first volume: `*.001`, `*.part1.rar`, `*.part01.rar`, `*.part001.rar`. Used so manifests/conversions only run once per multi-volume archive. |
| `detect_archive_type FILE` | Prints `7z`, `zip`, `rar`, `tar`, `tar.gz`, `tar.xz`, `tar.bz2`, `tar.zst`, or `unknown`. Compressed-tar spellings are matched before the generic `*.tar.*` catch-all, and 7z/zip/rar before tar, so `foo.tar.zip` classifies as `zip`. |
| `detect_tar_compression FILE` | Prints `gz`, `bz2`, `xz`, `zst`, `lzma` (`.tlz`/`.tar.lzma`), `Z` (`.taz`/`.tar.Z`), or `none` from the filename. |
| `resolve_tar_compression FILE [STRICT]` | Starts from `detect_tar_compression` and cross-checks the payload via `file` magic — a misnamed archive is corrected to its real decompressor; non-tar content (7z/zip/rar/lz4, or anything unrecognized in STRICT mode) dies loudly. |

## Content sniffing / repair

| Function | Purpose |
| --- | --- |
| `detect_actual_format FILE` | Maps `file` output to `gz`, `bz2`, `xz`, `zst`, `lzma`, `lz4`, `tar`, `Z`, `zip`, `rar`, `7z`, or `unknown`. |
| `get_expected_extension FILE` | The format implied by the filename's extension. |
| `rename_misnamed_file FILE` | Renames a file whose content disagrees with its extension (`f.zip` holding tar data → `f.tar`, etc.); refuses when the target exists. Prints the new name on stdout. |

## Compressor mappings

- `COMPRESSOR_EXTS` (assoc): `pixz`→`xz txz`, `pzstd`→`zst tzst`,
  `pigz`→`gz tgz`, `pbzip2`→`bz2 tbz tbz2`.
- `get_compression_extension TOOL`: `xz`/`pixz`→`xz`, `zstd`/`pzstd`→`zst`.
- `get_compressor_command TOOL`: the command template for `compress.sh`
  (`xz`, `zstd`, `pixz`, `xz_big`, `pzstd`, `zstd_big`).
- `get_decompression_command CODEC`: display name of the decompressor used
  for a tar stream (`pigz -dc`, `pbzip2 -dc`, `pixz -d`, `xz -dc`,
  `gzip -dc`, `pzstd -d -q -c`, `cat`).

## Tar streaming helpers

Used by `analyze-archive.sh` and `convert-to-tarzst.sh`.

| Function | Purpose |
| --- | --- |
| `tar_decompress_stream FILE CODEC` | Writes the raw tar payload of a (possibly compressed) tarball to stdout. `xz` goes through `pixz -dk FILE /dev/stdout` — pixz needs a seekable input and an explicit output path. |
| `tar_list_entries FILE DEST [CODEC]` | Lists member names (one per line) into DEST; dies with the tar error output on failure. |
| `write_tar_checksum_command DEST` | Writes the `tar --to-command` helper script: uses tar's exported `TAR_SIZE`/`TAR_FILETYPE`/`TAR_FILENAME`, skips non-regular members (draining stdin so the stream stays in sync), strips a leading `./`, and appends `hash⇥path⇥size` records to `$TMP_MANIFEST`. Set `TAR_CMD_VERBOSE=1` for `processing: ...` progress on stderr. |
| `write_tar_manifest FILE [CODEC] DEST` | Single-pass manifest generation over the whole stream (`--to-command` per member, extraction retargeted into a scratch dir so link/dir members never touch the cwd); appends sorted `hash  path  size` lines to DEST. |

## Path helpers

- `strip_archive_suffixes NAME`: repeatedly strips `.tar.*`, compound
  short forms (`.tgz`, `.txz`, `.tzst`, ...), split-volume suffixes
  (`.7z.001`, `.z01`, `.partN.rar`, `.rNN`), and single extensions
  (`.7z`, `.zip`, `.rar`, `.gz`, ...).
- `default_basename_path ARCHIVE`: `dir/` + `strip_archive_suffixes(base)`.
- `default_sha256_path ARCHIVE`: `ARCHIVE` + `.sha256` — the full name is
  kept so `a.tar`, `a.tar.zst`, and `a.7z` each get their own manifest
  instead of colliding on `a.sha256`.

## Manifest / misc helpers

- `write_sha256_manifest ROOT DEST [EXCLUDE...]`: `find` + `sha256sum` +
  `stat` over ROOT, appending `hash  path  size` lines sorted by relative
  path; ROOT-relative paths listed as EXCLUDE are skipped (used for output
  files inside the scanned tree). Prefix stripping is literal-safe — glob
  characters in ROOT are not treated as patterns.
- `prepare_file_for_write FILE APPEND`: truncate FILE unless APPEND is set.
- `create_temp_dir PREFIX [PARENT]`: `mktemp -d` wrapper.
- `log MSG`, `die MSG`, `require_cmd CMD`, `validate_dir_exists`,
  `confirm_action MSG AUTOCONFIRM ITEMS...`.

## Conventions

- Manifest record on stdout/files: `SHA256␣␣path␣␣size` (two spaces).
- Internal record passing uses `hash⇥path⇥size` (tabs) and NUL framing
  (`path⇥size\0` in analyzer listings). Paths are C-style escaped in
  manifests (`\`→`\\`, tab→`\t`, newline→`\n`, CR→`\r`), so hostile names
  stay single-line records; consumers compare the field opaquely.
