# Avaota-F1 image inputs

- `sys_partition.fex`: SD/raw layout;
- `sys_partition_nor.fex`: SPI-NOR layout;
- `image_nor.cfg`, `env-*.cfg`, and `prebuilt/`: Allwinner packaging inputs.

`avaota-f1-spinor.img` follows Tina's `image_nor` flow and is for SPI-NOR
with PhoenixSuit. `avaota-f1-sd.raw` is a separate DOS/MBR image for direct
SD writes and uses rootfs partition 2. SPI-NOR uses logical MTD partition 6.
