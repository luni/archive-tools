"""Tests for XZ header parsing, patching, and candidate generation."""

import shutil
import subprocess
from pathlib import Path

import pytest

from torrent_compress_recovery.xz import (
    XzHeader,
    format_xz_header,
    generate_xz_candidates,
    parse_xz_header,
    patch_xz_header,
)


def test_parse_xz_header(temp_dir: Path):
    """Test parsing XZ header from a file."""
    # Create a simple XZ file using subprocess if xz is available
    if not shutil.which("xz"):
        pytest.skip("xz tool not available")

    raw = temp_dir / "raw"
    raw.mkdir()
    src = raw / "test.txt"
    src.write_text("hello world")
    xz_path = temp_dir / "test.txt.xz"

    # Create XZ file
    result = subprocess.run(["xz", "-c", str(src)], capture_output=True, check=True)
    xz_path.write_bytes(result.stdout)

    header = parse_xz_header(xz_path)
    assert header is not None
    assert isinstance(header.flags, int)
    assert isinstance(header.has_crc64, bool)


def test_format_xz_header():
    """Test formatting XZ header for display."""
    header = XzHeader(flags=0, has_crc64=False, check_type=0)
    out = format_xz_header(header)
    assert "flags: 0" in out
    assert "has_crc64: False" in out
    assert "check_type: NONE" in out

    # Test with different check types
    header_crc64 = XzHeader(flags=0x400, has_crc64=True, check_type=4)  # check type 4 (CRC64) in stream-flag byte 7
    out_crc64 = format_xz_header(header_crc64)
    assert "check_type: CRC64" in out_crc64
    assert "has_crc64: True" in out_crc64
    assert "flag_names: CRC64" in out_crc64

    # Test with different check types
    header_crc32 = XzHeader(flags=0x100, has_crc64=False, check_type=1)
    out_crc32 = format_xz_header(header_crc32)
    assert "check_type: CRC32" in out_crc32
    assert "has_crc64: False" in out_crc32
    # No flag_names expected since no stream flags are set


def test_patch_xz_header(temp_dir: Path):
    """Test patching XZ header."""
    # Create minimal XZ-like data
    xz_magic = b"\xfd\x37\x7a\x58\x5a\x00"  # XZ magic
    stream_flags = b"\x00\x00"  # Simple flags
    crc_placeholder = b"\x00\x00\x00\x00"  # CRC32 placeholder
    data = xz_magic + stream_flags + crc_placeholder + b"some compressed data"

    # Create new header with check type 0 (NONE)
    new_header = XzHeader(flags=0, has_crc64=False, check_type=0)
    patched = patch_xz_header(data, new_header)

    # Check that stream flags were updated (byte 6 zero, check in byte 7)
    assert patched[6:8] == (new_header.check_type << 8).to_bytes(2, "little")


def test_generate_xz_candidates(temp_dir: Path):
    """Test generating XZ compression candidates."""
    if not shutil.which("xz") and not shutil.which("pixz"):
        pytest.skip("Neither xz nor pixz available")

    raw = temp_dir / "raw"
    raw.mkdir()
    src = raw / "sample.txt"
    src.write_text("sample content")

    header = XzHeader(flags=0, has_crc64=False, check_type=0)
    candidates = generate_xz_candidates(src, header)

    # Should have at least some candidates
    assert len(candidates) > 0

    # Check that candidates have labels and data
    for label, data in candidates:
        assert isinstance(label, str)
        assert isinstance(data, bytes)
        assert len(data) > 0


def test_parse_xz_header_invalid_file(temp_dir: Path):
    """Test parsing header from invalid XZ file."""
    invalid_file = temp_dir / "invalid.xz"
    invalid_file.write_bytes(b"not an xz file")

    header = parse_xz_header(invalid_file)
    assert header is None


def test_xz_header_usage_in_compression():
    """Test that header information is actually used in compression."""
    # Create minimal XZ-like data
    xz_magic = b"\xfd\x37\x7a\x58\x5a\x00"  # XZ magic
    stream_flags = b"\x00\x00"  # Simple flags
    crc_placeholder = b"\x00\x00\x00\x00"  # CRC32 placeholder
    data = xz_magic + stream_flags + crc_placeholder + b"some compressed data"

    # Test different header settings produce different results
    header1 = XzHeader(flags=0x100, has_crc64=False, check_type=1)  # CRC32
    header2 = XzHeader(flags=0x400, has_crc64=True, check_type=4)  # CRC64

    patched1 = patch_xz_header(data, header1)
    patched2 = patch_xz_header(data, header2)

    # Results should be different
    assert patched1 != patched2
    assert patched1[6:8] == (header1.check_type << 8).to_bytes(2, "little")
    assert patched2[6:8] == (header2.check_type << 8).to_bytes(2, "little")
    assert patched1[6:8] != patched2[6:8]


def test_parse_xz_header_too_small(temp_dir: Path):
    """Test parsing header from file that's too small."""
    small_file = temp_dir / "small.xz"
    small_file.write_bytes(b"\xfd\x37")  # Only partial magic

    header = parse_xz_header(small_file)
    assert header is None
