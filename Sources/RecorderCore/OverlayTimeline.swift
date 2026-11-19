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
    public var mainTrackStyle: MainTrackVisualStyle? = nil
    public var sourceStart: TimeInterval = 0
    public var playbackRate: Double = 1
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
        shadowOpacity: Double = 0.24,
        shadowRadius: Double = 30,
        shadowOffsetX: Double = 0,
        shadowOffsetY: Double = 12,
        animation: StickerAnimationPreset = .pop,
        animationCurve: ElementMotionCurve = .swift,
        exitAnimation: StickerAnimationPreset? = nil,
        enterDuration: TimeInterval = 0.45,
        exitDuration: TimeInterval = 0.3,
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
        case mainTrackStyle
        case sourceStart, playbackRate
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
        mainTrackStyle = try container.decodeIfPresent(MainTrackVisualStyle.self, forKey: .mainTrackStyle)
        sourceStart = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStart) ?? 0
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(mainTrackStyle, forKey: .mainTrackStyle)
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

/// A value for one property a Rive file exposes through its view model.
/// Unknown/unset properties keep the file's own default.
public enum AnimationPropertyValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case color(HexColor)
}

/// EDT-073: the user's hands-on change to one element of an HTML motion —
/// moved (in the page's CSS px), hidden, or retexted. Kept on the clip, so
/// the design file and other uses of it are untouched.
public struct MotionElementEdit: Codable, Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var hidden: Bool
    public var text: String?
    /// EDT-077: 1 = the page's own size.
    public var scale: Double
    /// Text colour, as #RRGGBB.
    public var color: String?
    /// nil preserves the font authored by the motion page.
    public var fontFamily: String?
    public var fontWeight: Int?
    /// Fill (background colour) of a box or shape, as #RRGGBB.
    public var fill: String?
    /// A picture the user put in place of an image element (absolute path).
    public var image: String?
    /// EDT-079: corner radius in page pixels; nil keeps the page's own.
    public var radius: Double?
    /// Outline width in page pixels and its colour.
    public var strokeWidth: Double?
    public var strokeColor: String?
    /// Degrees, clockwise.
    public var rotation: Double
    /// 0–1; 1 = the page's own.
    public var opacity: Double

    public init(dx: Double = 0, dy: Double = 0, hidden: Bool = false, text: String? = nil,
                scale: Double = 1, color: String? = nil, fill: String? = nil, image: String? = nil,
                radius: Double? = nil, strokeWidth: Double? = nil, strokeColor: String? = nil,
                rotation: Double = 0, opacity: Double = 1,
                fontFamily: String? = nil, fontWeight: Int? = nil) {
        self.dx = dx
        self.dy = dy
        self.hidden = hidden
        self.text = text
        self.scale = scale
        self.color = color
        self.fill = fill
        self.image = image
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.rotation = rotation
        self.opacity = opacity
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight.map { min(max($0, 100), 900) }
    }

    public var isEmpty: Bool {
        dx == 0 && dy == 0 && !hidden && text == nil && abs(scale - 1) < 0.0001
            && color == nil && fill == nil && image == nil && fontFamily == nil && fontWeight == nil
            && radius == nil && strokeWidth == nil && strokeColor == nil
            && abs(rotation) < 0.0001 && abs(opacity - 1) < 0.0001
    }

    private enum CodingKeys: String, CodingKey { case dx, dy, hidden, text, scale, color, fill, image, radius, strokeWidth, strokeColor, rotation, opacity, fontFamily, fontWeight }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dx = try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0
        dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        color = try c.decodeIfPresent(String.self, forKey: .color)
        fill = try c.decodeIfPresent(String.self, forKey: .fill)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth)
        strokeColor = try c.decodeIfPresent(String.self, forKey: .strokeColor)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        fontWeight = try c.decodeIfPresent(Int.self, forKey: .fontWeight).map { min(max($0, 100), 900) }
    }
}

/// An HTML motion graphic placed over the picture for a span of time. The
/// file is referenced where it lives (AI-generated files live in the project);
/// its playback time is the clip-local time, stepped at the project frame
/// rate so preview and export see identical frames.
public struct AnimationClip: Codable, Equatable, Identifiable, Sendable {
    public var mainTrackStyle: MainTrackVisualStyle? = nil
    public var playbackRate: Double = 1
    public var soundtrack: VisualClipSound? = nil
    public var id: UUID
    public var timing: OverlayTiming
    /// Absolute path, or a path relative to the project package.
    public var sourcePath: String
    public var artboard: String?
    public var stateMachine: String?
    public var position: NormalizedPoint
    /// Width relative to the output canvas. Height follows the artboard aspect.
    public var width: Double
    public var opacity: Double
    public var properties: [String: AnimationPropertyValue]
    public var layerIndex: Int
    /// Where in the animation this clip starts; a split's second half
    /// continues instead of restarting.
    public var timeOffset: TimeInterval
    /// Per-element edits by element key (EDT-073).
    public var elementEdits: [String: MotionElementEdit]

    private enum CodingKeys: String, CodingKey {
        case id, timing, sourcePath, artboard, stateMachine, position, width, opacity, properties, layerIndex, timeOffset, elementEdits, mainTrackStyle, playbackRate, soundtrack
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timing = try c.decode(OverlayTiming.self, forKey: .timing)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        artboard = try c.decodeIfPresent(String.self, forKey: .artboard)
        stateMachine = try c.decodeIfPresent(String.self, forKey: .stateMachine)
        position = try c.decode(NormalizedPoint.self, forKey: .position)
        width = try c.decode(Double.self, forKey: .width)
        opacity = try c.decode(Double.self, forKey: .opacity)
        properties = try c.decodeIfPresent([String: AnimationPropertyValue].self, forKey: .properties) ?? [:]
        layerIndex = try c.decodeIfPresent(Int.self, forKey: .layerIndex) ?? 0
        timeOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .timeOffset) ?? 0
        elementEdits = try c.decodeIfPresent([String: MotionElementEdit].self, forKey: .elementEdits) ?? [:]
        mainTrackStyle = try c.decodeIfPresent(MainTrackVisualStyle.self, forKey: .mainTrackStyle)
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        soundtrack = try c.decodeIfPresent(VisualClipSound.self, forKey: .soundtrack)
    }

    public init(
        id: UUID = UUID(),
        timing: OverlayTiming,
        sourcePath: String,
        artboard: String? = nil,
        stateMachine: String? = nil,
        position: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        width: Double = 0.5,
        opacity: Double = 1,
        properties: [String: AnimationPropertyValue] = [:],
        layerIndex: Int = 0
    ) {
        self.id = id
        self.timing = timing
        self.sourcePath = sourcePath
        self.artboard = artboard
        self.stateMachine = stateMachine
        self.position = position
        self.width = width
        self.opacity = opacity
        self.properties = properties
        self.layerIndex = layerIndex
        self.timeOffset = 0
        self.elementEdits = [:]
    }
}
