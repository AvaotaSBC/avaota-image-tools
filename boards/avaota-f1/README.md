# Avaota-F1 image inputs

- `sys_partition.fex`: SD/raw layout;
- `sys_partition_nor.fex`: SPI-NOR and common Phoenix image layout;
- `image.cfg`, `env-*.cfg`, and `prebuilt/`: Allwinner packaging inputs.

The common `IMAGEWTY` image uses the Tina NOR map while carrying separate SD
and NOR boot packages. Its `boot-resource` placeholder is intentionally not a
download item. `cardscript.fex` and `cardtool.fex` are kept unchanged for the
PhoenixCard product path.

The raw SD image is assembled separately with a DOS/MBR table and rootfs at
p2. The common SD path uses the Tina GPT map and rootfs at p7. The NOR path
uses the logical MTD map and rootfs at mtd6. The packer preserves the NOR
`dlinfo.fex` in the common image after generating the raw SD image. The SD
U-Boot repairs only stale GPT CRCs in-place, preserving PhoenixCard entries.
