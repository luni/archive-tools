"""Integration test fixtures using real CLI-generated data."""

import subprocess
import tempfile
from pathlib import Path

import pytest


def run_cmd(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    """Run a command and raise on failure."""
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True)


@pytest.fixture(scope="session")
def integration_dir():
    """Session-wide temp directory for generated test data."""
    with tempfile.TemporaryDirectory() as td:
        yield Path(td)


@pytest.fixture(scope="session")
def raw_files(integration_dir):
    """Create a few raw files with deterministic content."""
    raw = integration_dir / "raw"
    raw.mkdir()
    files = {}
    for name, content in {
        "alpha.txt": b"Alpha content\nLine 2\n",
        "beta.txt": b"Beta content\nAnother line\n",
        "data.bin": bytes(range(256)),
    }.items():
        p = raw / name
        p.write_bytes(content)
        files[name] = p
    return files


@pytest.fixture(scope="session")
def gz_files_cli(integration_dir, raw_files):
    """Create gz files using the system gzip CLI (deterministic)."""
    gz = integration_dir / "gz"
    gz.mkdir()
    gz_files = {}
    for name, src in raw_files.items():
        dst = gz / (name + ".gz")
        # Use gzip with deterministic options (no name, no timestamp)
        run_cmd(["gzip", "-n", "-c", str(src)], cwd=integration_dir)
        # gzip -c writes to stdout, so we need to capture and write
        proc = subprocess.run(
            ["gzip", "-n", "-c", str(src)],
            cwd=integration_dir,
            check=True,
            capture_output=True,
        )
        dst.write_bytes(proc.stdout)
        gz_files[name + ".gz"] = dst
    return gz_files


@pytest.fixture(scope="session")
def tar_gz_file(integration_dir, raw_files):
    """Create a single tar.gz archive using tar."""
    tar_gz = integration_dir / "archive.tar.gz"
    # Create tar.gz using tar (this will be used as a single file in torrent)
    run_cmd(["tar", "-czf", str(tar_gz), "-C", str(integration_dir / "raw"), "."], cwd=integration_dir)
    return tar_gz


@pytest.fixture(scope="session")
def torrent_single_file(integration_dir, gz_files_cli):
    """Create a real torrent file containing a single .gz."""
    torrent_path = integration_dir / "single.torrent"
    # Use transmission-create or mktorrent if available; fallback to simple bencode
    try:
        run_cmd(["transmission-create", "-o", str(torrent_path), str(next(iter(gz_files_cli.values())))], cwd=integration_dir)
    except (FileNotFoundError, subprocess.CalledProcessError):
        # Fallback: generate minimal torrent using our helper
        from tests.conftest import make_simple_torrent

        files = [{"path": [p.name], "length": p.stat().st_size} for p in gz_files_cli.values()]
        torrent_path.write_bytes(make_simple_torrent(b"single", files))
    return torrent_path


@pytest.fixture(scope="session")
def torrent_multi_file(integration_dir, gz_files_cli, tar_gz_file):
    """Create a torrent with multiple files (including a tar.gz)."""
    torrent_path = integration_dir / "multi.torrent"
    files = [{"path": [p.name], "length": p.stat().st_size} for p in gz_files_cli.values()] + [
        {"path": [tar_gz_file.name], "length": tar_gz_file.stat().st_size}
    ]
    try:
        # Try to create with a real tool
        all_paths = [*list(gz_files_cli.values()), tar_gz_file]
        cmd = ["transmission-create", "-o", str(torrent_path)] + [str(p) for p in all_paths]
        run_cmd(cmd, cwd=integration_dir)
    except (FileNotFoundError, subprocess.CalledProcessError):
        from tests.conftest import make_simple_torrent

        torrent_path.write_bytes(make_simple_torrent(b"multi", files))
    return torrent_path


@pytest.fixture(scope="session")
def partial_gz_files(integration_dir, gz_files_cli, tar_gz_file):
    """Create truncated partial downloads."""
    partial = integration_dir / "partial"
    partial.mkdir()
    partial_files = {}
    for name, src in gz_files_cli.items():
        dst = partial / name
        # Truncate to simulate partial download (keep first half)
        data = src.read_bytes()
        dst.write_bytes(data[: len(data) // 2])
        partial_files[name] = dst
    # Also add a truncated tar.gz
    dst_tar = partial / tar_gz_file.name
    data = tar_gz_file.read_bytes()
    dst_tar.write_bytes(data[: len(data) // 2])
    partial_files[tar_gz_file.name] = dst_tar
    return partial_files


@pytest.fixture(scope="session")
def corrupted_gz_files(integration_dir, gz_files_cli):
    """Create corrupted gz files (bad gzip header)."""
    corrupt = integration_dir / "corrupt"
    corrupt.mkdir()
    corrupt_files = {}
    for name, src in gz_files_cli.items():
        dst = corrupt / name
        data = src.read_bytes()
        # Corrupt the gzip magic number (first 2 bytes)
        corrupted = b"XX" + data[2:]
        dst.write_bytes(corrupted)
        corrupt_files[name] = dst
    return corrupt_files
