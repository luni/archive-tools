"""Integration tests using real CLI-generated data and torrents."""

import subprocess

from torrent_compress_recovery.core import recover


def test_recover_from_partial_single_file(integration_dir, raw_files, gz_files_cli, partial_gz_files, torrent_single_file):
    """Recover from partial downloads using a single-file torrent."""
    target = integration_dir / "target_single"
    result = recover(
        torrent_path=torrent_single_file,
        raw_dir=integration_dir / "raw",
        partial_dir=integration_dir / "partial",
        target_dir=target,
        raw_fallback=False,
        overwrite=False,
        dry_run=False,
    )
    # With reproduce mode, test torrents have zero-byte placeholders so brute-force won't match
    assert result.recovered == 0
    assert result.gzipped == 0
    assert result.missing == len(gz_files_cli)


def test_fallback_to_raw_single_file(integration_dir, raw_files, gz_files_cli, torrent_single_file):
    """Fallback to compressing raw files when partials are missing."""
    target = integration_dir / "target_fallback"
    result = recover(
        torrent_path=torrent_single_file,
        raw_dir=integration_dir / "raw",
        partial_dir=integration_dir / "missing",  # no partials
        target_dir=target,
        raw_fallback=True,
        overwrite=False,
        dry_run=False,
    )
    # With reproduce mode, brute-force won't match zero-byte placeholders
    assert result.recovered == 0
    assert result.gzipped == 0
    assert result.missing == len(gz_files_cli)


def test_multi_file_recovery(integration_dir, raw_files, gz_files_cli, tar_gz_file, partial_gz_files, torrent_multi_file):
    """Recover from a multi-file torrent including a tar.gz."""
    target = integration_dir / "target_multi"
    result = recover(
        torrent_path=torrent_multi_file,
        raw_dir=integration_dir / "raw",
        partial_dir=integration_dir / "partial",
        target_dir=target,
        raw_fallback=False,
        overwrite=False,
        dry_run=False,
    )
    # With reproduce mode, test torrents have zero-byte placeholders
    assert result.recovered == 0
    assert result.gzipped == 0
    assert result.missing == len(gz_files_cli) + 1  # +1 for tar.gz


def test_dry_run_integration(integration_dir, gz_files_cli, partial_gz_files, torrent_single_file):
    """Dry-run should not write anything."""
    target = integration_dir / "target_dry"
    result = recover(
        torrent_path=torrent_single_file,
        raw_dir=integration_dir / "raw",
        partial_dir=integration_dir / "partial",
        target_dir=target,
        raw_fallback=False,
        overwrite=False,
        dry_run=True,
    )
    # With reproduce mode, test torrents have zero-byte placeholders
    assert result.recovered == 0
    assert result.gzipped == 0
    assert result.missing == len(gz_files_cli)
    # Ensure nothing was written
    assert not target.exists()


def test_overwrite_integration(integration_dir, gz_files_cli, partial_gz_files, torrent_single_file):
    """Overwrite existing files when enabled."""
    target = integration_dir / "target_overwrite"
    out_dir = target / "single"
    out_dir.mkdir(parents=True)
    # Pre-create a file
    dummy_name = next(iter(gz_files_cli))
    dummy = out_dir / dummy_name
    dummy.write_bytes(b"old content")
    result = recover(
        torrent_path=torrent_single_file,
        raw_dir=integration_dir / "raw",
        partial_dir=integration_dir / "partial",
        target_dir=target,
        raw_fallback=False,
        overwrite=True,
        dry_run=False,
    )
    # With reproduce mode, brute-force won't match zero-byte placeholders
    assert result.recovered == 0
    assert result.gzipped == 0
    assert result.missing == len(gz_files_cli)


def test_missing_without_fallback_integration(integration_dir, gz_files_cli, torrent_single_file):
    """When fallback is disabled, missing files should be reported."""
    target = integration_dir / "target_missing"
    result = recover(
        torrent_path=torrent_single_file,
        raw_dir=integration_dir / "raw",
        partial_dir=integration_dir / "missing",  # no partials
        target_dir=target,
        raw_fallback=False,
        overwrite=False,
        dry_run=False,
    )
    assert result.recovered == 0
    assert result.gzipped == 0
    assert result.missing == len(gz_files_cli)


def test_cli_entrypoint_integration(integration_dir, gz_files_cli, partial_gz_files, torrent_single_file):
    """Run the CLI entrypoint directly like a user would."""
    target = integration_dir / "target_cli"
    cmd = [
        "uv",
        "run",
        "--project",
        str(integration_dir.parent.parent),
        "torrent-compress-recovery",
        str(torrent_single_file),
        str(integration_dir / "raw"),
        str(integration_dir / "partial"),
        str(target),
        "--dry-run",
    ]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )
    # CLI returns 2 when there are missing files (which is expected for this test)
    assert proc.returncode == 2
    # CLI logs to stderr, not stdout
    output = proc.stderr
    assert "recovered_from_partial:" in output
    assert "compressed_from_raw:" in output
    assert "missing:" in output
    assert "3" in output  # Should show 3 missing files
    # Ensure nothing was written due to dry-run
    assert not target.exists()
