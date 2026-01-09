"""Test v2 torrent support."""

from pathlib import Path

import bencodepy

from torrent_compress_recovery.bencode import parse_torrent


def test_parse_v2_single_file_torrent(tmp_path: Path):
    """Test parsing a v2 single-file torrent."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test.txt",
                b"meta version": 2,
                b"length": 1024,
                b"piece layers": {},
                b"root hash": b"a" * 32,
            }
        }
    )
    torrent_file = tmp_path / "v2_single.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert meta.version == "v2"
    assert meta.name == "test.txt"
    assert len(meta.files) == 1
    assert meta.files[0].rel_path == "test.txt"
    assert meta.files[0].length == 1024
    assert meta.piece_length == 16384  # Default for v2
    assert meta.pieces == []  # v2 doesn't use pieces


def test_parse_v2_multi_file_torrent(tmp_path: Path):
    """Test parsing a v2 multi-file torrent with file tree."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"meta version": 2,
                b"piece layers": {},
                b"root hash": b"a" * 32,
                b"file tree": {
                    b"file1.txt": {
                        b"": {
                            b"length": 1024,
                            b"sha1": b"b" * 20,
                        }
                    },
                    b"dir": {
                        b"file2.txt": {
                            b"": {
                                b"length": 2048,
                                b"attr": b"x",
                            }
                        }
                    },
                },
            }
        }
    )
    torrent_file = tmp_path / "v2_multi.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert meta.version == "v2"
    assert meta.name == "test"
    assert len(meta.files) == 2

    # Check first file
    file1 = next(f for f in meta.files if f.rel_path == "file1.txt")
    assert file1.length == 1024
    assert file1.sha1 == b"b" * 20
    assert file1.attr is None

    # Check second file
    file2 = next(f for f in meta.files if f.rel_path == "dir/file2.txt")
    assert file2.length == 2048
    assert file2.attr == "x"


def test_parse_v2_piece_layers_detection(tmp_path: Path):
    """Test v2 detection via meta version."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"meta version": 2,
                b"piece length": 16384,
                b"root hash": b"a" * 32,
            }
        }
    )
    torrent_file = tmp_path / "v2_piece_layers.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert meta.version == "v2"


def test_parse_hybrid_torrent(tmp_path: Path):
    """Test parsing a hybrid torrent (both v1 and v2 fields)."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"meta version": 2,
                b"piece length": 524288,
                b"pieces": b"a" * 40,
                b"piece layers": {},
                b"root hash": b"a" * 32,
            }
        }
    )
    torrent_file = tmp_path / "hybrid.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert meta.version == "hybrid"
    assert meta.piece_length == 524288
    assert len(meta.pieces) == 2  # Should have v1 pieces


def test_parse_v2_empty_file_tree(tmp_path: Path):
    """Test v2 torrent with empty file tree."""
    data = bencodepy.encode({b"info": {b"name": b"empty", b"meta version": 2, b"piece layers": {}, b"root hash": b"a" * 32, b"file tree": {}}})
    torrent_file = tmp_path / "v2_empty.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert meta.version == "v2"
    assert meta.name == "empty"
    assert len(meta.files) == 0
