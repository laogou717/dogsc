import Foundation

private struct PlaybackRateTimeTransform {
    let segmentStart: TimeInterval
    let oldSegmentEnd: TimeInterval
    let newSegmentEnd: TimeInterval
    let insideScale: Double

    var tailOffset: TimeInterval { newSegmentEnd - oldSegmentEnd }

    func map(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return time }
        if time <= segmentStart { return time }
        if time >= oldSegmentEnd { return time + tailOffset }
        return segmentStart + (time - segmentStart) * insideScale
    }

    func map(_ timing: OverlayTiming) -> OverlayTiming {
        let start = map(timing.startTime)
        let end = map(timing.endTime)
        return OverlayTiming(startTime: start, duration: max(end - start, 0.000_001))
    }

    func map(_ timing: TransitionTiming) -> TransitionTiming {
        let start = map(timing.startTime)
        let end = map(timing.endTime)
        let leadInEnd = map(
            timing.startTime + min(timing.leadInDuration, timing.duration)
        )
        let returnEnd = map(timing.effectEndTime)
        var result = timing
        result.startTime = start
        result.duration = max(end - start, 0.000_001)
        result.leadInDuration = min(max(leadInEnd - start, 0), 5)
        result.returnDuration = min(max(returnEnd - end, 0), 5)
        return result
    }

    func map(_ clip: ZoomAnimationClip) -> ZoomAnimationClip {
        let start = map(clip.startTime)
        let end = map(clip.endTime)
        let enterEnd = map(clip.startTime + min(clip.enterDuration, clip.duration))
        let effectEnd = map(clip.effectEndTime)
        var result = clip
        result.startTime = start
        result.endTime = max(end, start)
        result.enterDuration = min(max(enterEnd - start, 0), 5)
        result.exitDuration = min(max(effectEnd - end, 0), 5)
        return result
    }
}

public extension ProjectTimelineEditing {
    /// Changes one retained primary segment's speed and maps every authored
    /// output-time value through the same piecewise transform. Effects remain
    /// attached to the recorded actions they were authored against.
    static func settingPlaybackRate(
        _ requestedRate: Double,
        for segmentID: UUID,
        in timeline: ProjectTimeline,
        fullSourceDuration: TimeInterval
    ) throws -> ProjectTimeline {
        try validate(timeline, fullSourceDuration: fullSourceDuration)
        let oldMap = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
        guard let resolved = oldMap.segments.first(where: { $0.id == segmentID }) else {
            throw ProjectTimelineEditingError.segmentNotFound(segmentID)
        }
        let rate = min(max(requestedRate.isFinite ? requestedRate : 1, 1), 20)
        guard abs(rate - resolved.playbackRate) > epsilon else { return timeline }

        var authored = oldMap.segments.map(authoredSegment)
        guard let index = authored.firstIndex(where: { $0.id == segmentID }) else {
            throw ProjectTimelineEditingError.segmentNotFound(segmentID)
        }
        authored[index].playbackRate = rate

        let transform = PlaybackRateTimeTransform(
            segmentStart: resolved.outputStart,
            oldSegmentEnd: resolved.outputEnd,
            newSegmentEnd: resolved.outputStart + resolved.sourceDuration / rate,
            insideScale: resolved.playbackRate / rate
        )

        var result = timeline
        result.sourceSequence = .edited(authored)
        result.zoomClips = timeline.zoomClips.map(transform.map)
        result.screenMotionClips = timeline.screenMotionClips.map { clip in
            var edited = clip
            edited.timing = transform.map(clip.timing)
            return edited
        }
        result.cameraMotionClips = timeline.cameraMotionClips.map { clip in
            var edited = clip
            edited.timing = transform.map(clip.timing)
            return edited
        }
        result.mosaicClips = timeline.mosaicClips.map { clip in
            var edited = clip
            edited.timing = transform.map(clip.timing)
            return edited
        }
        result.stickerClips = timeline.stickerClips.map { clip in
            var edited = clip
            edited.timing = transform.map(clip.timing)
            edited.enterDuration = min(
                edited.enterDuration,
                edited.timing.duration
            )
            edited.exitDuration = min(
                edited.exitDuration,
                edited.timing.duration
            )
            return edited
        }
        if var progress = timeline.progressOverlay {
            progress.chapters = progress.chapters.map { chapter in
                var edited = chapter
                edited.time = transform.map(chapter.time)
                return edited
            }.sorted {
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.id.uuidString < $1.id.uuidString
            }
            result.progressOverlay = progress
        }

        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        result.mosaicClips.sort { lhs, rhs in
            lhs.timing.startTime == rhs.timing.startTime
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.timing.startTime < rhs.timing.startTime
        }
        result.stickerClips.sort { lhs, rhs in
            if lhs.layerIndex != rhs.layerIndex { return lhs.layerIndex < rhs.layerIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }
}
