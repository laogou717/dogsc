import Foundation

/// Anything placed on the output timeline for a span of time.
public protocol TimedOverlayClip {
    var id: UUID { get }
    var timing: OverlayTiming { get set }
}

extension AnimationClip: TimedOverlayClip {}

public enum MediaAssetKind: String, Codable, CaseIterable, Sendable {
    case video
    case image
    case audio
    case animation

    public static func kind(forExtension ext: String) -> MediaAssetKind? {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v": .video
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": .image
        case "mp3", "m4a", "wav", "aiff", "aif", "aac", "caf", "flac": .audio
        case "dmhtml", "html": .animation
        default: nil
        }
    }
}

/// A file the user brought into this project. Referenced where it lives;
/// never copied (EDT-054). Missing files are relinked by replacing `path`.
public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var kind: MediaAssetKind
    public var name: String
    public var importedAt: Date

    public init(id: UUID = UUID(), path: String, kind: MediaAssetKind, name: String? = nil, importedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.kind = kind
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.importedAt = importedAt
    }

    /// The label shown in the media library. The extension is dropped: a tile
    /// is narrow, the kind is already shown as its own badge, and leaving it in
    /// spends the only visible characters on ".dmhtml" for every motion.
    public var displayName: String {
        let trimmed = (name as NSString).deletingPathExtension
        return trimmed.isEmpty ? name : trimmed
    }
}

public enum VideoMaskShape: String, Codable, CaseIterable, Sendable {
    case rectangle = "矩形"
    case rounded = "圆角矩形"
    case circle = "圆形"
}

public enum VideoCameraMode: String, Codable, CaseIterable, Sendable {
    case videoInFront, pictureInPicture
    // Decoded from projects authored before explicit stacking order.
    case original, hidden, automatic
}

public enum VideoSourceError: LocalizedError {
    case insufficientTimeline
    case invalidRange(name: String)
    case unreadable(name: String)

    public var errorDescription: String? {
        switch self {
        case .insufficientTimeline: return "成片剩余时长不足以容纳这个速度下的完整片段。"
        case let .invalidRange(name): return "视频「\(name)」的取材范围超出了可播放画面。"
        case let .unreadable(name): return "无法读取视频「\(name)」的画面轨道。"
        }
    }
}

/// A video placed over the recording for a span of time (picture-in-picture
/// or full-frame B-roll), with its own sound.
public struct VideoClip: Codable, Equatable, Identifiable, Sendable, TimedOverlayClip {
    public var cameraMode: VideoCameraMode = .pictureInPicture {
        didSet {
            if cameraMode != oldValue {
                legacyAutoCoverage = cameraMode == .automatic ? .init(minimumCanvasAspect: minimumAspectForAutomaticInset) : nil
            }
        }
    }
    // Legacy Auto used the opening layout to decide whether the video covered
    // the canvas. Freeze its coverage threshold on load so moving or cropping
    // an old video cannot silently reverse the order shown in the inspector.
    private struct LegacyAutoCoverage: Codable, Equatable, Sendable {
        let minimumCanvasAspect: Double?
    }
    private var legacyAutoCoverage: LegacyAutoCoverage?
    // Round-trip old documents without using video-local camera appearance.
    private var cameraInsetMirrored: Bool?
    private var cameraInsetShape: CameraShape?
    private var cameraInsetPosition: NormalizedPoint?
    private var cameraInsetSize: Double?
    public static let maskRadiusRange = 0.0...0.5
    public static let defaultMaskRadius = 0.12
    /// Radius as a fraction of the mask's shorter edge. Retained while another shape is selected.
    public var maskCornerRadius: Double = Self.defaultMaskRadius
    public var maskShape: VideoMaskShape = .rectangle
    public var contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
    public var contentScale: Double = 1
    public static let sourceTimeTolerance: TimeInterval = 1.0 / 120_000
    /// Playable source seconds measured from the video track start. Older documents
    /// acquire this metadata when their media is opened.
    public var sourceFileEnd: TimeInterval?
    public var playbackRate: Double = 1
    public var sourceDuration: TimeInterval { timing.duration * playbackRate }
    public var sourceEnd: TimeInterval { sourceStart + sourceDuration }

    public func validateSourceRange() throws {
        guard timing.duration.isFinite, timing.duration > 0,
              timing.startTime.isFinite, timing.startTime >= 0,
              sourceStart.isFinite, sourceStart >= 0, playbackRate.isFinite,
              playbackRate > 0, sourceEnd.isFinite, sourceEnd > sourceStart,
              !sourcePath.isEmpty else {
            throw VideoSourceError.invalidRange(name: URL(fileURLWithPath: sourcePath).lastPathComponent)
        }
        if let end = sourceFileEnd, !(end.isFinite && sourceStart < end && sourceEnd <= end + Self.sourceTimeTolerance) {
            throw VideoSourceError.invalidRange(name: URL(fileURLWithPath: sourcePath).lastPathComponent)
        }
    }

    /// A speed change keeps the selected source frames. Only their output duration changes.
    public mutating func setPlaybackRate(_ rate: Double) throws {
        var updated = self
        updated.timing.duration = sourceDuration / rate
        updated.playbackRate = rate
        try updated.validateSourceRange()
        self = updated
    }
    public var mainTrackStyle: MainTrackVisualStyle? = nil
    public var videoAudio: VideoAudioAttachment?
    public var id: UUID
    public var timing: OverlayTiming
    public var sourcePath: String
    public var sourceStart: TimeInterval
    /// Centre, 0-1 from the canvas top-left.
    public var position: NormalizedPoint
    /// Width relative to the canvas; height follows `aspect` (h / w).
    public var width: Double
    public var aspect: Double
    public var opacity: Double
    public var volume: Double
    public var layerIndex: Int

    public init(
        id: UUID = UUID(),
        timing: OverlayTiming,
        sourcePath: String,
        sourceStart: TimeInterval = 0,
        position: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        width: Double = 1,
        aspect: Double = 9.0 / 16.0,
        opacity: Double = 1,
        volume: Double = 1,
        layerIndex: Int = 0
    ) {
        self.id = id
        self.timing = timing
        self.sourcePath = sourcePath
        self.sourceStart = sourceStart
        self.position = position
        self.width = width
        self.aspect = aspect
        self.opacity = opacity
        self.volume = volume
        self.layerIndex = layerIndex
    }

    private enum CodingKeys: String, CodingKey {
        case cameraMode, legacyAutoCoverage, cameraInsetMirrored, cameraInsetShape, cameraInsetPosition, cameraInsetSize
        case maskShape, maskCornerRadius, contentPosition, contentScale
        case id, timing, sourcePath, sourceStart, position, width, aspect, opacity, volume, layerIndex, playbackRate, mainTrackStyle, videoAudio, sourceFileEnd
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), timing: try c.decode(OverlayTiming.self, forKey: .timing),
            sourcePath: try c.decode(String.self, forKey: .sourcePath), sourceStart: try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0,
            position: try c.decode(NormalizedPoint.self, forKey: .position), width: try c.decode(Double.self, forKey: .width),
            aspect: try c.decode(Double.self, forKey: .aspect), opacity: try c.decode(Double.self, forKey: .opacity),
            volume: try c.decode(Double.self, forKey: .volume), layerIndex: try c.decode(Int.self, forKey: .layerIndex))
        maskShape = try c.decodeIfPresent(VideoMaskShape.self, forKey: .maskShape) ?? .rectangle
        maskCornerRadius = try c.decodeIfPresent(Double.self, forKey: .maskCornerRadius) ?? Self.defaultMaskRadius
        guard Self.maskRadiusRange.contains(maskCornerRadius) else {
            throw DecodingError.dataCorruptedError(forKey: .maskCornerRadius, in: c, debugDescription: "maskCornerRadius must be in 0...0.5.")
        }
        cameraMode = try c.decodeIfPresent(VideoCameraMode.self, forKey: .cameraMode) ?? .original
        if cameraMode == .automatic {
            legacyAutoCoverage = try c.decodeIfPresent(LegacyAutoCoverage.self, forKey: .legacyAutoCoverage)
                ?? .init(minimumCanvasAspect: minimumAspectForAutomaticInset)
        }
        cameraInsetMirrored = try c.decodeIfPresent(Bool.self, forKey: .cameraInsetMirrored)
        cameraInsetShape = try c.decodeIfPresent(CameraShape.self, forKey: .cameraInsetShape)
        cameraInsetPosition = try c.decodeIfPresent(NormalizedPoint.self, forKey: .cameraInsetPosition)
        cameraInsetSize = try c.decodeIfPresent(Double.self, forKey: .cameraInsetSize)
        contentPosition = try c.decodeIfPresent(NormalizedPoint.self, forKey: .contentPosition) ?? NormalizedPoint(x: 0.5, y: 0.5)
        contentScale = try c.decodeIfPresent(Double.self, forKey: .contentScale) ?? 1
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        sourceFileEnd = try c.decodeIfPresent(Double.self, forKey: .sourceFileEnd)
        videoAudio = try c.decodeIfPresent(VideoAudioAttachment.self, forKey: .videoAudio)
        mainTrackStyle = try c.decodeIfPresent(MainTrackVisualStyle.self, forKey: .mainTrackStyle)
    }

    static func layerOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.layerIndex == rhs.layerIndex ? lhs.id.uuidString < rhs.id.uuidString : lhs.layerIndex < rhs.layerIndex
    }

    public mutating func fillCanvas(canvasAspect: Double) {
        position = .init(x: 0.5, y: 0.5)
        width = max(1, 1 / max(aspect * canvasAspect, 0.0001))
        maskShape = .rectangle
    }

    public var maskAspect: Double { maskShape == .circle ? 1 : aspect }
    public var framingAxes: (horizontal: Bool, vertical: Bool) {
        guard let fill = CameraContentFill.layout(sourceWidth: 1, sourceHeight: aspect,
            target: .init(x: 0, y: 0, width: 1, height: maskAspect), contentScale: contentScale, overscan: 1)
        else { return (false, false) }
        return (fill.visibleSource.width < 1 - 0.000001, fill.visibleSource.height < aspect * (1 - 0.000001))
    }

    private var minimumAspectForAutomaticInset: Double? {
        // Fitted video edges can be a fraction of a pixel shy of the canvas.
        let tolerance = 0.002
        guard maskShape == .rectangle, opacity >= 0.999, width > 0, aspect > 0,
              width + tolerance >= 1 + 2 * abs(position.x - 0.5) else { return nil }
        return (1 + 2 * abs(position.y - 0.5) - tolerance) / (width * aspect)
    }

    func requestsCameraInset(cameraOnlyFullscreen: Bool, canvasAspect: Double) -> Bool {
        switch cameraMode {
        case .videoInFront, .original, .hidden: return false
        case .pictureInPicture: return true
        case .automatic:
            guard cameraOnlyFullscreen, let minimum = legacyAutoCoverage?.minimumCanvasAspect else { return false }
            return canvasAspect >= minimum
        }
    }
}

public extension ProjectTimeline {
    /// The focus map follows the visible overlay under the playhead. When inspecting a zoom
    /// from outside its range, use the first covered frame in that range.
    func focusMapVideo(for zoom: ZoomAnimationClip, at time: TimeInterval) -> VideoClip? {
        let candidates = videoClips.filter {
            $0.opacity > 0 && $0.timing.endTime > zoom.startTime && videoPresentationStart($0) < zoom.effectEndTime
        }
        let first = candidates.map { max(zoom.startTime, videoPresentationStart($0)) }.min()
        guard let first else { return nil }
        let sample = (zoom.startTime..<zoom.effectEndTime).contains(time) ? time : first
        return candidates.filter { presentsVideo($0, at: sample) }.max(by: VideoClip.layerOrder)
    }

    /// Pictures, motion graphics and overlay videos share one stacking order;
    /// a newly added item goes on a new layer above everything.
    var nextVisualLayer: Int {
        (stickerClips.map(\.layerIndex) + animationClips.map(\.layerIndex) + videoClips.map(\.layerIndex))
            .max().map { $0 + 1 } ?? 0
    }

    /// The track a new picture/motion/video clip should go on: the lowest
    /// layer that is free for its whole span and in front of everything it
    /// overlaps. A new track opens only when it overlaps the top one.
    func visualLayer(for timing: OverlayTiming, excluding id: UUID? = nil) -> Int {
        let spans = stickerClips.filter { $0.id != id }.map { ($0.layerIndex, $0.timing) }
            + animationClips.filter { $0.id != id }.map { ($0.layerIndex, $0.timing) }
            + videoClips.filter { $0.id != id }.map { ($0.layerIndex, $0.timing) }
        guard let lowest = spans.map(\.0).min() else { return 0 }
        let overlapping = spans.filter {
            $0.1.startTime < timing.endTime - 0.000_001 && $0.1.endTime > timing.startTime + 0.000_001
        }.map(\.0)
        return overlapping.max().map { $0 + 1 } ?? lowest
    }

    /// Renumbers visual layers to 0…n, keeping their order.
    mutating func compactVisualLayers() {
        let order = Set(stickerClips.map(\.layerIndex) + animationClips.map(\.layerIndex) + videoClips.map(\.layerIndex)).sorted()
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for i in stickerClips.indices { stickerClips[i].layerIndex = rank[stickerClips[i].layerIndex] ?? 0 }
        for i in animationClips.indices { animationClips[i].layerIndex = rank[animationClips[i].layerIndex] ?? 0 }
        for i in videoClips.indices { videoClips[i].layerIndex = rank[videoClips[i].layerIndex] ?? 0 }
    }

    /// Reuse visual gaps while preserving front/back order wherever clips
    /// overlap. Audio lanes are independent of this operation.
    mutating func organizeVisualLayers() {
        enum Ref { case sticker(Int), animation(Int), video(Int) }
        var visual: [(layer: Int, rank: Int, id: String, start: TimeInterval, end: TimeInterval, ref: Ref)] =
            stickerClips.indices.map { (stickerClips[$0].layerIndex, 1, stickerClips[$0].id.uuidString, stickerClips[$0].timing.startTime, stickerClips[$0].timing.endTime, .sticker($0)) }
            + animationClips.indices.map { (animationClips[$0].layerIndex, 2, animationClips[$0].id.uuidString, animationClips[$0].timing.startTime, animationClips[$0].timing.endTime, .animation($0)) }
            + videoClips.indices.map { (videoClips[$0].layerIndex, 0, videoClips[$0].id.uuidString, videoClips[$0].timing.startTime, videoClips[$0].timing.endTime, .video($0)) }
        // Match the shared renderer even when overlapping clips originally
        // share a layer: video, picture, motion, then stable ID within kind.
        visual.sort {
            if $0.layer != $1.layer { return $0.layer < $1.layer }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.id < $1.id
        }
        var placed: [(start: TimeInterval, end: TimeInterval, layer: Int)] = []
        for item in visual {
            let below = placed.filter { $0.start < item.end - 0.000_001 && $0.end > item.start + 0.000_001 }.map(\.layer).max()
            let layer = below.map { $0 + 1 } ?? 0
            placed.append((item.start, item.end, layer))
            switch item.ref {
            case let .sticker(i): stickerClips[i].layerIndex = layer
            case let .animation(i): animationClips[i].layerIndex = layer
            case let .video(i): videoClips[i].layerIndex = layer
            }
        }
    }

    /// 整理轨道: visual clips reuse gaps without changing their stacking
    /// order; audio packs into free rows (music before effects).
    mutating func organizeTracks() {
        organizeVisualLayers()
        var rows: [[(TimeInterval, TimeInterval)]] = []
        func pack(_ indices: [Int], from first: Int) -> Int {
            var used = first
            for i in indices.sorted(by: { audioClips[$0].timing.startTime < audioClips[$1].timing.startTime }) {
                let timing = audioClips[i].timing
                var lane = first
                while lane < rows.count, rows[lane].contains(where: { $0.0 < timing.endTime - 0.000_001 && $0.1 > timing.startTime + 0.000_001 }) {
                    lane += 1
                }
                while rows.count <= lane { rows.append([]) }
                rows[lane].append((timing.startTime, timing.endTime))
                audioClips[i].lane = lane
                used = max(used, lane + 1)
            }
            return used
        }
        let music = audioClips.indices.filter { audioClips[$0].kind == .music }
        let effects = audioClips.indices.filter { audioClips[$0].kind != .music }
        let next = pack(music, from: 0)
        _ = pack(effects, from: music.isEmpty ? 0 : next)
    }

    /// Common program-audio inputs. Includes overlay videos even at
    /// 0% volume and muted audio clips. Preview and export render the same
    /// stable track structure into their shared program audio.
    var programAudioClips: [AudioClip] {
        programAudioClips(audio: .init())
    }

    func programAudioClips(audio: AudioStyle) -> [AudioClip] {
        audioClips + linkedPrimaryAudioClips(audio: audio) + videoClips.flatMap { video -> [AudioClip] in
            if let attachment = video.videoAudio {
                return attachment.clips(for: video.id, timing: video.timing, sourceStart: video.sourceStart,
                                        rate: video.playbackRate, gain: { _ in video.volume })
            }
            return [AudioClip(id: video.id, timing: video.timing, sourcePath: video.sourcePath, sourceStart: video.sourceStart,
                      volume: video.volume, fadeIn: 0, fadeOut: 0, kind: .effect, playbackRate: video.playbackRate)]
        } + animationClips.compactMap { clip in
            guard let sound = clip.soundtrack else { return nil }
            return AudioClip(id: clip.id, timing: clip.timing, sourcePath: sound.path, sourceStart: clip.timeOffset,
                volume: sound.volume, fadeIn: sound.fadeIn, fadeOut: sound.fadeOut, kind: .effect, playbackRate: clip.playbackRate)
        }
    }
}

public enum AudioClipKind: String, Codable, Sendable {
    case music
    case effect
}

/// Background music or a sound effect mixed under the recording.
public struct AudioClip: Codable, Equatable, Identifiable, Sendable, TimedOverlayClip {
    public var playbackRate: Double = 1
    public var id: UUID
    public var timing: OverlayTiming
    public var sourcePath: String
    /// Offset into the source file where playback starts.
    public var sourceStart: TimeInterval
    public var volume: Double
    public var isMuted: Bool = false
    public var fadeIn: TimeInterval
    public var fadeOut: TimeInterval
    public var kind: AudioClipKind
    /// Lower this clip while someone is speaking (subtitle cues mark speech).
    public var ducksUnderSpeech: Bool
    /// Audio row on the timeline (0 = first row under the recording).
    public var lane: Int
    public var videoOrigin: VideoAudioOrigin?

    private enum CodingKeys: String, CodingKey {
        case id, timing, sourcePath, sourceStart, volume, isMuted, fadeIn, fadeOut, kind, ducksUnderSpeech, lane, playbackRate, videoOrigin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timing = try c.decode(OverlayTiming.self, forKey: .timing)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        sourceStart = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceStart) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.6
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        fadeIn = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
        kind = try c.decodeIfPresent(AudioClipKind.self, forKey: .kind) ?? .music
        ducksUnderSpeech = try c.decodeIfPresent(Bool.self, forKey: .ducksUnderSpeech) ?? (kind == .music)
        videoOrigin = try c.decodeIfPresent(VideoAudioOrigin.self, forKey: .videoOrigin)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? (kind == .music ? 0 : 1)
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
    }

    public init(
        id: UUID = UUID(),
        timing: OverlayTiming,
        sourcePath: String,
        sourceStart: TimeInterval = 0,
        volume: Double = 0.6,
        isMuted: Bool = false,
        fadeIn: TimeInterval = 0.5,
        fadeOut: TimeInterval = 1,
        kind: AudioClipKind = .music,
        playbackRate: Double = 1
    ) {
        self.id = id
        self.timing = timing
        self.sourcePath = sourcePath
        self.sourceStart = sourceStart
        self.volume = volume
        self.isMuted = isMuted
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.kind = kind
        self.playbackRate = playbackRate
        self.ducksUnderSpeech = kind == .music
        self.lane = kind == .music ? 0 : 1
    }

    /// Whether two clips build identical `AVMutableCompositionTrack` time ranges.
    /// Gain, mute, fades and ducking only affect `AVAudioMix`.
    public func matchesCompositionStructure(of other: AudioClip) -> Bool {
        id == other.id
            && timing == other.timing
            && sourcePath == other.sourcePath
            && abs(sourceStart - other.sourceStart) <= 0.000_001
            && abs(playbackRate - other.playbackRate) <= 0.000_001
    }
}

/// One subtitle line, optionally with a second language beneath it.
public struct SubtitleCue: Codable, Equatable, Identifiable, Sendable, TimedOverlayClip {
    public var id: UUID
    public var timing: OverlayTiming
    public var text: String
    public var secondaryText: String?

    public init(id: UUID = UUID(), timing: OverlayTiming, text: String, secondaryText: String? = nil) {
        self.id = id
        self.timing = timing
        self.text = text
        self.secondaryText = secondaryText
    }
}

public enum SubtitleFont: String, Codable, CaseIterable, Sendable {
    case system, rounded, serif, mono
}

public enum SubtitleEntrance: String, Codable, CaseIterable, Sendable {
    case none, fade, rise, pop, typewriter
}

public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// Font size relative to canvas height.
    public var fontScale: Double
    /// Baseline distance from the bottom, relative to canvas height.
    public var bottomMargin: Double
    public var textColor: HexColor
    public var backgroundOpacity: Double
    public var showsSecondary: Bool
    public var font: SubtitleFont
    /// A specific installed font family; nil uses `font`'s system design.
    public var fontFamily: String?
    public var bold: Bool
    public var entrance: SubtitleEntrance

    public init(
        fontScale: Double = 0.03,
        bottomMargin: Double = 0.05,
        textColor: HexColor = .white,
        backgroundOpacity: Double = 1,
        showsSecondary: Bool = true,
        font: SubtitleFont = .system,
        bold: Bool = true,
        entrance: SubtitleEntrance = .none
    ) {
        self.fontScale = fontScale
        self.bottomMargin = bottomMargin
        self.textColor = textColor
        self.backgroundOpacity = backgroundOpacity
        self.showsSecondary = showsSecondary
        self.font = font
        self.fontFamily = nil
        self.bold = bold
        self.entrance = entrance
    }

    /// Used only before a project's first captions, never to restyle existing
    /// subtitles or overwrite a user's custom appearance.
    public static let legacyDefault = SubtitleStyle(fontScale: 0.045, bottomMargin: 0.08,
        backgroundOpacity: 0.55, entrance: .fade)

    private enum CodingKeys: String, CodingKey {
        case fontScale, bottomMargin, textColor, backgroundOpacity, showsSecondary, font, fontFamily, bold, entrance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleStyle()
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? d.fontScale
        bottomMargin = try c.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? d.bottomMargin
        textColor = try c.decodeIfPresent(HexColor.self, forKey: .textColor) ?? d.textColor
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? d.backgroundOpacity
        showsSecondary = try c.decodeIfPresent(Bool.self, forKey: .showsSecondary) ?? d.showsSecondary
        font = try c.decodeIfPresent(SubtitleFont.self, forKey: .font) ?? d.font
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? d.bold
        entrance = try c.decodeIfPresent(SubtitleEntrance.self, forKey: .entrance) ?? d.entrance
    }
}

/// Subtitle display text cleanup. Numeric and name notation is preserved.
public enum SubtitleText {
    /// Longest line, in Chinese-character widths (Latin letters count half).
    public static let maxUnits: Double = 16
    /// Only sounds that never begin a real word (so not 额度、呐喊).
    static let fillers = "啊|呃|嗯|哦|噢|唉|诶|欸"

    public static func units(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 0.5 : 1) }
    }

    /// Explicit subtitle cleanup also removes filler sounds.
    public static func clean(_ text: String) -> String {
        format(text, removesFillers: true)
    }

    /// Speech captions retain recognizer wording, including fillers. Only
    /// presentation punctuation and recognized profanity are filtered here.
    public static func speechDisplay(_ text: String) -> String {
        format(censoredSpeechTokens([text])[0], removesFillers: false)
    }

    private static func format(_ text: String, removesFillers: Bool) -> String {
        var result = text
        var rules: [(String, String)] = [
            ("(?<![0-9])[，,]|[，,](?![0-9])", " "),
            ("[。！？!?；;：:…\\.]+(?=\\s*$)", " "),
        ]
        if removesFillers {
            rules += [("(^|\\s)(\(fillers))+(?=\\s|$)", "$1"), ("^(\(fillers))+", ""), ("(\(fillers))+$", "")]
        }
        rules.append(("\\s+", " "))
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let profanity = try? NSRegularExpression(
        pattern: #"([他她它]\s*妈\s*的|特\s*么\s*的|(?<![a-z0-9])tmd(?![a-z0-9]))|(?:操\s*你\s*妈|傻\s*逼|狗\s*屎|屎(?!\s*壳\s*郎)|我\s*操(?=\s*(?:[，,。！？!?；;]|$))|(?<![a-z0-9])(?:motherfuck(?:er|ing)|fuck(?:s|ed|ing)?|bullshit|shit(?:ty)?|asshole|bitch)(?![a-z0-9]))"#,
        options: .caseInsensitive
    )

    /// Match across recognizer tokens before grouping captions. A cue may
    /// split a profane phrase, so retain one output element per original token.
    public static func censoredSpeechTokens(_ tokens: [String]) -> [String] {
        guard let profanity, !tokens.isEmpty else { return tokens }
        var offsets = [0]
        for token in tokens { offsets.append(offsets[offsets.count - 1] + token.utf16.count) }
        let joined = tokens.joined()
        let matches = profanity.matches(in: joined, range: NSRange(location: 0, length: joined.utf16.count))
        var output = tokens
        var tokenIndex = tokens.count - 1
        // Right-to-left replacements leave the original offsets of earlier
        // matches valid, even when several of them are in the same token.
        for match in matches.reversed() {
            let start = match.range.location, end = NSMaxRange(match.range)
            while offsets[tokenIndex] >= end { tokenIndex -= 1 }
            while offsets[tokenIndex + 1] > start {
                let lower = max(start, offsets[tokenIndex]), upper = min(end, offsets[tokenIndex + 1])
                if lower < upper {
                    let range = NSRange(location: lower - offsets[tokenIndex], length: upper - lower)
                    let replacement = lower == start ? (match.range(at: 1).location == NSNotFound ? " " : "TM") : ""
                    output[tokenIndex] = (output[tokenIndex] as NSString).replacingCharacters(in: range, with: replacement)
                }
                if offsets[tokenIndex] <= start { break }
                tokenIndex -= 1
            }
        }
        return output
    }

    /// Retain notation present in the recognized audio text when generating
    /// corrected/translated display text. Timing never depends on this text.
    public static func preservingNumericNotation(_ text: String, from reference: String) -> String {
        guard let numbers = try? NSRegularExpression(pattern: #"(?<![0-9])[0-9]+(?:\.[0-9]+)+(?![0-9])"#) else { return text }
        let ns = reference as NSString
        var result = text
        for match in numbers.matches(in: reference, range: NSRange(location: 0, length: ns.length)) {
            let number = ns.substring(with: match.range)
            let pieces = number.split(separator: ".").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![0-9])"# + pieces.joined(separator: #"\s*(?:\.|点|point)\s*"#) + #"(?![0-9])"#
            result = result.replacingOccurrences(of: pattern, with: number, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// Cleans display text while preserving cue identity and timing. New
    /// subtitle segments are authored from speech token boundaries instead.
    public static func normalized(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.compactMap { original in
            var cue = original
            cue.text = clean(cue.text)
            cue.secondaryText = cue.secondaryText.map(clean).flatMap { $0.isEmpty ? nil : $0 }
            return cue.text.isEmpty ? nil : cue
        }
    }

}

public enum SubtitleSRT {
    public static func encode(_ cues: [SubtitleCue], secondary: Bool = false) -> String {
        cues.sorted { $0.timing.startTime < $1.timing.startTime }.enumerated().compactMap { index, cue in
            let text = secondary ? (cue.secondaryText ?? "") : cue.text
            guard !text.isEmpty else { return nil }
            return "\(index + 1)\n\(stamp(cue.timing.startTime)) --> \(stamp(cue.timing.endTime))\n\(text)\n"
        }.joined(separator: "\n")
    }

    public static func decode(_ srt: String) -> [SubtitleCue] {
        srt.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap { block in
                let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
                let parts = lines[arrow].components(separatedBy: "-->")
                guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1]), end > start else { return nil }
                let text = lines[(arrow + 1)...].joined(separator: "\n")
                guard !text.isEmpty else { return nil }
                return SubtitleCue(timing: OverlayTiming(startTime: start, duration: end - start), text: text)
            }
    }

    static func stamp(_ t: TimeInterval) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func seconds(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
