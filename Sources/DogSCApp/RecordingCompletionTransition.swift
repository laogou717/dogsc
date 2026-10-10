import AppKit
import QuartzCore
import SwiftUI

/// One finite clock drives both the window contour and the two page layers.
/// A fixed, monotonic ease accelerates then settles once. Both pages overlap
/// throughout the handoff; there is no empty frame or spring tail.
@MainActor
final class RecordingCompletionTransition: NSObject {
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.32
    private var update: ((TimeInterval) -> Void)?
    private var completion: (() -> Void)?

    func start(window: NSWindow, surface: RecordingCompletionSurfaceView,
               from outgoing: NSView, to incoming: NSView, targetFrame: NSRect,
               completion: @escaping () -> Void) {
        stop()
        let startFrame = window.frame
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        duration = reducesMotion ? 0.14 : 0.32
        let transitionDuration = duration
        self.completion = completion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Alpha belongs to NSView, not its AppKit-managed backing layer.
        // Layout/key-window changes must not expose an unprepared new page.
        outgoing.alphaValue = 1
        incoming.alphaValue = 0
        outgoing.layer?.transform = CATransform3DIdentity
        incoming.layer?.transform = CATransform3DIdentity
        outgoing.isHidden = false
        incoming.isHidden = false
        surface.layoutSubtreeIfNeeded()
        surface.layoutCards()
        CATransaction.commit()
        update = { [weak window, weak surface, weak outgoing, weak incoming] elapsed in
            guard let window, let surface, let outgoing, let incoming else { return }
            let time = CGFloat(min(max(elapsed / transitionDuration, 0), 1))
            let remaining = 1 - time
            // Derivative 20*t*(1-t)^3 is nonnegative, peaks at t=1/4,
            // and reaches zero at both ends. No overshoot or reversal.
            let progress = 1 - remaining * remaining * remaining * remaining * (1 + 4 * time)
            let geometry = reducesMotion ? 1 : progress
            let frame = NSRect(
                x: startFrame.minX + (targetFrame.minX - startFrame.minX) * geometry,
                y: startFrame.minY + (targetFrame.minY - startFrame.minY) * geometry,
                width: startFrame.width + (targetFrame.width - startFrame.width) * geometry,
                height: startFrame.height + (targetFrame.height - startFrame.height) * geometry)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(frame, display: false, animate: false)
            window.contentView?.layoutSubtreeIfNeeded()
            surface.layoutCards()
            outgoing.alphaValue = 1 - progress
            incoming.alphaValue = progress
            CATransaction.commit()
            window.invalidateShadow()
        }
        update?(0)
        startedAt = CACurrentMediaTime()
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
        // Back must complete while runModal owns the AppKit event loop.
        link.add(to: .main, forMode: .modalPanel)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        update = nil
        completion = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = min(max(CACurrentMediaTime() - startedAt, 0), duration)
        update?(elapsed)
        if elapsed >= duration {
            let completion = completion
            stop()
            completion?()
        }
    }
}

/// Both pages share this one surface and one clipped viewport. Its native
/// bounds are the visible card; WindowServer draws the shadow outside them.
@MainActor
final class RecordingCompletionSurfaceView: NSView {
    let resultView: NSView
    private let background = NSHostingView(rootView: RecorderSurfaceShape(radius: 28))
    private let viewport = NSView()
    private(set) var decisionView: NSView?

    init(resultView: NSView) {
        self.resultView = resultView
        super.init(frame: .zero)
        wantsLayer = true
        viewport.wantsLayer = true
        viewport.layer?.cornerRadius = 28
        viewport.layer?.cornerCurve = .continuous
        viewport.layer?.masksToBounds = true
        addSubview(background)
        addSubview(viewport)
        viewport.addSubview(resultView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    func setDecisionView(_ view: NSView?) {
        decisionView?.removeFromSuperview()
        decisionView = view
        if let view { viewport.addSubview(view) }
        layoutCards()
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    func layoutCards() {
        background.frame = bounds
        viewport.frame = bounds
        // Both pages stay on the bottom edge with their intrinsic heights.
        // Opening reveals the preview above, instead of dragging or clipping
        // action buttons along the changing bottom of a top-aligned page.
        resultView.setFrameOrigin(.zero)
        decisionView?.setFrameOrigin(.zero)
    }
}
