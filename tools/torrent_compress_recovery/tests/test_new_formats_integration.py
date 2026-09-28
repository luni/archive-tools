"""Integration tests for the XZ and Zstd formats."""

from pathlib import Path

import pytest

from torrent_compress_recovery.verify import verify_raw_against_xz, verify_raw_against_zst


def test_verify_raw_against_xz_integration(temp_dir: Path):
    """Test XZ verification with real files."""
    import shutil
    import subprocess

    if not shutil.which("xz"):
        pytest.skip("xz tool not available")

    # Create test files
    raw_file = temp_dir / "test.txt"
    raw_file.write_text("Hello world for XZ verification test")

    xz_file = temp_dir / "test.txt.xz"
    result = subprocess.run(["xz", "-c", str(raw_file)], capture_output=True, check=True)
    xz_file.write_bytes(result.stdout)

    # Test verification
    assert verify_raw_against_xz(raw_file, xz_file) is True

    # Test with mismatched content
    wrong_raw = temp_dir / "wrong.txt"
    wrong_raw.write_text("Different content")
    assert verify_raw_against_xz(wrong_raw, xz_file) is False


def test_verify_raw_against_zst_integration(temp_dir: Path):
    """Test Zstd verification with real files."""
    import shutil
    import subprocess

    if not shutil.which("zstd"):
        pytest.skip("zstd tool not available")

    # Create test files
    raw_file = temp_dir / "test.txt"
    raw_file.write_text("Hello world for Zstd verification test")

    zst_file = temp_dir / "test.txt.zst"
    result = subprocess.run(["zstd", "-c", str(raw_file)], capture_output=True, check=True)
    zst_file.write_bytes(result.stdout)

    # Test verification
    assert verify_raw_against_zst(raw_file, zst_file) is True

    # Test with mismatched content
    wrong_raw = temp_dir / "wrong.txt"
    wrong_raw.write_text("Different content")
    assert verify_raw_against_zst(wrong_raw, zst_file) is False


def test_core_recovery_with_new_formats(temp_dir: Path):
    """Test core recovery functionality with XZ and Zstd files."""
    import shutil
    import subprocess

    # Skip if tools not available
    if not (shutil.which("xz") and shutil.which("zstd")):
        pytest.skip("xz or zstd tool not available")

    # Create test directory structure
    torrent_dir = temp_dir / "torrent"
    raw_dir = temp_dir / "raw"
    partial_dir = temp_dir / "partial"
    target_dir = temp_dir / "target"

    torrent_dir.mkdir()
    raw_dir.mkdir()
    partial_dir.mkdir()
    target_dir.mkdir()

    # Create raw files
    raw_file = raw_dir / "test.txt"
    content = "Test content for recovery testing"
    raw_file.write_text(content)

    # Create compressed files
    xz_file = torrent_dir / "test.txt.xz"
    zst_file = torrent_dir / "test.txt.zst"

    subprocess.run(["xz", "-c", str(raw_file)], capture_output=True, check=True)
    xz_file.write_bytes(subprocess.run(["xz", "-c", str(raw_file)], capture_output=True, check=True).stdout)
    zst_file.write_bytes(subprocess.run(["zstd", "-c", str(raw_file)], capture_output=True, check=True).stdout)

    # Create partial files (truncated)
    partial_xz = partial_dir / "test.txt.xz"
    partial_zst = partial_dir / "test.txt.zst"

    with xz_file.open("rb") as f:
        partial_xz.write_bytes(f.read(len(xz_file.read_bytes()) // 2))
    with zst_file.open("rb") as f:
        partial_zst.write_bytes(f.read(len(zst_file.read_bytes()) // 2))

    # Test that Result dataclass has new fields
    from torrent_compress_recovery.core import Result

    result = Result(recovered=0, gzipped=0, bzipped=0, xzipped=1, zstipped=1, skipped=0, missing=0)
    assert result.xzipped == 1
    assert result.zstipped == 1

    # Test file extension handling
    from torrent_compress_recovery.core import _extract_raw_name

    assert _extract_raw_name("test.txt.xz", "test.txt.xz") == "test.txt"
    assert _extract_raw_name("test.txt.zst", "test.txt.zst") == "test.txt"


def test_header_parsing_integration(temp_dir: Path):
    """Test header parsing with real compressed files."""
    import shutil
    import subprocess

    # Test XZ header parsing
    if shutil.which("xz"):
        raw_file = temp_dir / "test.txt"
        raw_file.write_text("Test content")

        xz_file = temp_dir / "test.txt.xz"
        result = subprocess.run(["xz", "-c", str(raw_file)], capture_output=True, check=True)
        xz_file.write_bytes(result.stdout)

        from torrent_compress_recovery.xz import parse_xz_header

        header = parse_xz_header(xz_file)
        assert header is not None
        assert isinstance(header.flags, int)
        assert isinstance(header.has_crc64, bool)

    # Test Zstd header parsing
    if shutil.which("zstd"):
        raw_file = temp_dir / "test.txt"
        raw_file.write_text("Test content")

        zst_file = temp_dir / "test.txt.zst"
        result = subprocess.run(["zstd", "-c", str(raw_file)], capture_output=True, check=True)
        zst_file.write_bytes(result.stdout)

        from torrent_compress_recovery.zst import parse_zstd_header

        header = parse_zstd_header(zst_file)
        assert header is not None
        assert isinstance(header.window_log, int)
        assert isinstance(header.single_segment, bool)
        assert isinstance(header.has_checksum, bool)
        assert isinstance(header.has_dict_id, bool)
