"""Core recovery logic: match torrent files against input folders."""

import hashlib
import os
import shutil
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from .bencode import parse_torrent
from .bz2 import sha1_piece


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


def choose_candidate(candidates: list[Path], expected_size: int | None) -> Path | None:
    if not candidates:
        return None
    if expected_size is not None:
        sized = [p for p in candidates if p.exists() and p.stat().st_size == expected_size]
        if len(sized) == 1:
            return sized[0]
        if len(sized) > 1:
            return max(sized, key=lambda p: p.stat().st_mtime)
    return max(candidates, key=lambda p: p.stat().st_mtime)


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
    skipped: int
    missing: int


def _should_skip_file(tf, dst: Path, overwrite: bool) -> bool:
    """Check if a file should be skipped during recovery."""
    # Skip padding files (BEP47)
    if tf.attr and "p" in tf.attr:
        return True

    # Handle .gz and .bz2 files (skip symlinks and other files)
    if not (tf.rel_path.endswith(".gz") or tf.rel_path.endswith(".bz2")):
        return True

    # Skip if destination exists and overwrite is False
    if dst.exists() and not overwrite:
        return True

    return False


def _extract_raw_name(expected_name: str, rel_path: str) -> str:
    """Extract raw filename from compressed filename."""
    if rel_path.endswith(".gz"):
        return expected_name[: -len(".gz")]
    # Handle double extensions like .bz1.bz2, .pbz6.bz2, etc.
    elif expected_name.endswith(".bz2"):
        # Remove the last .bz2 extension
        without_bz2 = expected_name[: -len(".bz2")]
        # Check if there's another compression extension
        if without_bz2.endswith((".bz1", ".bz6", ".bz9", ".pbz1", ".pbz6", ".pbz9")):
            # Remove the compression level extension too
            if without_bz2.endswith((".bz1", ".bz6", ".bz9")):
                return without_bz2[:-4]  # Remove .bzX
            else:  # .pbzX
                return without_bz2[:-5]  # Remove .pbzX
        else:
            return without_bz2
    else:
        return expected_name


def _get_piece_info(tf, meta, piece_length: int) -> tuple[int, bytes] | None:
    """Get piece index and hash for a torrent file."""
    if tf.offset is None or tf.length is None:
        return None
    start_piece_index = tf.offset // piece_length
    if start_piece_index >= len(meta.pieces):
        return None
    return start_piece_index, meta.pieces[start_piece_index]


def _try_partial_recovery(
    tf, expected_name: str, partial_index, target_piece_hash: bytes, piece_length: int, dst: Path, overwrite: bool, dry_run: bool
) -> bool:
    """Try to recover from partial file."""
    cand_partial = partial_index.get(expected_name, [])
    chosen = choose_candidate(cand_partial, tf.length)
    if chosen is None:
        return False

    # If the partial file is complete and matches the first piece, use it
    if chosen.stat().st_size >= piece_length:
        piece_data = chosen.read_bytes()[:piece_length]
        if sha1_piece(piece_data) == target_piece_hash:
            if not dry_run and dst.exists() and overwrite:
                dst.unlink()
            copy_file(chosen, dst, dry_run)
            return True
    return False


def _parse_header_from_partial(tf, expected_name: str, partial_index, is_gz: bool):
    """Parse compression header from partial file."""
    cand_partial = partial_index.get(expected_name, [])
    chosen = choose_candidate(cand_partial, tf.length)
    if chosen is None:
        return None

    if is_gz:
        from .gzip import parse_gzip_header

        return parse_gzip_header(chosen)
    else:
        from .bz2 import parse_bzip2_header

        return parse_bzip2_header(chosen)


def _try_sha1_match(
    tf, raw_name: str, raw_index, header, target_piece_hash: bytes, piece_length: int, hash_algo: str, dst: Path, overwrite: bool, dry_run: bool, is_gz: bool
) -> tuple[bool, int]:
    """Try recovery using BEP47 SHA1 hash matching."""
    if not tf.sha1:
        return False, 0

    # Look for existing files with matching SHA1
    for raw_path in raw_index.get(raw_name, []):
        if raw_path.stat().st_size == tf.length:
            with raw_path.open("rb") as f:
                file_hash = hashlib.sha1(f.read()).digest()
            if file_hash == tf.sha1:
                # Found exact match by SHA1, compress it
                if is_gz:
                    from .gzip import generate_gzip_candidates, find_matching_candidate as find_gzip_candidate

                    candidates = generate_gzip_candidates(raw_path, header)
                    match_func = find_gzip_candidate
                else:
                    from .bz2 import generate_bzip2_candidates, find_matching_candidate

                    candidates = generate_bzip2_candidates(raw_path, header)
                    match_func = find_matching_candidate

                match = match_func(candidates, target_piece_hash, piece_length, hash_algo)
                if match:
                    _, data = match
                    if not dry_run and dst.exists() and overwrite:
                        dst.unlink()
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    if not dry_run:
                        dst.write_bytes(data)
                    return True, (1 if is_gz else 0)  # gzipped or bzipped
    return False, 0


def _try_brute_force_recovery(
    tf, raw_name: str, raw_index, header, target_piece_hash: bytes, piece_length: int, hash_algo: str, dst: Path, overwrite: bool, dry_run: bool, is_gz: bool
) -> tuple[bool, int]:
    """Try recovery using brute-force candidate generation."""
    cand_raw = raw_index.get(raw_name, [])
    raw_src = choose_candidate(cand_raw, None)
    if raw_src is None:
        return False, 0

    # Generate candidates and find one that matches the first piece hash
    if is_gz:
        from .gzip import generate_gzip_candidates, find_matching_candidate as find_gzip_candidate

        candidates = generate_gzip_candidates(raw_src, header)
        match_func = find_gzip_candidate
    else:
        from .bz2 import generate_bzip2_candidates, find_matching_candidate

        candidates = generate_bzip2_candidates(raw_src, header)
        match_func = find_matching_candidate

    match = match_func(candidates, target_piece_hash, piece_length, hash_algo)
    if match is None:
        return False, 0

    _, data = match
    if not dry_run and dst.exists() and overwrite:
        dst.unlink()
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dry_run:
        dst.write_bytes(data)

    return True, (1 if is_gz else 0)  # gzipped or bzipped


def recover(
    torrent_path: Path,
    raw_dir: Path,
    partial_dir: Path,
    target_dir: Path,
    *,
    raw_fallback: bool = False,
    overwrite: bool = False,
    dry_run: bool = False,
) -> Result:
    meta = parse_torrent(str(torrent_path))
    out_root = target_dir / meta.name

    partial_index = build_basename_index([partial_dir])
    raw_index = build_basename_index([raw_dir])

    recovered = 0
    gzipped = 0
    bzipped = 0
    skipped = 0
    missing = 0

    for tf in meta.files:
        expected_name = Path(tf.rel_path).name
        dst = out_root / tf.rel_path

        # Check if we should skip this file
        if _should_skip_file(tf, dst, overwrite):
            skipped += 1
            continue

        # Get piece information
        piece_info = _get_piece_info(tf, meta, meta.piece_length)
        if piece_info is None:
            missing += 1
            continue
        _, target_piece_hash = piece_info

        # Extract raw name and determine file type
        raw_name = _extract_raw_name(expected_name, tf.rel_path)
        is_gz = tf.rel_path.endswith(".gz")

        # 1) Try to find a partial file and use it as a candidate
        if _try_partial_recovery(tf, expected_name, partial_index, target_piece_hash, meta.piece_length, dst, overwrite, dry_run):
            recovered += 1
            continue

        # Parse header from partial file for brute-force
        header = _parse_header_from_partial(tf, expected_name, partial_index, is_gz)

        # 1a) Check if we have a matching file by BEP47 per-file SHA1
        sha1_success, compressed_count = _try_sha1_match(
            tf,
            raw_name,
            raw_index,
            header,
            target_piece_hash,
            meta.piece_length,
            "sha256" if meta.version in {"v2", "hybrid"} else "sha1",
            dst,
            overwrite,
            dry_run,
            is_gz,
        )
        if sha1_success:
            if is_gz:
                gzipped += compressed_count
            else:
                bzipped += compressed_count
            continue

        # 2) Find raw file for brute-force generation
        brute_force_success, compressed_count = _try_brute_force_recovery(
            tf,
            raw_name,
            raw_index,
            header,
            target_piece_hash,
            meta.piece_length,
            "sha256" if meta.version in {"v2", "hybrid"} else "sha1",
            dst,
            overwrite,
            dry_run,
            is_gz,
        )
        if brute_force_success:
            if is_gz:
                gzipped += compressed_count
            else:
                bzipped += compressed_count
            continue

        missing += 1

    return Result(
        recovered=recovered,
        gzipped=gzipped,
        bzipped=bzipped,
        skipped=skipped,
        missing=missing,
    )
