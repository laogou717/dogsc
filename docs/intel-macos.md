# Intel Mac（x86_64）支持说明

本分支在 Apple Silicon 主线之外，让 DogSC 能在 **Intel Mac** 上构建并完成录制。本文记录支持范围、修过的问题和排障方式，便于复核与继续维护。

验证环境：Intel `x86_64`、macOS 26.7.2（Tahoe 版本线）、Xcode 26.5 / Swift 6.3、ad-hoc 签名开发构建。

## 支持范围

| 能力 | Intel 状态 |
| --- | --- |
| 区域 / 窗口 / 全屏录制 | 可用（走 AVAssetWriter 采集后端） |
| 系统声音（Core Audio process tap） | 可用 |
| 麦克风 / 摄像头 | 可用 |
| 编辑器、导出、运镜 | 与主线一致 |
| 自动更新（Sparkle） | 保留，但开发构建不参与正式更新通道 |

编码默认 H.264 与 HEVC 都可用，差别见下文「HEVC 质量参数」。

## 与主线的差异

### 1. 构建链（`build-app.sh`、`Package.swift`、`scripts/setup-sparkle.sh`）

- `swift build` 统一加 `--disable-sandbox`：SwiftPM 的内部沙箱在受限环境（部分 CI、受管控终端）会直接拒绝执行，加该参数不影响产物。
- 架构检查接受 `x86_64`，不再只认 `arm64`。
- Sparkle 走 `Sparkle-local/` 本地二进制包：官方发布包在部分网络下下载失败时，SwiftPM 会卡住整个构建。`Sparkle-local/Sparkle.xcframework` 不入库，首次构建前执行一次

  ```bash
  ./scripts/setup-sparkle.sh
  ```

  脚本会下载官方 `Sparkle-for-Swift-Package-Manager.zip`（2.9.4），校验 SHA-256 后解压就位。缺失时 `build-app.sh` 会直接提示这条命令，而不是给出难以理解的构建错误。
- `Resources/DogSC.entitlements` 增加 `com.apple.security.cs.disable-library-validation`：开发构建是 ad-hoc 签名 + Hardened Runtime，没有这一项时 dyld 会拒绝加载 Sparkle.framework。

### 2. Swift 6.3 / Xcode 26 SDK 的编译修复

- `TimelineAudioGainProcessor`：`MTAudioProcessingTapCreate` 的出参类型变成了 `MTAudioProcessingTap?`，旧的 `Unmanaged<MTAudioProcessingTap>?` 不再匹配。
- `DogSCApp`：`.defaultLaunchBehavior` / `.restorationBehavior` 与新 SDK 中 SwiftUI 的同名修饰符产生歧义，改用兼容层的限定名。

### 3. 录制后端（`NativeScreenRecording`、`ScreenCaptureOutput`）

Intel + macOS 26 上有三处会直接让录制起不来：

1. **`SCRecordingOutput` 的启动回调不触发**
   macOS 15+ 的原生录制后端依赖 `recordingOutputDidStartRecording` 回调，Intel 上该回调从不触发，`waitForStart` 必然超时并报 `noFrames`。修复方式是在 `#if arch(x86_64)` 下强制走自研 `AVAssetWriter` 后端，直接消费 ScreenCaptureKit 的 sample buffer。

2. **HEVC 质量参数被拒**
   `AVAssetWriterInput` 在 Intel + macOS 26 上对 `hvc1` 拒绝 `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` 与 `kVTCompressionPropertyKey_Quality`，抛 `NSInvalidArgumentException: ... not supported for video codec type hvc1`；异常后录制会永久停在「正在等待首个屏幕帧」。单独隔离验证过：不带这两个参数的 HEVC 压缩字典可以正常 `startWriting` 并追加帧。因此 Intel 构建跳过这两项质量提示，Apple Silicon 行为不变——代价是 Intel 上 HEVC 码率更依赖 `AverageBitRate` 的软目标。

3. **帧状态枚举不能作为门槛**
   macOS 26 会把有效帧标成 `.screenUpdate`，个别情况标成 `.idle`。原代码要求 `status == .complete` 才计入首帧与写入，导致有帧却判定「没有帧」。现在以「buffer 内是否有可编码图像」为准，只有无图像的空样本才计作 idle。

### 4. 系统声音（`CoreAudioSystemAudioTap`）

兼容分支里这个文件是桩实现，所有初始化都 `throw ... .unavailable`，于是任何机器都会提示「系统声音捕获需要 macOS 14.2 或更高版本」。此处移植了主线基于 `AudioHardwareCreateProcessTap` 的真实实现（manifest / 聚合设备创建与拆除），`#available` 判断保留，用于决定何时可用。

### 5. 摄像头气泡（`CameraPreviewWindow`）

- 原来固定在屏幕右侧垂直居中，正好压住录制内容。改为默认停靠录制屏幕可视区**右下角**（内缩 24pt，越界时 clamp）。
- 位置按可视区**比例**持久化（`recording.camera-bubble-x/y`），拖动后记住，换分辨率或换显示器仍然合理。

### 6. 设置页崩溃（`AppSettingsComponents`、`AppSettingsWindowController`）

进入「设置 → 录制」会以 SIGILL 退出，栈顶是

```
-[NSView _updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:]
  → updateConstraintsForSubtreeIfNeeded → NSDisplayCycleFlush
```

原因是窗口高度由 120Hz 定时器逐帧驱动弹簧动画，同时 SwiftUI 页面又在实时测量自身高度；macOS 26 还会在 hosting view 调整尺寸期间报出**非有限高度**，该值一旦进入 frame，AppKit 在收集 baseline 时就会 trap。修复：测量值加 `isFinite` 守卫；窗口高度改为每次测量**一次性设置**（页面岛自身已经有高度动画）。

### 7. 录制条无法拖动（`MacOS13Compatibility`、`RecorderPanelInteraction`）

原来整条录制条拖不动，原因是兼容层的

```swift
public typealias WindowDragGesture = TapGesture
```

把 SwiftUI 真正的 `WindowDragGesture` 遮蔽了——模块内同名声明优先于 `import`，所以 `.gesture(WindowDragGesture())` 实际挂的是点击手势；而 macOS 15+ 又关闭了背景拖动（`isMovableByWindowBackground = false`），两条路一起失效。

修复：删除该别名（调用点已有 `if #available(macOS 15.0, *)` 保护），并给最右侧的六点把手加了一路原生 AppKit 拖动（`performDrag(with:)` + 张开手光标），不再依赖 SwiftUI 手势能否正确解析。

验证方式：`nm -a` 对比二进制符号，修复前 `7SwiftUI17WindowDragGestureV*` 零命中，修复后存在。

### 8. 崩溃自检（`CrashDiagnostics`）

有些机器 `~/Library/Logs/DiagnosticReports` 根本不会落盘（本次排查中就是如此），应用硬退出后毫无痕迹。新增：未捕获异常与致命信号（SIGABRT/SIGILL/SIGSEGV/SIGFPE/SIGBUS/SIGTRAP）用裸 `write` 追加到 `~/Library/Logs/DogSC/crash.log`，随后恢复 `SIG_DFL` 并重新抛出，不改变平台原有的退出处理。

调试钩子（`#if DEBUG` 内）：`DOGSC_OPEN_SETTINGS=<section>` 启动后自动打开指定设置页，`DOGSC_OPEN_SETTINGS_DELAY` 控制切页延迟，`DOGSC_SETTINGS_STRESS=1` 依次重放录制页控件——上面的设置页崩溃就是靠它们稳定复现的。

## 构建与打包

```bash
# 一次性：准备 Sparkle 二进制
./scripts/setup-sparkle.sh

# 开发构建（debug，约 10s 增量）
bash build-app.sh
open ".build/local/DogSC Dev.app"

# 发布构建 + 安装包
./scripts/make-dmg.sh          # 产出 dist/DogSC-Dev-<version>-<arch>.dmg
```

`dist/` 与 `Sparkle-local/Sparkle.xcframework` 都不入库。

## 已知限制

- **每次重新编译，系统授权可能失效。** ad-hoc 签名的 `cdhash` 每次构建都会变，TCC 授权是按 `cdhash` 记录的。需要重新授权时：

  ```bash
  tccutil reset ScreenCapture cn.laogou.dogsc.dev
  tccutil reset Accessibility cn.laogou.dogsc.dev
  tccutil reset Microphone cn.laogou.dogsc.dev
  ```

  想彻底避免，可以用固定的自签名证书（`DOGSC_SIGNING_IDENTITY`）签名，让授权绑定证书身份而不是哈希。

- **HEVC 在 Intel 上不能加质量提示参数**（见上），同码率下画面锐度可能略逊于 Apple Silicon。
- **开发标识与正式版隔离**：构建产物是 `DogSC Dev` / `cn.laogou.dogsc.dev`，偏好、权限、更新通道都与正式版独立，属预期行为。
- 未做 Apple 公证，首次打开需要手动放行。

## 排障清单

| 现象 | 处理 |
| --- | --- |
| 停在「准备好录制」引导页 | 按上面的 `tccutil reset` 三行重置后重新勾选 |
| 应用直接消失 | 看 `~/Library/Logs/DogSC/crash.log` |
| 一直「正在等待首个屏幕帧」 | 确认是当前构建（HEVC 参数问题已修）；改用 H.264 交叉验证 |
| 系统声音提示版本过低 | 确认已移植真实 tap 实现，而不是桩 |
| 录制条拖不动 | 拖最右侧六点（手形光标）；确认 `WindowDragGesture` 未被同名别名遮蔽 |
| Sparkle 下载卡住 | 用 `./scripts/setup-sparkle.sh` 手动放置后再构建 |
