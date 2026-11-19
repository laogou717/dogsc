import Foundation

public enum TimelineMapError: Error, Equatable, Sendable {
    case invalidFullSourceDuration
    case emptyEditedSequence
    case duplicateSegmentID(UUID)
    case invalidSegment(UUID)
    case segmentOutsideSource(UUID)
}

extension TimelineMapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFullSourceDuration:
            return "主录屏时长必须是正的有限数。"
        case .emptyEditedSequence:
            return "剪辑后至少需要保留一个主录屏片段。"
        case .duplicateSegmentID:
            return "时间线中存在重复的主片段。"
        case .invalidSegment:
            return "主片段包含无效的时间范围。"
        case .segmentOutsideSource:
            return "主片段超出原始录屏可用时长。"
        }
    }
}

public struct ResolvedRecordingSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let sourceStart: TimeInterval
    public let sourceDuration: TimeInterval
    public let playbackRate: Double
    public let outputStart: TimeInterval
    /// Non-nil for an inserted video: source times are in that file and the
    /// recording's camera, audio and pointer are absent for this span.
    public let media: InsertedMedia?
    public let sceneStyle: SegmentSceneStyle?
    /// nil follows the recording source's crop; a value is this occurrence's own.
    public let crop: NormalizedCrop?

    public init(
        id: UUID,
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval,
        playbackRate: Double = 1,
        outputStart: TimeInterval,
        media: InsertedMedia? = nil,
        sourceID: UUID = RecordingSource.primaryID,
        sceneStyle: SegmentSceneStyle? = nil,
        crop: NormalizedCrop? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.playbackRate = playbackRate
        self.outputStart = outputStart
        self.media = media
        self.sceneStyle = sceneStyle
        self.crop = crop
    }

    public var isInserted: Bool { media != nil }

    public var sourceEnd: TimeInterval { sourceStart + sourceDuration }
    public var outputDuration: TimeInterval { sourceDuration / playbackRate }
    public var outputEnd: TimeInterval { outputStart + outputDuration }


    public var outputRange: MediaTimeRange? {
        MediaTimeRange(start: outputStart, duration: outputDuration)
    }
}

/// Pointer events are kept in groups across cuts. Flattening them would let an
/// interpolator travel through a deleted interval toward the next segment's
/// first position, creating motion that never existed in the finished video.
public struct TimelineMappedPointerSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let outputRange: MediaTimeRange
    public let events: [PointerEventRecord]

    public init(
        id: UUID,
        outputRange: MediaTimeRange,
        events: [PointerEventRecord],
        sourceID: UUID = RecordingSource.primaryID
    ) {
        self.id = id
        self.sourceID = sourceID
        self.outputRange = outputRange
        self.events = events
    }
}

/// A recording time is meaningful only with its source and occurrence.
public struct RecordingSourcePosition: Equatable, Sendable {
    public let sourceID: UUID
    public let segmentID: UUID
    public let time: TimeInterval
}

public struct RecordingOutputPosition: Equatable, Identifiable, Sendable {
    public let segmentID: UUID
    public let time: TimeInterval
    public var id: UUID { segmentID }
}

/// Array order is output order. A source interval may occur repeatedly; the
/// segment ID disambiguates each independently editable use of that interval.
public struct TimelineMap: Equatable, Sendable {
    public static let fullRecordingSegmentID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    )!

    public let segments: [ResolvedRecordingSegment]
    public let sourceDurations: [UUID: TimeInterval]

    @available(*, deprecated, message: "Use sourceDurations with an explicit recording source ID.")
    public var fullSourceDuration: TimeInterval { sourceDurations[RecordingSource.primaryID] ?? 0 }

    @available(*, deprecated, message: "Use init(sourceSequence:sourceDurations:) for independent recording clocks.")
    public init(
        sourceSequence: SourceSequence,
        fullSourceDuration: TimeInterval
    ) throws {
        try self.init(sourceSequence: sourceSequence, sourceDurations: [RecordingSource.primaryID: fullSourceDuration])
    }

    public init(sourceSequence: SourceSequence, sourceDurations: [UUID: TimeInterval]) throws {
        guard sourceDurations.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw TimelineMapError.invalidFullSourceDuration
        }
        self.sourceDurations = sourceDurations

        let authored: [RecordingSegment]
        switch sourceSequence {
        case .fullRecording:
            guard let primaryDuration = sourceDurations[RecordingSource.primaryID] else {
                throw TimelineMapError.invalidFullSourceDuration
            }
            authored = [
                RecordingSegment(
                    id: Self.fullRecordingSegmentID,
                    sourceStart: 0,
                    sourceDuration: primaryDuration
                ),
            ]
        case let .edited(edited):
            guard !edited.isEmpty else {
                throw TimelineMapError.emptyEditedSequence
            }
            authored = edited
        }

        var identifiers = Set<UUID>()
        var outputStart: TimeInterval = 0
        var resolved: [ResolvedRecordingSegment] = []
        let epsilon = 1.0 / 120_000.0

        for segment in authored {
            guard identifiers.insert(segment.id).inserted else {
                throw TimelineMapError.duplicateSegmentID(segment.id)
            }
            guard segment.sourceStart.isFinite,
                  segment.sourceDuration.isFinite,
                  segment.playbackRate.isFinite,
                  segment.sourceStart >= 0,
                  segment.sourceDuration > 0,
                  segment.playbackRate > 0,
                  segment.sourceEnd.isFinite else {
                throw TimelineMapError.invalidSegment(segment.id)
            }
            guard let availableDuration = segment.media?.fileDuration ?? sourceDurations[segment.resolvedSourceID],
                  availableDuration.isFinite, availableDuration > 0,
                  segment.sourceStart < availableDuration,
                  segment.sourceEnd <= availableDuration + epsilon else {
                throw TimelineMapError.segmentOutsideSource(segment.id)
            }
            let resolvedDuration = min(
                segment.sourceDuration,
                availableDuration - segment.sourceStart
            )
            guard resolvedDuration > 0 else {
                throw TimelineMapError.segmentOutsideSource(segment.id)
            }
            resolved.append(
                ResolvedRecordingSegment(
                    id: segment.id,
                    sourceStart: segment.sourceStart,
                    sourceDuration: resolvedDuration,
                    playbackRate: segment.playbackRate,
                    outputStart: outputStart,
                    media: segment.media,
                    sourceID: segment.resolvedSourceID,
                    sceneStyle: segment.sceneStyle,
                    crop: segment.crop
                )
            )
            outputStart += resolvedDuration / segment.playbackRate
        }
        segments = resolved
    }

    public var outputDuration: TimeInterval {
        segments.last?.outputEnd ?? 0
    }

    public func segment(atOutputTime time: TimeInterval) -> ResolvedRecordingSegment? {
        guard time.isFinite, time >= 0, time < outputDuration else { return nil }
        var lower = segments.startIndex
        var upper = segments.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].outputEnd < time
                || TimelineMediaPlan.isSameBoundary(segments[middle].outputEnd, time) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < segments.endIndex else { return nil }
        let candidate = segments[lower]
        return time > candidate.outputStart
            || TimelineMediaPlan.isSameBoundary(time, candidate.outputStart) ? candidate : nil
    }

    public func sourcePosition(atOutputTime time: TimeInterval) -> RecordingSourcePosition? {
        guard let segment = segment(atOutputTime: time), !segment.isInserted else { return nil }
        return RecordingSourcePosition(sourceID: segment.sourceID, segmentID: segment.id,
            time: segment.sourceStart + max(time - segment.outputStart, 0) * segment.playbackRate)
    }

    @available(*, deprecated, message: "Use sourcePosition(atOutputTime:); a bare time loses its source identity.")
    public func sourceTime(atOutputTime time: TimeInterval) -> TimeInterval? {
        guard let position = sourcePosition(atOutputTime: time), position.sourceID == RecordingSource.primaryID else { return nil }
        return position.time
    }

    @available(*, deprecated, message: "Use outputPositions(forSourceTime:sourceID:) or outputTime(forSourceTime:inSegment:).")
    public func outputTime(forSourceTime time: TimeInterval) -> TimeInterval? {
        outputPositions(forSourceTime: time, sourceID: RecordingSource.primaryID).first?.time
    }

    public func outputPositions(forSourceTime time: TimeInterval, sourceID: UUID) -> [RecordingOutputPosition] {
        guard time.isFinite else { return [] }
        return segments.compactMap { segment in
            guard !segment.isInserted, segment.sourceID == sourceID,
                  time >= segment.sourceStart, time < segment.sourceEnd else { return nil }
            let mapped = segment.outputStart + (time - segment.sourceStart) / segment.playbackRate
            return RecordingOutputPosition(segmentID: segment.id, time: mapped)
        }
    }

    public func outputTime(forSourceTime time: TimeInterval, inSegment segmentID: UUID) -> TimeInterval? {
        guard time.isFinite, let segment = segments.first(where: { $0.id == segmentID }),
              time >= segment.sourceStart, time < segment.sourceEnd else { return nil }
        return segment.outputStart + (time - segment.sourceStart) / segment.playbackRate
    }

    /// Maps events into output time while retaining cut boundaries. Each group
    /// receives the most recent source position as a move seed when possible.
    @available(*, deprecated, message: "Use mapPointerEventSegments(eventsBySource:) to avoid sharing primary pointer events.")
    public func mapPointerEventSegments(
        _ sourceEvents: [PointerEventRecord]
    ) -> [TimelineMappedPointerSegment] {
        mapPointerEventSegments(eventsBySource: [RecordingSource.primaryID: sourceEvents])
    }

    public func mapPointerEventSegments(eventsBySource: [UUID: [PointerEventRecord]]) -> [TimelineMappedPointerSegment] {
        let orderedSources = eventsBySource.mapValues(PointerEventTimelineOrdering.normalized)
        return segments.compactMap { segment in
            // No recorded pointer exists inside an inserted video.
            guard segment.media == nil, let outputRange = segment.outputRange else { return nil }
            let ordered = orderedSources[segment.sourceID] ?? []
            let lowerIndex = Self.firstEventIndex(atOrAfter: segment.sourceStart, in: ordered)
            let upperIndex = Self.firstEventIndex(atOrAfter: segment.sourceEnd, in: ordered)
            let eventsInRange = ordered[lowerIndex..<upperIndex]
            var mapped: [PointerEventRecord] = []
            let startsWithExactEvent = eventsInRange.first.map {
                abs($0.time - segment.sourceStart) < 0.000_001
            } ?? false
            if !startsWithExactEvent,
               lowerIndex > ordered.startIndex {
                let seed = ordered[lowerIndex - 1]
                mapped.append(
                    PointerEventRecord(
                        time: segment.outputStart,
                        location: seed.location,
                        kind: .move,
                        modifiers: seed.modifiers,
                        cursorAssetID: seed.cursorAssetID
                    )
                )
            }
            mapped.append(contentsOf: eventsInRange.map { event in
                PointerEventRecord(
                    time: segment.outputStart
                        + (event.time - segment.sourceStart) / segment.playbackRate,
                    location: event.location,
                    kind: event.kind,
                    modifiers: event.modifiers,
                    cursorAssetID: event.cursorAssetID
                )
            })
            return TimelineMappedPointerSegment(
                id: segment.id,
                outputRange: outputRange,
                events: mapped,
                sourceID: segment.sourceID
            )
        }
    }

    private static func firstEventIndex(
        atOrAfter time: TimeInterval,
        in events: [PointerEventRecord]
    ) -> Int {
        var lower = events.startIndex
        var upper = events.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].time < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

}
