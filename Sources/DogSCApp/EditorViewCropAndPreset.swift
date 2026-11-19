import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorView {

    func performEditorCommand(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    var editorWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "cn.laogou.dogsc.editor-window" }
    }

    func beginCrop(sourceID requestedSourceID: UUID? = nil) {
        guard cropPresentation.permits(.beginCrop) else { return }
        // Cropping takes over the monitor and its bar, so a bin preview has
        // to let go of both before the session starts.
        EditorAssetMonitor.shared.returnToProgramme()
        playbackController.endHoverPreview()
        playbackController.pause()
        guard let map = try? TimelineMap(sourceSequence: editorStore.project.timeline.sourceSequence,
            sourceDurations: mediaSession.sourceDurations) else { return }
        let now = playbackController.latestOutputTime
        let time = EditorPlaybackClockPolicy.frameLookupTime(now, duration: map.outputDuration)
        let current = map.segment(atOutputTime: time)
        let candidates = map.segments.filter { $0.media == nil && (requestedSourceID == nil || $0.sourceID == requestedSourceID) }
        guard let target = candidates.first(where: { $0.id == current?.id }) ?? candidates.min(by: {
            min(abs($0.outputStart - now), abs($0.outputEnd - now)) < min(abs($1.outputStart - now), abs($1.outputEnd - now))
        }) else { return }
        cropSourceID = target.sourceID
        if target.id != current?.id {
            playbackController.seek(to: target.outputStart + min(0.05, target.outputDuration / 2))
        }
        // 裁切期间检查器由裁切面板接管，完成/取消后选择回到屏幕初始状态，
        // 都落在合并后的"画面"页，无需在此预设页签。
        EditorCropAspectLock.shared.beginSession()
        // Reopen in the scope the clip is already in, so confirming a session
        // the user only looked at cannot silently widen or narrow it.
        EditorCropScope.shared.begin(
            segmentID: target.id,
            occurrences: editorStore.project.segmentCount(forSourceID: target.sourceID),
            isSegmentOnly: editorStore.project.timeline.recordingSegment(id: target.id)?.crop != nil
        )
        WindowAppearanceTransition.crossfade(editorWindow, waitsForPreviewFrame: true) {
            editorStore.beginInteraction(tool: .crop, selection: .crop, commandScope: .project)
        }
    }

    func confirmCrop() {
        guard cropPresentation.permits(.confirmCrop) else { return }
        WindowAppearanceTransition.crossfade(editorWindow, waitsForPreviewFrame: true) {
            do {
                _ = try editorStore.commitInteraction(
                    actionName: EditorCropScope.shared.isSegmentOnly ? "裁切此片段" : "裁切屏幕")
            } catch {
                editorStore.cancelInteraction()
                hostActions.reportError(error.localizedDescription)
            }
            editorStore.selection = .screen
        }
    }

    func discardCrop() {
        guard cropPresentation.permits(.cancelCrop) else { return }
        WindowAppearanceTransition.crossfade(editorWindow, waitsForPreviewFrame: true) {
            editorStore.cancelInteraction()
            editorStore.selection = .screen
        }
    }

    func resetCrop() {
        guard cropPresentation.permits(.resetCrop) else { return }
        EditorCropAspectLock.shared.aspect = .free
        withAnimation(SpringMotion.standard) {
            cropDraftBinding.wrappedValue = .full
        }
    }


    var cropDraftBinding: Binding<NormalizedCrop> {
        Binding(
            get: { EditorCropScope.shared.crop(in: editorStore, sourceID: cropSourceID) },
            set: { crop in
                guard cropPresentation.isActive else { return }
                EditorCropScope.shared.update(crop, in: editorStore, sourceID: cropSourceID)
            }
        )
    }

    func resolveExternalAction(_ action: EditorExternalAction) {
        let wasCropping = isCropping
        _ = editorStore.prepareForExternalAction(action)
        guard wasCropping else { return }
        if editorStore.selection == .crop {
            editorStore.selection = .screen
        }
    }

}
