import AppKit
import SwiftUI

@MainActor
enum AgentAttachmentPasteboard {
    enum Content {
        case files([URL])
        case image(NSImage)
    }

    static func read(_ pasteboard: NSPasteboard) -> Content? {
        let supported = AgentChatModel.imageExtensions.union(AgentChatModel.textExtensions)
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter {
                $0.isFileURL && supported.contains($0.pathExtension.lowercased())
            }
        if !urls.isEmpty { return .files(urls) }
        if let image = NSImage(pasteboard: pasteboard) { return .image(image) }
        return nil
    }
}

/// Handle composer shortcuts before SwiftUI's field editor treats Return as
/// submission or consumes image paste. IME confirmation remains native.
struct AgentComposerInputBridge: NSViewRepresentable {
    let isFocused: Bool
    let onSubmit: @MainActor () -> Void
    let onPaste: @MainActor () -> Bool

    func makeNSView(context: Context) -> AgentComposerInputAnchor { AgentComposerInputAnchor() }
    func updateNSView(_ view: AgentComposerInputAnchor, context: Context) {
        view.isFocused = isFocused
        view.onSubmit = onSubmit
        view.onPaste = onPaste
    }
    static func dismantleNSView(_ view: AgentComposerInputAnchor, coordinator: ()) { view.invalidate() }
}

final class AgentComposerInputAnchor: NSView {
    var isFocused = false
    var onSubmit: @MainActor () -> Void = {}
    var onPaste: @MainActor () -> Bool = { false }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidate()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown, isFocused, !isHiddenOrHasHiddenAncestor,
              let window, event.window === window,
              let editor = window.firstResponder as? NSTextView, editor.isEditable,
              convert(bounds.intersection(visibleRect), to: nil).intersects(
                editor.convert(editor.bounds.intersection(editor.visibleRect), to: nil)) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 36 || event.keyCode == 76 {
            guard !editor.hasMarkedText() else { return event }
            if modifiers == [.shift] {
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return nil
            }
            if modifiers.isEmpty {
                if !event.isARepeat { onSubmit() }
                return nil
            }
        }
        if event.charactersIgnoringModifiers?.lowercased() == "v", modifiers == [.command] {
            return onPaste() ? nil : event
        }
        return event
    }
}
