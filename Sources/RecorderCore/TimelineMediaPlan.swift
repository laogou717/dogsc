import Foundation

/// One retained source interval placed on the ripple output timeline.
/// The same plan drives preview compositions and deterministic export readers.
public struct TimelineMediaSlice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let segmentID: UUID
    public let outputStart: TimeInterval
    public let sourceStart: TimeInterval
    public let duration: TimeInterval
    public let sourceTimeScale: Double

    public init(
        id: UUID = UUID(),
        segmentID: UUID,
        outputStart: TimeInterval,
        sourceStart: TimeInterval,
        duration: TimeInterval,
        sourceTimeScale: Double = 1
    ) {
        self.id = id
        self.segmentID = segmentID
        self.outputStart = outputStart
        self.sourceStart = sourceStart
        self.duration = duration
        self.sourceTimeScale = sourceTimeScale.isFinite && sourceTimeScale > 0
            ? sourceTimeScale : 1
    }

    public var outputEnd: TimeInterval { outputStart + duration }
    public var sourceEnd: TimeInterval { sourceStart + duration * sourceTimeScale }

    public func sourceTime(atOutputTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite,
              time >= outputStart,
              time < outputEnd else { return nil }
        return sourceStart + (time - outputStart) * sourceTimeScale
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
                sourceTimeScale: $0.playbackRate
            )
        }
    }

    /// Intersects an auxiliary camera/microphone placement with every retained
    /// primary segment. Gaps remain gaps, while all surviving slices share the
    /// exact same output clock as the screen recording.
    public init(
        timelineMap: TimelineMap,
        auxiliary placement: MediaTimelinePlacement,
        syncAnchors: [MediaSyncAnchor] = [],
        sourceAvailableRange: MediaTimeRange? = nil
    ) {
        outputDuration = timelineMap.outputDuration
        guard !syncAnchors.isEmpty else {
            slices = timelineMap.segments.compactMap { segment in
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
                    sourceTimeScale: placement.sourceTimeScale * segment.playbackRate
                )
            }
            return
        }

        let curve = MediaSyncAnchorCurve(syncAnchors)
        let availableStart = sourceAvailableRange?.start ?? 0
        let availableEnd = sourceAvailableRange?.end ?? .greatestFiniteMagnitude
        slices = timelineMap.segments.flatMap { segment -> [TimelineMediaSlice] in
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
                    sourceTimeScale: correctedDuration / duration
                )
            }
        }
    }

    public var playableDuration: TimeInterval {
        slices.reduce(0) { $0 + $1.duration }
    }

    public func sourceTime(atOutputTime time: TimeInterval) -> TimeInterval? {
        guard let slice = slice(atOutputTime: time) else { return nil }
        return slice.sourceTime(atOutputTime: time)
    }

    public func contains(outputTime time: TimeInterval) -> Bool {
        sourceTime(atOutputTime: time) != nil
    }

    public func slice(atOutputTime time: TimeInterval) -> TimelineMediaSlice? {
        guard time.isFinite, time >= 0 else { return nil }
        var lower = slices.startIndex
        var upper = slices.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if slices[middle].outputEnd <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < slices.endIndex else { return nil }
        let candidate = slices[lower]
        return time >= candidate.outputStart ? candidate : nil
    }

    private static func isSameBoundary(
        _ lhs: TimeInterval,
        _ rhs: TimeInterval
    ) -> Bool {
        abs(lhs - rhs) <= numericalBoundaryTolerance
    }
}

/// Every time-bearing source resolved onto the one final output clock.
///
/// AVFoundation-specific composition code deliberately consumes this value
/// instead of recalculating offsets. That keeps preview, export, pointer
/// evaluation and auxiliary availability on the exact same cut boundaries.
public struct ProjectTimelineMediaPlan: Equatable, Sendable {
    public let timelineMap: TimelineMap
    public let primary: TimelineMediaPlan
    public let systemAudio: TimelineMediaPlan?
    public let camera: TimelineMediaPlan?
    public let microphone: TimelineMediaPlan?
    public let pointer: ProjectPointerTrack
    public let primarySourceTimeOffset: TimeInterval

    public init(
        project: RecorderProject,
        primaryVideoRange: MediaTimeRange,
        systemAudioRange: MediaTimeRange? = nil,
        cameraRange: MediaTimeRange? = nil,
        microphoneRange: MediaTimeRange? = nil,
        sourcePointerEvents: [PointerEventRecord] = []
    ) throws {
        try self.init(
            sourceSequence: project.timeline.sourceSequence,
            mediaManifest: project.media,
            primaryVideoRange: primaryVideoRange,
            systemAudioRange: systemAudioRange,
            cameraRange: cameraRange,
            microphoneRange: microphoneRange,
            sourcePointerEvents: sourcePointerEvents
        )
    }

    /// Builds the authoritative output clock from the media-bearing project
    /// fields only. Editor preview preparation uses this overload so visual
    /// styling and audio gain cannot accidentally become asset-cache keys.
    public init(
        sourceSequence: SourceSequence,
        mediaManifest: ProjectMediaManifest?,
        primaryVideoRange: MediaTimeRange,
        systemAudioRange: MediaTimeRange? = nil,
        cameraRange: MediaTimeRange? = nil,
        microphoneRange: MediaTimeRange? = nil,
        sourcePointerEvents: [PointerEventRecord] = []
    ) throws {
        let map = try TimelineMap(
            sourceSequence: sourceSequence,
            fullSourceDuration: primaryVideoRange.duration
        )
        timelineMap = map
        primary = TimelineMediaPlan(primary: map)
        primarySourceTimeOffset = primaryVideoRange.start

        if let systemAudioRange {
            let sharedSourceStart = max(systemAudioRange.start, primaryVideoRange.start)
            let placement = MediaTimelinePlacement(
                reference: ProjectMediaReference(
                    relativePath: mediaManifest?.screen.relativePath ?? "screen",
                    startOffset: max(systemAudioRange.start - primaryVideoRange.start, 0),
                    sourceStartTime: sharedSourceStart
                ),
                sourceAvailableStart: systemAudioRange.start,
                sourceAvailableDuration: systemAudioRange.duration,
                timelineDuration: primaryVideoRange.duration
            )
            systemAudio = TimelineMediaPlan(timelineMap: map, auxiliary: placement)
        } else {
            systemAudio = nil
        }

        camera = Self.auxiliaryPlan(
            reference: mediaManifest?.camera,
            availableRange: cameraRange,
            timelineMap: map,
            timelineDuration: primaryVideoRange.duration
        )
        microphone = Self.auxiliaryPlan(
            reference: mediaManifest?.microphone,
            availableRange: microphoneRange,
            timelineMap: map,
            timelineDuration: primaryVideoRange.duration
        )
        pointer = ProjectPointerTrack(
            timelineMap: map,
            sourceEvents: sourcePointerEvents
        )
    }

    public var outputDuration: TimeInterval { primary.outputDuration }

    private static func auxiliaryPlan(
        reference: ProjectMediaReference?,
        availableRange: MediaTimeRange?,
        timelineMap: TimelineMap,
        timelineDuration: TimeInterval
    ) -> TimelineMediaPlan? {
        guard let reference, let availableRange else { return nil }
        let placement = MediaTimelinePlacement(
            reference: reference,
            sourceAvailableStart: availableRange.start,
            sourceAvailableDuration: availableRange.duration,
            timelineDuration: timelineDuration
        )
        return TimelineMediaPlan(
            timelineMap: timelineMap,
            auxiliary: placement,
            syncAnchors: reference.syncAnchors,
            sourceAvailableRange: availableRange
        )
    }
}

/// Aligns both ends of an independently clocked capture. This is deliberately
/// inferred for legacy projects: a fixed start trim cannot repair drift, while
/// the finalized source and primary durations provide a stable second anchor.
public enum AuxiliaryMediaClockAlignment {
    public static func inferredSourceTimeScale(
        reference: ProjectMediaReference,
        availableRange: MediaTimeRange,
        timelineDuration: TimeInterval
    ) -> Double? {
        let sourceStart = min(
            max(reference.sourceStartTime, availableRange.start),
            availableRange.end
        )
        let sourceSpan = availableRange.end - sourceStart
        let timelineSpan = timelineDuration - max(reference.startOffset, 0)
        guard sourceSpan.isFinite, timelineSpan.isFinite,
              sourceSpan > 0.1, timelineSpan > 0.1 else { return nil }
        let scale = sourceSpan / timelineSpan
        // A disconnected/truncated auxiliary track must remain visibly
        // incomplete instead of being stretched across most of the project.
        guard scale >= 0.9, scale <= 1.1 else { return nil }
        return scale
    }
}
