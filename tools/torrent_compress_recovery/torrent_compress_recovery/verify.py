"""Step B: Verify raw files against gzip trailer (CRC32/ISIZE) using last piece."""

import zlib
from pathlib import Path

from .bencode import parse_torrent


def read_gzip_trailer(path: Path) -> tuple[int, int] | None:
    """Read CRC32 and ISIZE from the last 8 bytes of a gzip file."""
    # Check file size first - files smaller than 8 bytes are broken
    file_size = path.stat().st_size
    if file_size < 8:
        return None

    with path.open("rb") as f:
        f.seek(-8, 2)  # Seek 8 bytes from end
        trailer = f.read()
    if len(trailer) != 8:
        return None
    crc32 = int.from_bytes(trailer[:4], "little")
    isize = int.from_bytes(trailer[4:], "little")
    return crc32, isize


def compute_raw_crc32_and_isize(raw_path: Path) -> tuple[int, int]:
    """Compute CRC32 and size (mod 2^32) of raw data."""
    crc = 0
    size = 0
    with raw_path.open("rb") as f:
        while chunk := f.read(8192):
            crc = zlib.crc32(chunk, crc) & 0xFFFFFFFF
            size += len(chunk)
    return crc, size & 0xFFFFFFFF


def verify_raw_against_gz(raw_path: Path, gz_path: Path) -> bool:
    """Verify raw file matches gzip trailer (CRC32/ISIZE)."""
    trailer = read_gzip_trailer(gz_path)
    if trailer is None:
        return False
    gz_crc32, gz_isize = trailer
    raw_crc32, raw_isize = compute_raw_crc32_and_isize(raw_path)
    return gz_crc32 == raw_crc32 and gz_isize == raw_isize


def verify_last_piece_against_raw(torrent_path: Path, raw_dir: Path, partial_dir: Path) -> dict[str, bool]:
    """
    For each .gz in the torrent, if the last piece exists in partial_dir,
    extract the trailer and compare to the corresponding raw file.
    Returns a mapping from filename to verification result.
    """
    meta = parse_torrent(str(torrent_path))
    results: dict[str, bool] = {}
    for tf in meta.files:
        if not tf.rel_path.endswith(".gz"):
            continue
        gz_name = Path(tf.rel_path).name
        gz_partial = partial_dir / gz_name
        if not gz_partial.is_file():
            continue
        # Determine if we have the last piece (file size >= tf.length)
        if tf.length is None:
            continue
        if gz_partial.stat().st_size < tf.length:
            continue
        # Try to read the last 8 bytes (trailer)
        trailer = read_gzip_trailer(gz_partial)
        if trailer is None:
            results[gz_name] = False
            continue
        gz_crc32, gz_isize = trailer
        # Find corresponding raw file
        raw_name = gz_name[: -len(".gz")]
        raw_path = raw_dir / raw_name
        if not raw_path.is_file():
            results[gz_name] = False
            continue
        raw_crc32, raw_isize = compute_raw_crc32_and_isize(raw_path)
        results[gz_name] = gz_crc32 == raw_crc32 and gz_isize == raw_isize
    return results
