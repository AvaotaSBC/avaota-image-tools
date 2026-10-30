#!/usr/bin/env python3
"""Check the SPI-NOR map and the direct-SD raw layout.

The Allwinner IMAGEWTY output is the SPI-NOR/PhoenixSuit image.  The SD
output is deliberately a separate DOS/MBR raw image and is never treated as
an IMAGEWTY image.
"""

from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path


SECTOR_SIZE = 512


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def env_value(path: Path, name: str) -> str:
    data = path.read_bytes()
    # mkenvimage -r reserves the CRC and redundant-copy flag first.  The
    # fallback also makes the checker useful with a plain text env fixture.
    payload = data[5:] if len(data) > 5 and b"=" in data[5:] else data
    for item in payload.split(b"\0"):
        if item.startswith(name.encode() + b"="):
            return item.split(b"=", 1)[1].decode("ascii")
    fail(f"{path}: missing environment variable {name}")


def check_gpt(path: Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 4096:
        fail(f"{path}: GPT fixture is too small")

    header = data[SECTOR_SIZE : 2 * SECTOR_SIZE]
    if header[:8] != b"EFI PART":
        fail(f"{path}: missing GPT signature at LBA1")
    header_size = struct.unpack_from("<I", header, 12)[0]
    if not 92 <= header_size <= SECTOR_SIZE:
        fail(f"{path}: invalid GPT header size {header_size}")
    if struct.unpack_from("<Q", header, 24)[0] != 1:
        fail(f"{path}: GPT header is not at LBA1")
    stored_crc = struct.unpack_from("<I", header, 16)[0]
    header_copy = bytearray(header[:header_size])
    header_copy[16:20] = b"\0" * 4
    calculated_crc = zlib.crc32(header_copy) & 0xFFFFFFFF
    if stored_crc != calculated_crc:
        fail(f"{path}: GPT header CRC mismatch")

    if data[510:512] != b"\x55\xaa" or data[446 + 4] != 0xEE:
        fail(f"{path}: missing protective MBR")

    entry_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_count = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    if entry_size < 128:
        fail(f"{path}: unsupported GPT entry size {entry_size}")

    names: list[str] = []
    for index in range(entry_count):
        offset = entry_lba * SECTOR_SIZE + index * entry_size
        entry = data[offset : offset + entry_size]
        if not entry or not any(entry):
            continue
        name = entry[56:128].decode("utf-16le", "ignore").split("\0", 1)[0]
        names.append(name)
    if names != [
        "boot-resource",
        "env",
        "env-redund",
        "boot",
        "private",
        "riscv0",
        "rootfs",
        "rootfs_data",
        "UDISK",
    ]:
        fail(f"{path}: unexpected GPT partition names: {names}")
    return names


def check_sd_raw(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < 1024:
        fail(f"{path}: raw SD image is too small")
    if data[510:512] != b"\x55\xaa":
        fail(f"{path}: missing DOS MBR signature")

    expected = {
        1: (0x80, 0x83, 52352, 10240),
        2: (0x00, 0x83, 67712, 20096),
        3: (0x00, 0x83, 87808, 10240),
        4: (0x00, 0x83, 98048, len(data) // SECTOR_SIZE - 98048),
    }
    for number, (bootable, part_type, start, size) in expected.items():
        entry = data[446 + (number - 1) * 16 : 462 + (number - 1) * 16]
        actual = (
            entry[0],
            entry[4],
            struct.unpack_from("<I", entry, 8)[0],
            struct.unpack_from("<I", entry, 12)[0],
        )
        if actual != (bootable, part_type, start, size):
            fail(f"{path}: MBR p{number} is {actual}, expected {(bootable, part_type, start, size)}")

    # The compatibility GPT is intentionally not valid.  Otherwise Linux and
    # generic host tools could prefer the vendor map over the DOS MBR.
    if data[512:520] != b"EFI PART":
        fail(f"{path}: missing V821 Boot0 GPT compatibility signature")
    if data[528:532] != b"\0" * 4:
        fail(f"{path}: raw SD compatibility GPT unexpectedly has a valid header CRC")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nor-gpt", required=True, type=Path)
    parser.add_argument("--sd-raw", required=True, type=Path)
    parser.add_argument("--sd-env", required=True, type=Path)
    parser.add_argument("--nor-env", required=True, type=Path)
    args = parser.parse_args()

    names = check_gpt(args.nor_gpt)
    check_sd_raw(args.sd_raw)
    if names.index("rootfs") + 1 != 7:
        fail(f"{args.nor_gpt}: rootfs is not logical partition 7")
    if env_value(args.sd_env, "mmc_root") != "/dev/mmcblk0p2":
        fail(f"{args.sd_env}: raw-SD mmc_root is not /dev/mmcblk0p2")
    if env_value(args.nor_env, "nor_root") != "/dev/mtdblock6":
        fail(f"{args.nor_env}: NOR nor_root is not /dev/mtdblock6")

    print("ok: SPI-NOR logical root=mtdblock6; SD raw DOS rootfs=p2")


if __name__ == "__main__":
    main()
