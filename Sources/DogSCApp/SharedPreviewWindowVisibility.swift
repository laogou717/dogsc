import AppKit
import QuartzCore

typealias PreviewSleepCoverHandler = (Bool, @escaping () -> Void) -> Void

/// Owns the display link, notification registration, and suspension state for
/// one preview surface. The surface renders pixels; this object decides when
/// that surface is allowed to present them.
@MainActor
final class SharedPreviewWindowVisibilityController: NSObject {
    private weak var view: SharedRenderedPreviewNSView?
    private var displayLink: CADisplayLink?
    private(set) var isSuspended = true
    private var isAwaitingResumedFrame = false
    private var transitionRevision: UInt64 = 0
    private var retirementWatchdog: Task<Void, Never>?
    private var hasRetiredForSuspension = false

    func attach(to view: SharedRenderedPreviewNSView) {
        stopObserving()
        self.view = view
        guard let window = view.window else {
            updatePresentationVisibility(force: true)
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
        updatePresentationVisibility(force: true)

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
        transitionRevision &+= 1
        retirementWatchdog?.cancel()
        retirementWatchdog = nil
        isAwaitingResumedFrame = false
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

        resumePresentation(in: view)
    }

    private func updatePresentationVisibility(force: Bool = false) {
        guard let view else { return }
        let window = view.window
        let shouldSuspend = PreviewPresentationVisibilityPolicy.shouldSuspend(
            hasWindow: window != nil,
            isMiniaturized: window?.isMiniaturized ?? false,
            isVisible: window?.occlusionState.contains(.visible) ?? false,
            isApplicationActive: NSApp.isActive && !NSApp.isHidden
        )
        guard force || shouldSuspend != isSuspended else {
            updatePlaybackState()
            return
        }

        isSuspended = shouldSuspend
        if shouldSuspend {
            transitionRevision &+= 1
            retirementWatchdog?.cancel()
            retirementWatchdog = nil
            isAwaitingResumedFrame = false
            hasRetiredForSuspension = false
            displayLink?.isPaused = true
            view.renderGeneration &+= 1
            view.presentationEpochID &+= 1
            view.renderDirty = false
            view.lastSubmittedSignature = nil
            // Freeze the last valid pixels and cursor while the cover fades.
            // Rendering is already suspended; this is not continued playback.
            requestSleepCover(true)
            let revision = transitionRevision
            let canShowTransition = window?.isVisible == true
                && window?.isMiniaturized == false && !NSApp.isHidden
                && window?.occlusionState.contains(.visible) == true
            if !canShowTransition || view.onSleepCoverChanged == nil {
                finishSuspension(revision: revision)
            } else {
                // Hidden/dismantled SwiftUI animations may never report their
                // completion. Bound resource retention without a polling loop.
                retirementWatchdog = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.finishSuspension(revision: revision)
                }
            }
            return
        }

        resumePresentation(in: view)
    }

    private func resumePresentation(in view: SharedRenderedPreviewNSView) {
        transitionRevision &+= 1
        retirementWatchdog?.cancel()
        retirementWatchdog = nil
        isSuspended = false
        isAwaitingResumedFrame = true
        view.installPreviewBackingLayerIfNeeded()
        updatePlaybackState()
        view.lastSubmittedSignature = nil
        view.renderCurrentFrame()
    }

    /// The current drawable is rendered and its presentation command finished.
    /// A fully opaque cover may occlude it, so do not wait for an onscreen
    /// presentedTime event before allowing that cover to start fading away.
    func previewFrameBecameReady(epochID: UInt64) {
        guard !isSuspended, isAwaitingResumedFrame,
              let view, view.presentationEpochID == epochID else { return }
        isAwaitingResumedFrame = false
        requestSleepCover(false)
    }

    private func requestSleepCover(_ covered: Bool) {
        let revision = transitionRevision
        // Attaching a native view can occur during SwiftUI's update. Keep all
        // cover state changes out of that pass and reject stale notifications.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transitionRevision == revision else { return }
            if let handler = self.view?.onSleepCoverChanged {
                handler(covered) { [weak self] in
                    if covered { self?.finishSuspension(revision: revision) }
                }
            } else if covered {
                self.finishSuspension(revision: revision)
            }
        }
    }

    private func finishSuspension(revision: UInt64) {
        guard isSuspended, transitionRevision == revision, !hasRetiredForSuspension else { return }
        hasRetiredForSuspension = true
        retirementWatchdog?.cancel()
        retirementWatchdog = nil
        view?.suspendPreviewBackingLayer()
    }
}
