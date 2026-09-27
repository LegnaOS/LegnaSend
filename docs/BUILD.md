# Building LegnaSend

Use Flutter from `.fvmrc` through FVM, and Rust from `rust-toolchain.toml`.

```sh
fvm install
cd app
fvm flutter pub get
fvm flutter build linux --release
# On Windows: fvm flutter build windows --release
# For Android: fvm flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64
```

GitHub Actions `legnasend_packages.yml` builds Windows x64/ARM64 portable bundles, Linux x64 and Android ARM64/x86_64 APKs. Windows ARM64 uses the documented Flutter 3.47.4 exception and native VS 2026 runner. Other targets use 3.41.9.

Windows bundles are unsigned. Android CI uses a fixed debug key for direct installation with Release compilation; production-store signing is separate. Configure `ANDROID_KEY_STORE`, `ANDROID_KEY_PROPERTIES` and `ANDROID_SIGNING_KIND` as repository secrets/variables, never files in Git. Package manifests and SHA-256 hashes identify outputs.

Apple builds and signing are local. Set your own team in Xcode. iOS account overrides belong in the ignored `app/ios/Flutter/LegnaSigning.local.xcconfig`. Archive symbols are collected by `support/scripts/apple_symbols.py`.

The separate release workflow verifies successful jobs, source compatibility and checksums before publication; it does not upload to app stores. Keep personal signing material and submission metadata outside the public repository.

## Tests

```sh
cd app
fvm flutter analyze
fvm flutter test
# From packages/core:
cargo test --features full
```
