"""Extended tests for verify module to improve coverage."""

import gzip
import zlib
from pathlib import Path

import pytest

from torrent_compress_recovery.verify import (
    compute_raw_crc32_and_isize,
    read_gzip_trailer,
    verify_last_piece_against_raw,
    verify_raw_against_gz,
)


def test_read_gzip_trailer_valid_file(tmp_path: Path):
    """Test reading gzip trailer from a valid gzip file."""
    # Create a simple gzip file with known trailer
    gz_file = tmp_path / "test.gz"
    with gzip.open(gz_file, "wb") as f:
        f.write(b"test content")

    trailer = read_gzip_trailer(gz_file)
    assert trailer is not None
    assert isinstance(trailer, tuple)
    assert len(trailer) == 2
    crc32, isize = trailer
    assert isinstance(crc32, int)
    assert isinstance(isize, int)


def test_read_gzip_trailer_file_too_small(tmp_path: Path):
    """Test reading trailer from file smaller than 8 bytes."""
    small_file = tmp_path / "small.gz"
    small_file.write_bytes(b"small")

    trailer = read_gzip_trailer(small_file)
    assert trailer is None


def test_read_gzip_trailer_exactly_8_bytes(tmp_path: Path):
    """Test reading trailer from file exactly 8 bytes."""
    # Create exactly 8 bytes
    exactly_8_file = tmp_path / "exact.gz"
    exactly_8_file.write_bytes(b"a" * 8)

    trailer = read_gzip_trailer(exactly_8_file)
    assert trailer is not None
    crc32, isize = trailer
    # Should read the 8 bytes as trailer
    assert crc32 == int.from_bytes(b"a" * 4, "little")
    assert isize == int.from_bytes(b"a" * 4, "little")


def test_read_gzip_trailer_nonexistent_file(tmp_path: Path):
    """Test reading trailer from nonexistent file."""
    nonexistent = tmp_path / "nonexistent.gz"

    with pytest.raises(FileNotFoundError):
        read_gzip_trailer(nonexistent)


def test_compute_raw_crc32_and_isize_empty_file(tmp_path: Path):
    """Test computing CRC32 and size for empty file."""
    empty_file = tmp_path / "empty.txt"
    empty_file.write_bytes(b"")

    crc32, isize = compute_raw_crc32_and_isize(empty_file)
    assert crc32 == 0
    assert isize == 0


def test_compute_raw_crc32_and_isize_small_file(tmp_path: Path):
    """Test computing CRC32 and size for small file."""
    small_file = tmp_path / "small.txt"
    content = b"hello world"
    small_file.write_bytes(content)

    crc32, isize = compute_raw_crc32_and_isize(small_file)
    assert crc32 == zlib.crc32(content) & 0xFFFFFFFF
    assert isize == len(content)


def test_compute_raw_crc32_and_isize_large_file(tmp_path: Path):
    """Test computing CRC32 and size for file larger than one chunk."""
    large_file = tmp_path / "large.txt"
    # Create content larger than 8192 bytes (chunk size)
    content = b"x" * 10000
    large_file.write_bytes(content)

    crc32, isize = compute_raw_crc32_and_isize(large_file)
    expected_crc32 = zlib.crc32(content) & 0xFFFFFFFF
    assert crc32 == expected_crc32
    assert isize == len(content)


def test_compute_raw_crc32_and_isize_nonexistent_file(tmp_path: Path):
    """Test computing CRC32 for nonexistent file."""
    nonexistent = tmp_path / "nonexistent.txt"

    with pytest.raises(FileNotFoundError):
        compute_raw_crc32_and_isize(nonexistent)


def test_verify_raw_against_gz_valid_match(tmp_path: Path):
    """Test verification when raw file matches gzip trailer."""
    # Create raw content
    content = b"test content for verification"
    raw_file = tmp_path / "test.txt"
    raw_file.write_bytes(content)

    # Create corresponding gzip file
    gz_file = tmp_path / "test.txt.gz"
    with gzip.open(gz_file, "wb") as f:
        f.write(content)

    result = verify_raw_against_gz(raw_file, gz_file)
    assert result is True


def test_verify_raw_against_gz_invalid_trailer(tmp_path: Path):
    """Test verification when gzip trailer is invalid."""
    raw_file = tmp_path / "test.txt"
    raw_file.write_bytes(b"test content")

    # Create invalid gzip file (too small)
    gz_file = tmp_path / "test.txt.gz"
    gz_file.write_bytes(b"invalid")

    result = verify_raw_against_gz(raw_file, gz_file)
    assert result is False


def test_verify_raw_against_gz_content_mismatch(tmp_path: Path):
    """Test verification when content doesn't match."""
    raw_file = tmp_path / "test.txt"
    raw_file.write_bytes(b"different content")

    # Create gzip file with different content
    gz_file = tmp_path / "test.txt.gz"
    with gzip.open(gz_file, "wb") as f:
        f.write(b"original content")

    result = verify_raw_against_gz(raw_file, gz_file)
    assert result is False


def test_verify_raw_against_gz_nonexistent_raw(tmp_path: Path):
    """Test verification when raw file doesn't exist."""
    nonexistent_raw = tmp_path / "nonexistent.txt"

    gz_file = tmp_path / "nonexistent.txt.gz"
    with gzip.open(gz_file, "wb") as f:
        f.write(b"content")

    with pytest.raises(FileNotFoundError):
        verify_raw_against_gz(nonexistent_raw, gz_file)


def test_verify_raw_against_gz_nonexistent_gz(tmp_path: Path):
    """Test verification when gzip file doesn't exist."""
    raw_file = tmp_path / "test.txt"
    raw_file.write_bytes(b"content")

    nonexistent_gz = tmp_path / "nonexistent.gz"

    with pytest.raises(FileNotFoundError):
        verify_raw_against_gz(raw_file, nonexistent_gz)


def test_verify_last_piece_against_raw_no_gz_files(tmp_path: Path):
    """Test verification when torrent has no .gz files."""
    # Create a torrent with non-gz files
    from torrent_compress_recovery.bencode import TorrentFile, TorrentMeta

    meta = TorrentMeta(
        name="test",
        files=[
            TorrentFile("file1.txt", 1024, 0),
            TorrentFile("file2.dat", 2048, 1024),
        ],
        piece_length=524288,
        pieces=[b"a" * 20],
        version="v1",
    )

    torrent_file = tmp_path / "test.torrent"
    # Create a minimal valid torrent file
    import bencodepy

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 20,
                b"files": [
                    {b"length": 1024, b"path": [b"file1.txt"]},
                    {b"length": 2048, b"path": [b"file2.dat"]},
                ],
            }
        }
    )
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {}


def test_verify_last_piece_against_raw_no_partial_file(tmp_path: Path):
    """Test verification when partial file doesn't exist."""
    import bencodepy

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 20,
                b"files": [
                    {b"length": 1024, b"path": [b"test.txt.gz"]},
                ],
            }
        }
    )
    torrent_file = tmp_path / "test.torrent"
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {}


def test_verify_last_piece_against_raw_incomplete_file(tmp_path: Path):
    """Test verification when partial file is incomplete."""
    import bencodepy

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 20,
                b"files": [
                    {b"length": 1024, b"path": [b"test.txt.gz"]},
                ],
            }
        }
    )
    torrent_file = tmp_path / "test.torrent"
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Create partial file that's smaller than expected
    partial_file = partial_dir / "test.txt.gz"
    partial_file.write_bytes(b"partial")  # Much smaller than 1024

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {}


def test_verify_last_piece_against_raw_no_raw_file(tmp_path: Path):
    """Test verification when raw file doesn't exist."""
    import bencodepy

    # Create content and gzip it to get actual size
    content = b"test content"
    gz_file = tmp_path / "test.txt.gz"
    with gzip.open(gz_file, "wb") as f:
        f.write(content)

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 20,
                b"files": [
                    {b"length": gz_file.stat().st_size, b"path": [b"test.txt.gz"]},
                ],
            }
        }
    )
    torrent_file = tmp_path / "test.torrent"
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Copy the gz file to partial dir
    partial_file = partial_dir / "test.txt.gz"
    partial_file.write_bytes(gz_file.read_bytes())

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {"test.txt.gz": False}


def test_verify_last_piece_against_raw_successful_verification(tmp_path: Path):
    """Test successful verification of multiple files."""
    import bencodepy

    # Create content and gzip files to get actual sizes
    content1 = b"content for file1"
    content2 = b"content for file2"
    gz_file1 = tmp_path / "file1.txt.gz"
    gz_file2 = tmp_path / "file2.txt.gz"
    with gzip.open(gz_file1, "wb") as f:
        f.write(content1)
    with gzip.open(gz_file2, "wb") as f:
        f.write(content2)

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 40,  # 2 pieces
                b"files": [
                    {b"length": gz_file1.stat().st_size, b"path": [b"file1.txt.gz"]},
                    {b"length": gz_file2.stat().st_size, b"path": [b"file2.txt.gz"]},
                ],
            }
        }
    )
    torrent_file = tmp_path / "test.torrent"
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Create raw files
    (raw_dir / "file1.txt").write_bytes(content1)
    (raw_dir / "file2.txt").write_bytes(content2)

    # Copy matching partial files
    partial_file1 = partial_dir / "file1.txt.gz"
    partial_file2 = partial_dir / "file2.txt.gz"
    partial_file1.write_bytes(gz_file1.read_bytes())
    partial_file2.write_bytes(gz_file2.read_bytes())

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {"file1.txt.gz": True, "file2.txt.gz": True}


def test_verify_last_piece_against_raw_mixed_results(tmp_path: Path):
    """Test verification with mixed success/failure results."""
    import bencodepy

    # Create content and gzip files to get actual sizes
    good_content = b"good content"
    bad_raw_content = b"raw content"
    bad_gz_content = b"different content"

    good_gz_file = tmp_path / "good.txt.gz"
    bad_gz_file = tmp_path / "bad.txt.gz"

    with gzip.open(good_gz_file, "wb") as f:
        f.write(good_content)
    with gzip.open(bad_gz_file, "wb") as f:
        f.write(bad_gz_content)

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 40,
                b"files": [
                    {b"length": good_gz_file.stat().st_size, b"path": [b"good.txt.gz"]},
                    {b"length": bad_gz_file.stat().st_size, b"path": [b"bad.txt.gz"]},
                    {b"length": 300, b"path": [b"missing.txt.gz"]},  # This one won't exist
                ],
            }
        }
    )
    torrent_file = tmp_path / "test.torrent"
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Create matching files for good.txt
    (raw_dir / "good.txt").write_bytes(good_content)
    partial_file = partial_dir / "good.txt.gz"
    partial_file.write_bytes(good_gz_file.read_bytes())

    # Create mismatching files for bad.txt
    (raw_dir / "bad.txt").write_bytes(bad_raw_content)
    partial_file = partial_dir / "bad.txt.gz"
    partial_file.write_bytes(bad_gz_file.read_bytes())

    # missing.txt.gz doesn't exist

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {"good.txt.gz": True, "bad.txt.gz": False}


def test_verify_last_piece_against_raw_file_without_length(tmp_path: Path):
    """Test verification when torrent file has no length (None)."""
    import bencodepy

    torrent_data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 20,
                b"files": [
                    {b"path": [b"no_length.txt.gz"]},  # No length field
                ],
            }
        }
    )
    torrent_file = tmp_path / "test.torrent"
    torrent_file.write_bytes(torrent_data)

    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Create partial file
    partial_file = partial_dir / "no_length.txt.gz"
    with gzip.open(partial_file, "wb") as f:
        f.write(b"content")

    results = verify_last_piece_against_raw(torrent_file, raw_dir, partial_dir)
    assert results == {}  # Should skip files without length
