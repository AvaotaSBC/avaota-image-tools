# Avaota-F1 board image inputs

`sys_partition.fex` is the SD/card layout. `sys_partition_nor.fex` is the
SPI-NOR layout. The packer converts these text FEX files to DOS line endings
before invoking Allwinner's `script` utility; that conversion is required for
the utility to retain all partition records.

The Phoenix/Dragon `image.cfg` is used for the common `avaota-f1-flash.img`
and is switched to the NOR map during packing, matching Tina's common image
flow. The independent `avaota-f1-sd.raw` is assembled from the SD map and SD
Boot0/boot package.

The common SD card written by PhoenixCard/PhoenixSuit uses Tina's valid GPT
map: `boot-resource`, `env`, `env-redund`, `boot`, `private`, `riscv0`,
`rootfs`, `rootfs_data`, and `UDISK`, with `rootfs` as GPT partition 7. The
direct SD raw image uses a separate DOS MBR with `rootfs` as p2. The SD
U-Boot detects the format from the medium at runtime, so these two layouts do
not require separate SD U-Boot binaries.

The common image intentionally keeps the Tina NOR `sys_partition.fex` map,
including its non-downloadable `boot-resource` placeholder, and carries both
boot packages as separate `IMAGEWTY` items. PhoenixSuit/PhoenixCard selects the
appropriate Boot0/boot package for the target medium. The package checker in
`tools/pack/` verifies that the NOR item is the uncompressed package containing
the NOR U-Boot; this prevents the SD U-Boot or the optional IPC LZMA package
from being selected accidentally.
The SD U-Boot repairs the primary and backup GPT header entry-array CRC when a
PhoenixCard write leaves that CRC stale after resizing the card-specific last
partition. This repair is restricted to the valid common GPT path; the direct
SD raw image continues to use its DOS MBR.
The `u-boot-efex.fex` member used by the USB/FEL updater is built from the
dedicated `sun300iw1p1_efex_defconfig` and uses the NOR storage overlay
(`storage_type = 3`), as it does in Tina's NOR image. It is not a copy of the
SD U-Boot or the runtime NOR U-Boot.

`boot-resource.fex` is placed only in the fixed boot-resource area of the raw
SD image. It is deliberately not an `IMAGEWTY` item in the common image,
because the Tina NOR map comments out that partition's `downloadfile`; adding
an SD-only map or a guessed boot-resource item to the common image causes
PhoenixCard to report a boot-resource write failure.
`update_mbr` generates a different `dlinfo.fex` for the SD and NOR maps. The
packer snapshots the NOR result before assembling SD, then restores that NOR
variant for the common `IMAGEWTY` image; this is required because its
`sys_partition.fex` is the Tina NOR map. The SD `dlinfo` is used only while
constructing the fixed raw SD layout and is never mixed into the common image.

The U-Boot board DTS inputs live in the sibling `u-boot-v821` repository:
`boards/avaota-f1/uboot/nor/uboot-board.dts` selects SPI-NOR
(`storage_type = 3`) and `boards/avaota-f1/uboot/sd/uboot-board.dts` selects
card0 (`storage_type = 1`). The two U-Boot variants are therefore built
separately even though they share the same source tree.
