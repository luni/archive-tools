"""Zstandard header parsing and brute-force generation utilities."""

import subprocess  # nosec B404
from dataclasses import dataclass
from pathlib import Path

# Zstandard format constants
ZSTD_MAGIC_NUMBER = b"\x28\xb5\x2f\xfd"
ZSTD_FRAME_HEADER_MIN_SIZE = 6  # Magic (4) + frame_header (2)
ZSTD_MAGIC_SIZE = 4
ZSTD_FRAME_HEADER_SIZE = 2

# Zstandard frame header descriptor byte (RFC 8878 3.1.1.1.1):
#   bits 7-6: Frame_Content_Size_flag, bit 5: Single_Segment_flag,
#   bit 4: Unused, bit 3: Reserved, bit 2: Content_Checksum_flag,
#   bits 1-0: Dictionary_ID_flag
ZSTD_DESCRIPTOR_FCS_FLAG_SHIFT = 6
ZSTD_DESCRIPTOR_SINGLE_SEGMENT = 0x20
ZSTD_DESCRIPTOR_UNUSED = 0x10
ZSTD_DESCRIPTOR_RESERVED = 0x08
ZSTD_DESCRIPTOR_CHECKSUM = 0x04
ZSTD_DESCRIPTOR_DICT_ID_MASK = 0x03
# Field sizes indexed by their descriptor flag values
ZSTD_FCS_SIZES = {0: 0, 1: 2, 2: 4, 3: 8}  # flag 0 -> 1 byte when single-segment
ZSTD_DICT_ID_SIZES = {0: 0, 1: 1, 2: 2, 3: 4}
# Window_Descriptor: bits 7-3 exponent (5 bits), bits 2-0 mantissa (3 bits);
# windowBase = 1 << (10 + exponent), window = windowBase * (1 + mantissa/8)
ZSTD_WINDOW_LOG_BASE = 10
ZSTD_WINDOW_MANTISSA_STEPS = 8

# Common compression levels for zstd
ZSTD_MIN_LEVEL = 1
ZSTD_DEFAULT_LEVEL = 3
ZSTD_MAX_LEVEL = 22
# Levels above this require --ultra
ZSTD_ULTRA_THRESHOLD = 19


@dataclass(frozen=True)
class ZstdHeader:
    """Zstandard frame header information."""

    window_log: int  # Window log exponent (10 + window-descriptor exponent)
    single_segment: bool  # Single segment flag
    has_checksum: bool  # Whether content checksum is enabled
    has_dict_id: bool  # Whether dictionary ID is present
    has_reserved: bool  # Whether reserved flag is set
    fcs_flag: int = 0  # Raw Frame_Content_Size_flag (bits 7-6 of descriptor)
    dict_id_flag: int = 0  # Raw Dictionary_ID_flag (bits 1-0); has_dict_id == (flag != 0)
    window_descriptor: int = 0  # Raw Window_Descriptor byte (only when not single-segment)


def _get_flag_names(descriptor: int) -> list[str]:
    """Extract flag names from the frame header descriptor byte."""
    names = [
        (ZSTD_DESCRIPTOR_SINGLE_SEGMENT, "SINGLE_SEGMENT"),
        (ZSTD_DESCRIPTOR_UNUSED, "UNUSED"),
        (ZSTD_DESCRIPTOR_RESERVED, "RESERVED"),
        (ZSTD_DESCRIPTOR_CHECKSUM, "CHECKSUM"),
    ]
    result = [name for flag, name in names if descriptor & flag]
    if descriptor & ZSTD_DESCRIPTOR_DICT_ID_MASK:
        result.append("DICT_ID")
    if descriptor >> ZSTD_DESCRIPTOR_FCS_FLAG_SHIFT:
        result.append("FCS")
    return result


def _get_window_size(window_log: int) -> str:
    """Get human-readable window size from window log."""
    if window_log == 0:
        return "N/A (single segment)"
    window_size = 1 << window_log
    return f"{window_size} bytes ({window_size / 1024:.1f} KB)"


def parse_zstd_header(path: Path) -> ZstdHeader | None:
    """Parse the Zstandard frame header from a file."""
    with path.open("rb") as f:
        data = f.read(ZSTD_FRAME_HEADER_MIN_SIZE)

    if len(data) < ZSTD_FRAME_HEADER_MIN_SIZE or not data.startswith(ZSTD_MAGIC_NUMBER):
        return None

    # Byte 4 is the Frame_Header_Descriptor; byte 5 is the Window_Descriptor
    # (present only when Single_Segment_flag is clear).
    descriptor = data[4]
    fcs_flag = descriptor >> ZSTD_DESCRIPTOR_FCS_FLAG_SHIFT
    single_segment = bool(descriptor & ZSTD_DESCRIPTOR_SINGLE_SEGMENT)
    has_checksum = bool(descriptor & ZSTD_DESCRIPTOR_CHECKSUM)
    dict_id_flag = descriptor & ZSTD_DESCRIPTOR_DICT_ID_MASK
    has_reserved = bool(descriptor & ZSTD_DESCRIPTOR_RESERVED)

    window_descriptor = 0
    window_log = 0
    if not single_segment:
        window_descriptor = data[5]
        window_log = ZSTD_WINDOW_LOG_BASE + (window_descriptor >> 3)

    return ZstdHeader(
        window_log=window_log,
        single_segment=single_segment,
        has_checksum=has_checksum,
        has_dict_id=bool(dict_id_flag),
        has_reserved=has_reserved,
        fcs_flag=fcs_flag,
        dict_id_flag=dict_id_flag,
        window_descriptor=window_descriptor,
    )


def format_zstd_header(header: ZstdHeader) -> str:
    """Return a human-readable summary of Zstd header fields."""
    lines = [
        f"window_log: {header.window_log}",
        f"window_size: {_get_window_size(header.window_log)}",
        f"single_segment: {header.single_segment}",
        f"has_checksum: {header.has_checksum}",
        f"has_dict_id: {header.has_dict_id}",
        f"has_reserved: {header.has_reserved}",
    ]

    # Reconstruct the descriptor byte for flag-name display
    flag_names = _get_flag_names(_descriptor_byte(header))
    if flag_names:
        lines.append(f"flag_names: {', '.join(flag_names)}")

    return "\n".join(lines)


def _descriptor_byte(header: ZstdHeader) -> int:
    """Reconstruct the frame descriptor byte from a parsed/constructed header."""
    # dict_id_flag may be unset on manually constructed headers
    dict_id_flag = header.dict_id_flag or (1 if header.has_dict_id else 0)
    return (
        (header.fcs_flag << ZSTD_DESCRIPTOR_FCS_FLAG_SHIFT)
        | (ZSTD_DESCRIPTOR_SINGLE_SEGMENT if header.single_segment else 0)
        | (ZSTD_DESCRIPTOR_CHECKSUM if header.has_checksum else 0)
        | (ZSTD_DESCRIPTOR_RESERVED if header.has_reserved else 0)
        | dict_id_flag
    )


def _frame_field_layout(descriptor: int) -> tuple[bool, int, int]:
    """Return (has_window_descriptor, dict_id_len, fcs_len) for a descriptor byte."""
    fcs_flag = descriptor >> ZSTD_DESCRIPTOR_FCS_FLAG_SHIFT
    single_segment = bool(descriptor & ZSTD_DESCRIPTOR_SINGLE_SEGMENT)
    dict_id_len = ZSTD_DICT_ID_SIZES[descriptor & ZSTD_DESCRIPTOR_DICT_ID_MASK]
    fcs_len = ZSTD_FCS_SIZES[fcs_flag]
    if fcs_flag == 0 and single_segment:
        fcs_len = 1  # single-segment frames carry a mandatory 1-byte FCS
    return not single_segment, dict_id_len, fcs_len


def patch_zstd_header(data: bytes, header: ZstdHeader) -> bytes:
    """Patch a Zstandard frame header to match the provided header.

    The descriptor controls the variable-length layout (window descriptor,
    dictionary ID, frame content size). Only patches that keep a consistent
    layout are applied; if the requested header would need fields that the
    data does not carry, or a different checksum flag (the xxHash trailer
    cannot be recomputed without decompressing), the input is returned
    unchanged.
    """
    if len(data) < ZSTD_FRAME_HEADER_MIN_SIZE or not data.startswith(ZSTD_MAGIC_NUMBER):
        return data

    data_desc = data[4]
    if bool(data_desc & ZSTD_DESCRIPTOR_CHECKSUM) != header.has_checksum:
        return data  # cannot recompute the xxHash-64 trailer

    win_d, dict_len_d, fcs_len_d = _frame_field_layout(data_desc)
    pos = ZSTD_MAGIC_SIZE + 1
    if win_d:
        pos += 1
    dict_bytes = data[pos : pos + dict_len_d]
    pos += dict_len_d
    fcs_bytes = data[pos : pos + fcs_len_d]
    if len(fcs_bytes) != fcs_len_d or len(dict_bytes) != dict_len_d:
        return data  # truncated frame header
    pos += fcs_len_d
    payload = data[pos:]

    # Layout demanded by the target header
    descriptor = _descriptor_byte(header)
    win_t, dict_len_t, fcs_len_t = _frame_field_layout(descriptor)
    if dict_len_t > len(dict_bytes) or fcs_len_t > len(fcs_bytes):
        return data  # would need field content we don't have
    out = bytearray(data[:ZSTD_MAGIC_SIZE])
    out.append(descriptor)
    if win_t:
        # Prefer the parsed window descriptor; otherwise approximate one
        # from the window_log exponent.
        if header.window_descriptor:
            out.append(header.window_descriptor)
        else:
            exponent = max(0, min(31, header.window_log - ZSTD_WINDOW_LOG_BASE))
            out.append(exponent << 3)
    out += dict_bytes[:dict_len_t]
    out += fcs_bytes[:fcs_len_t]
    out += payload
    return bytes(out)


def _generate_header_match_candidate(src: Path, header: ZstdHeader) -> tuple[str, bytes] | None:
    """Generate a candidate that matches the exact header settings.

    File input is used deliberately: zstd records Frame_Content_Size for
    seekable input (as downloaded files have), while stdin produces a
    streaming header without FCS.
    """
    cmd = ["zstd", "-c", "--stdout"]
    if not header.has_checksum:
        cmd.append("--no-check")
    cmd.append(str(src))
    try:
        proc = subprocess.run(cmd, capture_output=True, check=False)  # nosec B603
    except FileNotFoundError:
        return None
    if proc.returncode == 0:
        data = proc.stdout
        data = patch_zstd_header(data, header)
        return ("header_match", data)
    return None


def _get_available_tools() -> list[str]:
    """Get list of available compression tools."""
    tools = ["zstd"]
    try:
        subprocess.run(["pzstd", "--version"], check=True, capture_output=True)  # nosec B603, B607
        tools.append("pzstd")
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    return tools


def _build_command(tool: str, level: int) -> list[str]:
    """Build compression command with appropriate flags."""
    cmd = [tool, f"-{level}", "-c", "--stdout"]
    # zstd levels above 19 require --ultra
    if level > ZSTD_ULTRA_THRESHOLD:
        cmd.append("--ultra")
    return cmd


def _generate_tool_candidate(src: Path, tool: str, level: int, header: ZstdHeader | None) -> tuple[str, bytes] | None:
    """Generate a candidate using a specific tool and settings."""
    cmd = _build_command(tool, level)
    cmd.append(str(src))

    try:
        proc = subprocess.run(cmd, check=True, capture_output=True)  # nosec B603
        data = proc.stdout
        if header:
            data = patch_zstd_header(data, header)
        label = f"{tool} -{level}"
        return (label, data)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def generate_zstd_candidates(src: Path, header: ZstdHeader | None, *, brute: bool = True) -> list[tuple[str, bytes]]:
    """Generate candidate Zstandard bytes for a source file using common tools/settings.

    With ``brute=False`` only the header-guided candidate is produced.
    """
    candidates: list[tuple[str, bytes]] = []

    # 1) Try to match header settings if available
    if header:
        header_match = _generate_header_match_candidate(src, header)
        if header_match:
            candidates.append(header_match)

    if not brute:
        return candidates

    # 2) Brute-force common tools/levels
    tools = _get_available_tools()

    for tool in tools:
        for level in [ZSTD_MIN_LEVEL, ZSTD_DEFAULT_LEVEL, ZSTD_MAX_LEVEL]:
            candidate = _generate_tool_candidate(src, tool, level, header)
            if candidate:
                candidates.append(candidate)

    return candidates
