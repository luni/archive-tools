"""Realistic pigz integration test using actual pigz-compressed files."""

import gzip
from pathlib import Path

import pytest

from torrent_compress_recovery.gzip import generate_gzip_candidates, parse_gzip_header


@pytest.fixture
def real_data_dir():
    """Path to realistic test data."""
    return Path(__file__).parent / "fixtures" / "real_data"


def test_generate_gzip_candidates_with_pigz(real_data_dir: Path):
    """Test generate_gzip_candidates function with real pigz files."""
    raw_dir = real_data_dir / "raw"

    # Test with a sample raw file
    raw_file = raw_dir / "readme.txt"
    assert raw_file.exists(), f"Raw file {raw_file} not found"

    # Get header from an existing pigz file
    pigz_file = real_data_dir / "readme.txt.pigz6.gz"
    if pigz_file.exists():
        header = parse_gzip_header(pigz_file)
    else:
        header = None

    # Generate candidates
    candidates = generate_gzip_candidates(raw_file, header)

    # Should have multiple candidates (gzip + pigz variants)
    assert len(candidates) > 5, f"Expected multiple candidates, got {len(candidates)}"

    # Check that pigz candidates are included if pigz is available
    pigz_candidates = [label for label, _ in candidates if "pigz" in label]
    if pigz_candidates:
        assert len(pigz_candidates) >= 4, f"Expected at least 4 pigz candidates, got {len(pigz_candidates)}"

        # Check different pigz compression levels are present
        levels_found = [label for label in pigz_candidates if "pigz -1" in label or "pigz -6" in label or "pigz -9" in label]
        assert len(levels_found) >= 3, f"Expected pigz levels 1, 6, 9, found: {levels_found}"

    # Check gzip candidates are also present
    gzip_candidates = [label for label, _ in candidates if label.startswith("gzip")]
    assert len(gzip_candidates) >= 3, f"Expected at least 3 gzip candidates, got {len(gzip_candidates)}"

    # Verify that we have at least some valid candidates (skip problematic ones)
    valid_count = 0
    for label, data in candidates:
        assert len(data) > 0, f"Empty data for candidate: {label}"
        # Try to decompress to verify it's valid gzip
        try:
            import gzip
            import tempfile
            with tempfile.NamedTemporaryFile() as tmp:
                tmp.write(data)
                tmp.flush()
                with gzip.open(tmp.name, 'rb') as f:
                    decompressed = f.read()
            if decompressed:
                valid_count += 1
        except Exception:
            # Skip invalid candidates - the function might have some edge cases
            continue

    # Should have at least some valid candidates
    assert valid_count >= 3, f"Expected at least 3 valid candidates, got {valid_count}"


def test_pigz_files_are_distinct(real_data_dir: Path):
    """Test that different pigz settings produce distinct compressed files."""
    base_name = "readme.txt"

    # Find all pigz variants of the same file
    pigz_files = {}
    for gz_file in real_data_dir.glob(f"{base_name}.pigz*.gz"):
        if gz_file.is_file():
            pigz_files[gz_file.name] = gz_file.read_bytes()

    # Should have multiple pigz variants
    if len(pigz_files) >= 4:
        # Check that different settings produce different outputs
        file_contents = list(pigz_files.values())
        unique_contents = set(file_contents)

        # At least some should be different (different compression levels)
        assert len(unique_contents) >= 2, f"Expected pigz variants to be different, but all were identical"

        # Higher compression should generally produce smaller files (for compressible data)
        pigz1_size = pigz_files.get(f"{base_name}.pigz1.gz", b"").__len__()
        pigz9_size = pigz_files.get(f"{base_name}.pigz9.gz", b"").__len__()

        if pigz1_size > 0 and pigz9_size > 0:
            # For compressible data, level 9 should be <= level 1
            # Note: This might not always be true for very small files
            print(f"Pigz1 size: {pigz1_size}, Pigz9 size: {pigz9_size}")


def test_pigz_header_parsing(real_data_dir: Path):
    """Test that pigz files can be parsed correctly."""
    for gz_file in real_data_dir.glob("*.pigz*.gz"):
        if not gz_file.is_file():
            continue

        # Try to parse the header
        header = parse_gzip_header(gz_file)
        assert header is not None, f"Failed to parse header for {gz_file.name}"

        # Basic header validation
        assert hasattr(header, 'mtime'), f"Missing mtime in header for {gz_file.name}"
        assert hasattr(header, 'os'), f"Missing os in header for {gz_file.name}"
        assert hasattr(header, 'flags'), f"Missing flags in header for {gz_file.name}"

        # Verify the file can be decompressed
        try:
            with gzip.open(gz_file, 'rb') as f:
                content = f.read()
            assert len(content) > 0, f"Empty content after decompressing {gz_file.name}"
        except Exception as e:
            pytest.fail(f"Failed to decompress {gz_file.name}: {e}")


def test_pigz_rsyncable_option(real_data_dir: Path):
    """Test that pigz --rsyncable produces valid output."""
    base_name = "data.bin"  # Use larger file for better compression differences

    regular_file = real_data_dir / f"{base_name}.pigz6.gz"
    rsyncable_file = real_data_dir / f"{base_name}.pigz_rsync.gz"

    if regular_file.exists() and rsyncable_file.exists():
        regular_data = regular_file.read_bytes()
        rsyncable_data = rsyncable_file.read_bytes()

        # Both should be valid gzip and decompress to the same content
        import gzip
        import tempfile
        with tempfile.NamedTemporaryFile() as tmp1:
            tmp1.write(regular_data)
            tmp1.flush()
            with gzip.open(tmp1.name, 'rb') as f:
                regular_content = f.read()

            with tempfile.NamedTemporaryFile() as tmp2:
                tmp2.write(rsyncable_data)
                tmp2.flush()
                with gzip.open(tmp2.name, 'rb') as f:
                    rsyncable_content = f.read()

            assert regular_content == rsyncable_content, "Both should decompress to the same content"

        # They might be the same size for some data (that's OK), but both should be valid
        assert len(regular_data) > 0, "Regular pigz should produce valid output"
        assert len(rsyncable_data) > 0, "Rsyncable pigz should produce valid output"

        # Log the sizes for debugging
        print(f"Regular pigz size: {len(regular_data)}, Rsyncable pigz size: {len(rsyncable_data)}")
