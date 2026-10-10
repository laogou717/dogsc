import AppKit
import QuartzCore

/// One owner for recorder-window opacity. A cancelled fade may finish late,
/// but only the latest visibility request can order the window out.
@MainActor
final class RecorderPanelTransition {
    private var revision: UInt64 = 0
    private var wantsVisible = false

    func show(_ window: RecorderPanel, animated: Bool) {
        guard !wantsVisible || !window.isVisible else { return }
        revision &+= 1
        wantsVisible = true
        window.setPointerInteractionEnabled(true)
        if !window.isVisible { window.alphaValue = animated ? 0 : 1 }
        window.orderFrontRegardless()
        animate(window, to: 1, animated: animated)
    }

    func hide(_ window: RecorderPanel, animated: Bool) {
        window.setPointerInteractionEnabled(false)
        guard wantsVisible || !animated else { return }
        revision &+= 1
        wantsVisible = false
        let retiringRevision = revision
        guard animated, window.isVisible else {
            window.orderOut(nil)
            window.alphaValue = 1
            return
        }
        animate(window, to: 0, animated: true) { [weak self, weak window] in
            guard let self, let window,
                  revision == retiringRevision, !wantsVisible else { return }
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    private func animate(
        _ window: NSWindow,
        to opacity: CGFloat,
        animated: Bool,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            // Reduced motion keeps a brief fade, with no window movement.
            context.duration = animated
                ? (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : 0.18)
                : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = opacity
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}
