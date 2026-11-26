#!/usr/bin/env bash
# Build selected Unisoc BSP out-of-tree modules against the P720S11 kernel.
#   OUT=out_stock_lto2 CLANG_BIN=/path/to/clang/bin ./build_bsp_modules.sh <KO_MODULE_NAME> [...]
set -euo pipefail
cd "$(dirname "$0")"

OUT=${OUT:-out_stageb}
CLANG_BIN=${CLANG_BIN:-}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
if [[ -n "$CLANG_BIN" ]]; then
    [[ -x "$CLANG_BIN/clang" ]] || { echo "ERROR: CLANG_BIN has no executable clang: $CLANG_BIN" >&2; exit 2; }
    export PATH="$CLANG_BIN:$PATH"
fi
command -v clang >/dev/null || { echo "ERROR: clang not found; set CLANG_BIN." >&2; exit 2; }
command -v ld.lld >/dev/null || { echo "ERROR: ld.lld not found." >&2; exit 2; }

if [[ $# -lt 1 ]]; then
    echo "Usage: OUT=<kernel-out> CLANG_BIN=<clang-bin> $0 <KO_MODULE_NAME> [...]" >&2
    exit 2
fi

KDIR="$(pwd)/$OUT"
[[ -s "$KDIR/.config" ]] || { echo "ERROR: missing $KDIR/.config; build/configure the kernel first." >&2; exit 2; }
[[ -f "$KDIR/include/generated/autoconf.h" ]] || { echo "ERROR: missing generated kernel headers; run the kernel build first." >&2; exit 2; }
BSP_OUT="$KDIR/bsp_modules"
export BSP_MODULES_OUT="$BSP_OUT"
export BSP_KERNEL_PATH="$KDIR"
export BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig
export BSP_KERNEL_VERSION=kernel5.4
export BSP_BOARD_CAMERA_MODULE_ISP_VERSION=isp2.6
export BSP_BOARD_CAMERA_MODULE_ISP_ADAPT_VERSION=qogirn6pro
export BSP_BOARD_CAMERA_MODULE_CSI_VERSION=receiver_r3p1v2
export BSP_BOARD_CAMERA_MODULE_CPP_VERSION=lite_r6p0
export BSP_BOARD_CAMERA_MODULE_DVFS=qogirn6pro
export BSP_BOARD_CAMERA_PRODECT_NAME=qogirn6pro
export BSP_BOARD_PRODUCT_USING_VDSP=qogirn6pro
export BSP_VDSP_TARGET_DTB=ums9620_2h10
export BSP_BOARD_UNISOC_WCN_SOCKET=sdio
mkdir -p "$BSP_OUT"

MAKEARGS=(O="$KDIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION=
          KCFLAGS="-Wno-error=enum-compare -Wno-error=compare-distinct-pointer-types -Wno-error=strict-prototypes")

built=0
failed=0
for name in "$@"; do
    src=$(grep -rlE "^[[:space:]]*(export[[:space:]]+)?KO_MODULE_NAME[[:space:]]*:=[[:space:]]*$name\$" \
            kernel_modules --include=Kbuild --include=Makefile 2>/dev/null \
          | grep -v "/Kbuild\$" | head -1 | xargs -r dirname || true)
    if [[ -z "$src" ]]; then
        src=$(grep -rlE "^[[:space:]]*(export[[:space:]]+)?KO_MODULE_NAME[[:space:]]*:=[[:space:]]*$name\$" \
                kernel_modules --include=Kbuild 2>/dev/null | head -1 | xargs -r dirname || true)
    fi
    if [[ -z "$src" ]]; then
        echo "ERROR: $name: KO_MODULE_NAME not found in kernel_modules/" >&2
        failed=$((failed+1))
        continue
    fi
    od="$BSP_OUT/$name"
    rm -rf "$od"
    mkdir -p "$od"
    if [[ -f "$src/Kbuild" ]]; then
        ln -snf "$(pwd)/$src/Kbuild" "$od/Kbuild"
    elif [[ -f "$src/Makefile" ]]; then
        ln -snf "$(pwd)/$src/Makefile" "$od/Makefile"
    else
        echo "ERROR: $name: source directory has neither Kbuild nor Makefile: $src" >&2
        failed=$((failed+1))
        continue
    fi
    ln -snf "$(pwd)/$src" "$od/source"
    if make "${MAKEARGS[@]}" KBUILD_MODPOST_WARN=1 M="$od" src="$(pwd)/$src" modules > "$od/build.log" 2>&1; then
        ko=$(find "$od" -type f -name "$name.ko" -print -quit)
        if [[ -n "$ko" ]]; then
            printf "  OK %-34s %9s B  (%s)\n" "$name.ko" "$(stat -c%s "$ko")" "${src#kernel_modules/}"
            built=$((built+1))
        else
            echo "ERROR: $name: build succeeded but no $name.ko was produced"
            failed=$((failed+1))
        fi
    else
        err=$(grep -m1 -E "error:|Error [0-9]" "$od/build.log" | head -1 || true)
        printf "FAIL %-34s %s\n" "$name.ko" "${err:-see $od/build.log}"
        failed=$((failed+1))
    fi
done
echo "== BSP modules: $built succeeded / $failed failed =="
[[ "$failed" -eq 0 ]]
