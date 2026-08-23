import AppKit
import RecorderCore
import SwiftUI

// 设计 token（2026-08-15 视觉语言重做，雾白极简方向）：
// 界面本身是近乎单色的石墨分层，强调色只用米白；颜色全部留给内容
// （片段、波形、壁纸、同步曲线）。旧的亮紫 accent 已废弃。
let appBackground = Color(red: 0.078, green: 0.078, blue: 0.086)
let panelBackground = Color(red: 0.105, green: 0.105, blue: 0.114)
let dividerColor = Color.white.opacity(0.08)
/// 全编辑器唯一交互强调色：米白。滑块、开关、选中态、主动作按钮共用。
let editorAccent = Color(white: 0.92)
/// 内容色：缩放/运镜片段的板岩蓝（不是界面强调色，只是该轨道的身份色）。
let editorZoomClip = Color(red: 0.42, green: 0.52, blue: 0.70)
/// 内容色：主片段的温润琥珀，比旧版高饱和橙更安静。
let editorClipAmberTop = Color(red: 0.80, green: 0.56, blue: 0.24)
let editorClipAmberBottom = Color(red: 0.64, green: 0.43, blue: 0.14)
let setupBarBackground = Color(red: 0.075, green: 0.078, blue: 0.09)

func setupWindowWidth() -> CGFloat { 856 }
func recordingWindowWidth() -> CGFloat { 360 }

private struct RecorderHoverEffect: ViewModifier {
    @State private var isHovering = false

    let cornerRadius: CGFloat
    let enabled: Bool
    let highlightOpacity: Double

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        Color.white.opacity(
                            isHovering && enabled ? highlightOpacity : 0
                        )
                    )
            }
            // 不能用 scaleEffect 表达 hover：它只放大渲染、不放大命中区域，
            // 按钮“看起来变大了”但可点击区域仍是原尺寸——点击放大后的边缘
            // 无效，用户会误以为按钮失效。hover 反馈用高亮 + 亮度即可。
            .brightness(isHovering && enabled ? 0.045 : 0)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { hovering in
                isHovering = hovering && enabled
            }
    }
}

private extension View {
    func recorderHover(
        cornerRadius: CGFloat = 10,
        enabled: Bool = true,
        highlightOpacity: Double = 0.065
    ) -> some View {
        modifier(
            RecorderHoverEffect(
                cornerRadius: cornerRadius,
                enabled: enabled,
                highlightOpacity: highlightOpacity
            )
        )
    }
}

private struct LiveMicrophoneLevelView: View {
    @ObservedObject var levelState: LiveMicrophoneLevelState
    var width: CGFloat = 84
    var height: CGFloat = 5

    var body: some View {
        let level = levelState.value
        let visibleLevel = min(max(level, 0), 1)
        let displayedLevel = visibleLevel < 0.015 ? 0 : visibleLevel

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.22))
            Capsule()
                .fill(meterColor)
                .frame(width: width * CGFloat(displayedLevel))
                .opacity(displayedLevel > 0 ? 1 : 0)
        }
        .frame(width: width, height: height)
        .overlay {
            Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private var meterColor: Color {
        switch levelState.value {
        case 0.86...: .red
        case 0.68...: .orange
        default: .green
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                captureModeButton("显示器", icon: "display", source: .display, enabled: true)
                captureModeButton("窗口", icon: "macwindow", source: .window, enabled: true)
                captureModeButton("区域", icon: "viewfinder", source: .area, enabled: true)
                captureModeButton("设备", icon: "iphone", source: .device, enabled: true)
            }

            Divider()
                .frame(height: 32)
                .overlay(dividerColor)
                .padding(.horizontal, 6)

            HStack(spacing: 4) {
                cameraSelector
                microphoneSelector
                systemAudioSelector
            }
            .frame(width: 372)

            Divider()
                .frame(height: 32)
                .overlay(dividerColor)
                .padding(.horizontal, 6)

            HStack(spacing: 4) {
                RecorderPopupMenuButton(
                    width: 44,
                    items: settingsMenuItems,
                    accessibilityLabel: "录制质量与状态",
                    accessibilityIdentifier: RecorderAccessibilityID.setupSettings,
                    cornerRadius: 12,
                    highlightOpacity: 0.11
                ) {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .frame(width: 44, height: 44)
                    .foregroundStyle(
                        model.captureReadiness.displayCanShowTargetRate
                            ? Color.primary : Color.orange
                    )
                }
                .frame(width: 44, height: 44)
                .help(model.captureReadiness.frameRateWarningText ?? "录制质量与状态")

                RecorderPopupMenuButton(
                    width: 44,
                    items: projectMenuItems,
                    accessibilityLabel: "项目与恢复",
                    cornerRadius: 12,
                    highlightOpacity: 0.11
                ) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .frame(width: 44, height: 44)
                }
                .frame(width: 44, height: 44)
                .help("打开项目、恢复录制与设置保存位置")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help("退出DogSC")
                .accessibilityLabel("退出DogSC")
                .recorderHover(
                    cornerRadius: 12,
                    highlightOpacity: 0.11
                )

                Button(action: model.startRecording) {
                    HStack(spacing: 7) {
                        switch model.recorderStartAvailability {
                        case .ready:
                            Circle().fill(.white).frame(width: 8, height: 8)
                        case .needsCaptureTarget:
                            Circle()
                                .stroke(Color.secondary, lineWidth: 1.5)
                                .frame(width: 8, height: 8)
                        case .preparingCamera:
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 10, height: 10)
                        }
                        Text(startButtonTitle).fontWeight(.semibold)
                    }
                    .frame(width: 116, height: 36)
                    .background(startButtonBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .foregroundStyle(
                    model.canStartRecording
                        ? Color.white
                        : Color.secondary
                )
                .disabled(!model.canStartRecording)
                .help(startButtonHelp)
                .accessibilityLabel(startButtonHelp)
                .accessibilityIdentifier(RecorderAccessibilityID.setupStart)
                .recorderHover(
                    cornerRadius: 18,
                    enabled: model.canStartRecording,
                    highlightOpacity: 0.08
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(width: setupWindowWidth(), height: 64)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(setupBarBackground)
                WindowDragArea(purpose: .recorderPanel(phase: .setup))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.phaseSetup)
        .onAppear {
            model.refreshRecentProjects()
            model.refreshCaptureReadiness()
            model.refreshCaptureDevices()
        }
        .alert(
            "录制提示",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            if model.errorMessage?.contains("屏幕录制权限") == true {
                Button("打开系统设置", action: model.openScreenRecordingSettings)
            }
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var startButtonTitle: String {
        switch model.recorderStartAvailability {
        case .needsCaptureTarget: "开始录制"
        case .preparingCamera: "等待摄像头"
        case .ready: "开始录制"
        }
    }

    private var startButtonBackground: Color {
        model.canStartRecording ? captureSelectionAccent : Color.white.opacity(0.07)
    }

    private var startButtonHelp: String {
        switch model.recorderStartAvailability {
        case .needsCaptureTarget:
            "开始录制不可用：请先在左侧选择显示器、窗口、区域或设备"
        case .preparingCamera:
            "正在等待摄像头首批真实画面，以确认分辨率和帧率"
        case .ready:
            "开始录制"
        }
    }

    private var cameraSelector: some View {
        RecorderPopupMenuButton(
            width: cameraControlWidth,
            items: cameraMenuItems,
            accessibilityLabel: "选择摄像头"
        ) {
            compactControl(
                title: cameraControlTitle,
                icon: model.configuration.recordsCamera ? "video.fill" : "video.slash",
                width: cameraControlWidth,
                isActive: model.configuration.recordsCamera,
                indicatorColor: cameraIndicatorColor
            )
        }
        .frame(width: cameraControlWidth, height: 44)
        .help(cameraControlHelp)
    }

    private var microphoneSelector: some View {
        RecorderPopupMenuButton(
            width: microphoneControlWidth,
            items: microphoneMenuItems,
            accessibilityLabel: "选择麦克风"
        ) {
            compactControl(
                title: microphoneControlTitle,
                icon: model.configuration.recordsMicrophone ? "mic.fill" : "mic.slash",
                width: microphoneControlWidth,
                isActive: model.configuration.recordsMicrophone
            )
        }
        .frame(width: microphoneControlWidth, height: 44)
        .overlay(alignment: .bottom) {
            LiveMicrophoneLevelView(
                levelState: model.microphoneInputLevel,
                width: max(58, microphoneControlWidth - 26),
                height: 6
            )
            .padding(.bottom, 4)
            .opacity(model.configuration.recordsMicrophone ? 1 : 0)
            .allowsHitTesting(false)
        }
        .help(model.configuration.microphoneDeviceName ?? "选择麦克风")
    }

    @ViewBuilder
    private var systemAudioSelector: some View {
        if model.configuration.source == .device {
            RecorderPopupMenuButton(
                width: systemAudioControlWidth,
                items: deviceAudioMenuItems,
                accessibilityLabel: "选择设备声音"
            ) {
                compactControl(
                    title: systemAudioControlTitle,
                    icon: model.configuration.recordsSystemAudio
                        ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    width: systemAudioControlWidth,
                    isActive: model.configuration.recordsSystemAudio
                )
            }
            .frame(width: systemAudioControlWidth, height: 44)
            .help(model.configuration.recordsSystemAudio ? "录制设备声音" : "无设备声音")
        } else {
            RecorderPopupMenuButton(
                width: systemAudioControlWidth,
                items: systemAudioMenuItems,
                accessibilityLabel: "选择系统声音"
            ) {
                compactControl(
                    title: systemAudioControlTitle,
                    icon: model.configuration.recordsSystemAudio
                        ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    width: systemAudioControlWidth,
                    isActive: model.configuration.recordsSystemAudio
                )
            }
            .frame(width: systemAudioControlWidth, height: 44)
            .help(
                model.configuration.recordsSystemAudio
                    ? model.configuration.systemAudioScope.rawValue
                    : "无系统声音"
            )
        }
    }

    private func captureModeButton(
        _ title: String,
        icon: String,
        source: CaptureSource?,
        enabled: Bool
    ) -> some View {
        let selected = source == model.confirmedCaptureSource
        let isChoosing = !selected && source == model.selectedCaptureSource
        return ZStack {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(width: 44, height: 44)
            .background(
                selected
                    ? captureSelectionAccent.opacity(0.22)
                    : (isChoosing ? Color.white.opacity(0.055) : .clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected
                            ? captureSelectionAccent.opacity(0.95)
                            : (isChoosing ? captureSelectionAccent.opacity(0.45) : .clear),
                        lineWidth: 1
                    )
            )

            RecorderActionTrigger(
                action: {
                    if let source { model.selectCaptureSource(source) }
                },
                accessibilityLabel: selected
                    ? "\(title)，已选择"
                    : (isChoosing
                        ? "正在选择\(title)录制范围"
                        : "选择\(title)录制范围"),
                isEnabled: enabled
            )
            .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .foregroundStyle(enabled ? (selected ? Color.white : Color.secondary) : Color.secondary.opacity(0.45))
        .help(
            enabled
                ? (isChoosing ? "正在选择\(title)录制范围" : title)
                : "设备直录将在后续版本开放"
        )
    }

    private var settingsMenuItems: [RecorderMenuItem] {
        var items: [RecorderMenuItem] = [
            .info("录制节奏"),
            .info(model.configuration.source == .device
                ? "设备原生可变帧率（VFR）"
                : "可变帧率（VFR）"),
            .info("保留系统实际交付帧；导出时再选择 30/60 FPS"),
        ]

        if model.configuration.source == .device {
            items.append(.info("设备源保留 iPhone/iPad 提供的原始时间戳"))
        } else {
            if let warning = model.captureReadiness.frameRateWarningText {
                items.append(.info(warning))
            }
        }

        items.append(contentsOf: [
            .separator,
            .info("录制格式"),
        ])
        items.append(contentsOf: CaptureCodec.allCases.map { codec in
            .action(
                codec.recordingLabel,
                isOn: model.configuration.captureCodec == codec,
                isEnabled: model.configuration.source != .device
            ) {
                model.captureSetup.setCaptureCodec(codec)
            }
        })
        if model.configuration.captureCodec == .hevc {
            items.append(.info("HEVC：保留屏幕/窗口 Retina 原生像素，使用 Apple 硬件编码"))
            items.append(.info("导出 4K/1440p/1080p 时可转为 H.264"))
        } else if model.configuration.captureCodec == .proRes422 {
            items.append(.info("ProRes 422：录制即近乎无损，文件很大；导出时再压缩"))
        }

        items.append(contentsOf: [
            .separator,
            .info("状态"),
            .info("录屏权限：\(model.captureReadiness.permissionText)"),
            .info("摄像头：\(model.captureReadiness.cameraPermission.label)"),
            .info("麦克风：\(model.captureReadiness.microphonePermission.label)"),
            .info("显示器：\(model.captureReadiness.displayText)"),
            .info("磁盘：\(model.captureReadiness.diskText)"),
            .info("编码器：\(model.captureReadiness.encoderText)"),
        ])
        if let warning = model.captureReadiness.frameRateWarningText {
            items.append(.info(warning))
        }

        if !model.captureReadiness.hasScreenRecordingPermission {
            items.append(.action("打开录屏权限设置", handler: model.openScreenRecordingSettings))
        }
        return items
    }

    private var projectMenuItems: [RecorderMenuItem] {
        [
            .info("项目与恢复"),
            .action("打开项目…", handler: model.openProjectPicker),
            .action(
                "继续上次",
                isEnabled: !model.recentProjects.isEmpty,
                handler: model.openMostRecentProject
            ),
            .separator,
            .action(
                "恢复中断录制",
                isEnabled: !model.recoverableProjects.isEmpty,
                handler: model.recoverMostRecentProject
            ),
            .action("项目保存位置…", handler: model.chooseProjectsFolder),
        ]
    }

    private var cameraMenuItems: [RecorderMenuItem] {
        var items: [RecorderMenuItem] = [
            .action("关闭摄像头", isOn: !model.configuration.recordsCamera) {
                model.selectCamera(nil)
            },
            .separator,
        ]
        if model.availableCameras.isEmpty {
            items.append(.info("没有找到摄像头"))
        } else {
            items.append(contentsOf: model.availableCameras.map { device in
                .action(
                    device.name,
                    isOn: model.configuration.cameraDeviceID == device.id
                ) {
                    model.selectCamera(device)
                }
            })
        }
        if model.configuration.recordsCamera {
            items.append(contentsOf: [
                .separator,
                .info(model.cameraRuntimeFormat.map {
                    "当前：\($0.label)（帧率自动）"
                } ?? "当前格式将在预览启动后自动显示"),
                .info("摄像头分辨率（帧率由设备自动协商）"),
                .action(
                    "自动分辨率",
                    isOn: model.configuration.cameraCaptureResolution == nil
                ) {
                    model.selectCameraCaptureResolution(nil)
                },
            ])
            if model.availableCameraResolutions.isEmpty {
                items.append(.info("该摄像头没有公开可选格式"))
            } else {
                items.append(contentsOf: model.availableCameraResolutions.map { resolution in
                    .action(
                        resolution.label,
                        isOn: model.configuration.cameraCaptureResolution == resolution
                    ) {
                        model.selectCameraCaptureResolution(resolution)
                    }
                })
            }
            let effects = CaptureDeviceCatalog.enabledSystemVideoEffects()
            items.append(.separator)
            if effects.names.isEmpty {
                items.append(.info("系统视频效果：未开启"))
            } else {
                items.append(.info("系统视频效果：\(effects.names.joined(separator: "、"))"))
                items.append(.info("视频效果会额外占用 GPU / 神经网络算力，并可能限制帧率"))
            }
            items.append(.action("管理系统视频效果…") {
                CaptureDeviceCatalog.showSystemVideoEffects()
            })
        }
        items.append(contentsOf: [
            .separator,
            .action("刷新设备", handler: model.refreshCaptureDevices),
        ])
        return items
    }

    private var microphoneMenuItems: [RecorderMenuItem] {
        var items: [RecorderMenuItem] = [
            .action("关闭麦克风", isOn: !model.configuration.recordsMicrophone) {
                model.selectMicrophone(nil)
            },
            .separator,
        ]
        if model.availableMicrophones.isEmpty {
            items.append(.info("没有找到麦克风"))
        } else {
            items.append(contentsOf: model.availableMicrophones.map { device in
                .action(
                    device.name,
                    isOn: model.configuration.microphoneDeviceID == device.id
                ) {
                    model.selectMicrophone(device)
                }
            })
        }
        items.append(contentsOf: [
            .separator,
            .action("刷新设备", handler: model.refreshCaptureDevices),
        ])
        return items
    }

    private var deviceAudioMenuItems: [RecorderMenuItem] {
        [
            .action("不录设备声音", isOn: !model.configuration.recordsSystemAudio) {
                model.setDefaultSystemAudioRecordingEnabled(false)
            },
            .action("录制设备声音", isOn: model.configuration.recordsSystemAudio) {
                model.setDefaultSystemAudioRecordingEnabled(true)
            },
        ]
    }

    private var systemAudioMenuItems: [RecorderMenuItem] {
        var items: [RecorderMenuItem] = [
            .action("不录系统声音", isOn: !model.configuration.recordsSystemAudio) {
                model.setDefaultSystemAudioRecordingEnabled(false)
            },
            .separator,
        ]
        items.append(contentsOf: SystemAudioScope.allCases.map { scope in
            .action(
                scope.rawValue,
                isOn: model.configuration.recordsSystemAudio
                    && model.configuration.systemAudioScope == scope,
                isEnabled: scope != .selectedApplication
                    || model.configuration.selectedApplicationBundleIdentifier != nil
            ) {
                model.setDefaultSystemAudioRecordingEnabled(true, scope: scope)
            }
        })
        return items
    }

    private func compactControl(
        title: String,
        icon: String,
        width: CGFloat,
        isActive: Bool,
        indicatorColor: Color? = nil
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 13)
                .fixedSize()
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.primary.opacity(0.84) : Color.secondary)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(indicatorColor ?? (isActive ? Color.green : Color.secondary))
                        .frame(width: 4, height: 4)
                        .overlay {
                            Circle()
                                .stroke(setupBarBackground, lineWidth: 0.75)
                        }
                        .offset(x: 1.5, y: 1.5)
                }
                .frame(width: 14)
                .fixedSize()
            Color.clear
                .frame(width: 7)
                .fixedSize()
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: max(width - 58, 0), alignment: .leading)
            Color.clear
                .frame(width: 6)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 9)
                .fixedSize()
            Color.clear
                .frame(width: 9)
                .fixedSize()
        }
        .frame(width: width, height: 44)
        .clipped()
    }

    private var compactSystemAudioTitle: String {
        guard model.configuration.recordsSystemAudio else { return "无系统声音" }
        switch model.configuration.systemAudioScope {
        case .all:
            return "系统声音"
        case .selectedApplication:
            return "窗口声音"
        }
    }

    private var cameraControlTitle: String {
        switch model.cameraReadiness {
        case .disabled:
            return "无摄像头"
        case .preparing:
            return "正在检测…"
        case let .ready(runtime):
            return "\(runtime.resolution.resolutionLabel) \(Int(runtime.framesPerSecond.rounded()))帧"
        }
    }

    private var cameraIndicatorColor: Color {
        switch model.cameraReadiness {
        case .disabled: .secondary
        case .preparing: .orange
        case .ready:
            CaptureDeviceCatalog.enabledSystemVideoEffects().names.isEmpty ? .green : .orange
        }
    }

    private var cameraControlHelp: String {
        let deviceName = model.configuration.cameraDeviceName ?? "摄像头"
        switch model.cameraReadiness {
        case .disabled:
            return "选择摄像头"
        case .preparing:
            return "\(deviceName)：正在检测真实分辨率和帧率"
        case let .ready(runtime):
            let effects = CaptureDeviceCatalog.enabledSystemVideoEffects().names
            if effects.isEmpty {
                return "\(deviceName)：\(runtime.label)"
            }
            return "\(deviceName)：\(runtime.label)；系统效果已开启："
                + effects.joined(separator: "、")
        }
    }

    private var microphoneControlTitle: String {
        guard model.configuration.recordsMicrophone else { return "无麦克风" }
        return conciseDeviceName(
            model.configuration.microphoneDeviceName ?? "麦克风",
            removing: [" microphone", " mic", "麦克风", "话筒"]
        )
    }

    private var systemAudioControlTitle: String {
        if model.configuration.source == .device {
            return model.configuration.recordsSystemAudio ? "设备声音" : "无设备声音"
        }
        return compactSystemAudioTitle
    }

    private var cameraControlWidth: CGFloat {
        sourceControlWidth(for: cameraControlTitle, minimum: 104, maximum: 154)
    }

    private var microphoneControlWidth: CGFloat {
        sourceControlWidth(for: microphoneControlTitle, minimum: 96, maximum: 104)
    }

    private var systemAudioControlWidth: CGFloat {
        sourceControlWidth(for: systemAudioControlTitle, minimum: 104, maximum: 110)
    }

    private func sourceControlWidth(
        for title: String,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth = ceil(
            (title as NSString).size(withAttributes: [.font: font]).width
        )
        return min(max(textWidth + 58, minimum), maximum)
    }

    private func conciseDeviceName(
        _ name: String,
        removing redundantSuffixes: [String]
    ) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in redundantSuffixes {
            guard result.lowercased().hasSuffix(suffix.lowercased()) else { continue }
            result.removeLast(suffix.count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return result.isEmpty ? name : result
    }
}

struct RecordingBar: View {
    @ObservedObject var model: AppModel
    @State private var pendingAction: RecordingBarAction?

    var body: some View {
        HStack(spacing: 8) {
            recordingStatus

            Spacer(minLength: 4)

            recordingActions
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.horizontal, 12)
        .frame(width: recordingWindowWidth(), height: 46)
        .background {
            ZStack {
                Capsule().fill(Color(red: 0.055, green: 0.058, blue: 0.067))
                WindowDragArea(purpose: .recorderPanel(phase: .recording))
                    .clipShape(Capsule())
            }
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.phaseRecording)
        .confirmationDialog(
            pendingAction == .restart ? "停止当前录制并重新开始？" : "将这次录制移到废纸篓？",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if pendingAction == .restart {
                Button("重新录制", role: .destructive) {
                    pendingAction = nil
                    model.restartCurrentRecording()
                }
            } else {
                Button("移到废纸篓", role: .destructive) {
                    pendingAction = nil
                    model.discardCurrentRecording()
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        }
        .alert(
            "无法更新录制画面",
            isPresented: Binding(
                get: { model.errorMessage?.hasPrefix("无法更新录制画面") == true },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecordingPaused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .shadow(
                    color: (model.isRecordingPaused ? Color.orange : Color.red).opacity(0.75),
                    radius: 4
                )

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .frame(width: 54, alignment: .leading)
            }

            recordingRateLabel
                .font(.caption2.weight(.medium))
                .frame(width: 48, alignment: .leading)

            if model.configuration.recordsMicrophone {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    LiveMicrophoneLevelView(
                        levelState: model.microphoneInputLevel,
                        width: 48,
                        height: 4
                    )
                }
                .help("麦克风实时音量")
            }
        }
        .lineLimit(1)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var recordingRateLabel: some View {
        if let measurement = model.recorder.liveMeasurement {
            if model.isRecordingPaused {
                Text("已暂停").foregroundStyle(.secondary)
            } else if measurement.isMostlyIdle {
                // 画面静止：SCK 只交付 idle 状态帧（不计入写入），
                // 低 fps 是预期行为而不是性能问题。
                Text("画面静止")
                    .foregroundStyle(.secondary)
                    .help(
                        String(
                            format: "画面静止：SCK 交付 %.0f fps（含静止帧）",
                            measurement.sckDeliveryFramesPerSecond
                        )
                    )
            } else {
                Text(String(format: "%.0f fps", measurement.actualFramesPerSecond))
                    .foregroundStyle(
                        measurement.deliveryRatio >= 0.92 ? Color.secondary : Color.orange
                    )
                    .help(
                        String(
                            format: "写入 %.0f fps · SCK 交付 %.0f fps"
                                + (measurement.writerDroppedFrames > 0
                                    ? " · 编码丢弃 %d 帧" : ""),
                            measurement.actualFramesPerSecond,
                            measurement.sckDeliveryFramesPerSecond,
                            measurement.writerDroppedFrames
                        )
                    )
            }
        } else {
            Text(
                model.isRecordingPaused
                    ? "已暂停"
                    : (model.configuration.source == .device
                        ? "设备原生"
                        : "VFR")
            )
            .foregroundStyle(.secondary)
        }
    }

    private var recordingActions: some View {
        HStack(spacing: 5) {
            recordingActionButton(
                icon: model.isRecordingPaused ? "play.fill" : "pause.fill",
                accessibilityLabel: model.isRecordingPaused ? "继续录制" : "暂停录制",
                accessibilityIdentifier: RecorderAccessibilityID.recordingPauseResume,
                isEnabled: !model.isPauseTransitioning,
                action: model.toggleRecordingPause
            )

            recordingActionButton(
                icon: "stop.fill",
                accessibilityLabel: "结束录制",
                accessibilityIdentifier: RecorderAccessibilityID.recordingStop,
                emphasized: true,
                action: model.stopRecording
            )

            RecorderPopupMenuButton(
                width: 34,
                items: recordingMenuItems,
                accessibilityLabel: "录制画面与更多操作",
                accessibilityIdentifier: RecorderAccessibilityID.recordingMore,
                height: 32,
                cornerRadius: 10,
                highlightOpacity: 0.1
            ) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 34, height: 32)
                    .foregroundStyle(.primary)
            }
            .frame(width: 34, height: 32)
            .help("录制画面与更多操作")
        }
    }

    private func recordingActionButton(
        icon: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        isEnabled: Bool = true,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ZStack {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: 28)
                .background(
                    emphasized ? Color.white : Color.white.opacity(0.08),
                    in: Circle()
                )
                .foregroundStyle(emphasized ? Color.black : Color.primary)

            RecorderActionTrigger(
                action: action,
                accessibilityLabel: accessibilityLabel,
                isEnabled: isEnabled,
                accessibilityIdentifier: accessibilityIdentifier,
                cornerRadius: 10,
                highlightOpacity: 0.08
            )
            .frame(width: 32, height: 32)
        }
        .frame(width: 32, height: 32)
        .opacity(isEnabled ? 1 : 0.45)
        .help(accessibilityLabel)
    }

    private var recordingMenuItems: [RecorderMenuItem] {
        let canHideDesktopElements = model.configuration.source != .window
            && model.configuration.source != .device

        let items: [RecorderMenuItem] = [
            .info("录制画面"),
            .action(
                "隐藏桌面文件",
                isOn: model.configuration.hidesDesktopFiles,
                isEnabled: canHideDesktopElements
            ) {
                model.setHidesDesktopFiles(!model.configuration.hidesDesktopFiles)
            },
            .action(
                "隐藏 Dock",
                isOn: model.configuration.hidesDock,
                isEnabled: canHideDesktopElements
            ) {
                model.setHidesDock(!model.configuration.hidesDock)
            },
            .info(recordingMenuScopeHint),
            .separator,
            .action("重新录制…", isEnabled: !model.isPauseTransitioning) {
                pendingAction = .restart
            },
            .action("丢弃这次录制…", isEnabled: !model.isPauseTransitioning) {
                pendingAction = .discard
            },
        ]
        return items
    }

    private var recordingMenuScopeHint: String {
        switch model.configuration.source {
        case .window:
            "单窗口录制不会包含桌面和 Dock"
        case .device:
            "设备录制不会包含 Mac 桌面和 Dock"
        default:
            "只影响录制画面，不修改系统设置"
        }
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(Int(model.elapsedRecordingTime(at: date)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private enum RecordingBarAction {
    case restart
    case discard
}

enum InspectorTab: String, CaseIterable, Identifiable {
    // 画布与屏幕曾分为两页，但两者写的是同一个 CanvasStyle：背景/边距/
    // 屏幕位置/圆角描边都是"美化画面"这一项任务。合并为一个"画面"页，
    // 页签数量与"这个参数到底在哪页"的猜测同步减少。
    case frame = "画面"
    case zoom = "运镜"
    case cursor = "光标"
    case camera = "摄像头"
    case audio = "声音"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .frame: return "photo.on.rectangle.angled"
        case .zoom: return "viewfinder"
        case .cursor: return "cursorarrow.motionlines"
        case .camera: return "video.fill"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

enum BackgroundPanelTab: String, CaseIterable, Identifiable {
    case wallpaper = "壁纸"
    case gradient = "渐变"
    case color = "颜色"
    case image = "图片"

    var id: String { rawValue }
}

enum CropEdge {
    case left
    case right
    case top
    case bottom
}

enum CropHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var accessibilityName: String {
        switch self {
        case .topLeft: return "左上裁切点"
        case .top: return "上边裁切点"
        case .topRight: return "右上裁切点"
        case .right: return "右边裁切点"
        case .bottomRight: return "右下裁切点"
        case .bottom: return "下边裁切点"
        case .bottomLeft: return "左下裁切点"
        case .left: return "左边裁切点"
        }
    }
}

enum ZoomResizeEdge {
    case leading
    case trailing
}
