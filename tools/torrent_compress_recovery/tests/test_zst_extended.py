"""Extended tests for ZSTD module to improve coverage."""

from torrent_compress_recovery.zst import (
    ZSTD_DESCRIPTOR_CHECKSUM,
    ZSTD_DESCRIPTOR_DICT_ID_MASK,
    ZSTD_DESCRIPTOR_RESERVED,
    ZSTD_DESCRIPTOR_SINGLE_SEGMENT,
    ZSTD_DESCRIPTOR_UNUSED,
)


def test_zstd_descriptor_constants():
    """Test ZSTD frame descriptor constants match RFC 8878."""
    assert ZSTD_DESCRIPTOR_SINGLE_SEGMENT == 0x20
    assert ZSTD_DESCRIPTOR_UNUSED == 0x10
    assert ZSTD_DESCRIPTOR_RESERVED == 0x08
    assert ZSTD_DESCRIPTOR_CHECKSUM == 0x04
    assert ZSTD_DESCRIPTOR_DICT_ID_MASK == 0x03


def test_zstd_descriptor_flag_values():
    """Test that descriptor flags have expected bit positions."""
    for flag in [
        ZSTD_DESCRIPTOR_SINGLE_SEGMENT,
        ZSTD_DESCRIPTOR_UNUSED,
        ZSTD_DESCRIPTOR_RESERVED,
        ZSTD_DESCRIPTOR_CHECKSUM,
    ]:
        assert flag & (flag - 1) == 0  # Power of 2 check

    # Dictionary ID flag is a 2-bit field, not a single bit
    assert ZSTD_DESCRIPTOR_DICT_ID_MASK & (ZSTD_DESCRIPTOR_DICT_ID_MASK - 1) != 0
