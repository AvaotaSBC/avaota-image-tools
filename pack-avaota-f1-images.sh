#!/bin/sh

set -e

usage() {
	cat <<'EOF'
Usage: pack-avaota-f1-images.sh --binaries-dir DIR [options]

Build U-Boot with a Buildroot RISC-V32 compiler and produce:
  avaota-f1-spinor.img  Allwinner IMAGEWTY image for SPI-NOR (PhoenixSuit)
  avaota-f1-spinor.raw  raw SPI-NOR image
  avaota-f1-sd.raw      raw SD image (write directly; not PhoenixCard)

Options:
  --binaries-dir DIR       Buildroot images directory (required)
  --build-dir DIR          scratch directory
  --output-dir DIR         final image directory (default: binaries-dir)
  --u-boot-dir DIR         sibling u-boot-v821 repository
  --toolchain-prefix PATH  .../host/bin/riscv32-buildroot-linux-gnu-
  --jobs N                 parallel U-Boot jobs

Environment:
  AVAOTA_SD_IMAGE_SECTORS  SD raw image size in 512-byte sectors (default: 131072)
EOF
}

make_absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*)
			path_dir=$(dirname -- "$1")
			path_base=$(basename -- "$1")
			path_dir=$(CDPATH= cd -- "$path_dir" && pwd -P)
			printf '%s/%s\n' "$path_dir" "$path_base"
			;;
	esac
}

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BOARD_DIR=$REPO_DIR/boards/avaota-f1
TOOLS_DIR=$REPO_DIR/tools/pack
PREBUILT_DIR=$BOARD_DIR/prebuilt

BINARIES_DIR=
BUILD_DIR=
OUTPUT_DIR=
UBOOT_REPO_DIR=
TOOLCHAIN_PREFIX=
JOBS=
SD_IMAGE_SECTORS=${AVAOTA_SD_IMAGE_SECTORS:-131072}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--binaries-dir) BINARIES_DIR=$2; shift 2 ;;
		--build-dir) BUILD_DIR=$2; shift 2 ;;
		--output-dir) OUTPUT_DIR=$2; shift 2 ;;
		--u-boot-dir) UBOOT_REPO_DIR=$2; shift 2 ;;
		--toolchain-prefix) TOOLCHAIN_PREFIX=$2; shift 2 ;;
		--jobs) JOBS=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

if [ -z "$BINARIES_DIR" ]; then
	echo "error: --binaries-dir is required" >&2
	exit 2
fi

# U-Boot's make -C changes the current directory before resolving O= and
# CROSS_COMPILE.  Normalize every caller-supplied path first, so a relative
# toolchain or output path can never create an accidental directory inside the
# U-Boot source tree.
BINARIES_DIR=$(make_absolute "$BINARIES_DIR")
if [ -z "$OUTPUT_DIR" ]; then OUTPUT_DIR=$BINARIES_DIR; else OUTPUT_DIR=$(make_absolute "$OUTPUT_DIR"); fi
if [ -z "$BUILD_DIR" ]; then BUILD_DIR=$OUTPUT_DIR/.avaota-image-tools; else BUILD_DIR=$(make_absolute "$BUILD_DIR"); fi
if [ -z "$UBOOT_REPO_DIR" ]; then UBOOT_REPO_DIR=$REPO_DIR/../u-boot-v821; else UBOOT_REPO_DIR=$(make_absolute "$UBOOT_REPO_DIR"); fi
if [ -z "$JOBS" ]; then JOBS=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1); fi
case "$SD_IMAGE_SECTORS" in
	''|*[!0-9]*)
		echo "error: AVAOTA_SD_IMAGE_SECTORS must be a positive integer" >&2
		exit 2
		;;
esac
[ "$SD_IMAGE_SECTORS" -gt 100000 ] || {
	echo "error: AVAOTA_SD_IMAGE_SECTORS is too small for the V821 SD layout" >&2
	exit 2
}

if [ -z "$TOOLCHAIN_PREFIX" ]; then
	if command -v riscv32-buildroot-linux-gnu-gcc >/dev/null 2>&1; then
		TOOLCHAIN_PREFIX=$(command -v riscv32-buildroot-linux-gnu-gcc)
		TOOLCHAIN_PREFIX=$(echo "$TOOLCHAIN_PREFIX" | sed 's/gcc$//')
	else
		echo "error: Buildroot RISC-V32 compiler not found; pass --toolchain-prefix" >&2
		exit 1
	fi
fi
TOOLCHAIN_PREFIX=$(make_absolute "$TOOLCHAIN_PREFIX")

CC=$TOOLCHAIN_PREFIX"gcc"
if [ ! -x "$CC" ]; then
	echo "error: compiler not found: $CC" >&2
	exit 1
fi
MACHINE=$("$CC" -dumpmachine)
case "$MACHINE" in
	riscv32-*) ;;
	*) echo "error: expected a RISC-V32 Buildroot compiler, got $MACHINE" >&2; exit 1 ;;
esac

UBOOT_BUILDER=$UBOOT_REPO_DIR/scripts/build-u-boot-v821.sh
[ -x "$UBOOT_BUILDER" ] || {
	echo "error: U-Boot repository not found: $UBOOT_REPO_DIR" >&2
	exit 1
}

KERNEL=$BINARIES_DIR/Image.gz
DTB=$BINARIES_DIR/avaota-f1.dtb
ROOTFS=$BINARIES_DIR/rootfs.squashfs
for input in "$KERNEL" "$DTB" "$ROOTFS"; do
	[ -f "$input" ] || { echo "error: missing Buildroot output: $input" >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
UBOOT_BUILD=$BUILD_DIR/u-boot
PACK_DIR=$BUILD_DIR/pack

# The U-Boot repository used to contain its source below u-boot/.  Keep a
# small marker beside the generated variant outputs so a source-layout change
# cannot reuse stale Kbuild files and dependency paths from the old checkout.
# Only the three explicitly generated variant directories are removed.
UBOOT_SOURCE_MARKER=$UBOOT_BUILD/.source-root
UBOOT_SOURCE_MARKER_VALUE="${UBOOT_REPO_DIR}|standalone-top-level-v2"
UBOOT_SOURCE_CHANGED=1
if [ -f "$UBOOT_SOURCE_MARKER" ] && [ "$(cat "$UBOOT_SOURCE_MARKER")" = "$UBOOT_SOURCE_MARKER_VALUE" ]; then
	UBOOT_SOURCE_CHANGED=0
fi
if [ "$UBOOT_SOURCE_CHANGED" -ne 0 ]; then
	echo "==> resetting stale U-Boot scratch outputs for $UBOOT_REPO_DIR"
	for variant in nor sd efex; do
		variant_dir=$UBOOT_BUILD/$variant
		if [ -e "$variant_dir" ] || [ -L "$variant_dir" ]; then
			find "$variant_dir" -depth -delete
		fi
		mkdir -p "$variant_dir"
	done
	printf '%s\n' "$UBOOT_SOURCE_MARKER_VALUE" > "$UBOOT_SOURCE_MARKER"
else
	mkdir -p "$UBOOT_BUILD/nor" "$UBOOT_BUILD/sd" "$UBOOT_BUILD/efex"
fi
mkdir -p "$PACK_DIR"

# These were outputs of the old split-specific image flow. Remove only these
# exact files so a rerun cannot leave an obsolete image next to the new ones.
for stale in avaota-f1-flash.img avaota-f1-spinor.img avaota-f1-sd.img \
	avaota-f1-nor-env.fex avaota-f1-sd-env.fex; do
	find "$OUTPUT_DIR" -maxdepth 1 -type f -name "$stale" -delete
done
for stale in avaota-f1-flash.img avaota-f1-sd.img image.cfg env-common.cfg \
	env-nor.fex env-sd.fex; do
	find "$PACK_DIR" -maxdepth 1 -type f -name "$stale" -delete
done

UPDATE_DIR=$TOOLS_DIR/mod_update
SCRIPT_TOOL=$UPDATE_DIR/script
UPDATE_BOOT0=$UPDATE_DIR/update_boot0
UPDATE_FES1=$UPDATE_DIR/update_fes1
UPDATE_MBR=$UPDATE_DIR/update_mbr
UPDATE_UBOOT=$UPDATE_DIR/update_uboot
MERGE_FULL_IMG=$UPDATE_DIR/merge_full_img
DRAGONSECBOOT=$TOOLS_DIR/dragonsecboot
DRAGON_DIR=$TOOLS_DIR/eDragonEx
DRAGON=$DRAGON_DIR/dragon
MKBOOTIMG=$TOOLS_DIR/android/mkbootimg.py
MKENVIMAGE=$UBOOT_BUILD/sd/tools/mkenvimage
MAKE_SD_MBR=$TOOLS_DIR/make-sd-mbr.py
PATCH_BOOT0_BAUD=$TOOLS_DIR/patch-boot0-baud.py
CHECK_BOOT_PACKAGE=$TOOLS_DIR/check-boot-package.py
CHECK_IMAGE=$TOOLS_DIR/check-image.py
CHECK_RAW_IMAGES=$TOOLS_DIR/check-raw-images.py
CHECK_PARTITION_MODES=$TOOLS_DIR/check-partition-modes.py

for tool in "$SCRIPT_TOOL" "$UPDATE_BOOT0" "$UPDATE_FES1" "$UPDATE_MBR" "$UPDATE_UBOOT" "$MERGE_FULL_IMG" "$DRAGONSECBOOT" "$DRAGON" "$MKBOOTIMG"; do
	[ -x "$tool" ] || { echo "error: missing pack tool: $tool" >&2; exit 1; }
done
[ -f "$MAKE_SD_MBR" ] || { echo "error: missing SD MBR generator: $MAKE_SD_MBR" >&2; exit 1; }
[ -x "$PATCH_BOOT0_BAUD" ] || { echo "error: missing Boot0 baud patcher: $PATCH_BOOT0_BAUD" >&2; exit 1; }
[ -f "$CHECK_BOOT_PACKAGE" ] || { echo "error: missing boot package checker: $CHECK_BOOT_PACKAGE" >&2; exit 1; }
[ -f "$CHECK_IMAGE" ] || { echo "error: missing Phoenix image checker: $CHECK_IMAGE" >&2; exit 1; }
[ -f "$CHECK_RAW_IMAGES" ] || { echo "error: missing raw image checker: $CHECK_RAW_IMAGES" >&2; exit 1; }
[ -f "$CHECK_PARTITION_MODES" ] || { echo "error: missing partition mode checker: $CHECK_PARTITION_MODES" >&2; exit 1; }

build_uboot() {
	variant=$1
	out_dir=$2
	"$UBOOT_BUILDER" --variant "$variant" --output-dir "$out_dir" \
		--toolchain-prefix "$TOOLCHAIN_PREFIX" --jobs "$JOBS"
}

echo "==> building U-Boot NOR variant with $MACHINE"
build_uboot nor "$UBOOT_BUILD/nor"
echo "==> building U-Boot SD variant with $MACHINE"
build_uboot sd "$UBOOT_BUILD/sd"
echo "==> building U-Boot EFEX/FEL variant with $MACHINE"
build_uboot efex "$UBOOT_BUILD/efex"
[ -x "$MKENVIMAGE" ] || { echo "error: U-Boot did not build mkenvimage" >&2; exit 1; }

check_uboot_variant() {
	variant=$1
	config=$UBOOT_BUILD/$variant/.config
	dtb=$UBOOT_BUILD/$variant/u-boot.dtb
	[ -f "$config" ] || { echo "error: missing U-Boot config: $config" >&2; exit 1; }
	[ -f "$dtb" ] || { echo "error: missing U-Boot DTB: $dtb" >&2; exit 1; }
	case "$variant" in
		nor)
			grep -q '^CONFIG_SUNXI_NOR_IMG=y$' "$config" || {
				echo "error: NOR U-Boot was built without CONFIG_SUNXI_NOR_IMG" >&2
				exit 1
			}
			;;
		sd)
			if grep -q '^CONFIG_SUNXI_NOR_IMG=y$' "$config"; then
				echo "error: SD U-Boot unexpectedly has CONFIG_SUNXI_NOR_IMG" >&2
				exit 1
			fi
			;;
		efex)
			grep -q '^CONFIG_SUNXI_EFEX_IMG=y$' "$config" || {
				echo "error: EFEX U-Boot was built without CONFIG_SUNXI_EFEX_IMG" >&2
				exit 1
			}
			;;
		*) echo "error: unknown U-Boot variant: $variant" >&2; exit 1 ;;
	esac
	# The DTS is the source of the storage_type value printed by U-Boot.  Use
	# the host DTC when present, otherwise use the copy built in the standalone
	# U-Boot repository; silently skipping this check would allow a copied DTB.
	DTC=$(command -v dtc 2>/dev/null || true)
	if [ -z "$DTC" ] && [ -x "$UBOOT_REPO_DIR/scripts/dtc/dtc" ]; then
		DTC=$UBOOT_REPO_DIR/scripts/dtc/dtc
	fi
	[ -n "$DTC" ] || {
		echo "error: no DTC available to verify $variant U-Boot DTB" >&2
		exit 1
	}
	case "$variant" in
		nor|efex) expected=3 ;;
		sd) expected=1 ;;
		esac
	actual=$("$DTC" -I dtb -O dts "$dtb" 2>/dev/null \
		| awk '$1 == "storage_type" { gsub(/[<>;]/, "", $3); print $3; exit }')
	[ "$actual" = "0x0$(printf '%x' "$expected")" ] ||
	[ "$actual" = "0x$(printf '%02x' "$expected")" ] ||
	[ "$actual" = "0x$(printf '%x' "$expected")" ] || {
		echo "error: $variant U-Boot DTB storage_type=$actual, expected $expected" >&2
		exit 1
	}
}

check_uboot_variant nor
check_uboot_variant sd
check_uboot_variant efex

check_env_image() {
	python3 - "$1" <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]
data = open(path, "rb").read()
if len(data) != 0x20000:
    raise SystemExit(f"error: {path}: expected 0x20000 bytes, got {len(data):#x}")

# CONFIG_SYS_REDUNDAND_ENVIRONMENT adds the serial/validity byte between the
# CRC and the environment data.  mkenvimage -r emits an active copy (1).
if data[4] not in (0, 1, 255):
    raise SystemExit(f"error: {path}: missing redundant-environment flag")
stored = struct.unpack_from("<I", data, 0)[0]
calculated = zlib.crc32(data[5:]) & 0xffffffff
if stored != calculated:
    raise SystemExit(
        f"error: {path}: redundant U-Boot CRC mismatch "
        f"{stored:#x} != {calculated:#x}"
    )
PY
}

dosify() {
	if command -v unix2dos >/dev/null 2>&1; then
		unix2dos "$1" >/dev/null
	else
		busybox unix2dos "$1" >/dev/null
	fi
}

run_pack_tool() { "$@"; }

copy_prebuilt() {
	for name in boot-resource.fex split_xxxx.fex usbtool.fex usbtool_crash.fex \
		aultools.fex aultls32.fex cardtool.fex cardscript.fex arisc.fex \
		dlinfo.fex toc0.fex toc1.fex u-boot-crash.fex vmlinux.fex dragon_toc.fex; do
		cp -f "$PREBUILT_DIR/$name" "$PACK_DIR/$name"
	done
	cp -f "$PREBUILT_DIR/amp_rv0.bin" "$PACK_DIR/amp_rv0.fex"
	cp -f "$PREBUILT_DIR/opensbi.bin" "$PACK_DIR/opensbi.fex"
	cp -f "$PREBUILT_DIR/boot0_sdcard_sun300iw1p1.bin" "$PACK_DIR/boot0_sdcard.fex"
	cp -f "$PREBUILT_DIR/boot0_spinor_sun300iw1p1.bin" "$PACK_DIR/boot0_spinor.fex"
	cp -f "$PREBUILT_DIR/fes1_sun300iw1p1.bin" "$PACK_DIR/fes1.fex"
	cp -f "$PREBUILT_DIR/pmboot_sdcard_sun300iw1p1.bin" "$PACK_DIR/pmboot_sdcard.fex"
	cp -f "$PREBUILT_DIR/pmboot_spinor_sun300iw1p1.bin" "$PACK_DIR/pmboot_spinor.fex"
}

copy_prebuilt
python3 "$PATCH_BOOT0_BAUD" \
	"$PACK_DIR/boot0_sdcard.fex" "$PACK_DIR/boot0_spinor.fex" \
	"$PACK_DIR/pmboot_sdcard.fex" "$PACK_DIR/pmboot_spinor.fex"
cp -f "$BOARD_DIR/image_nor.cfg" "$PACK_DIR/image_nor.cfg"
cp -f "$BOARD_DIR/boot_package.cfg" "$PACK_DIR/boot_package.cfg"
cp -f "$BOARD_DIR/boot_package_nor.cfg" "$PACK_DIR/boot_package_nor.cfg"
cp -f "$BOARD_DIR/boot-resource.ini" "$PACK_DIR/boot-resource.ini"
cp -f "$BOARD_DIR/sys_partition.fex" "$PACK_DIR/sys_partition.fex"
cp -f "$BOARD_DIR/sys_partition_nor.fex" "$PACK_DIR/sys_partition_nor.fex"
dosify "$PACK_DIR/sys_partition.fex"
dosify "$PACK_DIR/sys_partition_nor.fex"

cp -f "$KERNEL" "$PACK_DIR/Image.gz"
cp -f "$DTB" "$PACK_DIR/sunxi.fex"
cp -f "$ROOTFS" "$PACK_DIR/rootfs.fex"
cp -f "$ROOTFS" "$PACK_DIR/rootfs_nor.fex"
python3 "$MKBOOTIMG" --kernel "$KERNEL" --board sun300i_riscv32 \
	--base 0x80000000 --kernel_offset 0 --dtb "$DTB" --dtb_offset 0xa00000 \
	--header_version 2 -o "$PACK_DIR/boot.fex"

cp -f "$UBOOT_BUILD/nor/u-boot.bin" "$PACK_DIR/u-boot-spinor.fex"
cp -f "$UBOOT_BUILD/sd/u-boot.bin" "$PACK_DIR/u-boot.fex"
cp -f "$UBOOT_BUILD/efex/u-boot.bin" "$PACK_DIR/u-boot-efex.fex"

cp -f "$BOARD_DIR/sys_config.fex" "$PACK_DIR/sys_config-nor.fex"
sed -i -E 's/^[[:space:]]*storage_type[[:space:]]*=.*/storage_type    = 3/' "$PACK_DIR/sys_config-nor.fex"
dosify "$PACK_DIR/sys_config-nor.fex"
"$SCRIPT_TOOL" "$PACK_DIR/sys_config-nor.fex" >/dev/null
"$SCRIPT_TOOL" "$PACK_DIR/sys_partition.fex" >/dev/null
"$SCRIPT_TOOL" "$PACK_DIR/sys_partition_nor.fex" >/dev/null
# U-Boot is built with CONFIG_SUNXI_REDUNDAND_ENVIRONMENT.  Without -r,
# mkenvimage puts the first environment byte at offset 4, while U-Boot treats
# that byte as the redundant-environment flag and calculates the CRC from
# offset 5.  Both copies would consequently be rejected as "bad CRC".
"$MKENVIMAGE" -r -s 0x20000 -o "$PACK_DIR/env.fex" "$BOARD_DIR/env-nor.cfg"
check_env_image "$PACK_DIR/env.fex"
cp -f "$PACK_DIR/env.fex" "$PACK_DIR/env-nor.fex"

echo "==> packaging SPI-NOR raw image"
(
	cd "$PACK_DIR"
	"$UPDATE_BOOT0" boot0_spinor.fex sys_config-nor.bin SPINOR_FLASH >/dev/null
	"$UPDATE_FES1" fes1.fex sys_config-nor.bin >/dev/null
	"$UPDATE_BOOT0" pmboot_spinor.fex sys_config-nor.bin SPINOR_FLASH >/dev/null
	python3 "$PATCH_BOOT0_BAUD" --check boot0_spinor.fex pmboot_spinor.fex
	"$UPDATE_UBOOT" -no_merge u-boot-spinor.fex sys_config-nor.bin >/dev/null
	"$UPDATE_UBOOT" -no_merge u-boot-efex.fex sys_config-nor.bin >/dev/null
	run_pack_tool "$DRAGONSECBOOT" -pack boot_package_nor.cfg >/dev/null
	cp -f boot_package.fex boot_package_nor.fex
	python3 "$CHECK_BOOT_PACKAGE" boot_package_nor.fex \
		--entries opensbi,u-boot,pmboot \
		--match opensbi=opensbi.fex \
		--match u-boot=u-boot-spinor.fex \
		--match pmboot=pmboot_spinor.fex >/dev/null
	"$UPDATE_MBR" sys_partition_nor.bin 1 sunxi_mbr_nor.fex dlinfo.fex 65536 2016 1 >/dev/null
	cp -f dlinfo.fex dlinfo-nor.fex
	cp -f sunxi_gpt.fex sunxi_gpt-nor.fex
	"$MERGE_FULL_IMG" --out avaota-f1-spinor.raw --boot0 boot0_spinor.fex \
		--boot1 boot_package_nor.fex --mbr sunxi_gpt-nor.fex \
		--partition sys_partition_nor.bin --logic_start 1008 --uboot_start 64 >/dev/null
)
cp -f "$PACK_DIR/avaota-f1-spinor.raw" "$OUTPUT_DIR/avaota-f1-spinor.raw"

echo "==> packaging SD raw image"
cp -f "$BOARD_DIR/sys_config.fex" "$PACK_DIR/sys_config.fex"
sed -i -E 's/^[[:space:]]*storage_type[[:space:]]*=.*/storage_type    = 1/' "$PACK_DIR/sys_config.fex"
dosify "$PACK_DIR/sys_config.fex"
"$SCRIPT_TOOL" "$PACK_DIR/sys_config.fex" >/dev/null
cp -f "$PACK_DIR/sys_config.bin" "$PACK_DIR/config.fex"
"$MKENVIMAGE" -r -s 0x20000 -o "$PACK_DIR/env.fex" "$BOARD_DIR/env-sd.cfg"
check_env_image "$PACK_DIR/env.fex"
cp -f "$PACK_DIR/env.fex" "$PACK_DIR/env-sd.fex"

(
	cd "$PACK_DIR"
	"$UPDATE_BOOT0" boot0_sdcard.fex sys_config.bin SDMMC_CARD >/dev/null
	"$UPDATE_FES1" fes1.fex sys_config.bin >/dev/null
	"$UPDATE_BOOT0" pmboot_sdcard.fex sys_config.bin SDMMC_CARD >/dev/null
	python3 "$PATCH_BOOT0_BAUD" --check boot0_sdcard.fex pmboot_sdcard.fex
	"$UPDATE_UBOOT" -no_merge u-boot.fex sys_config.bin >/dev/null
	run_pack_tool "$DRAGONSECBOOT" -pack boot_package.cfg >/dev/null
	python3 "$CHECK_BOOT_PACKAGE" boot_package.fex \
		--entries opensbi,u-boot,melis-elf \
		--match opensbi=opensbi.fex \
		--match u-boot=u-boot.fex \
		--match melis-elf=amp_rv0.fex >/dev/null
	"$UPDATE_MBR" sys_partition.bin 4 >/dev/null
	"$UPDATE_MBR" sys_partition.bin 4 sunxi_mbr.fex dlinfo.fex 15269888 40960 0 >/dev/null
	# The host-visible SD layout is standard DOS/MBR.  The fixed vendor Boot0
	# also requires its Allwinner partition map at LBA1; keep it as compatibility
	# metadata with invalid GPT CRCs so Linux and host tools use the MBR at LBA0.
	python3 "$MAKE_SD_MBR" --output avaota-f1-sd.raw \
		--boot0-gpt sunxi_gpt.fex --sectors "$SD_IMAGE_SECTORS" >/dev/null
	find . -maxdepth 1 -type f -name sunxi_gpt.fex -delete
	copy_at_sector() {
		input=$1
		sector=$2
		dd if="$input" of=avaota-f1-sd.raw bs=512 seek="$sector" \
			conv=notrunc 2>/dev/null
	}
	copy_at_sector boot0_sdcard.fex 16
	copy_at_sector boot0_sdcard.fex 256
	copy_at_sector boot_package.fex 24576
	copy_at_sector boot_package.fex 32800
	copy_at_sector sunxi_mbr.fex 40960
	copy_at_sector boot-resource.fex 41088
	copy_at_sector env.fex 51328
	copy_at_sector env.fex 51840
	copy_at_sector boot.fex 52352
	copy_at_sector amp_rv0.fex 63616
	copy_at_sector rootfs.fex 67712
)
cp -f "$PACK_DIR/avaota-f1-sd.raw" "$OUTPUT_DIR/avaota-f1-sd.raw"

echo "==> packaging common Allwinner SPI-NOR/SD image"
(
	cd "$PACK_DIR"
	# Tina's image_nor flow is the SPI-NOR IMAGEWTY flow.  It is not an SD
	# image and must be written to SPI-NOR with PhoenixSuit.
	# update_mbr rewrites dlinfo.fex in place.  The SD raw flow above leaves
	# an SD dlinfo, while this image deliberately carries the NOR dlinfo
	# matching sys_partition_nor.fex.
	cp -f dlinfo-nor.fex dlinfo.fex
	"$MKENVIMAGE" -r -s 0x20000 -o env.fex "$BOARD_DIR/env-nor.cfg"
	check_env_image env.fex
	cp -f sys_config-nor.fex sys_config.fex
	cp -f sys_config-nor.bin config.fex
	cp -f sys_partition_nor.fex sys_partition.fex
	cp -f sunxi_gpt-nor.fex sunxi_gpt.fex
	run_pack_tool "$DRAGON" image_nor.cfg sys_partition.fex >/dev/null
	python3 "$CHECK_IMAGE" avaota-f1-spinor.img \
		--item COMMON:SYS_CONFIG100000=sys_config.fex \
		--item COMMON:SYS_CONFIG000000=sys_partition.fex \
		--item 12345678:BOOTPKG-00000000=boot_package.fex \
		--item 12345678:BOOTPKG-NOR00000=boot_package_nor.fex \
		--filename u-boot-efex.fex=u-boot-efex.fex \
		--filename sunxi_gpt.fex=sunxi_gpt.fex \
		--filename sunxi_mbr_nor.fex=sunxi_mbr_nor.fex \
		--filename dlinfo.fex=dlinfo-nor.fex \
		--filename cardtool.fex=cardtool.fex \
		--filename cardscript.fex=cardscript.fex \
		--filename env.fex=env.fex \
		--filename boot.fex=boot.fex \
		--filename rootfs_nor.fex=rootfs_nor.fex >/dev/null
)
cp -f "$PACK_DIR/avaota-f1-spinor.img" "$OUTPUT_DIR/avaota-f1-spinor.img"

python3 "$CHECK_PARTITION_MODES" \
	--nor-gpt "$PACK_DIR/sunxi_gpt.fex" \
	--sd-raw "$OUTPUT_DIR/avaota-f1-sd.raw" \
	--sd-env "$PACK_DIR/env-sd.fex" \
	--nor-env "$PACK_DIR/env-nor.fex" >/dev/null

# These are only snapshots needed while the SD flow rewrites the shared FEX
# files.  They must not look like publishable board inputs in the scratch
# directory after a successful pack.
rm -f "$PACK_DIR/dlinfo-nor.fex" "$PACK_DIR/sunxi_gpt-nor.fex"
# The vendor `script` helper leaves four-byte V*.fex checksum sidecars in its
# working directory.  They are not referenced by image_nor.cfg or any output
# image, so remove them from the reusable scratch directory as well.
find "$PACK_DIR" -maxdepth 1 -type f -name 'V*.fex' -delete

nor_magic=$(dd if="$OUTPUT_DIR/avaota-f1-spinor.raw" bs=1 skip=4 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
sd_mbr_magic=$(dd if="$OUTPUT_DIR/avaota-f1-sd.raw" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
sd_boot0_gpt_magic=$(dd if="$OUTPUT_DIR/avaota-f1-sd.raw" bs=1 skip=512 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
sd_boot0_gpt_crc=$(dd if="$OUTPUT_DIR/avaota-f1-sd.raw" bs=1 skip=528 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
sd_raw_magic=$(dd if="$OUTPUT_DIR/avaota-f1-sd.raw" bs=1 skip=$((16 * 512 + 4)) count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
spinor_image_magic=$(dd if="$OUTPUT_DIR/avaota-f1-spinor.img" bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$nor_magic" = "65474f4e2e425430" ] ||
	{ echo "error: invalid NOR eGON.BT0 magic" >&2; exit 1; }
[ "$sd_mbr_magic" = "55aa" ] ||
	{ echo "error: invalid SD DOS/MBR signature" >&2; exit 1; }
[ "$sd_boot0_gpt_magic" = "4546492050415254" ] ||
	{ echo "error: SD raw image is missing the V821 Boot0 GPT compatibility header" >&2; exit 1; }
[ "$sd_boot0_gpt_crc" = "00000000" ] ||
	{ echo "error: SD Boot0 GPT compatibility header must not override the DOS MBR" >&2; exit 1; }
[ "$sd_raw_magic" = "65474f4e2e425430" ] ||
	{ echo "error: invalid SD raw eGON.BT0 magic" >&2; exit 1; }
[ "$spinor_image_magic" = "494d414745575459" ] ||
	{ echo "error: invalid SPI-NOR IMAGEWTY magic" >&2; exit 1; }

python3 "$CHECK_RAW_IMAGES" \
	--nor-raw "$OUTPUT_DIR/avaota-f1-spinor.raw" \
	--nor-package "$PACK_DIR/boot_package_nor.fex" \
	--sd-raw "$OUTPUT_DIR/avaota-f1-sd.raw" \
	--sd-package "$PACK_DIR/boot_package.fex" >/dev/null

(
	cd "$OUTPUT_DIR"
	sha256sum avaota-f1-spinor.img avaota-f1-spinor.raw avaota-f1-sd.raw > avaota-f1-images.sha256
)
{
	echo "board=Avaota-F1"
	echo "soc=Allwinner V821 / sun300iw1p1"
	echo "toolchain=$MACHINE"
	echo "kernel=$KERNEL"
	echo "dtb=$DTB"
	echo "allwinner_spinor_image=$OUTPUT_DIR/avaota-f1-spinor.img"
	echo "spinor_raw_image=$OUTPUT_DIR/avaota-f1-spinor.raw"
	echo "sd_raw_image=$OUTPUT_DIR/avaota-f1-sd.raw"
	echo "nor_layout=32MiB SPI-NOR, logic_start=2016 sectors, uboot_start=128 sectors"
	echo "nor_root=/dev/mtdblock6"
	echo "sd_layout=DOS-MBR@LBA0, Boot0-GPT-compat@LBA1(invalid-CRC), p1=boot@LBA52352+10240, p2=rootfs@LBA67712+20096, p3=rootfs_data@LBA87808+10240, p4=UDISK@LBA98048+to-end"
	echo "sd_root=/dev/mmcblk0p2"
	echo "sd_allwinner_boot=Boot0@LBA16/256, boot_package@LBA24576/32800, sunxi_mbr@LBA40960, logical_start=40960 sectors"
	echo "sd_image_sectors=$SD_IMAGE_SECTORS"
	echo "spinor_image_scope=Allwinner IMAGEWTY image for SPI-NOR/PhoenixSuit only"
	echo "nor_boot_package=uncompressed:opensbi,u-boot,pmboot; u-boot=u-boot-spinor.fex; storage_type=3"
	echo "nor_fel_uboot=u-boot-efex.fex; dedicated EFEX/FEL variant; storage_type=3"
	echo "sd_boot_package=uncompressed:opensbi,u-boot,melis-elf; u-boot=u-boot.fex; storage_type=1"
} > "$OUTPUT_DIR/avaota-f1-boot-manifest.txt"

echo "SPINOR: $OUTPUT_DIR/avaota-f1-spinor.img"
echo "NOR  : $OUTPUT_DIR/avaota-f1-spinor.raw"
echo "SD   : $OUTPUT_DIR/avaota-f1-sd.raw"

