import AppKit
import QuartzCore
import SwiftUI

/// The recording workspace deliberately has one material across all states.
enum RecorderStyle {
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.19)
    static let muted = Color(red: 0.47, green: 0.50, blue: 0.52)
    static let mint = Color(red: 0.22, green: 0.70, blue: 0.47)
    static let mintWash = Color(red: 0.84, green: 0.95, blue: 0.90)
    static let silver = Color(red: 0.965, green: 0.973, blue: 0.977)
    static let line = Color.black.opacity(0.065)
    static let lift = Color(red: 0.17, green: 0.23, blue: 0.27).opacity(0.08)
}

struct RecorderRaisedSurface: ViewModifier {
    var radius: CGFloat = EditorInterfaceRadius.group
    var selected = false
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selected ? RecorderStyle.mintWash : .white)
                .shadow(color: RecorderStyle.lift.opacity(0.4), radius: 3, y: 1)
                .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(RecorderStyle.line, lineWidth: 0.75) }
        }
    }
}

struct RecorderButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .foregroundStyle(primary ? .white : RecorderStyle.ink)
            .background(primary ? AnyShapeStyle(Color(white: pressed ? 0.16 : 0.24)) : AnyShapeStyle(Color.white), in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).strokeBorder(RecorderStyle.line, lineWidth: 0.75) }
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous),
                              color: primary ? .white.opacity(0.65) : EditorTheme.chrome(0.40))
            .shadow(color: RecorderStyle.lift.opacity(pressed ? 0.2 : 0.4), radius: pressed ? 1 : 3, y: 1)
            .modifier(RecorderPressFeedback(isPressed: pressed, cornerRadius: EditorInterfaceRadius.control))
    }
}

/// Keep compact configuration actions inside their existing hit bounds while
/// sharing the toolbar's short pressed settle and reduced-motion behavior.
struct RecorderPlainPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(RecorderPressFeedback(isPressed: configuration.isPressed,
                                           isEnabled: isEnabled, cornerRadius: cornerRadius))
    }
}

/// Artwork reacts inside its existing native hit target. The inset edge and
/// shade remain visible when accessibility settings suppress physical motion.
struct RecorderPressFeedback: ViewModifier {
    let isPressed: Bool
    var isEnabled = true
    var cornerRadius: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pressed = isPressed && isEnabled
        return content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.black.opacity(pressed ? 0.075 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.black.opacity(0.15), .white.opacity(0.5)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
                    .opacity(pressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .offset(y: pressed && !reduceMotion ? 0.7 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.09 : 0.15), value: pressed)
            .animation(nil, value: reduceMotion)
    }
}

/// Each action keeps its press state through updates to the recording bar.
/// The original AppKit control still owns mouse-up actions and accessibility.
struct RecorderNativeActionButton<Label: View>: View {
    let accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    var isEnabled = true
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 10
    var highlightOpacity: Double = 0.04
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        ZStack {
            label()
                .frame(width: width, height: height)
                .modifier(RecorderPressFeedback(isPressed: pressed, isEnabled: isEnabled,
                                               cornerRadius: cornerRadius))
                .accessibilityHidden(true)
            RecorderActionTrigger(action: action, accessibilityLabel: accessibilityLabel,
                isEnabled: isEnabled, accessibilityIdentifier: accessibilityIdentifier,
                cornerRadius: cornerRadius, highlightOpacity: highlightOpacity,
                onPressChange: { pressed = $0 })
        }
        .frame(width: width, height: height)
        .opacity(isEnabled ? 1 : 0.4)
        .help(accessibilityLabel)
    }
}

struct RecorderInputOrb: View {
    let symbol: String
    var enabled = true
    var size: CGFloat = 42
    var level: Double = 0
    var showsStatus = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedLevel: Double = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Circle().fill(LinearGradient(colors: [.white, RecorderStyle.silver], startPoint: .top, endPoint: .bottom))
            Rectangle().fill(RecorderStyle.mint.opacity(0.25))
                .frame(height: size * displayedLevel)
                .opacity(displayedLevel > 0.015 ? 1 : 0)
            Image(systemName: symbol).font(.appUI(size: size * 0.46, weight: .regular))
                .foregroundStyle(enabled ? RecorderStyle.ink : RecorderStyle.muted)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(RecorderStyle.line, lineWidth: 0.6) }
        .shadow(color: RecorderStyle.lift.opacity(0.5), radius: 3, y: 1)
        .overlay(alignment: .bottomTrailing) {
            if showsStatus {
                Circle().fill(enabled ? RecorderStyle.mint : RecorderStyle.muted.opacity(0.5))
                    .frame(width: 6, height: 6).overlay { Circle().stroke(.white, lineWidth: 1.3) }.padding(1)
            }
        }
        .onAppear { displayedLevel = enabled ? min(max(level, 0), 1) : 0 }
        .onChange(of: level) { _, value in updateLevel(value) }
        .onChange(of: enabled) { _, _ in updateLevel(level) }
    }
    private func updateLevel(_ value: Double) {
        let target = enabled ? min(max(value, 0), 1) : 0
        withAnimation(reduceMotion ? nil : .easeOut(duration: target > displayedLevel ? 0.07 : 0.26)) { displayedLevel = target }
    }
}

struct RecorderMicrophoneOrb: View {
    @ObservedObject var meter: LiveMicrophoneLevelState
    var enabled: Bool
    var size: CGFloat = 42
    var body: some View {
        RecorderInputOrb(symbol: "mic", enabled: enabled, size: size, level: meter.value, showsStatus: false)
            .accessibilityLabel(appLocalized("输入电平"))
            .accessibilityValue("\(Int(meter.value * 100))%")
    }
}

struct RecorderSelectionEntrance: ViewModifier {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 7)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
            .onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.2)) { appeared = true } }
    }
}

@MainActor
func animateRecorderOverlayIn(_ window: NSWindow) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    window.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
    }
}

struct RecorderCirclePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }
    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.black.opacity(isEnabled && hovered && !configuration.isPressed ? 0.065 : 0))
                        .allowsHitTesting(false)
                }
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .modifier(RecorderPressFeedback(isPressed: configuration.isPressed, isEnabled: isEnabled,
                                               cornerRadius: 18))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        }
    }
}
