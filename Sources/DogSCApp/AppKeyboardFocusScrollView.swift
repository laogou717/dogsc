import AppKit
import SwiftUI

/// Kept by the owner of a set of tasks. Native scrolling updates this memory
/// without invalidating the SwiftUI inspector on every wheel event.
@MainActor
final class AppScrollPositionMemory<Context: Hashable> {
    private var positions: [Context: AppScrollPosition] = [:]

    func position(for context: Context) -> AppScrollPosition {
        if let position = positions[context] { return position }
        let position = AppScrollPosition()
        positions[context] = position
        return position
    }
}

@MainActor
final class AppScrollPosition {
    fileprivate var topOffset: CGFloat = 0
}

/// Reveal keyboard focus with the smallest scroll needed. Pointer interaction
/// and controls outside this scroll view keep their existing behavior.
struct AppKeyboardFocusScrollView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content
    private let savedPosition: AppScrollPosition?

    init(
        savedPosition: AppScrollPosition? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.savedPosition = savedPosition
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content.focusSection()
                    .background {
                        if let savedPosition {
                            AppScrollPositionBridge(position: savedPosition)
                        }
                    }
            }
                .environment(\.appKeyboardFocusScrollEnabled, true)
                .overlayPreferenceValue(AppKeyboardFocusScrollTargetKey.self) { target in
                    GeometryReader { viewport in
                        let request = AppKeyboardFocusScrollRequest(
                            target: target,
                            viewportSize: viewport.size
                        )
                        Color.clear
                            .task(id: request) {
                                guard let target = request.target,
                                      request.viewportSize.width > 0,
                                      request.viewportSize.height > 0 else { return }
                                // Focus can stay on the same control when the
                                // viewport shrinks. Observe its size, not its
                                // scroll offset, so manual scrolling stays put.
                                // Let layout finish registering the target first.
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                    proxy.scrollTo(target)
                                }
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }
}

private struct AppKeyboardFocusScrollRequest: Equatable {
    let target: UUID?
    let viewportSize: CGSize
}

/// macOS 14's ID-based scroll API cannot restore an arbitrary position between
/// controls. This passive view observes only its enclosing native scroll view.
private struct AppScrollPositionBridge: NSViewRepresentable {
    let position: AppScrollPosition

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.configure(position: position)
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.configure(position: position)
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.disconnect()
    }

    final class ObserverView: NSView {
        private var position: AppScrollPosition?
        private weak var scrollView: NSScrollView?
        private var needsRestore = true
        private var restoreIsScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        func configure(position: AppScrollPosition) {
            if self.position !== position {
                disconnect()
                self.position = position
                needsRestore = true
            }
            connect()
        }

        private func connect() {
            guard let resolved = enclosingScrollView else { return }
            if scrollView !== resolved {
                disconnect()
                scrollView = resolved
                needsRestore = true
                let clipView = resolved.contentView
                clipView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(boundsChanged),
                    name: NSView.boundsDidChangeNotification, object: clipView
                )
                if let document = resolved.documentView {
                    document.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(documentChanged),
                        name: NSView.frameDidChangeNotification, object: document
                    )
                }
            }
            scheduleRestore()
        }

        func disconnect() {
            rememberPosition()
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
        }

        @objc private func boundsChanged(_ notification: Notification) {
            rememberPosition()
        }

        @objc private func documentChanged(_ notification: Notification) {
            scheduleRestore()
        }

        private func rememberPosition() {
            guard !needsRestore, let position, let scrollView,
                  let document = scrollView.documentView else { return }
            let viewport = scrollView.contentView.bounds
            let offset = document.isFlipped
                ? viewport.minY - document.bounds.minY
                : document.bounds.maxY - viewport.maxY
            position.topOffset = max(offset, 0)
        }

        private func scheduleRestore() {
            guard needsRestore, !restoreIsScheduled else { return }
            restoreIsScheduled = true
            // SwiftUI first installs and lays out the new task's document.
            // Restore before displaying it, without a second scrolling animation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restoreIsScheduled = false
                guard self.needsRestore, let position = self.position,
                      let scrollView = self.scrollView,
                      let document = scrollView.documentView else { return }
                scrollView.layoutSubtreeIfNeeded()
                let clipView = scrollView.contentView
                guard clipView.bounds.height > 0, document.bounds.height > 0 else { return }
                let offset = min(
                    position.topOffset,
                    max(document.bounds.height - clipView.bounds.height, 0)
                )
                let y = document.isFlipped
                    ? document.bounds.minY + offset
                    : document.bounds.maxY - clipView.bounds.height - offset
                self.needsRestore = false
                clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clipView)
                self.rememberPosition()
            }
        }
    }
}

extension View {
    func appKeyboardFocusScrollTarget(isFocused: Bool) -> some View {
        modifier(AppKeyboardFocusScrollTarget(isFocused: isFocused))
    }
}

private struct AppKeyboardFocusScrollEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var appKeyboardFocusScrollEnabled: Bool {
        get { self[AppKeyboardFocusScrollEnabledKey.self] }
        set { self[AppKeyboardFocusScrollEnabledKey.self] = newValue }
    }
}

private struct AppKeyboardFocusScrollTargetKey: PreferenceKey {
    static var defaultValue: UUID? { nil }

    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        if let target = nextValue() { value = target }
    }
}

private struct AppKeyboardFocusScrollTarget: ViewModifier {
    @Environment(\.appKeyboardFocusScrollEnabled) private var isScrollEnabled
    @Environment(\.appShowsKeyboardFocus) private var showsKeyboardFocus
    @Environment(\.isEnabled) private var isEnabled
    @State private var targetID = UUID()
    let isFocused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isScrollEnabled {
            content
                .id(targetID)
                .preference(
                    key: AppKeyboardFocusScrollTargetKey.self,
                    value: isFocused && showsKeyboardFocus && isEnabled ? targetID : nil
                )
        } else {
            content
        }
    }
}
