"""Extended tests for bencode module to improve coverage."""

from pathlib import Path

import bencodepy
import pytest

from torrent_compress_recovery.bencode import (
    BencodeError,
    TorrentFile,
    TorrentMeta,
    _bstr,
    parse_torrent,
)


def test_bstr_none_value():
    """Test _bstr with None value."""
    result = _bstr({}, b"key")
    assert result is None


def test_bstr_non_bytes_value():
    """Test _bstr with non-bytes value."""
    result = _bstr({b"key": 123}, b"key")
    assert result is None


def test_bstr_unicode_decode_error():
    """Test _bstr with bytes that cause UnicodeDecodeError."""
    # Invalid UTF-8 bytes
    result = _bstr({b"key": b"\xff\xfe"}, b"key")
    assert result is not None  # Should decode with replacement


def test_parse_torrent_decode_error(tmp_path: Path):
    """Test parse_torrent with invalid bencode data."""
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(b"invalid bencode data")

    with pytest.raises(BencodeError, match="Failed to decode torrent"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_non_dict_root(tmp_path: Path):
    """Test parse_torrent with non-dict root."""
    # Valid bencode but not a dict
    data = bencodepy.encode("string")
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Torrent root must be a dict"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_missing_info(tmp_path: Path):
    """Test parse_torrent with missing info dict."""
    data = bencodepy.encode({})
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Missing or invalid 'info' dict"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_invalid_info(tmp_path: Path):
    """Test parse_torrent with invalid info dict."""
    data = bencodepy.encode({b"info": b"not a dict"})
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Missing or invalid 'info' dict"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_missing_piece_length(tmp_path: Path):
    """Test parse_torrent with missing piece length."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"pieces": b"a" * 40,  # 2 pieces * 20 bytes
            }
        }
    )
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Missing or invalid 'piece length'"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_invalid_piece_length(tmp_path: Path):
    """Test parse_torrent with invalid piece length."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": b"not an int",
                b"pieces": b"a" * 40,
            }
        }
    )
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Missing or invalid 'piece length'"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_missing_pieces(tmp_path: Path):
    """Test parse_torrent with missing pieces."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
            }
        }
    )
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Missing or invalid 'pieces'"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_invalid_pieces(tmp_path: Path):
    """Test parse_torrent with invalid pieces."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": 123,  # Not bytes
            }
        }
    )
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Missing or invalid 'pieces'"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_invalid_pieces_length(tmp_path: Path):
    """Test parse_torrent with invalid pieces length (not multiple of 20)."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 19,  # Not multiple of 20
            }
        }
    )
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Invalid pieces hash list length"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_invalid_files_entry(tmp_path: Path):
    """Test parse_torrent with invalid files entry."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 40,
                b"files": b"not a list",
            }
        }
    )
    invalid_file = tmp_path / "invalid.torrent"
    invalid_file.write_bytes(data)

    with pytest.raises(BencodeError, match="Invalid 'files' entry"):
        parse_torrent(str(invalid_file))


def test_parse_torrent_hybrid_detection(tmp_path: Path):
    """Test torrent version detection for hybrid."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"meta version": 2,
                b"piece length": 524288,
                b"pieces": b"a" * 40,
            }
        }
    )
    torrent_file = tmp_path / "hybrid.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert meta.version == "hybrid"


def test_parse_torrent_single_file(tmp_path: Path):
    """Test parsing single-file torrent."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"single_file.txt",
                b"length": 1024,
                b"piece length": 524288,
                b"pieces": b"a" * 20,
            }
        }
    )
    torrent_file = tmp_path / "single.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert len(meta.files) == 1
    assert meta.files[0].rel_path == "single_file.txt"
    assert meta.files[0].length == 1024
    assert meta.files[0].offset == 0


def test_parse_torrent_bep47_fields(tmp_path: Path):
    """Test parsing BEP47 fields in multi-file torrent."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 40,
                b"files": [
                    {
                        b"length": 1024,
                        b"path": [b"file1.txt"],
                        b"sha1": b"a" * 20,
                        b"attr": b"x",
                        b"symlink path": [b"target"],
                    },
                    {
                        b"length": 2048,
                        b"path": [b"dir", b"file2.txt"],
                        # No BEP47 fields
                    },
                ],
            }
        }
    )
    torrent_file = tmp_path / "bep47.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert len(meta.files) == 2

    # First file has BEP47 fields
    file1 = meta.files[0]
    assert file1.sha1 == b"a" * 20
    assert file1.attr == "x"
    assert file1.symlink_path == ["target"]

    # Second file has no BEP47 fields
    file2 = meta.files[1]
    assert file2.sha1 is None
    assert file2.attr is None
    assert file2.symlink_path is None


def test_parse_torrent_invalid_file_entry(tmp_path: Path):
    """Test parsing with invalid file entries (should be skipped)."""
    data = bencodepy.encode(
        {
            b"info": {
                b"name": b"test",
                b"piece length": 524288,
                b"pieces": b"a" * 40,
                b"files": [
                    b"not a dict",  # Invalid entry
                    {
                        b"length": 1024,
                        # Missing path - should be skipped
                    },
                    {
                        b"length": 2048,
                        b"path": [],  # Empty path - should be skipped
                    },
                    {
                        b"length": 4096,
                        b"path": [b"valid.txt"],  # Valid entry
                    },
                ],
            }
        }
    )
    torrent_file = tmp_path / "invalid_entries.torrent"
    torrent_file.write_bytes(data)

    meta = parse_torrent(str(torrent_file))
    assert len(meta.files) == 1
    assert meta.files[0].rel_path == "valid.txt"
    assert meta.files[0].length == 4096


def test_torrent_file_dataclass():
    """Test TorrentFile dataclass."""
    file = TorrentFile(rel_path="test.txt", length=1024, offset=0, sha1=b"a" * 20, attr="x", symlink_path=["target"])

    assert file.rel_path == "test.txt"
    assert file.length == 1024
    assert file.offset == 0
    assert file.sha1 == b"a" * 20
    assert file.attr == "x"
    assert file.symlink_path == ["target"]


def test_torrent_meta_dataclass():
    """Test TorrentMeta dataclass."""
    meta = TorrentMeta(name="test", files=[TorrentFile("test.txt", 1024, 0)], piece_length=524288, pieces=[b"a" * 20], version="v1")

    assert meta.name == "test"
    assert len(meta.files) == 1
    assert meta.piece_length == 524288
    assert len(meta.pieces) == 1
    assert meta.version == "v1"
