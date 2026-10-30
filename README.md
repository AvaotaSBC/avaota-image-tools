# avaota-image-tools

Reusable Allwinner image assembly for Avaota boards. The first board category
is `boards/avaota-f1`; shared host tools are in `tools/pack`.

The packer uses the sibling `u-boot-v821` source and a Buildroot RISC-V32
compiler. Board-specific Boot0/FES/PMBoot and Phoenix assets in
`boards/avaota-f1/prebuilt` remain vendor binaries because their DRAM code
cannot be linked by a generic toolchain.

## Use

```sh
./pack-avaota-f1-images.sh \
  --binaries-dir "$PWD/output/images" \
  --build-dir "$PWD/output/build/avaota-image-tools" \
  --u-boot-dir ../u-boot-v821 \
  --toolchain-prefix "$PWD/output/host/bin/riscv32-buildroot-linux-gnu-" \
  --jobs "$(nproc)"
```

The output is:

- `avaota-f1-spinor.img`: Allwinner `IMAGEWTY` image for SPI-NOR; write it
  to SPI-NOR with PhoenixSuit;
- `avaota-f1-spinor.raw`: raw SPI-NOR image;
- `avaota-f1-sd.raw`: raw SD image with a DOS/MBR partition table.

The SD image is independent of the IMAGEWTY flow and must be written directly
to the card. Its rootfs is `/dev/mmcblk0p2`; SPI-NOR uses `/dev/mtdblock6`.
The packer verifies payloads, boot-package placement, partition modes,
checksums, and the 115200-baud Boot0 patch.
