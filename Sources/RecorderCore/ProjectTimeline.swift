import Foundation

/// One retained portion of the original recording.
///
/// Segment order is output order. The lightweight editor deliberately does not
/// persist a second `outputStart`: it is derived by accumulating durations, so
/// a trim or ripple delete cannot leave two contradictory timeline positions.
public struct RecordingSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceStart: TimeInterval
    public var sourceDuration: TimeInterval
    /// Source seconds consumed by one output second. The editor currently
    /// exposes 1x...8x fast-forward while the storage contract remains ready
    /// for any positive rate supported by a future UI.
    public var playbackRate: Double

    public init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval,
        playbackRate: Double = 1
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.playbackRate = playbackRate.isFinite && playbackRate > 0
            ? playbackRate : 1
    }

    public var sourceEnd: TimeInterval {
        sourceStart + sourceDuration
    }

    public var outputDuration: TimeInterval {
        sourceDuration / playbackRate
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceStart, sourceDuration, playbackRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            sourceStart: try container.decode(TimeInterval.self, forKey: .sourceStart),
            sourceDuration: try container.decode(TimeInterval.self, forKey: .sourceDuration),
            playbackRate: try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
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
    /// 剪切跨过进入过渡起点时，保留删除区间末端已经走完的相位。
    /// 0 = 从头开始，1 = 进入过渡已经完成。
    public var leadInProgressOffset: Double
    public var easing: ZoomEasingPreset
    public var customCurve: ZoomBezierCurve
    /// 结尾自动回到基础状态的过渡时长；0 = 保持目标状态（旧项目语义）。
    public var returnDuration: TimeInterval
    /// 剪切跨过回落起点时保留的回落相位；0 = 从目标开始回落，1 = 已回到基础状态。
    public var returnProgressOffset: Double

    public init(
        startTime: TimeInterval,
        duration: TimeInterval = 0.7,
        leadInDuration: TimeInterval? = nil,
        easing: ZoomEasingPreset = .cubic,
        customCurve: ZoomBezierCurve = .cubic,
        returnDuration: TimeInterval = 0,
        leadInProgressOffset: Double = 0,
        returnProgressOffset: Double = 0
    ) {
        self.startTime = startTime
        self.duration = duration
        self.leadInDuration = min(max(leadInDuration ?? duration, 0), 5)
        self.leadInProgressOffset = min(max(leadInProgressOffset, 0), 1)
        self.easing = easing
        self.customCurve = customCurve
        self.returnDuration = min(max(returnDuration, 0), 5)
        self.returnProgressOffset = min(max(returnProgressOffset, 0), 1)
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
        returnProgressOffset = min(
            max(try container.decodeIfPresent(Double.self, forKey: .returnProgressOffset) ?? 0, 0),
            1
        )
    }
}

/// The single persisted owner of every time-varying project edit.
public struct ProjectTimeline: Codable, Equatable, Sendable {
    public var sourceSequence: SourceSequence
    public var zoomClips: [ZoomAnimationClip]
    public var screenMotionClips: [ScreenMotionClip]
    public var cameraMotionClips: [CameraMotionClip]
    public var mosaicClips: [MosaicClip]
    public var stickerClips: [StickerClip]
    public var progressOverlay: ProgressOverlay?

    public init(
        sourceSequence: SourceSequence = .fullRecording,
        zoomClips: [ZoomAnimationClip] = [],
        screenMotionClips: [ScreenMotionClip] = [],
        cameraMotionClips: [CameraMotionClip] = [],
        mosaicClips: [MosaicClip] = [],
        stickerClips: [StickerClip] = [],
        progressOverlay: ProgressOverlay? = nil
    ) {
        self.sourceSequence = sourceSequence
        self.zoomClips = zoomClips
        self.screenMotionClips = screenMotionClips
        self.cameraMotionClips = cameraMotionClips
        self.mosaicClips = mosaicClips
        self.stickerClips = stickerClips
        self.progressOverlay = progressOverlay
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSequence
        case zoomClips
        case screenMotionClips
        case cameraMotionClips
        case mosaicClips
        case stickerClips
        case progressOverlay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSequence = try container.decodeIfPresent(
            SourceSequence.self,
            forKey: .sourceSequence
        ) ?? .fullRecording
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
        progressOverlay = try container.decodeIfPresent(
            ProgressOverlay.self,
            forKey: .progressOverlay
        )
    }
}
