import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorTimelineView {
    func dismissCameraSyncSelection() {
        playbackController.cancelCameraSyncAudition()
        cameraSyncAnchorDrag = nil
        selectedCameraSyncAnchorID = nil
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
    }

    func removeCameraSyncAnchor(id: UUID) {
        playbackController.cancelCameraSyncAudition()
        var project = editorStore.project
        guard let sourceID = cameraSyncSourceID, var media = project.source(sourceID)?.media, var camera = media.camera else { return }
        let removedAnchor = camera.syncAnchors.first { $0.id == id }
        camera.syncAnchors.removeAll { $0.id == id }
        media.camera = camera
        project.setMedia(media, for: sourceID)
        do {
            try editorStore.replaceProject(with: project, actionName: "删除摄像头同步点")
            if selectedCameraSyncAnchorID == id { selectedCameraSyncAnchorID = nil }
            if let sourceTime = removedAnchor?.sourceTime,
               let outputTime = cameraSyncOutputTime(forSourceTime: sourceTime) {
                playbackController.scheduleCameraSyncAudition(at: outputTime)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    func cameraSyncOutputTime(forSourceTime time: TimeInterval, inSegment segmentID: UUID? = nil) -> TimeInterval? {
        guard let sourceID = cameraSyncSourceID, let timelineMap else { return nil }
        if let segmentID, let time = timelineMap.outputTime(forSourceTime: time, inSegment: segmentID) { return time }
        return timelineMap.outputPositions(forSourceTime: time, sourceID: sourceID)
            .min { abs($0.time - playbackTime) < abs($1.time - playbackTime) }?.time
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
        // Scale with the lane (62 pt at scale 1, centre 41, swing 14).
        let centerY: CGFloat = cameraSyncTimelineHeight * 41 / 62
        let amplitude: CGFloat = cameraSyncTimelineHeight * 14 / 62
        let normalized = min(max(offset / max(displayRange, 0.001), -1), 1)
        return centerY - CGFloat(normalized) * amplitude
    }

    func cameraSyncOffsetLabel(_ offset: TimeInterval) -> String {
        String(format: "%+d ms", Int((offset * 1_000).rounded()))
    }
}
