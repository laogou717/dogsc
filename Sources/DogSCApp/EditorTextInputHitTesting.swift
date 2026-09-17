import AppKit
import SwiftUI

/// A live window-space region, independent of SwiftUI's private text-field
/// wrappers and AppKit's shared field editor. It never intercepts mouse events.
@MainActor
final class EditorTextInputRegion {
    weak var view: NSView?

    func contains(_ event: NSEvent) -> Bool {
        guard let view, let window = view.window, event.window === window else { return false }
        // SwiftUI's unclipped hosting ancestors can report a visibleRect larger
        // than this anchor. Restrict it to the actual input's bounds as well.
        return view.bounds.intersection(view.visibleRect)
            .contains(view.convert(event.locationInWindow, from: nil))
    }
}

struct EditorTextInputRegionAnchor: NSViewRepresentable {
    let region: EditorTextInputRegion

    func makeNSView(context: Context) -> EditorTextInputAnchorView {
        let view = EditorTextInputAnchorView()
        region.view = view
        return view
    }

    func updateNSView(_ view: EditorTextInputAnchorView, context: Context) {
        region.view = view
    }
}

final class EditorTextInputAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
enum EditorTextInputHitTesting {
    static func targetsTextInput(at pointInWindow: NSPoint, in window: NSWindow) -> Bool {
        // A field editor may be reparented outside its NSTextField while active.
        // Protect caret placement and selection even if hitTest sees chrome.
        if let editor = window.firstResponder as? NSTextView, editor.isEditable,
           editor.bounds.intersection(editor.visibleRect)
               .contains(editor.convert(pointInWindow, from: nil)) {
            return true
        }
        guard let content = window.contentView else { return false }
        // hitTest takes its receiver's SUPERview coordinates, not its local
        // bounds; a full-size title bar need not begin at the content origin.
        let point = content.superview?.convert(pointInWindow, from: nil) ?? pointInWindow
        var candidate = content.hitTest(point)
        while let view = candidate {
            if let field = view as? NSTextField, field.isEditable { return true }
            if let editor = view as? NSTextView, editor.isEditable { return true }
            candidate = view.superview
        }
        return false
    }
}
