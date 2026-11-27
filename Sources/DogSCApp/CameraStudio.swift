import AppKit
import Combine
import RecorderCore
import SwiftUI

struct CameraBeautyControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Toggle(isOn: Binding(get: { model.recordingCameraBeauty.isEnabled },
                                 set: model.setRecordingBeautyEnabled)) {
                Label(appLocalized("美颜"), systemImage: "sparkles").font(.appUI(size: 13))
            }
            .toggleStyle(RecorderInputToggleStyle(title: appLocalized("美颜")))
            .padding(.horizontal, 8).frame(minHeight: 34)
            if model.recordingCameraBeauty.isEnabled {
                slider("磨皮", $model.recordingCameraBeauty.smoothing)
                slider("美白", $model.recordingCameraBeauty.whitening)
            }
        }
    }

    private func slider(_ title: String, _ amount: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(appLocalized(title))
            EditorSlider(value: amount, range: 0...1, formatValue: {
                $0.formatted(.percent.precision(.fractionLength(0)))
            }, showsFloatingValue: false)
            .accessibilityLabel(appLocalized(title))
            Text(amount.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(width: 34, alignment: .trailing)
        }
        .font(.appUI(size: 12)).padding(.horizontal, 10)
    }
}

struct CameraResolutionChoices: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let choices: [CameraCaptureResolution?] = [nil] + model.availableCameraResolutions.map(Optional.some)
        let selected = model.configuration.cameraCaptureResolution?.qualitySize
        if choices.count <= 4 && choices.allSatisfy({ ($0?.resolutionLabel.count ?? 0) <= 5 }) {
            EditorSegmentedControl(options: choices, title: { $0?.resolutionLabel ?? "自动" },
                selection: Binding(get: { selected }, set: { choice in
                    if choice != selected { model.selectCameraCaptureResolution(choice) }
                }))
                .environment(\.recordingDesignControls, true)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    RecorderChoiceRow(title: "自动", selected: selected == nil) {
                        if selected != nil { model.selectCameraCaptureResolution(nil) }
                    }
                    ForEach(model.availableCameraResolutions) { size in
                        RecorderChoiceRow(title: size.resolutionLabel, selected: size == selected) {
                            if size != selected { model.selectCameraCaptureResolution(size) }
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(choices.count) * 36, 180))
        }
    }
}

@MainActor
final class CameraStudioWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var formatObservation: AnyCancellable?
    private let frameName = "DogSC.CameraStudio"
    private var hasUserFrame = false

    init(model: AppModel, screen: NSScreen?) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 405 + 128),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = appLocalized("摄像头录制")
        window.identifier = NSUserInterfaceItemIdentifier("recorder.cameraStudio")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentMinSize = CGSize(width: 340, height: 300)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CameraStudioView(model: model).ignoresSafeArea().appControlFocusAppearance())
        window.delegate = self
        if window.setFrameUsingName(frameName) {
            hasUserFrame = true
            window.setFrameAutosaveName(frameName)
        } else if let screen {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                          y: screen.visibleFrame.midY - frame.height / 2))
        } else { window.center() }
        formatObservation = model.$cameraRuntimeFormat.compactMap { format -> CGFloat? in
            guard let format, format.height > 0, format.width > 0 else { return nil }
            return CGFloat(format.width) / CGFloat(format.height)
        }.removeDuplicates().sink { [weak self] ratio in self?.fitSource(ratio) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fitSource(_ ratio: CGFloat) {
        guard !hasUserFrame, let window, !window.inLiveResize, !window.styleMask.contains(.fullScreen),
              let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let chrome = CameraStudioView.headerHeight + CameraStudioView.footerHeight
        let width = min(720, visible.width - 20, (visible.height - chrome - 28) * ratio)
        let size = CGSize(width: max(width, window.contentMinSize.width), height: width / ratio + chrome)
        let old = window.frame
        let target = NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                            width: size.width, height: size.height)
        window.setFrame(window.constrainFrameRect(target, to: window.screen), display: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !hasUserFrame, let window, !window.styleMask.contains(.fullScreen) else { return }
        hasUserFrame = true
        window.saveFrame(usingName: frameName)
        window.setFrameAutosaveName(frameName)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch model.phase {
        case .recording: model.stopRecording(); return false
        case .preparing, .finishing: return false
        default: model.leaveCameraStudio(); return true
        }
    }
}

private struct CameraStudioView: View {
    static let headerHeight: CGFloat = 58
    static let footerHeight: CGFloat = 70
    @ObservedObject var model: AppModel
    @State private var settingsOpen = false
    @State private var pendingTakeAction: AppDialog?
    @AppStorage("cameraStudio.prompter.open") private var prompterOpen = RecorderMemoController.shared.isVisible
    private var ready: Bool { model.phase == .setup && model.recorderStartAvailability == .ready }
    private var recording: Bool { model.phase == .recording }
    private var busy: Bool { model.phase == .preparing || model.phase == .finishing }

    var body: some View {
        GeometryReader { bounds in studio(width: bounds.size.width) }
            .appDialog($pendingTakeAction)
            .onChange(of: model.phase) { if !recording { pendingTakeAction = nil } }
    }

    private func studio(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(appLocalized("摄像头录制")).font(.appUI(size: 16, weight: .semibold))
                EditorActionMenu(title: "摄像头", items: model.availableCameras.map { device in
                    .action(device.name, isOn: device.id == model.configuration.cameraDeviceID) {
                        if model.phase == .setup, model.configuration.cameraDeviceID != device.id { model.selectCamera(device) }
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(model.configuration.cameraDeviceName ?? appLocalized("选择摄像头"))
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.appUI(size: 12, weight: .medium)).foregroundStyle(RecorderStyle.muted)
                    .padding(.horizontal, 8).frame(height: 22)
                }
                .accessibilityValue(model.configuration.cameraDeviceName ?? "")
                .disabled(model.phase != .setup || model.availableCameras.isEmpty)
            }
            .frame(maxWidth: .infinity).frame(height: Self.headerHeight)
            .overlay(alignment: .trailing) {
                if width < 480 { prompterButton.padding(.trailing, 12) }
            }
            ZStack {
                Color.black
                RecorderCameraPreview(sink: model.studioCameraFrameSink, mirrored: model.recordingCameraMirrored)
                if let error = model.errorMessage, model.phase == .setup {
                    Text(appLocalized(error)).multilineTextAlignment(.center).padding().foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).padding()
                } else if model.cameraRuntimeFormat == nil && !busy {
                    if model.configuration.recordsCamera {
                        ProgressView().controlSize(.small).colorScheme(.dark)
                    } else {
                        Label(appLocalized("未发现设备"), systemImage: "video.slash").foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                StudioPrompter(store: RecorderMemoController.shared.store,
                    microphone: model.microphoneRecorder,
                    phase: model.phase, discarding: model.recorderTransitionStage == .discardingRecording,
                    deviceID: model.cameraStudioIsPresented && (ready || recording) && !model.isRecordingPaused
                        && model.configuration.recordsMicrophone ? model.configuration.microphoneDeviceID : nil,
                    presented: $prompterOpen)
            }
            .coordinateSpace(name: "studio.preview")
            ZStack {
                HStack {
                    microphoneControls
                    Spacer()
                    if width >= 480 { prompterButton }
                    if model.phase == .setup {
                        Button { model.recordingCameraMirrored.toggle() } label: {
                            Image(systemName: "flip.horizontal")
                                .foregroundStyle(model.recordingCameraMirrored ? RecorderStyle.positiveInk : RecorderStyle.ink)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(EditorToolbarPressButtonStyle())
                        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
                        .help(appLocalized("镜像画面")).accessibilityLabel(appLocalized("镜像画面"))
                        .accessibilityAddTraits(model.recordingCameraMirrored ? .isSelected : [])
                        settingsButton
                    } else if recording {
                        takeButton(.restart)
                        takeButton(.discard)
                    }
                }
                if busy {
                    HStack { ProgressView().controlSize(.small); Text(model.recorderTransitionStage.title) }
                } else {
                    HStack(spacing: 10) {
                        if recording {
                            Button { model.toggleRecordingPause() } label: {
                                Image(systemName: model.isRecordingPaused ? "play.fill" : "pause.fill")
                            }
                            .buttonStyle(EditorToolbarPressButtonStyle())
                            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 6))
                            .disabled(model.isPauseTransitioning)
                            .accessibilityLabel(appLocalized(model.isRecordingPaused ? "继续录制" : "暂停录制"))
                        }
                        Button {
                            if recording { model.stopRecording() } else { model.startRecording() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: recording ? "stop.fill" : "circle.fill")
                                if recording {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        let seconds = Int(model.elapsedRecordingTime(at: context.date))
                                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                                    }
                                } else { Text(appLocalized("开始录制")) }
                            }
                            .font(.appUI(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(RecorderStyle.recording, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(RecorderPlainPressButtonStyle())
                        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 12), color: .white.opacity(0.85))
                        .disabled(!recording && !ready)
                        .opacity(recording || ready ? 1 : 0.5)
                        .accessibilityLabel(appLocalized(recording ? "结束录制" : "开始录制"))
                    }
                }
            }
            .padding(.horizontal, 18).frame(height: Self.footerHeight)
        }
        .background(RecorderStyle.base).foregroundStyle(RecorderStyle.ink)
    }

    private func takeButton(_ action: RecordingTakeAction) -> some View {
        Button { pendingTakeAction = action.confirmation(for: model) } label: {
            Image(systemName: action.symbol).frame(width: 28, height: 32)
        }
        .buttonStyle(EditorToolbarPressButtonStyle())
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.isPauseTransitioning)
        .help(appLocalized(action.title)).accessibilityLabel(appLocalized(action.title))
    }

    private var prompterButton: some View {
        Button { prompterOpen.toggle() } label: {
            Image(systemName: "text.rectangle")
                .foregroundStyle(prompterOpen ? RecorderStyle.positiveInk : RecorderStyle.ink)
                .frame(width: 32, height: 32)
                .background(prompterOpen ? RecorderStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(EditorToolbarPressButtonStyle())
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
        .help(appLocalized("提词器")).accessibilityLabel(appLocalized("提词器"))
        .accessibilityAddTraits(prompterOpen ? .isSelected : [])
    }

    private var settingsButton: some View {
        Button { settingsOpen.toggle() } label: {
            Image(systemName: "gearshape")
                .frame(width: 32, height: 32)
                .background(settingsOpen ? RecorderStyle.selection : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(EditorToolbarPressButtonStyle())
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
        .help(appLocalized("摄像头设置")).accessibilityLabel(appLocalized("摄像头设置"))
        .editorPopoverKeyboardEntry { settingsOpen = true }
        .editorPopover(isPresented: $settingsOpen, arrowEdge: .top, background: RecorderStyle.base) {
            VStack(alignment: .leading, spacing: 10) {
                Text(appLocalized("摄像头设置")).font(.appUI(size: 15, weight: .semibold))
                CameraBeautyControls(model: model)
                Divider()
                HStack {
                    Text(appLocalized("采集分辨率")).font(.appUI(size: 12, weight: .medium))
                    Spacer(minLength: 4)
                    if let format = model.cameraRuntimeFormat {
                        Text(format.label).font(.appUI(size: 11)).monospacedDigit()
                            .foregroundStyle(RecorderStyle.muted)
                    }
                }
                CameraResolutionChoices(model: model)
            }
            .foregroundStyle(RecorderStyle.ink).padding(14).frame(width: 286)
        }
    }

    private var microphoneControls: some View {
        let selectedID = model.configuration.microphoneDeviceID
        let off = RecorderMenuItem.action("关闭", isOn: selectedID == nil) {
            if model.phase == .setup, selectedID != nil { model.selectMicrophone(nil) }
        }
        let devices = model.availableMicrophones.map { device in
            RecorderMenuItem.action(device.name, isOn: device.id == selectedID) {
                if model.phase == .setup, selectedID != device.id { model.selectMicrophone(device) }
            }
        }
        return HStack(spacing: 3) {
            EditorActionMenu(title: "麦克风", items: [off] + devices, arrowEdge: .top) {
                Image(systemName: model.configuration.recordsMicrophone ? "mic" : "mic.slash")
                    .frame(width: 28, height: 32)
            }
            .disabled(model.phase != .setup)
            .accessibilityValue(model.configuration.microphoneDeviceName ?? appLocalized("关闭"))
            StudioMicrophoneMeter(meter: model.microphoneInputLevel,
                                  active: model.configuration.recordsMicrophone && !model.isRecordingPaused)
        }
    }
}

private struct StudioMicrophoneMeter: View {
    @ObservedObject var meter: LiveMicrophoneLevelState
    let active: Bool

    var body: some View {
        let level = active ? meter.value : 0
        HStack(spacing: 3) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > Double(index) / 4 + 0.02 ? RecorderStyle.mint : RecorderStyle.chrome.opacity(0.18))
                    .frame(width: 7, height: 12)
            }
        }
        .fixedSize()
        .help(appLocalized("麦克风实时音量"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized("输入电平"))
        .accessibilityValue(level.formatted(.percent.precision(.fractionLength(0))))
    }
}
