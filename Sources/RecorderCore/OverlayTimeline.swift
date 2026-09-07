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
    /// Shared non-linear timing used by both entry and exit. The visual path
    /// remains independently selectable through `animation`/`exitAnimation`.
    public var animationCurve: ElementMotionCurve
    /// `nil` follows the complementary direction of `animation`.
    public var exitAnimation: StickerAnimationPreset?
    public var enterDuration: TimeInterval
    public var exitDuration: TimeInterval
    public var backdropBlur: Double
    /// Whether the sticker's backdrop blur also softens the independent
    /// camera layer. The recorded screen/background remain the default target.
    public var backdropBlurIncludesCamera: Bool
    /// Temporarily reveal only the authored canvas background behind this
    /// sticker. The transition follows the sticker's own entrance/exit curve.
    public var hidesScreen: Bool
    /// Temporarily suppress the camera while this sticker is visible.
    public var hidesCamera: Bool
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
        animationCurve: ElementMotionCurve = .swift,
        exitAnimation: StickerAnimationPreset? = nil,
        enterDuration: TimeInterval = 0.7,
        exitDuration: TimeInterval = 0.22,
        backdropBlur: Double = 20,
        backdropBlurIncludesCamera: Bool = false,
        hidesScreen: Bool = false,
        hidesCamera: Bool = false,
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
        self.animationCurve = animationCurve
        self.exitAnimation = exitAnimation
        self.enterDuration = enterDuration
        self.exitDuration = exitDuration
        self.backdropBlur = backdropBlur
        self.backdropBlurIncludesCamera = backdropBlurIncludesCamera
        self.hidesScreen = hidesScreen
        self.hidesCamera = hidesCamera
        self.layerIndex = layerIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timing
        case relativePath
        case position
        case width
        case rotationDegrees
        case opacity
        case cornerRadius
        case borderWidth
        case borderColor
        case shadowOpacity
        case shadowRadius
        case shadowOffsetX
        case shadowOffsetY
        case animation
        case animationCurve
        case exitAnimation
        case enterDuration
        case exitDuration
        case backdropBlur
        case backdropBlurIncludesCamera
        case hidesScreen
        case hidesCamera
        case layerIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            timing: try container.decode(OverlayTiming.self, forKey: .timing),
            relativePath: try container.decode(String.self, forKey: .relativePath),
            position: try container.decode(NormalizedPoint.self, forKey: .position),
            width: try container.decode(Double.self, forKey: .width),
            rotationDegrees: try container.decode(Double.self, forKey: .rotationDegrees),
            opacity: try container.decode(Double.self, forKey: .opacity),
            cornerRadius: try container.decode(Double.self, forKey: .cornerRadius),
            borderWidth: try container.decode(Double.self, forKey: .borderWidth),
            borderColor: try container.decode(HexColor.self, forKey: .borderColor),
            shadowOpacity: try container.decode(Double.self, forKey: .shadowOpacity),
            shadowRadius: try container.decode(Double.self, forKey: .shadowRadius),
            shadowOffsetX: try container.decode(Double.self, forKey: .shadowOffsetX),
            shadowOffsetY: try container.decode(Double.self, forKey: .shadowOffsetY),
            animation: try container.decode(StickerAnimationPreset.self, forKey: .animation),
            animationCurve: try container.decodeIfPresent(
                ElementMotionCurve.self,
                forKey: .animationCurve
            ) ?? .swift,
            exitAnimation: try container.decodeIfPresent(
                StickerAnimationPreset.self,
                forKey: .exitAnimation
            ),
            enterDuration: try container.decode(Double.self, forKey: .enterDuration),
            exitDuration: try container.decode(Double.self, forKey: .exitDuration),
            backdropBlur: try container.decode(Double.self, forKey: .backdropBlur),
            backdropBlurIncludesCamera: try container.decodeIfPresent(
                Bool.self,
                forKey: .backdropBlurIncludesCamera
            ) ?? false,
            hidesScreen: try container.decodeIfPresent(
                Bool.self,
                forKey: .hidesScreen
            ) ?? false,
            hidesCamera: try container.decodeIfPresent(
                Bool.self,
                forKey: .hidesCamera
            ) ?? false,
            layerIndex: try container.decode(Int.self, forKey: .layerIndex)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timing, forKey: .timing)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(position, forKey: .position)
        try container.encode(width, forKey: .width)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(borderColor, forKey: .borderColor)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(shadowRadius, forKey: .shadowRadius)
        try container.encode(shadowOffsetX, forKey: .shadowOffsetX)
        try container.encode(shadowOffsetY, forKey: .shadowOffsetY)
        try container.encode(animation, forKey: .animation)
        try container.encode(animationCurve, forKey: .animationCurve)
        try container.encodeIfPresent(exitAnimation, forKey: .exitAnimation)
        try container.encode(enterDuration, forKey: .enterDuration)
        try container.encode(exitDuration, forKey: .exitDuration)
        try container.encode(backdropBlur, forKey: .backdropBlur)
        try container.encode(
            backdropBlurIncludesCamera,
            forKey: .backdropBlurIncludesCamera
        )
        try container.encode(hidesScreen, forKey: .hidesScreen)
        try container.encode(hidesCamera, forKey: .hidesCamera)
        try container.encode(layerIndex, forKey: .layerIndex)
    }
}
