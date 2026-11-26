#!/usr/bin/env bash
# Build the P720S11 stock-based kernel with the pinned Android Clang toolchain.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

OUT="${OUT:-out_stock_lto2}"
DEFCONFIG="${DEFCONFIG:-arch/arm64/configs/sprd_p720s11_defconfig}"
STOCK_CONFIG="${STOCK_CONFIG:-stock_p720s11.config}"
JOBS="${JOBS:-$(nproc)}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# CLANG_DIR may point to the bin directory from an AOSP prebuilt, e.g.
# /opt/toolchains/clang-r563880c/bin. Do not depend on the original author's
# workstation paths.
if [[ -n "${CLANG_DIR:-}" ]]; then
    [[ -d "$CLANG_DIR" ]] || { echo "CLANG_DIR does not exist: $CLANG_DIR" >&2; exit 2; }
    export PATH="$CLANG_DIR:$PATH"
fi
command -v clang >/dev/null || {
    echo "clang not found. Set CLANG_DIR=/path/to/clang-r563880c/bin or install clang." >&2
    exit 2
}
command -v ld.lld >/dev/null || { echo "ld.lld not found in PATH" >&2; exit 2; }
command -v llvm-ar >/dev/null || { echo "llvm-ar not found in PATH" >&2; exit 2; }

mkdir -p "$OUT"
CFG="$OUT/.config"

# Prefer an existing output config, then the known-good config captured from
# the running P720S11 kernel. Never silently copy an unrelated out_lto config.
if [[ ! -s "$CFG" ]]; then
    if [[ -s "$STOCK_CONFIG" ]]; then
        cp "$STOCK_CONFIG" "$CFG"
        echo "[config] seeded $CFG from $STOCK_CONFIG"
    else
        echo "Missing $CFG and $STOCK_CONFIG. Refusing to guess a device config." >&2
        exit 1
    fi
fi
[[ -s "$DEFCONFIG" ]] || { echo "Missing defconfig: $DEFCONFIG" >&2; exit 1; }

python3 - "$CFG" "$DEFCONFIG" <<'PY'
import re, sys
cfg, deff = sys.argv[1:]
want = {}
for line in open(deff, encoding="utf-8"):
    m = re.match(r"^(# )?(CONFIG_[A-Z0-9_]+)(=| is not set)", line.rstrip("\n"))
    if m and m.group(2).startswith("CONFIG_KSU"):
        want[m.group(2)] = line.rstrip("\n")
lines = []
for line in open(cfg, encoding="utf-8").read().splitlines():
    m = re.match(r"^(# )?(CONFIG_[A-Z0-9_]+)(=| is not set)", line)
    if m and m.group(2) in want:
        continue
    lines.append(line)
lines.extend(want.values())
with open(cfg, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(f"[config] imported {len(want)} CONFIG_KSU* symbols from {deff}")
PY

scripts/config --file "$CFG" \
  -e LTO_CLANG -d LTO_CLANG_FULL -e LTO_CLANG_THIN -e CFI_CLANG \
  -e VENDOR_COMMON_COMPILE -e VENDOR_SOC_SPRD_COMPILE \
  -m TOUCHSCREEN_VENDOR_V2 -m TOUCHSCREEN_LCD_NOTIFY \
  -e KSU -d KSU_SUSFS -e KSU_MANUAL_HOOK -d KSU_TRACEPOINT_HOOK \
  -d WERROR
while read -r symbol; do
    [[ -n "$symbol" ]] && scripts/config --file "$CFG" -d "${symbol#CONFIG_}"
done < <(grep -oE '^CONFIG_KSU_SUSFS[A-Z0-9_]*' "$CFG" || true)

# Keep the known build identity used by the previously tested device kernel.
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-twodays}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-twodays-Workstation}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Fri Oct 2 14:55:29 CST 2026}"
[[ -f "$OUT/.version" ]] || echo 2 > "$OUT/.version"

MAKE_ARGS=(
    "O=$OUT"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    "CROSS_COMPILE=$CROSS_COMPILE"
    LOCALVERSION=
    KCFLAGS="-Wno-error=enum-compare -Wno-error=compare-distinct-pointer-types -Wno-error=strict-prototypes"
)

echo "== Toolchain =="
clang --version | head -n 1
ld.lld --version | head -n 1
echo "== Kernel release =="
make "${MAKE_ARGS[@]}" kernelrelease

echo "== Configure =="
make "${MAKE_ARGS[@]}" olddefconfig

# Fail early if the requested core options were dropped by Kconfig.
grep -q '^CONFIG_KSU=y$' "$CFG" || { echo "CONFIG_KSU is not enabled after olddefconfig" >&2; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$CFG" || { echo "CONFIG_KSU_MANUAL_HOOK is not enabled after olddefconfig" >&2; exit 1; }
grep -q '^CONFIG_LTO_CLANG_THIN=y$' "$CFG" || { echo "ThinLTO is not enabled after olddefconfig" >&2; exit 1; }
grep -q '^CONFIG_CFI_CLANG=y$' "$CFG" || { echo "CFI is not enabled after olddefconfig" >&2; exit 1; }

echo "== Build Image + modules ($JOBS jobs) =="
make "${MAKE_ARGS[@]}" -j"$JOBS" Image modules

IMAGE="$OUT/arch/arm64/boot/Image"
[[ -s "$IMAGE" ]] || { echo "Kernel Image was not produced" >&2; exit 1; }
echo "Image: $(stat -c '%s bytes' "$IMAGE")"
echo "Modules: $(find "$OUT" -type f -name '*.ko' | wc -l)"
echo "Kernel release: $(make "${MAKE_ARGS[@]}" -s kernelrelease)"
