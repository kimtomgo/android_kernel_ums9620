# P720S11 kernel CI

The workflow is `.github/workflows/p720s11-kernel.yml`.

## Normal build

The workflow runs on pushes to `master` and `ci/**`, pull requests targeting
`master`, and manual dispatch. It:

1. Checks out the exact source revision and recursively initializes the recorded
   submodule commits.
2. Installs the Ubuntu 24.04 kernel build dependencies.
3. Downloads the pinned Android `clang-r563880c` prebuilt from AOSP Gitiles.
4. Seeds `out_stock_lto2/.config` from `stock_p720s11.config` when no output
   config exists, imports the KSU symbols from the P720S11 defconfig, and
   validates KSU Manual Hook, ThinLTO and CFI after `olddefconfig`.
5. Builds `Image` and in-tree modules, then uploads the Image, config,
   System.map, Module.symvers, modules and build manifest as an Actions artifact.

The scripts no longer depend on paths under `/home/twodays/AOSP`. Locally,
`CLANG_DIR` can point at any compatible Clang `bin` directory; Actions sets
it to the downloaded AOSP toolchain.

## Optional BSP modules

Use **Actions → P720S11 kernel CI → Run workflow**. Enable
`build_bsp_modules` and provide one or more exact `KO_MODULE_NAME` values in
`bsp_modules`, separated by spaces. The resulting `.ko` files are included
in the kernel artifact. The workflow deliberately does not guess which
camera/WCN/NPU modules should be built.

## Optional raw partition-image packaging

Packaging is disabled by default. To enable it, configure these repository
Actions secrets:

- `DEVICE_DUMP_URL`: a time-limited HTTPS download URL for a private
  `.tar.gz` archive. Prefer a short-lived signed URL; do not commit device
  dumps or credentials to this repository.
- `DEVICE_DUMP_SHA256`: the exact 64-character SHA-256 of that archive.

The archive must contain these paths at its root:

```text
device_dump/
├── boot_a.img
└── vendor_dlkm.img
```

The archive may also include `device_dump/vendor_boot.img` for your own
recordkeeping. The current packager only consumes `boot_a.img` and
`vendor_dlkm.img`.

Then manually dispatch the workflow with `package_images=true`. Set
`boot_partition_size` to the verified byte size of the *actual target
device's* boot partition. The current default of 67108864 bytes preserves the
assumption in the original local script; it is not a substitute for checking
the phone's partition table.

The package step uses the pinned AOSP `mkbootimg` tools and the system
`erofs-utils`. It reconstructs the boot image using the original boot
header parameters emitted by `unpack_bootimg --format=mkbootimg -0`, replacing
only the kernel and retaining the extracted stock ramdisk. It refuses to
truncate an oversized image. The vendor_dlkm image is rebuilt from the exact
device dump; it does not silently mix modules from a second ROM extraction.

**Important:** the output `boot_stock.img` and `vendor_dlkm_stock.img` are
raw partition images, not a recovery-flashable ZIP. They are not automatically
flashed, published as a Release, or considered safe for a different phone or
slot. Confirm the exact 7541N/P720S11 identity, slot, partition name, partition
size, AVB state and stock backups before flashing. A successful CI build does
not establish device compatibility.

## Local invocation

```bash
export CLANG_DIR=/path/to/clang-r563880c/bin
OUT=out_stock_lto2 JOBS=4 ./build_stock_lto.sh

# Optional, with exact module names:
OUT=out_stock_lto2 ./build_bsp_modules.sh module_name

# Optional raw-image packaging after preparing the device dump:
OUT=out_stock_lto2 DUMP=device_dump IMGDIR=out_images \
  HOST_TOOLS_DIR=/path/to/aosp-mkbootimg-tools \
  BOOT_PARTITION_SIZE=67108864 ./package_stock_lto.sh
```
