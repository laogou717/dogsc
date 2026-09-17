import AppKit
import QuartzCore

/// Owns the display link, notification registration, and suspension state for
/// one preview surface. The surface renders pixels; this object decides when
/// that surface is allowed to present them.
@MainActor
final class SharedPreviewWindowVisibilityController: NSObject {
    private weak var view: SharedRenderedPreviewNSView?
    private var displayLink: CADisplayLink?
    private(set) var isSuspended = true

    func attach(to view: SharedRenderedPreviewNSView) {
        stopObserving()
        self.view = view
        guard let window = view.window else {
            updatePresentationVisibility()
            return
        }

        let link = window.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        configureCadence(link, screen: window.screen)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link

        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didExposeNotification,
            NSWindow.didUpdateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(windowVisibilityDidChange(_:)),
                name: name,
                object: window
            )
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityDidChange(_:)), name: name, object: nil)
        }

        isSuspended = true
        updatePresentationVisibility()

    }

    func updatePlaybackState() {
        displayLink?.isPaused = isSuspended
            || view?.playbackController?.isPlaying != true
    }

    func invalidate() {
        stopObserving()
        view = nil
        isSuspended = true
    }

    private func stopObserving() {
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        view?.playbackDisplayLinkDidFire(link)
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        if notification.name == NSWindow.didChangeScreenNotification, let displayLink {
            configureCadence(displayLink, screen: view?.window?.screen)
        }
        if notification.name == NSApplication.didBecomeActiveNotification {
            resumePreviewPresentationForForegroundWindow(
                acceptsExplicitForegroundSignal: true
            )
            return
        }
        if notification.name == NSWindow.didExposeNotification {
            resumePreviewPresentationForForegroundWindow(
                acceptsExplicitForegroundSignal: true
            )
            return
        }
        if notification.name == NSWindow.didUpdateNotification {
            resumePreviewPresentationForForegroundWindow()
            return
        }
        updatePresentationVisibility()
        if notification.name == NSWindow.didDeminiaturizeNotification
            || notification.name == NSWindow.didBecomeKeyNotification
            || notification.name == NSWindow.didBecomeMainNotification {
            DispatchQueue.main.async { [weak self] in
                self?.resumePreviewPresentationForForegroundWindow(
                    acceptsExplicitForegroundSignal: true
                )
            }
        }
    }

    private func configureCadence(_ link: CADisplayLink, screen: NSScreen?) {
        // A full-resolution effects graph must not silently double its work on
        // a 120/144 Hz display. This is a presentation budget, not an export
        // frame-rate or pixel-resolution change; the OS still owns scheduling.
        let maximum = Float(min(max(screen?.maximumFramesPerSecond ?? 60, 1),
                                PreviewAnimationCadence.framesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: maximum, maximum: maximum, preferred: maximum)
    }

    private func resumePreviewPresentationForForegroundWindow(
        acceptsExplicitForegroundSignal: Bool = false
    ) {
        guard isSuspended,
              let view,
              let window = view.window,
              NSApp.isActive,
              !NSApp.isHidden,
              window.isVisible,
              !window.isMiniaturized,
              acceptsExplicitForegroundSignal
                || window.occlusionState.contains(.visible)
                || window.isKeyWindow
                || window.isMainWindow
        else { return }

        isSuspended = false
        view.installPreviewBackingLayerIfNeeded()
        updatePlaybackState()
        view.lastSubmittedSignature = nil
        view.renderCurrentFrame()
    }

    private func updatePresentationVisibility() {
        guard let view else { return }
        let window = view.window
        let shouldSuspend = PreviewPresentationVisibilityPolicy.shouldSuspend(
            hasWindow: window != nil,
            isMiniaturized: window?.isMiniaturized ?? false,
            isVisible: window?.occlusionState.contains(.visible) ?? false,
            isApplicationActive: NSApp.isActive && !NSApp.isHidden
        )
        guard shouldSuspend != isSuspended else {
            updatePlaybackState()
            return
        }

        isSuspended = shouldSuspend
        if shouldSuspend {
            displayLink?.isPaused = true
            view.renderGeneration &+= 1
            view.presentationEpochID &+= 1
            view.renderDirty = false
            view.lastSubmittedSignature = nil
            view.cursorImageLayer.isHidden = true
            view.cursorClickGradientLayer.isHidden = true
            view.cursorClickLayer.isHidden = true
            view.cursorClickSecondaryLayer.isHidden = true
            view.cursorClickAccentLayer.isHidden = true
            view.suspendPreviewBackingLayer()
            return
        }

        view.installPreviewBackingLayerIfNeeded()
        updatePlaybackState()
        view.lastSubmittedSignature = nil
        view.renderCurrentFrame()
    }
}
