"""Tests for overlapping pieces functionality."""

from pathlib import Path
from unittest.mock import patch

import pytest

from torrent_compress_recovery.cli import main


class TestOverlappingPieces:
    """Test overlapping pieces and offset file functionality."""

    @pytest.fixture
    def overlap_test_data(self):
        """Path to overlapping pieces test data."""
        return Path(__file__).parent / "fixtures" / "real_data" / "overlap_test"

    @pytest.fixture
    def padding_test_data(self):
        """Path to padding offset test data."""
        return Path(__file__).parent / "fixtures" / "real_data" / "padding_test"

    def test_overlap_small_pieces_header_info(self, overlap_test_data):
        """Test header info with small pieces torrent (16-byte pieces)."""
        torrent_path = overlap_test_data / "overlap_small_pieces.torrent"
        raw_dir = overlap_test_data / "raw"
        partial_dir = overlap_test_data / "partial"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--header-info"])

        assert result == 0

    def test_overlap_medium_pieces_header_info(self, overlap_test_data):
        """Test header info with medium pieces torrent (32-byte pieces)."""
        torrent_path = overlap_test_data / "overlap_medium_pieces.torrent"
        raw_dir = overlap_test_data / "raw"
        partial_dir = overlap_test_data / "partial"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--header-info"])

        assert result == 0

    def test_padding_offset_header_info(self, padding_test_data, overlap_test_data):
        """Test header info with padding offset torrent."""
        torrent_path = padding_test_data / "padding_offset.torrent"
        raw_dir = padding_test_data / "raw"
        partial_dir = overlap_test_data / "partial"  # Use overlap partial for testing

        if not torrent_path.exists():
            pytest.skip("Padding test data not available")

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--header-info"])

        assert result == 0

    def test_overlap_small_pieces_dry_run(self, overlap_test_data):
        """Test dry run recovery with small pieces torrent."""
        torrent_path = overlap_test_data / "overlap_small_pieces.torrent"
        raw_dir = overlap_test_data / "raw"
        partial_dir = overlap_test_data / "partial"
        target_dir = overlap_test_data / "target"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        # Create target directory
        target_dir.mkdir(exist_ok=True)

        result = main(
            ["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir), "--dry-run"]
        )

        # Exit code 2 indicates missing files, which is expected for test data
        assert result in [0, 2]

    def test_overlap_filename_filter(self, overlap_test_data):
        """Test filename filtering with overlapping pieces torrent."""
        torrent_path = overlap_test_data / "overlap_small_pieces.torrent"
        raw_dir = overlap_test_data / "raw"
        partial_dir = overlap_test_data / "partial"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        result = main(
            ["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--header-info", "--filename", "file1.txt.gz"]
        )

        assert result == 0

    @patch("torrent_compress_recovery.cli.recover")
    def test_overlap_small_pieces_recovery_mode(self, mock_recover, overlap_test_data):
        """Test recovery mode with overlapping pieces torrent."""
        torrent_path = overlap_test_data / "overlap_small_pieces.torrent"
        raw_dir = overlap_test_data / "raw"
        partial_dir = overlap_test_data / "partial"
        target_dir = overlap_test_data / "target"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        # Mock the recover function to avoid actual file operations
        mock_result = mock_recover.return_value
        mock_result.recovered = 2
        mock_result.gzipped = 0
        mock_result.bzipped = 0
        mock_result.xzipped = 0
        mock_result.zstipped = 0
        mock_result.skipped = 0
        mock_result.missing = 0

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir)])

        assert result == 0
        mock_recover.assert_called_once()

    def test_inplace_recovery_with_overlap(self, overlap_test_data):
        """Test in-place recovery with overlapping pieces torrent."""
        torrent_path = overlap_test_data / "overlap_small_pieces.torrent"
        raw_dir = overlap_test_data / "raw"
        partial_dir = overlap_test_data / "partial"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        result = main(
            [
                "--torrent",
                str(torrent_path),
                "--raw-dir",
                str(raw_dir),
                "--partial-dir",
                str(partial_dir),
                "--dry-run",  # Use dry-run to avoid modifying test data
            ]
        )

        # Exit code 2 indicates missing files, which is expected for test data
        assert result in [0, 2]

    def test_overlap_torrent_piece_boundary_analysis(self, overlap_test_data):
        """Test that overlapping pieces torrent has expected piece boundaries."""
        torrent_path = overlap_test_data / "overlap_small_pieces.torrent"

        if not torrent_path.exists():
            pytest.skip("Overlap test data not available")

        # Parse the torrent to verify piece boundaries
        from torrent_compress_recovery.bencode import parse_torrent

        meta = parse_torrent(str(torrent_path))

        # Verify we have multiple files and pieces
        assert len(meta.files) > 0
        assert meta.piece_length > 0
        assert len(meta.pieces) > 0

        # Check that files have different offsets (indicating overlapping)
        offsets = [f.offset for f in meta.files if f.offset is not None]
        assert len(set(offsets)) > 1, "Files should have different offsets for overlapping test"
