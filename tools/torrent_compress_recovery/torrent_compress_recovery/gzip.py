"""Gzip header parsing and brute-force generation utilities."""

import gzip
import hashlib
import subprocess  # nosec B404
import tempfile
from dataclasses import dataclass
from pathlib import Path

# Gzip format constants
GZIP_MAGIC = b"\x1f\x8b"
GZIP_METHOD_DEFLATE = 8
GZIP_MIN_HEADER_SIZE = 10
GZIP_FLAG_FTEXT = 1
GZIP_FLAG_FHCRC = 2
GZIP_FLAG_FEXTRA = 4
GZIP_FLAG_FNAME = 8
GZIP_FLAG_FCOMMENT = 16
GZIP_FLAG_RESERVED1 = 32
GZIP_FLAG_RESERVED2 = 64
GZIP_FLAG_RESERVED3 = 128
GZIP_XFL_POS = 8
GZIP_OS_POS = 9
GZIP_MTIME_POS = 4
GZIP_MTIME_SIZE = 4
GZIP_METHOD_POS = 2
GZIP_FLAGS_POS = 3
GZIP_XLEN_SIZE = 2
# Common compression levels
GZIP_MIN_LEVEL = 1
GZIP_DEFAULT_LEVEL = 6
GZIP_MAX_LEVEL = 9


@dataclass(frozen=True)
class GzipHeader:
    mtime: int
    os: int
    flags: int
    extra: bytes | None = None
    fname: bytes | None = None
    fcomment: bytes | None = None


def parse_gzip_header(path: Path) -> GzipHeader | None:
    """Parse the gzip header from a file (first 10 bytes + optional fields)."""
    with path.open("rb") as f:
        data = f.read(256)  # enough for header and most extra fields
    if len(data) < GZIP_MIN_HEADER_SIZE or data[:2] != GZIP_MAGIC:
        return None
    method = data[GZIP_METHOD_POS]
    if method != GZIP_METHOD_DEFLATE:
        return None
    flags = data[GZIP_FLAGS_POS]
    mtime = int.from_bytes(data[GZIP_MTIME_POS : GZIP_MTIME_POS + GZIP_MTIME_SIZE], "little")
    # xfl = data[GZIP_XFL_POS]  # XFL not used in our implementation
    os = data[GZIP_OS_POS]
    pos = GZIP_MIN_HEADER_SIZE
    extra = None
    fname = None
    fcomment = None
    if flags & GZIP_FLAG_FEXTRA:  # FEXTRA
        xlen = int.from_bytes(data[pos : pos + GZIP_XLEN_SIZE], "little")
        pos += GZIP_XLEN_SIZE
        extra = data[pos : pos + xlen]
        pos += xlen
    if flags & GZIP_FLAG_FNAME:  # FNAME
        end = data.find(b"\x00", pos)
        if end == -1:
            return None
        fname = data[pos:end]
        pos = end + 1
    if flags & GZIP_FLAG_FCOMMENT:  # FCOMMENT
        end = data.find(b"\x00", pos)
        if end == -1:
            return None
        fcomment = data[pos:end]
        pos = end + 1
    # FHCRC (flags & 2) ignored for our purposes
    return GzipHeader(mtime=mtime, os=os, flags=flags, extra=extra, fname=fname, fcomment=fcomment)


def format_gzip_header(header: GzipHeader) -> str:
    """Return a human-readable summary of gzip header fields."""
    lines = [
        f"mtime: {header.mtime}",
        f"OS: {header.os}",
        f"flags: {header.flags:08b}",
    ]
    flag_names = []
    if header.flags & GZIP_FLAG_FTEXT:
        flag_names.append("FTEXT")
    if header.flags & GZIP_FLAG_FHCRC:
        flag_names.append("FHCRC")
    if header.flags & GZIP_FLAG_FEXTRA:
        flag_names.append("FEXTRA")
    if header.flags & GZIP_FLAG_FNAME:
        flag_names.append("FNAME")
    if header.flags & GZIP_FLAG_FCOMMENT:
        flag_names.append("FCOMMENT")
    if header.flags & GZIP_FLAG_RESERVED1:
        flag_names.append("RESERVED1")
    if header.flags & GZIP_FLAG_RESERVED2:
        flag_names.append("RESERVED2")
    if header.flags & GZIP_FLAG_RESERVED3:
        flag_names.append("RESERVED3")
    lines.append(f"flag_names: {', '.join(flag_names) if flag_names else '(none)'}")
    if header.extra is not None:
        lines.append(f"extra: {len(header.extra)} bytes")
    if header.fname is not None:
        try:
            fname_str = header.fname.decode("utf-8", errors="replace")
        except Exception:
            fname_str = repr(header.fname)
        lines.append(f"fname: {fname_str}")
    if header.fcomment is not None:
        try:
            fcomment_str = header.fcomment.decode("utf-8", errors="replace")
        except Exception:
            fcomment_str = repr(header.fcomment)
        lines.append(f"fcomment: {fcomment_str}")
    return "\n".join(lines)


def patch_gzip_header(data: bytes, header: GzipHeader) -> bytes:
    """Patch gzip header fields to match the provided header (mtime, OS, flags, fname, fcomment, extra)."""
    if len(data) < GZIP_MIN_HEADER_SIZE:
        return data
    # Preserve method (should be 8)
    patched = bytearray(data)
    # Update flags
    patched[GZIP_FLAGS_POS] = header.flags & 0xFF
    # Update mtime (little-endian)
    patched[GZIP_MTIME_POS : GZIP_MTIME_POS + GZIP_MTIME_SIZE] = header.mtime.to_bytes(GZIP_MTIME_SIZE, "little")
    # Update XFL and OS
    # Note: We don't store XFL in GzipHeader, so we leave it as-is or set to 0
    patched[GZIP_XFL_POS] = 0  # XFL set to 0 for consistency
    patched[GZIP_OS_POS] = header.os & 0xFF
    pos = GZIP_MIN_HEADER_SIZE
    # Handle FEXTRA
    if header.flags & GZIP_FLAG_FEXTRA:
        if header.extra is not None:
            extra_len = len(header.extra)
            patched = patched[:pos] + extra_len.to_bytes(GZIP_XLEN_SIZE, "little") + header.extra + patched[pos + GZIP_XLEN_SIZE :]
            pos += GZIP_XLEN_SIZE + extra_len
        else:
            # Remove existing extra if any
            extra_len = int.from_bytes(patched[pos : pos + GZIP_XLEN_SIZE], "little")
            patched = patched[:pos] + patched[pos + GZIP_XLEN_SIZE + extra_len :]
    # Handle FNAME
    if header.flags & GZIP_FLAG_FNAME:
        if header.fname is not None:
            fname_bytes = header.fname + b"\x00"
            patched = patched[:pos] + fname_bytes + patched[pos:]
            pos += len(fname_bytes)
        else:
            # Remove existing fname if any
            end = patched.find(b"\x00", pos)
            if end != -1:
                patched = patched[:pos] + patched[end + 1 :]
                pos = len(patched)
    # Handle FCOMMENT
    if header.flags & GZIP_FLAG_FCOMMENT:
        if header.fcomment is not None:
            fcomment_bytes = header.fcomment + b"\x00"
            patched = patched[:pos] + fcomment_bytes + patched[pos:]
        else:
            # Remove existing fcomment if any
            end = patched.find(b"\x00", pos)
            if end != -1:
                patched = patched[:pos] + patched[end + 1 :]
    return bytes(patched)


def sha1_piece(data: bytes) -> bytes:
    """Return SHA-1 hash of data."""
    return hashlib.sha1(data).digest()


def generate_gzip_candidates(src: Path, header: GzipHeader | None) -> list[tuple[str, bytes]]:
    """Generate candidate gzip bytes for a source file using common tools/settings."""
    candidates: list[tuple[str, bytes]] = []
    src_bytes = src.read_bytes()
    # 1) Try to match header settings if available
    if header:
        # Use python gzip with exact header fields (except mtime which we set)
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp_path = Path(tmp.name)
            try:
                with gzip.GzipFile(filename="", mode="wb", fileobj=tmp_path.open("wb"), mtime=header.mtime) as gz:
                    gz.write(src_bytes)
                data = tmp_path.read_bytes()
                # Patch flags/fname/fcomment/extra if needed (simplified)
                data = patch_gzip_header(data, header)
                candidates.append(("header_match", data))
            finally:
                tmp_path.unlink()
    # 2) Brute-force common tools/levels
    tools = ["gzip"]
    try:
        subprocess.run(["pigz", "--version"], check=True, capture_output=True)  # nosec B603, B607
        tools.append("pigz")
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    for tool in tools:
        for level in [GZIP_MIN_LEVEL, GZIP_DEFAULT_LEVEL, GZIP_MAX_LEVEL]:
            for no_name in [True, False]:
                for rsyncable in [False, True] if tool == "gzip" else [False]:
                    cmd = [tool, f"-{level}"]
                    if no_name:
                        cmd.append("-n")
                    if rsyncable:
                        cmd.append("--rsyncable")
                    cmd.extend(["-c", str(src)])
                    try:
                        proc = subprocess.run(cmd, check=True, capture_output=True)  # nosec B603
                        data = proc.stdout
                        # Apply header patching if we have a header and this candidate is likely to be used
                        if header:
                            data = patch_gzip_header(data, header)
                        label = f"{tool} -{level}" + (" -n" if no_name else "") + (" --rsyncable" if rsyncable else "")
                        candidates.append((label, data))
                    except (FileNotFoundError, subprocess.CalledProcessError):
                        continue
    return candidates


def sha256_piece(data: bytes) -> bytes:
    """Return SHA-256 hash of data."""
    return hashlib.sha256(data).digest()


def find_matching_candidate(
    candidates: list[tuple[str, bytes]],
    target_piece_hash: bytes,
    piece_length: int,
    hash_algo: str = "sha1",
) -> tuple[str, bytes] | None:
    """Return the first candidate whose first piece hash matches."""
    hash_fn = sha1_piece if hash_algo == "sha1" else sha256_piece
    for label, data in candidates:
        if len(data) < piece_length:
            continue
        piece = data[:piece_length]
        if hash_fn(piece) == target_piece_hash:
            return label, data
    return None
