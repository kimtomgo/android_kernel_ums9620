# P720S11 GitHub Actions build

The workflow is `.github/workflows/p720s11-kernel.yml`.

## What it builds

- Android Clang/LLVM `clang-r563880c`, fetched from an immutable AOSP prebuilts commit.
- Kernel Image and in-tree modules using `stock_p720s11.config`.
- ReSukiSU/KernelSU from the pinned Git submodule.
- Optional selected UNISOC BSP modules when `build_bsp_modules` is supplied in `workflow_dispatch`.
- Optional stock-derived `boot_stock.img` and `vendor_dlkm_stock.img` when the private device dump is supplied.

The build scripts no longer depend on either developer workstation path:
- `/home/twodays/AOSP/LineageOS-23/prebuilts/clang/host/linux-x86/clang-r563880c/bin`
- `/home/twodays/AOSP/LineageOS-23/out/host/linux-x86/bin`

They accept `CLANG_BIN` and `HOST_TOOLS_BIN`, respectively, and use normal `PATH` when those variables are unset.

## Optional image packaging secrets

Do not commit a phone dump to this public repository. To enable image packaging, create a private tar.gz archive and host it at a URL accessible to Actions. Configure these repository Actions secrets:

- `DEVICE_DUMP_URL`: private or expiring download URL for the archive.
- `DEVICE_DUMP_SHA256`: SHA-256 of that exact archive (64 hexadecimal characters).

The archive must contain these paths at its root (no leading `./`):

```text
device_dump/
  boot_a.img
  vendor_boot.img
  vendor_dlkm.img
vendor_dlkm_extract/
  lib/modules/
    *.ko
    modules.dep / modules.alias / modules.load (as present in the dump)
```

Run the workflow manually and enable `package_device_images`. The workflow verifies the archive SHA-256 before extraction.

**Important:** `BOOT_PARTITION_SIZE` is currently set to 67,108,864 bytes (64 MiB), matching the packaging script's existing P720S11 assumption. Confirm the actual boot partition size on the exact target phone before using the generated image. The workflow only creates artifacts; it never flashes a device.

## Optional BSP modules

In `workflow_dispatch`, set `build_bsp_modules` to space-separated `KO_MODULE_NAME` values. These are the module names declared in the relevant `kernel_modules/**/Kbuild` or Makefile. The BSP build deliberately uses `KBUILD_MODPOST_WARN=1` because some vendor modules reference symbols exported by other separately-built BSP modules; a successful compile is not proof that the module is safe to load. Review each module's unresolved symbols and load order before packaging or installing it.

## Artifacts

Every run uploads `p720s11-kernel-<commit>` for 14 days:

- `Image`
- `modules/**/*.ko`
- `metadata/kernel.config`
- `metadata/kernelrelease.txt`
- `metadata/clang-version.txt`
- `metadata/source-commit.txt`
- `metadata/submodules.txt`
- `SHA256SUMS`

When image packaging is enabled, it additionally includes `images/boot_stock.img` and `images/vendor_dlkm_stock.img`.

The generated files are raw images, not a recovery-flashable ZIP. Do not flash `vendor_dlkm_stock.img` or a boot image until the target phone's slot layout, partition names, sizes, AVB state, and source dump have been checked against the exact device.

## Local build

```bash
OUT=out_stock_lto2 CLANG_BIN=/path/to/clang-r563880c/bin ./build_stock_lto.sh

# Optional:
OUT=out_stock_lto2 CLANG_BIN=/path/to/clang-r563880c/bin \
  ./build_bsp_modules.sh <KO_MODULE_NAME> [...]
```

For local image packaging, install AOSP `mkbootimg`/`unpack_bootimg`, `erofs-utils`, `lz4`, and `cpio`, then provide the same device-specific input layout and set `DUMP`, `IMGDIR`, and `BOOT_PARTITION_SIZE`.
