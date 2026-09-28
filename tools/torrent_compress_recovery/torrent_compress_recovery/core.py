"""Core recovery logic: match torrent files against input folders."""

import hashlib
import logging
import os
import re
import shutil
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from .bencode import TorrentFile, TorrentMeta, parse_torrent
from .bz2 import Bzip2Header, generate_bzip2_candidates, parse_bzip2_header
from .gzip import GzipHeader, generate_gzip_candidates, parse_gzip_header
from .xz import XzHeader, generate_xz_candidates, parse_xz_header
from .zst import ZstdHeader, generate_zstd_candidates, parse_zstd_header

Header = GzipHeader | Bzip2Header | XzHeader | ZstdHeader

# Dispatch tables keyed by compressed-file extension.
_GENERATORS: dict[str, Callable[..., list[tuple[str, bytes]]]] = {
    ".gz": generate_gzip_candidates,
    ".bz2": generate_bzip2_candidates,
    ".xz": generate_xz_candidates,
    ".zst": generate_zstd_candidates,
}
_HEADER_PARSERS: dict[str, Callable[[Path], Header | None]] = {
    ".gz": parse_gzip_header,
    ".bz2": parse_bzip2_header,
    ".xz": parse_xz_header,
    ".zst": parse_zstd_header,
}


def iter_files(root: Path) -> Iterable[Path]:
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            yield Path(dirpath) / fn


def build_basename_index(roots: list[Path]) -> dict[str, list[Path]]:
    idx: dict[str, list[Path]] = {}
    for r in roots:
        if not r.exists():
            continue
        for p in iter_files(r):
            if not p.is_file():
                continue
            idx.setdefault(p.name, []).append(p)
    return idx


def _ordered_partial_candidates(candidates: list[Path], expected_size: int | None) -> list[tuple[Path, int]]:
    """Live ``(path, size)`` candidates: exact-size matches first, then newest."""
    live: list[tuple[Path, os.stat_result]] = []
    for p in candidates:
        try:
            live.append((p, p.stat()))
        except OSError:
            continue
    live.sort(key=lambda x: (x[1].st_size == expected_size, x[1].st_mtime), reverse=True)
    return [(p, st.st_size) for p, st in live]


def copy_file(src: Path, dst: Path, dry_run: bool) -> None:
    if dry_run:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


@dataclass(frozen=True)
class Result:
    recovered: int
    gzipped: int
    bzipped: int
    xzipped: int
    zstipped: int
    skipped: int
    missing: int


@dataclass(frozen=True)
class _Ctx:
    """Shared recovery state passed to the per-file strategies."""

    meta: TorrentMeta
    partial_index: dict[str, list[Path]]
    raw_index: dict[str, list[Path]]
    hash_algo: str
    brute_force: bool
    dry_run: bool


def _extension(rel_path: str) -> str | None:
    """Return the compression extension of a torrent file, or None."""
    ext = Path(rel_path).suffix.lower()
    return ext if ext in _GENERATORS else None


def _same_file(a: Path, b: Path) -> bool:
    """True if both paths refer to the same file (incl. symlinks/hardlinks)."""
    if a == b:
        return True
    try:
        return b.exists() and os.path.samefile(a, b)
    except OSError:
        return False


# Suffix segments produced by alternate compression tools/levels, e.g.
# "data.bin.pigz1.gz", "data.bin.bz6.bz2", "data.bin.pzstd19.zst".
_VARIANT_SUFFIX_RE = re.compile(r"\.(?:pigz|pbz|bz|xz|pixz|zst|pzstd|gz)\d*(?:_rsync)?$", re.IGNORECASE)


def _extract_raw_name(expected_name: str, rel_path: str) -> str:
    """Extract raw filename from compressed filename."""
    ext = _extension(rel_path)
    if ext is None:
        return expected_name
    without_ext = expected_name[: -len(ext)]
    # Strip tool/level variant segments, e.g. ".pigz9" or ".bz6"
    while _VARIANT_SUFFIX_RE.search(without_ext):
        without_ext = _VARIANT_SUFFIX_RE.sub("", without_ext)
    return without_ext


def _contained_pieces(meta: TorrentMeta, tf: TorrentFile, total_length: int) -> list[tuple[int, int, int]]:
    """All pieces lying fully inside this file's data.

    Yields ``(piece_index, offset_within_file, piece_size)`` tuples. Pieces
    overlapping a file boundary hash data from the neighbouring file and
    cannot be verified from this file alone; the torrent's final piece may
    be short.
    """
    pl = meta.piece_length
    if pl <= 0 or not meta.pieces or tf.length is None:
        return []
    start = tf.offset // pl + (1 if tf.offset % pl else 0)
    pieces = []
    for idx in range(start, len(meta.pieces)):
        in_off = idx * pl - tf.offset
        piece_size = min(pl, total_length - idx * pl)
        if piece_size <= 0:
            break  # malformed torrent: more pieces than data
        if in_off + piece_size > tf.length:
            break  # subsequent pieces start even further inside the file
        pieces.append((idx, in_off, piece_size))
    return pieces


def sha1_piece(data: bytes) -> bytes:
    """Return SHA-1 hash of data."""
    return hashlib.sha1(data).digest()


def sha256_piece(data: bytes) -> bytes:
    """Return SHA-256 hash of data."""
    return hashlib.sha256(data).digest()


def _hash_fn(ctx: _Ctx) -> Callable[[bytes], bytes]:
    return sha256_piece if ctx.hash_algo == "sha256" else sha1_piece


def _try_partial_recovery(ctx: _Ctx, tf: TorrentFile, expected_name: str, dst: Path, pieces: list[tuple[int, int, int]]) -> bool:
    """Recover by reusing an existing (partial) download of the compressed file.

    Every piece fully contained in the file's data that the candidate actually
    holds must match — for a complete candidate that is a whole-file check.
    Every same-named partial candidate is tried, exact-size matches first.
    """
    if not pieces:
        return False
    hash_fn = _hash_fn(ctx)
    need = pieces[-1][1] + pieces[-1][2]  # bytes up to the last contained piece

    for chosen, size in _ordered_partial_candidates(ctx.partial_index.get(expected_name, []), tf.length):
        if tf.length is not None and size > tf.length:
            continue  # longer than the expected file — cannot be its content
        try:
            with chosen.open("rb") as f:
                data = f.read(need)
        except OSError:
            continue
        verified = False
        rejected = False
        for idx, in_off, piece_size in pieces:
            if in_off + piece_size > len(data):
                break  # truncated partial — nothing more to check
            if hash_fn(data[in_off : in_off + piece_size]) != ctx.meta.pieces[idx]:
                rejected = True  # has the bytes but they are wrong
                break
            verified = True
        if rejected or not verified:
            continue

        # The found partial may already sit at the destination (in-place
        # mode, or overlapping dirs) — then nothing needs to be written.
        if _same_file(chosen, dst):
            return True
        copy_file(chosen, dst, ctx.dry_run)
        return True
    return False


def _partial_header(ctx: _Ctx, tf: TorrentFile, expected_name: str) -> Header | None:
    """Parse the compression header from the first parseable partial file."""
    parser = _HEADER_PARSERS.get(_extension(tf.rel_path) or "")
    if parser is None:
        return None
    for chosen, _size in _ordered_partial_candidates(ctx.partial_index.get(expected_name, []), tf.length):
        try:
            header = parser(chosen)
        except OSError:
            continue
        if header is not None:
            return header
    return None


def _recompress_from_raw(ctx: _Ctx, tf: TorrentFile, ext: str, dst: Path, pieces: list[tuple[int, int, int]]) -> bool:
    """Regenerate the compressed file from the raw file and verify against the torrent.

    With a BEP47 per-file SHA-1 only a full-file hash match is accepted — a
    piece-only match without it would produce a file the torrent rejects.
    Otherwise every piece fully contained in the file must match.
    """
    expected_name = Path(tf.rel_path).name
    raw_name = _extract_raw_name(expected_name, tf.rel_path)
    raw_candidates = ctx.raw_index.get(raw_name, [])
    if not raw_candidates:
        return False

    generate = _GENERATORS[ext]
    header = _partial_header(ctx, tf, expected_name)
    hash_fn = _hash_fn(ctx)

    for raw_src in raw_candidates:
        candidates = generate(raw_src, header, brute=ctx.brute_force)

        match = None
        if tf.sha1:
            match = next((data for _, data in candidates if sha1_piece(data) == tf.sha1), None)
        elif pieces:
            match = next(
                (
                    data
                    for _, data in candidates
                    if (tf.length is None or len(data) == tf.length)
                    and all(hash_fn(data[off : off + size]) == ctx.meta.pieces[idx] for idx, off, size in pieces)
                ),
                None,
            )
        if match is None:
            continue

        if not ctx.dry_run:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(match)
        return True
    return False


def recover(  # noqa: PLR0913 - public API; most parameters are keyword-only
    torrent_path: Path,
    raw_dir: Path,
    partial_dir: Path,
    target_dir: Path | None,
    *,
    raw_fallback: bool = False,
    overwrite: bool = False,
    dry_run: bool = False,
    filename_filter: str | None = None,
    brute_force: bool = True,
) -> Result:
    meta = parse_torrent(str(torrent_path))
    out_root = target_dir / meta.name if target_dir else partial_dir
    # Total data length across all files; needed to size the last (short) piece
    total_length = max((tf.offset + (tf.length or 0) for tf in meta.files), default=0)

    ctx = _Ctx(
        meta=meta,
        partial_index=build_basename_index([partial_dir]),
        raw_index=build_basename_index([raw_dir]) if raw_fallback else {},
        # v1 and hybrid pieces are SHA-1; v2 uses SHA-256 piece layers
        hash_algo="sha256" if meta.version == "v2" else "sha1",
        brute_force=brute_force,
        dry_run=dry_run,
    )

    recovered = 0
    compressed = dict.fromkeys(_GENERATORS, 0)
    skipped = 0
    missing = 0

    for tf in meta.files:
        expected_name = Path(tf.rel_path).name
        # Preserve the torrent's relative layout; in-place mode writes next
        # to the partial download at partial_dir/<rel_path>.
        dst = out_root / tf.rel_path

        if filename_filter and expected_name != filename_filter:
            continue

        ext = _extension(tf.rel_path)
        # Skip padding and symlink members (BEP47, no payload data), files
        # without a compression extension, empty members and existing outputs
        if ext is None or (tf.attr and ("p" in tf.attr or "l" in tf.attr)) or (dst.exists() and not overwrite):
            skipped += 1
            continue

        if tf.length is None or tf.length <= 0:
            missing += 1
            continue
        pieces = _contained_pieces(meta, tf, total_length)

        # Isolate per-file failures: one unreadable/unwritable file must not
        # abort the recovery of the remaining torrent members.
        try:
            # 1) Reuse a matching (partial) download of the compressed file
            if _try_partial_recovery(ctx, tf, expected_name, dst, pieces):
                recovered += 1
                continue

            # 2) Regenerate the compressed file from the raw file (opt-in)
            if raw_fallback and _recompress_from_raw(ctx, tf, ext, dst, pieces):
                compressed[ext] += 1
                continue
        except OSError as e:
            logging.warning(f"{tf.rel_path}: recovery failed: {e}")

        missing += 1

    return Result(
        recovered=recovered,
        gzipped=compressed[".gz"],
        bzipped=compressed[".bz2"],
        xzipped=compressed[".xz"],
        zstipped=compressed[".zst"],
        skipped=skipped,
        missing=missing,
    )
