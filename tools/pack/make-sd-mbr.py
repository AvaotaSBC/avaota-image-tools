#!/usr/bin/env python3
"""Create the standard DOS/MBR view of the V821 SD raw image.

Allwinner's SD boot protocol uses fixed physical sectors before and after the
host-visible partition table.  This file creates only the conventional 512
byte MBR at LBA 0; the packer then places Boot0, boot packages, sunxi_mbr and
the payloads at their fixed V821 sectors.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


SECTOR_SIZE = 512
MIN_IMAGE_SECTORS = 100_000
UINT32_MAX = (1 << 32) - 1
UDISK_START = 98_048

# These entries intentionally expose only the useful Linux partitions.  The
# remaining Allwinner fixed-layout areas are addressed by their names in
# V821 U-Boot and are not conventional MBR partitions.
FIXED_PARTITIONS = (
    ("boot", 52_352, 10_240),
    ("rootfs", 67_712, 20_096),
    ("rootfs_data", 87_808, 10_240),
)


def mbr_partition(status: int, start: int, size: int, part_type: int = 0x83) -> bytes:
    end = start + size
    if start < 1 or size < 1 or end > UINT32_MAX + 1:
        raise ValueError(f"invalid MBR partition range: start={start}, size={size}")

    # LBA addressing is authoritative; saturated CHS values are the normal
    # representation for partitions that are not tied to a cylinder layout.
    chs = b"\xfe\xff\xff"
    return struct.pack("<B3sB3sII", status, chs, part_type, chs, start, size)


def create_image(output: Path, sectors: int, boot0_gpt: Path | None = None) -> None:
    if sectors < MIN_IMAGE_SECTORS:
        raise ValueError(
            f"image must contain at least {MIN_IMAGE_SECTORS} sectors"
        )
    if sectors - 1 > UINT32_MAX:
        raise ValueError("image is too large for a DOS/MBR partition table")

    entries = bytearray()
    for index, (_name, start, size) in enumerate(FIXED_PARTITIONS):
        if start + size > sectors:
            raise ValueError(f"partition {_name} exceeds the image")
        entries += mbr_partition(0x80 if index == 0 else 0, start, size)

    udisk_size = sectors - UDISK_START
    if udisk_size < 1:
        raise ValueError("image has no space for the UDISK partition")
    entries += mbr_partition(0, UDISK_START, udisk_size)

    mbr = bytearray(SECTOR_SIZE)
    mbr[440:444] = struct.pack("<I", 0x41564131)  # deterministic "AVA1"
    mbr[446:446 + len(entries)] = entries
    mbr[510:512] = b"\x55\xaa"

    compatibility_gpt = b""
    if boot0_gpt is not None:
        compatibility_gpt = boot0_gpt.read_bytes()
        if len(compatibility_gpt) < 4096:
            raise ValueError("Boot0 GPT compatibility data must be at least 4 KiB")
        if compatibility_gpt[512:520] != b"EFI PART":
            raise ValueError("Boot0 GPT compatibility data has no GPT header at LBA 1")

        # The vendor Boot0 parser checks the GPT signature and partition names
        # but does not check either CRC.  Keep its physical V821 map available
        # at LBA 1 while making the DOS MBR at LBA 0 authoritative to Linux
        # and normal host partitioning tools.
        compatibility_gpt = bytearray(compatibility_gpt[:4096])
        compatibility_gpt[512 + 16:512 + 20] = b"\0" * 4
        compatibility_gpt[512 + 88:512 + 92] = b"\0" * 4

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        stream.truncate(sectors * SECTOR_SIZE)
        if compatibility_gpt:
            stream.seek(0)
            stream.write(compatibility_gpt)
        stream.seek(0)
        stream.write(mbr)

    print(
        "created DOS/MBR image: %d sectors, rootfs=/dev/mmcblk0p2, UDISK starts at LBA %d"
        % (sectors, UDISK_START)
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sectors", required=True, type=int)
    parser.add_argument(
        "--boot0-gpt",
        type=Path,
        help="Allwinner GPT map used by the fixed V821 Boot0 loader",
    )
    args = parser.parse_args()

    try:
        create_image(args.output, args.sectors, args.boot0_gpt)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
