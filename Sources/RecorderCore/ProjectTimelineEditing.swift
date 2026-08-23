import Foundation

public enum RecordingSegmentTrimEdge: String, Codable, Equatable, Sendable {
    case left
    case right
}

public enum ProjectTimelineTrack: String, Equatable, Sendable {
    case primaryRecording
    case zoom
    case screenMotion
    case cameraMotion
}

public enum ProjectTimelineEditingError: Error, Equatable, Sendable {
    case invalidSourceSequence
    case segmentNotFound(UUID)
    case splitOutsideSegment
    case duplicateSegmentID(UUID)
    case trimOutsideSegment(UUID)
    case cannotRemoveFinalSegment
    case restoreJunctionNotFound(previous: UUID, next: UUID)
    case noRestorableSourceGap(previous: UUID, next: UUID)
    case noRestorableLeadingSourceGap(UUID)
    case noRestorableTrailingSourceGap(UUID)
    case cannotMergeDeletedGap(previous: UUID, next: UUID)
    case duplicateClipID(track: ProjectTimelineTrack, id: UUID)
    case missingClip(track: ProjectTimelineTrack, id: UUID)
    case mismatchedClipID(track: ProjectTimelineTrack, expected: UUID, actual: UUID)
    case invalidClip(track: ProjectTimelineTrack, id: UUID)
    case overlappingClips(track: ProjectTimelineTrack, first: UUID, second: UUID)
}

extension ProjectTimelineEditingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSourceSequence:
            return "主录屏片段必须有效、不重复使用源素材且至少保留一段。"
        case let .segmentNotFound(id):
            return "找不到主录屏片段：\(id)。"
        case .splitOutsideSegment:
            return "拆分点必须位于主录屏片段内部。"
        case let .duplicateSegmentID(id):
            return "主录屏片段 ID 重复：\(id)。"
        case let .trimOutsideSegment(id):
            return "片段 \(id) 的裁切点必须位于当前片段内部，且不能裁成空片段。"
        case .cannotRemoveFinalSegment:
            return "项目必须至少保留一个主录屏片段。"
        case let .restoreJunctionNotFound(previous, next):
            return "找不到要还原的相邻剪切点：\(previous) → \(next)。"
        case let .noRestorableSourceGap(previous, next):
            return "该剪切点没有可还原的源素材：\(previous) → \(next)。"
        case let .noRestorableLeadingSourceGap(next):
            return "开头剪切点没有可还原的源素材：→ \(next)。"
        case let .noRestorableTrailingSourceGap(previous):
            return "结尾剪切点没有可还原的源素材：\(previous) →。"
        case let .cannotMergeDeletedGap(previous, next):
            return "该剪切点包含已删除素材，应先还原而不是直接合并：\(previous) → \(next)。"
        case let .duplicateClipID(track, id):
            return "\(track.rawValue) 轨道中存在重复片段 ID：\(id)。"
        case let .missingClip(track, id):
            return "\(track.rawValue) 轨道中找不到片段：\(id)。"
        case let .mismatchedClipID(track, expected, actual):
            return "\(track.rawValue) 轨道替换片段的 ID 不匹配：\(expected) / \(actual)。"
        case let .invalidClip(track, id):
            return "\(track.rawValue) 轨道中的片段无效：\(id)。"
        case let .overlappingClips(track, first, second):
            return "\(track.rawValue) 轨道片段重叠：\(first) / \(second)。"
        }
    }
}

/// Pure edit decisions for the lightweight primary-recording timeline.
///
/// Source ranges remain unique and play at normal speed, while their array
/// order is the authored output order. Splitting preserves duration; trims,
/// removal and reordering transform every time-varying track with the edit.
public enum ProjectTimelineEditing {
    static let epsilon = 1.0 / 120_000.0

    public static func materialized(
        _ timeline: ProjectTimeline,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        var result = timeline
        result.sourceSequence = map.materializedSourceSequence()
        try validate(result)
        return result
    }

    /// Repairs projects that were saved by the old ripple implementation with
    /// a consumed (`progressOffset == 1`) zero-length return at a real source
    /// gap. Those values encode a one-frame jump, so reopening the project must
    /// restore the transition just as a newly performed deletion now does.
    public static func repairingPersistedRippleTransitions(
        _ timeline: ProjectTimeline,
        defaultTransitionDuration: TimeInterval = 0.7
    ) -> ProjectTimeline {
        guard case let .edited(segments) = timeline.sourceSequence,
              segments.count > 1 else { return timeline }
        var output = 0.0
        var gapJunctions: [TimeInterval] = []
        for index in segments.indices {
            output += segments[index].sourceDuration
            guard segments.indices.contains(index + 1),
                  segments[index + 1].sourceStart
                    - (segments[index].sourceStart + segments[index].sourceDuration)
                    > epsilon else { continue }
            gapJunctions.append(output)
        }
        guard !gapJunctions.isEmpty else { return timeline }

        let safeDefault = max(defaultTransitionDuration, 0)
        var result = timeline
        result.zoomClips.sort(by: zoomOrder)
        for index in result.zoomClips.indices {
            let clip = result.zoomClips[index]
            let isBrokenJunction = gapJunctions.contains {
                abs($0 - clip.endTime) <= ZoomInterpolator.adjacencyTolerance
            }
            let touchesNext = result.zoomClips.indices.contains(index + 1)
                && abs(result.zoomClips[index + 1].startTime - clip.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            guard isBrokenJunction, !touchesNext,
                  clip.exitDuration <= epsilon,
                  clip.exitProgressOffset >= 1 - epsilon else { continue }
            let available = result.zoomClips.indices.contains(index + 1)
                ? max(result.zoomClips[index + 1].startTime - clip.endTime, 0)
                : safeDefault
            result.zoomClips[index].exitDuration = min(safeDefault, available)
            result.zoomClips[index].exitProgressOffset = 0
        }

        result.screenMotionClips.sort(by: screenMotionOrder)
        for index in result.screenMotionClips.indices {
            let timing = result.screenMotionClips[index].timing
            let isBrokenJunction = gapJunctions.contains {
                abs($0 - timing.endTime) <= ZoomInterpolator.adjacencyTolerance
            }
            let touchesNext = result.screenMotionClips.indices.contains(index + 1)
                && abs(
                    result.screenMotionClips[index + 1].timing.startTime
                        - timing.endTime
                ) <= ZoomInterpolator.adjacencyTolerance
            guard isBrokenJunction, !touchesNext,
                  timing.returnDuration <= epsilon,
                  timing.returnProgressOffset >= 1 - epsilon else { continue }
            let available = result.screenMotionClips.indices.contains(index + 1)
                ? max(
                    result.screenMotionClips[index + 1].timing.startTime
                        - timing.endTime,
                    0
                )
                : safeDefault
            result.screenMotionClips[index].timing.returnDuration = min(
                safeDefault, available
            )
            result.screenMotionClips[index].timing.returnProgressOffset = 0
        }

        result.cameraMotionClips.sort(by: cameraMotionOrder)
        for index in result.cameraMotionClips.indices {
            let timing = result.cameraMotionClips[index].timing
            let isBrokenJunction = gapJunctions.contains {
                abs($0 - timing.endTime) <= ZoomInterpolator.adjacencyTolerance
            }
            let touchesNext = result.cameraMotionClips.indices.contains(index + 1)
                && abs(
                    result.cameraMotionClips[index + 1].timing.startTime
                        - timing.endTime
                ) <= ZoomInterpolator.adjacencyTolerance
            guard isBrokenJunction, !touchesNext,
                  timing.returnDuration <= epsilon,
                  timing.returnProgressOffset >= 1 - epsilon else { continue }
            let available = result.cameraMotionClips.indices.contains(index + 1)
                ? max(
                    result.cameraMotionClips[index + 1].timing.startTime
                        - timing.endTime,
                    0
                )
                : safeDefault
            result.cameraMotionClips[index].timing.returnDuration = min(
                safeDefault, available
            )
            result.cameraMotionClips[index].timing.returnProgressOffset = 0
        }
        return result
    }

    public static func splitPrimarySegment(
        in timeline: ProjectTimeline,
        atOutputTime outputTime: TimeInterval,
        newRightSegmentID: UUID,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard outputTime.isFinite,
              let resolved = map.segment(atOutputTime: outputTime),
              outputTime > resolved.outputStart + epsilon,
              outputTime < resolved.outputEnd - epsilon else {
            throw ProjectTimelineEditingError.splitOutsideSegment
        }
        guard !map.segments.contains(where: { $0.id == newRightSegmentID }) else {
            throw ProjectTimelineEditingError.duplicateSegmentID(newRightSegmentID)
        }

        let splitOffset = outputTime - resolved.outputStart
        var segments = map.segments.map(Self.authoredSegment)
        guard let index = segments.firstIndex(where: { $0.id == resolved.id }) else {
            throw ProjectTimelineEditingError.segmentNotFound(resolved.id)
        }
        segments[index].sourceDuration = splitOffset
        segments.insert(
            RecordingSegment(
                id: newRightSegmentID,
                sourceStart: resolved.sourceStart + splitOffset,
                sourceDuration: resolved.sourceDuration - splitOffset
            ),
            at: index + 1
        )

        var result = timeline
        result.sourceSequence = .edited(segments)
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    public static func trimPrimarySegment(
        in timeline: ProjectTimeline,
        segmentID: UUID,
        edge: RecordingSegmentTrimEdge,
        toOutputTime outputTime: TimeInterval,
        fullSourceDuration: TimeInterval,
        defaultTransitionDuration: TimeInterval = 0.7
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let resolved = map.segments.first(where: { $0.id == segmentID }) else {
            throw ProjectTimelineEditingError.segmentNotFound(segmentID)
        }
        guard outputTime.isFinite else {
            throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
        }

        let deletion: OutputDeletion
        var segments = map.segments.map(Self.authoredSegment)
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else {
            throw ProjectTimelineEditingError.segmentNotFound(segmentID)
        }

        switch edge {
        case .left:
            if abs(outputTime - resolved.outputStart) <= epsilon {
                return timeline
            }
            if outputTime < resolved.outputStart - epsilon {
                let previousSourceEnd = segments.enumerated()
                    .filter { $0.offset != index && $0.element.sourceEnd <= resolved.sourceStart + epsilon }
                    .map { $0.element.sourceEnd }
                    .max() ?? 0
                let available = max(resolved.sourceStart - previousSourceEnd, 0)
                let amount = resolved.outputStart - outputTime
                guard amount <= available + epsilon else {
                    throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
                }
                segments[index].sourceStart -= amount
                segments[index].sourceDuration += amount
                var result = timeline
                result.sourceSequence = .edited(segments)
                result.zoomClips = timeline.zoomClips.map {
                    inserting($0, at: resolved.outputStart, duration: amount)
                }
                result.screenMotionClips = timeline.screenMotionClips.map {
                    inserting($0, at: resolved.outputStart, duration: amount)
                }
                result.cameraMotionClips = timeline.cameraMotionClips.map {
                    inserting($0, at: resolved.outputStart, duration: amount)
                }
                sortZoom(&result.zoomClips)
                sortScreenMotion(&result.screenMotionClips)
                sortCameraMotion(&result.cameraMotionClips)
                try validate(result, fullSourceDuration: fullSourceDuration)
                return result
            }
            guard outputTime > resolved.outputStart + epsilon,
                  outputTime < resolved.outputEnd - epsilon else {
                throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
            }
            let amount = outputTime - resolved.outputStart
            segments[index].sourceStart += amount
            segments[index].sourceDuration -= amount
            deletion = OutputDeletion(start: resolved.outputStart, end: outputTime)

        case .right:
            if abs(outputTime - resolved.outputEnd) <= epsilon {
                return timeline
            }
            if outputTime > resolved.outputEnd + epsilon {
                let nextSourceStart = segments.enumerated()
                    .filter { $0.offset != index && $0.element.sourceStart >= resolved.sourceEnd - epsilon }
                    .map { $0.element.sourceStart }
                    .min() ?? fullSourceDuration
                let available = max(nextSourceStart - resolved.sourceEnd, 0)
                let amount = outputTime - resolved.outputEnd
                guard amount <= available + epsilon else {
                    throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
                }
                segments[index].sourceDuration += amount
                var result = timeline
                result.sourceSequence = .edited(segments)
                result.zoomClips = timeline.zoomClips.map {
                    inserting($0, at: resolved.outputEnd, duration: amount)
                }
                result.screenMotionClips = timeline.screenMotionClips.map {
                    inserting($0, at: resolved.outputEnd, duration: amount)
                }
                result.cameraMotionClips = timeline.cameraMotionClips.map {
                    inserting($0, at: resolved.outputEnd, duration: amount)
                }
                sortZoom(&result.zoomClips)
                sortScreenMotion(&result.screenMotionClips)
                sortCameraMotion(&result.cameraMotionClips)
                try validate(result, fullSourceDuration: fullSourceDuration)
                return result
            }
            guard outputTime > resolved.outputStart + epsilon,
                  outputTime < resolved.outputEnd - epsilon else {
                throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
            }
            segments[index].sourceDuration = outputTime - resolved.outputStart
            deletion = OutputDeletion(start: outputTime, end: resolved.outputEnd)
        }

        return try ripple(
            timeline,
            replacingSourceSequenceWith: .edited(segments),
            deleting: deletion,
            deletesOutputTail: deletion.end >= map.outputDuration - epsilon,
            fullSourceDuration: fullSourceDuration,
            defaultTransitionDuration: defaultTransitionDuration
        )
    }

    public static func removePrimarySegment(
        from timeline: ProjectTimeline,
        segmentID: UUID,
        fullSourceDuration: TimeInterval,
        defaultTransitionDuration: TimeInterval = 0.7
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let removed = map.segments.first(where: { $0.id == segmentID }) else {
            throw ProjectTimelineEditingError.segmentNotFound(segmentID)
        }
        guard map.segments.count > 1 else {
            throw ProjectTimelineEditingError.cannotRemoveFinalSegment
        }
        let retained = map.segments
            .filter { $0.id != segmentID }
            .map(Self.authoredSegment)
        return try ripple(
            timeline,
            replacingSourceSequenceWith: .edited(retained),
            deleting: OutputDeletion(start: removed.outputStart, end: removed.outputEnd),
            deletesOutputTail: removed.outputEnd >= map.outputDuration - epsilon,
            fullSourceDuration: fullSourceDuration,
            defaultTransitionDuration: defaultTransitionDuration
        )
    }

    /// Moves one retained source segment to a new output-order index. Media,
    /// audio, camera and pointer tracks follow through TimelineMap; authored
    /// visual tracks are translated with the segment that owns their start.
    public static func movePrimarySegment(
        in timeline: ProjectTimeline,
        segmentID: UUID,
        toIndex requestedIndex: Int,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let oldMap = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let oldIndex = oldMap.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw ProjectTimelineEditingError.segmentNotFound(segmentID)
        }
        let finalIndex = min(max(requestedIndex, 0), oldMap.segments.count - 1)
        guard finalIndex != oldIndex else { return timeline }

        var segments = oldMap.segments.map(Self.authoredSegment)
        let moved = segments.remove(at: oldIndex)
        segments.insert(moved, at: finalIndex)
        let newMap = try TimelineMap(
            sourceSequence: .edited(segments),
            fullSourceDuration: fullSourceDuration
        )
        let newStarts = Dictionary(uniqueKeysWithValues: newMap.segments.map {
            ($0.id, $0.outputStart)
        })

        var result = timeline
        result.sourceSequence = .edited(segments)
        result.zoomClips = remappedZoomClips(
            timeline.zoomClips,
            oldMap: oldMap,
            newStarts: newStarts,
            outputDuration: newMap.outputDuration
        )
        result.screenMotionClips = remappedScreenMotionClips(
            timeline.screenMotionClips,
            oldMap: oldMap,
            newStarts: newStarts,
            outputDuration: newMap.outputDuration
        )
        result.cameraMotionClips = remappedCameraMotionClips(
            timeline.cameraMotionClips,
            oldMap: oldMap,
            newStarts: newStarts,
            outputDuration: newMap.outputDuration
        )
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    /// CUT-001: restore one deleted source interval without collapsing or
    /// replacing any other authored cut. All media tracks inherit this source
    /// sequence; existing timed effects at/after the junction are moved through
    /// the inverse ripple so they keep their output-relative placement.
    public static func restorePrimaryGap(
        in timeline: ProjectTimeline,
        previousSegmentID: UUID,
        nextSegmentID: UUID,
        restoredSegmentID: UUID,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard !map.segments.contains(where: { $0.id == restoredSegmentID }) else {
            throw ProjectTimelineEditingError.duplicateSegmentID(restoredSegmentID)
        }
        guard let previousIndex = map.segments.firstIndex(where: {
            $0.id == previousSegmentID
        }),
        map.segments.indices.contains(previousIndex + 1),
        map.segments[previousIndex + 1].id == nextSegmentID else {
            throw ProjectTimelineEditingError.restoreJunctionNotFound(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }
        let previous = map.segments[previousIndex]
        let next = map.segments[previousIndex + 1]
        let restoredDuration = next.sourceStart - previous.sourceEnd
        guard restoredDuration > epsilon else {
            throw ProjectTimelineEditingError.noRestorableSourceGap(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }

        var segments = map.segments.map(Self.authoredSegment)
        segments.insert(
            RecordingSegment(
                id: restoredSegmentID,
                sourceStart: previous.sourceEnd,
                sourceDuration: restoredDuration
            ),
            at: previousIndex + 1
        )
        let insertionTime = previous.outputEnd
        var result = timeline
        result.sourceSequence = .edited(segments)
        result.zoomClips = timeline.zoomClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.screenMotionClips = timeline.screenMotionClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.cameraMotionClips = timeline.cameraMotionClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    /// Restores source material removed before the first retained segment.
    /// The former UI only described junctions between two clips, making an
    /// opening trim impossible to undo from the timeline.
    public static func restorePrimaryLeadingGap(
        in timeline: ProjectTimeline,
        restoredSegmentID: UUID,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let first = map.segments.first,
              first.sourceStart > epsilon else {
            throw ProjectTimelineEditingError.noRestorableLeadingSourceGap(
                map.segments.first?.id ?? restoredSegmentID
            )
        }
        guard !map.segments.contains(where: { $0.id == restoredSegmentID }) else {
            throw ProjectTimelineEditingError.duplicateSegmentID(restoredSegmentID)
        }
        let restoredDuration = first.sourceStart
        var segments = map.segments.map(Self.authoredSegment)
        segments.insert(
            RecordingSegment(
                id: restoredSegmentID,
                sourceStart: 0,
                sourceDuration: restoredDuration
            ),
            at: 0
        )
        var result = timeline
        result.sourceSequence = .edited(segments)
        result.zoomClips = timeline.zoomClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.screenMotionClips = timeline.screenMotionClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.cameraMotionClips = timeline.cameraMotionClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    /// Restores source material removed after the final retained segment.
    /// This is the right-edge counterpart of `restorePrimaryLeadingGap`:
    /// earlier cuts and every existing timed effect remain unchanged because
    /// the insertion happens strictly after the current output duration.
    public static func restorePrimaryTrailingGap(
        in timeline: ProjectTimeline,
        restoredSegmentID: UUID,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let last = map.segments.last,
              fullSourceDuration - last.sourceEnd > epsilon else {
            throw ProjectTimelineEditingError.noRestorableTrailingSourceGap(
                map.segments.last?.id ?? restoredSegmentID
            )
        }
        guard !map.segments.contains(where: { $0.id == restoredSegmentID }) else {
            throw ProjectTimelineEditingError.duplicateSegmentID(restoredSegmentID)
        }
        var segments = map.segments.map(Self.authoredSegment)
        segments.append(
            RecordingSegment(
                id: restoredSegmentID,
                sourceStart: last.sourceEnd,
                sourceDuration: fullSourceDuration - last.sourceEnd
            )
        )
        var result = timeline
        result.sourceSequence = .edited(segments)
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    /// CUT-002: remove a structural split between two source-contiguous
    /// segments. Output time and every timed effect stay unchanged because no
    /// media interval is inserted or removed.
    public static func mergeAdjacentPrimarySegments(
        in timeline: ProjectTimeline,
        previousSegmentID: UUID,
        nextSegmentID: UUID,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let previousIndex = map.segments.firstIndex(where: {
            $0.id == previousSegmentID
        }),
        map.segments.indices.contains(previousIndex + 1),
        map.segments[previousIndex + 1].id == nextSegmentID else {
            throw ProjectTimelineEditingError.restoreJunctionNotFound(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }
        let previous = map.segments[previousIndex]
        let next = map.segments[previousIndex + 1]
        guard abs(next.sourceStart - previous.sourceEnd) <= epsilon else {
            throw ProjectTimelineEditingError.cannotMergeDeletedGap(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }

        var segments = map.segments.map(Self.authoredSegment)
        segments[previousIndex].sourceDuration = next.sourceEnd - previous.sourceStart
        segments.remove(at: previousIndex + 1)
        var result = timeline
        result.sourceSequence = .edited(segments)
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    public static func insertingScreenMotion(
        _ clip: ScreenMotionClip,
        in timeline: ProjectTimeline
    ) throws -> ProjectTimeline {
        guard !timeline.screenMotionClips.contains(where: { $0.id == clip.id }) else {
            throw ProjectTimelineEditingError.duplicateClipID(track: .screenMotion, id: clip.id)
        }
        var result = timeline
        result.screenMotionClips.append(clip)
        sortScreenMotion(&result.screenMotionClips)
        try validate(result)
        return result
    }

    public static func removingScreenMotion(
        id: UUID,
        from timeline: ProjectTimeline,
        defaultReturn: TimeInterval = 0.7
    ) throws -> ProjectTimeline {
        let ordered = timeline.screenMotionClips.sorted(by: screenMotionOrder)
        guard let removedIndex = ordered.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineEditingError.missingClip(track: .screenMotion, id: id)
        }
        let predecessorID = removedIndex > 0 ? ordered[removedIndex - 1].id : nil
        var result = timeline
        result.screenMotionClips.removeAll { $0.id == id }
        // 删除让前一段成为"结尾"：没有回落时长时补上默认回落（受剩余间隙限制），
        // 仍与后一段相接的片段不动。
        if let predecessorID,
           let index = result.screenMotionClips.firstIndex(where: { $0.id == predecessorID }),
           result.screenMotionClips[index].timing.returnDuration <= 0.000_1 {
            let available = result.screenMotionClips.indices.contains(index + 1)
                ? result.screenMotionClips[index + 1].timing.startTime
                    - result.screenMotionClips[index].timing.endTime
                : defaultReturn
            if available > ZoomInterpolator.adjacencyTolerance {
                result.screenMotionClips[index].timing.returnDuration = min(
                    max(defaultReturn, 0),
                    max(available, 0)
                )
            }
        }
        try validate(result)
        return result
    }

    public static func replacingScreenMotion(
        id: UUID,
        in timeline: ProjectTimeline,
        with clip: ScreenMotionClip
    ) throws -> ProjectTimeline {
        guard id == clip.id else {
            throw ProjectTimelineEditingError.mismatchedClipID(
                track: .screenMotion,
                expected: id,
                actual: clip.id
            )
        }
        guard let index = timeline.screenMotionClips.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineEditingError.missingClip(track: .screenMotion, id: id)
        }
        var result = timeline
        result.screenMotionClips[index] = clip
        sortScreenMotion(&result.screenMotionClips)
        try validate(result)
        return result
    }

    public static func insertingCameraMotion(
        _ clip: CameraMotionClip,
        in timeline: ProjectTimeline
    ) throws -> ProjectTimeline {
        guard !timeline.cameraMotionClips.contains(where: { $0.id == clip.id }) else {
            throw ProjectTimelineEditingError.duplicateClipID(track: .cameraMotion, id: clip.id)
        }
        var result = timeline
        result.cameraMotionClips.append(clip)
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result)
        return result
    }

    public static func removingCameraMotion(
        id: UUID,
        from timeline: ProjectTimeline,
        defaultReturn: TimeInterval = 0.7
    ) throws -> ProjectTimeline {
        let ordered = timeline.cameraMotionClips.sorted(by: cameraMotionOrder)
        guard let removedIndex = ordered.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineEditingError.missingClip(track: .cameraMotion, id: id)
        }
        let predecessorID = removedIndex > 0 ? ordered[removedIndex - 1].id : nil
        var result = timeline
        result.cameraMotionClips.removeAll { $0.id == id }
        // 与屏幕动画一致：删除让前一段成为结尾时补上受限默认回落。
        if let predecessorID,
           let index = result.cameraMotionClips.firstIndex(where: { $0.id == predecessorID }),
           result.cameraMotionClips[index].timing.returnDuration <= 0.000_1 {
            let available = result.cameraMotionClips.indices.contains(index + 1)
                ? result.cameraMotionClips[index + 1].timing.startTime
                    - result.cameraMotionClips[index].timing.endTime
                : defaultReturn
            if available > ZoomInterpolator.adjacencyTolerance {
                result.cameraMotionClips[index].timing.returnDuration = min(
                    max(defaultReturn, 0),
                    max(available, 0)
                )
            }
        }
        try validate(result)
        return result
    }

    public static func replacingCameraMotion(
        id: UUID,
        in timeline: ProjectTimeline,
        with clip: CameraMotionClip
    ) throws -> ProjectTimeline {
        guard id == clip.id else {
            throw ProjectTimelineEditingError.mismatchedClipID(
                track: .cameraMotion,
                expected: id,
                actual: clip.id
            )
        }
        guard let index = timeline.cameraMotionClips.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineEditingError.missingClip(track: .cameraMotion, id: id)
        }
        var result = timeline
        result.cameraMotionClips[index] = clip
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result)
        return result
    }

    /// Structural validation used by the reducer when the source asset duration
    /// is not available. Edit operations additionally validate against the real
    /// duration through `TimelineMap` before returning.
    public static func validate(_ timeline: ProjectTimeline) throws {
        try validateSourceSequence(timeline.sourceSequence)
        try validateZoomClips(timeline.zoomClips)
        try validateScreenMotionClips(timeline.screenMotionClips)
        try validateCameraMotionClips(timeline.cameraMotionClips)
    }

    public static func validate(
        _ timeline: ProjectTimeline,
        fullSourceDuration: TimeInterval
    ) throws {
        _ = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        try validate(timeline)
    }
}
