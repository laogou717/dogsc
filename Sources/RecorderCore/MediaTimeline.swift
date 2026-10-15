import Foundation

/// One canonical mapping between a source track and the project timeline.
/// `ProjectMediaReference` describes user/capture placement while the
/// available source range comes from AVFoundation's actual track inventory.
public struct MediaTimelinePlacement: Equatable, Sendable {
    public let timelineStart: TimeInterval
    public let sourceStart: TimeInterval
    public let playableDuration: TimeInterval
    public let sourceTimeScale: Double

    public init(
        reference: ProjectMediaReference,
        sourceAvailableStart: TimeInterval = 0,
        sourceAvailableDuration: TimeInterval,
        timelineDuration: TimeInterval
    ) {
        let requestedSourceStart = Self.nonnegative(reference.sourceStartTime)
        let availableStart = Self.nonnegative(sourceAvailableStart)
        let availableDuration = Self.nonnegative(sourceAvailableDuration)
        let availableEnd = availableStart + availableDuration
        let effectiveSourceStart = min(max(requestedSourceStart, availableStart), availableEnd)
        let requestedSourceEnd = reference.sourceEndTime ?? availableEnd
        let effectiveSourceEnd = min(
            max(requestedSourceEnd, effectiveSourceStart),
            availableEnd
        )
        let unavailableLead = max(effectiveSourceStart - requestedSourceStart, 0)
        let safeTimelineDuration = Self.nonnegative(timelineDuration)
        let requestedScale = reference.sourceTimeScale ?? 1
        let safeScale = requestedScale.isFinite && requestedScale > 0
            ? requestedScale : 1
        let effectiveTimelineStart = Self.nonnegative(reference.startOffset)
            + unavailableLead / safeScale

        sourceStart = effectiveSourceStart
        timelineStart = min(effectiveTimelineStart, safeTimelineDuration)
        sourceTimeScale = safeScale
        playableDuration = min(
            max(effectiveSourceEnd - effectiveSourceStart, 0) / safeScale,
            max(safeTimelineDuration - timelineStart, 0)
        )
    }

    public var sourceEnd: TimeInterval {
        sourceStart + playableDuration * sourceTimeScale
    }
    public var timelineEnd: TimeInterval { timelineStart + playableDuration }

    public func sourceTime(at timelineTime: TimeInterval) -> TimeInterval? {
        guard timelineTime.isFinite,
              timelineTime >= timelineStart,
              timelineTime < timelineEnd else { return nil }
        return sourceStart + (timelineTime - timelineStart) * sourceTimeScale
    }

    public func timelineTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
        guard sourceTime.isFinite,
              sourceTime >= sourceStart,
              sourceTime < sourceEnd else { return nil }
        return timelineStart + (sourceTime - sourceStart) / sourceTimeScale
    }

    public func contains(timelineTime: TimeInterval) -> Bool {
        sourceTime(at: timelineTime) != nil && playableDuration > 0
    }

    private static func nonnegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(value, 0) : 0
    }
}

/// Evaluates piecewise-linear camera clock corrections against the original
/// screen source clock. Before the first authored point the curve grows from
/// an implicit zero correction at source time zero; after the final point it
/// holds the last correction.
public struct MediaSyncAnchorCurve: Equatable, Sendable {
    public let anchors: [MediaSyncAnchor]

    public init(_ anchors: [MediaSyncAnchor]) {
        self.anchors = anchors.sorted {
            if $0.sourceTime != $1.sourceTime { return $0.sourceTime < $1.sourceTime }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func offset(atSourceTime sourceTime: TimeInterval) -> TimeInterval {
        guard sourceTime.isFinite, !anchors.isEmpty else { return 0 }
        let safeTime = max(sourceTime, 0)
        guard let first = anchors.first else { return 0 }

        // Preserve the implicit zero-correction origin without copying the
        // complete anchor array and allocating a temporary UUID on every
        // sample. This path is hit repeatedly by editor curve drawing and by
        // auxiliary media-plan construction.
        if first.sourceTime > 0.000_001, safeTime <= first.sourceTime {
            let progress = min(max(safeTime / first.sourceTime, 0), 1)
            return first.offset * progress
        }
        if safeTime <= first.sourceTime { return first.offset }

        // Anchors are sorted at initialization. Find the first right-hand
        // point instead of walking the complete curve for every evaluation.
        var lower = 1
        var upper = anchors.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if anchors[middle].sourceTime < safeTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < anchors.count else { return anchors.last?.offset ?? 0 }
        let left = anchors[lower - 1]
        let right = anchors[lower]
        let span = right.sourceTime - left.sourceTime
        guard span > 0.000_001 else { return right.offset }
        let progress = min(max((safeTime - left.sourceTime) / span, 0), 1)
        return left.offset + (right.offset - left.offset) * progress
    }
}
