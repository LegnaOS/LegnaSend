# LegnaSend

**Share files. Create spaces.**

A cross-platform file-sharing app by **Legna**. Send files to nearby devices, share folders as named workspaces, and let recipients browse from their browser.

[Download](https://x.legna.cn/ls) · [Release packages](https://github.com/LegnaOS/LegnaSend/releases) · [简体中文](support/readme/README_ZH.md) · [Issues](https://github.com/LegnaOS/LegnaSend/issues)

## What you can do

- **Send and receive** — manage transfer progress, queues and retries.
- **Share workspaces** — name shared folders and manage visibility, passwords and upload permissions separately.
- **Browse before downloading** — preview supported media, text and Markdown; search document content.
- **Download in batches** — select multiple files or download folders as ZIP archives in the browser.
- **See your networks** — identify local interfaces, subnets and VPN/proxy indicators.
- **Connect your tools** — use documented APIs with keys, permission scopes and rate limits.

Sharing requires a reachable host. Resume depends on both peers and the save destination; other peers retain whole-file transfer. Mobile background behavior and browser capabilities depend on the platform.

Workspace links have explicit Copy actions and custom paths. Authorized workspace uploads do not require repeated prompts. Mobile albums support batch selection; desktop media supports multiple files.

## Downloads and builds

Version **1.0.0**. Windows, macOS, Linux, Android and iOS source targets are included.

[GitHub Actions](https://github.com/LegnaOS/LegnaSend/actions/workflows/legnasend_packages.yml) builds Windows x64/ARM64, Linux x64, and Android ARM64/x86_64. Windows bundles are unsigned; Android uses Release compilation with a stable debug signing key for direct installation, not Google Play distribution. Apple packages are managed separately. See the [build guide](docs/BUILD.md) for artifact status and reproduction.

Windows packages launch through `LegnaSend.exe`.

## Documentation

- [Release notes](app/assets/CHANGELOG.md)
- [API integration](docs/INTEGRATION_API.md)

## License

[Apache-2.0](LICENSE). LegnaSend builds on LocalSend; original copyright and third-party notices are retained. [Attribution](docs/ATTRIBUTION.md).
