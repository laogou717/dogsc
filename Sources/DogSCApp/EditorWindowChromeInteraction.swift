import AppKit
import SwiftUI

/// Restores native title-bar behavior in the editor's custom, full-size
/// toolbar. Controls remain above this view and keep their own hit targets;
/// only otherwise-empty chrome reaches this AppKit surface.
struct EditorWindowChromeInteraction: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorWindowChromeView {
        EditorWindowChromeView()
    }

    func updateNSView(
        _ nsView: EditorWindowChromeView,
        context: Context
    ) {}
}

@MainActor
final class EditorWindowChromeView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        if event.clickCount == 2 {
            EditorWindowTitlebarDoubleClickAction.perform(on: window)
            return
        }

        // The editor extends SwiftUI content through a transparent title bar,
        // so AppKit cannot infer a drag region from an empty SwiftUI Spacer.
        // Forward blank-chrome drags to the owning window explicitly.
        window.performDrag(with: event)
    }

}

@MainActor
enum EditorWindowTitlebarDoubleClickAction {
    static func perform(on window: NSWindow) {
        switch EditorTitlebarDoubleClickPreference.current {
        case .zoom:
            window.performZoom(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .none:
            break
        }
    }
}

private enum EditorTitlebarDoubleClickPreference {
    case zoom
    case minimize
    case none

    /// macOS currently exposes this choice in Desktop & Dock. Newer systems
    /// store an action string, while older systems expose only the legacy
    /// minimize Boolean. Read both so the custom title bar follows the same
    /// preference across OS versions instead of imposing an app-specific one.
    static var current: Self {
        let defaults = UserDefaults.standard

        if let rawAction = defaults.string(forKey: "AppleActionOnDoubleClick")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch rawAction {
            case "minimize", "miniaturize":
                return .minimize
            case "none", "do nothing", "donothing":
                return .none
            case "maximize", "zoom", "fill":
                return .zoom
            default:
                break
            }
        }

        if defaults.object(forKey: "AppleMiniaturizeOnDoubleClick") != nil {
            return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
                ? .minimize
                : .zoom
        }

        // AppKit's long-standing title-bar default is zoom. This fallback is
        // used only when neither the modern nor legacy preference is present.
        return .zoom
    }
}
