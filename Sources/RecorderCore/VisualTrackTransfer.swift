import Foundation

/// Presentation saved while an authored visual changes track roles.
public struct MainTrackVisualStyle: Codable, Equatable, Sendable {
    public var usesFrameStyle: Bool
    public var screenAppearance: ScreenCardAppearance?
    public var sceneStyle: SegmentSceneStyle?
}

public struct VisualClipSound: Codable, Equatable, Sendable {
    public var path: String
    public var volume: Double
    public var fadeIn: TimeInterval
    public var fadeOut: TimeInterval

    public init(path: String, volume: Double = 1, fadeIn: TimeInterval = 0, fadeOut: TimeInterval = 0) {
        self.path = path; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

public enum TransferableVisualClip: Codable, Equatable, Sendable {
    case video(VideoClip)
    case animation(AnimationClip)
    case sticker(StickerClip)

    public var id: UUID {
        switch self { case let .video(c): c.id; case let .animation(c): c.id; case let .sticker(c): c.id }
    }
    public var timing: OverlayTiming {
        switch self { case let .video(c): c.timing; case let .animation(c): c.timing; case let .sticker(c): c.timing }
    }
    public var sourceStart: TimeInterval {
        switch self { case let .video(c): c.sourceStart; case let .animation(c): c.timeOffset; case let .sticker(c): c.sourceStart }
    }
    public var playbackRate: Double {
        switch self { case let .video(c): c.playbackRate; case let .animation(c): c.playbackRate; case let .sticker(c): c.playbackRate }
    }
    public var mainTrackStyle: MainTrackVisualStyle? {
        switch self { case let .video(c): c.mainTrackStyle; case let .animation(c): c.mainTrackStyle; case let .sticker(c): c.mainTrackStyle }
    }

    public static func find(_ id: UUID, in timeline: ProjectTimeline) -> Self? {
        if let c = timeline.videoClips.first(where: { $0.id == id }) { return .video(c) }
        if let c = timeline.animationClips.first(where: { $0.id == id }) { return .animation(c) }
        if let c = timeline.stickerClips.first(where: { $0.id == id }) { return .sticker(c) }
        return nil
    }
}

public enum VisualTrackTransferError: Error {
    case unsupportedClip, insufficientMainDuration
}

public enum VisualTrackTransfer {
    /// A cross-track move ripples the other tracks. Keep the video's detached
    /// sounds out of that edit so their source ranges and reattachment IDs survive.
    private struct DetachedAudio {
        let group: UUID
        let clips: [AudioClip]

        init?(_ attachment: VideoAudioAttachment?, takingFrom timeline: inout ProjectTimeline) {
            guard let group = attachment?.detachedGroup else { return nil }
            let clips = timeline.audioClips.filter { $0.videoOrigin?.group == group }
            guard !clips.isEmpty else { return nil }
            self.group = group
            self.clips = clips
            timeline.audioClips.removeAll { $0.videoOrigin?.group == group }
        }

        /// Call before attaching the moved video at its destination. A group
        /// shared with other split occurrences keeps its own timeline placement.
        func place(in timeline: inout ProjectTimeline, movingBy delta: TimeInterval, outputDuration: TimeInterval) {
            var shift = timeline.hasDetachedVideo(group: group) ? 0 : delta
            // Slide the sounds together at a programme edge when they fit as a group.
            if let first = clips.map(\.timing.startTime).min(), let last = clips.map(\.timing.endTime).max(),
               last - first <= outputDuration {
                shift = min(max(shift, -first), outputDuration - last)
            }
            for var clip in clips {
                let latestStart = max(0, outputDuration - clip.timing.duration)
                clip.timing.startTime = min(max(0, clip.timing.startTime + shift), latestStart)
                timeline.audioClips.append(clip)
            }
        }
    }

    /// Source is removed before the insertion ripples the remaining tracks.
    /// Media preparation (stand-in/image video) is owned by the app, not this edit.
    public static func moveToMain(_ id: UUID, media prepared: InsertedMedia, at time: TimeInterval,
                                  in original: ProjectTimeline, sourceDurations: [UUID: TimeInterval]) throws -> ProjectTimeline {
        guard let clip = TransferableVisualClip.find(id, in: original) else { throw VisualTrackTransferError.unsupportedClip }
        var timeline = original
        var detachedAudio: DetachedAudio?
        var media = prepared
        media.overlayOrigin = clip
        media.usesFrameStyle = clip.mainTrackStyle?.usesFrameStyle ?? false
        media.screenAppearance = clip.mainTrackStyle?.screenAppearance ?? media.screenAppearance
        switch clip {
        case let .animation(c):
            media.cameraSlot = c.cameraSlot
            media.motionPath = c.sourcePath; media.properties = c.properties; media.elementEdits = c.elementEdits
            media.soundPath = c.soundtrack?.path; media.transferSound = c.soundtrack
        case let .video(c):
            media.transferSound = VisualClipSound(path: c.sourcePath, volume: c.volume)
            detachedAudio = DetachedAudio(c.videoAudio, takingFrom: &timeline)
        case .sticker: break
        }
        timeline.videoClips.removeAll { $0.id == id }
        timeline.animationClips.removeAll { $0.id == id }
        timeline.stickerClips.removeAll { $0.id == id }
        let segment = RecordingSegment(id: id, sourceStart: clip.sourceStart,
            sourceDuration: clip.timing.duration * clip.playbackRate, playbackRate: clip.playbackRate,
            media: media, sceneStyle: clip.mainTrackStyle?.sceneStyle)
        var result = try ProjectTimelineEditing.insertPrimarySegments(in: timeline, segments: [segment],
            atOutputTime: time, sourceDurations: sourceDurations)
        if let detachedAudio {
            let map = try TimelineMap(sourceSequence: result.sourceSequence, sourceDurations: sourceDurations)
            guard let placed = map.segments.first(where: { $0.id == id }) else {
                throw ProjectTimelineEditingError.segmentNotFound(id)
            }
            detachedAudio.place(in: &result, movingBy: placed.outputStart - clip.timing.startTime,
                                outputDuration: map.outputDuration)
        }
        if case let .video(video) = clip, let attachment = video.videoAudio {
            var settings = PrimarySegmentAudioOverrides(systemVolume: video.volume, isSystemMuted: false)
            settings.videoAudio = attachment
            result.primarySegmentAudioOverrides[id] = settings
        }
        return result
    }

    public static func moveToOverlay(_ id: UUID, at requestedTime: TimeInterval, layer: Int?,
                                     in original: ProjectTimeline, sourceDurations: [UUID: TimeInterval],
                                     defaultTransition: TimeInterval, newVideoCameraMode: VideoCameraMode = .pictureInPicture,
                                     videoSourceEnd: TimeInterval? = nil) throws -> ProjectTimeline {
        let map = try TimelineMap(sourceSequence: original.sourceSequence, sourceDurations: sourceDurations)
        guard let segment = map.segments.first(where: { $0.id == id }), let media = segment.media else {
            throw VisualTrackTransferError.unsupportedClip
        }
        let overrides = original.primarySegmentAudioOverrides[id]
        var timeline = original
        let detachedAudio = DetachedAudio(overrides?.videoAudio, takingFrom: &timeline)
        timeline = try ProjectTimelineEditing.removePrimarySegment(from: timeline, segmentID: id,
            sourceDurations: sourceDurations, defaultTransitionDuration: defaultTransition)
        let remaining = map.outputDuration - segment.outputDuration
        guard segment.outputDuration <= remaining + 0.000_001 else { throw VisualTrackTransferError.insufficientMainDuration }
        let timing = OverlayTiming(startTime: min(max(requestedTime, 0), max(remaining - segment.outputDuration, 0)),
                                   duration: segment.outputDuration)
        detachedAudio?.place(in: &timeline, movingBy: timing.startTime - segment.outputStart, outputDuration: remaining)
        let targetLayer = layer ?? timeline.visualLayer(for: timing)
        let style = MainTrackVisualStyle(usesFrameStyle: media.usesFrameStyle,
            screenAppearance: media.screenAppearance, sceneStyle: segment.sceneStyle)
        var volume = overrides?.systemVolume ?? media.transferSound?.volume ?? 1
        if overrides?.isSystemMuted == true { volume = 0 }
        let stickerOrigin: StickerClip?
        if case let .sticker(saved) = media.overlayOrigin { stickerOrigin = saved }
        else if let path = media.imagePath {
            stickerOrigin = StickerClip(id: id, timing: timing, relativePath: path, width: 1,
                cornerRadius: 0, shadowOpacity: 0, animation: .none, enterDuration: 0, exitDuration: 0, backdropBlur: 0)
        } else { stickerOrigin = nil }
        if let path = media.motionPath {
            var clip: AnimationClip
            if case let .animation(saved) = media.overlayOrigin { clip = saved }
            else { clip = AnimationClip(id: id, timing: timing, sourcePath: path, width: 1) }
            clip.id = id; clip.timing = timing; clip.sourcePath = path
            clip.timeOffset = segment.sourceStart; clip.playbackRate = segment.playbackRate
            clip.cameraSlot = media.cameraSlot
            clip.properties = media.properties; clip.elementEdits = media.elementEdits
            clip.layerIndex = targetLayer; clip.mainTrackStyle = style
            if let soundPath = media.soundPath {
                clip.soundtrack = VisualClipSound(path: soundPath, volume: volume,
                    fadeIn: media.transferSound?.fadeIn ?? 0, fadeOut: media.transferSound?.fadeOut ?? 0)
            }
            timeline.animationClips.append(clip)
        } else if var clip = stickerOrigin {
            if let path = media.imagePath { clip.relativePath = path }
            clip.id = id; clip.timing = timing; clip.layerIndex = targetLayer; clip.mainTrackStyle = style
            clip.sourceStart = segment.sourceStart; clip.playbackRate = segment.playbackRate
            timeline.stickerClips.append(clip)
        } else {
            var clip: VideoClip
            if case let .video(saved) = media.overlayOrigin { clip = saved }
            else {
                clip = VideoClip(id: id, timing: timing, sourcePath: media.path,
                                 aspect: 1 / max(media.sourceAspectRatio ?? (16.0 / 9.0), 0.001))
                clip.cameraMode = newVideoCameraMode
            }
            clip.id = id; clip.timing = timing; clip.sourcePath = media.path
            clip.sourceStart = segment.sourceStart; clip.playbackRate = segment.playbackRate
            clip.sourceFileEnd = videoSourceEnd ?? clip.sourceFileEnd ?? media.fileDuration
            clip.videoAudio = overrides?.videoAudio
            clip.volume = volume; clip.layerIndex = targetLayer; clip.mainTrackStyle = style
            timeline.videoClips.append(clip)
        }
        try ProjectTimelineEditing.validate(timeline, sourceDurations: sourceDurations)
        return timeline
    }
}
