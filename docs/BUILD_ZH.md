# 构建 LegnaSend

Flutter 使用 `.fvmrc` 固定版本，通过 FVM 调用；Rust 使用 `rust-toolchain.toml`。

```sh
fvm install
cd app
fvm flutter pub get
fvm flutter build linux --release
# Windows：fvm flutter build windows --release
# Android：fvm flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64
```

GitHub Actions `legnasend_packages.yml` 提供 Windows x64／ARM64 便携包、Linux x64 目录包和 Android ARM64／x86_64 APK。Windows ARM64 使用 Flutter 3.47.4 与原生 VS 2026 runner，其余目标使用 3.41.9。

Windows 不签名。Android CI 使用固定 debug 密钥和 Release 编译供直接安装，商店发行签名单独配置。`ANDROID_KEY_STORE`、`ANDROID_KEY_PROPERTIES` 与 `ANDROID_SIGNING_KIND` 通过仓库 Secrets／变量管理，不把密钥写入 Git。每个产物带构建清单和 SHA-256。

Apple 构建与签名由本地处理，在 Xcode 填写自己的团队；iOS 账号覆盖写入被忽略的 `app/ios/Flutter/LegnaSigning.local.xcconfig`。归档符号由 `support/scripts/apple_symbols.py` 收集。

独立发布工作流核验构建、源代码一致性与摘要后发布 GitHub Release，不上传应用商店。个人签名材料和上架资料放在公开仓库之外。

## 测试

```sh
cd app
fvm flutter analyze
fvm flutter test
# 在 packages/core 中：
cargo test --features full
```
