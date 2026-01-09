"""Torrent parsing using bencodepy."""

from dataclasses import dataclass
from pathlib import Path

import bencodepy


class BencodeError(Exception):
    pass


def _bstr(dct: dict, key: bytes) -> str | None:
    v = dct.get(key)
    if v is None:
        return None
    if not isinstance(v, (bytes, bytearray)):
        return None
    try:
        return bytes(v).decode("utf-8")
    except UnicodeDecodeError:
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

                # Extract BEP47 fields if present
                sha1 = file_data.get(b"sha1")
                sha1 = bytes(sha1) if isinstance(sha1, (bytes, bytearray)) and len(sha1) == 20 else None

                attr = file_data.get(b"attr")
                attr = _bstr(file_data, b"attr") if isinstance(attr, (bytes, bytearray)) else None

                files.append(TorrentFile(rel_path=full_path, length=length, offset=offset, sha1=sha1, attr=attr, symlink_path=None))
                offset += length or 0
        elif isinstance(value, dict):
            # This is a directory, recurse
            files.extend(_parse_v2_file_tree(value, full_path, offset))

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

    # Detect torrent version
    version = "v1"
    if b"meta version" in info and info.get(b"meta version") == 2:
        version = "v2"
    # Hybrid torrents have both v1 and v2 fields
    if version == "v2" and b"pieces" in info:
        version = "hybrid"

    # Handle v2 torrents (they don't have v1 fields)
    if version == "v2":
        # For v2 torrents, we need to handle piece layers and root hash
        # For now, we'll create a minimal structure
        piece_length = 16384  # Default piece length for v2
        pieces = []  # v2 uses piece layers instead of pieces
    else:
        # v1 or hybrid torrents
        piece_length = info.get(b"piece length")
        if not isinstance(piece_length, int):
            raise BencodeError("Missing or invalid 'piece length'")
        pieces_raw = info.get(b"pieces")
        if not isinstance(pieces_raw, (bytes, bytearray)):
            raise BencodeError("Missing or invalid 'pieces'")
        if len(pieces_raw) % 20 != 0:
            raise BencodeError("Invalid pieces hash list length")
        pieces = [bytes(pieces_raw[i : i + 20]) for i in range(0, len(pieces_raw), 20)]  # type: ignore[assignment]

    files: list[TorrentFile] = []
    offset = 0

    if version == "v2":
        # V2 torrents use "file tree" structure
        file_tree = info.get(b"file tree")
        if isinstance(file_tree, dict):
            files = _parse_v2_file_tree(file_tree, "", offset)
        else:
            # V2 single file torrent
            length = info.get(b"length")
            length = length if isinstance(length, int) else None
            files.append(TorrentFile(rel_path=name, length=length, offset=offset, sha1=None, attr=None, symlink_path=None))
    elif b"files" in info:
        # V1 multi-file torrent
        fentries = info.get(b"files")
        if not isinstance(fentries, list):
            raise BencodeError("Invalid 'files' entry")
        for fe in fentries:
            if not isinstance(fe, dict):
                continue
            plen = fe.get(b"length")
            length = plen if isinstance(plen, int) else None
            parts = fe.get(b"path")
            if not isinstance(parts, list) or not parts:
                continue
            p: list[str] = []
            ok = True
            for part in parts:
                if not isinstance(part, (bytes, bytearray)):
                    ok = False
                    break
                p.append(bytes(part).decode("utf-8", errors="replace"))
            if not ok:
                continue

            # Extract BEP47 fields
            sha1 = fe.get(b"sha1")
            sha1 = bytes(sha1) if isinstance(sha1, (bytes, bytearray)) and len(sha1) == 20 else None

            attr = fe.get(b"attr")
            attr = _bstr(fe, b"attr") if isinstance(attr, (bytes, bytearray)) else None

            symlink_parts = fe.get(b"symlink path")
            symlink_path = None
            if isinstance(symlink_parts, list):
                symlink_path = []
                for part in symlink_parts:
                    if isinstance(part, (bytes, bytearray)):
                        symlink_path.append(bytes(part).decode("utf-8", errors="replace"))

            files.append(TorrentFile(rel_path="/".join(p), length=length, offset=offset, sha1=sha1, attr=attr, symlink_path=symlink_path))
            offset += length or 0
    else:
        # V1 single-file torrent
        length_v = info.get(b"length")
        length = length_v if isinstance(length_v, int) else None

        # Extract BEP47 fields for single file
        sha1 = info.get(b"sha1")
        sha1 = bytes(sha1) if isinstance(sha1, (bytes, bytearray)) and len(sha1) == 20 else None

        attr = info.get(b"attr")
        attr = _bstr(info, b"attr") if isinstance(attr, (bytes, bytearray)) else None

        files.append(TorrentFile(rel_path=name, length=length, offset=offset, sha1=sha1, attr=attr, symlink_path=None))
        offset += length or 0

    return TorrentMeta(name=name, files=files, piece_length=piece_length, pieces=pieces, version=version)
