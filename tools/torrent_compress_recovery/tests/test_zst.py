"""Tests for Zstandard header parsing, patching, and candidate generation."""

import shutil
import subprocess
from pathlib import Path

import pytest

from torrent_compress_recovery.zst import (
    ZstdHeader,
    format_zstd_header,
    generate_zstd_candidates,
    parse_zstd_header,
    patch_zstd_header,
)


def test_parse_zstd_header(temp_dir: Path):
    """Test parsing Zstandard header from a file."""
    # Create a simple Zstd file using subprocess if zstd is available
    if not shutil.which("zstd"):
        pytest.skip("zstd tool not available")

    raw = temp_dir / "raw"
    raw.mkdir()
    src = raw / "test.txt"
    src.write_text("hello world")
    zst_path = temp_dir / "test.txt.zst"

    # Create Zstd file
    result = subprocess.run(["zstd", "-c", str(src)], capture_output=True, check=True)
    zst_path.write_bytes(result.stdout)

    header = parse_zstd_header(zst_path)
    assert header is not None
    assert isinstance(header.window_log, int)
    assert isinstance(header.single_segment, bool)
    assert isinstance(header.has_checksum, bool)
    assert isinstance(header.has_dict_id, bool)


def test_format_zstd_header():
    """Test formatting Zstd header for display."""
    header = ZstdHeader(window_log=10, single_segment=False, has_checksum=True, has_dict_id=False, has_reserved=False)
    out = format_zstd_header(header)
    assert "window_log: 10" in out
    assert "single_segment: False" in out
    assert "has_checksum: True" in out
    assert "has_dict_id: False" in out
    assert "has_reserved: False" in out
    assert "window_size:" in out

    # Test with flags set
    header_with_flags = ZstdHeader(window_log=15, single_segment=True, has_checksum=True, has_dict_id=True, has_reserved=False)
    out_with_flags = format_zstd_header(header_with_flags)
    assert "flag_names: SINGLE_SEGMENT, CHECKSUM, DICT_ID" in out_with_flags


def test_patch_zstd_header(temp_dir: Path):
    """Test patching a Zstd frame header preserves frame structure."""
    # Real layout: magic + descriptor(0x00 -> window desc present) + window_desc
    zstd_magic = b"\x28\xb5\x2f\xfd"
    descriptor = 0x00  # no FCS flag, no single-segment, no checksum, no dict
    window_desc = 0x00  # exponent 0, mantissa 0 -> window_log 10
    data = zstd_magic + bytes([descriptor, window_desc]) + b"some compressed data"

    # Compatible patch: same layout, larger window -> descriptor unchanged,
    # window descriptor updated (window_log 20 -> exponent 10 -> 10 << 3)
    new_header = ZstdHeader(window_log=20, single_segment=False, has_checksum=False, has_dict_id=False, has_reserved=False)
    patched = patch_zstd_header(data, new_header)
    assert patched[4] == descriptor
    assert patched[5] == (20 - 10) << 3
    assert patched[6:] == data[6:]

    # Incompatible patch: toggling the checksum flag changes the trailer ->
    # cannot be patched without recompressing, data must be returned unchanged
    checksum_header = ZstdHeader(window_log=20, single_segment=False, has_checksum=True, has_dict_id=False, has_reserved=False)
    assert patch_zstd_header(data, checksum_header) == data

    # Layout change: single-segment needs a mandatory FCS byte we don't have
    ss_header = ZstdHeader(window_log=20, single_segment=True, has_checksum=False, has_dict_id=False, has_reserved=False)
    assert patch_zstd_header(data, ss_header) == data


def test_generate_zstd_candidates(temp_dir: Path):
    """Test generating Zstd compression candidates."""
    if not shutil.which("zstd") and not shutil.which("pzstd"):
        pytest.skip("Neither zstd nor pzstd available")

    raw = temp_dir / "raw"
    raw.mkdir()
    src = raw / "sample.txt"
    src.write_text("sample content")

    header = ZstdHeader(window_log=10, single_segment=False, has_checksum=True, has_dict_id=False, has_reserved=False)
    candidates = generate_zstd_candidates(src, header)

    # Should have at least some candidates
    assert len(candidates) > 0

    # Check that candidates have labels and data
    for label, data in candidates:
        assert isinstance(label, str)
        assert isinstance(data, bytes)
        assert len(data) > 0


def test_parse_zstd_header_invalid_file(temp_dir: Path):
    """Test parsing header from invalid Zstd file."""
    invalid_file = temp_dir / "invalid.zst"
    invalid_file.write_bytes(b"not a zstd file")

    header = parse_zstd_header(invalid_file)
    assert header is None


def test_parse_zstd_header_too_small(temp_dir: Path):
    """Test parsing header from file that's too small."""
    small_file = temp_dir / "small.zst"
    small_file.write_bytes(b"\x28\xb5")  # Only partial magic

    header = parse_zstd_header(small_file)
    assert header is None


def test_zstd_header_usage_in_compression():
    """Test that header information is actually used in patching."""
    # Real layout: magic + descriptor + window descriptor + payload
    zstd_magic = b"\x28\xb5\x2f\xfd"
    data = zstd_magic + b"\x00\x00" + b"some compressed data"

    # Two compatible targets produce different window descriptors
    header1 = ZstdHeader(window_log=10, single_segment=False, has_checksum=False, has_dict_id=False, has_reserved=False)
    header2 = ZstdHeader(window_log=15, single_segment=False, has_checksum=False, has_dict_id=False, has_reserved=False)

    patched1 = patch_zstd_header(data, header1)
    patched2 = patch_zstd_header(data, header2)

    assert patched1 != patched2
    # Descriptor byte stays the same, window descriptor differs
    assert patched1[4] == patched2[4] == 0x00
    assert patched1[5] == (10 - 10) << 3
    assert patched2[5] == (15 - 10) << 3


def test_zstd_header_flags_parsing():
    """Test parsing different Zstd header flags."""
    # Test various flag combinations
    header = ZstdHeader(window_log=15, single_segment=True, has_checksum=True, has_dict_id=False, has_reserved=False)
    assert header.window_log == 15
    assert header.single_segment is True
    assert header.has_checksum is True
    assert header.has_dict_id is False

    formatted = format_zstd_header(header)
    assert "window_log: 15" in formatted
    assert "single_segment: True" in formatted
    assert "has_checksum: True" in formatted
    assert "has_dict_id: False" in formatted
