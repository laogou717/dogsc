import AppKit
import SwiftUI

/// Observes only the NSWindow that hosts this editor. A resign-key event ends
/// any transient editor gesture through the store's shared lifecycle policy,
/// so no half-finished preview survives a window switch.
struct EditorWindowLifecycleBridge: NSViewRepresentable {
    let projectTitle: String
    let onResignKey: @MainActor () -> Void
    var onActivityChanged: @MainActor (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowObservationView {
        WindowObservationView(
            projectTitle: projectTitle,
            onResignKey: onResignKey,
            onActivityChanged: onActivityChanged
        )
    }

    func updateNSView(_ view: WindowObservationView, context: Context) {
        view.projectTitle = projectTitle
        view.onResignKey = onResignKey
        view.onActivityChanged = onActivityChanged
        view.updateWindowTitle()
    }

    static func dismantleNSView(_ view: WindowObservationView, coordinator: Void) {
        view.invalidate()
    }
}

final class WindowObservationView: NSView {
    var projectTitle: String
    var onResignKey: @MainActor () -> Void
    var onActivityChanged: @MainActor (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var lastActivity: Bool?

    init(
        projectTitle: String,
        onResignKey: @escaping @MainActor () -> Void,
        onActivityChanged: @escaping @MainActor (Bool) -> Void
    ) {
        self.projectTitle = projectTitle
        self.onResignKey = onResignKey
        self.onActivityChanged = onActivityChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        updateWindowTitle()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onResignKey() }
            })
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didExposeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            })
        }
        updateActivity()
    }

    private func updateActivity() {
        let active = NSApp.isActive && !NSApp.isHidden && window?.isMiniaturized == false
            && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        guard active != lastActivity else { return }
        lastActivity = active
        // NSView attachment may occur during SwiftUI's update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastActivity == active else { return }
            self.onActivityChanged(active)
        }
    }

    func updateWindowTitle() {
        guard let window else { return }
        let trimmed = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = trimmed.isEmpty
            ? "\(AppIdentity.displayName) 编辑器"
            : "\(trimmed) — \(AppIdentity.displayName)"
    }

    func invalidate() {
        stopObserving()
    }

    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        lastActivity = nil
    }
}

private struct EditorActivityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var editorIsActive: Bool {
        get { self[EditorActivityKey.self] }
        set { self[EditorActivityKey.self] = newValue }
    }
}
