import AppKit
import RecorderCore

extension EditorView {
    var scenePresetSegments: [ResolvedRecordingSegment] {
        (try? TimelineMap(sourceSequence: editorStore.project.timeline.sourceSequence,
                          sourceDurations: mediaSession.sourceDurations).segments) ?? []
    }

    var scenePresetCurrentSegment: ResolvedRecordingSegment? {
        if case let .primarySegment(id) = editorStore.selection,
           let selected = scenePresetSegments.first(where: { $0.id == id }) { return selected }
        let time = playbackController.latestOutputTime
        return scenePresetSegments.first { time >= $0.outputStart && time < $0.outputEnd } ?? scenePresetSegments.last
    }

    var scenePresetApplicationIDs: Set<UUID> {
        scenePresetAppliesToAll ? Set(scenePresetSegments.map(\.id)) : scenePresetSelectedIDs
    }

    var scenePresetEditingProject: RecorderProject {
        editorStore.project.sceneProject(forSegmentID: scenePresetCurrentSegment?.id)
    }

    var scenePresetSourceSize: CGSize {
        scenePresetCurrentSegment.flatMap { mediaSession.sourceDisplaySize(for: $0.sourceID) }
            ?? mediaSession.primarySourceDisplaySize
    }
}
