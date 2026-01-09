"""Tests for BEP47 support: padding files, per-file SHA1, symlinks, and attributes."""

import hashlib
import tempfile
from pathlib import Path

from torrent_compress_recovery.bencode import parse_torrent
from torrent_compress_recovery.core import recover


def test_parse_bep47_padding_file():
    """Test parsing a torrent with BEP47 padding file."""
    # Create a minimal torrent with a padding file
    torrent_data = {
        b"info": {
            b"name": b"test",
            b"piece length": 16384,
            b"pieces": hashlib.sha1(b"").digest(),
            b"files": [
                {
                    b"length": 100,
                    b"path": [b"file.txt"],
                    b"sha1": hashlib.sha1(b"content").digest(),
                    b"attr": b"",
                },
                {
                    b"length": 1024,
                    b"path": [b".padding", b"pad000001"],
                    b"attr": b"p",
                },
            ],
        }
    }

    # Simple bencode encoder
    def encode(obj):
        if isinstance(obj, int):
            return b"i" + str(obj).encode() + b"e"
        if isinstance(obj, bytes):
            return str(len(obj)).encode() + b":" + obj
        if isinstance(obj, str):
            return str(len(obj)).encode() + b":" + obj.encode()
        if isinstance(obj, list):
            return b"l" + b"".join(encode(x) for x in obj) + b"e"
        if isinstance(obj, dict):
            items = sorted(obj.items(), key=lambda kv: kv[0])
            return b"d" + b"".join(encode(k) + encode(v) for k, v in items) + b"e"
        raise TypeError(type(obj))

    torrent_bytes = encode(torrent_data)

    with tempfile.NamedTemporaryFile(suffix=".torrent", delete=False) as f:
        f.write(torrent_bytes)
        torrent_path = f.name

    try:
        meta = parse_torrent(torrent_path)

        # Check we have two files
        assert len(meta.files) == 2

        # Check regular file
        regular = meta.files[0]
        assert regular.rel_path == "file.txt"
        assert regular.length == 100
        assert regular.sha1 == hashlib.sha1(b"content").digest()
        assert regular.attr == ""
        assert regular.symlink_path is None

        # Check padding file
        padding = meta.files[1]
        assert padding.rel_path == ".padding/pad000001"
        assert padding.length == 1024
        assert padding.sha1 is None  # Padding files don't have SHA1
        assert padding.attr == "p"
        assert padding.symlink_path is None

    finally:
        Path(torrent_path).unlink()


def test_recover_skips_padding_files(temp_dir):
    """Test that recovery skips padding files."""
    # Create test data
    raw_dir = temp_dir / "raw"
    raw_dir.mkdir()
    partial_dir = temp_dir / "partial"
    partial_dir.mkdir()
    target_dir = temp_dir / "target"

    # Create a raw file
    raw_file = raw_dir / "test.txt.gz"
    raw_file.write_text("test content")

    # Create a minimal torrent with padding file
    torrent_data = {
        b"info": {
            b"name": b"test",
            b"piece length": 32,
            b"pieces": hashlib.sha1(b"test content").digest(),
            b"files": [
                {
                    b"length": len("test content"),
                    b"path": [b"test.txt.gz"],
                    b"sha1": hashlib.sha1(b"test content").digest(),
                    b"attr": b"",
                },
                {
                    b"length": 1024,
                    b"path": [b".padding", b"pad000001"],
                    b"attr": b"p",
                },
            ],
        }
    }

    def encode(obj):
        if isinstance(obj, int):
            return b"i" + str(obj).encode() + b"e"
        if isinstance(obj, bytes):
            return str(len(obj)).encode() + b":" + obj
        if isinstance(obj, str):
            return str(len(obj)).encode() + b":" + obj.encode()
        if isinstance(obj, list):
            return b"l" + b"".join(encode(x) for x in obj) + b"e"
        if isinstance(obj, dict):
            items = sorted(obj.items(), key=lambda kv: kv[0])
            return b"d" + b"".join(encode(k) + encode(v) for k, v in items) + b"e"
        raise TypeError(type(obj))

    torrent_bytes = encode(torrent_data)
    torrent_path = temp_dir / "test.torrent"
    torrent_path.write_bytes(torrent_bytes)

    # Run recovery
    result = recover(
        torrent_path=torrent_path,
        raw_dir=raw_dir,
        partial_dir=partial_dir,
        target_dir=target_dir,
        raw_fallback=False,  # No fallback - only use actual files
        overwrite=False,
        dry_run=False,
    )

    # Should skip the padding file
    assert result.skipped == 1  # The padding file
    assert result.missing == 1  # The .gz file (raw content doesn't match BEP47 SHA1)
    assert result.recovered == 0
    assert result.gzipped == 0  # No .gz files in this test


def test_parse_bep47_symlink():
    """Test parsing a torrent with BEP47 symlink."""
    torrent_data = {
        b"info": {
            b"name": b"test",
            b"piece length": 16384,
            b"pieces": hashlib.sha1(b"").digest(),
            b"files": [
                {
                    b"length": 0,
                    b"path": [b"link.txt"],
                    b"attr": b"l",
                    b"symlink path": [b"target.txt"],
                },
            ],
        }
    }

    def encode(obj):
        if isinstance(obj, int):
            return b"i" + str(obj).encode() + b"e"
        if isinstance(obj, bytes):
            return str(len(obj)).encode() + b":" + obj
        if isinstance(obj, str):
            return str(len(obj)).encode() + b":" + obj.encode()
        if isinstance(obj, list):
            return b"l" + b"".join(encode(x) for x in obj) + b"e"
        if isinstance(obj, dict):
            items = sorted(obj.items(), key=lambda kv: kv[0])
            return b"d" + b"".join(encode(k) + encode(v) for k, v in items) + b"e"
        raise TypeError(type(obj))

    torrent_bytes = encode(torrent_data)

    with tempfile.NamedTemporaryFile(suffix=".torrent", delete=False) as f:
        f.write(torrent_bytes)
        torrent_path = f.name

    try:
        meta = parse_torrent(torrent_path)

        assert len(meta.files) == 1
        symlink = meta.files[0]
        assert symlink.rel_path == "link.txt"
        assert symlink.length == 0
        assert symlink.attr == "l"
        assert symlink.symlink_path == ["target.txt"]

    finally:
        Path(torrent_path).unlink()


def test_parse_bep47_single_file():
    """Test BEP47 fields in a single-file torrent."""
    torrent_data = {
        b"info": {
            b"name": b"single.txt",
            b"length": 42,
            b"piece length": 16384,
            b"pieces": hashlib.sha1(b"x" * 42).digest(),
            b"sha1": hashlib.sha1(b"x" * 42).digest(),
            b"attr": b"x",  # executable
        }
    }

    def encode(obj):
        if isinstance(obj, int):
            return b"i" + str(obj).encode() + b"e"
        if isinstance(obj, bytes):
            return str(len(obj)).encode() + b":" + obj
        if isinstance(obj, str):
            return str(len(obj)).encode() + b":" + obj.encode()
        if isinstance(obj, list):
            return b"l" + b"".join(encode(x) for x in obj) + b"e"
        if isinstance(obj, dict):
            items = sorted(obj.items(), key=lambda kv: kv[0])
            return b"d" + b"".join(encode(k) + encode(v) for k, v in items) + b"e"
        raise TypeError(type(obj))

    torrent_bytes = encode(torrent_data)

    with tempfile.NamedTemporaryFile(suffix=".torrent", delete=False) as f:
        f.write(torrent_bytes)
        torrent_path = f.name

    try:
        meta = parse_torrent(torrent_path)

        assert len(meta.files) == 1
        single = meta.files[0]
        assert single.rel_path == "single.txt"
        assert single.length == 42
        assert single.sha1 == hashlib.sha1(b"x" * 42).digest()
        assert single.attr == "x"
        assert single.symlink_path is None

    finally:
        Path(torrent_path).unlink()
