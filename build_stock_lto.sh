#!/usr/bin/env bash
# Stock P720S11 config + Android Clang ThinLTO/CFI build.
# CI/local overrides:
#   OUT=out_stock_lto2 CLANG_BIN=/path/to/clang/bin ./build_stock_lto.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT=${OUT:-out_stock_lto2}
CLANG_BIN=${CLANG_BIN:-}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
CFG="$OUT/.config"
DEFCONFIG=arch/arm64/configs/sprd_p720s11_defconfig

# Never depend on the original developer's AOSP checkout path.
if [[ -n "$CLANG_BIN" ]]; then
    [[ -x "$CLANG_BIN/clang" ]] || { echo "ERROR: CLANG_BIN has no executable clang: $CLANG_BIN" >&2; exit 2; }
    export PATH="$CLANG_BIN:$PATH"
fi
command -v clang >/dev/null || { echo "ERROR: clang not found; set CLANG_BIN to the toolchain bin directory." >&2; exit 2; }
command -v ld.lld >/dev/null || { echo "ERROR: ld.lld not found in PATH." >&2; exit 2; }
command -v llvm-ar >/dev/null || { echo "ERROR: llvm-ar not found in PATH." >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required." >&2; exit 2; }

mkdir -p "$OUT"

# Kbuild 5.4 refuses an out-of-tree build when the source root contains
# .config, even when O= points at a separate output directory. This
# repository tracks a root .config, so preserve it outside the tree while
# building and restore it on every normal shell exit (success or failure).
SOURCE_CONFIG_BACKUP=""
if [[ -f .config ]]; then
    SOURCE_CONFIG_BACKUP=$(mktemp "${TMPDIR:-/tmp}/p720s11-source-config.XXXXXX")
    mv .config "$SOURCE_CONFIG_BACKUP"
    restore_source_config() {
        if [[ -n "$SOURCE_CONFIG_BACKUP" && -f "$SOURCE_CONFIG_BACKUP" ]]; then
            mv -f "$SOURCE_CONFIG_BACKUP" .config
        fi
    }
    trap restore_source_config EXIT
fi

if [[ ! -f "$CFG" ]]; then
    # CI starts with a clean workspace: use the checked-in known-good config.
    if [[ -f stock_p720s11.config ]]; then
        cp stock_p720s11.config "$CFG"
        echo "[config] initialized from stock_p720s11.config"
    elif [[ -f out_lto/.config ]]; then
        cp out_lto/.config "$CFG"
        echo "[config] initialized from out_lto/.config"
    else
        echo "[config] no saved config; generating $DEFCONFIG"
        make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" sprd_p720s11_defconfig
    fi
fi
[[ -s "$CFG" ]] || { echo "ERROR: failed to initialize $CFG" >&2; exit 2; }

python3 - "$CFG" "$DEFCONFIG" <<'PY'
import re, sys
cfg, deff = sys.argv[1], sys.argv[2]
want = {}
with open(deff, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        m = re.match(r'^(# )?(CONFIG_[A-Z0-9_]+)(=| is not set)', line)
        if m and m.group(2).startswith('CONFIG_KSU'):
            want[m.group(2)] = line
with open(cfg, encoding="utf-8") as f:
    lines = f.read().splitlines()
out = []
for line in lines:
    m = re.match(r'^(# )?(CONFIG_[A-Z0-9_]+)(=| is not set)', line)
    if m and m.group(2) in want:
        continue
    out.append(line)
out.extend(want.values())
with open(cfg, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
print(f"[config] imported {len(want)} KSU symbols from {deff}")
PY

scripts/config --file "$CFG" \
  -e LTO_CLANG -e THINLTO -e CFI_CLANG \
  -e VENDOR_COMMON_COMPILE -e VENDOR_SOC_SPRD_COMPILE \
  -m TOUCHSCREEN_VENDOR_V2 -m TOUCHSCREEN_LCD_NOTIFY \
  -e KSU -d KSU_SUSFS -e KSU_MANUAL_HOOK -d KSU_TRACEPOINT_HOOK \
  -e KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
  -e KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
  -e KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
  -d WERROR
while IFS= read -r sym; do
    [[ -n "$sym" ]] && scripts/config --file "$CFG" -d "${sym#CONFIG_}"
done < <(grep -oE '^CONFIG_KSU_SUSFS[A-Z0-9_]*' "$CFG" || true)

# Keep the version metadata used by the author's known-good flashed build.
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-twodays}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-twodays-Workstation}
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Fri Oct 2 14:55:29 CST 2026"}
[[ -f "$OUT/.version" ]] || echo 2 > "$OUT/.version"

MAKE_ARGS=(O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION=
           KCFLAGS="-Wno-error=enum-compare -Wno-error=compare-distinct-pointer-types -Wno-error=strict-prototypes")

echo "== Toolchain =="
clang --version | head -n 1
ld.lld --version | head -n 1
echo "== Configuration =="
make "${MAKE_ARGS[@]}" olddefconfig
require_enabled() {
    grep -qx "CONFIG_$1=y" "$CFG" || {
        echo "ERROR: required config CONFIG_$1=y is not enabled after olddefconfig." >&2
        exit 1
    }
}
for symbol in LTO_CLANG THINLTO CFI_CLANG KSU KSU_MANUAL_HOOK \
              KSU_MANUAL_HOOK_AUTO_SETUID_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
              KSU_MANUAL_HOOK_AUTO_INPUT_HOOK VENDOR_COMMON_COMPILE VENDOR_SOC_SPRD_COMPILE; do
    require_enabled "$symbol"
done
grep -E '^(CONFIG_(KSU|KSU_MANUAL_HOOK|LTO_CLANG|THINLTO|CFI_CLANG|VENDOR_COMMON_COMPILE|VENDOR_SOC_SPRD_COMPILE)=|# CONFIG_KSU_SUSFS is not set)' "$CFG"

echo "== Build =="
make "${MAKE_ARGS[@]}" -j"$(nproc)" Image modules
[[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: Image was not produced." >&2; exit 1; }
echo "== Image =="
ls -lh "$OUT/arch/arm64/boot/Image"
echo "== Modules =="
find "$OUT" -type f -name '*.ko' | wc -l
make "${MAKE_ARGS[@]}" kernelrelease
