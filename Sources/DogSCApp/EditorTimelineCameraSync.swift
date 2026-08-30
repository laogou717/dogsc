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
        guard var media = project.media, var camera = media.camera else { return }
        let removedAnchor = camera.syncAnchors.first { $0.id == id }
        camera.syncAnchors.removeAll { $0.id == id }
        media.camera = camera
        project.media = media
        do {
            try editorStore.replaceProject(with: project, actionName: "删除摄像头同步点")
            if selectedCameraSyncAnchorID == id { selectedCameraSyncAnchorID = nil }
            if let sourceTime = removedAnchor?.sourceTime,
               let outputTime = timelineMap?.outputTime(forSourceTime: sourceTime) {
                playbackController.scheduleCameraSyncAudition(at: outputTime)
            }
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
