# P720S11 / UMS9620 GitHub Actions

Workflow: `.github/workflows/p720s11-kernel.yml`

## Build target

- Device: ZTE P720S11 (ZTE 远航 41)
- SoC: Unisoc UMS9620 / qogirn6pro
- Kernel: Linux 5.4.302, ARM64
- Compiler: AOSP Android Clang `clang-r563880c`, pinned to commit `21b19c041de1f1df9b97fd9902ae5405c6cf8eb9`
- Base config: `stock_p720s11.config`, refreshed by `olddefconfig`
- Kernel options: Clang LTO + ThinLTO, CFI, ReSukiSU/BakaSU KernelSU with Manual Hook; SUSFS disabled
- External vendor modules: `kernel_modules/`, selected by `KO_MODULE_NAME`

## Run the workflow

After this branch is pushed, the workflow runs automatically for `ci/**` branches and `master`. For manual runs, use **Actions → P720S11 kernel build → Run workflow**.

The `build_bsp_modules` input accepts one or more space-separated `KO_MODULE_NAME` values. Leave it empty to build only the kernel and in-tree modules.

## Default artifacts

- `Image`: ARM64 kernel image
- `metadata/kernel.config`: final resolved kernel configuration
- `metadata/kernelrelease.txt`: kernel release string
- `metadata/clang-version.txt`: compiler version
- `metadata/source-commit.txt` and `metadata/submodules.txt`: build provenance
- `modules/`: built in-tree and selected BSP modules
- `SHA256SUMS`: checksums

## Optional stock-derived image packaging

Packaging `boot_stock.img` and `vendor_dlkm_stock.img` requires original device dump files. Do not put these personal device images in the public repository.

Create two repository Actions secrets:

- `DEVICE_DUMP_URL`: HTTPS URL for a `.tar.gz` archive
- `DEVICE_DUMP_SHA256`: SHA-256 hex digest of that exact archive (64 hexadecimal characters)

The archive must contain this layout:

```text
device_dump/
  boot_a.img
  vendor_boot.img
  vendor_dlkm.img
vendor_dlkm_extract/
  lib/modules/
    *.ko
    modules.load
    modules.dep
    ...
```

Run the workflow manually with `package_device_images=true`. The job verifies the archive checksum, checks required files, preserves the stock boot header parameters while replacing the kernel and ramdisk, and rebuilds EROFS vendor_dlkm from the device's module inventory.

## Safety and validation

- No successful runner build has yet been established; inspect the Actions run and logs before treating artifacts as validated.
- Image packaging is opt-in and requires the exact device's own dump.
- The output images are raw partition images, not a recovery-flashable ZIP.
- Before flashing, verify partition sizes and boot/vendor_dlkm compatibility against the exact firmware build. Keep the stock images available for recovery.
