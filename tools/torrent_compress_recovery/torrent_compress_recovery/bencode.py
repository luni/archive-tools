"""Torrent parsing using bencodepy."""

from dataclasses import dataclass
from pathlib import Path

import bencodepy

SHA1_DIGEST_LEN = 20
V2_META_VERSION = 2
V2_DEFAULT_PIECE_LENGTH = 16384


class BencodeError(Exception):
    pass


def _bstr(dct: dict, key: bytes) -> str | None:
    v = dct.get(key)
    if not isinstance(v, (bytes, bytearray)):
        return None
    return bytes(v).decode("utf-8", errors="replace")


@dataclass(frozen=True)
class TorrentFile:
    rel_path: str
    length: int | None
    offset: int
    sha1: bytes | None = None  # BEP47 per-file SHA1
    attr: str | None = None  # BEP47 attributes (l=link, x=exec, h=hidden, p=padding)
    symlink_path: list[str] | None = None  # BEP47 symlink target


@dataclass(frozen=True)
class TorrentMeta:
    name: str
    files: list[TorrentFile]
    piece_length: int
    pieces: list[bytes]  # SHA-1 hashes (20 bytes each) for v1
    version: str  # "v1", "v2", or "hybrid"


def _bep47_sha1(dct: dict) -> bytes | None:
    """Extract a BEP47 per-file SHA-1 digest, or None."""
    sha1 = dct.get(b"sha1")
    return bytes(sha1) if isinstance(sha1, (bytes, bytearray)) and len(sha1) == SHA1_DIGEST_LEN else None


def _is_safe_component(part: str) -> bool:
    """Reject path components that would escape the output directory."""
    return part not in {"", ".", ".."} and "/" not in part and "\\" not in part and "\x00" not in part


def _decode_path_parts(parts: object) -> list[str] | None:
    """Decode a bencoded path component list, or None if malformed."""
    if not isinstance(parts, list) or not parts:
        return None
    decoded: list[str] = []
    for part in parts:
        if not isinstance(part, (bytes, bytearray)):
            return None
        decoded.append(bytes(part).decode("utf-8", errors="replace"))
    return decoded


def _validate_rel_path(rel_path: str) -> None:
    """Raise BencodeError if a torrent path could escape the output directory."""
    if not rel_path or any(not _is_safe_component(c) for c in rel_path.split("/")):
        raise BencodeError(f"Unsafe path in torrent: {rel_path!r}")


def _v1_pieces(info: dict) -> tuple[int, list[bytes]]:
    """Return (piece_length, piece hashes) for v1/hybrid torrents."""
    piece_length = info.get(b"piece length")
    if not isinstance(piece_length, int) or piece_length <= 0:
        raise BencodeError("Missing or invalid 'piece length'")
    pieces_raw = info.get(b"pieces")
    if not isinstance(pieces_raw, (bytes, bytearray)):
        raise BencodeError("Missing or invalid 'pieces'")
    if len(pieces_raw) % SHA1_DIGEST_LEN != 0:
        raise BencodeError("Invalid pieces hash list length")
    pieces = [bytes(pieces_raw[i : i + SHA1_DIGEST_LEN]) for i in range(0, len(pieces_raw), SHA1_DIGEST_LEN)]
    return piece_length, pieces


def _parse_v1_file_entries(info: dict) -> list[TorrentFile]:
    """Parse v1 multi-file 'files' entries."""
    fentries = info.get(b"files")
    if not isinstance(fentries, list):
        raise BencodeError("Invalid 'files' entry")
    files: list[TorrentFile] = []
    offset = 0
    for fe in fentries:
        if not isinstance(fe, dict):
            continue
        plen = fe.get(b"length")
        length = plen if isinstance(plen, int) else None
        parts = _decode_path_parts(fe.get(b"path"))
        if parts is None:
            continue
        symlink_path = _decode_path_parts(fe.get(b"symlink path"))
        rel_path = "/".join(parts)
        _validate_rel_path(rel_path)
        files.append(
            TorrentFile(
                rel_path=rel_path,
                length=length,
                offset=offset,
                sha1=_bep47_sha1(fe),
                attr=_bstr(fe, b"attr"),
                symlink_path=symlink_path,
            )
        )
        offset += length or 0
    return files


def _parse_v2_file_tree(tree: dict, prefix: str, offset: int) -> list[TorrentFile]:
    """Parse v2 torrent file tree structure."""
    files: list[TorrentFile] = []

    for key, value in tree.items():
        if not isinstance(key, (bytes, bytearray)):
            continue

        key_str = bytes(key).decode("utf-8", errors="replace")
        full_path = f"{prefix}/{key_str}" if prefix else key_str

        if isinstance(value, dict) and b"" in value:
            # This is a file
            file_data = value[b""]
            if isinstance(file_data, dict):
                length = file_data.get(b"length")
                length = length if isinstance(length, int) else None
                _validate_rel_path(full_path)

                files.append(
                    TorrentFile(
                        rel_path=full_path,
                        length=length,
                        offset=offset,
                        sha1=_bep47_sha1(file_data),
                        attr=_bstr(file_data, b"attr"),
                        symlink_path=None,
                    )
                )
                offset += length or 0
        elif isinstance(value, dict):
            # This is a directory, recurse; advance the offset by the total
            # size of the files found inside so siblings get correct offsets.
            sub_files = _parse_v2_file_tree(value, full_path, offset)
            files.extend(sub_files)
            offset += sum(f.length or 0 for f in sub_files)

    return files


def parse_torrent(torrent_path: str) -> TorrentMeta:
    """Parse a .torrent file and return metadata including piece hashes."""
    raw = Path(torrent_path).read_bytes()
    try:
        root = bencodepy.decode(raw)
    except Exception as e:
        raise BencodeError(f"Failed to decode torrent: {e}") from e
    if not isinstance(root, dict):
        raise BencodeError("Torrent root must be a dict")

    info = root.get(b"info")
    if not isinstance(info, dict):
        raise BencodeError("Missing or invalid 'info' dict")

    name = _bstr(info, b"name") or Path(torrent_path).stem
    if not _is_safe_component(name):
        raise BencodeError(f"Unsafe torrent name: {name!r}")

    # Detect torrent version
    version = "v1"
    if b"meta version" in info and info.get(b"meta version") == V2_META_VERSION:
        version = "v2"
    # Hybrid torrents have both v1 and v2 fields
    if version == "v2" and b"pieces" in info:
        version = "hybrid"

    # Handle v2 torrents (they don't have v1 fields)
    if version == "v2":
        # For v2 torrents, we need to handle piece layers and root hash
        # For now, we'll create a minimal structure
        v2_piece_length = info.get(b"piece length")
        piece_length = v2_piece_length if isinstance(v2_piece_length, int) and v2_piece_length > 0 else V2_DEFAULT_PIECE_LENGTH
        pieces = []  # v2 uses piece layers instead of pieces
    else:
        piece_length, pieces = _v1_pieces(info)

    files = _parse_file_list(info, version, name)

    return TorrentMeta(name=name, files=files, piece_length=piece_length, pieces=pieces, version=version)


def _parse_file_list(info: dict, version: str, name: str) -> list[TorrentFile]:
    """Dispatch file-list parsing by torrent version/layout."""
    if version == "v2":
        # V2 torrents use "file tree" structure
        file_tree = info.get(b"file tree")
        if isinstance(file_tree, dict):
            return _parse_v2_file_tree(file_tree, "", 0)
        # V2 single file torrent
        length = info.get(b"length")
        length = length if isinstance(length, int) else None
        return [TorrentFile(rel_path=name, length=length, offset=0, sha1=None, attr=None, symlink_path=None)]
    if b"files" in info:
        # V1 multi-file torrent
        return _parse_v1_file_entries(info)
    # V1 single-file torrent
    length_v = info.get(b"length")
    length = length_v if isinstance(length_v, int) else None
    return [
        TorrentFile(
            rel_path=name,
            length=length,
            offset=0,
            sha1=_bep47_sha1(info),
            attr=_bstr(info, b"attr"),
            symlink_path=None,
        )
    ]
