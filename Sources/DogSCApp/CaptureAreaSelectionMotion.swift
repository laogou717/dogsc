import AppKit
import QuartzCore

/// A short, interruptible presentation transition. Capture geometry is owned
/// by the selector; this clock only moves its visible frame and toolbar.
@MainActor
final class CaptureAreaSelectionMotion: NSObject {
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var update: ((CGFloat) -> Void)?
    private let duration: CFTimeInterval = 0.32

    func start(in window: NSWindow, update: @escaping (CGFloat) -> Void) {
        stop()
        self.update = update
        startedAt = CACurrentMediaTime()
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
        update(0)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        update = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = min(max((CACurrentMediaTime() - startedAt) / duration, 0), 1)
        // Ease out without overshoot: selection edges must stay on screen.
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 1 : 1 - pow(1 - time, 3)
        let update = update
        if progress >= 1 { stop() }
        update?(CGFloat(progress))
    }
}
