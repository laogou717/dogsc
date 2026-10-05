import AppKit
import SwiftUI

extension View {
    /// Space remains the workspace transport key. Only the focused menu
    /// trigger handles Return/Down, without adding a window-wide shortcut.
    func editorPopoverKeyboardEntry(action: @escaping () -> Void) -> some View {
        modifier(EditorPopoverKeyboardEntry(action: action))
    }

    /// Keep native placement, material and dismissal. Content roots leave the
    /// background to the popover so its body and arrow form one surface.
    /// Give even menus made entirely of scroll rows their own focus entry.
    func editorPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        establishesKeyboardEntry: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            EditorPopoverFocusScope(isPresented: isPresented,
                establishesKeyboardEntry: establishesKeyboardEntry, content: content())
        }
    }
}

private struct EditorPopoverKeyboardEntry: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.return, .downArrow], phases: .down) { press in
            guard isEnabled,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                return .ignored
            }
            action()
            return .handled
        }
    }
}

private struct EditorPopoverFocusScope<Content: View>: View {
    @Binding var isPresented: Bool
    let establishesKeyboardEntry: Bool
    let content: Content
    @FocusState private var entryHasFocus: Bool
    @State private var entryIsEnabled = true

    var body: some View {
        content
            .appControlFocusAppearance()
            .background(alignment: .topLeading) {
                // Establish keyboard entry without making the content itself
                // a control: nested text fields must keep their own responder.
                if establishesKeyboardEntry {
                    Color.clear.frame(width: 1, height: 1)
                        .focusable(entryIsEnabled, interactions: .edit)
                        .focused($entryHasFocus)
                        .defaultFocus($entryHasFocus, true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onAppear { entryHasFocus = true }
                        .onChange(of: entryHasFocus) { _, focused in
                            if !focused { entryIsEnabled = false }
                        }
                }
            }
            .focusSection()
            .onExitCommand { isPresented = false }
    }
}

extension NSEvent {
    /// AppKit can deliver a popover's keys through its owner window even when
    /// the first responder belongs to the presented window. Workspace monitors
    /// must leave these events to that responder instead of playing or editing.
    var targetsPresentedContent: Bool {
        guard let eventWindow = window else { return false }
        return MainActor.assumeIsolated {
            guard let responder = eventWindow.firstResponder as? NSView,
                  let responderWindow = responder.window else { return false }
            return responderWindow !== eventWindow
        }
    }
}
