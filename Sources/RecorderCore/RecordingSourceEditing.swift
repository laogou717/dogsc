import Foundation

public extension RecorderProject {
    mutating func stabilizeRecordingColors() {
        for index in additionalSources.indices where additionalSources[index].colorIndex == nil {
            additionalSources[index].colorIndex = index
        }
    }
}

public enum RecordingSourceEditing {
    public static func usageCount(_ sourceID: UUID, in sequence: SourceSequence) -> Int {
        switch sequence {
        case .fullRecording: sourceID == RecordingSource.primaryID ? 1 : 0
        case let .edited(segments): segments.filter { $0.media == nil && $0.resolvedSourceID == sourceID }.count
        }
    }

    /// `sourceRange` is the span of the recording to insert; nil inserts all
    /// of it. A recording auditioned in the monitor with in and out marks is
    /// inserted as exactly what was marked.
    public static func insertingFullRecording(_ sourceID: UUID, into project: RecorderProject,
                                             atOutputTime time: TimeInterval,
                                             sourceDurations: [UUID: TimeInterval],
                                             sourceRange: ClosedRange<TimeInterval>? = nil) throws -> RecorderProject {
        guard let source = project.source(sourceID), let duration = sourceDurations[sourceID], duration > 0 else {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
        let sourceStart = min(max(sourceRange?.lowerBound ?? 0, 0), max(duration - 0.1, 0))
        let span = min(max(sourceRange.map { $0.upperBound - $0.lowerBound } ?? duration, 0.1), duration - sourceStart)
        let map = try TimelineMap(sourceSequence: project.timeline.sourceSequence, sourceDurations: sourceDurations)
        let time = RecordingProjectImport.insertionTime(time, map: map)
        let id = UUID()
        var timeline = try ProjectTimelineEditing.insertMediaSegment(
            in: RecordingProjectImport.splitEdits(project.timeline, at: time),
            media: InsertedMedia(path: "recording-placeholder", fileDuration: duration, name: ""),
            atOutputTime: time, duration: span, newSegmentID: id, sourceDurations: sourceDurations)
        guard case var .edited(segments) = timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
        segments[index] = RecordingSegment(id: id, sourceStart: sourceStart, sourceDuration: span,
            sourceID: sourceID == RecordingSource.primaryID ? nil : sourceID)
        if let camera = source.cameraAppearance {
            var style = SegmentSceneStyle(project: project)
            source.screenAppearance?.apply(to: &style.canvas)
            style.camera = camera
            segments[index].sceneStyle = style
        }
        timeline.sourceSequence = .edited(segments)
        try ProjectTimelineEditing.validate(timeline, sourceDurations: sourceDurations)
        var result = project; result.timeline = timeline
        return result
    }

    public static func removing(_ sourceID: UUID, from project: RecorderProject,
                                sourceDurations: [UUID: TimeInterval]) throws -> RecorderProject {
        guard sourceID != RecordingSource.primaryID,
              project.additionalSources.contains(where: { $0.id == sourceID }) else {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
        let map = try TimelineMap(sourceSequence: project.timeline.sourceSequence, sourceDurations: sourceDurations)
        let removed = map.segments.filter { $0.media == nil && $0.sourceID == sourceID }
        guard removed.count < map.segments.count else { throw ProjectTimelineEditingError.cannotRemoveFinalSegment }
        var result = project
        result.stabilizeRecordingColors()
        for segment in removed.reversed() {
            result.timeline = try ProjectTimelineEditing.removePrimarySegment(from: result.timeline,
                segmentID: segment.id, sourceDurations: sourceDurations,
                defaultTransitionDuration: project.motion.defaultZoomTransitionDuration)
        }
        result.additionalSources.removeAll { $0.id == sourceID }
        result.recordingMarkers.removeAll { $0.resolvedSourceID == sourceID }
        try ProjectValidator.validate(result)
        return result
    }

    /// A project whose main track still points at a removed recording cannot
    /// be rendered at all, yet the rest of the edit is intact. Loading drops
    /// those segments so the user can reopen and rescue the project instead
    /// of facing a preview that fails before the editor appears.
    public static func droppingMissingSources(
        from project: RecorderProject
    ) -> (project: RecorderProject, droppedSegments: Int) {
        let available = Set(project.additionalSources.map(\.id)).union([RecordingSource.primaryID])
        var result = project
        result.recordingMarkers.removeAll { !available.contains($0.resolvedSourceID) }
        guard case let .edited(segments) = project.timeline.sourceSequence else { return (result, 0) }
        let kept = segments.filter { $0.media != nil || available.contains($0.resolvedSourceID) }
        guard kept.count < segments.count else { return (result, 0) }
        // An empty sequence is not a valid edit; fall back to the untouched
        // primary recording, which is also what a project starts from.
        result.timeline.sourceSequence = kept.isEmpty ? .fullRecording : .edited(kept)
        result.timeline.primarySegmentAudioOverrides = ProjectTimelineEditing.prunedPrimarySegmentAudioOverrides(
            result.timeline.primarySegmentAudioOverrides, sourceSequence: result.timeline.sourceSequence)
        return (result, segments.count - kept.count)
    }
}
