"""Gzip header parsing and brute-force generation utilities."""

import gzip
import subprocess  # nosec B404
import tempfile
import zlib
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
    xfl: int = 0


def _read_gzip_extra(path: Path, data: bytes, pos: int) -> tuple[bytes, bytes, int] | None:
    """Read the FEXTRA field at pos, extending the buffer when XLEN exceeds it.

    Returns (data, extra, new_pos) or None when the field is truncated.
    """
    if pos + GZIP_XLEN_SIZE > len(data):
        return None
    xlen = int.from_bytes(data[pos : pos + GZIP_XLEN_SIZE], "little")
    pos += GZIP_XLEN_SIZE
    if pos + xlen > len(data):
        # Initial 256-byte read was too small for this extra field;
        # extend the buffer contiguously (plus room for FNAME/FCOMMENT)
        with path.open("rb") as f:
            f.seek(len(data))
            data += f.read(pos + xlen - len(data) + 4096)
    if pos + xlen > len(data):
        return None
    return data, data[pos : pos + xlen], pos + xlen


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
    xfl = data[GZIP_XFL_POS]
    os = data[GZIP_OS_POS]
    pos = GZIP_MIN_HEADER_SIZE
    extra = None
    fname = None
    fcomment = None
    if flags & GZIP_FLAG_FEXTRA:  # FEXTRA
        res = _read_gzip_extra(path, data, pos)
        if res is None:
            return None
        data, extra, pos = res
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
    return GzipHeader(mtime=mtime, os=os, flags=flags, extra=extra, fname=fname, fcomment=fcomment, xfl=xfl)


def _get_flag_names(flags: int) -> list[str]:
    """Extract flag names from flag bitmask."""
    flag_mappings = [
        (GZIP_FLAG_FTEXT, "FTEXT"),
        (GZIP_FLAG_FHCRC, "FHCRC"),
        (GZIP_FLAG_FEXTRA, "FEXTRA"),
        (GZIP_FLAG_FNAME, "FNAME"),
        (GZIP_FLAG_FCOMMENT, "FCOMMENT"),
        (GZIP_FLAG_RESERVED1, "RESERVED1"),
        (GZIP_FLAG_RESERVED2, "RESERVED2"),
        (GZIP_FLAG_RESERVED3, "RESERVED3"),
    ]

    return [name for flag, name in flag_mappings if flags & flag]


def _safe_decode_bytes(data: bytes) -> str:
    """Safely decode bytes to string, falling back to repr on error."""
    try:
        return data.decode("utf-8", errors="replace")
    except Exception:
        return repr(data)


def format_gzip_header(header: GzipHeader) -> str:
    """Return a human-readable summary of gzip header fields."""
    lines = [
        f"mtime: {header.mtime}",
        f"OS: {header.os}",
        f"flags: {header.flags:08b}",
    ]

    flag_names = _get_flag_names(header.flags)
    lines.append(f"flag_names: {', '.join(flag_names) if flag_names else '(none)'}")

    if header.extra is not None:
        lines.append(f"extra: {len(header.extra)} bytes")

    if header.fname is not None:
        lines.append(f"fname: {_safe_decode_bytes(header.fname)}")

    if header.fcomment is not None:
        lines.append(f"fcomment: {_safe_decode_bytes(header.fcomment)}")

    return "\n".join(lines)


def _payload_offset(data: bytes) -> int | None:
    """Return the offset where the compressed payload starts, or None if the
    optional header fields cannot be walked."""
    data_flags = data[GZIP_FLAGS_POS]
    pos = GZIP_MIN_HEADER_SIZE
    if data_flags & GZIP_FLAG_FEXTRA:
        if pos + GZIP_XLEN_SIZE > len(data):
            return None
        pos += GZIP_XLEN_SIZE + int.from_bytes(data[pos : pos + GZIP_XLEN_SIZE], "little")
    for flag in (GZIP_FLAG_FNAME, GZIP_FLAG_FCOMMENT):
        if data_flags & flag:
            end = data.find(b"\x00", pos)
            if end == -1:
                return None
            pos = end + 1
    if data_flags & GZIP_FLAG_FHCRC:
        pos += 2
    return pos if pos <= len(data) else None


def patch_gzip_header(data: bytes, header: GzipHeader) -> bytes:
    """Patch gzip header fields to match the provided header (mtime, OS, flags, fname, fcomment, extra, xfl)."""
    if len(data) < GZIP_MIN_HEADER_SIZE or data[:2] != GZIP_MAGIC:
        return data

    # Locate the compressed payload by walking the optional fields present in
    # the generated data itself (its own flag byte decides what is there).
    pos = _payload_offset(data)
    if pos is None:
        return data
    body = data[pos:]

    # Emit only the optional-field bits we can actually satisfy; keep the
    # remaining flag bits (e.g. FTEXT) from the requested header.
    flags_out = header.flags & 0xFF
    if header.extra is None:
        flags_out &= ~GZIP_FLAG_FEXTRA
    if header.fname is None:
        flags_out &= ~GZIP_FLAG_FNAME
    if header.fcomment is None:
        flags_out &= ~GZIP_FLAG_FCOMMENT

    out = bytearray(data[:GZIP_FLAGS_POS])  # magic + method
    out.append(flags_out)
    out += header.mtime.to_bytes(GZIP_MTIME_SIZE, "little")
    out.append(header.xfl & 0xFF)
    out.append(header.os & 0xFF)
    if header.extra is not None:
        out += len(header.extra).to_bytes(GZIP_XLEN_SIZE, "little") + header.extra
    if header.fname is not None:
        out += header.fname + b"\x00"
    if header.fcomment is not None:
        out += header.fcomment + b"\x00"
    if flags_out & GZIP_FLAG_FHCRC:
        out += (zlib.crc32(bytes(out)) & 0xFFFF).to_bytes(2, "little")
    return bytes(out) + body


def _generate_header_match_candidate(src_bytes: bytes, header: GzipHeader) -> tuple[str, bytes]:
    """Generate a candidate that matches the exact header settings."""
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = Path(tmp.name)
        try:
            with gzip.GzipFile(filename="", mode="wb", fileobj=tmp_path.open("wb"), mtime=header.mtime) as gz:
                gz.write(src_bytes)
            data = tmp_path.read_bytes()
            data = patch_gzip_header(data, header)
            return ("header_match", data)
        finally:
            tmp_path.unlink()


def _get_available_tools() -> list[str]:
    """Get list of available compression tools."""
    tools = ["gzip"]
    try:
        subprocess.run(["pigz", "--version"], check=True, capture_output=True)  # nosec B603, B607
        tools.append("pigz")
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    return tools


def _build_command(tool: str, level: int, no_name: bool, rsyncable: bool) -> list[str]:
    """Build compression command with appropriate flags."""
    cmd = [tool, f"-{level}"]
    if no_name:
        cmd.append("-n")
    if rsyncable:
        cmd.append("--rsyncable")
    return cmd


def _generate_tool_candidate(  # noqa: PLR0913, PLR0917
    src: Path, tool: str, level: int, no_name: bool, rsyncable: bool, header: GzipHeader | None
) -> tuple[str, bytes] | None:
    """Generate a candidate using a specific tool and settings."""
    cmd = _build_command(tool, level, no_name, rsyncable)
    cmd.extend(["-c", str(src)])

    try:
        proc = subprocess.run(cmd, check=True, capture_output=True)  # nosec B603
        data = proc.stdout
        if header:
            data = patch_gzip_header(data, header)
        label = f"{tool} -{level}" + (" -n" if no_name else "") + (" --rsyncable" if rsyncable else "")
        return (label, data)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def generate_gzip_candidates(src: Path, header: GzipHeader | None, *, brute: bool = True) -> list[tuple[str, bytes]]:
    """Generate candidate gzip bytes for a source file using common tools/settings.

    With ``brute=False`` only the header-guided candidate is produced.
    """
    candidates: list[tuple[str, bytes]] = []
    src_bytes = src.read_bytes()

    # 1) Try to match header settings if available
    if header:
        candidates.append(_generate_header_match_candidate(src_bytes, header))

    if not brute:
        return candidates

    # 2) Brute-force common tools/levels
    tools = _get_available_tools()

    for tool in tools:
        for level in [GZIP_MIN_LEVEL, GZIP_DEFAULT_LEVEL, GZIP_MAX_LEVEL]:
            for no_name in [True, False]:
                rsyncable_options = [False, True] if tool == "gzip" else [False]
                for rsyncable in rsyncable_options:
                    candidate = _generate_tool_candidate(src, tool, level, no_name, rsyncable, header)
                    if candidate:
                        candidates.append(candidate)

    return candidates
