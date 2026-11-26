#!/usr/bin/env bash
# Rebuild P720S11 boot.img + vendor_dlkm.img from this device's own stock dump.
# Required layout:
#   DUMP/boot_a.img
#   DUMP/vendor_boot.img
#   DUMP/vendor_dlkm.img
#   IMGDIR/vendor_dlkm_extract/lib/modules/
# Overrides: OUT=... DUMP=... IMGDIR=... HOST_TOOLS_BIN=... BOOT_PARTITION_SIZE=67108864
set -euo pipefail
cd "$(dirname "$0")"

OUT=${OUT:-out_stock_lto2}
DUMP=${DUMP:-device_dump}
IMGDIR=${IMGDIR:-out_images}
HOST_TOOLS_BIN=${HOST_TOOLS_BIN:-}
BOOT_PARTITION_SIZE=${BOOT_PARTITION_SIZE:-67108864}
WORK="$IMGDIR/work_pack"

# Replace the original developer's private AOSP out/host path with an explicit
# host-tools override. Tools may also be installed in the runner's PATH.
if [[ -n "$HOST_TOOLS_BIN" ]]; then
    [[ -d "$HOST_TOOLS_BIN" ]] || { echo "ERROR: HOST_TOOLS_BIN does not exist: $HOST_TOOLS_BIN" >&2; exit 2; }
    export PATH="$HOST_TOOLS_BIN:$PATH"
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $1" >&2; exit 2; }; }
for tool in unpack_bootimg mkbootimg fsck.erofs mkfs.erofs lz4 cpio python3 sha256sum; do need_cmd "$tool"; done

[[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: missing $OUT/arch/arm64/boot/Image; build the kernel first." >&2; exit 1; }
for f in "$DUMP/boot_a.img" "$DUMP/vendor_boot.img" "$DUMP/vendor_dlkm.img"; do
    [[ -s "$f" ]] || { echo "ERROR: missing device dump input: $f" >&2; exit 1; }
done
[[ -d "$IMGDIR/vendor_dlkm_extract/lib/modules" ]] || {
    echo "ERROR: missing $IMGDIR/vendor_dlkm_extract/lib/modules; extract the device's vendor_dlkm first." >&2
    exit 1
}
[[ "$BOOT_PARTITION_SIZE" =~ ^[0-9]+$ ]] && (( BOOT_PARTITION_SIZE > 0 )) || {
    echo "ERROR: BOOT_PARTITION_SIZE must be a positive byte count." >&2; exit 2;
}
mkdir -p "$WORK" "$IMGDIR"

echo "== 1. boot.img (preserve stock header parameters) =="
rm -rf "$WORK/boot"
mkdir -p "$WORK/boot"
unpack_bootimg --boot_img "$DUMP/boot_a.img" --out "$WORK/boot" --format=mkbootimg > "$WORK/boot/mkbootimg.args"
[[ -s "$WORK/boot/ramdisk" ]] || { echo "ERROR: unpack_bootimg did not extract ramdisk." >&2; exit 1; }
# Keep every original mkbootimg header parameter (header version, OS version,
# patch level, cmdline, offsets, board, signature, etc.); replace only kernel,
# ramdisk and output. This avoids the previous hard-coded OS/patch-level loss.
python3 - "$WORK/boot/mkbootimg.args" "$OUT/arch/arm64/boot/Image" "$WORK/boot/ramdisk" "$IMGDIR/boot_stock.img" <<'PY'
import shlex, subprocess, sys
arg_file, kernel, ramdisk, output = sys.argv[1:]
args = shlex.split(open(arg_file, encoding="utf-8").read())
skip = {"--kernel", "--ramdisk", "--output"}
kept = []
i = 0
while i < len(args):
    if args[i] in skip:
        i += 2
    else:
        kept.append(args[i])
        i += 1
cmd = ["mkbootimg", *kept, "--kernel", kernel, "--ramdisk", ramdisk, "--output", output]
print("[mkbootimg] preserving stock parameters; replacing kernel and ramdisk")
subprocess.run(cmd, check=True)
PY
BOOT_IMAGE_SIZE=$(stat -c%s "$IMGDIR/boot_stock.img")
if (( BOOT_IMAGE_SIZE > BOOT_PARTITION_SIZE )); then
    echo "ERROR: rebuilt boot image ($BOOT_IMAGE_SIZE) exceeds configured boot partition ($BOOT_PARTITION_SIZE)." >&2
    exit 1
fi
truncate -s "$BOOT_PARTITION_SIZE" "$IMGDIR/boot_stock.img"
echo "   boot image: $BOOT_IMAGE_SIZE bytes; padded partition image: $BOOT_PARTITION_SIZE bytes"

echo "== 2. vendor_dlkm.img =="
STAGE="$WORK/vd"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib/modules"
cp -a "$IMGDIR/vendor_dlkm_extract/lib/modules/." "$STAGE/lib/modules/"

# Extract metadata and the module inventory from the device's own image.
rm -rf "$WORK/vdref"
mkdir -p "$WORK/vdref"
fsck.erofs --extract="$WORK/vdref" "$DUMP/vendor_dlkm.img" >/dev/null 2>&1
RAMDISK_LOAD="$WORK/ramdisk_modules.load"
if [[ ! -s "$RAMDISK_LOAD" ]]; then
    for cand in "$DUMP/vb_unpack/ex00/lib/modules/modules.load" "$WORK/vbex/lib/modules/modules.load"; do
        if [[ -s "$cand" ]]; then cp -f "$cand" "$RAMDISK_LOAD"; break; fi
    done
    if [[ ! -s "$RAMDISK_LOAD" ]]; then
        rm -rf "$WORK/vb" "$WORK/vbex"
        mkdir -p "$WORK/vb" "$WORK/vbex"
        if unpack_bootimg --boot_img "$DUMP/vendor_boot.img" --out "$WORK/vb" >/dev/null 2>&1; then
            ramdisk_file=$(find "$WORK/vb" -maxdepth 1 -type f -name 'vendor_ramdisk*' -print -quit)
            if [[ -n "$ramdisk_file" ]]; then
                ( cd "$WORK/vbex" && (lz4 -d "$ramdisk_file" stdout 2>/dev/null || lz4 -dc "$ramdisk_file" 2>/dev/null || cat "$ramdisk_file") | cpio -idm --quiet 2>/dev/null ) || true
                [[ -s "$WORK/vbex/lib/modules/modules.load" ]] && cp -f "$WORK/vbex/lib/modules/modules.load" "$RAMDISK_LOAD"
            fi
        fi
    fi
fi

for f in modules.load modules.dep modules.alias modules.softdep modules.load.cali modules.load.charger init.insmod.cfg; do
    [[ -f "$WORK/vdref/lib/modules/$f" ]] && cp -f "$WORK/vdref/lib/modules/$f" "$STAGE/lib/modules/$f"
done
# Some vendor builds keep the first-stage module list in vendor_boot rather
# than vendor_dlkm. Preserve it when vendor_dlkm itself has no modules.load.
if [[ ! -s "$STAGE/lib/modules/modules.load" && -s "$RAMDISK_LOAD" ]]; then
    cp -f "$RAMDISK_LOAD" "$STAGE/lib/modules/modules.load"
fi

# Rebuild only modules already present in the device's vendor_dlkm. Do not
# blindly inject every .ko from the kernel output into the vendor partition.
shopt -s nullglob
device_kos=("$WORK/vdref/lib/modules/"*.ko)
(( ${#device_kos[@]} > 0 )) || { echo "ERROR: no .ko files found in the device vendor_dlkm image." >&2; exit 1; }
added=0
for ko in "${device_kos[@]}"; do
    name=$(basename "$ko")
    if [[ -f "$OUT/$name" ]]; then
        built="$OUT/$name"
    else
        built=$(find "$OUT" -type f -name "$name" -print -quit 2>/dev/null || true)
    fi
    if [[ -n "$built" ]]; then
        cp -f "$built" "$STAGE/lib/modules/$name"
        ( llvm-strip --strip-debug "$STAGE/lib/modules/$name" 2>/dev/null || aarch64-linux-gnu-strip --strip-debug "$STAGE/lib/modules/$name" 2>/dev/null || true )
    elif [[ ! -f "$STAGE/lib/modules/$name" ]]; then
        cp -f "$ko" "$STAGE/lib/modules/$name"
    fi
    chmod 644 "$STAGE/lib/modules/$name"
    added=$((added+1))
done
module_count=$(find "$STAGE/lib/modules" -maxdepth 1 -type f -name '*.ko' | wc -l)
echo "   processed $added stock modules; staged module count $module_count"

FC="$WORK/file_contexts"
cat > "$FC" <<'EOT'
/(vendor_dlkm|vendor/vendor_dlkm|system/vendor/vendor_dlkm)(/.*)?	u:object_r:vendor_file:s0
/(vendor_dlkm|vendor/vendor_dlkm|system/vendor/vendor_dlkm)/etc(/.*)?	u:object_r:vendor_configs_file:s0
EOT
find "$STAGE" -type d -exec chmod 755 {} ;
find "$STAGE" -type f -exec chmod 644 {} ;
rm -f "$IMGDIR/vendor_dlkm_stock.img"
mkfs.erofs -b 4096 -zlz4hc,9 --all-root -T 1712768737 \
    -U df370144-e703-4f5f-a8db-6ade567482e3 -E ^xattr-name-filter \
    --mount-point /vendor_dlkm --file-contexts="$FC" \
    "$IMGDIR/vendor_dlkm_stock.img" "$STAGE" >/dev/null
echo "   vendor_dlkm image: $(stat -c%s "$IMGDIR/vendor_dlkm_stock.img") bytes"

echo "== 3. Checksums =="
sha256sum "$IMGDIR/boot_stock.img" "$IMGDIR/vendor_dlkm_stock.img"
echo "NOTE: images are raw partition images, not a recovery-flashable ZIP."
