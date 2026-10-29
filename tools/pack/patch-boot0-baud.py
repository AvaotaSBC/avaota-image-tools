#!/usr/bin/env python3
"""Set the V821 Boot0/PMBoot UART divisor to 115200 baud.

The V821 vendor DRAM stage uses Andes-specific instructions and relocation
types, so it cannot be rebuilt with Buildroot's generic RISC-V binutils.  The
serial setup is nevertheless a normal RISC-V instruction sequence.  Patch
that board-specific sequence with bytes produced by the Buildroot assembler,
then recalculate the Allwinner add-sum so the image remains bootable.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


STAMP_VALUE = 0x5F0A6C39
OLD = bytes.fromhex("23 22 05 00 a1 47 1c c1")
NEW = bytes.fromhex("e9 47 8a 07 1c c1 01 00")


def image_length(data: bytes, path: Path) -> int:
    if len(data) < 20 or len(data) % 4:
        raise ValueError(f"{path}: invalid Allwinner image size {len(data)}")
    length = struct.unpack_from("<I", data, 16)[0]
    if length == 0 or length > len(data) or length % 4:
        raise ValueError(f"{path}: invalid image length {length} (file size {len(data)})")
    return length


def checksum(data: bytes, path: Path) -> int:
    length = image_length(data, path)
    work = bytearray(data[:length])
    struct.pack_into("<I", work, 12, STAMP_VALUE)
    return sum(struct.unpack_from("<I", work, offset)[0]
               for offset in range(0, length, 4)) & 0xFFFFFFFF


def checksum_is_valid(data: bytes, path: Path) -> bool:
    stored = struct.unpack_from("<I", data, 12)[0]
    return stored == checksum(data, path)


def patch(path: Path, check_only: bool) -> None:
    data = bytearray(path.read_bytes())
    image_length(data, path)
    old_count = data.count(OLD)
    new_count = data.count(NEW)

    if check_only:
        if old_count:
            raise ValueError(f"{path}: still contains {old_count} 1500000-baud sequence(s)")
        if new_count != 1:
            raise ValueError(f"{path}: expected one 115200-baud sequence, found {new_count}")
        if not checksum_is_valid(data, path):
            raise ValueError(f"{path}: Allwinner checksum is invalid")
        return

    if old_count == 1 and new_count == 0:
        data[data.find(OLD):data.find(OLD) + len(OLD)] = NEW
        struct.pack_into("<I", data, 12, checksum(data, path))
        path.write_bytes(data)
        return
    if old_count == 0 and new_count == 1:
        if not checksum_is_valid(data, path):
            raise ValueError(f"{path}: already patched, but Allwinner checksum is invalid")
        return
    raise ValueError(
        f"{path}: expected one unpatched sequence or one valid patched sequence; "
        f"found old={old_count}, new={new_count}"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate without modifying files")
    parser.add_argument("images", nargs="+", type=Path, help="Boot0/PMBoot images")
    args = parser.parse_args(argv)

    try:
        for image in args.images:
            patch(image, args.check)
    except (OSError, ValueError, struct.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
