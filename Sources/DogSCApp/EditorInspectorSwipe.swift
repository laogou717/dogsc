import AppKit
import SwiftUI

/// EDT-070: back / forward for the inspector's page stack, like a browser.
/// A two-finger horizontal swipe over the inspector (trackpad), the mouse's
/// back / forward buttons and ⌘[ / ⌘] all move between 全片设置 and the page
/// that was open. Only events inside the inspector count, so horizontal
/// scrolling on the timeline is never taken.
///
/// The swipe follows the fingers: an arrow grows at the edge it points to,
/// fills in once the gesture has gone far enough, and the page turns only
/// when the fingers lift. Lifting early, or swiping back, cancels.
struct EditorInspectorNavigationGestures: NSViewRepresentable {
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    /// -1…1 while swiping (negative: back), nil when idle.
    @Binding var progress: CGFloat?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        update(view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { update(view) }

    private func update(_ view: MonitorView) {
        view.canGoBack = canGoBack
        view.canGoForward = canGoForward
        view.onBack = onBack
        view.onForward = onForward
        let binding = $progress
        view.onProgress = { binding.wrappedValue = $0 }
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }


    final class MonitorView: NSView {
        var canGoBack = false
        var canGoForward = false
        var onBack: () -> Void = {}
        var onForward: () -> Void = {}
        var onProgress: (CGFloat?) -> Void = { _ in }
        private var monitor: Any?
        /// Accumulated travel of the current two-finger gesture.
        private var travel: CGFloat = 0
        private var vertical: CGFloat = 0
        /// Set once the gesture reads as horizontal; it then owns the events.
        private var tracking = false
        private var decided = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseUp]) { [weak self] event in
                guard let self else { return event }
                // A gesture that started here keeps its events to the end
                // even if the pointer drifts out.
                guard self.tracking || self.contains(event) else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            return bounds.contains(convert(event.locationInWindow, from: nil))
        }

        private func reset() {
            travel = 0; vertical = 0; tracking = false; decided = false
            onProgress(nil)
        }

        /// Returns true when the event was used.
        private func handle(_ event: NSEvent) -> Bool {
            switch event.type {
            case .otherMouseUp:
                // Mouse buttons 4 / 5 are back / forward.
                if event.buttonNumber == 3, canGoBack { onBack(); return true }
                if event.buttonNumber == 4, canGoForward { onForward(); return true }
                return false
            case .scrollWheel:
                // Trackpad only (precise deltas with phases); a mouse wheel
                // and momentum scrolling keep scrolling the inspector.
                guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return tracking }
                if event.phase == .began || event.phase == .mayBegin {
                    reset()
                    return false
                }
                if event.phase == .changed {
                    travel += event.scrollingDeltaX
                    vertical += abs(event.scrollingDeltaY)
                    if !decided, abs(travel) + vertical > 10 {
                        decided = true
                        // Clearly sideways, toward a page that exists.
                        let back = travel > 0
                        tracking = abs(travel) > vertical * 1.5 && (back ? canGoBack : canGoForward)
                    }
                    guard tracking else { return false }
                    let direction: CGFloat = travel > 0 ? -1 : 1
                    let allowed = direction < 0 ? canGoBack : canGoForward
                    onProgress(allowed ? direction * min(abs(travel) / Threshold.value, 1.2) : 0)
                    return true
                }
                if event.phase == .ended || event.phase == .cancelled {
                    let used = tracking
                    let commit = tracking && event.phase == .ended && abs(travel) >= Threshold.value
                    let back = travel > 0
                    reset()
                    if commit { back ? onBack() : onForward() }
                    return used
                }
                return tracking
            default:
                return false
            }
        }
    }

    /// Horizontal travel (points) that commits the page turn.
    private enum Threshold { static let value: CGFloat = 110 }
}

/// The arrow at the inspector's edge while swiping: it slides in and grows
/// with the fingers, and fills with the accent once releasing will turn the
/// page.
struct EditorInspectorSwipeIndicator: View {
    let progress: CGFloat?

    var body: some View {
        let value = progress ?? 0
        let amount = min(abs(value), 1)
        let armed = abs(value) >= 1
        HStack {
            if value < 0 { arrow(amount: amount, armed: armed, back: true) }
            Spacer(minLength: 0)
            if value > 0 { arrow(amount: amount, armed: armed, back: false) }
        }
        .allowsHitTesting(false)
        .animation(SpringMotion.micro, value: armed)
    }

    private func arrow(amount: CGFloat, armed: Bool, back: Bool) -> some View {
        ZStack {
            Circle()
                .fill(armed ? EditorTheme.accent : EditorTheme.panelRaised)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            Circle().strokeBorder(armed ? .clear : EditorTheme.hairline, lineWidth: 1)
            AppLineIcon(kind: back ? .chevronLeft : .chevron, size: 14)
                .foregroundStyle(armed ? Color.white : EditorTheme.secondaryText)
        }
        .frame(width: 36, height: 36)
        .scaleEffect(0.6 + 0.4 * amount)
        .opacity(Double(min(amount * 1.6, 1)))
        // Slides in from the edge it points to.
        .offset(x: (back ? -1 : 1) * (1 - amount) * 28)
        .padding(.horizontal, 10)
    }
}
