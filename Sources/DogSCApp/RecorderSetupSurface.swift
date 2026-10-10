import AppKit
import RecorderCore
import SwiftUI

/// The idle island. One wheel chooses what to record, three glyphs say which
/// inputs are live, and the red button goes and frames it. Everything else
/// lives behind the ellipsis.
struct RecorderSetupSurface: View {
    @ObservedObject var model: AppModel
    @AppStorage("recorder.capture-mode") private var storedMode = CaptureSource.display.rawValue
    @State private var rollsForward = true

    private var mode: CaptureSource {
        model.selectedCaptureSource ?? CaptureSource(rawValue: storedMode) ?? .display
    }

    var body: some View {
        HStack(spacing: 0) {
            wheel
                .firstUseTourTarget("recorder.source", in: .recorder, highlight: .rounded(20))

            HStack(spacing: 0) {
                RecorderPopoverButton(id: "microphone", title: "麦克风", width: 44, height: 44) {
                    RecorderMicrophoneGlyph(meter: model.microphoneInputLevel, enabled: model.configuration.recordsMicrophone)
                } panel: { RecorderInputPopover(model: model, kind: .microphone) }
                RecorderPopoverButton(id: "camera", title: "摄像头", width: 44, height: 44) {
                    RecorderInputGlyph(on: "video.fill", off: "video.slash.fill", enabled: model.configuration.recordsCamera)
                } panel: { RecorderInputPopover(model: model, kind: .camera) }
                RecorderPopoverButton(id: "system-audio", title: "系统声音", width: 44, height: 44) {
                    RecorderInputGlyph(on: "speaker.wave.2.fill", off: "speaker.slash.fill", enabled: model.configuration.recordsSystemAudio)
                } panel: { RecorderInputPopover(model: model, kind: .systemAudio) }
            }
            .firstUseTourTarget("recorder.inputs", in: .recorder, highlight: .recorderInputs)
            .padding(.leading, 6)

            RecorderPopoverButton(id: "destination", title: "保存与录制配置", width: 44, height: 44, panelWidth: 300) {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RecorderStyle.muted)
                    .frame(width: 44, height: 44)
            } panel: { RecorderSavePopover(model: model) }
            .firstUseTourTarget("recorder.save", in: .recorder, highlight: .rounded(22))

            recordButton.padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .foregroundStyle(RecorderStyle.ink)
        .firstUseTour(.recorder, enabled: model.phase == .setup && !model.showsRequiredPermissionGate)
    }

    /// One mode at a time. Scrolling, the arrow keys or a click roll to the
    /// next; the island stretches to whatever name is showing.
    private var wheel: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                RecorderModeGlyph(mode: mode)
                Text(appLocalized(Self.label(for: mode))).font(.appUI(size: 13, weight: .semibold))
                    .fixedSize()
            }
            .id(mode)
            .transition(.asymmetric(
                insertion: .move(edge: rollsForward ? .bottom : .top).combined(with: .opacity),
                removal: .move(edge: rollsForward ? .top : .bottom).combined(with: .opacity)))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                .foregroundStyle(RecorderStyle.faint)
        }
        .padding(.leading, 14).padding(.trailing, 11)
        .frame(height: 40)
        .background(RecorderStyle.well, in: Capsule())
        .clipShape(Capsule())
        .overlay {
            RecorderModeWheelInput(label: appLocalized(Self.label(for: mode))) { step in roll(step) }
        }
        .help(appLocalized(Self.label(for: mode)))
    }

    private var recordButton: some View {
        RecorderNativeActionButton(accessibilityLabel: appLocalized("开始录制"),
            accessibilityIdentifier: RecorderCaptureSourceAccessibilityID.value(for: mode), isEnabled: true,
            width: 44, height: 44, cornerRadius: 22, highlightOpacity: 0, action: {
                RecorderPopoverPresenter.shared.dismiss()
                model.selectCaptureSource(mode)
            }) {
            ZStack {
                Circle().fill(RecorderStyle.recording).frame(width: 36, height: 36)
                Circle().fill(.white).frame(width: 12, height: 12)
            }
            .frame(width: 44, height: 44)
        }
    }

    private func roll(_ step: Int) {
        let all = CaptureSource.allCases
        guard step != 0, let index = all.firstIndex(of: mode) else { return }
        let next = all[(index + step % all.count + all.count) % all.count]
        rollsForward = step > 0
        RecorderPopoverPresenter.shared.dismiss()
        withAnimation(RecorderMotion.settle) { storedMode = next.rawValue }
    }

    private static func label(for mode: CaptureSource) -> String {
        switch mode {
        case .display: "显示器"
        case .window: "窗口"
        case .area: "区域"
        case .device: "设备"
        }
    }
}

/// The app's own pictograms for the four things it can record, drawn on one
/// grid with one stroke so they read as a family.
struct RecorderModeGlyph: View {
    let mode: CaptureSource
    var size: CGFloat = 18
    var body: some View {
        RecorderModeShape(mode: mode)
            .stroke(style: StrokeStyle(lineWidth: size / 11, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct RecorderModeShape: Shape {
    let mode: CaptureSource
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 18
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * u, y: rect.minY + y * u, width: w * u, height: h * u)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        var path = Path()
        switch mode {
        case .display:
            path.addRoundedRect(in: r(1.5, 2.5, 15, 10), cornerSize: CGSize(width: 2.4 * u, height: 2.4 * u), style: .continuous)
            path.move(to: p(6, 15.6)); path.addLine(to: p(12, 15.6))
        case .window:
            path.addRoundedRect(in: r(1.5, 3, 15, 12), cornerSize: CGSize(width: 2.6 * u, height: 2.6 * u), style: .continuous)
            path.move(to: p(4.6, 6.2)); path.addLine(to: p(7.4, 6.2))
        case .area:
            path.addPath(CaptureViewfinder(inset: 2 * u, arm: 4.4 * u, radius: 2.4 * u).path(in: rect))
        case .device:
            path.addRoundedRect(in: r(5, 1.5, 8, 15), cornerSize: CGSize(width: 2.4 * u, height: 2.4 * u), style: .continuous)
            path.move(to: p(8, 13.6)); path.addLine(to: p(10, 13.6))
        }
        return path
    }
}

/// The wheel's input surface: scroll to roll either way, click or press the
/// arrow keys to step. One AppKit view so the first click lands even while
/// another app is frontmost.
private struct RecorderModeWheelInput: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let label: String
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {
        _ = locale
        view.onStep = onStep
        view.setAccessibilityLabel(appLocalized("开始录制"))
        view.setAccessibilityValue(label)
    }

    final class WheelView: NSView {
        var onStep: (Int) -> Void = { _ in }
        private var travel: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.incrementor)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { onStep(1) }

        override func scrollWheel(with event: NSEvent) {
            // A trackpad reports many small deltas; a mouse wheel reports lines.
            if event.phase == .began { travel = 0 }
            travel += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14
            let notch: CGFloat = 26
            while travel >= notch { travel -= notch; onStep(-1) }
            while travel <= -notch { travel += notch; onStep(1) }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 125, 124: onStep(1)
            case 126, 123: onStep(-1)
            default: super.keyDown(with: event)
            }
        }
        override func accessibilityPerformIncrement() -> Bool { onStep(1); return true }
        override func accessibilityPerformDecrement() -> Bool { onStep(-1); return true }
        override func accessibilityPerformPress() -> Bool { onStep(1); return true }
    }
}

/// An input says whether it will be recorded with its own shape: a filled
/// glyph when live, a struck-through one when off. No badge, no tinted disc.
struct RecorderInputGlyph: View {
    let on: String
    let off: String
    var enabled = true
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: enabled ? on : off)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(enabled ? RecorderStyle.ink : RecorderStyle.faint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
            .animation(RecorderMotion.quick, value: enabled)
    }
}

/// The microphone also shows that it can hear: a ring that opens with the
/// live input level and rests when the room is quiet.
struct RecorderMicrophoneGlyph: View {
    @ObservedObject var meter: LiveMicrophoneLevelState
    var enabled: Bool

    var body: some View {
        let level = enabled ? min(max(meter.value, 0), 1) : 0
        ZStack {
            Circle()
                .strokeBorder(RecorderStyle.mint, lineWidth: 1.5)
                .frame(width: 30, height: 30)
                .scaleEffect(0.78 + 0.34 * level)
                .opacity(min(1, level * 4))
                .animation(RecorderMotion.reduces ? nil : .spring(response: 0.2, dampingFraction: 0.62), value: level)
            RecorderInputGlyph(on: "mic.fill", off: "mic.slash.fill", enabled: enabled)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(appLocalized("输入电平"))
        .accessibilityValue("\(Int(meter.value * 100))%")
    }
}

/// A handful of bars that move with the microphone. Used wherever a compact
/// "this is being heard" signal is enough.
struct RecorderLevelBars: View {
    @ObservedObject var meter: LiveMicrophoneLevelState
    var active = true
    var count = 4
    var height: CGFloat = 14
    private static let response: [Double] = [0.62, 1, 0.8, 0.5, 0.9, 0.7, 0.55, 0.95]

    var body: some View {
        let level = active ? min(max(meter.value, 0), 1) : 0
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let reach = min(1, level * 1.6 * Self.response[index % Self.response.count])
                Capsule()
                    .fill(level > 0.02 ? RecorderStyle.mint : RecorderStyle.faint)
                    .frame(width: 2.5, height: 3 + (height - 3) * reach)
            }
        }
        .frame(height: height)
        .animation(RecorderMotion.reduces ? nil : .spring(response: 0.18, dampingFraction: 0.6), value: level)
        .accessibilityHidden(true)
    }
}
