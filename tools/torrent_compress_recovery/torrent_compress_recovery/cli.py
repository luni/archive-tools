"""CLI entrypoint for torrent-compress-recovery."""

import argparse
import logging
from pathlib import Path

from .bencode import BencodeError
from .bz2 import format_bzip2_header, parse_bzip2_header
from .core import recover
from .gzip import format_gzip_header, parse_gzip_header
from .verify import verify_last_piece_against_raw
from .xz import format_xz_header, parse_xz_header
from .zst import format_zstd_header, parse_zstd_header


def _run_header_info(args: argparse.Namespace) -> int:
    """Step A: display compression header info for partial files."""
    # Built here (not at module level) so the entries resolve to the current
    # module attributes — tests patch parse_gzip_header & friends.
    header_tools = {
        ".gz": (parse_gzip_header, format_gzip_header),
        ".bz2": (parse_bzip2_header, format_bzip2_header),
        ".xz": (parse_xz_header, format_xz_header),
        ".zst": (parse_zstd_header, format_zstd_header),
    }
    for p in args.partial_dir.rglob("*"):
        if not p.is_file():
            continue
        # Skip if filename filter is specified and doesn't match
        if args.filename and p.name != args.filename:
            continue
        tools = header_tools.get(p.suffix.lower())
        if tools is None:
            continue
        try:
            header = tools[0](p)
        except OSError as e:
            logging.warning(f"{p}: cannot read header: {e}")
            continue
        if header is None:
            continue
        logging.info(f"--- {p.relative_to(args.partial_dir)} ---")
        logging.info(tools[1](header))
        logging.info("")
    return 0


def _run_verify_only(args: argparse.Namespace) -> int:
    """Step B: verify raw files against gzip trailers (last piece)."""
    if args.torrent is None:
        logging.error("--verify-only requires --torrent")
        return 2
    results = verify_last_piece_against_raw(args.torrent, args.raw_dir, args.partial_dir)
    any_missing = False
    for name, ok in results.items():
        status = "OK" if ok else "FAIL"
        logging.info(f"{name}: {status}")
        if not ok:
            any_missing = True
    return 1 if any_missing else 0


def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "Recover compressed files referenced by a .torrent by searching for matching files in two input folders. "
            "Folder structure in inputs is ignored; files are matched by basename. "
            "If a compressed file is not found, the tool can optionally compress the corresponding raw file."
        )
    )
    modes = ap.add_mutually_exclusive_group()
    modes.add_argument(
        "--header-info",
        action="store_true",
        help="Step A: Show compression header info for partial files and exit",
    )
    modes.add_argument(
        "--verify-only",
        action="store_true",
        help="Step B: Verify raw files against compression trailers (last piece) and exit",
    )
    ap.add_argument(
        "--brute-force",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Step C: Try candidate generators/levels when recompressing raw files (use --no-brute-force to limit fallback to the header-guided candidate)",
    )
    ap.add_argument(
        "--torrent",
        type=Path,
        help="Path to the .torrent file (required except for --header-info)",
    )
    ap.add_argument(
        "--raw-dir",
        type=Path,
        required=True,
        help="Folder containing uncompressed raw data",
    )
    ap.add_argument(
        "--partial-dir",
        type=Path,
        required=True,
        help="Folder containing partially/fully downloaded compressed files",
    )
    ap.add_argument(
        "--target-dir",
        type=Path,
        help="Output folder (optional - if not specified, files will be recovered in-place in partial-dir)",
    )
    ap.add_argument(
        "--filename",
        type=str,
        help="Process only this specific filename (basename match)",
    )
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--raw-fallback",
        action="store_true",
        help="If a required compressed file is not found in partial_dir, try compressing the corresponding raw file (basename without extension)",
    )
    ap.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing output files",
    )
    return ap


def main(argv: list[str] | None = None) -> int:
    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    args = _build_parser().parse_args(argv)

    try:
        if args.header_info:
            return _run_header_info(args)

        if args.verify_only:
            return _run_verify_only(args)

        if args.torrent is None:
            logging.error("the following argument is required: --torrent")
            return 2

        result = recover(
            torrent_path=args.torrent,
            raw_dir=args.raw_dir,
            partial_dir=args.partial_dir,
            target_dir=args.target_dir,
            raw_fallback=args.raw_fallback,
            overwrite=args.overwrite,
            dry_run=args.dry_run,
            filename_filter=args.filename,
            brute_force=args.brute_force,
        )
    except BencodeError as e:
        logging.error(f"Failed to parse torrent: {e}")
        return 1
    except OSError as e:
        logging.error(f"I/O error: {e}")
        return 1

    torrent_name = args.torrent.stem
    out_root = args.target_dir or args.partial_dir
    compressed_total = result.gzipped + result.bzipped + result.xzipped + result.zstipped
    logging.info(f"torrent: {torrent_name}")
    logging.info(f"output:  {out_root}")
    logging.info(f"recovered_from_partial: {result.recovered}")
    logging.info(f"compressed_from_raw:    {compressed_total} (gz={result.gzipped}, bz2={result.bzipped}, xz={result.xzipped}, zst={result.zstipped})")
    logging.info(f"skipped:                {result.skipped}")
    logging.info(f"missing:                {result.missing}")

    return 0 if result.missing == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
