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

- `avaota-f1-flash.img`: common `IMAGEWTY` image for PhoenixSuit/PhoenixCard,
  usable on SPI-NOR and SD;
- `avaota-f1-spinor.raw`: raw SPI-NOR image;
- `avaota-f1-sd.raw`: raw SD image with a DOS/MBR partition table.

The common image follows Tina's packaging model: it carries both storage
boot packages and the NOR-compatible common partition map. The raw SD image
uses rootfs p2; the common SD path uses the Tina GPT map and rootfs p7; the
NOR path uses `/dev/mtdblock6`. The packer verifies image payloads, boot
package placement, partition modes, checksums, and the 115200-baud Boot0
patch before publishing outputs.

Use only the `*.raw` files for direct device writes. Use the `IMAGEWTY` file
with the Allwinner flashing tools.
