# Avaota Allwinner image tools

This repository contains the reusable Allwinner image assembly layer for
Avaota boards. It is deliberately separate from the
`u-boot-v821` source repository: this tree owns Allwinner boot stages, FEX
partition/environment inputs, Phoenix/Dragon tools, Android boot image
creation, and final NOR/SD image assembly.

## Repository layout

- `boards/avaota-f1/`: the first board category, containing FEX
  partition/configuration files, boot environments, and the board-specific
  Boot0/FES/PMBoot/OpenSBI/AMP/Phoenix assets under `prebuilt/`.
- `tools/pack/`: shared Allwinner host packers, Dragon plugins, and
  `mkbootimg.py`; future board categories can reuse these tools.
- `pack-avaota-f1-images.sh`: builds the NOR, SD, and dedicated EFEX/FEL
  U-Boot variants through the sibling `u-boot-v821` repository and assembles
  the final images.

The V821 Boot0/FES/PMBoot DRAM code remains vendor-prebuilt because it uses
Andes instructions and vendor relocation types that the generic Buildroot
binutils cannot link. The pack script applies the deterministic
`tools/pack/patch-boot0-baud.py` patch to the vendor Boot0/PMBoot UART setup
and recomputes the Allwinner checksum; this changes only the standard RISC-V
UART divisor from 1500000 to 115200. U-Boot, Linux, the rootfs getty, and all
image environments use the same 115200 setting. U-Boot itself is built from
source by `u-boot-v821` with Buildroot's RISC-V32 compiler.

## Direct use

The normal Buildroot external-tree post-image hook invokes this script. A
direct invocation is:

```sh
./pack-avaota-f1-images.sh \
  --binaries-dir "$PWD/output/images" \
  --build-dir "$PWD/output/build/avaota-image-tools" \
  --u-boot-dir ../u-boot-v821 \
  --toolchain-prefix "$PWD/output/host/bin/riscv32-buildroot-linux-gnu-" \
  --jobs "$(nproc)"
```

The packer also converts relative arguments to absolute paths before invoking
U-Boot, so a relative path supplied by another build system cannot create
output inside the U-Boot source tree.

It produces exactly three board images:

- `avaota-f1-flash.img`: `IMAGEWTY` Phoenix/Dragon image in the same common
  form as Tina. Its file list contains both SD and SPI-NOR Boot0/U-Boot
  packages, and its NOR partition map makes the same image usable by the
  Allwinner flashing tool for either storage medium. The packaged environment
  starts from `setargs_nand`; V821 U-Boot changes that to `setargs_mmc` for SD
  or `setargs_nor` for SPI-NOR, so the common image selects the correct root.
  On SD, Tina's common GPT map makes `rootfs` GPT partition 7; on SPI-NOR the
  root is `/dev/mtdblock6`.
- `avaota-f1-spinor.raw`: raw SPI-NOR image with the Allwinner `eGON.BT0`
  header and the F1 V821 NOR map.
- `avaota-f1-sd.raw`: standard DOS/MBR SD image with four primary entries:
  `boot` at LBA52352, `rootfs` at LBA67712 (`/dev/mmcblk0p2`),
  `rootfs_data` at LBA87808, and `UDISK` at LBA98048 through the end. The
  fixed V821 Boot0 also requires its vendor partition map at LBA1; the image
  carries that map with invalid GPT CRCs as compatibility metadata, so it is
  not a second host-visible partition table and the DOS MBR remains
  authoritative.
  V821 Boot0 copies are at LBA16/LBA256, the boot packages are at
  LBA24576/LBA32800, and the Allwinner `sunxi_mbr` remains at LBA40960. The
  default image size is 64 MiB; set
  `AVAOTA_SD_IMAGE_SECTORS` to choose another size.

The SD runtime U-Boot also contains a narrow PhoenixCard compatibility repair.
Some PhoenixCard versions resize the last GPT entry for the target card but
leave the GPT entry-array CRC from the source image. Before partition probing,
the SD U-Boot verifies the GPT header, recomputes the entry-array CRC when this
is the only inconsistency, and updates the primary and backup header CRCs. It
does not change the direct raw SD path: that image has a real DOS MBR at LBA0
and an intentionally invalid GPT compatibility header at LBA1.

The SPI-NOR raw image uses the Allwinner logical map rather than an MBR. Its
Linux root partition is `/dev/mtdblock6` (`rootfs`; `rootfs_data` is mtd7);
U-Boot supplies the NOR logical offset (`mbr_offset=2016*512`) to the kernel.

The script verifies all three image signatures, removes stale outputs from the
old SD-only image flow, and writes SHA256 checksums and a boot manifest beside
the images. Before the files are copied into the final images it also verifies
the DragonSecBoot TOC and payloads:

- NOR must contain exactly the uncompressed `opensbi`, `u-boot`, and `pmboot`
  entries, with the U-Boot payload built from the NOR variant
  (`storage_type = 3`).
- SD must contain exactly the uncompressed `opensbi`, `u-boot`, and
  `melis-elf` entries, with the SD U-Boot variant (`storage_type = 1`).
- The common `IMAGEWTY` file is checked again after Dragon has embedded both
  boot packages, so a stale package cannot silently be published. Its
  `u-boot-efex.fex` is the dedicated EFEX/FEL U-Boot (`storage_type = 3`),
  matching Tina; it is not the SD U-Boot or a copied runtime NOR binary.
- The raw-image checker compares the packages at the actual V821 Boot0 LBAs,
  rejects compressed `*-lzma` TOC names, and verifies the NOR eGON header and
  SD DOS/MBR header. The common image also preserves Tina's NOR `dlinfo.fex`;
  the SD `update_mbr` result is never allowed to overwrite it.
- The partition-mode checker verifies the exact Tina common GPT map and the
  raw SD MBR, including the fallback roots (`p7` for common SD, `p2` for raw
  SD, and `mtdblock6` for NOR). The SD U-Boot selects GPT for the common
  Phoenix image and DOS only when it sees the raw image's real MBR.

The host needs a compatible 32-bit glibc and libstdc++ runtime for the bundled
Phoenix Dragon executable.

If a board log still starts with `opensbi-lzma`/`u-boot-lzma`, or the NOR U-Boot
prints `storage type = 1`, the board has not booted the package produced by
this tree: those entries indicate the older compressed package or the SD
U-Boot variant. Check the SHA256 of `avaota-f1-flash.img` and use that file
with PhoenixSuit/PhoenixCard; the `*.raw` files are for direct raw writes and
must not be passed to a Phoenix tool.
