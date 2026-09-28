"""Extended tests for gzip module to improve coverage."""

from pathlib import Path

from torrent_compress_recovery.gzip import (
    _get_flag_names,
    _safe_decode_bytes,
    parse_gzip_header,
)


def test_safe_decode_bytes():
    """Test safe byte decoding."""
    # Test valid UTF-8
    assert _safe_decode_bytes(b"hello") == "hello"

    # Test invalid UTF-8 with fallback
    invalid_bytes = b"\xff\xfe\xfd"
    result = _safe_decode_bytes(invalid_bytes)
    assert result is not None
    assert isinstance(result, str)

    # Test empty bytes
    assert _safe_decode_bytes(b"") == ""


def test_get_flag_names():
    """Test flag name extraction."""
    # Test no flags
    flag_names = _get_flag_names(0x00)
    assert flag_names == []

    # Test some flags
    flag_names = _get_flag_names(0x04)  # FEXTRA
    assert "FEXTRA" in flag_names

    flag_names = _get_flag_names(0x08)  # FNAME
    assert "FNAME" in flag_names

    flag_names = _get_flag_names(0x10)  # FCOMMENT
    assert "FCOMMENT" in flag_names


def test_parse_gzip_header_invalid_file(tmp_path: Path):
    """Test parsing gzip header from invalid file."""
    invalid_file = tmp_path / "invalid.gz"
    invalid_file.write_bytes(b"not a gzip file")

    header = parse_gzip_header(invalid_file)
    assert header is None


def test_parse_gzip_header_too_small(tmp_path: Path):
    """Test parsing gzip header from file that's too small."""
    small_file = tmp_path / "small.gz"
    small_file.write_bytes(b"\x1f\x8b")  # Only magic bytes

    header = parse_gzip_header(small_file)
    assert header is None
