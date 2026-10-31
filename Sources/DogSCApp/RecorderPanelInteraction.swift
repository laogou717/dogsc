import AppKit
import SwiftUI

/// Native buttons own nearly all of the compact bar. Reserve an explicit
/// SwiftUI target for the root's WindowDragGesture instead of requiring the
/// user to find a few pixels between buttons. The shadow remains click-through.
struct RecorderDragGrip: View {
    var body: some View {
        HStack(spacing: 3) {
            dots
            dots
        }
        .foregroundStyle(RecorderStyle.faint)
        .frame(width: 22, height: 40)
        .contentShape(Rectangle())
        .help(appLocalized("拖动录制条"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized("拖动录制条"))
        .accessibilityIdentifier("recorder.window-drag-grip")
    }

    private var dots: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 2, height: 2)
            }
        }
    }
}

/// Background SwiftUI regions must accept the first press just like the
/// recorder's native buttons. Otherwise an inactive panel consumes that press
/// to focus and its WindowDragGesture cannot start until the next attempt.
final class RecorderHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window includes shadow drawing room, but only the visible island may
/// receive pointer input. NSView.hitTest alone cannot pass a click to another
/// process; change the window's acceptance before the next mouse-down instead.
@MainActor
final class RecorderPanelPointerRegion {
    private weak var window: NSWindow?
    private weak var islandView: NSView?
    private var enabled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(window: NSWindow) { self.window = window }

    func setIslandView(_ view: NSView?) {
        islandView = view
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled, localMonitor == nil {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.refresh() }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !enabled {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil
            globalMonitor = nil
        }
        refresh()
    }

    func refresh() {
        guard let window else { return }
        guard enabled, let islandView, islandView.window === window else {
            window.ignoresMouseEvents = true
            return
        }
        // Keep the recipient stable until a native control or window drag
        // receives its mouse-up, even if the pointer leaves the island.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if let regions = (window as? RecorderPanel)?.notchPointerRegions {
            window.ignoresMouseEvents = !regions.contains { $0.contains(NSEvent.mouseLocation) }
            return
        }
        let point = islandView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let bounds = islandView.bounds
        let radius = min(bounds.width, bounds.height) / 2
        let outline = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        window.ignoresMouseEvents = !outline.contains(point)
    }
}

/// The same layout that draws the island supplies its pointer boundary. No
/// hard-coded setup width, screen polling, event swallowing or replay is used.
struct RecorderIslandInteractionRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> RecorderIslandInteractionView {
        RecorderIslandInteractionView()
    }

    func updateNSView(_ view: RecorderIslandInteractionView, context: Context) {
        view.refresh()
    }
}

final class RecorderIslandInteractionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        (window as? RecorderPanel)?.setIslandInteractionView(self)
    }
}
