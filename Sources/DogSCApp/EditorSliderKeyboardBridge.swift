import AppKit
import SwiftUI

/// The timeline has a window-level arrow-key monitor. Give an actively edited
/// slider a real responder so that monitor can defer to the control instead
/// of stepping the movie while the user adjusts a parameter.
struct EditorSliderKeyboardBridge: NSViewRepresentable {
    let requestsFocus: Bool
    let isEnabled: Bool
    let onFocusChange: (Bool) -> Void
    let onStep: (Double, Bool) -> Void

    func makeNSView(context: Context) -> EditorSliderKeyboardView {
        EditorSliderKeyboardView()
    }

    func updateNSView(_ view: EditorSliderKeyboardView, context: Context) {
        view.onFocusChange = onFocusChange
        view.onStep = onStep
        view.isEnabled = isEnabled
        if requestsFocus && !view.wasRequestingFocus {
            view.window?.makeFirstResponder(view)
        }
        view.wasRequestingFocus = requestsFocus
        if !isEnabled { view.releaseFocus() }
    }

    static func dismantleNSView(_ view: EditorSliderKeyboardView, coordinator: Void) {
        view.releaseFocus()
        view.removeMouseMonitor()
    }
}

@MainActor
final class EditorSliderKeyboardView: NSView {
    var isEnabled = true
    var wasRequestingFocus = false
    var onFocusChange: (Bool) -> Void = { _ in }
    var onStep: (Double, Bool) -> Void = { _, _ in }
    private var mouseMonitor: Any?

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        guard isEnabled else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.onFocusChange(true)
        }
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.window !== self.window ||
                !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.releaseFocus()
            }
            return event
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        removeMouseMonitor()
        DispatchQueue.main.async { [weak self] in self?.onFocusChange(false) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if isEnabled, modifiers.isEmpty, (123...126).contains(event.keyCode) {
            onStep(event.keyCode == 124 || event.keyCode == 126 ? 1 : -1,
                   event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    func releaseFocus() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}
