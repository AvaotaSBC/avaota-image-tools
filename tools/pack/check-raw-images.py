#!/usr/bin/env python3
"""Validate the V821 boot packages after they are placed in raw images.

The package files are checked before image assembly as well, but a raw image
must be checked at the offsets consumed by Boot0.  This catches accidentally
using the SD package in the NOR image, stale compressed TOCs, or a copy/truncation
error during raw image construction.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


SECTOR_SIZE = 512
PACKAGE_HEADER_SIZE = 64
PACKAGE_ITEM_SIZE = 368
PACKAGE_MAGIC = b"sunxi-package"
NOR_PACKAGE_LBA = 128
SD_PACKAGE_LBAS = (24576, 32800)


def c_string(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("ascii", errors="replace")


def package_items(package: bytes) -> list[tuple[str, int, int]]:
    if len(package) < PACKAGE_HEADER_SIZE or not package.startswith(PACKAGE_MAGIC):
        raise ValueError("missing sunxi-package header")
    count, valid_length = struct.unpack_from("<II", package, 32)
    table_end = PACKAGE_HEADER_SIZE + count * PACKAGE_ITEM_SIZE
    if not count or count > 64 or valid_length < table_end or valid_length > len(package):
        raise ValueError(
            f"invalid package table: count={count}, valid_length={valid_length:#x}"
        )

    items = []
    for index in range(count):
        base = PACKAGE_HEADER_SIZE + index * PACKAGE_ITEM_SIZE
        name = c_string(package[base : base + 64])
        offset, length = struct.unpack_from("<II", package, base + 64)
        if not name or offset < table_end or offset + length > valid_length:
            raise ValueError(
                f"invalid package item {index}: {name!r} @{offset:#x}+{length:#x}"
            )
        items.append((name, offset, length))
    return items


def load_package(path: Path) -> tuple[bytes, list[tuple[str, int, int]]]:
    data = path.read_bytes()
    items = package_items(data)
    names = [name for name, _, _ in items]
    if any(name.endswith("-lzma") for name in names):
        raise ValueError(f"{path}: compressed TOC entries are not allowed: {names}")
    return data, items


def check_at(raw_path: Path, package_path: Path, lba: int, expected: list[str]) -> None:
    raw = raw_path.read_bytes()
    source, source_items = load_package(package_path)
    source_names = [name for name, _, _ in source_items]
    if source_names != expected:
        raise ValueError(
            f"{package_path}: entries={source_names!r}, expected={expected!r}"
        )

    offset = lba * SECTOR_SIZE
    if offset + len(source) > len(raw):
        raise ValueError(
            f"{raw_path}: package at LBA {lba} exceeds raw image "
            f"({offset + len(source):#x} > {len(raw):#x})"
        )
    actual = raw[offset : offset + len(source)]
    if actual != source:
        raise ValueError(
            f"{raw_path}: package at LBA {lba} does not equal {package_path}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nor-raw", required=True, type=Path)
    parser.add_argument("--nor-package", required=True, type=Path)
    parser.add_argument("--sd-raw", required=True, type=Path)
    parser.add_argument("--sd-package", required=True, type=Path)
    args = parser.parse_args()

    try:
        nor_data = args.nor_raw.read_bytes()
        if len(nor_data) < 16 or nor_data[4:12] != b"eGON.BT0":
            raise ValueError(f"{args.nor_raw}: missing eGON.BT0 at byte offset 4")

        sd_data = args.sd_raw.read_bytes()
        sd_boot0_offset = 16 * SECTOR_SIZE
        if (
            len(sd_data) < sd_boot0_offset + 12
            or sd_data[sd_boot0_offset + 4 : sd_boot0_offset + 12] != b"eGON.BT0"
        ):
            raise ValueError(
                f"{args.sd_raw}: missing eGON.BT0 at LBA 16 byte offset "
                f"{sd_boot0_offset + 4}"
            )

        check_at(
            args.nor_raw,
            args.nor_package,
            NOR_PACKAGE_LBA,
            ["opensbi", "u-boot", "pmboot"],
        )
        for lba in SD_PACKAGE_LBAS:
            check_at(
                args.sd_raw,
                args.sd_package,
                lba,
                ["opensbi", "u-boot", "melis-elf"],
            )
    except (OSError, ValueError, struct.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(
        "ok: raw images contain uncompressed NOR package at LBA "
        f"{NOR_PACKAGE_LBA} and SD package at LBAs {SD_PACKAGE_LBAS}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
