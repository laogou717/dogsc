import AppKit
import SwiftUI

/// A measured editor surface. Its hosting view always fills the window;
/// only the unbounded scroll content reports an ideal height. This prevents
/// the old window height from becoming the next content layout proposal.
struct EditorContentSizedPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let width: CGFloat
    let content: Content
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorPopoverAnchorView {
        let view = EditorPopoverAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleUpdate()
        }
        return view
    }

    func updateNSView(_ view: EditorPopoverAnchorView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.configuration = self
        context.coordinator.scheduleUpdate()
    }

    static func dismantleNSView(_ view: EditorPopoverAnchorView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.configuration = nil
        coordinator.dismiss(notify: false)
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var configuration: EditorContentSizedPopoverAnchor?
        private var panel: EditorContentSizedPanel?
        private var host: NSHostingController<AnyView>?
        private var chrome = EditorPopoverPlacement()
        private var contentHeight: CGFloat = 0
        private var targetFrame: NSRect?
        private var updateScheduled = false
        private var localMonitor: Any?
        private var globalMonitor: Any?
        private var observers: [NSObjectProtocol] = []

        func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.update()
            }
        }

        private func update() {
            guard let configuration, configuration.isPresented else {
                dismiss(notify: false)
                return
            }
            guard let anchor, let owner = anchor.window, let screen = owner.screen else { return }
            if panel == nil {
                let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
                chrome = EditorPopoverPlacement()
                chrome.pointsDown = visible.maxY - rect.maxY >= rect.minY - visible.minY
                let panel = EditorContentSizedPanel(contentRect:
                    NSRect(x: rect.minX, y: rect.maxY, width: configuration.width, height: 300),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.isReleasedWhenClosed = false
                panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
                panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
                panel.identifier = NSUserInterfaceItemIdentifier("editor.content-sized-popover")
                let host = NSHostingController(rootView: AnyView(EmptyView()))
                host.sizingOptions = []
                self.panel = panel
                self.host = host
                panel.contentViewController = host
                setContent(configuration, panel: panel, host: host)
                place()
                host.view.layoutSubtreeIfNeeded()
                owner.addChildWindow(panel, ordered: .above)
                panel.makeKeyAndOrderFront(nil)
                animateRecorderOverlayIn(panel)
                installDismissal(owner: owner, panel: panel)
            } else if let panel, let host {
                setContent(configuration, panel: panel, host: host)
                place()
            }
        }

        private func setContent(_ configuration: EditorContentSizedPopoverAnchor,
                                panel: NSPanel, host: NSHostingController<AnyView>) {
            panel.appearance = NSAppearance(named:
                configuration.environment.colorScheme == .dark ? .darkAqua : .aqua)
            host.rootView = AnyView(EditorMeasuredPopoverViewport(
                content: configuration.content, width: configuration.width, placement: chrome
            ) { [weak self, weak panel] height in
                // Geometry callbacks run during SwiftUI layout. Resize on the
                // next main turn and ignore callbacks from a dismissed host.
                DispatchQueue.main.async {
                    guard let self, let panel, self.panel === panel,
                          height.isFinite, height > 0,
                          abs(self.contentHeight - height) > 0.5 else { return }
                    self.contentHeight = height
                    self.place()
                }
            }.environment(\.self, configuration.environment))
        }

        private func place() {
            guard let anchor, let owner = anchor.window, let screen = owner.screen,
                  let panel, let configuration else { return }
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let width = configuration.width
            let gap: CGFloat = 4
            let availableHeight = chrome.pointsDown
                ? visible.maxY - rect.maxY - gap
                : rect.minY - visible.minY - gap
            let height = min((contentHeight > 0 ? contentHeight : 300) + EditorPopoverOutline.arrowHeight,
                             max(availableHeight, 1))
            let x = min(max(rect.midX - width / 2, visible.minX), visible.maxX - width)
            let y = chrome.pointsDown ? rect.maxY + gap : rect.minY - gap - height
            let arrowX = min(max(rect.midX - x, 24), width - 24)
            if chrome.arrowX != arrowX { chrome.arrowX = arrowX }
            let frame = NSRect(x: x, y: y, width: width, height: height)
            guard targetFrame != frame else { return }
            targetFrame = frame
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }

        private func installDismissal(owner: NSWindow, panel: NSPanel) {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching:
                [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak panel] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss(); return nil }
                } else if event.window !== panel {
                    let clickedTrigger: Bool
                    if let anchor = self.anchor, event.window === anchor.window {
                        clickedTrigger = anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                    } else {
                        clickedTrigger = false
                    }
                    self.dismiss()
                    // A click on the trigger closes it once, without its
                    // subsequent button action immediately opening it again.
                    if clickedTrigger { return nil }
                }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
        }

        func dismiss(notify: Bool = true) {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil
            globalMonitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            let current = panel
            let owner = current?.parent
            let wasKey = current?.isKeyWindow == true
            panel = nil
            host = nil
            contentHeight = 0
            targetFrame = nil
            if let current { current.parent?.removeChildWindow(current) }
            current?.orderOut(nil)
            current?.contentViewController = nil
            current?.close()
            if wasKey, NSApp.isActive { owner?.makeKeyAndOrderFront(nil) }
            if notify { configuration?.isPresented = false }
        }
    }
}

final class EditorPopoverAnchorView: NSView {
    var onWindowChange: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var frame: NSRect {
        didSet {
            if frame != oldValue { onWindowChange?() }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

private final class EditorContentSizedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class EditorPopoverPlacement: ObservableObject {
    @Published var arrowX: CGFloat = 150
    @Published var pointsDown = true
}

private struct EditorMeasuredPopoverViewport<Content: View>: View {
    let content: Content
    let width: CGFloat
    @ObservedObject var placement: EditorPopoverPlacement
    let onResize: (CGFloat) -> Void

    var body: some View {
        let outline = EditorPopoverOutline(arrowX: placement.arrowX, pointsDown: placement.pointsDown)
        ScrollView(.vertical) {
            content.frame(width: width).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { onResize($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width)
        .padding(placement.pointsDown ? .bottom : .top, EditorPopoverOutline.arrowHeight)
        .background(EditorTheme.panelRaised, in: outline)
        .clipShape(outline)
        .overlay { outline.stroke(EditorTheme.chrome(0.20), lineWidth: 0.5).allowsHitTesting(false) }
    }
}

/// Body and pointer share one fill, including while the hosting window grows
/// or shrinks. There is no exposed system-material strip above/below content.
private struct EditorPopoverOutline: Shape {
    static let arrowHeight: CGFloat = 10
    let arrowX: CGFloat
    let pointsDown: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 10
        let bottom = max(rect.height - Self.arrowHeight, radius * 2)
        let right = rect.width
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: right - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: right, y: radius), control: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: arrowX + 10, y: bottom))
        path.addQuadCurve(to: CGPoint(x: arrowX + 6, y: bottom + 2), control: CGPoint(x: arrowX + 8, y: bottom))
        path.addLine(to: CGPoint(x: arrowX + 2.5, y: bottom + 7))
        path.addQuadCurve(to: CGPoint(x: arrowX - 2.5, y: bottom + 7), control: CGPoint(x: arrowX, y: bottom + 11))
        path.addLine(to: CGPoint(x: arrowX - 6, y: bottom + 2))
        path.addQuadCurve(to: CGPoint(x: arrowX - 10, y: bottom), control: CGPoint(x: arrowX - 8, y: bottom))
        path.addLine(to: CGPoint(x: radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: 0, y: bottom - radius), control: CGPoint(x: 0, y: bottom))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return pointsDown ? path : path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height))
    }
}
