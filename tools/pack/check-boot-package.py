#!/usr/bin/env python3
"""Validate an Allwinner V821 DragonSecBoot boot package.

The V821 Boot0 accepts several TOC item names for the same payload, including
compressed names such as ``opensbi-lzma`` and ``u-boot-lzma``.  The Avaota-F1
Tina configuration uses the uncompressed names, and the NOR and SD packages
must contain different U-Boot binaries.  This small host-side check makes
those two requirements explicit before an image is published.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


ITEM_SIZE = 368
ITEM_NAME_SIZE = 64
HEADER_SIZE = 64
MAGIC = b"sunxi-package"


def c_string(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("ascii", errors="replace")


def parse_items(data: bytes) -> list[tuple[str, int, int]]:
    if len(data) < HEADER_SIZE or data[: len(MAGIC)] != MAGIC:
        raise ValueError("missing sunxi-package header")

    item_count, valid_length = struct.unpack_from("<II", data, 32)
    table_end = HEADER_SIZE + item_count * ITEM_SIZE
    if not item_count or item_count > 64:
        raise ValueError(f"invalid TOC item count: {item_count}")
    if valid_length < table_end or valid_length > len(data):
        raise ValueError(
            f"invalid package length: valid={valid_length:#x}, file={len(data):#x}"
        )

    items = []
    for index in range(item_count):
        base = HEADER_SIZE + index * ITEM_SIZE
        name = c_string(data[base : base + ITEM_NAME_SIZE])
        offset, length = struct.unpack_from("<II", data, base + 64)
        if not name:
            raise ValueError(f"TOC item {index} has an empty name")
        if offset < table_end or offset + length > valid_length:
            raise ValueError(
                f"TOC item {name!r} is outside package: "
                f"offset={offset:#x} length={length:#x} valid={valid_length:#x}"
            )
        items.append((name, offset, length))

    return items


def parse_match(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("match must be NAME=FILE")
    name, path = value.split("=", 1)
    if not name or not path:
        raise argparse.ArgumentTypeError("match must be NAME=FILE")
    return name, Path(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument(
        "--entries",
        required=True,
        help="comma-separated TOC names in the expected order",
    )
    parser.add_argument(
        "--match",
        action="append",
        type=parse_match,
        default=[],
        metavar="NAME=FILE",
        help="require the TOC payload NAME to equal FILE; may be repeated",
    )
    args = parser.parse_args()

    try:
        package = args.package.read_bytes()
        items = parse_items(package)
        actual_names = [name for name, _, _ in items]
        expected_names = [name for name in args.entries.split(",") if name]
        if actual_names != expected_names:
            raise ValueError(
                f"unexpected TOC entries: got {actual_names!r}, "
                f"expected {expected_names!r}"
            )

        by_name = {name: (offset, length) for name, offset, length in items}
        for name, source_path in args.match:
            if name not in by_name:
                raise ValueError(f"missing TOC item {name!r}")
            source = source_path.read_bytes()
            offset, length = by_name[name]
            if length != len(source):
                raise ValueError(
                    f"payload length mismatch for {name!r}: "
                    f"package={length:#x}, source={len(source):#x}"
                )
            if package[offset : offset + length] != source:
                raise ValueError(f"payload mismatch for {name!r}: {source_path}")
    except (OSError, ValueError, struct.error) as exc:
        print(f"error: {args.package}: {exc}", file=sys.stderr)
        return 1

    print(f"ok: {args.package}: {', '.join(expected_names)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
