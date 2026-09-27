# 离线图表构建

本独立 Node 工具生成由 Rust HTTP 服务嵌入的网页资源，不属于 Dart 工作区；运行应用时不需要包管理器或 CDN。

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
```

在本目录运行，使用 Node 22 或以上版本。`package-lock.json` 固定直接版本与传递依赖完整性哈希：Mermaid 12.0.0、Markmap 解析／视图 0.18.12、DOMPurify 3.4.15、esbuild 0.25.12。禁止依赖安装脚本；使用浏览器导出，应用包装器在 `src/`。

生成位置：

- `packages/core/assets/web/vendor/diagrams/`：内容哈希命名的包、法律声明、完整依赖许可证，以及字节数／SHA-256／版本／源码包／上游地址清单。
- `packages/core/assets/web/diagram-config.js`：本地包 URL。
- `packages/core/src/http/server/diagram_assets.rs`：编译期固定资源白名单，不把请求路径当成磁盘路径打开。

只淘汰上一份生成清单登记的旧文件，不手改压缩包。限定目录的 `.gitattributes` 保留第三方模板字符串及法律文本的原始空白；这些字节通过哈希校验，不通过重写空白“修复”。应用源码仍执行正常空白检查。更新后将锁文件、包装器、资源、清单与 Rust 路由一起提交；从仓库根运行 `node --test packages/core/tests/web/diagram_preview.test.cjs` 验证。

Mermaid 固定严格模式、站点限制和绿色主题；Markmap 转换 Markdown 后清理标签，不加载文档声明的插件资源。图表在不具备同源权限且 CSP 受限的框架中执行，原文、访问凭据和 LocalSend 协议不改变；错误局限在单图。当前接入已有完整文档 Markdown 阅读视图，大文档块级虚拟化继续单列。

依赖保留各自许可证，应用包装器不改写其许可。`LICENSES.txt` 逐项收录实际打包依赖的原法律文本，`manifest.json` 登记 npm 源码包和上游仓库。特别是 `elkjs` 0.9.3 保留 EPL-2.0，源码见[固定修订](https://github.com/kieler/elkjs/tree/a8304cf79fde75bc2ab1a89d28320f53f8637436)，构建说明关联 [Eclipse Layout Kernel 源码](https://github.com/eclipse-elk/elk)；打包压缩不替代这些声明和源码引用。
