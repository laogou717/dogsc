import Foundation
import RecorderCore

/// Native object edits use the same Codable data and validators as the
/// inspector. A partial patch preserves every field it does not name.
enum AgentTimelineAccess {
    struct AccessError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func revision(_ project: RecorderProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AgentOperationLog.digest(try encoder.encode(project))
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }

    static func inspect(project: RecorderProject, durations: [UUID: Double], ids: Set<UUID>?) throws -> [String: Any] {
        let t = project.timeline
        var rows: [[String: Any]] = []
        func append<T: Encodable & Identifiable>(_ clips: [T], kind: String) throws where T.ID == UUID {
            for clip in clips where ids == nil || ids!.contains(clip.id) {
                rows.append(["id": clip.id.uuidString, "kind": kind, "value": try object(clip)])
            }
        }
        try append(t.zoomClips, kind: "zoom")
        try append(t.screenMotionClips, kind: "motion3d")
        try append(t.cameraMotionClips, kind: "cameraMotion")
        try append(t.mosaicClips, kind: "highlight")
        try append(t.stickerClips, kind: "sticker")
        try append(t.animationClips, kind: "animation")
        try append(t.videoClips, kind: "video")
        try append(t.audioClips, kind: "audio")
        try append(t.subtitleCues, kind: "subtitle")
        let map = try TimelineMap(sourceSequence: t.sourceSequence, sourceDurations: durations)
        for segment in map.segments where ids == nil || ids!.contains(segment.id) {
            var row: [String: Any] = ["id": segment.id.uuidString, "kind": "main",
                "start": segment.outputStart, "end": segment.outputEnd,
                "value": ["audio": try object(t.primarySegmentAudioOverrides[segment.id] ?? PrimarySegmentAudioOverrides()),
                          "source": ["start": segment.sourceStart, "end": segment.sourceEnd, "speed": segment.playbackRate],
                          "sceneStyle": try segment.sceneStyle.map { try object($0) } as Any? ?? NSNull(),
                          "media": try segment.media.map { try object($0) } as Any? ?? NSNull()] as [String: Any]]
            var source: [String: Any] = ["start": segment.sourceStart, "end": segment.sourceEnd,
                                         "speed": segment.playbackRate]
            if let media = segment.media { source["mediaPath"] = media.path }
            else { source["id"] = segment.sourceID.uuidString }
            row["source"] = source
            row["availableSource"] = ["start": 0, "end": segment.media?.fileDuration ?? durations[segment.sourceID] ?? segment.sourceEnd]
            rows.append(row)
        }
        if let ids {
            let found = Set(rows.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
            guard found == ids else { throw AccessError(message: "Some IDs are no longer on the timeline. Read the current timeline.") }
        }
        return ["revision": try revision(project), "objects": rows]
    }

    static func updated(project: RecorderProject, changes: [[String: Any]], durations: [UUID: Double]) throws -> ProjectTimeline {
        guard !changes.isEmpty else { throw AccessError(message: "changes [{id,patch}] is required.") }
        var t = project.timeline
        var visualTimingChanged = false
        var explicitVisualLayer = false
        func update<T: Codable & Identifiable>(_ clips: inout [T], id: UUID, patch: [String: Any]) throws -> Bool where T.ID == UUID {
            guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }
            clips[index] = try patched(clips[index], patch: patch)
            return true
        }
        for item in changes {
            guard let rawID = item["id"] as? String, let id = UUID(uuidString: rawID),
                  let patch = item["patch"] as? [String: Any], !patch.isEmpty, patch["id"] == nil else {
                throw AccessError(message: "Each change needs a valid id and nonempty patch; object IDs are immutable.")
            }
            if let index = t.zoomClips.firstIndex(where: { $0.id == id }) {
                var clip = t.zoomClips[index]
                clip.preserveTransitionIntent(defaultTransition: project.motion.defaultZoomTransitionDuration)
                var change = patch
                for (duration, preferred) in [("enterDuration", "preferredEnterDuration"), ("exitDuration", "preferredExitDuration")] {
                    if let value = patch[duration], patch[preferred] == nil { change[preferred] = value }
                }
                t.zoomClips[index] = try patched(clip, patch: change)
                continue
            }
            if try update(&t.screenMotionClips, id: id, patch: patch) { continue }
            if try update(&t.cameraMotionClips, id: id, patch: patch) { continue }
            if try update(&t.mosaicClips, id: id, patch: patch) { continue }
            if try update(&t.stickerClips, id: id, patch: patch) {
                visualTimingChanged = visualTimingChanged || patch["timing"] != nil
                explicitVisualLayer = explicitVisualLayer || patch["layerIndex"] != nil
                continue
            }
            if try update(&t.animationClips, id: id, patch: patch) {
                visualTimingChanged = visualTimingChanged || patch["timing"] != nil
                explicitVisualLayer = explicitVisualLayer || patch["layerIndex"] != nil
                continue
            }
            if try update(&t.videoClips, id: id, patch: patch) {
                visualTimingChanged = visualTimingChanged || patch["timing"] != nil
                explicitVisualLayer = explicitVisualLayer || patch["layerIndex"] != nil
                continue
            }
            if try update(&t.audioClips, id: id, patch: patch) { continue }
            if try update(&t.subtitleCues, id: id, patch: patch) { continue }
            let map = try TimelineMap(sourceSequence: t.sourceSequence, sourceDurations: durations)
            guard let index = map.segments.firstIndex(where: { $0.id == id }) else {
                throw AccessError(message: "Object \(id) is no longer on the timeline; nothing was changed.")
            }
            let unknown = patch.keys.filter { !["media", "sceneStyle", "audio", "source"].contains($0) }
            guard unknown.isEmpty else {
                throw AccessError(message: "Main clip patches use source {start,end,speed}, media, sceneStyle or audio. Unknown keys: \(unknown.sorted()).")
            }
            var segments = map.segments.map {
                RecordingSegment(id: $0.id, sourceStart: $0.sourceStart, sourceDuration: $0.sourceDuration,
                    playbackRate: $0.playbackRate, media: $0.media, sourceID: $0.sourceID, sceneStyle: $0.sceneStyle,
                    crop: $0.crop)
            }
            if let value = patch["audio"] {
                if value is NSNull { t.primarySegmentAudioOverrides[id] = nil }
                else if let change = value as? [String: Any] {
                    t.primarySegmentAudioOverrides[id] = try patched(t.primarySegmentAudioOverrides[id] ?? .init(), patch: change)
                } else { throw AccessError(message: "audio must be an object or null.") }
            }
            var segmentPatch = patch
            segmentPatch["audio"] = nil
            segmentPatch["source"] = nil
            if !segmentPatch.isEmpty { segments[index] = try patched(segments[index], patch: segmentPatch) }
            t.sourceSequence = .edited(segments)
            if let source = patch["source"] {
                guard let source = source as? [String: Any] else {
                    throw AccessError(message: "source must be {start?,end?,speed?} in source seconds.")
                }
                t = try updatingSource(source, id: id, timeline: t, durations: durations,
                                       transition: project.motion.defaultZoomTransitionDuration)
            }
        }
        if visualTimingChanged && !explicitVisualLayer { t.organizeVisualLayers() }
        try ProjectTimelineEditing.validate(t, sourceDurations: durations)
        var next = project; next.timeline = t
        try ProjectValidator.validate(next)
        return t
    }

    /// Reuse the editor's edge trims: media, captions and effects retain the
    /// same ripple behaviour, and the entire batch remains one undoable edit.
    private static func updatingSource(_ patch: [String: Any], id: UUID, timeline: ProjectTimeline,
                                       durations: [UUID: Double], transition: Double) throws -> ProjectTimeline {
        let unknown = patch.keys.filter { !["start", "end", "speed"].contains($0) }
        guard unknown.isEmpty else { throw AccessError(message: "Unknown source fields: \(unknown.sorted()).") }
        func segment(in timeline: ProjectTimeline) throws -> ResolvedRecordingSegment {
            let map = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: durations)
            guard let value = map.segments.first(where: { $0.id == id }) else {
                throw AccessError(message: "Main clip is no longer on the timeline.")
            }
            return value
        }
        let original = try segment(in: timeline)
        func number(_ key: String, default value: Double) throws -> Double {
            guard let raw = patch[key] else { return value }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw AccessError(message: "source.\(key) must be a finite number.")
            }
            return number.doubleValue
        }
        let start = try number("start", default: original.sourceStart)
        let end = try number("end", default: original.sourceEnd)
        let speed = try number("speed", default: original.playbackRate)
        let available = original.media?.fileDuration ?? durations[original.sourceID] ?? 0
        guard start >= 0, end > start, end <= available,
              (RecordingSegment.minimumPlaybackRate...RecordingSegment.maximumPlaybackRate).contains(speed) else {
            throw AccessError(message: "Source range must be nonempty and inside the media; speed must be within the editor's supported range. Nothing was changed.")
        }
        var result = timeline
        func trim(_ edge: RecordingSegmentTrimEdge, to sourceTime: Double) throws {
            let current = try segment(in: result)
            let outputTime = current.outputStart + (sourceTime - current.sourceStart) / current.playbackRate
            result = try ProjectTimelineEditing.trimPrimarySegment(in: result, segmentID: id, edge: edge,
                toOutputTime: outputTime, sourceDurations: durations, defaultTransitionDuration: transition)
        }
        // Extend first, so moving a range wholly outside its former interval
        // never temporarily removes the clip or loses its stable ID.
        if start < original.sourceStart { try trim(.left, to: start) }
        if end > original.sourceEnd { try trim(.right, to: end) }
        if start > original.sourceStart { try trim(.left, to: start) }
        if end < original.sourceEnd { try trim(.right, to: end) }
        if speed != original.playbackRate {
            result = try ProjectTimelineEditing.settingPlaybackRate(speed, for: id, in: result, sourceDurations: durations)
        }
        return result
    }

    private static func patched<T: Codable>(_ value: T, patch: [String: Any]) throws -> T {
        let before = try object(value)
        func merge(_ base: Any?, _ change: Any) -> Any {
            guard let change = change as? [String: Any] else { return change }
            var result = base as? [String: Any] ?? [:]
            for (key, child) in change { result[key] = merge(result[key], child) }
            return result
        }
        let data = try JSONSerialization.data(withJSONObject: merge(before, patch))
        let next = try JSONDecoder().decode(T.self, from: data)
        let actual = try object(next)
        func check(_ patch: [String: Any], actual: [String: Any], path: String) throws {
            for (key, expected) in patch {
                let field = path.isEmpty ? key : path + "." + key
                if expected is NSNull, actual[key] == nil || actual[key] is NSNull { continue }
                guard let received = actual[key] else { throw AccessError(message: "Unknown or unsupported field: \(field). Nothing was changed.") }
                if let expected = expected as? [String: Any], let received = received as? [String: Any] {
                    try check(expected, actual: received, path: field)
                } else if !NSDictionary(dictionary: ["value": expected]).isEqual(to: ["value": received]) {
                    throw AccessError(message: "Invalid value for \(field); the native object cannot represent it exactly. Nothing was changed.")
                }
            }
        }
        try check(patch, actual: actual, path: "")
        return next
    }
}
