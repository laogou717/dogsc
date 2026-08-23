import Foundation

public enum TimelineMapError: Error, Equatable, Sendable {
    case invalidFullSourceDuration
    case emptyEditedSequence
    case duplicateSegmentID(UUID)
    case invalidSegment(UUID)
    case segmentOutsideSource(UUID)
    case nonMonotonicSegments(previous: UUID, current: UUID)
}

extension TimelineMapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFullSourceDuration:
            return "主录屏时长必须是正的有限数。"
        case .emptyEditedSequence:
            return "剪辑后至少需要保留一个主录屏片段。"
        case let .duplicateSegmentID(id):
            return "主片段 ID 重复：\(id)。"
        case let .invalidSegment(id):
            return "主片段 \(id) 包含非有限、负数或空时长。"
        case let .segmentOutsideSource(id):
            return "主片段 \(id) 超出原始录屏可用时长。"
        case let .nonMonotonicSegments(previous, current):
            return "主片段不能重复使用同一段源素材：\(previous) / \(current)。"
        }
    }
}

public struct ResolvedRecordingSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceStart: TimeInterval
    public let sourceDuration: TimeInterval
    public let outputStart: TimeInterval

    public init(
        id: UUID,
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval,
        outputStart: TimeInterval
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.outputStart = outputStart
    }

    public var sourceEnd: TimeInterval { sourceStart + sourceDuration }
    public var outputEnd: TimeInterval { outputStart + sourceDuration }

    public var sourceRange: MediaTimeRange? {
        MediaTimeRange(start: sourceStart, duration: sourceDuration)
    }

    public var outputRange: MediaTimeRange? {
        MediaTimeRange(start: outputStart, duration: sourceDuration)
    }
}

/// Pointer events are kept in groups across cuts. Flattening them would let an
/// interpolator travel through a deleted interval toward the next segment's
/// first position, creating motion that never existed in the finished video.
public struct TimelineMappedPointerSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let outputRange: MediaTimeRange
    public let events: [PointerEventRecord]

    public init(
        id: UUID,
        outputRange: MediaTimeRange,
        events: [PointerEventRecord]
    ) {
        self.id = id
        self.outputRange = outputRange
        self.events = events
    }
}

/// Pure mapping between the final ripple timeline and the original recording
/// clock. Array order is output order; source ranges may be rearranged but
/// remain non-overlapping so every original source instant has one owner.
public struct TimelineMap: Equatable, Sendable {
    public static let fullRecordingSegmentID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    )!

    public let segments: [ResolvedRecordingSegment]
    public let fullSourceDuration: TimeInterval

    public init(
        sourceSequence: SourceSequence,
        fullSourceDuration: TimeInterval
    ) throws {
        guard fullSourceDuration.isFinite, fullSourceDuration > 0 else {
            throw TimelineMapError.invalidFullSourceDuration
        }
        self.fullSourceDuration = fullSourceDuration

        let authored: [RecordingSegment]
        switch sourceSequence {
        case .fullRecording:
            authored = [
                RecordingSegment(
                    id: Self.fullRecordingSegmentID,
                    sourceStart: 0,
                    sourceDuration: fullSourceDuration
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
                  segment.sourceStart >= 0,
                  segment.sourceDuration > 0,
                  segment.sourceEnd.isFinite else {
                throw TimelineMapError.invalidSegment(segment.id)
            }
            guard segment.sourceEnd <= fullSourceDuration + epsilon else {
                throw TimelineMapError.segmentOutsideSource(segment.id)
            }
            let resolvedDuration = min(
                segment.sourceDuration,
                fullSourceDuration - segment.sourceStart
            )
            resolved.append(
                ResolvedRecordingSegment(
                    id: segment.id,
                    sourceStart: segment.sourceStart,
                    sourceDuration: resolvedDuration,
                    outputStart: outputStart
                )
            )
            outputStart += resolvedDuration
        }
        let sourceOrdered = authored.sorted {
            if $0.sourceStart != $1.sourceStart { return $0.sourceStart < $1.sourceStart }
            return $0.id.uuidString < $1.id.uuidString
        }
        for (previous, current) in zip(sourceOrdered, sourceOrdered.dropFirst())
            where current.sourceStart < previous.sourceEnd - epsilon {
            throw TimelineMapError.nonMonotonicSegments(
                previous: previous.id,
                current: current.id
            )
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
            if segments[middle].outputEnd <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < segments.endIndex else { return nil }
        let candidate = segments[lower]
        return time >= candidate.outputStart ? candidate : nil
    }

    public func sourceTime(atOutputTime time: TimeInterval) -> TimeInterval? {
        guard let segment = segment(atOutputTime: time) else { return nil }
        return segment.sourceStart + time - segment.outputStart
    }

    public func outputTime(forSourceTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite else { return nil }
        guard let segment = segments.first(where: {
            time >= $0.sourceStart && time < $0.sourceEnd
        }) else { return nil }
        return segment.outputStart + time - segment.sourceStart
    }

    public func outputRange(forSegmentID id: UUID) -> MediaTimeRange? {
        segments.first(where: { $0.id == id })?.outputRange
    }

    public func sourceRange(forSegmentID id: UUID) -> MediaTimeRange? {
        segments.first(where: { $0.id == id })?.sourceRange
    }

    public func materializedSourceSequence() -> SourceSequence {
        .edited(
            segments.map {
                RecordingSegment(
                    id: $0.id,
                    sourceStart: $0.sourceStart,
                    sourceDuration: $0.sourceDuration
                )
            }
        )
    }

    /// Maps events into output time while retaining cut boundaries. Each group
    /// receives the most recent source position as a move seed when possible.
    public func mapPointerEventSegments(
        _ sourceEvents: [PointerEventRecord]
    ) -> [TimelineMappedPointerSegment] {
        let ordered = PointerEventTimelineOrdering.normalized(sourceEvents)

        return segments.compactMap { segment in
            guard let outputRange = segment.outputRange else { return nil }
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
                        modifiers: seed.modifiers
                    )
                )
            }
            mapped.append(contentsOf: eventsInRange.map { event in
                PointerEventRecord(
                    time: segment.outputStart + event.time - segment.sourceStart,
                    location: event.location,
                    kind: event.kind,
                    modifiers: event.modifiers
                )
            })
            return TimelineMappedPointerSegment(
                id: segment.id,
                outputRange: outputRange,
                events: mapped
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
