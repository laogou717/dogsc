import AppKit
import QuartzCore
import SwiftUI

/// Owns windows until their presentation or retirement finishes. Retired
/// windows never reach back into a selector's current window collection.
@MainActor
final class CaptureSelectionTransition {
    private struct Transition {
        let id: UUID
        let window: NSWindow
    }

    private var transitions: [ObjectIdentifier: Transition] = [:]

    func present(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        window.orderFrontRegardless()
        fade(window, to: 1, retiring: false)
    }

    func retire(_ windows: [NSWindow], animated: Bool) {
        for window in windows {
            window.ignoresMouseEvents = true
            window.sharingType = .none
            window.makeFirstResponder(nil)
            window.resignKey()
            window.resignMain()
            if animated {
                fade(window, to: 0, retiring: true)
            } else {
                interrupt(window)
                close(window)
            }
        }
    }

    func finishImmediately() {
        let interrupted = Array(transitions.values)
        transitions.removeAll()
        for transition in interrupted {
            settleAlpha(transition.window, to: transition.window.alphaValue)
            close(transition.window)
        }
    }

    func settlePresentation(_ windows: [NSWindow]) {
        for window in windows {
            interrupt(window)
            window.alphaValue = 1
        }
    }

    private func interrupt(_ window: NSWindow) {
        guard transitions.removeValue(forKey: ObjectIdentifier(window)) != nil else { return }
        settleAlpha(window, to: window.alphaValue)
    }

    private func settleAlpha(_ window: NSWindow, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = alpha
        }
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    private func fade(_ window: NSWindow, to target: CGFloat, retiring: Bool) {
        interrupt(window)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.alphaValue = target
            if retiring { close(window) }
            return
        }
        let key = ObjectIdentifier(window)
        let id = UUID()
        transitions[key] = Transition(id: id, window: window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = retiring ? 0.16 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = target
        } completionHandler: { [weak self, window] in
            Task { @MainActor in
                guard let self, self.transitions[key]?.id == id else { return }
                self.transitions.removeValue(forKey: key)
                if retiring { self.close(window) }
            }
        }
    }
}

/// Placement follows the chosen target immediately. Only opacity is animated;
/// a fresh card can never travel from an old or uncommitted layer frame.
@MainActor
final class CaptureSelectionCardTransition {
    private weak var animatedView: NSView?
    private var generation: UInt64 = 0
    private var targetFrame: CGRect?
    private(set) var isPresented = false

    func show(_ view: NSView, at target: CGRect) {
        guard !isPresented || targetFrame != target else { return }
        let entering = !isPresented
        isPresented = true
        targetFrame = target
        // Set geometry before revealing the card, outside every animation
        // context. Pointer tracking never waits for a layout transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            view.frame = target
        }
        CATransaction.commit()
        guard entering else { return }
        interrupt()
        if view.isHidden { view.alphaValue = 0 }
        view.isHidden = false
        animate(view, alpha: 1, duration: 0.16)
    }

    func hide(_ view: NSView, animated: Bool = true) {
        guard isPresented else {
            if !animated {
                interrupt()
                view.alphaValue = 0
                view.isHidden = true
            }
            return
        }
        interrupt()
        isPresented = false
        targetFrame = nil
        animate(
            view,
            alpha: 0,
            duration: animated ? 0.14 : 0,
            hideOnCompletion: true
        )
    }

    func stop() {
        interrupt()
        isPresented = false
        targetFrame = nil
    }

    func visibleFrame(of view: NSView) -> CGRect {
        view.frame
    }

    private func interrupt() {
        generation &+= 1
        guard let view = animatedView else { return }
        let alpha = CGFloat(view.layer?.presentation()?.opacity ?? Float(view.alphaValue))
        view.layer?.removeAnimation(forKey: "opacity")
        view.layer?.removeAnimation(forKey: "alphaValue")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            view.animator().alphaValue = alpha
        }
        animatedView = nil
    }

    private func animate(
        _ view: NSView,
        alpha: CGFloat,
        duration: TimeInterval,
        hideOnCompletion: Bool = false
    ) {
        let initialAlpha = view.alphaValue
        guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = alpha
            view.isHidden = hideOnCompletion
            return
        }
        guard initialAlpha != alpha else {
            view.isHidden = hideOnCompletion
            return
        }
        let generation = generation
        animatedView = view
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        } completionHandler: { [weak self, weak view] in
            Task { @MainActor in
                guard let self, let view, self.generation == generation else { return }
                view.alphaValue = alpha
                view.isHidden = hideOnCompletion
                self.animatedView = nil
            }
        }
    }
}

/// Panel opacity owns the fade; this modifier adds only the card's small
/// spatial movement, avoiding a second opacity animation on the same card.
struct CaptureSelectionCardMotion: ViewModifier {
    var retiring: Bool
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = appeared && !retiring
        content
            .offset(y: visible || reduceMotion ? 0 : 6)
            .scaleEffect(visible || reduceMotion ? 1 : 0.985)
            .animation(reduceMotion ? nil : .easeOut(duration: retiring ? 0.16 : 0.2), value: visible)
            .onAppear { appeared = true }
    }
}
