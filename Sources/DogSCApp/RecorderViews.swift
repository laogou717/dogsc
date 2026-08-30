import AppKit
import RecorderCore
import SwiftUI

// 全局视觉基线收口到同一套暖石墨硬件语言。不用蓝紫做界面强调，
// 颜色优先表达录制、警告与时间线内容身份。
let appBackground = EditorTheme.backgroundDeep
let panelBackground = EditorTheme.panelSurface
let dividerColor = EditorTheme.hairline
/// 全编辑器唯一交互强调色：米白。滑块、开关、选中态、主动作按钮共用。
let editorAccent = EditorTheme.platinumAccent
/// 内容色：缩放/运镜片段的板岩蓝（不是界面强调色，只是该轨道的身份色）。
let editorZoomClip = Color(red: 0.58, green: 0.48, blue: 0.34)
let editorCameraSyncClip = Color(red: 0.34, green: 0.56, blue: 0.47)
let editorOverlayClip = Color(red: 0.58, green: 0.37, blue: 0.31)
let editorProgressClip = Color(red: 0.34, green: 0.52, blue: 0.39)
/// 内容色：主片段的经典暖琥珀橙（Orange + White 标志性主片段风格）。
let editorClipAmberTop = Color(red: 0.82, green: 0.56, blue: 0.22)
let editorClipAmberBottom = Color(red: 0.65, green: 0.42, blue: 0.14)
let setupBarBackground = EditorTheme.recorderSurface

func setupWindowWidth() -> CGFloat { 856 }
func recordingWindowWidth(recordsMicrophone: Bool) -> CGFloat {
    recordsMicrophone ? 344 : 270
}

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
            .brightness(isHovering && enabled ? 0.05 : 0)
            .scaleEffect(isHovering && enabled ? 1.018 : 1)
            .animation(SpringMotion.interactive, value: isHovering)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isHovering = hovering && enabled
                }
            }
    }
}

/// 悬浮录制条保留现有 hover 层，按下反馈只负责让实体按钮短促下沉。
/// 这避免主录制与退出按钮使用 plain style 后，点击时看起来完全静止。
private struct RecorderPressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.965 : 1)
            .brightness(configuration.isPressed && isEnabled ? -0.035 : 0)
            .animation(SpringMotion.snappy, value: configuration.isPressed)
    }
}

private extension View {
    func recorderHover(
        cornerRadius: CGFloat = 10,
        enabled: Bool = true,
        highlightOpacity: Double = 0.075
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
                .fill(Color.black.opacity(0.35))
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.2, green: 0.82, blue: 0.45),
                            meterColor
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width * CGFloat(displayedLevel))
                .opacity(displayedLevel > 0 ? 1 : 0)
        }
        .frame(width: width, height: height)
        .overlay {
            Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .animation(SpringMotion.interactive, value: level)
    }

    private var meterColor: Color {
        switch levelState.value {
        case 0.86...: Color(red: 1.0, green: 0.28, blue: 0.28)
        case 0.68...: Color(red: 1.0, green: 0.65, blue: 0.15)
        default: Color(red: 0.25, green: 0.85, blue: 0.45)
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // 1. 录制对象是一个单选任务，用共享底座表达为一组，
            // 避免四个散落按钮和设备状态混成同一层。
            HStack(spacing: 2) {
                captureModeButton("显示器", icon: "display", source: .display)
                captureModeButton("窗口", icon: "macwindow", source: .window)
                captureModeButton("区域", icon: "viewfinder", source: .area)
                captureModeButton("设备", icon: "iphone", source: .device)
            }
            .padding(3)
            .background(controlDeck(cornerRadius: 13))
            .padding(.leading, 7)

            // 极细晶体微光垂线
            crystalDivider

            // 2. 多媒体输入源底座
            HStack(spacing: 2) {
                cameraSelector
                microphoneSelector
                systemAudioSelector
            }
            .frame(width: 372)
            .background(controlDeck(cornerRadius: 13))

            // 极细晶体微光垂线
            crystalDivider

            // 3. 参数、抽屉、退出与 Hero 录制主按键
            HStack(spacing: 4) {
                RecorderPopupMenuButton(
                    width: 38,
                    items: recordingFormatMenuItems,
                    accessibilityLabel: "录制格式，当前\(recordingFormatSummary)",
                    accessibilityIdentifier: RecorderAccessibilityID.setupSettings,
                    cornerRadius: 9,
                    highlightOpacity: 0.12
                ) {
                    HStack(spacing: 2) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 38, height: 38)
                    .foregroundStyle(
                        model.captureReadiness.displayCanShowTargetRate
                            ? Color.primary.opacity(0.9) : Color.orange
                    )
                }
                .frame(width: 38, height: 38)
                .help(
                    model.captureReadiness.frameRateWarningText
                        ?? "录制格式：\(recordingFormatSummary)"
                )

                RecorderPopupMenuButton(
                    width: 38,
                    items: projectMenuItems,
                    accessibilityLabel: "项目与恢复",
                    cornerRadius: 9,
                    highlightOpacity: 0.12
                ) {
                    HStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 38, height: 38)
                    .foregroundStyle(Color.primary.opacity(0.85))
                }
                .frame(width: 38, height: 38)
                .help("打开项目、恢复录制与设置保存位置")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(RecorderPressButtonStyle())
                .help("退出\(AppIdentity.displayName)")
                .accessibilityLabel("退出\(AppIdentity.displayName)")
                .recorderHover(
                    cornerRadius: 9,
                    highlightOpacity: 0.12
                )

                heroStartButton
            }
            .padding(.trailing, 6)
        }
        .padding(.horizontal, 4)
        .frame(width: setupWindowWidth(), height: 64)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [EditorTheme.panelRaised, setupBarBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [EditorTheme.topHighlight, Color.white.opacity(0.035)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
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
            AppIdentity.displayName,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            if model.errorMessage?.hasPrefix("保存目录不可用") == true {
                Button("重新选择文件夹…") {
                    model.errorMessage = nil
                    model.chooseProjectsFolder()
                }
                Button("使用默认位置") {
                    UserDefaults.standard.removeObject(forKey: ProjectStore.projectsFolderDefaultsKey)
                    model.refreshRecentProjects()
                    model.errorMessage = nil
                }
            } else if model.errorMessage?.hasPrefix("没有摄像头采集权限") == true {
                Button("打开系统设置") {
                    model.errorMessage = nil
                    model.openCameraPrivacySettings()
                }
                Button("暂不使用摄像头", role: .cancel) {
                    model.selectCamera(nil)
                    model.errorMessage = nil
                }
            } else if model.errorMessage?.hasPrefix("没有麦克风权限") == true {
                Button("打开系统设置") {
                    model.errorMessage = nil
                    model.openMicrophonePrivacySettings()
                }
                Button("暂不使用麦克风", role: .cancel) {
                    model.selectMicrophone(nil)
                    model.errorMessage = nil
                }
            } else {
                Button("知道了", role: .cancel) { model.errorMessage = nil }
            }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private func controlDeck(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.black.opacity(0.34), Color.black.opacity(0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.black.opacity(0.50), Color.white.opacity(0.065)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private var crystalDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.02),
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1, height: 22)
            .padding(.horizontal, 8)
    }

    private var startButtonTitle: String {
        switch model.recorderStartAvailability {
        case .needsCaptureTarget: "开始录制"
        case .preparingCamera: "等待摄像头"
        case .ready: "开始录制"
        }
    }

    private var heroStartButton: some View {
        Button(action: model.startRecording) {
            HStack(spacing: 7) {
                switch model.recorderStartAvailability {
                case .ready:
                    ZStack {
                        Circle()
                            .fill(EditorTheme.recording)
                            .frame(width: 8, height: 8)
                            .shadow(color: EditorTheme.recording.opacity(0.82), radius: 4)
                    }
                case .needsCaptureTarget:
                    Circle()
                        .stroke(Color.secondary, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                case .preparingCamera:
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                }
                Text(startButtonTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(width: 112, height: 40)
            .background(
                model.canStartRecording
                    ? LinearGradient(
                        colors: [Color(red: 1.0, green: 0.99, blue: 0.96), EditorTheme.platinumAccent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    : LinearGradient(
                        colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        model.canStartRecording
                            ? LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [Color.white.opacity(0.1), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                        lineWidth: 0.75
                    )
            )
            .overlay {
                if model.canStartRecording {
                    RecorderReadyHalo()
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: model.canStartRecording ? Color.black.opacity(0.38) : Color.clear,
                radius: 6,
                y: 3
            )
        }
        .buttonStyle(RecorderPressButtonStyle())
        .foregroundStyle(
            model.canStartRecording
                ? Color.black.opacity(0.9)
                : Color.secondary
        )
        .disabled(!model.canStartRecording)
        .scaleEffect(model.canStartRecording ? 1.0 : 0.98)
        .animation(SpringMotion.interactive, value: model.canStartRecording)
        .help(startButtonHelp)
        .accessibilityLabel(startButtonHelp)
        .accessibilityIdentifier(RecorderAccessibilityID.setupStart)
        .recorderHover(
            cornerRadius: 13,
            enabled: model.canStartRecording,
            highlightOpacity: 0.08
        )
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
        source: CaptureSource
    ) -> some View {
        let selected = source == model.confirmedCaptureSource
        let isChoosing = !selected && source == model.selectedCaptureSource
        return ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.99, blue: 0.96), EditorTheme.platinumAccent],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white, Color.white.opacity(0.28)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(color: Color.black.opacity(0.38), radius: 4, y: 2)
            } else if isChoosing {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.orange.opacity(0.4), lineWidth: 0.75)
                    )
            }

            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Text(title)
                    .font(.caption2.weight(selected ? .semibold : .medium))
            }
            .accessibilityHidden(true)
            .foregroundStyle(
                selected
                    ? Color.black.opacity(0.86)
                    : (isChoosing ? Color.orange : Color.secondary)
            )

            RecorderActionTrigger(
                action: {
                    withAnimation(SpringMotion.interactive) {
                        model.selectCaptureSource(source)
                    }
                },
                accessibilityLabel: selected
                    ? "\(title)，已选择"
                    : (isChoosing
                        ? "正在选择\(title)录制范围"
                        : "选择\(title)录制范围"),
                accessibilityIdentifier: RecorderCaptureSourceAccessibilityID.value(
                    for: source
                )
            )
            .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .scaleEffect(selected ? 1.018 : 1.0)
        .animation(SpringMotion.interactive, value: selected)
        .animation(SpringMotion.interactive, value: isChoosing)
        .help(isChoosing ? "正在选择\(title)录制范围" : title)
    }

    private var recordingFormatMenuItems: [RecorderMenuItem] {
        if model.configuration.source == .device {
            return [.info("设备录制沿用 iPhone/iPad 原始格式与时间戳")]
        }

        var items: [RecorderMenuItem] = CaptureCodec.allCases.map { codec in
            .action(
                codec.recordingLabel,
                isOn: model.configuration.captureCodec == codec
            ) {
                model.captureSetup.setCaptureCodec(codec)
            }
        }
        if model.configuration.captureCodec == .hevc {
            items.append(.separator)
            items.append(.info("保留 Retina 原生像素；导出时可转为 H.264"))
        } else if model.configuration.captureCodec == .proRes422 {
            items.append(.separator)
            items.append(.info("近乎无损，但文件很大；导出时再压缩"))
        }

        if let warning = model.captureReadiness.frameRateWarningText {
            items.append(.separator)
            items.append(.info(warning))
        }

        if !model.captureReadiness.hasScreenRecordingPermission {
            items.append(.separator)
            items.append(.action("打开录屏权限设置", handler: model.openScreenRecordingSettings))
        }
        return items
    }

    private var recordingFormatSummary: String {
        if model.configuration.source == .device {
            return "原格式"
        }
        return switch model.configuration.captureCodec {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes422: "ProRes"
        }
    }

    private var projectMenuItems: [RecorderMenuItem] {
        var items: [RecorderMenuItem] = [
            .action("打开项目…", handler: model.openProjectPicker),
            .action(
                "继续上次项目",
                isEnabled: !model.recentProjects.isEmpty,
                handler: model.openMostRecentProject
            ),
            .separator,
        ]

        if !model.recoverableProjects.isEmpty {
            items.append(
                .action(
                    "恢复中断录制",
                    handler: model.recoverMostRecentProject
                )
            )
        }

        items.append(.action("项目保存位置…", handler: model.chooseProjectsFolder))
        return items
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
                items.append(
                    .info(
                        "系统视频效果：\(effects.names.joined(separator: "、"))；可能降低帧率"
                    )
                )
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

/// The ready state should feel alive without adding another label, badge or
/// persistent colour. A single outward light pass makes the primary action
/// discoverable, while Reduce Motion keeps only the static outline.
private struct RecorderReadyHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var expands = false

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(EditorTheme.platinumAccent.opacity(reducesMotion ? 0.18 : 0.34), lineWidth: 1)
            .scaleEffect(reducesMotion ? 1 : (expands ? 1.055 : 0.985))
            .opacity(reducesMotion ? 1 : (expands ? 0 : 0.78))
            .onAppear {
                guard !reducesMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    expands = true
                }
            }
            .onChange(of: reducesMotion) { _, shouldReduce in
                if shouldReduce {
                    expands = false
                } else {
                    expands = false
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        expands = true
                    }
                }
            }
    }
}

private struct RecordingPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    let isPaused: Bool
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if !isPaused && !reducesMotion {
                Circle()
                    .stroke(Color.red.opacity(isPulsing ? 0 : 0.6), lineWidth: 1.5)
                    .scaleEffect(isPulsing ? 2.2 : 1.0)
                    .opacity(isPulsing ? 0 : 0.8)
                    .frame(width: 8, height: 8)
            }
            Circle()
                .fill(
                    isPaused
                        ? LinearGradient(
                            colors: [Color.orange, Color(red: 0.9, green: 0.5, blue: 0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [Color(red: 1.0, green: 0.35, blue: 0.35), Color(red: 0.95, green: 0.15, blue: 0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                )
                .frame(width: 8, height: 8)
                .shadow(
                    color: (isPaused ? Color.orange : Color.red).opacity(0.85),
                    radius: isPulsing && !isPaused ? 5 : 3
                )
        }
        .onAppear {
            guard !reducesMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .onChange(of: reducesMotion) { _, shouldReduce in
            isPulsing = !shouldReduce
        }
        .animation(SpringMotion.interactive, value: isPaused)
    }
}

struct RecordingBar: View {
    @ObservedObject var model: AppModel
    @State private var pendingAction: RecordingBarAction?

    var body: some View {
        HStack(spacing: 10) {
            recordingStatus

            Spacer(minLength: 4)

            recordingActions
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .frame(
            width: recordingWindowWidth(
                recordsMicrophone: model.configuration.recordsMicrophone
            ),
            height: 52
        )
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [EditorTheme.panelRaised, EditorTheme.recorderSurface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [EditorTheme.topHighlight, Color.white.opacity(0.035)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
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
        HStack(spacing: 9) {
            HStack(spacing: 6) {
                RecordingPulseDot(isPaused: model.isRecordingPaused)
                Text(model.isRecordingPaused ? "已暂停" : "录制中")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        model.isRecordingPaused
                            ? EditorTheme.amberAccent
                            : Color.primary.opacity(0.88)
                    )
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                Color.black.opacity(0.26),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.75)
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .frame(width: 54, alignment: .leading)
                    .contentTransition(.numericText())
            }

            recordingQualityWarning

            if model.configuration.recordsMicrophone {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    LiveMicrophoneLevelView(
                        levelState: model.microphoneInputLevel,
                        width: 42,
                        height: 5
                    )
                }
                .help("麦克风实时音量")
            }
        }
        .lineLimit(1)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var recordingQualityWarning: some View {
        if let measurement = model.recorder.liveMeasurement,
           !model.isRecordingPaused,
           !measurement.isMostlyIdle,
           (measurement.deliveryRatio < 0.92 || measurement.writerDroppedFrames > 0) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EditorTheme.amberAccent)
                .help(
                    String(
                        format: "写入 %.0f fps · 屏幕交付 %.0f fps"
                            + (measurement.writerDroppedFrames > 0
                                ? " · 编码丢弃 %d 帧" : ""),
                        measurement.actualFramesPerSecond,
                        measurement.sckDeliveryFramesPerSecond,
                        measurement.writerDroppedFrames
                    )
                )
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
                accessibilityLabel: "更多录制操作",
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
            .help("更多录制操作")
        }
        .padding(3)
        .background(
            Color.black.opacity(0.25),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 0.75)
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
                    emphasized ? EditorTheme.platinumAccent : Color.white.opacity(0.07),
                    in: Circle()
                )
                .foregroundStyle(emphasized ? Color.black : Color.primary)
                .accessibilityHidden(true)

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

        var items: [RecorderMenuItem] = []
        if canHideDesktopElements {
            items.append(
                .action(
                    "录制画面中隐藏桌面文件",
                    isOn: model.configuration.hidesDesktopFiles
                ) {
                    model.setHidesDesktopFiles(!model.configuration.hidesDesktopFiles)
                }
            )
            items.append(
                .action(
                    "录制画面中隐藏 Dock",
                    isOn: model.configuration.hidesDock
                ) {
                    model.setHidesDock(!model.configuration.hidesDock)
                }
            )
            items.append(.separator)
        }

        items.append(
            .action("重新录制…", isEnabled: !model.isPauseTransitioning) {
                pendingAction = .restart
            }
        )
        items.append(
            .action("丢弃这次录制…", isEnabled: !model.isPauseTransitioning) {
                pendingAction = .discard
            }
        )
        return items
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
    case frame = "画面"
    case opening = "开场"
    case zoom = "运镜"
    case cursor = "光标"
    case camera = "摄像头"
    case audio = "声音"
    case mockup = "样机"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .frame: return "photo.on.rectangle.angled"
        case .opening: return "sparkles.rectangle.stack"
        case .mockup: return "iphone.gen3"
        case .zoom: return "viewfinder"
        case .cursor: return "cursorarrow.motionlines"
        case .camera: return "video.fill"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

enum BackgroundPanelTab: String, CaseIterable, Identifiable {
    case wallpaper = "壁纸"
    case pattern = "网格"
    case dynamic = "动效"
    case gradient = "渐变"
    case color = "纯色"
    case image = "自定"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .wallpaper: return "photo.on.rectangle"
        case .pattern: return "grid"
        case .dynamic: return "waveform.path.ecg.rectangle"
        case .gradient: return "circle.lefthalf.filled"
        case .color: return "paintpalette.fill"
        case .image: return "photo.badge.plus"
        }
    }
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
