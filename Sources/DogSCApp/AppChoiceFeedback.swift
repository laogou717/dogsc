import AppKit
import SwiftUI

// Shared recorder/settings/editor selection feedback. Layout and hit regions
// stay fixed while only the designated foreground content responds.
private struct AppChoicePress: Sendable {
    var pressed = false
    var wasSelected = false
}

private struct AppChoicePressKey: EnvironmentKey {
    static let defaultValue = AppChoicePress()
}

private extension EnvironmentValues {
    var appChoicePress: AppChoicePress {
        get { self[AppChoicePressKey.self] }
        set { self[AppChoicePressKey.self] = newValue }
    }
}

/// A native Button owns activation; the feedback joins a short tap and a held
/// press into one response without delaying or duplicating the actual action.
struct AppChoiceButton<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    let label: Label
    @StateObject private var feedback = AppChoiceFeedback()
    @Environment(\.isEnabled) private var isEnabled

    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.isSelected = isSelected
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            // Capture the role before the action changes selection. Tap to
            // click and accessibility activation may skip isPressed entirely.
            feedback.activate(wasSelected: isSelected)
            action()
        } label: {
            label
        }
        .buttonStyle(AppChoicePressStyle(isSelected: isSelected, feedback: feedback))
        .onDisappear { feedback.reset() }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard isEnabled,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            feedback.activate(wasSelected: isSelected)
            action()
            return .handled
        }
    }
}

@MainActor
private final class AppChoiceFeedback: ObservableObject {
    @Published private(set) var press = AppChoicePress()
    private var nativeIsPressed = false
    private var nativeReleaseTime: TimeInterval?
    private var nativeActivationHandled = false
    private var feedbackStartedAt: TimeInterval = 0
    private var releaseTask: Task<Void, Never>?
    private let minimumPressDuration: TimeInterval = 0.10

    func trackPress(_ pressed: Bool, wasSelected: Bool) {
        guard pressed != nativeIsPressed else { return }
        nativeIsPressed = pressed
        if pressed {
            nativeReleaseTime = nil
            nativeActivationHandled = false
            begin(wasSelected: wasSelected)
        } else {
            nativeReleaseTime = ProcessInfo.processInfo.systemUptime
            release()
        }
    }

    func activate(wasSelected: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // Button action and its isPressed=false observation can arrive in
        // either order. Consume the existing native press once in both cases.
        let justReleased = nativeReleaseTime.map { now - $0 < 0.05 } ?? false
        if !nativeActivationHandled && (nativeIsPressed || justReleased) {
            nativeActivationHandled = true
            return
        }
        nativeActivationHandled = true
        begin(wasSelected: wasSelected)
        release()
    }

    func reset() {
        releaseTask?.cancel()
        releaseTask = nil
        nativeIsPressed = false
        nativeReleaseTime = nil
        nativeActivationHandled = false
        press = AppChoicePress()
    }

    private func begin(wasSelected: Bool) {
        releaseTask?.cancel()
        releaseTask = nil
        feedbackStartedAt = ProcessInfo.processInfo.systemUptime
        press = AppChoicePress(pressed: true, wasSelected: wasSelected)
    }

    private func release() {
        releaseTask?.cancel()
        let remaining = minimumPressDuration - (ProcessInfo.processInfo.systemUptime - feedbackStartedAt)
        guard remaining > 0 else {
            press.pressed = false
            releaseTask = nil
            return
        }
        // Only the visual release waits. Long holds release immediately;
        // short presses get enough visible time to reach the same light dip.
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.press.pressed = false
            self.releaseTask = nil
        }
    }
}

private struct AppChoicePressStyle: ButtonStyle {
    let isSelected: Bool
    let feedback: AppChoiceFeedback

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, isSelected: isSelected, feedback: feedback)
    }

    private struct PressBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @ObservedObject var feedback: AppChoiceFeedback
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .environment(\.appChoicePress, feedback.press)
                .opacity(isEnabled ? 1 : 0.45)
                .onChange(of: configuration.isPressed) { _, pressed in
                    feedback.trackPress(pressed && isEnabled, wasSelected: isSelected)
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { feedback.reset() }
                }
        }
    }
}

/// Apply to the icon/text group, inside its stable padding and hit area.
/// Current choice: both move together. Other choice: this group stays still.
struct AppChoiceContentFeedback: ViewModifier {
    @Environment(\.appChoicePress) private var press

    func body(content: Content) -> some View {
        let engaged = press.pressed && press.wasSelected
        content
            .scaleEffect(engaged && !RecorderMotion.reduces ? 0.96 : 1)
            .animation(engaged ? .easeOut(duration: 0.09) : RecorderMotion.quick, value: engaged)
    }
}

/// Other choice: only the glyph responds while held, then springs back on
/// release. No second, action-triggered bounce after the mouse is already up.
struct AppChoiceIconFeedback: ViewModifier {
    @Environment(\.appChoicePress) private var press

    func body(content: Content) -> some View {
        let engaged = press.pressed && !press.wasSelected
        content
            .scaleEffect(engaged && !RecorderMotion.reduces ? 0.90 : 1)
            .animation(engaged ? .easeOut(duration: 0.09) : RecorderMotion.quick, value: engaged)
    }
}
