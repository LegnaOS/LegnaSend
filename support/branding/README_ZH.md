# LegnaSend 产品标志

依据下载站 `support/download-portal/index.php` 与 `assets/portal.css` 的实际 `brand-mark` 绘制：绿色 `#54B865`、深色 `#102C16`、三个圆角与一个较紧圆角、整体旋转 −12°。字母采用不依赖字体的几何 L。网站保持不变；这是对相同视觉标识的确定性原生绘制，不声称字体像素完全一致。

可检查的矢量源为 `legnasend-mark.svg`：

```sh
python3 support/scripts/generate_brand_icons.py
python3 support/scripts/generate_brand_icons.py --check
```

生成器使用 Pillow，保持现有文件名和平台元数据，生成140个二进制资源，以及矢量和两个 Android XML 文件。`generated-icons.json` 记录路径、尺寸、颜色模式与内容哈希。脚本、矢量、生成资源和清单应共同维护。

- iOS 图标使用不透明背景；Android 自适应前景保留遮罩安全余量。
- 托盘与通知单色图标采用透明 L 镂空。
- Windows 应用与安装器图标包含16至256像素的多个尺寸。
- Linux 现有打包配置沿用公共 PNG；macOS 成功、失败状态角标继续分别呈现。
- 不删除上游许可或法律归属。内部 `LocalSendLogo` 类名为兼容保留，显示内容已替换。网页与渐进式网页应用资源不在本原生批次改动范围。

旋转组件改用 Flutter 帧回调，不再永久定时唤醒。减少动态效果、动画关闭、路由隐藏、子树停止帧回调、应用后台时停止，恢复时从原角度继续。接收页保留在线及当前选项卡门控；关于和设置页面显示静态标志。

验证与预览位于 `docs/evidence/portal-brand-icons/`，真实 Flutter 明暗渲染位于 `app/test/widget/goldens/legnasend_portal_mark.png`。资源编译与组件测试不替代安装后各平台视觉验收。
