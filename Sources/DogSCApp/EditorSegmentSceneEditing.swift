import Foundation
import RecorderCore

extension EditorStore {
    /// Existing inspector and canvas gestures edit a resolved scene. Put its
    /// static styles back on that occurrence, creating its first override when
    /// needed, without leaking them to neighbours.
    static func storingSceneEdit(_ presented: RecorderProject, in baseline: RecorderProject,
                                 segmentID: UUID) -> RecorderProject {
        var result = presented
        let previous = baseline.timeline.recordingSegment(id: segmentID)?.sceneStyle
        let style = SegmentSceneStyle(project: presented, presetID: previous?.presetID, presetName: previous?.presetName)
        result.canvas = baseline.canvas
        result.canvas.aspectRatio = presented.canvas.aspectRatio
        result.canvas.customAspectRatio = presented.canvas.customAspectRatio
        result.camera = baseline.camera
        result.cursorStyle = baseline.cursorStyle
        result.motion = baseline.motion
        result.setSceneStyle(style, forSegmentID: segmentID)
        // Moving/resizing a flat insert must not enable recording frame chrome.
        if let media = baseline.timeline.recordingSegment(id: segmentID)?.media,
           case var .edited(segments) = result.timeline.sourceSequence,
           let index = segments.firstIndex(where: { $0.id == segmentID }) {
            segments[index].media?.usesFrameStyle = media.usesFrameStyle
            result.timeline.sourceSequence = .edited(segments)
        }
        return result
    }

    /// An occurrence style is an override, so there has to be a way back: the
    /// segment follows the programme's appearance again once it is dropped.
    func clearSceneStyle(forSegmentID id: UUID, actionName: String) throws {
        guard case var .edited(segments) = project.timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].sceneStyle != nil else { return }
        segments[index].sceneStyle = nil
        var timeline = project.timeline
        timeline.sourceSequence = .edited(segments)
        try replaceTimeline(with: timeline, actionName: actionName)
    }
}

extension EditorInspectorView {
    var sceneEditingCandidateID: UUID? {
        let project = editorStore.previewProject
        let id: UUID?
        if case let .primarySegment(selected) = editorStore.selection {
            id = selected
        } else {
            id = project.timeline.recordingSegment(atOutputTime: playbackTime)?.id
        }
        guard let id, project.timeline.recordingSegment(id: id) != nil else { return nil }
        return id
    }
}

@MainActor
extension CanvasPreview {
    func beginSceneCanvasInteraction(scope: EditorCanvasEditScope, operation: EditorCanvasInteractionOperation) -> Bool {
        let segment = project.timeline.recordingSegment(atOutputTime: playbackController.latestOutputTime)
        editorStore.sceneEditingSegmentID = segment?.id
        return editorStore.beginCanvasInteraction(scope: scope, operation: operation)
    }
}

/// How far one occurrence's appearance is pushed. Crop never travels with it:
/// it has its own authority (the recording, or a clip framed on its own).
enum EditorSceneStyleSpread: Equatable {
    /// Every occurrence of the same recording wears this clip's appearance.
    case recording
    /// The appearance becomes the programme's, and the other recordings'
    /// occurrences drop their overrides so the whole video really is uniform.
    case programme
}

extension EditorStore {
    /// How many occurrences each spread would rewrite, for the action's label.
    func sceneStyleSpreadCount(_ spread: EditorSceneStyleSpread, forSegmentID id: UUID) -> Int {
        guard case let .edited(segments) = project.timeline.sourceSequence,
              let segment = segments.first(where: { $0.id == id }), segment.media == nil else { return 0 }
        switch spread {
        case .recording:
            return segments.count { $0.media == nil && $0.resolvedSourceID == segment.resolvedSourceID }
        case .programme:
            return segments.count { $0.media == nil }
        }
    }

    /// A clip edited on its own is a dead end once a recording is cut into
    /// eight of them: there was no way to say "the rest look like this one".
    /// Both spreads are one undo step, and neither touches crop or sound.
    func spreadSceneStyle(ofSegmentID id: UUID, to spread: EditorSceneStyleSpread,
                          actionName: String) throws {
        guard case var .edited(segments) = project.timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].media == nil else { return }
        var result = project
        switch spread {
        case .recording:
            // Copying the override verbatim keeps "inherits" honest: a clip
            // that follows the programme hands its neighbours that, not a
            // frozen snapshot of the same values.
            let style = segments[index].sceneStyle
            let sourceID = segments[index].resolvedSourceID
            for other in segments.indices
            where segments[other].media == nil && segments[other].resolvedSourceID == sourceID {
                segments[other].sceneStyle = style
            }
        case .programme:
            let resolved = project.sceneProject(forSegmentID: id)
            result.canvas = resolved.canvas
            // Output ratio and crop are not part of an occurrence's look.
            result.canvas.aspectRatio = project.canvas.aspectRatio
            result.canvas.customAspectRatio = project.canvas.customAspectRatio
            result.canvas.crop = project.canvas.crop
            result.camera = resolved.camera
            result.cursorStyle = resolved.cursorStyle
            result.motion = resolved.motion
            for other in segments.indices where segments[other].media == nil {
                segments[other].sceneStyle = nil
            }
            // A recording keeping its own screen decoration would break the
            // uniformity the user just asked for; the programme now owns it.
            for source in result.additionalSources.indices {
                result.additionalSources[source].screenAppearance = nil
            }
        }
        result.timeline.sourceSequence = .edited(segments)
        try replaceProject(with: result, actionName: actionName)
    }

    /// Crop's own "apply to all": this clip's rectangle becomes the
    /// recording's, and every occurrence of it follows that one again.
    func spreadSegmentCropToRecording(segmentID: UUID, actionName: String) throws {
        guard case var .edited(segments) = project.timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == segmentID }),
              segments[index].media == nil, let crop = segments[index].crop else { return }
        let sourceID = segments[index].resolvedSourceID
        var result = project
        result.setCrop(crop.clamped(), for: sourceID)
        for other in segments.indices
        where segments[other].media == nil && segments[other].resolvedSourceID == sourceID {
            segments[other].crop = nil
        }
        result.timeline.sourceSequence = .edited(segments)
        try replaceProject(with: result, actionName: actionName)
    }
}
