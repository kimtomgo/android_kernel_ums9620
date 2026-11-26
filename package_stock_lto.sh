#!/usr/bin/env bash
# Repackage a P720S11 boot image and vendor_dlkm image from this device's own
# stock dumps. This does not create a flashable ZIP.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

OUT="${OUT:-out_stock_lto2}"
DUMP="${DUMP:-device_dump}"
IMGDIR="${IMGDIR:-out_images}"
HOST_TOOLS_DIR="${HOST_TOOLS_DIR:-}"
BOOT_PARTITION_SIZE="${BOOT_PARTITION_SIZE:-67108864}"
WORK="$IMGDIR/work_pack"

if [[ -n "$HOST_TOOLS_DIR" ]]; then
    [[ -d "$HOST_TOOLS_DIR" ]] || { echo "HOST_TOOLS_DIR does not exist: $HOST_TOOLS_DIR" >&2; exit 2; }
    export PATH="$HOST_TOOLS_DIR:$PATH"
fi
for tool in unpack_bootimg mkbootimg fsck.erofs mkfs.erofs lz4 cpio; do
    command -v "$tool" >/dev/null || { echo "Required host tool not found: $tool" >&2; exit 2; }
done

[[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "Missing $OUT/arch/arm64/boot/Image; build first." >&2; exit 1; }
[[ -s "$DUMP/boot_a.img" ]] || { echo "Missing $DUMP/boot_a.img" >&2; exit 1; }
[[ -s "$DUMP/vendor_dlkm.img" ]] || { echo "Missing $DUMP/vendor_dlkm.img" >&2; exit 1; }
[[ "$BOOT_PARTITION_SIZE" =~ ^[0-9]+$ ]] || { echo "BOOT_PARTITION_SIZE must be an integer byte count" >&2; exit 2; }

mkdir -p "$WORK" "$IMGDIR"

echo "== 1. Rebuild boot.img, preserving the original header parameters =="
rm -rf "$WORK/boot"
mkdir -p "$WORK/boot"
# The NUL-delimited argument list avoids shell-quoting bugs and preserves the
# original page size, offsets, cmdline, board, OS version and header version.
mapfile -d '' -t BOOT_ARGS < <(
    unpack_bootimg --boot_img "$DUMP/boot_a.img" --out "$WORK/boot" --format=mkbootimg -0
)
(("${#BOOT_ARGS[@]}" > 0)) || { echo "Could not read original boot header parameters" >&2; exit 1; }

kernel_arg=0
ramdisk_arg=0
for ((i=0; i<${#BOOT_ARGS[@]}; i++)); do
    case "${BOOT_ARGS[$i]}" in
        --kernel)
            BOOT_ARGS[$((i+1))]="$OUT/arch/arm64/boot/Image"
            kernel_arg=1
            ;;
        --ramdisk)
            # Keep the byte-for-byte ramdisk extracted from this device.
            BOOT_ARGS[$((i+1))]="$WORK/boot/ramdisk"
            ramdisk_arg=1
            ;;
    esac
done
(( kernel_arg == 1 && ramdisk_arg == 1 )) || {
    echo "Original boot image did not expose both --kernel and --ramdisk arguments; refusing to guess." >&2
    exit 1
}
rm -f "$IMGDIR/boot_stock.img"
mkbootimg "${BOOT_ARGS[@]}" --output "$IMGDIR/boot_stock.img"
boot_bytes="$(stat -c '%s' "$IMGDIR/boot_stock.img")"
if (( boot_bytes > BOOT_PARTITION_SIZE )); then
    echo "boot image is $boot_bytes bytes, larger than target partition $BOOT_PARTITION_SIZE; refusing to truncate." >&2
    exit 1
fi
truncate -s "$BOOT_PARTITION_SIZE" "$IMGDIR/boot_stock.img"
echo "   boot_stock.img: $(stat -c '%s' "$IMGDIR/boot_stock.img") bytes"

echo "== 2. Rebuild vendor_dlkm.img =="
STAGE="$WORK/vd"
VDREF="$WORK/vdref"
rm -rf "$STAGE" "$VDREF"
mkdir -p "$STAGE" "$VDREF"
fsck.erofs --extract="$VDREF" "$DUMP/vendor_dlkm.img" >/dev/null
# Rebuild from the exact target-device EROFS contents. Do not mix in a second
# extracted image or silently replace modules with unverified build outputs.
cp -a "$VDREF/." "$STAGE/"
[[ -d "$STAGE/lib/modules" ]] || { echo "vendor_dlkm image has no lib/modules directory" >&2; exit 1; }
echo "   stock modules: $(find "$STAGE/lib/modules" -type f -name '*.ko' | wc -l)"

FC="$WORK/file_contexts"
cat > "$FC" <<'EOT'
/(vendor_dlkm|vendor/vendor_dlkm|system/vendor/vendor_dlkm)(/.*)?	u:object_r:vendor_file:s0
/(vendor_dlkm|vendor/vendor_dlkm|system/vendor/vendor_dlkm)/etc(/.*)?	u:object_r:vendor_configs_file:s0
EOT
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
rm -f "$IMGDIR/vendor_dlkm_stock.img"
mkfs.erofs -b 4096 -zlz4hc,9 --all-root -T 1712768737 \
    -U df370144-e703-4f5f-a8db-6ade567482e3 -E ^xattr-name-filter \
    --mount-point /vendor_dlkm --file-contexts="$FC" \
    "$IMGDIR/vendor_dlkm_stock.img" "$STAGE" >/dev/null

echo "== 3. Output checksums =="
fsck.erofs "$IMGDIR/vendor_dlkm_stock.img" >/dev/null
sha256sum "$IMGDIR/boot_stock.img" "$IMGDIR/vendor_dlkm_stock.img"
echo "NOTE: these are raw partition images, not a recovery-flashable ZIP."
