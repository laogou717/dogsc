import Foundation

public struct RecordingProjectImportOptions: Equatable, Sendable {
    public var includesMotion = true
    public var includesSubtitles = true
    public var includesOverlays = true
    public var includesAudio = true
    public var copiesMedia = true
    public init() {}
}

/// A pure edit decision. File preparation happens before this transaction;
/// replacing its result is one undo command, including all source identities.
public enum RecordingProjectImport {
    /// What an import does now: the recordings join the project as sources,
    /// ready to be dragged onto the main track, and nothing is placed. Only
    /// position-independent material can come along — the bin files and the
    /// recording markers; the imported programme's timed edits have no
    /// output time to live at until the user drops the recording somewhere.
    public static func adding(
        _ imported: RecorderProject, into current: RecorderProject,
        currentDurations: [UUID: TimeInterval], importedDurations: [UUID: TimeInterval],
        sourceIDs: [UUID: UUID]
    ) throws -> RecorderProject {
        var result = current
        result.stabilizeRecordingColors()
        var nextColor = (result.additionalSources.compactMap(\.colorIndex).max() ?? -1) + 1
        var durations = currentDurations
        for var source in imported.sources {
            guard let id = sourceIDs[source.id], id != RecordingSource.primaryID,
                  !result.sources.contains(where: { $0.id == id }),
                  let duration = importedDurations[source.id] else {
                throw ProjectTimelineEditingError.invalidSourceSequence
            }
            source.screenAppearance = source.screenAppearance ?? ScreenCardAppearance(canvas: imported.canvas)
            if source.capture.source == .cameraOnly && source.cameraAppearance == nil {
                source.cameraAppearance = imported.camera
            }
            source.id = id
            source.colorIndex = nextColor; nextColor += 1
            result.additionalSources.append(source)
            durations[id] = duration
        }
        result.timeline.mediaAssets += imported.timeline.mediaAssets.map { var a = $0; a.id = UUID(); return a }
        result.recordingMarkers += imported.recordingMarkers.compactMap { marker in
            sourceIDs[marker.resolvedSourceID].map {
                RecordingMarker(sourceTime: marker.sourceTime, number: marker.number, sourceID: $0)
            }
        }
        try ProjectTimelineEditing.validate(result.timeline, sourceDurations: durations)
        try ProjectValidator.validate(result)
        return result
    }

    /// Places an imported programme, with its edits, at an output time. No
    /// longer reached from the import panel (see `adding`); it stays as the
    /// building block for carrying an imported recording's edits onto the
    /// main track when the recording is dragged there.
    public static func inserting(
        _ imported: RecorderProject, into current: RecorderProject,
        atOutputTime requestedTime: TimeInterval,
        currentDurations: [UUID: TimeInterval], importedDurations: [UUID: TimeInterval],
        options: RecordingProjectImportOptions,
        sourceIDs: [UUID: UUID]
    ) throws -> RecorderProject {
        let incomingMap = try TimelineMap(sourceSequence: imported.timeline.sourceSequence, sourceDurations: importedDurations)
        let currentMap = try TimelineMap(sourceSequence: current.timeline.sourceSequence, sourceDurations: currentDurations)
        let time = insertionTime(requestedTime, map: currentMap)
        var result = current
        result.stabilizeRecordingColors()
        var nextColor = (result.additionalSources.compactMap(\.colorIndex).max() ?? -1) + 1
        var durations = currentDurations
        for var source in imported.sources {
            guard let id = sourceIDs[source.id], id != RecordingSource.primaryID,
                  !result.sources.contains(where: { $0.id == id }),
                  let duration = importedDurations[source.id] else {
                throw ProjectTimelineEditingError.invalidSourceSequence
            }
            source.screenAppearance = source.screenAppearance ?? ScreenCardAppearance(canvas: imported.canvas)
            if source.capture.source == .cameraOnly && source.cameraAppearance == nil {
                source.cameraAppearance = imported.camera
            }
            source.id = id
            source.colorIndex = nextColor; nextColor += 1
            result.additionalSources.append(source)
            durations[id] = duration
        }
        var edits = imported.timeline
        var segmentIDs: [UUID: UUID] = [:]
        var segments: [RecordingSegment] = []
        for resolved in incomingMap.segments {
            let id = UUID()
            segmentIDs[resolved.id] = id
            guard resolved.media != nil || sourceIDs[resolved.sourceID] != nil else {
                throw ProjectTimelineEditingError.invalidSourceSequence
            }
            var media = resolved.media
            if media?.screenAppearance == nil { media?.screenAppearance = ScreenCardAppearance(canvas: imported.canvas) }
            segments.append(RecordingSegment(id: id, sourceStart: resolved.sourceStart,
                sourceDuration: resolved.sourceDuration, playbackRate: resolved.playbackRate,
                media: media, sourceID: resolved.media == nil ? sourceIDs[resolved.sourceID] : nil,
                sceneStyle: resolved.sceneStyle, crop: resolved.crop))
        }
        // Freeze the imported programme's effective gains and mute state on
        // each occurrence so the destination's global defaults cannot change it.
        edits.primarySegmentAudioOverrides = Dictionary(uniqueKeysWithValues:
            incomingMap.segments.compactMap { segment in
                guard let id = segmentIDs[segment.id] else { return nil }
                let overrides = imported.timeline.primarySegmentAudioOverrides[segment.id]
                var settings = PrimarySegmentAudioOverrides(
                    systemVolume: overrides?.systemVolume ?? imported.audio.systemVolume,
                    microphoneVolume: overrides?.microphoneVolume ?? imported.audio.microphoneVolume,
                    isSystemMuted: overrides?.isSystemMuted ?? imported.audio.isSystemMuted,
                    isMicrophoneMuted: overrides?.isMicrophoneMuted ?? imported.audio.isMicrophoneMuted)
                settings.videoAudio = overrides?.videoAudio
                return (id, settings)
            })
        if !options.includesMotion {
            edits.zoomClips = []; edits.screenMotionClips = []; edits.cameraMotionClips = []
        }
        if !options.includesSubtitles { edits.subtitleCues = [] }
        if !options.includesOverlays {
            edits.mosaicClips = []; edits.stickerClips = []; edits.animationClips = []; edits.videoClips = []
        }
        if !options.includesAudio { edits.audioClips = [] }
        // Clamp only portions outside the source programme; authored ranges,
        // playback speed, HTML properties and in-file offsets remain intact.
        edits = boundedEdits(edits, endingAt: incomingMap.outputDuration)
        var groupIDs: [UUID: UUID] = [:]
        func group(_ old: UUID?) -> UUID? {
            guard let old else { return nil }
            if let id = groupIDs[old] { return id }
            let id = UUID(); groupIDs[old] = id; return id
        }
        edits.zoomClips = edits.zoomClips.map { var c = $0; c.id = UUID(); c.startTime += time; c.endTime += time; return c }
        edits.screenMotionClips = edits.screenMotionClips.map { var c = $0; c.id = UUID(); c.groupID = group(c.groupID); c.timing.startTime += time; return c }
        edits.cameraMotionClips = edits.cameraMotionClips.map { var c = $0; c.id = UUID(); c.groupID = group(c.groupID); c.timing.startTime += time; return c }
        edits.mosaicClips = shifted(edits.mosaicClips, timing: \.timing, id: \.id, by: time)
        edits.stickerClips = shifted(edits.stickerClips, timing: \.timing, id: \.id, by: time)
        edits.animationClips = shifted(edits.animationClips, timing: \.timing, id: \.id, by: time)
        edits.audioClips = shifted(edits.audioClips, timing: \.timing, id: \.id, by: time)
        edits.videoClips = shifted(edits.videoClips, timing: \.timing, id: \.id, by: time)
        edits.isolateCopiedVideoAudio(ids: Set(segmentIDs.values).union(edits.videoClips.map(\.id)).union(edits.audioClips.map(\.id)))
        edits.subtitleCues = shifted(edits.subtitleCues, timing: \.timing, id: \.id, by: time)
        edits.mediaAssets = edits.mediaAssets.map { var a = $0; a.id = UUID(); return a }
        let placeholderID = UUID()
        // Reuse the main-track ripple/split implementation. Split effects at
        // the insertion point first so imported edits have their own interval.
        var timeline = splitEdits(current.timeline, at: time)
        timeline = try ProjectTimelineEditing.insertMediaSegment(in: timeline,
            media: InsertedMedia(path: "import-placeholder", fileDuration: incomingMap.outputDuration, name: ""),
            atOutputTime: time, duration: incomingMap.outputDuration,
            newSegmentID: placeholderID, sourceDurations: durations)
        guard case var .edited(authored) = timeline.sourceSequence,
              let index = authored.firstIndex(where: { $0.id == placeholderID }) else {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
        authored.replaceSubrange(index...index, with: segments)
        timeline.sourceSequence = .edited(authored)
        timeline.primarySegmentAudioOverrides.merge(edits.primarySegmentAudioOverrides) { _, new in new }
        timeline.zoomClips += edits.zoomClips
        timeline.screenMotionClips += edits.screenMotionClips
        timeline.cameraMotionClips += edits.cameraMotionClips
        timeline.mosaicClips += edits.mosaicClips
        timeline.stickerClips += edits.stickerClips
        timeline.animationClips += edits.animationClips
        timeline.audioClips += edits.audioClips
        timeline.videoClips += edits.videoClips
        timeline.subtitleCues += edits.subtitleCues
        timeline.mediaAssets += edits.mediaAssets
        timeline.zoomClips.sort { $0.startTime < $1.startTime }
        timeline.screenMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
        timeline.cameraMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
        result.timeline = timeline
        result.recordingMarkers += imported.recordingMarkers.compactMap { marker in
            sourceIDs[marker.resolvedSourceID].map {
                RecordingMarker(sourceTime: marker.sourceTime, number: marker.number, sourceID: $0)
            }
        }
        try ProjectTimelineEditing.validate(timeline, sourceDurations: durations)
        try ProjectValidator.validate(result)
        return result
    }

    public static func insertionTime(_ requested: TimeInterval, map: TimelineMap) -> TimeInterval {
        let time = min(max(requested.isFinite ? requested : map.outputDuration, 0), map.outputDuration)
        guard let segment = map.segment(atOutputTime: time) else { return map.outputDuration }
        if time - segment.outputStart < 1.0 / 60 { return segment.outputStart }
        if segment.outputEnd - time < 1.0 / 60 { return segment.outputEnd }
        return time
    }

    private static func shifted<C>(_ clips: [C], timing: WritableKeyPath<C, OverlayTiming>,
                                    id: WritableKeyPath<C, UUID>, by delta: Double) -> [C] {
        clips.map { var c = $0; c[keyPath: id] = UUID(); c[keyPath: timing].startTime += delta; return c }
    }

    private static func boundedEdits(_ original: ProjectTimeline, endingAt end: Double) -> ProjectTimeline {
        var t = original
        t.zoomClips = t.zoomClips.filter { $0.startTime < end }.map { c in
            var c = c; c.endTime = min(c.endTime, end); c.exitDuration = min(c.exitDuration, max(end - c.endTime, 0)); return c
        }
        t.screenMotionClips = boundTransitions(t.screenMotionClips, timing: \.timing, end: end)
        t.cameraMotionClips = boundTransitions(t.cameraMotionClips, timing: \.timing, end: end)
        t.mosaicClips = boundOverlays(t.mosaicClips, timing: \.timing, end: end)
        t.stickerClips = boundOverlays(t.stickerClips, timing: \.timing, end: end)
        t.animationClips = boundOverlays(t.animationClips, timing: \.timing, end: end)
        t.audioClips = boundOverlays(t.audioClips, timing: \.timing, end: end)
        t.videoClips = boundOverlays(t.videoClips, timing: \.timing, end: end)
        t.subtitleCues = boundOverlays(t.subtitleCues, timing: \.timing, end: end)
        return t
    }

    private static func boundTransitions<C>(_ clips: [C], timing: WritableKeyPath<C, TransitionTiming>, end: Double) -> [C] {
        clips.filter { $0[keyPath: timing].startTime < end }.map {
            var c = $0; var t = c[keyPath: timing]
            t.duration = min(t.duration, end - t.startTime)
            t.returnDuration = min(t.returnDuration, max(end - t.endTime, 0)); c[keyPath: timing] = t; return c
        }
    }
    private static func boundOverlays<C>(_ clips: [C], timing: WritableKeyPath<C, OverlayTiming>, end: Double) -> [C] {
        clips.filter { $0[keyPath: timing].startTime < end }.map {
            var c = $0; c[keyPath: timing].duration = min(c[keyPath: timing].duration, end - c[keyPath: timing].startTime); return c
        }
    }

    /// A programme inserted through an existing effect splits that effect.
    /// The right fragment resumes its original media/animation phase after
    /// the imported interval rather than stretching music or covering it.
    static func splitEdits(_ original: ProjectTimeline, at time: Double) -> ProjectTimeline {
        var t = original
        t.zoomClips = t.zoomClips.flatMap { old -> [ZoomAnimationClip] in
            guard old.startTime < time else { return [old] }
            var left = old
            left.endTime = min(old.endTime, time)
            left.exitDuration = min(old.exitDuration, max(time - left.endTime, 0))
            guard old.endTime > time else { return [left] }
            var right = old; right.id = UUID(); right.startTime = time
            let elapsed = max(time - old.startTime, 0)
            right.enterProgressOffset = continued(old.enterProgressOffset, elapsed: elapsed, duration: old.enterDuration)
            right.enterDuration = max(old.enterDuration - elapsed, 0)
            return [left, right]
        }
        let originalMotionIDs = Set(t.screenMotionClips.map(\.id) + t.cameraMotionClips.map(\.id))
        var rightGroups: [UUID: UUID] = [:]
        func splitGroup(_ group: UUID?, clipID: UUID) -> UUID? {
            guard let group, !originalMotionIDs.contains(clipID) else { return group }
            if let id = rightGroups[group] { return id }
            let id = UUID(); rightGroups[group] = id; return id
        }
        t.screenMotionClips = splitTransitions(t.screenMotionClips, timing: \.timing, id: \.id, at: time).map {
            var clip = $0; clip.groupID = splitGroup(clip.groupID, clipID: clip.id); return clip
        }
        t.cameraMotionClips = splitTransitions(t.cameraMotionClips, timing: \.timing, id: \.id, at: time).map {
            var clip = $0; clip.groupID = splitGroup(clip.groupID, clipID: clip.id); return clip
        }
        t.mosaicClips = splitOverlays(t.mosaicClips, timing: \.timing, id: \.id, at: time)
        t.stickerClips = splitOverlays(t.stickerClips, timing: \.timing, id: \.id, at: time) { c, offset in
            if offset > 0 { c.enterDuration = 0 } else { c.exitDuration = 0 }
        }
        t.animationClips = splitOverlays(t.animationClips, timing: \.timing, id: \.id, at: time) { $0.timeOffset += $1 * $0.playbackRate }
        t.audioClips = splitOverlays(t.audioClips, timing: \.timing, id: \.id, at: time) { c, offset in
            c.sourceStart += offset * c.playbackRate
            if offset > 0 { c.fadeIn = 0 } else { c.fadeOut = 0 }
        }
        t.videoClips = splitVideos(t.videoClips, at: time)
        t.subtitleCues = splitOverlays(t.subtitleCues, timing: \.timing, id: \.id, at: time)
        return t
    }
    private static func continued(_ phase: Double, elapsed: Double, duration: Double) -> Double {
        duration > 0 ? min(phase + (1 - phase) * elapsed / duration, 1) : 1
    }
    private static func splitTransitions<C>(_ clips: [C], timing: WritableKeyPath<C, TransitionTiming>,
                                           id: WritableKeyPath<C, UUID>, at time: Double) -> [C] {
        clips.flatMap { old -> [C] in
            let before = old[keyPath: timing]
            guard before.startTime < time else { return [old] }
            var left = old
            left[keyPath: timing].duration = min(before.duration, time - before.startTime)
            left[keyPath: timing].returnDuration = min(before.returnDuration, max(time - left[keyPath: timing].endTime, 0))
            guard before.endTime > time else { return [left] }
            var right = old; right[keyPath: id] = UUID()
            var after = before
            after.startTime = time; after.duration = before.endTime - time
            after.leadInProgressOffset = continued(before.leadInProgressOffset, elapsed: time - before.startTime, duration: before.leadInDuration)
            after.leadInDuration = max(before.leadInDuration - (time - before.startTime), 0)
            right[keyPath: timing] = after
            return [left, right]
        }
    }
    static func splitVideos(_ clips: [VideoClip], at time: Double) -> [VideoClip] {
        splitOverlays(clips, timing: \.timing, id: \.id, at: time) { clip, elapsed in
            clip.sourceStart += elapsed * clip.playbackRate
        }
    }

    private static func splitOverlays<C>(_ clips: [C], timing: WritableKeyPath<C, OverlayTiming>,
                                        id: WritableKeyPath<C, UUID>, at time: Double,
                                        adjusting: (inout C, Double) -> Void = { _, _ in }) -> [C] {
        clips.flatMap { old -> [C] in
            let before = old[keyPath: timing]
            guard before.startTime < time, before.endTime > time else { return [old] }
            var left = old; left[keyPath: timing].duration = time - before.startTime; adjusting(&left, 0)
            var right = old; right[keyPath: id] = UUID()
            right[keyPath: timing] = OverlayTiming(startTime: time, duration: before.endTime - time)
            adjusting(&right, time - before.startTime)
            return [left, right]
        }
    }
}
