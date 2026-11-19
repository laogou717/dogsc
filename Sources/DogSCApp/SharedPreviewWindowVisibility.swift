import AppKit
import QuartzCore

typealias PreviewSleepCoverHandler = (Bool, @escaping () -> Void) -> Void

/// Owns window notifications and suspension state for one preview surface.
/// The background engine owns frame scheduling and drawable acquisition.
@MainActor
final class SharedPreviewWindowVisibilityController: NSObject {
    private weak var view: SharedRenderedPreviewNSView?
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
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
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
            return
        }

        isSuspended = shouldSuspend
        if shouldSuspend {
            transitionRevision &+= 1
            retirementWatchdog?.cancel()
            retirementWatchdog = nil
            isAwaitingResumedFrame = false
            hasRetiredForSuspension = false
            view.suspendRendering()
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
