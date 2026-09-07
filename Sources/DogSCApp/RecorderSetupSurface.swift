import AppKit
import RecorderCore
import SwiftUI

struct RecorderSetupSurface: View {
    @ObservedObject var model: AppModel
    @State private var pressedSource: CaptureSource?
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let sources: [(CaptureSource, String, String)] = [
        (.display, "显示器", "display"), (.window, "窗口", "macwindow"),
        (.area, "区域", "rectangle.dashed"), (.device, "设备", "iphone")
    ]
    private var activeSource: CaptureSource? { model.selectedCaptureSource ?? model.confirmedCaptureSource }
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(sources, id: \.0) { source, label, symbol in
                    ZStack {
                        if activeSource == source {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: [.white, RecorderStyle.mintWash], startPoint: .top, endPoint: .bottom))
                                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 1.2) }
                                .shadow(color: RecorderStyle.lift, radius: 4, y: 2)
                                .matchedGeometryEffect(id: "capture-source", in: selection)
                        }
                        VStack(spacing: 5) {
                            Image(systemName: symbol).font(.appUI(size: 21, weight: .regular))
                            Text(appLocalized(label)).font(.appUI(size: 11, weight: activeSource == source ? .medium : .regular))
                        }
                        .scaleEffect(pressedSource == source ? 0.94 : 1)
                        .animation(.easeOut(duration: 0.13), value: pressedSource)
                        .foregroundStyle(activeSource == source ? RecorderStyle.ink : RecorderStyle.muted)
                        .accessibilityHidden(true)
                        RecorderActionTrigger(action: {
                            RecorderPopoverPresenter.shared.dismiss()
                            model.selectCaptureSource(source)
                        }, accessibilityLabel: appLocalized(label), accessibilityIdentifier: RecorderCaptureSourceAccessibilityID.value(for: source), cornerRadius: 14, highlightOpacity: 0.06, onPressChange: { pressedSource = $0 ? source : nil })
                    }.frame(width: 56, height: 58)
                }
            }
            .padding(3)
            .firstUseTourTarget("recorder.source", in: .recorder, highlight: .recorderSources)
            .animation(reduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.88), value: activeSource)
            divider
            HStack(spacing: 10) {
                RecorderPopoverButton(id: "microphone", title: "麦克风", width: 42, height: 42) {
                    RecorderMicrophoneOrb(meter: model.microphoneInputLevel, enabled: model.configuration.recordsMicrophone)
                } panel: { RecorderInputPopover(model: model, kind: .microphone) }
                RecorderPopoverButton(id: "camera", title: "摄像头", width: 42, height: 42) {
                    RecorderInputOrb(symbol: "video", enabled: model.configuration.recordsCamera)
                } panel: { RecorderInputPopover(model: model, kind: .camera) }
                RecorderPopoverButton(id: "system-audio", title: "系统声音", width: 42, height: 42) {
                    RecorderInputOrb(symbol: "speaker.wave.2", enabled: model.configuration.recordsSystemAudio)
                } panel: { RecorderInputPopover(model: model, kind: .systemAudio) }
            }
            .firstUseTourTarget("recorder.inputs", in: .recorder, highlight: .recorderInputs)
            divider
            RecorderPopoverButton(id: "destination", title: "保存与录制配置", width: 154, height: 46, panelWidth: 350) {
                HStack(spacing: 9) {
                    Image(systemName: "folder").font(.appUI(size: 20))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保存到").font(.appUI(size: 10)).foregroundStyle(RecorderStyle.muted)
                        Text(model.recordingDestinationName).font(.appUI(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.appUI(size: 10, weight: .medium))
                }
                .foregroundStyle(RecorderStyle.ink).padding(.horizontal, 12).frame(width: 154, height: 46)
                .modifier(RecorderRaisedSurface(radius: 13))
            } panel: { RecorderSavePopover(model: model) }
            .firstUseTourTarget("recorder.save", in: .recorder, highlight: .rounded(13))
            Button {
                RecorderPopoverPresenter.shared.dismiss()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark").font(.appUI(size: 14, weight: .regular))
                    .foregroundStyle(RecorderStyle.ink).frame(width: 36, height: 36)
                    .modifier(RecorderRaisedSurface(radius: 18))
            }
            .buttonStyle(RecorderCirclePressStyle()).help("退出DogSC").accessibilityLabel("退出DogSC")
            .accessibilityIdentifier("recorder.setup.close")
        }
        .padding(.horizontal, 14)
        .frame(width: setupWindowWidth(), height: 80)
        .background(LinearGradient(colors: [.white, RecorderStyle.silver], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.92), lineWidth: 1) }
        .preferredColorScheme(.light)
        .firstUseTour(.recorder, enabled: model.phase == .setup && !model.showsRequiredPermissionGate)
    }
    private var divider: some View { Rectangle().fill(RecorderStyle.line).frame(width: 1, height: 34) }
}
