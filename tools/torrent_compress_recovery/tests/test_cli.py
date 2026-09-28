"""Test CLI functionality."""

import logging
from pathlib import Path
from unittest.mock import Mock, patch

from torrent_compress_recovery.cli import main


def test_main_header_info(tmp_path: Path):
    """Test --header-info flag."""
    # Create test partial files
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Create a simple gzip file
    gz_file = partial_dir / "test.gz"
    gz_file.write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x00test data\x00\x00\x00\x00\x00\x00\x00\x00\x00")

    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.parse_gzip_header") as mock_parse, patch("torrent_compress_recovery.cli.format_gzip_header") as mock_format:
        mock_parse.return_value = Mock()
        mock_format.return_value = "formatted header"

        result = main(
            ["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir), "--header-info"]
        )

        assert result == 0
        mock_parse.assert_called_once()
        mock_format.assert_called_once()


def test_main_verify_only(tmp_path: Path):
    """Test --verify-only flag."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.verify_last_piece_against_raw") as mock_verify:
        mock_verify.return_value = {"file1.gz": True, "file2.gz": False}

        result = main(
            ["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir), "--verify-only"]
        )

        assert result == 1  # Should return 1 when any verification fails
        mock_verify.assert_called_once_with(torrent_path, raw_dir, partial_dir)


def test_main_verify_only_all_success(tmp_path: Path):
    """Test --verify-only flag when all verifications succeed."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.verify_last_piece_against_raw") as mock_verify:
        mock_verify.return_value = {"file1.gz": True, "file2.gz": True}

        result = main(
            ["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir), "--verify-only"]
        )

        assert result == 0  # Should return 0 when all verifications succeed


def test_main_recover_mode(tmp_path: Path):
    """Test main recovery mode."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_result = Mock()
        mock_result.recovered = 1
        mock_result.gzipped = 2
        mock_result.bzipped = 0
        mock_result.xzipped = 0
        mock_result.zstipped = 0
        mock_result.skipped = 0
        mock_result.missing = 0
        mock_recover.return_value = mock_result

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir)])

        assert result == 0  # Should return 0 when no files are missing
        mock_recover.assert_called_once_with(
            torrent_path=torrent_path,
            raw_dir=raw_dir,
            partial_dir=partial_dir,
            target_dir=target_dir,
            raw_fallback=False,
            overwrite=False,
            dry_run=False,
            filename_filter=None,
            brute_force=True,
        )


def test_main_recover_mode_with_missing_files(tmp_path: Path):
    """Test main recovery mode when some files are missing."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_result = Mock()
        mock_result.recovered = 1
        mock_result.gzipped = 1
        mock_result.bzipped = 0
        mock_result.xzipped = 0
        mock_result.zstipped = 0
        mock_result.skipped = 0
        mock_result.missing = 2  # Some files missing
        mock_recover.return_value = mock_result

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir), "--target-dir", str(target_dir)])

        assert result == 2  # Should return 2 when files are missing


def test_main_with_all_flags(tmp_path: Path):
    """Test main function with all optional flags."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_result = Mock()
        mock_result.recovered = 1
        mock_result.gzipped = 1
        mock_result.bzipped = 0
        mock_result.xzipped = 0
        mock_result.zstipped = 0
        mock_result.skipped = 0
        mock_result.missing = 0
        mock_recover.return_value = mock_result

        result = main(
            [
                "--torrent",
                str(torrent_path),
                "--raw-dir",
                str(raw_dir),
                "--partial-dir",
                str(partial_dir),
                "--target-dir",
                str(target_dir),
                "--raw-fallback",
                "--overwrite",
                "--dry-run",
            ]
        )

        assert result == 0
        mock_recover.assert_called_once_with(
            torrent_path=torrent_path,
            raw_dir=raw_dir,
            partial_dir=partial_dir,
            target_dir=target_dir,
            raw_fallback=True,
            overwrite=True,
            dry_run=True,
            filename_filter=None,
            brute_force=True,
        )


def test_main_logging_configuration():
    """Test that logging is properly configured."""
    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_recover.return_value = Mock(recovered=0, gzipped=0, bzipped=0, xzipped=0, zstipped=0, skipped=0, missing=0)

        # Capture logging configuration
        with patch("logging.basicConfig") as mock_config:
            main(["--torrent", "test.torrent", "--raw-dir", "raw", "--partial-dir", "partial", "--target-dir", "target"])
            mock_config.assert_called_once_with(
                level=logging.INFO,
                format="%(levelname)s: %(message)s",
            )


def test_main_argument_parsing():
    """Test that arguments are properly parsed."""
    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_recover.return_value = Mock(recovered=0, gzipped=0, bzipped=0, xzipped=0, zstipped=0, skipped=0, missing=0)

        result = main(
            [
                "--torrent",
                "test.torrent",
                "--raw-dir",
                "raw_dir",
                "--partial-dir",
                "partial_dir",
                "--target-dir",
                "target_dir",
                "--raw-fallback",
                "--overwrite",
                "--dry-run",
            ]
        )

        assert result == 0
        # Verify the function was called with correct Path objects
        kwargs = mock_recover.call_args.kwargs
        assert isinstance(kwargs["torrent_path"], Path)
        assert isinstance(kwargs["raw_dir"], Path)
        assert isinstance(kwargs["partial_dir"], Path)
        assert isinstance(kwargs["target_dir"], Path)


def test_main_filename_filter(tmp_path: Path):
    """Test --filename flag with header-info mode."""
    # Create test partial files
    partial_dir = tmp_path / "partial"
    partial_dir.mkdir()

    # Create two gzip files
    gz_file1 = partial_dir / "test1.gz"
    gz_file1.write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x00test data1\x00\x00\x00\x00\x00\x00\x00\x00\x00")
    gz_file2 = partial_dir / "test2.gz"
    gz_file2.write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x00test data2\x00\x00\x00\x00\x00\x00\x00\x00\x00")

    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    target_dir = tmp_path / "target"

    with patch("torrent_compress_recovery.cli.parse_gzip_header") as mock_parse, patch("torrent_compress_recovery.cli.format_gzip_header") as mock_format:
        mock_parse.return_value = Mock()
        mock_format.return_value = "formatted header"

        result = main(
            [
                "--torrent",
                str(torrent_path),
                "--raw-dir",
                str(raw_dir),
                "--partial-dir",
                str(partial_dir),
                "--target-dir",
                str(target_dir),
                "--header-info",
                "--filename",
                "test1.gz",
            ]
        )

        assert result == 0
        # Should only call parse_gzip_header once (for test1.gz only)
        assert mock_parse.call_count == 1


def test_main_inplace_recovery(tmp_path: Path):
    """Test in-place recovery mode (no target directory)."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"

    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_result = Mock()
        mock_result.recovered = 1
        mock_result.gzipped = 0
        mock_result.bzipped = 0
        mock_result.xzipped = 0
        mock_result.zstipped = 0
        mock_result.skipped = 0
        mock_result.missing = 0
        mock_recover.return_value = mock_result

        result = main(["--torrent", str(torrent_path), "--raw-dir", str(raw_dir), "--partial-dir", str(partial_dir)])

        assert result == 0
        mock_recover.assert_called_once_with(
            torrent_path=torrent_path,
            raw_dir=raw_dir,
            partial_dir=partial_dir,
            target_dir=None,
            raw_fallback=False,
            overwrite=False,
            dry_run=False,
            filename_filter=None,
            brute_force=True,
        )


def test_main_filename_filter_recovery(tmp_path: Path):
    """Test --filename flag with recovery mode."""
    torrent_path = tmp_path / "test.torrent"
    raw_dir = tmp_path / "raw"
    partial_dir = tmp_path / "partial"

    with patch("torrent_compress_recovery.cli.recover") as mock_recover:
        mock_result = Mock()
        mock_result.recovered = 1
        mock_result.gzipped = 0
        mock_result.bzipped = 0
        mock_result.xzipped = 0
        mock_result.zstipped = 0
        mock_result.skipped = 0
        mock_result.missing = 0
        mock_recover.return_value = mock_result

        result = main(
            [
                "--torrent",
                str(torrent_path),
                "--raw-dir",
                str(raw_dir),
                "--partial-dir",
                str(partial_dir),
                "--filename",
                "specific_file.gz",
            ]
        )

        assert result == 0
        mock_recover.assert_called_once_with(
            torrent_path=torrent_path,
            raw_dir=raw_dir,
            partial_dir=partial_dir,
            target_dir=None,
            raw_fallback=False,
            overwrite=False,
            dry_run=False,
            filename_filter="specific_file.gz",
            brute_force=True,
        )
