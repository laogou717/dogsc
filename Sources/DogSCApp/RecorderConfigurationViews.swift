import AppKit
import AVFoundation
import Combine
import RecorderCore
import SwiftUI

enum RecorderInputKind { case microphone, camera, systemAudio }

struct RecorderInputPopover: View {
    @ObservedObject var model: AppModel
    let kind: RecorderInputKind
    private var title: String {
        switch kind { case .microphone: "麦克风"; case .camera: "摄像头"; case .systemAudio: model.configuration.source == .device ? "设备声音" : "系统声音" }
    }
    private var isOn: Bool {
        switch kind { case .microphone: model.configuration.recordsMicrophone; case .camera: model.configuration.recordsCamera; case .systemAudio: model.configuration.recordsSystemAudio }
    }
    private var enabled: Binding<Bool> {
        Binding(get: { isOn }, set: { value in
            switch kind {
            case .microphone: model.setDefaultMicrophoneRecordingEnabled(value)
            case .camera: model.selectCamera(value ? model.availableCameras.first : nil)
            case .systemAudio: model.setDefaultSystemAudioRecordingEnabled(value)
            }
        })
    }
    @State private var expandedResolution = false

    var body: some View {
        RecorderPopoverSurface {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(appLocalized(title), isOn: enabled)
                    .toggleStyle(RecorderInputToggleStyle(title: appLocalized(title)))
                    .font(.appUI(size: 15, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 40)
                switch kind {
                case .microphone: microphone
                case .camera: camera
                case .systemAudio: systemAudio
                }
            }
            .animation(RecorderMotion.settle, value: isOn)
        }
        // The list is always current when it opens; nobody should have to ask.
        .onAppear { if kind != .systemAudio { model.refreshCaptureDevicesInBackground() } }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 4) {
            deviceList(model.availableMicrophones, selectedID: model.configuration.microphoneDeviceID, action: model.selectMicrophone)
            if model.configuration.recordsMicrophone {
                RecorderLevelWave(meter: model.microphoneInputLevel)
                    .frame(height: 40)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityLabel(appLocalized("输入电平"))
            }
        }
    }

    private var camera: some View {
        VStack(alignment: .leading, spacing: 4) {
            deviceList(model.availableCameras, selectedID: model.configuration.cameraDeviceID, action: model.selectCamera)
            if model.configuration.recordsCamera {
                RecorderCameraPreview(sink: model.configurationCameraFrameSink, mirrored: model.recordingCameraMirrored)
                    .frame(height: 152).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if model.cameraRuntimeFormat == nil {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(RecorderStyle.silver, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // The two things done to the picture sit on the picture.
                        HStack(spacing: 6) {
                            previewButton("arrow.left.and.right", title: "镜像画面", active: model.recordingCameraMirrored) {
                                model.recordingCameraMirrored.toggle()
                            }
                            previewButton("wand.and.stars", title: "系统视频效果…", active: false) {
                                RecorderPopoverPresenter.shared.dismiss()
                                CaptureDeviceCatalog.showSystemVideoEffects()
                            }
                        }
                        .padding(8)
                    }
                    .padding(.horizontal, 10).padding(.top, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Button {
                    withAnimation(RecorderMotion.settle) { expandedResolution.toggle() }
                } label: {
                    HStack {
                        Text(model.cameraRuntimeFormat?.label ?? appLocalized("采集分辨率"))
                            .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(RecorderStyle.muted)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RecorderStyle.faint)
                            .rotationEffect(.degrees(expandedResolution ? 180 : 0))
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 10))
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(appLocalized("采集分辨率"))
                if expandedResolution {
                    VStack(spacing: 2) {
                        RecorderChoiceRow(title: "自动", selected: model.configuration.cameraCaptureResolution == nil, isAlternative: true) { model.selectCameraCaptureResolution(nil) }
                        ForEach(model.availableCameraResolutions) { size in
                            RecorderChoiceRow(title: size.label, selected: model.configuration.cameraCaptureResolution == size, isAlternative: true) { model.selectCameraCaptureResolution(size) }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func previewButton(_ symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? RecorderStyle.onPrimary : RecorderStyle.mediaInk)
                .frame(width: 28, height: 28)
                .background(active ? RecorderStyle.primaryFill.opacity(0.95) : RecorderStyle.mediaOverlay, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 14))
        .appButtonKeyboardFocus(in: Circle(), color: RecorderStyle.chrome.opacity(0.7))
        .help(appLocalized(title)).accessibilityLabel(appLocalized(title))
        .animation(RecorderMotion.quick, value: active)
    }

    private var systemAudio: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.configuration.source == .device {
                Text("录制所选设备的声音").foregroundStyle(RecorderStyle.muted).padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                RecorderChoiceRow(title: "全部系统声音", selected: model.configuration.systemAudioScope == .all, isAlternative: true) {
                    model.setDefaultSystemAudioRecordingEnabled(true, scope: .all)
                }
                RecorderChoiceRow(title: "所选窗口 App", selected: model.configuration.systemAudioScope == .selectedApplication,
                                  enabled: model.configuration.selectedApplicationBundleIdentifier != nil,
                                  subtitle: model.configuration.selectedApplicationName, isAlternative: true) {
                    model.setDefaultSystemAudioRecordingEnabled(true, scope: .selectedApplication)
                }
            }
        }.disabled(!model.configuration.recordsSystemAudio).opacity(model.configuration.recordsSystemAudio ? 1 : 0.4)
    }

    private func deviceList(_ devices: [CaptureDeviceInfo], selectedID: String?, action: @escaping (CaptureDeviceInfo?) -> Void) -> some View {
        VStack(spacing: 2) {
            if devices.isEmpty {
                Text("未发现设备").foregroundStyle(RecorderStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
            }
            ForEach(devices) { device in
                RecorderChoiceRow(title: device.name, selected: selectedID == device.id, isAlternative: true) { action(device) }
            }
        }
    }
}

/// The last couple of seconds of the microphone, scrolling. Quiet rooms draw
/// a resting line; speech draws itself.
struct RecorderLevelWave: View {
    @ObservedObject var meter: LiveMicrophoneLevelState
    @State private var samples = [Double](repeating: 0, count: 44)
    private let clock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2.5
            let width = max(1, (proxy.size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(samples.indices, id: \.self) { index in
                    let value = samples[index]
                    Capsule()
                        .fill(value > 0.03 ? RecorderStyle.mint : RecorderStyle.faint)
                        .opacity(0.35 + 0.65 * Double(index) / Double(samples.count - 1))
                        .frame(width: width, height: max(2.5, proxy.size.height * min(1, value * 1.5)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onReceive(clock) { _ in
            var next = samples
            next.removeFirst()
            next.append(min(max(meter.value, 0), 1))
            if RecorderMotion.reduces { samples = next }
            else { withAnimation(.linear(duration: 0.05)) { samples = next } }
        }
    }
}

/// Everything that is not needed for every take: where it goes, how it is
/// encoded, old projects, the memo, and the way out. Controls explain
/// themselves; there are no captions.
struct RecorderSavePopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var memo = RecorderMemoController.shared
    @State private var expandedQuality = false
    @Namespace private var codecSelection
    var body: some View {
        RecorderPopoverSurface(width: 300) {
            VStack(alignment: .leading, spacing: 4) {
                RecorderSaveActionRow(title: model.recordingDestinationName, symbol: "folder.fill") { [model] in
                    RecorderPopoverPresenter.shared.dismissAndPerform { model.chooseProjectsFolder() }
                }
                TextField("自动命名", text: $model.recordingTitleDraft)
                    .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 34)
                    .background(RecorderStyle.well, in: Capsule())
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .accessibilityLabel(appLocalized("文件名"))
                if model.configuration.source != .device {
                    HStack(spacing: 0) {
                        ForEach(CaptureCodec.allCases) { codec in
                            let selected = model.configuration.captureCodec == codec
                            Button { model.captureSetup.setCaptureCodec(codec) } label: {
                                Text(codec == .proRes422 ? "ProRes" : codec.rawValue)
                                    .font(.appUI(size: 12, weight: .medium))
                                    .foregroundStyle(selected ? RecorderStyle.ink : RecorderStyle.muted)
                                    .frame(maxWidth: .infinity).frame(height: 30)
                                    .background {
                                        if selected {
                                            Capsule().fill(RecorderStyle.selection)
                                                .matchedGeometryEffect(id: "codec", in: codecSelection)
                                        }
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 15))
                            .appButtonKeyboardFocus(in: Capsule())
                            .accessibilityValue(selected ? appLocalized("已选择") : "")
                        }
                    }
                    .padding(2)
                    .background(RecorderStyle.silver, in: Capsule())
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .animation(RecorderMotion.quick, value: model.configuration.captureCodec)

                    Button {
                        withAnimation(RecorderMotion.settle) { expandedQuality.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles.tv").font(.system(size: 13, weight: .medium)).frame(width: 18)
                                .foregroundStyle(RecorderStyle.muted)
                            Text(appLocalized(model.configuration.captureResolutionLimit.rawValue))
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(RecorderStyle.faint)
                                .rotationEffect(.degrees(expandedQuality ? 180 : 0))
                        }
                        .font(.appUI(size: 13)).padding(.horizontal, 8).frame(height: 36)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 10))
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(appLocalized("画质"))
                    if expandedQuality {
                        VStack(spacing: 2) {
                            ForEach(CaptureResolutionLimit.allCases) { limit in
                                RecorderChoiceRow(title: limit.rawValue, selected: model.configuration.captureResolutionLimit == limit, isAlternative: true) {
                                    model.captureSetup.setResolutionLimit(limit)
                                    withAnimation(RecorderMotion.settle) { expandedQuality = false }
                                }
                            }
                        }
                        .padding(.leading, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    RecorderSaveToggleRow(title: "隐藏桌面文件", symbol: "menubar.dock.rectangle", isOn: Binding(get: { model.configuration.hidesDesktopFiles }, set: { model.setHidesDesktopFiles($0) }))
                    RecorderSaveToggleRow(title: "隐藏 Dock", symbol: "dock.rectangle", isOn: Binding(get: { model.configuration.hidesDock }, set: { model.setHidesDock($0) }))
                }
                rule
                projectAction("打开项目…", symbol: "tray.full") { model.openProjectPicker() }
                if !model.recentProjects.isEmpty {
                    projectAction("继续上次项目", symbol: "clock.arrow.circlepath") { model.openMostRecentProject() }
                }
                if !model.recoverableProjects.isEmpty {
                    projectAction("恢复中断录制", symbol: "arrow.counterclockwise") { model.recoverMostRecentProject() }
                }
                if !model.captureReadiness.hasScreenRecordingPermission {
                    projectAction("打开录屏权限设置", symbol: "lock.shield") { model.openScreenRecordingSettings() }
                }
                RecorderSaveActionRow(title: memo.isVisible ? "收起备忘录" : "打开备忘录", symbol: "text.alignleft", showsChevron: false) {
                    RecorderPopoverPresenter.shared.dismissAndPerform { WindowCoordinator.toggleRecorderMemo() }
                }
                rule
                RecorderSaveActionRow(title: "退出DogSC", symbol: "power", showsChevron: false) {
                    RecorderPopoverPresenter.shared.dismissAndPerform { NSApplication.shared.terminate(nil) }
                }
                if let warning = model.captureReadiness.frameRateWarningText {
                    Text(warning).font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                        .padding(.horizontal, 8).padding(.top, 4)
                }
            }
        }
    }

    private var rule: some View {
        Rectangle().fill(RecorderStyle.line).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func projectAction(_ title: String, symbol: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) -> some View {
        RecorderSaveActionRow(title: title, symbol: symbol, enabled: enabled, showsChevron: false) {
            RecorderPopoverPresenter.shared.dismissAndPerform(action)
        }
    }
}

struct RecorderCameraPreview: NSViewRepresentable {
    let sink: ImmediateCameraPreviewFrameSink
    let mirrored: Bool
    func makeNSView(context: Context) -> RecorderCameraPreviewView { RecorderCameraPreviewView(sink: sink) }
    func updateNSView(_ view: RecorderCameraPreviewView, context: Context) { view.mirrored = mirrored; view.needsLayout = true }
    static func dismantleNSView(_ view: RecorderCameraPreviewView, coordinator: ()) { view.releasePreview() }
}
final class RecorderCameraPreviewView: NSView {
    private let sink: ImmediateCameraPreviewFrameSink
    private let displayLayer = AVSampleBufferDisplayLayer()
    var mirrored = true
    init(sink: ImmediateCameraPreviewFrameSink) {
        self.sink = sink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = RecorderStyle.chromeNSColor.withAlphaComponent(0.06).cgColor
        displayLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(displayLayer)
        sink.attach(displayLayer.sampleBufferRenderer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = RecorderStyle.chromeNSColor.withAlphaComponent(0.06).cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
        CATransaction.commit()
    }
    func releasePreview() { sink.attach(nil); displayLayer.flushAndRemoveImage() }
}
