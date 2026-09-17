import AppKit
import SwiftUI

/// Apply at every app-owned presentation root, not at individual labels.
/// A button's focus effect belongs to the control, outside its ButtonStyle.
/// Text editing, the responder chain and accessibility remain native.
extension View {
    func appControlFocusAppearance() -> some View {
        modifier(AppControlFocusAppearance())
    }

    /// An inset, shape-matched keyboard cue; automatic first-button focus and
    /// pointer clicks do not leave a replacement ring behind.
    func appKeyboardFocus<Outline: InsettableShape>(
        in outline: Outline,
        color: Color = EditorTheme.chrome(0.40)
    ) -> some View {
        modifier(AppKeyboardFocusCue(outline: outline, color: color))
    }
}

private struct AppShowsKeyboardFocusKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var appShowsKeyboardFocus: Bool {
        get { self[AppShowsKeyboardFocusKey.self] }
        set { self[AppShowsKeyboardFocusKey.self] = newValue }
    }
}

private struct AppControlFocusAppearance: ViewModifier {
    @ObservedObject private var visibility = AppKeyboardFocusVisibility.shared
    @State private var isMounted = false

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .environment(\.appShowsKeyboardFocus, visibility.isVisible)
            .onAppear {
                guard !isMounted else { return }
                isMounted = true
                visibility.acquire()
            }
            .onDisappear {
                guard isMounted else { return }
                isMounted = false
                visibility.release()
            }
    }
}

private struct AppKeyboardFocusCue<Outline: InsettableShape>: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appShowsKeyboardFocus) private var showsKeyboardFocus
    let outline: Outline
    let color: Color

    func body(content: Content) -> some View {
        content.overlay {
            if isEnabled && isFocused && showsKeyboardFocus {
                outline.strokeBorder(color, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Observe only navigation keys and pointer-down events. Never consume an
/// event, inspect text, monitor pointer motion, or schedule per-frame work.
/// The one monitor lives only while an app-owned presentation is mounted.
@MainActor
private final class AppKeyboardFocusVisibility: ObservableObject {
    static let shared = AppKeyboardFocusVisibility()
    @Published private(set) var isVisible = false
    private var mountedRoots = 0
    private var monitor: Any?

    func acquire() {
        mountedRoots += 1
        setVisible(false)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if modifiers.isDisjoint(with: [.command, .control, .option]),
                       [48, 123, 124, 125, 126].contains(event.keyCode) {
                        self.setVisible(true)
                    }
                } else {
                    self.setVisible(false)
                }
            }
            return event
        }
    }

    func release() {
        mountedRoots = max(mountedRoots - 1, 0)
        guard mountedRoots == 0 else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}
