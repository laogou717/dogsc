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
            case .camera: model.selectCamera(value ? model.preferredStudioCamera : nil)
            case .systemAudio: model.setDefaultSystemAudioRecordingEnabled(value)
            }
        })
    }
    @State private var expandedDevices = false
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
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Button {
                expandedDevices.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isOn ? "checkmark" : "video")
                        .foregroundStyle(isOn ? RecorderStyle.positiveInk : RecorderStyle.muted)
                    Text(model.configuration.cameraDeviceName ?? appLocalized("选择摄像头"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: expandedDevices ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(RecorderStyle.muted)
                }
                .font(.appUI(size: 13, weight: .medium))
                .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedDevices {
                deviceList(model.availableCameras, selectedID: model.configuration.cameraDeviceID) { device in
                    model.selectCamera(device)
                    expandedDevices = false
                }
            }
            if isOn {
                ZStack(alignment: .bottomTrailing) {
                    RecorderCameraPreview(sink: model.configurationCameraFrameSink, mirrored: model.recordingCameraMirrored)
                    if model.cameraRuntimeFormat == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Button { expandedResolution.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(model.cameraRuntimeFormat?.resolution.aspectRatioLabel ?? appLocalized("自动"))
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain).help(appLocalized("采集分辨率")).padding(6)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 8)
                if expandedResolution { CameraResolutionChoices(model: model) }
                RecorderSaveToggleRow(title: "镜像", symbol: "flip.horizontal",
                                      isOn: $model.recordingCameraMirrored)
                CameraBeautyControls(model: model)
            }
            Divider()
            RecorderSaveActionRow(title: "单独录制摄像头…", symbol: "video") {
                RecorderPopoverPresenter.shared.dismissAndPerform { model.openCameraStudio() }
            }
        }
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
    private static var expand: Animation? {
        RecorderMotion.reduces ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.24)
    }
    @ObservedObject var model: AppModel
    let mode: RecorderSourceMode
    @ObservedObject private var memo = RecorderMemoController.shared
    @State private var expandedQuality = false
    @Namespace private var codecSelection
    var body: some View {
        RecorderPopoverSurface(width: 300) {
            VStack(alignment: .leading, spacing: 4) {
                RecorderSaveActionRow(title: model.recordingDestinationName, symbol: "folder.fill") { [model] in
                    model.chooseProjectsFolder()
                }
                TextField("自动命名", text: $model.recordingTitleDraft)
                    .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 34)
                    .background(RecorderStyle.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .accessibilityLabel(appLocalized("文件名"))
                if mode != .device {
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
                                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(RecorderStyle.base)
                                                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                                                .matchedGeometryEffect(id: "codec", in: codecSelection)
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(RecorderPlainPressButtonStyle())
                            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityValue(selected ? appLocalized("已选择") : "")
                        }
                    }
                    .padding(2)
                    .background(RecorderStyle.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .animation(RecorderMotion.quick, value: model.configuration.captureCodec)

                    Button {
                        withAnimation(Self.expand) { expandedQuality.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            EditorSymbol("sparkles.tv", size: 13).font(.system(size: 13, weight: .medium)).frame(width: 18)
                                .foregroundStyle(RecorderStyle.muted)
                            Text(appLocalized(model.configuration.captureResolutionLimit.rawValue))
                            Spacer()
                            EditorSymbol("chevron.down", size: 9).font(.system(size: 9, weight: .bold))
                                .foregroundStyle(RecorderStyle.faint)
                                .rotationEffect(.degrees(expandedQuality ? 180 : 0))
                        }
                        .font(.appUI(size: 13)).padding(.horizontal, 8).frame(height: 36)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(RecorderPlainPressButtonStyle())
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(appLocalized("画质"))
                    if expandedQuality {
                        VStack(spacing: 2) {
                            ForEach(CaptureResolutionLimit.allCases) { limit in
                                RecorderChoiceRow(title: limit.rawValue, selected: model.configuration.captureResolutionLimit == limit, isAlternative: true) {
                                    model.captureSetup.setResolutionLimit(limit)
                                    withAnimation(Self.expand) { expandedQuality = false }
                                }
                            }
                        }
                        .padding(.leading, 20)
                        // Rows fade in place while the rows below make room;
                        // nothing slides over the label above (EDT-065).
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.08)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                    }
                    RecorderSaveToggleRow(title: "隐藏桌面文件", symbol: "menubar.dock.rectangle", isOn: Binding(get: { model.configuration.hidesDesktopFiles }, set: { model.setHidesDesktopFiles($0) }))
                    RecorderSaveToggleRow(title: "隐藏 Dock", symbol: "dock.rectangle", isOn: Binding(get: { model.configuration.hidesDock }, set: { model.setHidesDock($0) }))
                }
                rule
                RecorderSaveActionRow(title: "打开项目…", symbol: "tray.full", showsChevron: false) { [model] in
                    model.openProjectPicker()
                }
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
        displayLayer.videoGravity = .resizeAspect
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
