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
    case mosaic
    case sticker
    case animation
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
    case cannotMergeDifferentSources(previous: UUID, next: UUID)
    case cannotMergeDifferentSceneStyles
    case cannotMergeDifferentPlaybackRates(previous: UUID, next: UUID)
    case cannotMergeDifferentAudioOverrides(previous: UUID, next: UUID)
    case invalidPrimarySegmentAudioOverrides(UUID)
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
            return "主录屏片段必须有效且至少保留一段。"
        case .segmentNotFound:
            return "找不到要编辑的主片段。"
        case .splitOutsideSegment:
            return "拆分点必须位于主录屏片段内部。"
        case .duplicateSegmentID:
            return "主片段数据重复，无法继续编辑。"
        case .trimOutsideSegment:
            return "裁切点必须位于当前片段内部，且不能裁成空片段。"
        case .cannotRemoveFinalSegment:
            return "项目必须至少保留一个主录屏片段。"
        case .restoreJunctionNotFound:
            return "找不到要还原的相邻剪切点。"
        case .noRestorableSourceGap:
            return "该剪切点没有可还原的源素材。"
        case .noRestorableLeadingSourceGap:
            return "开头没有可还原的源素材。"
        case .noRestorableTrailingSourceGap:
            return "结尾没有可还原的源素材。"
        case .cannotMergeDeletedGap:
            return "该剪切点包含已删除素材，应先还原而不是直接合并。"
        case .cannotMergeDifferentSceneStyles:
            return "这两个片段的场景外观不同，不能合并。"
        case .cannotMergeDifferentSources:
            return "不同录制的片段无法合并。"
        case .cannotMergeDifferentPlaybackRates:
            return "相邻片段速度不同，无法直接合并。"
        case .cannotMergeDifferentAudioOverrides:
            return "相邻片段的声音设置不同，无法直接合并。"
        case .invalidPrimarySegmentAudioOverrides:
            return "当前片段的声音设置无效。"
        case let .duplicateClipID(track, _):
            return "\(track.userFacingName)轨道中存在重复片段。"
        case let .missingClip(track, _):
            return "\(track.userFacingName)轨道中找不到要编辑的片段。"
        case let .mismatchedClipID(track, _, _):
            return "\(track.userFacingName)轨道中的片段已发生变化，请重新选择后再试。"
        case let .invalidClip(track, _):
            return "\(track.userFacingName)轨道中存在无效片段。"
        case let .overlappingClips(track, _, _):
            return "\(track.userFacingName)轨道中的片段发生重叠。"
        }
    }
}

private extension ProjectTimelineTrack {
    var userFacingName: String {
        switch self {
        case .primaryRecording: "主片段"
        case .zoom: "缩放"
        case .screenMotion: "屏幕 3D"
        case .cameraMotion: "摄像运动"
        case .mosaic: "打码"
        case .sticker: "贴图"
        case .animation: "动效"
        }
    }
}

/// Pure edit decisions for the lightweight primary-recording timeline.
///
/// Source intervals can be reused independently; array order is output order. Splitting preserves duration; trims,
/// removal and reordering transform every time-varying track with the edit.
public enum ProjectTimelineEditing {
    static let epsilon = 1.0 / 120_000.0

    public static func primarySegmentAudioOverrides(
        in timeline: ProjectTimeline,
        segmentID: UUID
    ) -> PrimarySegmentAudioOverrides {
        timeline.primarySegmentAudioOverrides[segmentID] ?? PrimarySegmentAudioOverrides()
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
            output += segments[index].outputDuration
            guard segments.indices.contains(index + 1),
                  segments[index].media == nil, segments[index + 1].media == nil,
                  segments[index].resolvedSourceID == segments[index + 1].resolvedSourceID,
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
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
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

        let splitOutputOffset = outputTime - resolved.outputStart
        let splitSourceOffset = splitOutputOffset * resolved.playbackRate
        var segments = map.segments.map(Self.authoredSegment)
        guard let index = segments.firstIndex(where: { $0.id == resolved.id }) else {
            throw ProjectTimelineEditingError.segmentNotFound(resolved.id)
        }
        segments[index].sourceDuration = splitSourceOffset
        segments.insert(
            RecordingSegment(
                id: newRightSegmentID,
                sourceStart: resolved.sourceStart + splitSourceOffset,
                sourceDuration: resolved.sourceDuration - splitSourceOffset,
                playbackRate: resolved.playbackRate,
                media: resolved.media,
                sourceID: resolved.sourceID,
                sceneStyle: resolved.sceneStyle,
                crop: resolved.crop
            ),
            at: index + 1
        )

        var result = timeline
        result.sourceSequence = .edited(segments)
        if let overrides = timeline.primarySegmentAudioOverrides[resolved.id] {
            result.primarySegmentAudioOverrides[newRightSegmentID] = overrides
        }
        try validate(result, sourceDurations: sourceDurations)
        return result
    }

    public static func trimPrimarySegment(
        in timeline: ProjectTimeline,
        segmentID: UUID,
        edge: RecordingSegmentTrimEdge,
        toOutputTime outputTime: TimeInterval,
        sourceDurations: [UUID: TimeInterval],
        defaultTransitionDuration: TimeInterval = 0.7
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
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
                let previousSourceEnd: TimeInterval = 0
                let available = max(resolved.sourceStart - previousSourceEnd, 0)
                let outputAmount = resolved.outputStart - outputTime
                let sourceAmount = outputAmount * resolved.playbackRate
                guard sourceAmount <= available + epsilon else {
                    throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
                }
                segments[index].sourceStart -= sourceAmount
                segments[index].sourceDuration += sourceAmount
                var result = timeline
                result.sourceSequence = .edited(segments)
                result.zoomClips = timeline.zoomClips.map {
                    inserting($0, at: resolved.outputStart, duration: outputAmount)
                }
                result.screenMotionClips = timeline.screenMotionClips.map {
                    inserting($0, at: resolved.outputStart, duration: outputAmount)
                }
                result.cameraMotionClips = timeline.cameraMotionClips.map {
                    inserting($0, at: resolved.outputStart, duration: outputAmount)
                }
                result.mosaicClips = timeline.mosaicClips.map {
                    inserting($0, at: resolved.outputStart, duration: outputAmount)
                }
                result.stickerClips = timeline.stickerClips.map {
                    inserting($0, at: resolved.outputStart, duration: outputAmount)
                }
                result.animationClips = timeline.animationClips.map {
                    inserting($0, at: resolved.outputStart, duration: outputAmount)
                }
                result.audioClips = timeline.audioClips.map { insertingTimed($0, at: resolved.outputStart, duration: outputAmount) }
                result.videoClips = insertingVideoGap(in: timeline.videoClips, at: resolved.outputStart, duration: outputAmount)
                result.subtitleCues = timeline.subtitleCues.map { insertingTimed($0, at: resolved.outputStart, duration: outputAmount) }
                sortZoom(&result.zoomClips)
                sortScreenMotion(&result.screenMotionClips)
                sortCameraMotion(&result.cameraMotionClips)
                try validate(result, sourceDurations: sourceDurations)
                return result
            }
            guard outputTime > resolved.outputStart + epsilon,
                  outputTime < resolved.outputEnd - epsilon else {
                throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
            }
            let sourceAmount = (outputTime - resolved.outputStart) * resolved.playbackRate
            segments[index].sourceStart += sourceAmount
            segments[index].sourceDuration -= sourceAmount
            deletion = OutputDeletion(start: resolved.outputStart, end: outputTime)

        case .right:
            if abs(outputTime - resolved.outputEnd) <= epsilon {
                return timeline
            }
            if outputTime > resolved.outputEnd + epsilon {
                let availableDuration = resolved.media?.fileDuration ?? sourceDurations[resolved.sourceID] ?? 0
                let nextSourceStart = availableDuration
                let available = max(nextSourceStart - resolved.sourceEnd, 0)
                let outputAmount = outputTime - resolved.outputEnd
                let sourceAmount = outputAmount * resolved.playbackRate
                guard sourceAmount <= available + epsilon else {
                    throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
                }
                segments[index].sourceDuration += sourceAmount
                var result = timeline
                result.sourceSequence = .edited(segments)
                result.zoomClips = timeline.zoomClips.map {
                    inserting($0, at: resolved.outputEnd, duration: outputAmount)
                }
                result.screenMotionClips = timeline.screenMotionClips.map {
                    inserting($0, at: resolved.outputEnd, duration: outputAmount)
                }
                result.cameraMotionClips = timeline.cameraMotionClips.map {
                    inserting($0, at: resolved.outputEnd, duration: outputAmount)
                }
                result.mosaicClips = timeline.mosaicClips.map {
                    inserting($0, at: resolved.outputEnd, duration: outputAmount)
                }
                result.stickerClips = timeline.stickerClips.map {
                    inserting($0, at: resolved.outputEnd, duration: outputAmount)
                }
                result.animationClips = timeline.animationClips.map {
                    inserting($0, at: resolved.outputEnd, duration: outputAmount)
                }
                result.audioClips = timeline.audioClips.map { insertingTimed($0, at: resolved.outputEnd, duration: outputAmount) }
                result.videoClips = insertingVideoGap(in: timeline.videoClips, at: resolved.outputEnd, duration: outputAmount)
                result.subtitleCues = timeline.subtitleCues.map { insertingTimed($0, at: resolved.outputEnd, duration: outputAmount) }
                sortZoom(&result.zoomClips)
                sortScreenMotion(&result.screenMotionClips)
                sortCameraMotion(&result.cameraMotionClips)
                try validate(result, sourceDurations: sourceDurations)
                return result
            }
            guard outputTime > resolved.outputStart + epsilon,
                  outputTime < resolved.outputEnd - epsilon else {
                throw ProjectTimelineEditingError.trimOutsideSegment(segmentID)
            }
            segments[index].sourceDuration =
                (outputTime - resolved.outputStart) * resolved.playbackRate
            deletion = OutputDeletion(start: outputTime, end: resolved.outputEnd)
        }

        return try ripple(
            timeline,
            replacingSourceSequenceWith: .edited(segments),
            deleting: deletion,
            deletesOutputTail: deletion.end >= map.outputDuration - epsilon,
            sourceDurations: sourceDurations,
            defaultTransitionDuration: defaultTransitionDuration
        )
    }

    public static func removePrimarySegment(
        from timeline: ProjectTimeline,
        segmentID: UUID,
        sourceDurations: [UUID: TimeInterval],
        defaultTransitionDuration: TimeInterval = 0.7
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
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
            sourceDurations: sourceDurations,
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
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try movePrimarySegments(in: timeline, segmentIDs: [segmentID], toIndex: requestedIndex,
                                sourceDurations: sourceDurations)
    }

    /// Moves a selection as one block, retaining its timeline order. The index
    /// is in the sequence after removing all selected segments. Remap effects
    /// once so a multi-clip move is one atomic edit, including undo.
    public static func movePrimarySegments(
        in timeline: ProjectTimeline,
        segmentIDs: Set<UUID>,
        toIndex requestedIndex: Int,
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let oldMap = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: sourceDurations)
        guard !segmentIDs.isEmpty else { return timeline }
        let existingIDs = Set(oldMap.segments.map(\.id))
        if let missing = segmentIDs.subtracting(existingIDs).first {
            throw ProjectTimelineEditingError.segmentNotFound(missing)
        }
        let selected = oldMap.segments.filter { segmentIDs.contains($0.id) }.map(Self.authoredSegment)
        var segments = oldMap.segments.filter { !segmentIDs.contains($0.id) }.map(Self.authoredSegment)
        let finalIndex = min(max(requestedIndex, 0), segments.count)
        segments.insert(contentsOf: selected, at: finalIndex)
        guard segments.map(\.id) != oldMap.segments.map(\.id) else { return timeline }
        let newMap = try TimelineMap(
            sourceSequence: .edited(segments),
            sourceDurations: sourceDurations
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
        result.mosaicClips = remappedMosaicClips(
            timeline.mosaicClips,
            oldMap: oldMap,
            newStarts: newStarts,
            outputDuration: newMap.outputDuration
        )
        result.stickerClips = remappedStickerClips(
            timeline.stickerClips,
            oldMap: oldMap,
            newStarts: newStarts,
            outputDuration: newMap.outputDuration
        )
        result.animationClips = remappedAnimationClips(
            timeline.animationClips,
            oldMap: oldMap,
            newStarts: newStarts,
            outputDuration: newMap.outputDuration
        )
        result.audioClips = remappedTimed(timeline.audioClips, oldMap: oldMap, newStarts: newStarts, outputDuration: newMap.outputDuration)
        result.videoClips = remappedTimed(timeline.videoClips, oldMap: oldMap, newStarts: newStarts, outputDuration: newMap.outputDuration)
        result.subtitleCues = remappedTimed(timeline.subtitleCues, oldMap: oldMap, newStarts: newStarts, outputDuration: newMap.outputDuration)
        try validate(result, sourceDurations: sourceDurations)
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
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
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
        guard previous.media == nil, next.media == nil, previous.sourceID == next.sourceID, restoredDuration > epsilon else {
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
                sourceDuration: restoredDuration,
                sourceID: previous.sourceID,
                sceneStyle: previous.sceneStyle,
                crop: previous.crop
            ),
            at: previousIndex + 1
        )
        let insertionTime = previous.outputEnd
        var result = timeline
        result.sourceSequence = .edited(segments)
        result.primarySegmentAudioOverrides[restoredSegmentID] =
            timeline.primarySegmentAudioOverrides[previousSegmentID]
        result.zoomClips = timeline.zoomClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.screenMotionClips = timeline.screenMotionClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.cameraMotionClips = timeline.cameraMotionClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.mosaicClips = timeline.mosaicClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.stickerClips = timeline.stickerClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.animationClips = timeline.animationClips.map {
            inserting($0, at: insertionTime, duration: restoredDuration)
        }
        result.audioClips = timeline.audioClips.map { insertingTimed($0, at: insertionTime, duration: restoredDuration) }
        result.videoClips = insertingVideoGap(in: timeline.videoClips, at: insertionTime, duration: restoredDuration)
        result.subtitleCues = timeline.subtitleCues.map { insertingTimed($0, at: insertionTime, duration: restoredDuration) }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result, sourceDurations: sourceDurations)
        return result
    }

    /// Restores source material removed before the first retained segment.
    /// The former UI only described junctions between two clips, making an
    /// opening trim impossible to undo from the timeline.
    public static func restorePrimaryLeadingGap(
        in timeline: ProjectTimeline,
        restoredSegmentID: UUID,
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
        )
        guard let first = map.segments.first, first.media == nil,
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
                sourceDuration: restoredDuration,
                sourceID: first.sourceID,
                sceneStyle: first.sceneStyle,
                crop: first.crop
            ),
            at: 0
        )
        var result = timeline
        result.sourceSequence = .edited(segments)
        result.primarySegmentAudioOverrides[restoredSegmentID] =
            timeline.primarySegmentAudioOverrides[first.id]
        result.zoomClips = timeline.zoomClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.screenMotionClips = timeline.screenMotionClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.cameraMotionClips = timeline.cameraMotionClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.mosaicClips = timeline.mosaicClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.stickerClips = timeline.stickerClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.animationClips = timeline.animationClips.map {
            inserting($0, at: 0, duration: restoredDuration)
        }
        result.audioClips = timeline.audioClips.map { insertingTimed($0, at: 0, duration: restoredDuration) }
        result.videoClips = insertingVideoGap(in: timeline.videoClips, at: 0, duration: restoredDuration)
        result.subtitleCues = timeline.subtitleCues.map { insertingTimed($0, at: 0, duration: restoredDuration) }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result, sourceDurations: sourceDurations)
        return result
    }

    /// Restores source material removed after the final retained segment.
    /// This is the right-edge counterpart of `restorePrimaryLeadingGap`:
    /// earlier cuts and every existing timed effect remain unchanged because
    /// the insertion happens strictly after the current output duration.
    public static func restorePrimaryTrailingGap(
        in timeline: ProjectTimeline,
        restoredSegmentID: UUID,
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
        )
        guard let last = map.segments.last else {
            throw ProjectTimelineEditingError.noRestorableTrailingSourceGap(
                restoredSegmentID
            )
        }
        let sourceAvailableDuration = sourceDurations[last.sourceID] ?? 0
        guard last.media == nil, sourceAvailableDuration - last.sourceEnd > epsilon else {
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
                sourceDuration: sourceAvailableDuration - last.sourceEnd,
                sourceID: last.sourceID,
                sceneStyle: last.sceneStyle,
                crop: last.crop
            )
        )
        var result = timeline
        result.sourceSequence = .edited(segments)
        result.primarySegmentAudioOverrides[restoredSegmentID] =
            timeline.primarySegmentAudioOverrides[last.id]
        try validate(result, sourceDurations: sourceDurations)
        return result
    }

    /// CUT-002: remove a structural split between two source-contiguous
    /// segments. Output time and every timed effect stay unchanged because no
    /// media interval is inserted or removed.
    public static func mergeAdjacentPrimarySegments(
        in timeline: ProjectTimeline,
        previousSegmentID: UUID,
        nextSegmentID: UUID,
        sourceDurations: [UUID: TimeInterval]
    ) throws -> ProjectTimeline {
        try validate(timeline, sourceDurations: sourceDurations)
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
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
        guard previous.sourceID == next.sourceID else {
            throw ProjectTimelineEditingError.cannotMergeDifferentSources(previous: previousSegmentID, next: nextSegmentID)
        }
        guard previous.media?.path == next.media?.path,
              abs(next.sourceStart - previous.sourceEnd) <= epsilon else {
            throw ProjectTimelineEditingError.cannotMergeDeletedGap(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }
        guard abs(next.playbackRate - previous.playbackRate) <= epsilon else {
            throw ProjectTimelineEditingError.cannotMergeDifferentPlaybackRates(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }
        guard previous.sceneStyle == next.sceneStyle else {
            throw ProjectTimelineEditingError.cannotMergeDifferentSceneStyles
        }
        guard primarySegmentAudioOverrides(
            in: timeline,
            segmentID: previousSegmentID
        ) == primarySegmentAudioOverrides(
            in: timeline,
            segmentID: nextSegmentID
        ) else {
            throw ProjectTimelineEditingError.cannotMergeDifferentAudioOverrides(
                previous: previousSegmentID,
                next: nextSegmentID
            )
        }

        var segments = map.segments.map(Self.authoredSegment)
        segments[previousIndex].sourceDuration = next.sourceEnd - previous.sourceStart
        segments.remove(at: previousIndex + 1)
        var result = timeline
        result.sourceSequence = .edited(segments)
        result.primarySegmentAudioOverrides.removeValue(forKey: nextSegmentID)
        try validate(result, sourceDurations: sourceDurations)
        return result
    }

    /// EDT-054: inserts an outside video into the main track at an output
    /// time. A segment under that time is split; everything from there on —
    /// recording, effects, overlays, audio and subtitles — moves later by the
    /// inserted length, so the programme grows.
    /// `sourceStart` is the in point inside the file: a drop that carries in
    /// and out marks places that span, not the head of the file.
    public static func insertMediaSegment(
        in timeline: ProjectTimeline,
        media: InsertedMedia,
        atOutputTime requestedTime: TimeInterval,
        duration requestedDuration: TimeInterval,
        newSegmentID: UUID,
        sourceDurations: [UUID: TimeInterval],
        sourceStart requestedSourceStart: TimeInterval = 0
    ) throws -> ProjectTimeline {
        let sourceStart = max(requestedSourceStart, 0)
        let duration = min(requestedDuration, media.fileDuration - sourceStart)
        guard duration > 0 else { throw ProjectTimelineEditingError.invalidSourceSequence }
        return try insertPrimarySegments(in: timeline,
            segments: [RecordingSegment(id: newSegmentID, sourceStart: sourceStart, sourceDuration: duration, media: media)],
            atOutputTime: requestedTime, sourceDurations: sourceDurations, splitEffectsAtInsertion: false)
    }

    /// Inserts authored recording/media segments without losing source ranges,
    /// playback rates or per-segment appearance. Existing tracks ripple once.
    public static func insertPrimarySegments(
        in original: ProjectTimeline,
        segments inserted: [RecordingSegment],
        audioOverrides: [UUID: PrimarySegmentAudioOverrides] = [:],
        atOutputTime requestedTime: TimeInterval,
        sourceDurations: [UUID: TimeInterval],
        splitEffectsAtInsertion: Bool = true
    ) throws -> ProjectTimeline {
        let map = try TimelineMap(sourceSequence: original.sourceSequence, sourceDurations: sourceDurations)
        let requestedTime = RecordingProjectImport.insertionTime(requestedTime, map: map)
        let timeline = splitEffectsAtInsertion ? RecordingProjectImport.splitEdits(original, at: requestedTime) : original
        try validate(timeline, sourceDurations: sourceDurations)
        let duration = inserted.reduce(0) { $0 + $1.outputDuration }
        guard !inserted.isEmpty, duration.isFinite, duration > 0 else {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
        var segments = map.segments.map(Self.authoredSegment)
        var overrides = timeline.primarySegmentAudioOverrides
        // Snap to the nearest boundary when within a frame, otherwise split.
        var insertIndex = segments.count
        var insertionTime = map.outputDuration
        if let resolved = map.segment(atOutputTime: min(max(requestedTime, 0), map.outputDuration)) {
            let index = segments.firstIndex { $0.id == resolved.id } ?? segments.count
            if requestedTime - resolved.outputStart < 1.0 / 60 {
                insertIndex = index
                insertionTime = resolved.outputStart
            } else if resolved.outputEnd - requestedTime < 1.0 / 60 {
                insertIndex = index + 1
                insertionTime = resolved.outputEnd
            } else {
                let sourceOffset = (requestedTime - resolved.outputStart) * resolved.playbackRate
                segments[index].sourceDuration = sourceOffset
                let rightID = UUID()
                segments.insert(RecordingSegment(
                    id: rightID,
                    sourceStart: resolved.sourceStart + sourceOffset,
                    sourceDuration: resolved.sourceDuration - sourceOffset,
                    playbackRate: resolved.playbackRate,
                    media: resolved.media,
                    sourceID: resolved.sourceID,
                sceneStyle: resolved.sceneStyle,
                crop: resolved.crop
                ), at: index + 1)
                overrides[rightID] = overrides[resolved.id]
                insertIndex = index + 1
                insertionTime = requestedTime
            }
        }
        segments.insert(contentsOf: inserted, at: insertIndex)
        for segment in inserted { overrides[segment.id] = audioOverrides[segment.id] }
        var result = timeline
        result.primarySegmentAudioOverrides = overrides
        result.sourceSequence = .edited(segments)
        result.zoomClips = timeline.zoomClips.map { inserting($0, at: insertionTime, duration: duration) }
        result.screenMotionClips = timeline.screenMotionClips.map { inserting($0, at: insertionTime, duration: duration) }
        result.cameraMotionClips = timeline.cameraMotionClips.map { inserting($0, at: insertionTime, duration: duration) }
        result.mosaicClips = timeline.mosaicClips.map { inserting($0, at: insertionTime, duration: duration) }
        result.stickerClips = timeline.stickerClips.map { inserting($0, at: insertionTime, duration: duration) }
        result.animationClips = timeline.animationClips.map { inserting($0, at: insertionTime, duration: duration) }
        result.audioClips = timeline.audioClips.map { insertingTimed($0, at: insertionTime, duration: duration) }
        result.videoClips = insertingVideoGap(in: timeline.videoClips, at: insertionTime, duration: duration)
        result.subtitleCues = timeline.subtitleCues.map { insertingTimed($0, at: insertionTime, duration: duration) }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        try validate(result, sourceDurations: sourceDurations)
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
        sortScreenMotion(&result.screenMotionClips)
        // A removed successor frees room for the originally authored return.
        if let predecessorID,
           let index = result.screenMotionClips.firstIndex(where: { $0.id == predecessorID }) {
            let original = result.screenMotionClips[index].timing
            var timing = original
            timing.preserveTransitionIntent(defaultTransition: defaultReturn)
            let requested = timing.requestedReturnDuration(defaultTransition: defaultReturn)
            let available = result.screenMotionClips.indices.contains(index + 1)
                ? result.screenMotionClips[index + 1].timing.startTime - timing.endTime
                : requested
            if available > ZoomInterpolator.adjacencyTolerance {
                timing.returnDuration = min(requested, max(available, 0))
                if timing.returnDuration > original.returnDuration + 0.000_001 {
                    timing.returnProgressOffset = 0
                }
                result.screenMotionClips[index].timing = timing
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
        sortCameraMotion(&result.cameraMotionClips)
        // A removed successor frees room for the originally authored return.
        if let predecessorID,
           let index = result.cameraMotionClips.firstIndex(where: { $0.id == predecessorID }) {
            let original = result.cameraMotionClips[index].timing
            var timing = original
            timing.preserveTransitionIntent(defaultTransition: defaultReturn)
            let requested = timing.requestedReturnDuration(defaultTransition: defaultReturn)
            let available = result.cameraMotionClips.indices.contains(index + 1)
                ? result.cameraMotionClips[index + 1].timing.startTime - timing.endTime
                : requested
            if available > ZoomInterpolator.adjacencyTolerance {
                timing.returnDuration = min(requested, max(available, 0))
                if timing.returnDuration > original.returnDuration + 0.000_001 {
                    timing.returnProgressOffset = 0
                }
                result.cameraMotionClips[index].timing = timing
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
        try validatePrimarySegmentAudioOverrides(
            timeline.primarySegmentAudioOverrides,
            sourceSequence: timeline.sourceSequence
        )
        try validateZoomClips(timeline.zoomClips)
        try validateScreenMotionClips(timeline.screenMotionClips)
        try validateCameraMotionClips(timeline.cameraMotionClips)
        try validateMosaicClips(timeline.mosaicClips)
        try validateStickerClips(timeline.stickerClips)
        try validateAnimationClips(timeline.animationClips)
        for video in timeline.videoClips { try video.validateSourceRange() }
    }

    public static func validate(
        _ timeline: ProjectTimeline,
        sourceDurations: [UUID: TimeInterval]
    ) throws {
        _ = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            sourceDurations: sourceDurations
        )
        try validate(timeline)
    }
}

extension ProjectTimelineEditing {
    static func validateAnimationClips(_ clips: [AnimationClip]) throws {
        for clip in clips {
            guard clip.timing.startTime.isFinite, clip.timing.startTime >= 0,
                  clip.timing.duration.isFinite, clip.timing.duration > 0,
                  clip.width.isFinite, clip.width > 0,
                  clip.opacity.isFinite, (0...1).contains(clip.opacity),
                  clip.playbackRate.isFinite, clip.playbackRate > 0,
                  clip.cameraSlot?.isValid != false, !clip.sourcePath.isEmpty else {
                throw ProjectTimelineEditingError.invalidClip(track: .animation, id: clip.id)
            }
        }
    }
}
