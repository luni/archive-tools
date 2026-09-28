"""XZ header parsing and brute-force generation utilities."""

import subprocess  # nosec B404
import zlib
from dataclasses import dataclass
from pathlib import Path

# XZ format constants
XZ_MAGIC = b"\xfd\x37\x7a\x58\x5a\x00"
XZ_HEADER_MIN_SIZE = 12  # Magic (6) + stream_flags (2) + crc32 (4)
XZ_STREAM_FLAGS_SIZE = 2
XZ_CRC32_SIZE = 4

# XZ check types
XZ_CHECK_NONE = 0x00
XZ_CHECK_CRC32 = 0x01
XZ_CHECK_CRC64 = 0x04
XZ_CHECK_SHA256 = 0x0A

# XZ stream flags: byte 6 must be zero, byte 7's low nibble holds the check
# type, so a flags word naming a check type has it shifted into the high byte
XZ_STREAM_FLAGS_NONE = 0
XZ_STREAM_FLAGS_CRC64 = XZ_CHECK_CRC64 << 8

# Common compression levels for xz
XZ_MIN_LEVEL = 0
XZ_DEFAULT_LEVEL = 6
XZ_MAX_LEVEL = 9


@dataclass(frozen=True)
class XzHeader:
    """XZ header information."""

    flags: int  # Stream flags
    has_crc64: bool  # Whether CRC64 is enabled
    check_type: int  # Check type (simplified)


def _get_flag_names(flags: int) -> list[str]:
    """Extract flag names from flag bitmask."""
    flag_mappings = [
        (XZ_STREAM_FLAGS_CRC64, "CRC64"),
    ]
    return [name for flag, name in flag_mappings if flags & flag]


def _get_check_name(check_type: int) -> str:
    """Get human-readable name for check type."""
    check_names = {
        XZ_CHECK_NONE: "NONE",
        XZ_CHECK_CRC32: "CRC32",
        XZ_CHECK_CRC64: "CRC64",
        XZ_CHECK_SHA256: "SHA256",
    }
    return check_names.get(check_type, f"UNKNOWN({check_type})")


def parse_xz_header(path: Path) -> XzHeader | None:
    """Parse the XZ header from a file."""
    with path.open("rb") as f:
        data = f.read(XZ_HEADER_MIN_SIZE)

    if len(data) < XZ_HEADER_MIN_SIZE or not data.startswith(XZ_MAGIC):
        return None

    # Stream flags (bytes 6-7): byte 6 must be 0, check type is the low
    # nibble of byte 7. Bytes 8-11 hold CRC32 over the flags themselves.
    if data[6] != 0 or data[7] & 0xF0:
        return None
    if zlib.crc32(data[6:8]) & 0xFFFFFFFF != int.from_bytes(data[8:12], "little"):
        return None

    flags = int.from_bytes(data[6:8], "little")
    check_type = data[7] & 0x0F
    has_crc64 = check_type == XZ_CHECK_CRC64

    return XzHeader(flags=flags, has_crc64=has_crc64, check_type=check_type)


def format_xz_header(header: XzHeader) -> str:
    """Return a human-readable summary of XZ header fields."""
    lines = [
        f"flags: {header.flags:08x}",
        f"check_type: {_get_check_name(header.check_type)}",
        f"has_crc64: {header.has_crc64}",
    ]

    flag_names = _get_flag_names(header.flags)
    if flag_names:
        lines.append(f"flag_names: {', '.join(flag_names)}")

    return "\n".join(lines)


def patch_xz_header(data: bytes, header: XzHeader) -> bytes:
    """Patch XZ header to match the provided header (flags)."""
    if len(data) < XZ_HEADER_MIN_SIZE or not data.startswith(XZ_MAGIC):
        return data

    # Replace the stream flags and recompute the CRC32 that covers them,
    # otherwise the patched header fails xz's own consistency check.
    # Byte 6 must be zero; the check type lives in byte 7's low nibble.
    patched = bytearray(data)
    patched[6:8] = (header.check_type << 8).to_bytes(XZ_STREAM_FLAGS_SIZE, "little")
    patched[8:12] = (zlib.crc32(patched[6:8]) & 0xFFFFFFFF).to_bytes(XZ_CRC32_SIZE, "little")

    return bytes(patched)


_XZ_CHECK_NAMES = {XZ_CHECK_NONE: "none", XZ_CHECK_CRC32: "crc32", XZ_CHECK_CRC64: "crc64", XZ_CHECK_SHA256: "sha256"}


def _generate_header_match_candidate(src_bytes: bytes, header: XzHeader) -> tuple[str, bytes] | None:
    """Generate a candidate that matches the exact header settings."""
    cmd = ["xz", "-c", "--stdout"]
    check_name = _XZ_CHECK_NAMES.get(header.check_type)
    if check_name:
        cmd.append(f"--check={check_name}")
    try:
        proc = subprocess.run(cmd, input=src_bytes, capture_output=True, check=False)  # nosec B603
    except FileNotFoundError:
        return None
    if proc.returncode == 0:
        data = proc.stdout
        data = patch_xz_header(data, header)
        return ("header_match", data)
    return None


def _get_available_tools() -> list[str]:
    """Get list of available compression tools."""
    tools = ["xz"]
    try:
        subprocess.run(["pixz", "--version"], check=True, capture_output=True)  # nosec B603, B607
        tools.append("pixz")
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    return tools


def _build_command(tool: str, level: int) -> list[str]:
    """Build compression command with appropriate flags."""
    if tool == "xz":
        return ["xz", f"-{level}", "-c", "--stdout"]
    else:  # pixz
        return ["pixz", f"-{level}", "-c", "--stdout"]


def _generate_tool_candidate(src: Path, tool: str, level: int, header: XzHeader | None) -> tuple[str, bytes] | None:
    """Generate a candidate using a specific tool and settings."""
    cmd = _build_command(tool, level)
    cmd.append(str(src))

    try:
        proc = subprocess.run(cmd, check=True, capture_output=True)  # nosec B603
        data = proc.stdout
        if header:
            data = patch_xz_header(data, header)
        label = f"{tool} -{level}"
        return (label, data)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def generate_xz_candidates(src: Path, header: XzHeader | None, *, brute: bool = True) -> list[tuple[str, bytes]]:
    """Generate candidate XZ bytes for a source file using common tools/settings.

    With ``brute=False`` only the header-guided candidate is produced.
    """
    candidates: list[tuple[str, bytes]] = []
    src_bytes = src.read_bytes()

    # 1) Try to match header settings if available
    if header:
        header_match = _generate_header_match_candidate(src_bytes, header)
        if header_match:
            candidates.append(header_match)

    if not brute:
        return candidates

    # 2) Brute-force common tools/levels
    tools = _get_available_tools()

    for tool in tools:
        for level in [XZ_MIN_LEVEL, XZ_DEFAULT_LEVEL, XZ_MAX_LEVEL]:
            candidate = _generate_tool_candidate(src, tool, level, header)
            if candidate:
                candidates.append(candidate)

    return candidates
