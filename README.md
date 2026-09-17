<p align="center">
  <img src="Resources/AppIconMaster.png" width="112" alt="DogSC">
</p>

<h1 align="center">DogSC</h1>

<p align="center">macOS 原生录屏与轻量编辑工具。</p>

<p align="center">
  <a href="https://github.com/laogou717/dogsc/releases/latest"><strong>下载 DogSC</strong></a>
</p>

## 安装

打开 DMG，按照窗口中的指引将 DogSC 拖入 Applications。

## 功能

- 屏幕、窗口与区域录制
- 摄像头、麦克风与系统声音录制
- 不进入录制画面的悬浮备忘录，支持阅读模式、字号与背景不透明度调节，文稿自动保存在本机
- 鼠标轨迹、自动缩放与屏幕动画；新建屏幕 3D 可沿用上次设置的效果
- 光标样式、点击反馈、静止后隐藏与始终隐藏
- 时间线剪辑、变速与画面调整
- 画面柔化、贴图与自定义背景
- 硬件加速视频导出

## 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac

## 构建

需要 Apple Silicon Mac、Xcode 26 或更新版本及 Swift 6 工具链。首次构建需要联网下载已锁定版本的 Sparkle 依赖。

```bash
git clone https://github.com/laogou717/dogsc.git
cd dogsc
```

仅编译源码：

```bash
swift build -c release
```

这一步生成可执行文件，不会自动组装包含图标、字体、本地化资源和 Sparkle 的 `.app`。

生成可运行的开发版 App：先在 Xcode 的 Accounts → Manage Certificates 中创建自己的 Apple Development 证书，并用下面的命令查看其 SHA-1 指纹。证书及对应私钥保留在本机钥匙串中，无需项目作者的证书或 GitHub Secrets。

```bash
security find-identity -v -p codesigning
DOGSC_SIGNING_IDENTITY="你的 Apple Development 证书的 40 位 SHA-1 指纹" bash build-app.sh
open ".build/local/DogSC Dev.app"
```

脚本默认使用 `/Applications/Xcode.app`；如 Xcode 安装在其他位置，可在构建命令前设置 `DEVELOPER_DIR`，指向对应的 `Xcode.app/Contents/Developer`。仅编译源码时也需确保当前命令行工具指向该 Xcode。

脚本从当前源码进行 Release 构建、复制全部运行资源，并用同一证书签署主应用和 Sparkle。产物为 `DogSC Dev.app`（`cn.laogou.dogsc.dev`），使用独立于正式版的偏好与系统权限，不连接正式版自动更新源。首次运行仍需授予录屏、麦克风或摄像头权限。重新构建前请先保存并退出正在运行的 DogSC。

源码包含完整的录制与编辑实现；运行时展示的系统壁纸、用户录制和项目文件来自使用者本机，不随源码分发。正式 DMG 与签名更新源由 GitHub Actions 构建，需要维护者配置发布证书和 Sparkle 签名密钥；这些秘密不属于源码构建依赖。

## 许可

源代码采用 [MIT License](LICENSE)。
