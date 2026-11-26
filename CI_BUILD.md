# GitHub Actions：ZTE P720S11 / UMS9620

工作流：`.github/workflows/ums9620-kernel.yml`

## 当前构建目标

- SoC / 平台：Unisoc UMS9620（qogirn6pro）
- 设备代号：P720S11（中兴远航 41）
- Kernel：Linux 5.4.302，ARM64
- 编译器：Android Clang `clang-r563880c`，固定到 AOSP prebuilts 仓库提交 `21b19c041de1f1df9b97fd9902ae5405c6cf8eb9`
- 配置基线：仓库中的 `stock_p720s11.config`，由 `olddefconfig` 按当前源码更新
- 内核选项：ThinLTO、CFI、KernelSU；SUSFS 关闭，使用仓库现有的 manual hook 配置
- BSP：可选编译 `kernel_modules/` 下声明了 `KO_MODULE_NAME` 的外置模块

## 如何运行

1. 将本分支合并到 `master` 后，打开 GitHub 仓库的 **Actions**。
2. 选择 **ZTE P720S11 / UMS9620 Kernel**。
3. 点击 **Run workflow**。
4. 首次建议保持 `build_bsp_modules=true`、`package_images=false`，先验证内核和 BSP 模块编译。
5. 构建完成后，在本次运行页面的 Artifacts 下载 `ZTE-P720S11-UMS9620-...`。

也可以在 `master` 上修改内核源码、配置或构建脚本时由 push 自动触发。

## 产物

基础构建上传：

- `kernel/Image`：未压缩 ARM64 Kernel Image
- `kernel/kernel.config`：本次实际使用的最终配置
- `modules/`：本次构建产生的内核模块（保留输出目录结构）
- `logs/`：内核 / BSP 构建日志、BSP 模块清单及状态
- `SHA256SUMS`：产物校验和

## 可选生成刷机镜像

生成 `boot_stock.img` 和 `vendor_dlkm_stock.img` 需要设备原厂镜像，不能仅凭内核源码还原。不要把个人设备 dump 上传到公开仓库。

在仓库 **Settings → Secrets and variables → Actions → New repository secret** 中添加：

- Name：`DEVICE_DUMP_URL`
- Value：一个 HTTPS 下载地址，指向包含以下三个原厂文件的 `.tar.gz`：
  - `boot_a.img`
  - `vendor_boot.img`
  - `vendor_dlkm.img`

压缩包可以把三个文件放在根目录，也可以放在子目录中。然后手动运行工作流并将 `package_images` 设为 `true`。工作流会在临时 Runner 中解包，调用 AOSP `mkbootimg/unpack_bootimg` 与 EROFS 工具生成镜像，最终将镜像和 SHA256 一并上传。

不要把带长期访问令牌的下载 URL 写进仓库文件或公开日志；应使用仅对 Actions 可见的 Secret。

## 重要边界

- 目前只提交了 CI 工作流和本地路径兼容修复；尚未有一次真实 GitHub Runner 成功构建，因此不能把编译或镜像打包标记为已验证。
- `package_images=false` 是默认值。没有原厂 dump 时，工作流只输出内核 Image、模块、配置和日志，不会伪造完整刷机包。
- 首次运行如果失败，应优先看 `build_kernel.log`；若 BSP 某些模块失败，工作流会保留已成功编译的模块并在日志中标记 partial。
- `boot_stock.img` / `vendor_dlkm_stock.img` 在真机刷入前仍需核对设备分区布局、原厂镜像头信息、模块依赖及实际启动兼容性。不要直接把未验证的镜像刷入日用设备。
