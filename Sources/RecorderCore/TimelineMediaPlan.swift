import Foundation

/// One retained source interval placed on the ripple output timeline.
/// The same plan drives preview compositions and deterministic export readers.
public struct TimelineMediaSlice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let segmentID: UUID
    public let sourceID: UUID
    public let outputStart: TimeInterval
    public let sourceStart: TimeInterval
    public let duration: TimeInterval
    public let sourceTimeScale: Double
    /// Inserted video this slice reads instead of the recording.
    public let media: InsertedMedia?

    public init(
        id: UUID = UUID(),
        segmentID: UUID,
        outputStart: TimeInterval,
        sourceStart: TimeInterval,
        duration: TimeInterval,
        sourceTimeScale: Double = 1,
        media: InsertedMedia? = nil,
        sourceID: UUID = RecordingSource.primaryID
    ) {
        self.id = id
        self.segmentID = segmentID
        self.sourceID = sourceID
        self.outputStart = outputStart
        self.sourceStart = sourceStart
        self.duration = duration
        self.media = media
        self.sourceTimeScale = sourceTimeScale.isFinite && sourceTimeScale > 0
            ? sourceTimeScale : 1
    }

    public var outputEnd: TimeInterval { outputStart + duration }

    public func sourceTime(atOutputTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite,
              time > outputStart
                || TimelineMediaPlan.isSameBoundary(time, outputStart),
              time < outputEnd else { return nil }
        // `TimelineMediaPlan.slice` may deliberately assign a rational media
        // timestamp that is a few ulps below a Double-authored cut to the next
        // slice. Clamp that representation-only delta to the slice start so a
        // second strict comparison cannot turn the selected slice into a gap.
        let elapsed = max(time - outputStart, 0)
        return sourceStart + elapsed * sourceTimeScale
    }
}

/// Final-time media placement generated from the one authoritative
/// `TimelineMap`. No preview/export implementation is allowed to invent its
/// own offset or cut mapping after this point.
public struct TimelineMediaPlan: Equatable, Sendable {
    /// Only used to snap arithmetic results back onto an already-authored
    /// primary cut. It is deliberately far smaller than any media frame so a
    /// real camera/audio availability gap remains a gap.
    private static let numericalBoundaryTolerance: TimeInterval = 0.000_000_001

    // Sample either side outside the primary cut's numeric snap tolerance.
    static let boundaryProbeOffset = 2 * numericalBoundaryTolerance

    public let outputDuration: TimeInterval
    public let slices: [TimelineMediaSlice]

    public init(primary timelineMap: TimelineMap) {
        outputDuration = timelineMap.outputDuration
        slices = timelineMap.segments.map {
            TimelineMediaSlice(
                id: $0.id,
                segmentID: $0.id,
                outputStart: $0.outputStart,
                sourceStart: $0.sourceStart,
                duration: $0.outputDuration,
                sourceTimeScale: $0.playbackRate,
                media: $0.media,
                sourceID: $0.sourceID
            )
        }
    }

    /// Intersects an auxiliary camera/microphone placement with every retained
    /// primary segment. Gaps remain gaps, while all surviving slices share the
    /// exact same output clock as the screen recording.
    public init(
        timelineMap: TimelineMap,
        auxiliary placement: MediaTimelinePlacement,
        sourceID: UUID = RecordingSource.primaryID,
        syncAnchors: [MediaSyncAnchor] = [],
        sourceAvailableRange: MediaTimeRange? = nil
    ) {
        outputDuration = timelineMap.outputDuration
        guard !syncAnchors.isEmpty else {
            slices = timelineMap.segments.compactMap { segment in
                // Camera and audio of the recording are absent in inserts.
                guard segment.media == nil, segment.sourceID == sourceID else { return nil }
                let retainedStart = max(segment.sourceStart, placement.timelineStart)
                let retainedEnd = min(segment.sourceEnd, placement.timelineEnd)
                let startsAtPrimaryBoundary = Self.isSameBoundary(
                    retainedStart,
                    segment.sourceStart
                )
                let endsAtPrimaryBoundary = Self.isSameBoundary(
                    retainedEnd,
                    segment.sourceEnd
                )
                let outputStart = startsAtPrimaryBoundary
                    ? segment.outputStart
                    : segment.outputStart
                        + (retainedStart - segment.sourceStart) / segment.playbackRate
                let duration: TimeInterval
                if startsAtPrimaryBoundary, endsAtPrimaryBoundary {
                    // Reuse the primary duration verbatim. Recomputing
                    // `(sourceStart + duration) - sourceStart` can be a few
                    // ulps shorter, leaving a microscopic hole at a cut. A
                    // 60 fps output frame landing in that hole loses camera.
                    duration = segment.outputDuration
                } else {
                    let outputEnd = endsAtPrimaryBoundary
                        ? segment.outputEnd
                        : segment.outputStart
                            + (retainedEnd - segment.sourceStart) / segment.playbackRate
                    duration = outputEnd - outputStart
                }
                guard duration > 0 else { return nil }
                return TimelineMediaSlice(
                    id: segment.id,
                    segmentID: segment.id,
                    outputStart: outputStart,
                    sourceStart: placement.sourceTime(at: retainedStart) ?? placement.sourceStart,
                    duration: duration,
                    sourceTimeScale: placement.sourceTimeScale * segment.playbackRate,
                    sourceID: sourceID
                )
            }
            return
        }

        let curve = MediaSyncAnchorCurve(syncAnchors)
        let availableStart = sourceAvailableRange?.start ?? 0
        let availableEnd = sourceAvailableRange?.end ?? .greatestFiniteMagnitude
        slices = timelineMap.segments.flatMap { segment -> [TimelineMediaSlice] in
            guard segment.media == nil, segment.sourceID == sourceID else { return [] }
            let retainedStart = max(segment.sourceStart, placement.timelineStart)
            let retainedEnd = min(segment.sourceEnd, placement.timelineEnd)
            guard retainedEnd - retainedStart > 0.000_001 else { return [] }

            var boundaries = [retainedStart]
            boundaries.append(contentsOf: syncAnchors.lazy
                .map(\.sourceTime)
                .filter { $0 > retainedStart + 0.000_001 && $0 < retainedEnd - 0.000_001 })
            boundaries.append(retainedEnd)
            boundaries.sort()

            return boundaries.indices.dropLast().compactMap { index in
                let primaryStart = boundaries[index]
                let primaryEnd = boundaries[index + 1]
                let startsAtPrimaryBoundary = Self.isSameBoundary(
                    primaryStart,
                    segment.sourceStart
                )
                let endsAtPrimaryBoundary = Self.isSameBoundary(
                    primaryEnd,
                    segment.sourceEnd
                )
                let outputStart = startsAtPrimaryBoundary
                    ? segment.outputStart
                    : segment.outputStart
                        + (primaryStart - segment.sourceStart) / segment.playbackRate
                let outputEnd = endsAtPrimaryBoundary
                    ? segment.outputEnd
                    : segment.outputStart
                        + (primaryEnd - segment.sourceStart) / segment.playbackRate
                let duration = startsAtPrimaryBoundary && endsAtPrimaryBoundary
                    ? segment.outputDuration
                    : outputEnd - outputStart
                guard duration > 0.000_001 else { return nil }

                let baseStart = placement.sourceStart
                    + (primaryStart - placement.timelineStart) * placement.sourceTimeScale
                let baseEnd = placement.sourceStart
                    + (primaryEnd - placement.timelineStart) * placement.sourceTimeScale
                let correctedStart = min(
                    max(baseStart + curve.offset(atSourceTime: primaryStart), availableStart),
                    availableEnd
                )
                let correctedEnd = min(
                    max(baseEnd + curve.offset(atSourceTime: primaryEnd), availableStart),
                    availableEnd
                )
                let correctedDuration = correctedEnd - correctedStart
                guard correctedDuration > 0.000_001 else { return nil }

                return TimelineMediaSlice(
                    id: segment.id,
                    segmentID: segment.id,
                    outputStart: outputStart,
                    sourceStart: correctedStart,
                    duration: duration,
                    sourceTimeScale: correctedDuration / duration,
                    sourceID: sourceID
                )
            }
        }
    }

    public var playableDuration: TimeInterval {
        slices.reduce(0) { $0 + $1.duration }
    }

    @available(*, deprecated, message: "Select a slice and use its sourceID together with sourceTime(atOutputTime:).")
    public func sourceTime(atOutputTime time: TimeInterval) -> TimeInterval? {
        guard let slice = slice(atOutputTime: time), slice.sourceID == RecordingSource.primaryID else { return nil }
        return slice.sourceTime(atOutputTime: time)
    }

    public func contains(outputTime time: TimeInterval) -> Bool {
        slice(atOutputTime: time) != nil
    }

    public func slice(atOutputTime time: TimeInterval) -> TimelineMediaSlice? {
        guard time.isFinite, time >= 0 else { return nil }
        var lower = slices.startIndex
        var upper = slices.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let end = slices[middle].outputEnd
            if end < time || Self.isSameBoundary(end, time) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < slices.endIndex else { return nil }
        let candidate = slices[lower]
        return time > candidate.outputStart
            || Self.isSameBoundary(time, candidate.outputStart)
            ? candidate : nil
    }

    static func isSameBoundary(
        _ lhs: TimeInterval,
        _ rhs: TimeInterval
    ) -> Bool {
        abs(lhs - rhs) <= numericalBoundaryTolerance
    }

    /// Auxiliary plans from different sources have disjoint output ranges.
    public init(outputDuration: TimeInterval, combining plans: [TimelineMediaPlan]) {
        self.outputDuration = outputDuration
        slices = plans.flatMap(\.slices).sorted { $0.outputStart < $1.outputStart }
    }

    /// Restrict decoding to an export window without rebasing the authored
    /// clock used by subtitles, camera, motion and per-segment appearance.
    public init(clipping plan: TimelineMediaPlan, to range: MediaTimeRange) {
        outputDuration = plan.outputDuration
        slices = plan.slices.compactMap { slice in
            let start = max(slice.outputStart, range.start)
            let end = min(slice.outputEnd, range.end)
            guard end > start, !Self.isSameBoundary(start, end) else { return nil }
            return TimelineMediaSlice(
                id: slice.id,
                segmentID: slice.segmentID,
                outputStart: start,
                sourceStart: slice.sourceStart + (start - slice.outputStart) * slice.sourceTimeScale,
                duration: end - start,
                sourceTimeScale: slice.sourceTimeScale,
                media: slice.media,
                sourceID: slice.sourceID
            )
        }
    }
}

/// Validated source-clock inventory. Asset loading stays outside RecorderCore.
public struct RecordingSourceMedia: Equatable, Sendable {
    public var manifest: ProjectMediaManifest?
    public var videoRange: MediaTimeRange
    public var systemAudioRange: MediaTimeRange?
    public var cameraRange: MediaTimeRange?
    public var microphoneRange: MediaTimeRange?
    public var pointerEvents: [PointerEventRecord]

    public init(manifest: ProjectMediaManifest?, videoRange: MediaTimeRange,
                systemAudioRange: MediaTimeRange? = nil, cameraRange: MediaTimeRange? = nil,
                microphoneRange: MediaTimeRange? = nil, pointerEvents: [PointerEventRecord] = []) {
        self.manifest = manifest
        self.videoRange = videoRange
        self.systemAudioRange = systemAudioRange
        self.cameraRange = cameraRange
        self.microphoneRange = microphoneRange
        self.pointerEvents = pointerEvents
    }
}

/// Every time-bearing source resolved onto one final output clock. Missing
/// auxiliary tracks remain gaps; they never borrow another source's media.
public struct ProjectTimelineMediaPlan: Equatable, Sendable {
    public let timelineMap: TimelineMap
    public let primary: TimelineMediaPlan
    public let systemAudio: TimelineMediaPlan?
    public let camera: TimelineMediaPlan?
    public let microphone: TimelineMediaPlan?
    public let pointer: ProjectPointerTrack
    public let sources: [UUID: RecordingSourceMedia]
    public var sourceTimeOffsets: [UUID: TimeInterval] { sources.mapValues { $0.videoRange.start } }

    @available(*, deprecated, message: "Use sourceTimeOffsets with the slice's sourceID.")
    public var primarySourceTimeOffset: TimeInterval { sources[RecordingSource.primaryID]?.videoRange.start ?? 0 }

    @available(*, deprecated, message: "Use init(sourceSequence:sources:) so each recording has independent media.")
    public init(
        sourceSequence: SourceSequence,
        mediaManifest: ProjectMediaManifest?,
        primaryVideoRange: MediaTimeRange,
        systemAudioRange: MediaTimeRange? = nil,
        cameraRange: MediaTimeRange? = nil,
        microphoneRange: MediaTimeRange? = nil,
        sourcePointerEvents: [PointerEventRecord] = []
    ) throws {
        try self.init(sourceSequence: sourceSequence, sources: [RecordingSource.primaryID: RecordingSourceMedia(
            manifest: mediaManifest, videoRange: primaryVideoRange, systemAudioRange: systemAudioRange,
            cameraRange: cameraRange, microphoneRange: microphoneRange, pointerEvents: sourcePointerEvents)])
    }

    public init(sourceSequence: SourceSequence, sources: [UUID: RecordingSourceMedia]) throws {
        self.sources = sources
        let map = try TimelineMap(sourceSequence: sourceSequence,
                                  sourceDurations: sources.mapValues { $0.videoRange.duration })
        timelineMap = map
        primary = TimelineMediaPlan(primary: map)
        var systemPlans: [TimelineMediaPlan] = []
        var cameraPlans: [TimelineMediaPlan] = []
        var microphonePlans: [TimelineMediaPlan] = []
        var events: [UUID: [PointerEventRecord]] = [:]
        for (id, source) in sources {
            if let range = source.systemAudioRange {
                let sharedStart = max(range.start, source.videoRange.start)
                let placement = MediaTimelinePlacement(
                    reference: ProjectMediaReference(
                        relativePath: source.manifest?.screen.relativePath ?? "screen",
                        startOffset: max(range.start - source.videoRange.start, 0), sourceStartTime: sharedStart),
                    sourceAvailableStart: range.start, sourceAvailableDuration: range.duration,
                    timelineDuration: source.videoRange.duration)
                systemPlans.append(TimelineMediaPlan(timelineMap: map, auxiliary: placement, sourceID: id))
            }
            if let camera = Self.auxiliaryPlan(reference: source.manifest?.camera, availableRange: source.cameraRange,
                sourceID: id, timelineMap: map, timelineDuration: source.videoRange.duration) {
                cameraPlans.append(camera)
            }
            if let microphone = Self.auxiliaryPlan(reference: source.manifest?.microphone, availableRange: source.microphoneRange,
                sourceID: id, timelineMap: map, timelineDuration: source.videoRange.duration) {
                microphonePlans.append(microphone)
            }
            events[id] = PointerTimelineAlignment.align(source.pointerEvents,
                startOffset: source.manifest?.pointerEvents?.startOffset ?? 0,
                sourceStartTime: source.manifest?.pointerEvents?.sourceStartTime ?? 0)
        }
        systemAudio = systemPlans.isEmpty ? nil : TimelineMediaPlan(outputDuration: map.outputDuration, combining: systemPlans)
        camera = cameraPlans.isEmpty ? nil : TimelineMediaPlan(outputDuration: map.outputDuration, combining: cameraPlans)
        microphone = microphonePlans.isEmpty ? nil : TimelineMediaPlan(outputDuration: map.outputDuration, combining: microphonePlans)
        pointer = ProjectPointerTrack(timelineMap: map, eventsBySource: events)
    }

    public var outputDuration: TimeInterval { primary.outputDuration }

    private static func auxiliaryPlan(
        reference: ProjectMediaReference?, availableRange: MediaTimeRange?, sourceID: UUID,
        timelineMap: TimelineMap, timelineDuration: TimeInterval
    ) -> TimelineMediaPlan? {
        guard let reference, let availableRange else { return nil }
        let placement = MediaTimelinePlacement(reference: reference,
            sourceAvailableStart: availableRange.start, sourceAvailableDuration: availableRange.duration,
            timelineDuration: timelineDuration)
        return TimelineMediaPlan(timelineMap: timelineMap, auxiliary: placement, sourceID: sourceID,
            syncAnchors: reference.syncAnchors, sourceAvailableRange: availableRange)
    }
}
