import AppKit
import AVFoundation
import RecorderCore
import SwiftUI

enum RecorderInputKind { case microphone, camera, systemAudio }

struct RecorderInputPopover: View {
    @ObservedObject var model: AppModel
    let kind: RecorderInputKind
    private var title: String {
        switch kind { case .microphone: "麦克风"; case .camera: "摄像头"; case .systemAudio: model.configuration.source == .device ? "设备声音" : "系统声音" }
    }
    private var enabled: Binding<Bool> {
        Binding(get: {
            switch kind { case .microphone: model.configuration.recordsMicrophone; case .camera: model.configuration.recordsCamera; case .systemAudio: model.configuration.recordsSystemAudio }
        }, set: { value in
            switch kind {
            case .microphone: model.setDefaultMicrophoneRecordingEnabled(value)
            case .camera: model.selectCamera(value ? model.availableCameras.first : nil)
            case .systemAudio: model.setDefaultSystemAudioRecordingEnabled(value)
            }
        })
    }
    var body: some View {
        RecorderPopoverSurface {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(appLocalized(title), isOn: enabled)
                    .toggleStyle(RecorderInputToggleStyle(title: appLocalized(title)))
                    .font(.appUI(size: 14, weight: .medium))
                switch kind {
                case .microphone: microphone
                case .camera: camera
                case .systemAudio: systemAudio
                }
            }
        }
    }
    private var microphone: some View {
        VStack(spacing: 10) {
            deviceList(model.availableMicrophones, symbol: "mic", selectedID: model.configuration.microphoneDeviceID, action: model.selectMicrophone)
            RecorderMicrophoneOrb(meter: model.microphoneInputLevel, enabled: model.configuration.recordsMicrophone, size: 70).padding(.top, 8)
            Text("输入电平").font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
            refresh
        }
    }
    private var camera: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceList(model.availableCameras, symbol: "video", selectedID: model.configuration.cameraDeviceID, action: model.selectCamera)
            if model.configuration.recordsCamera {
                RecorderCameraPreview(sink: model.configurationCameraFrameSink, mirrored: model.recordingCameraMirrored)
                    .frame(height: 142).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if model.cameraRuntimeFormat == nil {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(RecorderStyle.silver)
                        }
                    }
                Toggle("镜像画面", isOn: $model.recordingCameraMirrored)
                    .toggleStyle(RecorderInputToggleStyle(title: appLocalized("镜像画面")))
                if let runtime = model.cameraRuntimeFormat {
                    Text(runtime.label).font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                }
                DisclosureGroup("采集分辨率") {
                    RecorderChoiceRow(title: "自动", selected: model.configuration.cameraCaptureResolution == nil) { model.selectCameraCaptureResolution(nil) }
                    ForEach(model.availableCameraResolutions) { size in
                        RecorderChoiceRow(title: size.label, selected: model.configuration.cameraCaptureResolution == size) { model.selectCameraCaptureResolution(size) }
                    }
                }.font(.appUI(size: 12))
            }
            Button {
                RecorderPopoverPresenter.shared.dismiss()
                CaptureDeviceCatalog.showSystemVideoEffects()
            } label: {
                Text("系统视频效果…").font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                    .padding(.horizontal, 8).frame(minHeight: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 8))
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
            refresh
        }
    }
    private var systemAudio: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.configuration.source == .device {
                Text("录制所选设备的声音").foregroundStyle(RecorderStyle.muted)
            } else {
                RecorderChoiceRow(title: "全部系统声音", symbol: "speaker.wave.2", selected: model.configuration.systemAudioScope == .all) {
                    model.setDefaultSystemAudioRecordingEnabled(true, scope: .all)
                }
                RecorderChoiceRow(title: "所选窗口 App", symbol: "macwindow", selected: model.configuration.systemAudioScope == .selectedApplication,
                                  enabled: model.configuration.selectedApplicationBundleIdentifier != nil,
                                  subtitle: model.configuration.selectedApplicationName ?? appLocalized("先选择要录制的窗口")) {
                    model.setDefaultSystemAudioRecordingEnabled(true, scope: .selectedApplication)
                }
            }
        }.disabled(!model.configuration.recordsSystemAudio).opacity(model.configuration.recordsSystemAudio ? 1 : 0.45)
    }
    private func deviceList(_ devices: [CaptureDeviceInfo], symbol: String, selectedID: String?, action: @escaping (CaptureDeviceInfo?) -> Void) -> some View {
        VStack(spacing: 2) {
            if devices.isEmpty {
                Text("未发现设备").foregroundStyle(RecorderStyle.muted).padding(.vertical, 14)
            }
            ForEach(devices) { device in
                RecorderChoiceRow(title: device.name, symbol: symbol, selected: selectedID == device.id) { action(device) }
            }
        }
    }
    private var refresh: some View {
        Button { model.refreshCaptureDevicesInBackground() } label: {
            Label("刷新设备", systemImage: "arrow.clockwise").font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                .padding(.horizontal, 8).frame(minHeight: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 8))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 3)
    }
}

struct RecorderSavePopover: View {
    @ObservedObject var model: AppModel
    @State private var expandedQuality = false
    var body: some View {
        RecorderPopoverSurface(width: 350) {
            VStack(alignment: .leading, spacing: 15) {
                Text("保存到").font(.appUI(size: 14, weight: .medium))
                RecorderSaveActionRow(title: model.recordingDestinationName, symbol: "folder", detail: "更改位置…") { [model] in
                    RecorderPopoverPresenter.shared.dismissAndPerform { model.chooseProjectsFolder() }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RecorderStyle.line).allowsHitTesting(false) }
                HStack {
                    Text("文件名").frame(width: 52, alignment: .leading)
                    TextField("自动命名", text: $model.recordingTitleDraft)
                        .textFieldStyle(.plain).padding(9).background(.white, in: RoundedRectangle(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RecorderStyle.line) }
                }
                if model.configuration.source == .device {
                    Text("设备录制保留原始格式与分辨率").font(.appUI(size: 12)).foregroundStyle(RecorderStyle.muted)
                } else {
                    HStack {
                        Text("格式").frame(width: 52, alignment: .leading)
                        HStack(spacing: 2) {
                            ForEach(CaptureCodec.allCases) { codec in
                                Button { model.captureSetup.setCaptureCodec(codec) } label: {
                                    Text(codec == .proRes422 ? "ProRes" : codec.rawValue)
                                        .font(.appUI(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(model.configuration.captureCodec == codec ? RecorderStyle.mintWash : .clear, in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 8))
                                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityValue(model.configuration.captureCodec == codec ? appLocalized("已选择") : "")
                            }
                        }.padding(3).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
                    }
                    if model.configuration.captureCodec == .h264 {
                        Text("H.264 使用最高 4K 的兼容分辨率。").font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                    }
                    HStack {
                        Text("画质").frame(width: 52, alignment: .leading)
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { expandedQuality.toggle() }
                        } label: {
                            HStack { Text(appLocalized(model.configuration.captureResolutionLimit.rawValue)); Spacer(); Image(systemName: "chevron.down").rotationEffect(.degrees(expandedQuality ? 180 : 0)) }
                                .font(.appUI(size: 12)).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 9))
                        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 9))
                    }
                    if expandedQuality {
                        VStack(spacing: 2) {
                            ForEach(CaptureResolutionLimit.allCases) { limit in
                                RecorderChoiceRow(title: limit.rawValue, selected: model.configuration.captureResolutionLimit == limit) {
                                    model.captureSetup.setResolutionLimit(limit)
                                    withAnimation(.easeOut(duration: 0.18)) { expandedQuality = false }
                                }
                            }
                        }.padding(.leading, 60)
                    }
                }
                Divider()
                VStack(spacing: 2) {
                    projectAction("打开项目…", symbol: "folder") { model.openProjectPicker() }
                    projectAction("继续上次项目", symbol: "clock.arrow.circlepath", enabled: !model.recentProjects.isEmpty) {
                        model.openMostRecentProject()
                    }
                    if !model.recoverableProjects.isEmpty {
                        projectAction("恢复中断录制", symbol: "arrow.counterclockwise") { model.recoverMostRecentProject() }
                    }
                    if !model.captureReadiness.hasScreenRecordingPermission {
                        projectAction("打开录屏权限设置", symbol: "lock.shield") { model.openScreenRecordingSettings() }
                    }
                }
                VStack(spacing: 2) {
                    RecorderSaveToggleRow(title: "隐藏桌面文件", isOn: Binding(get: { model.configuration.hidesDesktopFiles }, set: { model.setHidesDesktopFiles($0) }))
                    RecorderSaveToggleRow(title: "隐藏 Dock", isOn: Binding(get: { model.configuration.hidesDock }, set: { model.setHidesDock($0) }))
                }
                Text("同名录制会自动编号，不覆盖已有文件。")
                    .font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                if let warning = model.captureReadiness.frameRateWarningText {
                    Text(warning).font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                }
            }
        }
    }

    private func projectAction(_ title: String, symbol: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) -> some View {
        RecorderSaveActionRow(title: title, symbol: symbol, enabled: enabled) {
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
        layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
        displayLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(displayLayer)
        sink.attach(displayLayer.sampleBufferRenderer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
