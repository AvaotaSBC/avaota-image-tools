#!/usr/bin/env python3
"""Validate the file table and selected payloads in a Phoenix IMAGEWTY file."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


IMAGE_MAGIC = b"IMAGEWTY"
IMAGE_HEADER_SIZE = 1024
IMAGE_ITEM_SIZE = 1024
IMAGE_ITEM_TABLE_OFFSET = IMAGE_HEADER_SIZE


def c_string(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("ascii", errors="replace").rstrip()


def parse_items(data: bytes) -> list[tuple[tuple[str, str, str], int, int]]:
    if len(data) < IMAGE_HEADER_SIZE or data[:8] != IMAGE_MAGIC:
        raise ValueError("missing IMAGEWTY header")

    declared_length = struct.unpack_from("<Q", data, 0x18)[0]
    item_size, item_count, item_offset = struct.unpack_from("<III", data, 0x38)
    if item_size != IMAGE_ITEM_SIZE:
        raise ValueError(f"unexpected item size: {item_size:#x}")
    if item_offset < IMAGE_HEADER_SIZE or item_offset % IMAGE_ITEM_SIZE:
        raise ValueError(f"invalid item table offset: {item_offset:#x}")
    if not item_count or item_count > 4096:
        raise ValueError(f"invalid item count: {item_count}")
    if declared_length != len(data):
        raise ValueError(
            f"image length mismatch: header={declared_length:#x}, file={len(data):#x}"
        )

    table_end = item_offset + item_count * item_size
    if table_end > len(data):
        raise ValueError("item table is outside the image")

    items = []
    for index in range(item_count):
        base = item_offset + index * item_size
        main_type = c_string(data[base + 8 : base + 16])
        sub_type = c_string(data[base + 16 : base + 32])
        name = c_string(data[base + 36 : base + 292])
        file_length, file_offset = (
            struct.unpack_from("<Q", data, base + 300)[0],
            struct.unpack_from("<Q", data, base + 308)[0],
        )
        if not name:
            raise ValueError(f"item {index} has an empty filename")
        if file_offset < table_end or file_offset + file_length > len(data):
            raise ValueError(
                f"item {name!r} is outside image: offset={file_offset:#x}, "
                f"length={file_length:#x}"
            )
        items.append(((main_type, sub_type, name), file_offset, file_length))
    return items


def parse_item(value: str) -> tuple[str, str, Path]:
    if ":" not in value:
        raise argparse.ArgumentTypeError("item must be MAIN:SUBTYPE=FILE")
    main_type, source = value.split(":", 1)
    if "=" not in source:
        raise argparse.ArgumentTypeError("item must be MAIN:SUBTYPE=FILE")
    sub_type, source_path = source.split("=", 1)
    if not main_type or not sub_type or not source_path:
        raise argparse.ArgumentTypeError("item must be MAIN:SUBTYPE=FILE")
    return main_type, sub_type, Path(source_path)


def parse_filename(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("filename must be NAME=FILE")
    name, source_path = value.split("=", 1)
    if not name or not source_path:
        raise argparse.ArgumentTypeError("filename must be NAME=FILE")
    return name, Path(source_path)


def check_payload(
    image: bytes,
    key: tuple[str, str, str],
    offset: int,
    length: int,
    source_path: Path,
) -> None:
    source = source_path.read_bytes()
    if length != len(source):
        raise ValueError(
            f"payload length mismatch for {key[2]!r}: "
            f"image={length:#x}, source={len(source):#x}"
        )
    if image[offset : offset + length] != source:
        raise ValueError(f"payload mismatch for {key[2]!r}: {source_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument(
        "--item",
        action="append",
        type=str,
        default=[],
        metavar="MAIN:SUBTYPE=FILE",
        help="require an embedded item to equal FILE; may be repeated",
    )
    parser.add_argument(
        "--filename",
        action="append",
        type=parse_filename,
        default=[],
        metavar="NAME=FILE",
        help="require every item named NAME to equal FILE; may be repeated",
    )
    args = parser.parse_args()

    try:
        image = args.image.read_bytes()
        items = parse_items(image)
        for value in args.item:
            main_type, sub_type, source_path = parse_item(value)
            candidates = [
                (key, offset, length)
                for key, offset, length in items
                if key[0] == main_type and key[1] == sub_type
            ]
            if len(candidates) != 1:
                raise ValueError(
                    f"expected one {main_type!r}/{sub_type!r} item, "
                    f"found {len(candidates)}"
                )
            (key, offset, length) = candidates[0]
            check_payload(image, key, offset, length, source_path)

        for name, source_path in args.filename:
            candidates = [
                (key, offset, length)
                for key, offset, length in items
                if key[2] == name
            ]
            if not candidates:
                raise ValueError(f"expected at least one item named {name!r}")
            for key, offset, length in candidates:
                check_payload(image, key, offset, length, source_path)
    except (OSError, ValueError, struct.error) as exc:
        print(f"error: {args.image}: {exc}", file=sys.stderr)
        return 1

    print(f"ok: {args.image}: {len(items)} items")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
