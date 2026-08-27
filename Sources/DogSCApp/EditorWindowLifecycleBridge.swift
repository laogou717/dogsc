import AppKit
import SwiftUI

/// Observes only the NSWindow that hosts this editor. A resign-key event ends
/// any transient editor gesture through the store's shared lifecycle policy,
/// so no half-finished preview survives a window switch.
struct EditorWindowLifecycleBridge: NSViewRepresentable {
    let projectTitle: String
    let onResignKey: @MainActor () -> Void

    func makeNSView(context: Context) -> WindowObservationView {
        WindowObservationView(
            projectTitle: projectTitle,
            onResignKey: onResignKey
        )
    }

    func updateNSView(_ view: WindowObservationView, context: Context) {
        view.projectTitle = projectTitle
        view.onResignKey = onResignKey
        view.updateWindowTitle()
    }

    static func dismantleNSView(_ view: WindowObservationView, coordinator: Void) {
        view.invalidate()
    }
}

final class WindowObservationView: NSView {
    var projectTitle: String
    var onResignKey: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    init(
        projectTitle: String,
        onResignKey: @escaping @MainActor () -> Void
    ) {
        self.projectTitle = projectTitle
        self.onResignKey = onResignKey
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
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResignKey() }
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
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
