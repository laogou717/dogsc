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
        let recovery = RecorderSetupErrorRecovery.forMessage(message)
        let actions: [AppDialog.Action]
        if recovery == .projectFolder {
            actions = [
                .init(id: "cancel", title: "取消", role: .cancel),
                .init(id: "default", title: "使用默认位置") { _ in
                    UserDefaults.standard.removeObject(forKey: ProjectStore.projectsFolderDefaultsKey)
                    model.refreshRecentProjects()
                },
                .init(id: "choose", title: "重新选择文件夹…", role: .primary) { _ in model.chooseProjectsFolder() }
            ]
        } else if recovery == .camera {
            actions = [
                .init(id: "cancel", title: "暂不使用摄像头", role: .cancel) { _ in model.selectCamera(nil) },
                .init(id: "settings", title: "打开系统设置", role: .primary) { _ in model.openCameraPrivacySettings() }
            ]
        } else if recovery == .microphone {
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
        HStack(spacing: 0) {
            recordingStatus
            recordingActions
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(height: 48)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(RecorderStyle.ink)
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
            get: { model.errorMessage.map(RecorderSetupErrorRecovery.isSurfaceUpdateErrorMessage) == true },
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

    /// The take itself: a breathing point, the running time, and the voice.
    private var recordingStatus: some View {
        HStack(spacing: 9) {
            RecordingIndicator(isPaused: model.isRecordingPaused)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(model.isRecordingPaused ? RecorderStyle.muted : RecorderStyle.ink)
                    .contentTransition(.numericText())
                    .frame(minWidth: 46, alignment: .leading)
            }
            .accessibilityLabel(appLocalized(model.isRecordingPaused ? "已暂停" : "录制中"))
            if model.configuration.recordsMicrophone {
                RecorderLevelBars(meter: model.microphoneInputLevel, active: !model.isRecordingPaused)
                    .help("麦克风实时音量")
            }
            recordingQualityWarning
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 12)
        .animation(RecorderMotion.quick, value: model.isRecordingPaused)
    }

    @ViewBuilder private var recordingQualityWarning: some View {
        if let warning = qualityWarningMonitor.warning {
            RecorderPopoverButton(id: "recording-quality", title: warning.title, width: 24, height: 28) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
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
        HStack(spacing: 0) {
            recordingActionButton(icon: "bookmark.fill", accessibilityLabel: appLocalized("添加录制标记"),
                accessibilityIdentifier: "recorder.recording.marker",
                isEnabled: model.canAddRecordingMarker, action: model.addRecordingMarker)
                .overlay(alignment: .topTrailing) {
                    if !model.project.recordingMarkers.isEmpty {
                        Text(model.project.recordingMarkers.count, format: .number)
                            .font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(RecorderStyle.ink)
                            .contentTransition(.numericText())
                            .offset(x: -3, y: 7)
                            .allowsHitTesting(false)
                    }
                }
                .help(appLocalized(model.recordingMarkerShortcutAvailable
                    ? "添加录制标记（⌃⌥M）；保存到项目，不会录入画面"
                    : "添加录制标记；全局快捷键不可用，请使用此按钮"))
            RecorderMemoButton(size: 36)
            recordingActionButton(icon: model.isRecordingPaused ? "play.fill" : "pause.fill",
                accessibilityLabel: model.isRecordingPaused ? "继续录制" : "暂停录制",
                accessibilityIdentifier: RecorderAccessibilityID.recordingPauseResume,
                isEnabled: !model.isPauseTransitioning, action: model.toggleRecordingPause)
            RecorderPopoverButton(id: "recording-more", title: "更多录制操作", width: 32, height: 36) {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(RecorderStyle.muted)
            } panel: { RecorderActionList(title: "录制操作", items: recordingMenuItems) }
            stopButton.padding(.leading, 6)
        }
    }

    /// Ending the take is the island's one solid, coloured control.
    private var stopButton: some View {
        RecorderNativeActionButton(accessibilityLabel: appLocalized("结束录制"),
            accessibilityIdentifier: RecorderAccessibilityID.recordingStop, isEnabled: true,
            width: 36, height: 36, cornerRadius: 18, highlightOpacity: 0, action: model.stopRecording) {
            ZStack {
                Circle().fill(RecorderStyle.recording)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white).frame(width: 11, height: 11)
            }
            .frame(width: 36, height: 36)
        }
    }

    private func recordingActionButton(icon: String, accessibilityLabel: String,
        accessibilityIdentifier: String, isEnabled: Bool = true,
        action: @escaping () -> Void) -> some View {
        RecorderNativeActionButton(accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier, isEnabled: isEnabled,
            width: 36, height: 36, cornerRadius: 18, highlightOpacity: 0.05, action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RecorderStyle.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
        }
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
        // Past an hour, "75:03" stops reading as a duration.
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private enum RecordingBarAction {
    case restart
    case discard
}

/// A live take breathes; a paused one holds still in amber.
private struct RecordingIndicator: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        let breathes = !isPaused && !reduceMotion
        Circle()
            .fill(isPaused ? Color(red: 0.95, green: 0.62, blue: 0.2) : RecorderStyle.recording)
            .frame(width: 8, height: 8)
            .opacity(breathes && dimmed ? 0.32 : 1)
            .animation(breathes ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.15),
                       value: dimmed)
            .onAppear { dimmed = breathes }
            .onChange(of: breathes) { _, value in dimmed = value }
            .accessibilityHidden(true)
    }
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
        case .camera: return "video"
        case .audio: return "speaker.wave.2"
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
}

enum ZoomResizeEdge {
    case leading
    case trailing
}
