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
/// 内容色：主片段的经典暖琥珀橙（Orange + White 标志性主片段风格）。
let editorClipAmberTop = Color(red: 0.82, green: 0.56, blue: 0.22)
let editorClipAmberBottom = Color(red: 0.65, green: 0.42, blue: 0.14)

func setupWindowWidth() -> CGFloat { 714 }
func recordingWindowWidth(recordsMicrophone: Bool) -> CGFloat {
    // Initial size only; the live bar reports its actual localized width.
    312
}

struct RecordingQualityWarningPresentation: Equatable, Sendable {
    let title: String
    let recentDroppedFramesText: String
    let recentWriteHealthText: String
    let droppedFramesText: String

    var helpText: String {
        [
            title,
            recentDroppedFramesText,
            recentWriteHealthText,
            droppedFramesText,
            "这是画面写入提示，与麦克风录音无关。",
        ]
            .joined(separator: "；")
    }

    static func make(
        recentWrittenFrames: Int,
        recentDroppedFrames: Int,
        recentElapsed: TimeInterval,
        totalDroppedFrames: Int
    ) -> Self {
        let recentTotal = max(recentWrittenFrames + recentDroppedFrames, 1)
        let dropRatio = Double(recentDroppedFrames) / Double(recentTotal)
        return Self(
            title: "画面写入出现丢帧",
            recentDroppedFramesText: String(
                format: "最近 %.1f 秒明确丢弃 %d 帧",
                max(recentElapsed, 0),
                recentDroppedFrames
            ),
            recentWriteHealthText: String(
                format: "同期成功写入 %d 帧 · 丢弃比例 %.1f%%",
                recentWrittenFrames,
                dropRatio * 100
            ),
            droppedFramesText: "本次录制累计明确丢弃 \(totalDroppedFrames) 帧"
        )
    }
}

struct RecordingQualityWarningMonitor: Equatable, Sendable {
    private(set) var warning: RecordingQualityWarningPresentation?
    private var previousMeasurement: FrameRateMeasurement?
    private var consecutiveDropWindows = 0
    private var healthyWindowsAfterWarning = 0

    /// A single isolated dropped frame remains in the project diagnostics but
    /// does not interrupt the user. A visible warning requires either a real
    /// burst or explicit drops in two consecutive measurement windows.
    private static let immediateBurstFrameCount = 3
    private static let immediateBurstRatio = 0.05
    private static let healthyWindowsToClear = 5

    mutating func consume(
        measurement: FrameRateMeasurement?,
        isPaused: Bool
    ) {
        guard let measurement else {
            self = Self()
            return
        }
        guard !isPaused else {
            previousMeasurement = measurement
            consecutiveDropWindows = 0
            return
        }
        guard let previousMeasurement,
              measurement.elapsed >= previousMeasurement.elapsed,
              measurement.deliveredFrames >= previousMeasurement.deliveredFrames,
              measurement.writerDroppedFrames >= previousMeasurement.writerDroppedFrames
        else {
            self.previousMeasurement = measurement
            consecutiveDropWindows = 0
            return
        }

        let recentElapsed = measurement.elapsed - previousMeasurement.elapsed
        let recentWrittenFrames = measurement.deliveredFrames
            - previousMeasurement.deliveredFrames
        let recentDroppedFrames = measurement.writerDroppedFrames
            - previousMeasurement.writerDroppedFrames
        self.previousMeasurement = measurement

        guard recentDroppedFrames > 0 else {
            consecutiveDropWindows = 0
            guard warning != nil else { return }
            healthyWindowsAfterWarning += 1
            if healthyWindowsAfterWarning >= Self.healthyWindowsToClear {
                warning = nil
                healthyWindowsAfterWarning = 0
            }
            return
        }

        consecutiveDropWindows += 1
        healthyWindowsAfterWarning = 0
        let recentTotal = max(recentWrittenFrames + recentDroppedFrames, 1)
        let recentDropRatio = Double(recentDroppedFrames) / Double(recentTotal)
        let isImmediateBurst = recentDroppedFrames >= Self.immediateBurstFrameCount
            || (recentDroppedFrames >= 2
                && recentDropRatio >= Self.immediateBurstRatio)
        guard warning != nil || isImmediateBurst || consecutiveDropWindows >= 2 else {
            return
        }
        warning = RecordingQualityWarningPresentation.make(
            recentWrittenFrames: recentWrittenFrames,
            recentDroppedFrames: recentDroppedFrames,
            recentElapsed: recentElapsed,
            totalDroppedFrames: measurement.writerDroppedFrames
        )
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        RecorderSetupSurface(model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.phaseSetup)
        .onAppear {
            model.refreshRecentProjects()
            model.refreshCaptureReadiness()
            model.refreshCaptureDevicesInBackground()
        }
        .appDialog(isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { setupErrorDialog }
    }

    private var setupErrorDialog: AppDialog {
        let message = model.errorMessage ?? "未知错误"
        let actions: [AppDialog.Action]
        if message.hasPrefix("保存目录不可用") {
            actions = [
                .init(id: "cancel", title: "取消", role: .cancel),
                .init(id: "default", title: "使用默认位置") { _ in
                    UserDefaults.standard.removeObject(forKey: ProjectStore.projectsFolderDefaultsKey)
                    model.refreshRecentProjects()
                },
                .init(id: "choose", title: "重新选择文件夹…", role: .primary) { _ in model.chooseProjectsFolder() }
            ]
        } else if message.hasPrefix("没有摄像头采集权限") {
            actions = [
                .init(id: "cancel", title: "暂不使用摄像头", role: .cancel) { _ in model.selectCamera(nil) },
                .init(id: "settings", title: "打开系统设置", role: .primary) { _ in model.openCameraPrivacySettings() }
            ]
        } else if message.hasPrefix("没有麦克风权限") {
            actions = [
                .init(id: "cancel", title: "暂不使用麦克风", role: .cancel) { _ in model.selectMicrophone(nil) },
                .init(id: "settings", title: "打开系统设置", role: .primary) { _ in model.openMicrophonePrivacySettings() }
            ]
        } else {
            actions = [.init(id: "acknowledge", title: "知道了", role: .primary)]
        }
        return AppDialog(title: "操作未完成", message: message, symbol: "exclamationmark.circle", actions: actions)

    }

}

struct RecordingBar: View {
    @ObservedObject var model: AppModel
    var onContentWidthChange: (CGFloat) -> Void = { _ in }
    @State private var pendingAction: RecordingBarAction?
    @State private var qualityWarningMonitor = RecordingQualityWarningMonitor()

    var body: some View {
        HStack(spacing: 10) {
            recordingStatus

            recordingActions
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width.rounded(.up)
        } action: { width in
            onContentWidthChange(width)
        }
        .background(LinearGradient(colors: [.white, RecorderStyle.silver], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.9)) }
        .foregroundStyle(RecorderStyle.ink)
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.phaseRecording)
        .appDialog(isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            let restarting = pendingAction == .restart
            let runID = model.recordingRuns.active?.id
            return AppDialog(
                title: restarting ? "停止当前录制并重新开始？" : "将这次录制移到废纸篓？",
                message: restarting
                    ? "当前录制将移到废纸篓，随后使用相同设置重新开始。"
                    : "当前录制和相关素材将移到废纸篓，随后返回录制条。",
                symbol: restarting ? "arrow.counterclockwise" : "trash",
                actions: [
                    .init(id: "cancel", title: "取消", role: .cancel),
                    .init(id: "confirm", title: restarting ? "重新录制" : "移到废纸篓", role: .destructive) { _ in
                        guard model.recordingRuns.active?.id == runID else { return }
                        if restarting { model.restartCurrentRecording() }
                        else { model.discardCurrentRecording() }
                    }
                ]
            )
        }
        .appDialog(isPresented: Binding(
            get: { model.errorMessage?.hasPrefix("无法更新录制画面") == true },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            AppDialog(title: "无法更新录制画面", message: model.errorMessage ?? "未知错误",
                      symbol: "exclamationmark.circle",
                      actions: [.init(id: "acknowledge", title: "知道了", role: .primary)])
        }
        .onAppear {
            qualityWarningMonitor.consume(
                measurement: model.recorder.liveMeasurement,
                isPaused: model.isRecordingPaused
            )
        }
        .onChange(of: model.recorder.liveMeasurement) { _, measurement in
            qualityWarningMonitor.consume(
                measurement: measurement,
                isPaused: model.isRecordingPaused
            )
        }
        .onChange(of: model.isRecordingPaused) { _, isPaused in
            qualityWarningMonitor.consume(
                measurement: model.recorder.liveMeasurement,
                isPaused: isPaused
            )
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 10) {
            Circle().fill(model.isRecordingPaused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedText(at: context.date))
                    .font(.appUI(size: 17, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 54, alignment: .leading)
            }
            Text(model.isRecordingPaused ? "已暂停" : "录制中")
                .font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted).frame(width: 40)
            RecorderMicrophoneOrb(meter: model.microphoneInputLevel,
                enabled: model.configuration.recordsMicrophone && !model.isRecordingPaused, size: 34)
                .help("麦克风实时音量")
            recordingQualityWarning
        }.fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var recordingQualityWarning: some View {
        if let warning = qualityWarningMonitor.warning {
            RecorderPopoverButton(id: "recording-quality", title: warning.title, width: 24, height: 28) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            } panel: {
                RecorderActionList(title: warning.title, items: [
                    .info(warning.recentDroppedFramesText), .info(warning.recentWriteHealthText),
                    .info(warning.droppedFramesText), .separator,
                    .info("可变帧率的正常降帧不会触发此提示"), .info("这是画面写入提示，与录音无关")
                ])
            }.help(warning.helpText)
        }
    }

    private var recordingActions: some View {
        HStack(spacing: 8) {
            RecorderMemoButton(size: 34)
            recordingActionButton(icon: "bookmark.fill", accessibilityLabel: appLocalized("添加录制标记"),
                accessibilityIdentifier: "recorder.recording.marker",
                isEnabled: model.canAddRecordingMarker, action: model.addRecordingMarker)
                .overlay(alignment: .topTrailing) {
                    if !model.project.recordingMarkers.isEmpty {
                        Text(model.project.recordingMarkers.count, format: .number)
                            .font(.appUI(size: 8, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(RecorderStyle.ink)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(RecorderStyle.mintWash, in: Capsule())
                            .offset(x: 4, y: -3)
                            .allowsHitTesting(false)
                    }
                }
                .help(appLocalized(model.recordingMarkerShortcutAvailable
                    ? "添加录制标记（⌃⌥M）；保存到项目，不会录入画面"
                    : "添加录制标记；全局快捷键不可用，请使用此按钮"))
            recordingActionButton(icon: model.isRecordingPaused ? "play.fill" : "pause.fill",
                accessibilityLabel: model.isRecordingPaused ? "继续录制" : "暂停录制",
                accessibilityIdentifier: RecorderAccessibilityID.recordingPauseResume,
                isEnabled: !model.isPauseTransitioning, action: model.toggleRecordingPause)
            recordingActionButton(icon: "stop.fill", accessibilityLabel: "结束录制",
                accessibilityIdentifier: RecorderAccessibilityID.recordingStop,
                emphasized: true, action: model.stopRecording)
            RecorderPopoverButton(id: "recording-more", title: "更多录制操作", width: 28, height: 34) {
                Image(systemName: "ellipsis").font(.appUI(size: 16)).foregroundStyle(RecorderStyle.muted)
            } panel: { RecorderActionList(title: "录制操作", items: recordingMenuItems) }

        }
    }

    private func recordingActionButton(icon: String, accessibilityLabel: String,
        accessibilityIdentifier: String, isEnabled: Bool = true,
        emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        ZStack {
            Image(systemName: icon).font(.appUI(size: 13, weight: .medium))
                .foregroundStyle(emphasized ? Color.red : RecorderStyle.ink)
                .frame(width: 36, height: 34)
                .modifier(RecorderRaisedSurface(radius: 10))
                .accessibilityHidden(true)
            RecorderActionTrigger(action: action, accessibilityLabel: accessibilityLabel,
                isEnabled: isEnabled, accessibilityIdentifier: accessibilityIdentifier,
                cornerRadius: 10, highlightOpacity: 0.04)
                .frame(width: 36, height: 34)
        }
        .frame(width: 36, height: 34)
        .opacity(isEnabled ? 1 : 0.4)
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

    var id: String { rawValue }
    var localizedLabel: String { appLocalized(rawValue) }

    var icon: String {
        switch self {
        case .frame: return "photo.on.rectangle.angled"
        case .opening: return "sparkles.rectangle.stack"
        case .zoom: return "viewfinder"
        case .cursor: return "cursorarrow.motionlines"
        case .camera: return "video.fill"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

/// The frame inspector contains several different authoring tasks. Keeping
/// them as a second, horizontal level prevents a long wallpaper browser from
/// burying high-frequency layout and appearance controls.
enum FrameInspectorTab: String, CaseIterable, Identifiable {
    case background = "背景"
    case layout = "布局"
    case mockup = "样机"

    var id: String { rawValue }
    var localizedLabel: String { appLocalized(rawValue) }

    var icon: String {
        switch self {
        case .background: "square.3.layers.3d"
        case .layout: "rectangle.inset.filled"
        case .mockup: "macwindow"
        }
    }
}

enum BackgroundPanelTab: String, CaseIterable, Identifiable {
    case wallpaper = "壁纸"
    case pattern = "网格"
    case dynamic = "动效"
    case image = "自定"

    var id: String { rawValue }
    var localizedLabel: String { appLocalized(rawValue) }

    var icon: String {
        switch self {
        case .wallpaper: return "photo"
        case .pattern: return "grid"
        case .dynamic: return "waveform.path.ecg.rectangle"
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
