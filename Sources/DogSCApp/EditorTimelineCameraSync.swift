import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorTimelineView {
    /// Wait for the edited AVComposition generation before auditioning. If we
    /// played immediately after changing the anchor, the user would hear the
    /// previous mapping and make the next correction from stale evidence.
    func scheduleCameraSyncAudition(at outputTime: TimeInterval) {
        cancelCameraSyncAudition()
        pendingCameraSyncAudition = CameraSyncAuditionRequest(
            id: UUID(),
            outputTime: min(max(outputTime, 0), timelineDuration),
            previousPlaybackTimingRevision: playbackController.cameraTimingRevision
        )
        playbackController.pause()
        startPendingCameraSyncAuditionIfReady(playbackController.lifecycle)
    }

    func startPendingCameraSyncAuditionIfReady(
        _ lifecycle: EditorPlaybackLifecycle
    ) {
        guard let request = pendingCameraSyncAudition,
              case .ready = lifecycle,
              playbackController.cameraTimingRevision
                != request.previousPlaybackTimingRevision else { return }
        pendingCameraSyncAudition = nil
        activeCameraSyncAuditionID = request.id

        let startTime = max(request.outputTime - 0.35, 0)
        let endTime = min(request.outputTime + 1.25, playbackController.duration)
        playbackController.seek(
            to: startTime,
            pausing: true,
            resumeAfterCompletion: true
        )

        cameraSyncAuditionTask = Task { @MainActor in
            // Stop by the media clock, not by wall time: exact seek and camera
            // decoder startup must not steal time from the 1.6-second review.
            for _ in 0..<100 {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
                guard activeCameraSyncAuditionID == request.id else { return }
                if playbackController.outputTime >= endTime - 0.015 {
                    playbackController.pause()
                    playbackController.seek(to: request.outputTime, pausing: true)
                    activeCameraSyncAuditionID = nil
                    cameraSyncAuditionTask = nil
                    return
                }
            }
            guard activeCameraSyncAuditionID == request.id else { return }
            playbackController.pause()
            playbackController.seek(to: request.outputTime, pausing: true)
            activeCameraSyncAuditionID = nil
            cameraSyncAuditionTask = nil
        }
    }

    func cancelCameraSyncAudition() {
        pendingCameraSyncAudition = nil
        activeCameraSyncAuditionID = nil
        cameraSyncAuditionTask?.cancel()
        cameraSyncAuditionTask = nil
    }

    func dismissCameraSyncSelection() {
        if pendingCameraSyncAudition != nil || activeCameraSyncAuditionID != nil {
            playbackController.pause()
        }
        cancelCameraSyncAudition()
        cameraSyncAnchorDrag = nil
        selectedCameraSyncAnchorID = nil
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
    }

    func removeCameraSyncAnchor(id: UUID) {
        cancelCameraSyncAudition()
        var project = editorStore.project
        guard var media = project.media, var camera = media.camera else { return }
        camera.syncAnchors.removeAll { $0.id == id }
        media.camera = camera
        project.media = media
        do {
            try editorStore.replaceProject(with: project, actionName: "删除摄像头同步点")
            if selectedCameraSyncAnchorID == id { selectedCameraSyncAnchorID = nil }
        } catch {
            onError(error.localizedDescription)
        }
    }

    func presentedCameraSyncAnchor(id: UUID) -> MediaSyncAnchor? {
        if cameraSyncAnchorDrag?.original.id == id { return cameraSyncAnchorDrag?.draft }
        return cameraSyncAnchors.first(where: { $0.id == id })
    }

    var cameraSyncDisplayRange: TimeInterval {
        derivedPresentationCache.cameraSyncDisplayRange(
            for: cameraSyncAnchors
        )
    }

    func cameraSyncY(
        offset: TimeInterval,
        displayRange: TimeInterval
    ) -> CGFloat {
        let centerY: CGFloat = 41
        let amplitude: CGFloat = 14
        let normalized = min(max(offset / max(displayRange, 0.001), -1), 1)
        return centerY - CGFloat(normalized) * amplitude
    }

    func cameraSyncOffsetLabel(_ offset: TimeInterval) -> String {
        String(format: "%+d ms", Int((offset * 1_000).rounded()))
    }
}
