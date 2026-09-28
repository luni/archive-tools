"""Step B: Verify raw files against compression trailers using last piece."""

import subprocess  # nosec B404
import zlib
from pathlib import Path

from .bencode import parse_torrent
from .core import _extract_raw_name, build_basename_index

# Gzip trailer constants
GZIP_TRAILER_SIZE = 8
GZIP_CRC32_SIZE = 4
GZIP_ISIZE_SIZE = 4


def read_gzip_trailer(path: Path) -> tuple[int, int] | None:
    """Read CRC32 and ISIZE from the last 8 bytes of a gzip file."""
    # Check file size first - files smaller than 8 bytes are broken
    file_size = path.stat().st_size
    if file_size < GZIP_TRAILER_SIZE:
        return None

    with path.open("rb") as f:
        f.seek(-GZIP_TRAILER_SIZE, 2)  # Seek 8 bytes from end
        trailer = f.read()
    if len(trailer) != GZIP_TRAILER_SIZE:
        return None
    crc32 = int.from_bytes(trailer[:GZIP_CRC32_SIZE], "little")
    isize = int.from_bytes(trailer[GZIP_CRC32_SIZE:], "little")
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


def verify_raw_against_xz(raw_path: Path, xz_path: Path) -> bool:
    """Verify raw file matches XZ footer (basic validation)."""
    # For XZ, we'll do a basic check by decompressing and comparing
    # This is a simplified verification - real XZ verification is more complex
    try:
        # Try to decompress and compare sizes
        result = subprocess.run(["xz", "-dc", str(xz_path)], capture_output=True, check=True)  # nosec B603, B607
        decompressed = result.stdout
        raw_data = raw_path.read_bytes()
        return decompressed == raw_data
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def verify_raw_against_zst(raw_path: Path, zst_path: Path) -> bool:
    """Verify raw file matches Zstandard frame (basic validation)."""
    # For Zstd, we'll do a basic check by decompressing and comparing
    try:
        # Try to decompress and compare sizes
        result = subprocess.run(["zstd", "-dc", str(zst_path)], capture_output=True, check=True)  # nosec B603, B607
        decompressed = result.stdout
        raw_data = raw_path.read_bytes()
        return decompressed == raw_data
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def verify_last_piece_against_raw(torrent_path: Path, raw_dir: Path, partial_dir: Path) -> dict[str, bool]:
    """
    For each compressed file in the torrent, if the last piece exists in partial_dir,
    extract the footer/trailer and compare to the corresponding raw file.
    Returns a mapping from filename to verification result.
    """
    meta = parse_torrent(str(torrent_path))
    partial_index = build_basename_index([partial_dir])
    raw_index = build_basename_index([raw_dir])
    results: dict[str, bool] = {}
    for tf in meta.files:
        filename = Path(tf.rel_path).name
        ext = Path(tf.rel_path).suffix.lower()
        if ext not in (".gz", ".bz2", ".xz", ".zst"):
            continue

        # Largest partial candidate (may live in a subdirectory)
        live_partials = []
        for p in partial_index.get(filename, []):
            try:
                live_partials.append((p, p.stat().st_size))
            except OSError:
                continue
        if not live_partials:
            continue
        partial_file, partial_size = max(live_partials, key=lambda x: x[1])

        # The trailer is only comparable once the download is complete
        if tf.length is None or partial_size < tf.length:
            continue

        # For bzip2 we have no simple trailer check; skip it
        if ext == ".bz2":
            continue
        verify_func = {".gz": verify_raw_against_gz, ".xz": verify_raw_against_xz, ".zst": verify_raw_against_zst}[ext]

        raw_name = _extract_raw_name(filename, tf.rel_path)
        raw_candidates = raw_index.get(raw_name, [])
        if not raw_candidates:
            results[filename] = False
            continue

        try:
            results[filename] = verify_func(raw_candidates[0], partial_file)
        except OSError:
            results[filename] = False

    return results
