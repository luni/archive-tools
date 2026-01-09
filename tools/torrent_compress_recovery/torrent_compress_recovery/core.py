"""Core recovery logic: match torrent files against input folders."""

import hashlib
import os
import shutil
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from .bencode import parse_torrent
from .bz2 import find_matching_candidate, generate_bzip2_candidates, parse_bzip2_header, sha1_piece
from .gzip import find_matching_candidate as find_gzip_candidate
from .gzip import generate_gzip_candidates, parse_gzip_header


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
        # Skip padding files (BEP47)
        if tf.attr and "p" in tf.attr:
            skipped += 1
            continue

        # Handle .gz and .bz2 files (skip symlinks and other files)
        if not (tf.rel_path.endswith(".gz") or tf.rel_path.endswith(".bz2")):
            skipped += 1
            continue

        expected_name = Path(tf.rel_path).name
        dst = out_root / tf.rel_path

        if dst.exists() and not overwrite:
            skipped += 1
            continue

        # Determine which piece contains the start of this file
        if tf.offset is None or tf.length is None:
            missing += 1
            continue
        start_piece_index = tf.offset // meta.piece_length
        if start_piece_index >= len(meta.pieces):
            missing += 1
            continue
        target_piece_hash = meta.pieces[start_piece_index]

        # Determine file type and get raw name
        is_gz = tf.rel_path.endswith(".gz")
        if is_gz:
            raw_name = expected_name[: -len(".gz")]
        # Handle double extensions like .bz1.bz2, .pbz6.bz2, etc.
        elif expected_name.endswith(".bz2"):
            # Remove the last .bz2 extension
            without_bz2 = expected_name[: -len(".bz2")]
            # Check if there's another compression extension
            if without_bz2.endswith((".bz1", ".bz6", ".bz9", ".pbz1", ".pbz6", ".pbz9")):
                # Remove the compression level extension too
                if without_bz2.endswith((".bz1", ".bz6", ".bz9")):
                    raw_name = without_bz2[:-4]  # Remove .bzX
                else:  # .pbzX
                    raw_name = without_bz2[:-5]  # Remove .pbzX
            else:
                raw_name = without_bz2
        else:
            raw_name = expected_name

        # 1) Try to find a partial file and use it as a candidate
        cand_partial = partial_index.get(expected_name, [])
        chosen = choose_candidate(cand_partial, tf.length)
        if chosen is not None:
            # If the partial file is complete and matches the first piece, use it
            if chosen.stat().st_size >= meta.piece_length:
                piece_data = chosen.read_bytes()[: meta.piece_length]
                if sha1_piece(piece_data) == target_piece_hash:
                    if not dry_run and dst.exists() and overwrite:
                        dst.unlink()
                    copy_file(chosen, dst, dry_run)
                    recovered += 1
                    continue
            # Otherwise, use it to extract header settings for brute-force
            if is_gz:
                header = parse_gzip_header(chosen)
            else:  # is_bz2
                header = parse_bzip2_header(chosen)
        else:
            header = None

        # 1a) Check if we have a matching file by BEP47 per-file SHA1
        if tf.sha1:
            # Look for existing files with matching SHA1
            for raw_path in raw_index.get(raw_name, []):
                if raw_path.stat().st_size == tf.length:
                    with raw_path.open("rb") as f:
                        file_hash = hashlib.sha1(f.read()).digest()
                    if file_hash == tf.sha1:
                        # Found exact match by SHA1, compress it
                        if is_gz:
                            candidates = generate_gzip_candidates(raw_path, header)
                            match_func = find_gzip_candidate
                        else:  # is_bz2
                            candidates = generate_bzip2_candidates(raw_path, header)
                            match_func = find_matching_candidate
                        hash_algo = "sha256" if meta.version in {"v2", "hybrid"} else "sha1"
                        match = match_func(candidates, target_piece_hash, meta.piece_length, hash_algo)
                        if match:
                            _, data = match
                            if not dry_run and dst.exists() and overwrite:
                                dst.unlink()
                            dst.parent.mkdir(parents=True, exist_ok=True)
                            if not dry_run:
                                dst.write_bytes(data)
                            if is_gz:
                                gzipped += 1
                            else:  # is_bz2
                                bzipped += 1
                            continue

        # 2) Find raw file for brute-force generation
        cand_raw = raw_index.get(raw_name, [])
        raw_src = choose_candidate(cand_raw, None)
        if raw_src is None:
            missing += 1
            continue

        # 3) Generate candidates and find one that matches the first piece hash
        if is_gz:
            candidates = generate_gzip_candidates(raw_src, header)
            match_func = find_gzip_candidate
        else:  # is_bz2
            candidates = generate_bzip2_candidates(raw_src, header)
            match_func = find_matching_candidate
        hash_algo = "sha256" if meta.version in {"v2", "hybrid"} else "sha1"
        match = match_func(candidates, target_piece_hash, meta.piece_length, hash_algo)
        if match is None:
            missing += 1
            continue
        _, data = match
        if not dry_run and dst.exists() and overwrite:
            dst.unlink()
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dry_run:
            dst.write_bytes(data)
        if is_gz:
            gzipped += 1
        else:  # is_bz2
            bzipped += 1

    return Result(
        recovered=recovered,
        gzipped=gzipped,
        bzipped=bzipped,
        skipped=skipped,
        missing=missing,
    )
