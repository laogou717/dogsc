import AppKit
import SwiftUI

/// SwiftUI's root focus-effect policy does not suppress NSSwitch's native
/// AppKit ring. Keep the native switch and responder, with the same neutral,
/// keyboard-only capsule cue used by the other recorder controls.
struct RecorderInputToggleStyle: ToggleStyle {
    let title: String

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, title: title)
    }

    private struct Surface: View {
        let configuration: Configuration
        let title: String
        @State private var hasFocus = false

        var body: some View {
            HStack(spacing: 8) {
                configuration.label.accessibilityHidden(true)
                Spacer(minLength: 8)
                RecorderInputSwitch(isOn: configuration.$isOn, title: title) {
                    hasFocus = $0
                }
                .fixedSize()
                .appKeyboardFocus(in: Capsule(), color: RecorderStyle.ink.opacity(0.40), isFocused: hasFocus)
            }
        }
    }
}

private struct RecorderInputSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    let title: String
    let onFocusChange: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    func makeNSView(context: Context) -> RecorderInputSwitchNSView {
        let control = RecorderInputSwitchNSView()
        control.focusRingType = .none
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: RecorderInputSwitchNSView, context: Context) {
        context.coordinator.isOn = $isOn
        control.onFocusChange = onFocusChange
        control.isEnabled = isEnabled
        control.state = isOn ? .on : .off
        control.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderInputSwitchNSView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func changed(_ sender: NSSwitch) { isOn.wrappedValue = sender.state == .on }
    }
}

private final class RecorderInputSwitchNSView: NSSwitch {
    var onFocusChange: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { reportFocus() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { reportFocus() }
        return accepted
    }

    private func reportFocus() {
        // Avoid publishing SwiftUI state during the native view update. Read
        // the current responder when delivered, so rapid Tab does not leave
        // a stale cue or manufacture another focus target.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFocusChange(self.window?.firstResponder === self)
        }
    }
}
