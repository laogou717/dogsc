import Foundation

/// A normalized, top-left-origin rectangle authored directly on the preview.
public struct NormalizedOverlayRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let centered = NormalizedOverlayRect(
        x: 0.35,
        y: 0.39,
        width: 0.30,
        height: 0.22
    )

    public func clamped() -> Self {
        let safeWidth = min(max(width.isFinite ? width : 0.30, 0.01), 1)
        let safeHeight = min(max(height.isFinite ? height : 0.22, 0.01), 1)
        return Self(
            x: min(max(x.isFinite ? x : 0.35, 0), 1 - safeWidth),
            y: min(max(y.isFinite ? y : 0.39, 0), 1 - safeHeight),
            width: safeWidth,
            height: safeHeight
        )
    }
}

public struct OverlayTiming: Codable, Equatable, Sendable {
    public var startTime: TimeInterval
    public var duration: TimeInterval

    public init(startTime: TimeInterval, duration: TimeInterval = 3) {
        self.startTime = startTime
        self.duration = duration
    }

    public var endTime: TimeInterval { startTime + duration }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

public enum MosaicEffectStyle: String, CaseIterable, Sendable {
    case blur
    case spotlight

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Version 9 briefly exposed a pixel-block preset. It is intentionally
        // migrated to ordinary softening instead of keeping a hidden renderer
        // branch and a third product meaning forever.
        self = value == Self.spotlight.rawValue ? .spotlight : .blur
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension MosaicEffectStyle: Codable {}

public enum MosaicTransitionStyle: String, CaseIterable, Codable, Sendable {
    case none
    case linear
    case smooth
}

/// A timed redaction attached to the recorded screen's normalized source area.
public struct MosaicClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timing: OverlayTiming
    public var sourceRect: NormalizedOverlayRect
    /// Normalized against the shorter side of the redaction rectangle.
    public var cornerRadius: Double
    public var style: MosaicEffectStyle
    /// Product-facing 0...1 strength; renderers lower it to pixels.
    public var intensity: Double
    /// Black overlay outside a spotlight focus. Ignored by ordinary blur.
    public var spotlightDimming: Double
    public var transitionStyle: MosaicTransitionStyle
    public var transitionInDuration: TimeInterval
    public var transitionOutDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        timing: OverlayTiming,
        sourceRect: NormalizedOverlayRect = .centered,
        cornerRadius: Double = 0.08,
        style: MosaicEffectStyle = .blur,
        intensity: Double = 0.55,
        spotlightDimming: Double = 0.22,
        transitionStyle: MosaicTransitionStyle = .none,
        transitionInDuration: TimeInterval = 0.30,
        transitionOutDuration: TimeInterval = 0.30
    ) {
        self.id = id
        self.timing = timing
        self.sourceRect = sourceRect
        self.cornerRadius = cornerRadius
        self.style = style
        self.intensity = intensity
        self.spotlightDimming = spotlightDimming
        self.transitionStyle = transitionStyle
        self.transitionInDuration = transitionInDuration
        self.transitionOutDuration = transitionOutDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timing
        case sourceRect
        case cornerRadius
        case style
        case intensity
        case spotlightDimming
        case transitionStyle
        case transitionInDuration
        case transitionOutDuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timing = try container.decode(OverlayTiming.self, forKey: .timing)
        sourceRect = try container.decode(
            NormalizedOverlayRect.self,
            forKey: .sourceRect
        )
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        style = try container.decode(MosaicEffectStyle.self, forKey: .style)
        intensity = try container.decode(Double.self, forKey: .intensity)
        spotlightDimming = try container.decodeIfPresent(
            Double.self,
            forKey: .spotlightDimming
        ) ?? 0.22
        transitionStyle = try container.decodeIfPresent(
            MosaicTransitionStyle.self,
            forKey: .transitionStyle
        ) ?? (style == .spotlight ? .smooth : .none)
        transitionInDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .transitionInDuration
        ) ?? 0.30
        transitionOutDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .transitionOutDuration
        ) ?? 0.30
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timing, forKey: .timing)
        try container.encode(sourceRect, forKey: .sourceRect)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(style, forKey: .style)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(spotlightDimming, forKey: .spotlightDimming)
        try container.encode(transitionStyle, forKey: .transitionStyle)
        try container.encode(transitionInDuration, forKey: .transitionInDuration)
        try container.encode(transitionOutDuration, forKey: .transitionOutDuration)
    }
}

public enum StickerAnimationPreset: String, CaseIterable, Codable, Sendable {
    case none
    case fade
    case pop
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case slideTopLeft
    case slideTopRight
    case slideBottomLeft
    case slideBottomRight

    public var automaticExit: Self {
        switch self {
        case .slideLeft: .slideRight
        case .slideRight: .slideLeft
        case .slideUp: .slideDown
        case .slideDown: .slideUp
        case .slideTopLeft: .slideBottomRight
        case .slideTopRight: .slideBottomLeft
        case .slideBottomLeft: .slideTopRight
        case .slideBottomRight: .slideTopLeft
        case .none, .fade, .pop: self
        }
    }
}

/// A package-owned still image placed above the composed recording.
public struct StickerClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timing: OverlayTiming
    public var relativePath: String
    public var position: NormalizedPoint
    /// Width relative to the output canvas. Height follows the image aspect.
    public var width: Double
    public var rotationDegrees: Double
    public var opacity: Double
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var shadowOpacity: Double
    public var shadowRadius: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var animation: StickerAnimationPreset
    /// `nil` follows the complementary direction of `animation`.
    public var exitAnimation: StickerAnimationPreset?
    public var enterDuration: TimeInterval
    public var exitDuration: TimeInterval
    public var backdropBlur: Double
    public var layerIndex: Int

    public init(
        id: UUID = UUID(),
        timing: OverlayTiming,
        relativePath: String,
        position: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        width: Double = 0.38,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        cornerRadius: Double = 18,
        borderWidth: Double = 0,
        borderColor: HexColor = .white,
        shadowOpacity: Double = 0.28,
        shadowRadius: Double = 24,
        shadowOffsetX: Double = 0,
        shadowOffsetY: Double = 10,
        animation: StickerAnimationPreset = .pop,
        exitAnimation: StickerAnimationPreset? = nil,
        enterDuration: TimeInterval = 0.7,
        exitDuration: TimeInterval = 0.22,
        backdropBlur: Double = 20,
        layerIndex: Int = 0
    ) {
        self.id = id
        self.timing = timing
        self.relativePath = relativePath
        self.position = position
        self.width = width
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.animation = animation
        self.exitAnimation = exitAnimation
        self.enterDuration = enterDuration
        self.exitDuration = exitDuration
        self.backdropBlur = backdropBlur
        self.layerIndex = layerIndex
    }
}

public enum ProgressOverlayPlacement: String, CaseIterable, Codable, Sendable {
    case top
    case custom
    case bottom
}

public struct ProgressChapter: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: TimeInterval
    public var title: String

    public init(id: UUID = UUID(), time: TimeInterval, title: String) {
        self.id = id
        self.time = time
        self.title = title
    }
}

/// One project-wide authored playback indicator. Chapter times live on the
/// same ripple output clock as every other visual track.
public struct ProgressOverlay: Codable, Equatable, Sendable {
    public var placement: ProgressOverlayPlacement
    public var position: NormalizedPoint
    public var width: Double
    public var bandHeight: Double
    public var textSize: Double
    public var thickness: Double
    public var backgroundColor: HexColor
    public var backgroundOpacity: Double
    public var trackColor: HexColor
    public var fillColor: HexColor
    public var nodeColor: HexColor
    public var textColor: HexColor
    public var chapters: [ProgressChapter]

    public init(
        placement: ProgressOverlayPlacement = .top,
        position: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.05),
        width: Double = 1,
        bandHeight: Double = 58,
        textSize: Double = 30,
        thickness: Double = 3,
        backgroundColor: HexColor = HexColor(rgb24: 0x18_19_1F),
        backgroundOpacity: Double = 0.88,
        trackColor: HexColor = HexColor(rgb24: 0xFF_FF_FF),
        fillColor: HexColor = HexColor(rgb24: 0x78_8F_C4),
        nodeColor: HexColor = .white,
        textColor: HexColor = .white,
        chapters: [ProgressChapter] = [ProgressChapter(time: 0, title: "开场介绍")]
    ) {
        self.placement = placement
        self.position = position
        self.width = width
        self.bandHeight = bandHeight
        self.textSize = textSize
        self.thickness = thickness
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.trackColor = trackColor
        self.fillColor = fillColor
        self.nodeColor = nodeColor
        self.textColor = textColor
        self.chapters = chapters
    }

    private enum CodingKeys: String, CodingKey {
        case placement, position, width, bandHeight, textSize, thickness
        case backgroundColor, backgroundOpacity
        case trackColor, fillColor, nodeColor, textColor, chapters
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPosition = try values.decodeIfPresent(
            NormalizedPoint.self,
            forKey: .position
        ) ?? NormalizedPoint(x: 0.5, y: 0.05)
        placement = try values.decodeIfPresent(
            ProgressOverlayPlacement.self,
            forKey: .placement
        ) ?? .custom
        position = decodedPosition
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 1
        bandHeight = try values.decodeIfPresent(Double.self, forKey: .bandHeight) ?? 58
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? 30
        thickness = try values.decodeIfPresent(Double.self, forKey: .thickness) ?? 3
        backgroundColor = try values.decodeIfPresent(
            HexColor.self,
            forKey: .backgroundColor
        ) ?? HexColor(rgb24: 0x18_19_1F)
        backgroundOpacity = try values.decodeIfPresent(
            Double.self,
            forKey: .backgroundOpacity
        ) ?? 0.88
        trackColor = try values.decodeIfPresent(HexColor.self, forKey: .trackColor)
            ?? HexColor(rgb24: 0xFF_FF_FF)
        fillColor = try values.decodeIfPresent(HexColor.self, forKey: .fillColor)
            ?? HexColor(rgb24: 0x78_8F_C4)
        nodeColor = try values.decodeIfPresent(HexColor.self, forKey: .nodeColor)
            ?? .white
        textColor = try values.decodeIfPresent(HexColor.self, forKey: .textColor)
            ?? .white
        chapters = try values.decodeIfPresent(
            [ProgressChapter].self,
            forKey: .chapters
        ) ?? [ProgressChapter(time: 0, title: "开场介绍")]
        ensureOpeningChapter()
    }

    /// The bar always owns an editable first section beginning at the first
    /// video frame. Later chapters only divide that existing bar; they are not
    /// required in order to enter the opening text.
    public mutating func ensureOpeningChapter() {
        let tolerance = 1.0 / 120.0
        if let index = chapters.firstIndex(where: { abs($0.time) <= tolerance }) {
            chapters[index].time = 0
        } else {
            chapters.append(ProgressChapter(time: 0, title: "开场介绍"))
        }
        chapters.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// A repeated click at the same playhead edits the existing chapter rather
    /// than creating a zero-width segment that cannot be selected reliably.
    @discardableResult
    public mutating func insertChapterIfNeeded(
        at time: TimeInterval,
        title: String,
        tolerance: TimeInterval = 1.0 / 30.0
    ) -> UUID {
        ensureOpeningChapter()
        let safeTime = max(time.isFinite ? time : 0, 0)
        if let existing = chapters.min(by: {
            abs($0.time - safeTime) < abs($1.time - safeTime)
        }), abs(existing.time - safeTime) <= max(tolerance, 0) {
            return existing.id
        }
        let chapter = ProgressChapter(time: safeTime, title: title)
        chapters.append(chapter)
        chapters.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.id.uuidString < $1.id.uuidString
        }
        return chapter.id
    }
}
