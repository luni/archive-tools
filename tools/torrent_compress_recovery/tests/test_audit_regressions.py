"""Regression tests for bugs found in the second audit pass.

Covers: path traversal in torrent metadata, in-place recovery of files in
subdirectories, dry-run side effects, missing tool binaries, real xz/zstd
header parsing, and gzip FEXTRA fields larger than the initial read buffer.
"""

import gzip
import hashlib
import os
import shutil
import struct
import zlib
from pathlib import Path

import bencodepy
import pytest

from torrent_compress_recovery.bencode import BencodeError, parse_torrent
from torrent_compress_recovery.core import _extract_raw_name, recover


def _make_torrent(path: Path, files: list[tuple[str | list[str], bytes]], piece_length: int = 16384, name: bytes = b"t") -> Path:
    """Build a v1 torrent whose pieces hash the concatenated file contents.

    Each file is (path, content); path may be a "/" string or an explicit
    list of path components (needed to encode malicious components that
    pathlib would normalize away).
    """
    data = b"".join(content for _, content in files)
    pieces = b""
    for i in range(0, max(len(data), 1), piece_length):
        pieces += hashlib.sha1(data[i : i + piece_length]).digest()

    def parts_of(rel: str | list[str]) -> list[bytes]:
        if isinstance(rel, str):
            return [p.encode() for p in Path(rel).parts]
        return [p.encode() for p in rel]

    info = {
        b"name": name,
        b"piece length": piece_length,
        b"pieces": pieces,
        b"files": [{b"length": len(content), b"path": parts_of(rel)} for rel, content in files],
    }
    path.write_bytes(bencodepy.encode({b"info": info}))
    return path


def _dirs(tmp_path: Path) -> tuple[Path, Path, Path]:
    raw, partial = tmp_path / "raw", tmp_path / "partial"
    raw.mkdir()
    partial.mkdir()
    return raw, partial, tmp_path / "target"


# ---------------------------------------------------------------------------
# Path traversal
# ---------------------------------------------------------------------------


def test_torrent_path_traversal_rejected(tmp_path: Path):
    tp = _make_torrent(tmp_path / "t.torrent", [("../escape.gz", b"x")])
    with pytest.raises(BencodeError, match="Unsafe path"):
        parse_torrent(str(tp))


def test_torrent_name_traversal_rejected(tmp_path: Path):
    tp = _make_torrent(tmp_path / "t.torrent", [("f.gz", b"x")], name=b"..")
    with pytest.raises(BencodeError, match="Unsafe torrent name"):
        parse_torrent(str(tp))


def test_torrent_absolute_and_backslash_components_rejected(tmp_path: Path):
    for parts in (["/abs.gz"], ["a\\b.gz"], ["a", "", "b.gz"], ["a", ".", "b.gz"], ["a", "..", "b.gz"]):
        tp = _make_torrent(tmp_path / "t.torrent", [(parts, b"x")])
        with pytest.raises(BencodeError):
            parse_torrent(str(tp))


# ---------------------------------------------------------------------------
# In-place recovery: files inside subdirectories must be recognized as
# already-in-place rather than copied to the partial-dir root
# ---------------------------------------------------------------------------


def test_inplace_recovery_in_subdirectory(tmp_path: Path):
    raw, partial, _ = _dirs(tmp_path)
    sub = partial / "sub"
    sub.mkdir()
    gz = gzip.compress(b"hello")
    (sub / "f.gz").write_bytes(gz)
    tp = _make_torrent(tmp_path / "t.torrent", [("sub/f.gz", gz)])

    # overwrite=True so the existing destination is still verified/reused
    result = recover(tp, raw, partial, None, overwrite=True)

    assert result.recovered == 1
    assert (sub / "f.gz").read_bytes() == gz
    # Must NOT have duplicated the file at the partial-dir root
    assert not (partial / "f.gz").exists()


def test_inplace_no_overwrite_skips_existing(tmp_path: Path):
    raw, partial, _ = _dirs(tmp_path)
    gz = gzip.compress(b"hello")
    (partial / "f.gz").write_bytes(gz)
    tp = _make_torrent(tmp_path / "t.torrent", [("f.gz", gz)])

    result = recover(tp, raw, partial, None, overwrite=False)

    assert result.recovered == 0
    assert result.skipped == 1


def test_inplace_distinct_subdirs_no_basename_collision(tmp_path: Path):
    """a/f.gz and b/f.gz must not share one destination in in-place mode."""
    raw, partial, _ = _dirs(tmp_path)
    gz_a = gzip.compress(b"content-a")
    gz_b = gzip.compress(b"content-b")
    (partial / "a").mkdir()
    (partial / "b").mkdir()
    (partial / "a" / "f.gz").write_bytes(gz_a)
    (partial / "b" / "f.gz").write_bytes(gz_b)
    # Small pieces so each file contains at least one fully verifiable piece
    tp = _make_torrent(tmp_path / "t.torrent", [("a/f.gz", gz_a), ("b/f.gz", gz_b)], piece_length=8)

    result = recover(tp, raw, partial, None, overwrite=True)

    assert result.recovered == 2
    assert (partial / "a" / "f.gz").read_bytes() == gz_a
    assert (partial / "b" / "f.gz").read_bytes() == gz_b


# ---------------------------------------------------------------------------
# Files not starting at a piece boundary are still recoverable as long as a
# whole piece lies inside the file's data
# ---------------------------------------------------------------------------


def test_recovers_file_starting_mid_piece(tmp_path: Path):
    raw, partial, target = _dirs(tmp_path)
    filler = gzip.compress(b"filler-data")
    gz = gzip.compress(b"real-content")
    # Tiny pieces so f2.gz (which starts mid-piece) contains full pieces
    tp = _make_torrent(tmp_path / "t.torrent", [("f1.gz", filler), ("f2.gz", gz)], piece_length=8)
    (partial / "f2.gz").write_bytes(gz)

    result = recover(tp, raw, partial, target)

    assert result.recovered == 1
    assert (target / "t" / "f2.gz").read_bytes() == gz


@pytest.mark.skipif(not shutil.which("gzip"), reason="gzip tool not available")
def test_recompress_file_starting_mid_piece(tmp_path: Path):
    import subprocess

    raw, partial, target = _dirs(tmp_path)
    filler = gzip.compress(b"filler-data")
    raw_content = b"regeneration-target-content"
    (raw / "f2").write_bytes(raw_content)
    # The torrent content is the deterministic python-gzip output; the
    # recovery path generates the same bytes via gzip tooling
    gz = subprocess.run(["gzip", "-n", "-6", "-c"], input=raw_content, capture_output=True, check=True).stdout
    tp = _make_torrent(tmp_path / "t.torrent", [("f1.gz", filler), ("f2.gz", gz)], piece_length=8)

    result = recover(tp, raw, partial, target, raw_fallback=True)

    assert result.gzipped == 1
    assert (target / "t" / "f2.gz").read_bytes() == gz


# ---------------------------------------------------------------------------
# All same-named partial candidates must be tried, not only the newest
# ---------------------------------------------------------------------------


def test_partial_recovery_tries_all_same_name_candidates(tmp_path: Path):
    import os

    raw, partial, target = _dirs(tmp_path)
    gz = gzip.compress(b"good-content")
    (partial / "old").mkdir()
    (partial / "new").mkdir()
    (partial / "old" / "f.gz").write_bytes(gz)  # valid, older
    bad = partial / "new" / "f.gz"
    bad.write_bytes(b"garbage-garbage")
    os.utime(bad, (2**31, 2**31))  # make the corrupt one the newest
    tp = _make_torrent(tmp_path / "t.torrent", [("f.gz", gz)])

    result = recover(tp, raw, partial, target)

    assert result.recovered == 1
    assert (target / "t" / "f.gz").read_bytes() == gz


# ---------------------------------------------------------------------------
# BEP47 sha1 is authoritative: a piece match alone must not be written
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not shutil.which("gzip"), reason="gzip tool not available")
def test_bep47_sha1_mismatch_rejects_candidate(tmp_path: Path):
    import subprocess

    raw, partial, target = _dirs(tmp_path)
    raw_content = b"some-raw-content"
    (raw / "f").write_bytes(raw_content)
    gz = subprocess.run(["gzip", "-n", "-6", "-c"], input=raw_content, capture_output=True, check=True).stdout

    data = gz
    pieces = hashlib.sha1(data).digest()
    info = {
        b"name": b"t",
        b"piece length": 16384,
        b"pieces": pieces,
        # wrong (non-matching) BEP47 sha1 on purpose
        b"files": [{b"length": len(gz), b"path": [b"f.gz"], b"sha1": b"\x00" * 20}],
    }
    tp = tmp_path / "t.torrent"
    tp.write_bytes(bencodepy.encode({b"info": info}))

    result = recover(tp, raw, partial, target, raw_fallback=True)

    # The generated file would match the piece but NOT the file sha1 ->
    # it must not be accepted
    assert result.gzipped == 0
    assert result.missing == 1
    assert not (target / "t" / "f.gz").exists()


# ---------------------------------------------------------------------------
# Uppercase compression extensions are recognized
# ---------------------------------------------------------------------------


def test_uppercase_extension_recovered(tmp_path: Path):
    raw, partial, target = _dirs(tmp_path)
    gz = gzip.compress(b"upper-case")
    (partial / "F.GZ").write_bytes(gz)
    tp = _make_torrent(tmp_path / "t.torrent", [("F.GZ", gz)])

    result = recover(tp, raw, partial, target)

    assert result.recovered == 1
    assert (target / "t" / "F.GZ").read_bytes() == gz


# ---------------------------------------------------------------------------
# verify: raw files in subdirectories and variant suffixes are found
# ---------------------------------------------------------------------------


def test_verify_finds_raw_in_subdirectory(tmp_path: Path):
    from torrent_compress_recovery.verify import verify_last_piece_against_raw

    raw = tmp_path / "raw"
    partial = tmp_path / "partial"
    (raw / "deep").mkdir(parents=True)
    partial.mkdir()
    content = b"verify-me"
    (raw / "deep" / "f").write_bytes(content)
    (partial / "f.gz").write_bytes(gzip.compress(content))
    tp = _make_torrent(tmp_path / "t.torrent", [("f.gz", gzip.compress(content))])

    results = verify_last_piece_against_raw(tp, raw, partial)

    assert results == {"f.gz": True}


# ---------------------------------------------------------------------------
# dry-run must not create directories or files
# ---------------------------------------------------------------------------


def test_dry_run_creates_nothing(tmp_path: Path):
    raw, partial, target = _dirs(tmp_path)
    gz = gzip.compress(b"hello")
    (partial / "f.gz").write_bytes(gz)
    tp = _make_torrent(tmp_path / "t.torrent", [("sub/f.gz", gz)])

    result = recover(tp, raw, partial, target, dry_run=True)

    assert result.recovered == 1
    assert not target.exists()
    assert not (tmp_path / "target" / "sub").exists()


# ---------------------------------------------------------------------------
# Missing tool binaries must not crash candidate generation
# ---------------------------------------------------------------------------


def test_generate_xz_candidates_missing_tool(tmp_path: Path, monkeypatch):
    from torrent_compress_recovery.xz import XzHeader, generate_xz_candidates

    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    f = tmp_path / "f.bin"
    f.write_bytes(b"data")
    assert generate_xz_candidates(f, XzHeader(flags=0, has_crc64=True, check_type=4)) == []


def test_generate_zstd_candidates_missing_tool(tmp_path: Path, monkeypatch):
    from torrent_compress_recovery.zst import ZstdHeader, generate_zstd_candidates

    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    f = tmp_path / "f.bin"
    f.write_bytes(b"data")
    h = ZstdHeader(window_log=20, single_segment=False, has_checksum=True, has_dict_id=False, has_reserved=False)
    assert generate_zstd_candidates(f, h) == []


# ---------------------------------------------------------------------------
# Real-format header parsing (needs the actual tools to build files)
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not shutil.which("xz"), reason="xz tool not available")
def test_parse_xz_header_real_check_types(tmp_path: Path):
    import subprocess

    from torrent_compress_recovery.xz import parse_xz_header

    src = tmp_path / "f.bin"
    src.write_bytes(b"data" * 100)

    for check, expected_type, expected_crc64 in (("crc32", 1, False), ("crc64", 4, True), ("none", 0, False), ("sha256", 10, False)):
        xz_path = tmp_path / f"f_{check}.xz"
        xz_path.write_bytes(subprocess.run(["xz", f"--check={check}", "-c", str(src)], capture_output=True, check=True).stdout)
        header = parse_xz_header(xz_path)
        assert header is not None
        assert header.check_type == expected_type, check
        assert header.has_crc64 is expected_crc64, check


@pytest.mark.skipif(not shutil.which("xz"), reason="xz tool not available")
def test_patch_xz_header_keeps_header_crc_valid(tmp_path: Path):
    """A patched header must have a valid stream-header CRC32."""
    import subprocess

    from torrent_compress_recovery.xz import XzHeader, patch_xz_header

    src = tmp_path / "f.bin"
    src.write_bytes(b"data")
    data = subprocess.run(["xz", "--check=crc64", "-c", str(src)], capture_output=True, check=True).stdout

    patched = patch_xz_header(data, XzHeader(flags=0, has_crc64=False, check_type=1))
    # Stream flags now claim crc32; header CRC32 must be recomputed accordingly
    flags = patched[6:8]
    assert flags[0] == 0
    assert flags[1] & 0x0F == 1
    assert patched[8:12] == struct.pack("<I", zlib.crc32(flags) & 0xFFFFFFFF)


@pytest.mark.skipif(not shutil.which("zstd"), reason="zstd tool not available")
def test_parse_zstd_header_real_files(tmp_path: Path):
    import subprocess

    from torrent_compress_recovery.zst import parse_zstd_header

    src = tmp_path / "f.bin"
    src.write_bytes(b"x" * 100000)

    checked = tmp_path / "checked.zst"
    checked.write_bytes(subprocess.run(["zstd", "-c", str(src)], capture_output=True, check=True).stdout)
    h = parse_zstd_header(checked)
    assert h is not None and h.has_checksum

    nocheck = tmp_path / "nocheck.zst"
    nocheck.write_bytes(subprocess.run(["zstd", "--no-check", "-c", str(src)], capture_output=True, check=True).stdout)
    h = parse_zstd_header(nocheck)
    assert h is not None and not h.has_checksum


@pytest.mark.skipif(not shutil.which("zstd"), reason="zstd tool not available")
def test_patch_zstd_header_roundtrip(tmp_path: Path):
    """Patching a header to its own parsed values must reproduce the frame."""
    import subprocess

    from torrent_compress_recovery.zst import parse_zstd_header, patch_zstd_header

    src = tmp_path / "f.bin"
    src.write_bytes(b"x" * 100000)
    zst_path = tmp_path / "f.zst"
    zst_path.write_bytes(subprocess.run(["zstd", "--no-check", "-c", str(src)], capture_output=True, check=True).stdout)

    data = zst_path.read_bytes()
    header = parse_zstd_header(zst_path)
    assert header is not None
    assert patch_zstd_header(data, header) == data


# ---------------------------------------------------------------------------
# gzip FEXTRA larger than the initial 256-byte read buffer
# ---------------------------------------------------------------------------


def test_parse_gzip_header_large_fextra(tmp_path: Path):
    from torrent_compress_recovery.gzip import parse_gzip_header

    extra_payload = b"AB" + (400).to_bytes(2, "little") + b"x" * 400
    header = bytearray()
    header += b"\x1f\x8b\x08"
    header += b"\x0c"  # FLG: FEXTRA | FNAME
    header += b"\x00" * 6
    header += len(extra_payload).to_bytes(2, "little")
    header += extra_payload
    header += b"name.txt\x00"
    header += b"payload-bytes"

    p = tmp_path / "big_extra.gz"
    p.write_bytes(bytes(header))

    parsed = parse_gzip_header(p)
    assert parsed is not None
    assert parsed.fname == b"name.txt"  # FNAME sits beyond the first 256 bytes
    assert parsed.extra is not None and len(parsed.extra) == 400 + 4


# ---------------------------------------------------------------------------
# CLI error paths must return an exit code, not a traceback
# ---------------------------------------------------------------------------


def test_cli_verify_only_bad_torrent_no_traceback(tmp_path: Path, capsys):
    from torrent_compress_recovery.cli import main

    tp = tmp_path / "bad.torrent"
    tp.write_bytes(b"not bencoded at all")
    result = main(["--torrent", str(tp), "--raw-dir", str(tmp_path / "r"), "--partial-dir", str(tmp_path / "p"), "--verify-only"])
    assert result == 1


def test_cli_verify_only_missing_torrent_no_traceback(tmp_path: Path):
    from torrent_compress_recovery.cli import main

    tp = tmp_path / "missing.torrent"
    result = main(["--torrent", str(tp), "--raw-dir", str(tmp_path / "r"), "--partial-dir", str(tmp_path / "p"), "--verify-only"])
    assert result == 1


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="chmod ineffective as root")
def test_cli_header_info_skips_unreadable(tmp_path: Path):
    from torrent_compress_recovery.cli import main

    partial = tmp_path / "partial"
    partial.mkdir()
    bad = partial / "bad.gz"
    bad.write_bytes(b"\x1f\x8b\x08\x00junk")
    bad.chmod(0)  # unreadable
    try:
        result = main(["--raw-dir", str(tmp_path / "r"), "--partial-dir", str(partial), "--header-info"])
    finally:
        bad.chmod(0o644)
    assert result == 0


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="chmod ineffective as root")
def test_recover_isolates_unwritable_destination(tmp_path: Path):
    raw, partial, target = _dirs(tmp_path)
    gz = gzip.compress(b"data")
    (partial / "f.gz").write_bytes(gz)
    tp = _make_torrent(tmp_path / "t.torrent", [("sub/f.gz", gz)])
    target.mkdir()
    target.chmod(0o555)  # read-only target
    try:
        result = recover(tp, raw, partial, target)
    finally:
        target.chmod(0o755)
    # The write failure is isolated: counted missing, run continues
    assert result.missing == 1
    assert result.recovered == 0


# ---------------------------------------------------------------------------
# _extract_raw_name strips variant suffixes for every format
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("data.bin.pigz9.gz", "data.bin"),
        ("data.bin.pigz_rsync.gz", "data.bin"),
        ("d.bz6.bz2", "d"),
        ("d.pbz1.bz2", "d"),
        ("d.xz9.xz", "d"),
        ("d.pixz0.xz", "d"),
        ("d.zst19.zst", "d"),
        ("d.pzstd3.zst", "d"),
        ("f.tar.gz", "f.tar"),
    ],
)
def test_extract_raw_name_variant_suffixes(name: str, expected: str):
    assert _extract_raw_name(name, name) == expected
