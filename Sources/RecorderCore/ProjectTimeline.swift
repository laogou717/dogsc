import Foundation

/// EDT-054: an outside video placed on the main track. Its segment's
/// `sourceStart/sourceDuration` are seconds in this file, not the recording.
/// Images retain their original file; a tiny video supplies AVFoundation's
/// timeline clock while the compositor draws the still or animated image.
public struct InsertedMedia: Codable, Equatable, Sendable {
    /// Project-relative when inside the package, otherwise absolute.
    public var path: String
    public var fileDuration: TimeInterval
    public var name: String
    /// EDT-067: false (default) fills the whole canvas, like a title card or
    /// black; true shows it inside the recording's frame — background,
    /// padding, corners and shadow — like the recording itself.
    public var usesFrameStyle: Bool
    public var screenAppearance: ScreenCardAppearance?
    public var sourceAspectRatio: Double?
    /// EDT-071: an HTML motion played live on the main track. `path` is then
    /// only a black stand-in that gives the span a video track; the picture
    /// is drawn from this page (with `properties`) in preview and export, so
    /// its text and colours stay editable.
    public var cameraSlot: MotionCameraSlot?
    public var motionPath: String?
    public var imagePath: String?
    public var properties: [String: AnimationPropertyValue]
    /// The clip's own soundtrack (an HTML motion's sound effects).
    public var soundPath: String?
    /// Per-element edits of the HTML motion (EDT-073).
    public var elementEdits: [String: MotionElementEdit] = [:]
    public var overlayOrigin: TransferableVisualClip? = nil
    public var transferSound: VisualClipSound? = nil

    /// Whether this main-track insert carries its own soundtrack (an embedded
    /// motion sound, transferred overlay sound, or imported video file). Silent
    /// HTML motion stand-in videos and still images have no embedded audio.
    public var hasEmbeddedAudio: Bool {
        guard imagePath == nil else { return false }
        if transferSound != nil || soundPath != nil { return true }
        return motionPath == nil
    }

    public init(path: String, fileDuration: TimeInterval, name: String, usesFrameStyle: Bool = false,
                motionPath: String? = nil, properties: [String: AnimationPropertyValue] = [:], soundPath: String? = nil,
                screenAppearance: ScreenCardAppearance? = ScreenCardAppearance(), sourceAspectRatio: Double? = nil,
                imagePath: String? = nil) {
        self.path = path
        self.fileDuration = fileDuration
        self.name = name
        self.usesFrameStyle = usesFrameStyle
        self.screenAppearance = screenAppearance
        self.sourceAspectRatio = sourceAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.motionPath = motionPath
        self.imagePath = imagePath
        self.properties = properties
        self.soundPath = soundPath
    }

    private enum CodingKeys: String, CodingKey { case cameraSlot, path, fileDuration, name, usesFrameStyle, motionPath, imagePath, properties, soundPath, elementEdits, screenAppearance, sourceAspectRatio, overlayOrigin, transferSound }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        fileDuration = try c.decode(TimeInterval.self, forKey: .fileDuration)
        name = try c.decode(String.self, forKey: .name)
        usesFrameStyle = try c.decodeIfPresent(Bool.self, forKey: .usesFrameStyle) ?? false
        screenAppearance = try c.decodeIfPresent(ScreenCardAppearance.self, forKey: .screenAppearance)
        sourceAspectRatio = try c.decodeIfPresent(Double.self, forKey: .sourceAspectRatio).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        cameraSlot = try c.decodeIfPresent(MotionCameraSlot.self, forKey: .cameraSlot)
        motionPath = try c.decodeIfPresent(String.self, forKey: .motionPath)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        properties = try c.decodeIfPresent([String: AnimationPropertyValue].self, forKey: .properties) ?? [:]
        soundPath = try c.decodeIfPresent(String.self, forKey: .soundPath)
        elementEdits = try c.decodeIfPresent([String: MotionElementEdit].self, forKey: .elementEdits) ?? [:]
        overlayOrigin = try c.decodeIfPresent(TransferableVisualClip.self, forKey: .overlayOrigin)
        transferSound = try c.decodeIfPresent(VisualClipSound.self, forKey: .transferSound)
    }
}

/// One retained portion of the original recording, or an inserted video.
///
/// Segment order is output order. The lightweight editor deliberately does not
/// persist a second `outputStart`: it is derived by accumulating durations, so
/// a trim or ripple delete cannot leave two contradictory timeline positions.
public struct RecordingSegment: Codable, Equatable, Identifiable, Sendable {
    /// The editing surface deliberately supports substantial time compression
    /// for long pauses and setup work while keeping the persisted contract
    /// bounded to a rate AVFoundation can handle predictably.
    public static let minimumPlaybackRate: Double = 1
    public static let maximumPlaybackRate: Double = 100

    public var id: UUID
    public var sourceStart: TimeInterval
    public var sourceDuration: TimeInterval
    /// Source seconds consumed by one output second. The editor exposes
    /// 1×...100× fast-forward; animation tracks remain on the output clock.
    public var playbackRate: Double
    /// Set when this segment plays an inserted video instead of the recording.
    public var media: InsertedMedia?
    /// nil retains the legacy primary recording. Ignored for inserted media.
    public var sourceID: UUID?
    public var sceneStyle: SegmentSceneStyle?
    /// This occurrence's own crop. nil — the default — follows the recording
    /// source, so one re-crop still reframes the whole recording. A value
    /// detaches this clip alone, which is how the same recording can drop a
    /// sidebar before a cut and keep it after. Ignored for inserted media,
    /// and deliberately not part of `sceneStyle`: restyling a clip must not
    /// reframe it, and dropping the style must not restore the old crop.
    public var crop: NormalizedCrop?

    public var resolvedSourceID: UUID {
        media == nil ? (sourceID ?? RecordingSource.primaryID) : RecordingSource.primaryID
    }

    public init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval,
        playbackRate: Double = 1,
        media: InsertedMedia? = nil,
        sourceID: UUID? = nil,
        sceneStyle: SegmentSceneStyle? = nil,
        crop: NormalizedCrop? = nil
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.playbackRate = playbackRate.isFinite && playbackRate > 0
            ? playbackRate : 1
        self.media = media
        self.sourceID = sourceID
        self.sceneStyle = sceneStyle
        self.crop = crop?.clamped()
    }

    public var sourceEnd: TimeInterval {
        sourceStart + sourceDuration
    }

    public var outputDuration: TimeInterval {
        sourceDuration / playbackRate
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceStart, sourceDuration, playbackRate, media, sourceID, sceneStyle, crop
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            sourceStart: try container.decode(TimeInterval.self, forKey: .sourceStart),
            sourceDuration: try container.decode(TimeInterval.self, forKey: .sourceDuration),
            playbackRate: try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1,
            media: try container.decodeIfPresent(InsertedMedia.self, forKey: .media),
            sourceID: try container.decodeIfPresent(UUID.self, forKey: .sourceID),
            sceneStyle: try container.decodeIfPresent(SegmentSceneStyle.self, forKey: .sceneStyle),
            // Absent in every project saved before per-occurrence crops, which
            // is exactly the "follows the recording" default.
            crop: try container.decodeIfPresent(NormalizedCrop.self, forKey: .crop)
        )
    }
}

/// The persisted edit decision for the primary recording.
///
/// A newly recorded or legacy project remains `.fullRecording` until the user
/// performs the first destructive timeline edit. This lets migration stay pure:
/// decoding project JSON never needs to probe an AVAsset for its duration.
public enum SourceSequence: Codable, Equatable, Sendable {
    case fullRecording
    case edited([RecordingSegment])

    private enum Kind: String, Codable {
        case fullRecording
        case edited
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case segments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .fullRecording:
            self = .fullRecording
        case .edited:
            self = .edited(
                try container.decode([RecordingSegment].self, forKey: .segments)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullRecording:
            try container.encode(Kind.fullRecording, forKey: .kind)
        case let .edited(segments):
            try container.encode(Kind.edited, forKey: .kind)
            try container.encode(segments, forKey: .segments)
        }
    }
}

/// Timing shared by typed scene transitions. The clip interval is enter/hold:
/// the target eases in over `leadInDuration` at the start, then HOLDS until
/// `endTime`. After it ends, its target state remains active until another
/// clip changes it — unless `returnDuration` is nonzero, in which case a clip
/// that does NOT touch its successor eases back to the base state over that
/// window first (zoom-style enter/hold/return). Touching clips always chain.
public struct TransitionTiming: Codable, Equatable, Sendable {
    public var startTime: TimeInterval
    /// 整段时长（进入过渡 + 保持）；在时间线上拖动两端改变的就是它。
    public var duration: TimeInterval
    /// 进入过渡时长（速度：慢/标准/快调整的就是它）；0 = 直接跳变。
    /// 超过 duration 时按 duration 截断（整段都是过渡，无保持）。
    public var leadInDuration: TimeInterval
    /// 保留素材在剪切接点前的进入相位；起点被删除时从新接点重新进入。
    /// 0 = 从头开始，1 = 进入过渡已经完成。
    public var leadInProgressOffset: Double
    public var easing: ZoomEasingPreset
    public var customCurve: ZoomBezierCurve
    /// 结尾自动回到基础状态的过渡时长；0 = 保持目标状态（旧项目语义）。
    public var returnDuration: TimeInterval
    /// 剪切跨过回落起点时保留的回落相位；0 = 从目标开始回落，1 = 已回到基础状态。
    public var returnProgressOffset: Double
    /// Authored durations survive ripple fitting and temporary adjacency.
    public var preferredLeadInDuration: TimeInterval?
    public var preferredReturnDuration: TimeInterval?

    public var requestedLeadInDuration: TimeInterval { preferredLeadInDuration ?? leadInDuration }

    public func requestedReturnDuration(defaultTransition: TimeInterval = 0.7) -> TimeInterval {
        preferredReturnDuration ?? (returnDuration > 0.000_1 ? returnDuration : max(defaultTransition, 0))
    }

    public mutating func preserveTransitionIntent(defaultTransition: TimeInterval = 0.7) {
        if preferredLeadInDuration == nil { preferredLeadInDuration = leadInDuration }
        if preferredReturnDuration == nil {
            preferredReturnDuration = requestedReturnDuration(defaultTransition: defaultTransition)
        }
    }

    public init(
        startTime: TimeInterval,
        duration: TimeInterval = 0.7,
        leadInDuration: TimeInterval? = nil,
        easing: ZoomEasingPreset = .cubic,
        customCurve: ZoomBezierCurve = .cubic,
        returnDuration: TimeInterval = 0,
        leadInProgressOffset: Double = 0,
        returnProgressOffset: Double = 0,
        preferredLeadInDuration: TimeInterval? = nil,
        preferredReturnDuration: TimeInterval? = nil
    ) {
        self.startTime = startTime
        self.duration = duration
        self.leadInDuration = min(max(leadInDuration ?? duration, 0), 5)
        self.leadInProgressOffset = min(max(leadInProgressOffset, 0), 1)
        self.easing = easing
        self.customCurve = customCurve
        self.returnDuration = min(max(returnDuration, 0), 5)
        self.returnProgressOffset = min(max(returnProgressOffset, 0), 1)
        self.preferredLeadInDuration = preferredLeadInDuration
        self.preferredReturnDuration = preferredReturnDuration
    }

    public var endTime: TimeInterval {
        startTime + duration
    }

    /// 进入过渡完成（保持开始）的时间；leadIn 超出整段时按整段截断。
    public var leadInEndTime: TimeInterval {
        startTime + min(leadInDuration, duration)
    }

    public var effectEndTime: TimeInterval {
        endTime + returnDuration
    }

    private enum CodingKeys: String, CodingKey {
        case startTime, duration, leadInDuration, leadInProgressOffset
        case easing, customCurve, returnDuration, returnProgressOffset
        case preferredLeadInDuration, preferredReturnDuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        // 旧项目没有该字段：按新模型迁移——前 0.55s 进入过渡，其余保持
        // （否则旧片段在"过渡+保持"模型下仍是整段慢速过渡，永远停不住）
        leadInDuration = min(
            max(try container.decodeIfPresent(TimeInterval.self, forKey: .leadInDuration) ?? 0.55, 0),
            5
        )
        leadInProgressOffset = min(
            max(try container.decodeIfPresent(Double.self, forKey: .leadInProgressOffset) ?? 0, 0),
            1
        )
        easing = try container.decodeIfPresent(ZoomEasingPreset.self, forKey: .easing) ?? .cubic
        customCurve = try container.decodeIfPresent(ZoomBezierCurve.self, forKey: .customCurve) ?? .cubic
        returnDuration = min(
            max(try container.decodeIfPresent(TimeInterval.self, forKey: .returnDuration) ?? 0, 0),
            5
        )
        preferredLeadInDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .preferredLeadInDuration)
        preferredReturnDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .preferredReturnDuration)
        returnProgressOffset = min(
            max(try container.decodeIfPresent(Double.self, forKey: .returnProgressOffset) ?? 0, 0),
            1
        )
    }
}

/// Optional per-source overrides owned by one primary segment.
///
/// Missing values deliberately inherit the project-wide audio setting. This
/// keeps the familiar System Sound / Microphone controls as the default while
/// allowing a selected clip to diverge only for the source the user edits.
public struct PrimarySegmentAudioOverrides: Codable, Equatable, Sendable {
    public var videoAudio: VideoAudioAttachment?
    public var systemVolume: Double?
    public var microphoneVolume: Double?
    public var isSystemMuted: Bool?
    public var isMicrophoneMuted: Bool?

    public init(
        systemVolume: Double? = nil,
        microphoneVolume: Double? = nil,
        isSystemMuted: Bool? = nil,
        isMicrophoneMuted: Bool? = nil
    ) {
        self.systemVolume = systemVolume.map { min(max($0, 0), 1) }
        self.microphoneVolume = microphoneVolume.map { min(max($0, 0), 1) }
        self.isSystemMuted = isSystemMuted
        self.isMicrophoneMuted = isMicrophoneMuted
    }

    public var inheritsMix: Bool {
        systemVolume == nil
            && microphoneVolume == nil
            && isSystemMuted == nil
            && isMicrophoneMuted == nil
    }

    public var isEmpty: Bool { videoAudio == nil && inheritsMix }
}

/// The single persisted owner of every time-varying project edit.
public struct ProjectTimeline: Codable, Equatable, Sendable {
    public var sourceSequence: SourceSequence
    public var primarySegmentAudioOverrides: [UUID: PrimarySegmentAudioOverrides]
    public var zoomClips: [ZoomAnimationClip]
    public var screenMotionClips: [ScreenMotionClip]
    public var cameraMotionClips: [CameraMotionClip]
    public var mosaicClips: [MosaicClip]
    public var stickerClips: [StickerClip]
    public var animationClips: [AnimationClip]
    public var audioClips: [AudioClip]
    public var videoClips: [VideoClip] {
        didSet { videoJoinStarts = Self.videoJoinStarts(for: videoClips) }
    }
    // Derived visual coverage only. Audio, editable edges and the media clock keep authored time.
    private var videoJoinStarts: [UUID: TimeInterval]

    private static func videoJoinStarts(for clips: [VideoClip]) -> [UUID: TimeInterval] {
        guard clips.count > 1 else { return [:] }
        var starts: [UUID: TimeInterval] = [:]
        let layers = Dictionary(grouping: clips.filter { $0.opacity > 0 && $0.timing.duration > 0 }, by: \.layerIndex)
        for layer in layers.values {
            var coveredUntil = -Double.infinity
            for clip in layer.sorted(by: { $0.timing.startTime < $1.timing.startTime }) {
                let gap = clip.timing.startTime - coveredUntil
                // Audio-sample edits and frame-aligned trims can differ by a fraction
                // of a millisecond. Only bridge such a seam between videos on this lane.
                if gap > 0, gap <= 0.001 { starts[clip.id] = coveredUntil }
                coveredUntil = max(coveredUntil, clip.timing.endTime)
            }
        }
        return starts
    }

    func videoPresentationStart(_ clip: VideoClip) -> TimeInterval {
        videoJoinStarts[clip.id] ?? clip.timing.startTime
    }

    public func presentsVideo(_ clip: VideoClip, at time: TimeInterval) -> Bool {
        clip.opacity > 0 && time >= videoPresentationStart(clip) && time < clip.timing.endTime
    }
    public var subtitleCues: [SubtitleCue]
    public var subtitleStyle: SubtitleStyle
    /// Project media bin (EDT-054); files are referenced, not copied.
    public var mediaAssets: [MediaAsset]

    public init(
        sourceSequence: SourceSequence = .fullRecording,
        primarySegmentAudioOverrides: [UUID: PrimarySegmentAudioOverrides] = [:],
        zoomClips: [ZoomAnimationClip] = [],
        screenMotionClips: [ScreenMotionClip] = [],
        cameraMotionClips: [CameraMotionClip] = [],
        mosaicClips: [MosaicClip] = [],
        stickerClips: [StickerClip] = [],
        animationClips: [AnimationClip] = [],
        audioClips: [AudioClip] = [],
        videoClips: [VideoClip] = [],
        subtitleCues: [SubtitleCue] = [],
        subtitleStyle: SubtitleStyle = SubtitleStyle(),
        mediaAssets: [MediaAsset] = []
    ) {
        self.sourceSequence = sourceSequence
        self.primarySegmentAudioOverrides = primarySegmentAudioOverrides
        self.zoomClips = zoomClips
        self.screenMotionClips = screenMotionClips
        self.cameraMotionClips = cameraMotionClips
        self.mosaicClips = mosaicClips
        self.stickerClips = stickerClips
        self.animationClips = animationClips
        self.audioClips = audioClips
        self.videoClips = videoClips
        videoJoinStarts = Self.videoJoinStarts(for: videoClips)
        self.subtitleCues = subtitleCues
        self.subtitleStyle = subtitleStyle
        self.mediaAssets = mediaAssets
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSequence
        case primarySegmentAudioOverrides
        case zoomClips
        case screenMotionClips
        case cameraMotionClips
        case mosaicClips
        case stickerClips
        case animationClips
        case audioClips
        case videoClips
        case subtitleCues
        case subtitleStyle
        case mediaAssets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSequence = try container.decodeIfPresent(
            SourceSequence.self,
            forKey: .sourceSequence
        ) ?? .fullRecording
        primarySegmentAudioOverrides = try container.decodeIfPresent(
            [UUID: PrimarySegmentAudioOverrides].self,
            forKey: .primarySegmentAudioOverrides
        ) ?? [:]
        zoomClips = try container.decodeIfPresent(
            [ZoomAnimationClip].self,
            forKey: .zoomClips
        ) ?? []
        screenMotionClips = try container.decodeIfPresent(
            [ScreenMotionClip].self,
            forKey: .screenMotionClips
        ) ?? []
        cameraMotionClips = try container.decodeIfPresent(
            [CameraMotionClip].self,
            forKey: .cameraMotionClips
        ) ?? []
        mosaicClips = try container.decodeIfPresent(
            [MosaicClip].self,
            forKey: .mosaicClips
        ) ?? []
        stickerClips = try container.decodeIfPresent(
            [StickerClip].self,
            forKey: .stickerClips
        ) ?? []
        animationClips = try container.decodeIfPresent(
            [AnimationClip].self,
            forKey: .animationClips
        ) ?? []
        audioClips = try container.decodeIfPresent([AudioClip].self, forKey: .audioClips) ?? []
        videoClips = try container.decodeIfPresent([VideoClip].self, forKey: .videoClips) ?? []
        videoJoinStarts = Self.videoJoinStarts(for: videoClips)
        subtitleCues = try container.decodeIfPresent([SubtitleCue].self, forKey: .subtitleCues) ?? []
        subtitleStyle = try container.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? SubtitleStyle()
        mediaAssets = try container.decodeIfPresent([MediaAsset].self, forKey: .mediaAssets) ?? []
    }
}

public extension ProjectTimeline {
    /// Whether an inserted video plays at this output time (EDT-054).
    func containsInsertedMedia(atOutputTime time: TimeInterval) -> Bool {
        insertedMedia(atOutputTime: time) != nil
    }

    /// The inserted video playing at this output time, if any.
    func insertedMedia(atOutputTime time: TimeInterval) -> InsertedMedia? {
        insertedPlayback(atOutputTime: time)?.media
    }

    /// The inserted clip at this output time and the time inside its file.
    func insertedPlayback(atOutputTime time: TimeInterval) -> (media: InsertedMedia, localTime: TimeInterval, playbackRate: Double)? {
        recordingSegmentBoundary(atOutputTime: time).insertedPlayback(at: time)
    }

    /// Sound-effect audio clips placed on the audio lanes that overlap a
    /// main-track segment (for example, an AI-generated `sound.create` effect
    /// paired with a `html.create(placement: "main")` title card).
    func associatedEffectAudioClips(overlappingStart start: TimeInterval, end: TimeInterval) -> [AudioClip] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        let maxShortDuration = max((end - start) * 3, 15)
        return audioClips.filter { clip in
            let overlap = min(clip.timing.endTime, end) - max(clip.timing.startTime, start)
            guard clip.videoOrigin == nil, overlap > 0.02 else { return false }
            return clip.kind == .effect || clip.timing.duration <= maxShortDuration
        }
    }
}

public extension ProjectTimeline {
    mutating func resetSegmentAudioMix(_ id: UUID) {
        var inherited = PrimarySegmentAudioOverrides()
        inherited.videoAudio = primarySegmentAudioOverrides[id]?.videoAudio
        primarySegmentAudioOverrides[id] = inherited.isEmpty ? nil : inherited
    }
}
