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
[[ -d "$IMGDIR/vendor_dlkm_extract/lib/modules" ]] || {
    echo "Missing $IMGDIR/vendor_dlkm_extract/lib/modules (extract the matching stock vendor_dlkm first)." >&2
    exit 1
}
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
mkdir -p "$STAGE/lib/modules" "$VDREF"
cp -a "$IMGDIR/vendor_dlkm_extract/lib/modules/." "$STAGE/lib/modules/"
fsck.erofs --extract="$VDREF" "$DUMP/vendor_dlkm.img" >/dev/null

# Keep the target device's module metadata. The vendor_boot modules.load list
# is not a vendor_dlkm file and is intentionally not fabricated here.
for f in modules.load modules.dep modules.alias modules.softdep modules.load.cali modules.load.charger init.insmod.cfg; do
    [[ ! -f "$VDREF/lib/modules/$f" ]] || cp -f "$VDREF/lib/modules/$f" "$STAGE/lib/modules/$f"
done

# Add modules present in the device dump but absent from the extracted staging
# tree. Prefer a matching build output; otherwise retain the exact stock KO.
added=0
shopt -s nullglob
for ko in "$VDREF/lib/modules/"*.ko; do
    name="$(basename "$ko")"
    [[ -f "$STAGE/lib/modules/$name" ]] && continue
    built="$(find "$OUT" -type f -name "$name" -print -quit)"
    if [[ -n "$built" ]]; then
        cp -f "$built" "$STAGE/lib/modules/$name"
        if command -v llvm-strip >/dev/null; then
            llvm-strip --strip-debug "$STAGE/lib/modules/$name"
        elif command -v aarch64-linux-gnu-strip >/dev/null; then
            aarch64-linux-gnu-strip --strip-debug "$STAGE/lib/modules/$name"
        fi
    else
        cp -f "$ko" "$STAGE/lib/modules/$name"
    fi
    chmod 644 "$STAGE/lib/modules/$name"
    added=$((added+1))
done
shopt -u nullglob

echo "   additional modules: $added"
echo "   total modules: $(find "$STAGE/lib/modules" -maxdepth 1 -type f -name '*.ko' | wc -l)"

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
