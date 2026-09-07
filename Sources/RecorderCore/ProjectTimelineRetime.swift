import Foundation

private struct PlaybackRateTimeTransform {
    let segmentStart: TimeInterval
    let oldSegmentEnd: TimeInterval
    let newSegmentEnd: TimeInterval
    let insideScale: Double

    var tailOffset: TimeInterval { newSegmentEnd - oldSegmentEnd }

    func mapAnchor(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return time }
        if time <= segmentStart { return time }
        if time >= oldSegmentEnd { return time + tailOffset }
        return segmentStart + (time - segmentStart) * insideScale
    }

    func map(_ timing: OverlayTiming) -> OverlayTiming {
        OverlayTiming(
            startTime: mapAnchor(timing.startTime),
            duration: timing.duration
        )
    }

    func map(_ timing: TransitionTiming) -> TransitionTiming {
        var result = timing
        result.startTime = mapAnchor(timing.startTime)
        return result
    }

    func map(_ clip: ZoomAnimationClip) -> ZoomAnimationClip {
        var result = clip
        let duration = clip.duration
        result.startTime = mapAnchor(clip.startTime)
        result.endTime = result.startTime + duration
        return result
    }

    func map(_ time: TimeInterval) -> TimeInterval {
        mapAnchor(time)
    }
}

public extension ProjectTimelineEditing {
    /// Changes one retained primary segment's media speed. Timed objects move
    /// with the ripple edit, but their authored durations and easing windows
    /// remain on the output clock so a 100× clip cannot turn a smooth 0.7 s
    /// zoom/camera transition into an imperceptible flash.
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
        let rate = min(
            max(
                requestedRate.isFinite
                    ? requestedRate
                    : RecordingSegment.minimumPlaybackRate,
                RecordingSegment.minimumPlaybackRate
            ),
            RecordingSegment.maximumPlaybackRate
        )
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
        result.zoomClips = nonoverlappingZoomClips(
            timeline.zoomClips.map(transform.map)
        )
        result.screenMotionClips = timeline.screenMotionClips.map { clip in
            var edited = clip
            edited.timing = transform.map(clip.timing)
            return edited
        }
        result.screenMotionClips = nonoverlappingScreenMotionClips(
            result.screenMotionClips
        )
        result.cameraMotionClips = timeline.cameraMotionClips.map { clip in
            var edited = clip
            edited.timing = transform.map(clip.timing)
            return edited
        }
        result.cameraMotionClips = nonoverlappingCameraMotionClips(
            result.cameraMotionClips
        )
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

private extension ProjectTimelineEditing {
    /// Preserving output-time animation durations can bring two animations
    /// closer together when the media beneath them is compressed. Move the
    /// later animation forward instead of shortening either transition.
    static func nonoverlappingZoomClips(
        _ clips: [ZoomAnimationClip]
    ) -> [ZoomAnimationClip] {
        var result: [ZoomAnimationClip] = []
        for var clip in clips {
            if let previous = result.last,
               !EditorTimelineMath.zoomSequenceIsValid(
                   previous: previous,
                   next: clip
               ) {
                let minimumStart = clip.startTime < previous.endTime
                    ? previous.endTime
                    : previous.effectEndTime
                let duration = clip.duration
                clip.startTime = minimumStart
                clip.endTime = minimumStart + duration
            }
            result.append(clip)
        }
        return result
    }

    static func nonoverlappingScreenMotionClips(
        _ clips: [ScreenMotionClip]
    ) -> [ScreenMotionClip] {
        nonoverlappingTransitionClips(
            clips,
            timing: { $0.timing },
            setTiming: { $0.timing = $1 }
        )
    }

    static func nonoverlappingCameraMotionClips(
        _ clips: [CameraMotionClip]
    ) -> [CameraMotionClip] {
        nonoverlappingTransitionClips(
            clips,
            timing: { $0.timing },
            setTiming: { $0.timing = $1 }
        )
    }

    static func nonoverlappingTransitionClips<Clip>(
        _ clips: [Clip],
        timing: (Clip) -> TransitionTiming,
        setTiming: (inout Clip, TransitionTiming) -> Void
    ) -> [Clip] {
        var result: [Clip] = []
        for var clip in clips {
            var current = timing(clip)
            if let previousClip = result.last {
                let previous = timing(previousClip)
                let gap = current.startTime - previous.endTime
                let touches = gap <= ZoomInterpolator.adjacencyTolerance
                let clearsReturn = current.startTime
                    >= previous.effectEndTime - 0.000_1
                if current.startTime < previous.endTime - 0.000_1
                    || (!touches && !clearsReturn) {
                    current.startTime = current.startTime < previous.endTime
                        ? previous.endTime
                        : previous.effectEndTime
                    setTiming(&clip, current)
                }
            }
            result.append(clip)
        }
        return result
    }
}
