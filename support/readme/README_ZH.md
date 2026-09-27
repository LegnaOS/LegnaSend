# LegnaSend

**传文件，也分享空间。**

由 **Legna** 开发的跨平台文件共享工具。向附近设备发送文件，把常用文件夹变成工作区，让接收端通过浏览器浏览和下载。

[下载](https://x.legna.cn/ls) · [版本安装包](https://github.com/LegnaOS/LegnaSend/releases) · [English](../../README.md) · [问题反馈](https://github.com/LegnaOS/LegnaSend/issues)

## 核心功能

- **发送与接收**：查看进度，管理队列，失败后重试。
- **文件夹工作区**：独立命名，分别控制可见性、访问密码和上传权限。
- **下载前先预览**：浏览受支持的图片、音视频、文本与 Markdown，搜索文档正文。
- **批量下载**：网页支持多文件选择，文件夹可按 ZIP 下载。
- **网络标记**：展示网卡、网段及 VPN／代理状态，方便识别共享地址。
- **开放接口**：内置 API 文档，配置密钥、权限和请求限额。

共享需要主机网络可达；续传依赖双方及保存目标支持，其他对端保留整文件传输。移动端后台行为与网页能力受系统、浏览器影响。

工作区支持自定义路径、目录重新授权及复制／打开链接，IPv4 优先、其他地址折叠，允许上传后不再逐次确认。手机相册支持批量选择，桌面媒体支持多选。

## 下载与构建

当前版本 **1.0.0**，源码包含 Windows、macOS、Linux、Android 和 iOS 目标。

[GitHub Actions](https://github.com/LegnaOS/LegnaSend/actions/workflows/legnasend_packages.yml) 构建 Windows x64／ARM64、Linux x64，以及 Android ARM64／x86_64。Windows 包不签名；Android 使用 Release 编译和固定 debug 密钥签名，供直接安装，不用于 Google Play 正式分发。Apple 包独立处理。产物状态与复现方法见[构建说明](../../docs/BUILD_ZH.md)。

Windows 包使用 `LegnaSend.exe` 启动。 原生应用与共享网页统一使用绿色 LegnaSend 标志。 安装包修订使用独立发布标签，保留此前版本的下载文件。

## 文档

- [版本记录](../../app/assets/CHANGELOG_ZH.md)
- [API 接入](../../docs/INTEGRATION_API_ZH.md)

## 许可

采用 [Apache-2.0](../../LICENSE) 许可。LegnaSend 基于 LocalSend 开发，原始版权与第三方声明独立保留。详见[来源说明](../../docs/ATTRIBUTION_ZH.md)。
