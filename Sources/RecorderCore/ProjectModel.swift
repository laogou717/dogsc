import Foundation

/// Version 23 is the first deliberately compact project contract. It retains
/// recording cuts, motion, redaction and still-image stickers, and removes the
/// retired subtitle, material-library video and progress-overlay models.
public enum ProjectSchema {
    public static let minimumSupportedVersion = 23
    // Version 24 adds authored canvas ratios. Version 23 projects retain their defaults.
    // Version 27 persists recording markers; older apps must not silently discard them.
    public static let currentVersion = 27

    static func validateForDecoding(_ version: Int) throws {
        guard version >= minimumSupportedVersion else {
            throw ProjectSchemaError.unsupportedLegacyVersion(
                found: version,
                minimumSupported: minimumSupportedVersion
            )
        }
        guard version <= currentVersion else {
            throw ProjectSchemaError.unsupportedFutureVersion(
                found: version,
                current: currentVersion
            )
        }
    }

    static func validateForEncoding(_ version: Int) throws {
        guard version >= minimumSupportedVersion else {
            throw ProjectSchemaError.refusingToEncodeUnsupportedVersion(
                found: version,
                supportedRange: minimumSupportedVersion...currentVersion
            )
        }
        guard version <= currentVersion else {
            throw ProjectSchemaError.refusingToEncodeFutureVersion(
                found: version,
                current: currentVersion
            )
        }
    }
}

public enum ProjectSchemaError: Error, Equatable, Sendable {
    case unsupportedLegacyVersion(found: Int, minimumSupported: Int)
    case unsupportedFutureVersion(found: Int, current: Int)
    case refusingToEncodeUnsupportedVersion(found: Int, supportedRange: ClosedRange<Int>)
    case refusingToEncodeFutureVersion(found: Int, current: Int)
}

extension ProjectSchemaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedLegacyVersion(found, minimumSupported):
            return "项目版本 \(found) 过旧；当前应用最低支持版本 \(minimumSupported)。"
        case let .unsupportedFutureVersion(found, current):
            return "项目版本 \(found) 来自更新的应用；当前应用只支持到版本 \(current)，为避免损坏项目已停止打开。"
        case let .refusingToEncodeUnsupportedVersion(found, supportedRange):
            return "拒绝写入项目版本 \(found)；可写入版本范围为 \(supportedRange.lowerBound)...\(supportedRange.upperBound)。"
        case let .refusingToEncodeFutureVersion(found, current):
            return "拒绝用当前应用覆盖未来项目版本 \(found)；当前应用只支持到版本 \(current)。"
        }
    }
}

public enum CanvasAspectRatio: String, CaseIterable, Codable, Identifiable, Sendable {
    case adaptive = "适应"
    case landscape = "16:9"
    case standard = "4:3"
    case portrait = "9:16"
    case square = "1:1"
    case standardPortrait = "3:4"
    case cinema = "2.39:1"
    case cinemaPortrait = "1:2.39"
    case custom = "自定义"

    public var id: String { rawValue }
}

public enum CanvasResolution: String, CaseIterable, Codable, Identifiable, Sendable {
    case source = "原始素材"
    case fullHD = "1080p"
    case quadHD = "1440p"
    case ultraHD = "4K"

    public var id: String { rawValue }

    fileprivate var presetEdges: (short: Int, long: Int)? {
        switch self {
        case .source: return nil
        case .fullHD: return (1_080, 1_920)
        case .quadHD: return (1_440, 2_560)
        case .ultraHD: return (2_160, 3_840)
        }
    }
}

/// Stable, project-facing identity for the vector frame drawn around the
/// recorded screen. The renderer receives a fully evaluated decoration scene;
/// it never interprets these storage values itself.
public enum ScreenFrameStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case windowLight
    case windowDark
    case browserLight
    case browserDark
    case devicePhone
    case deviceTablet
    case devicePhonePortrait
    case devicePhoneLandscape
    case deviceTabletPortrait
    case deviceTabletLandscape

    /// One adaptive device entry; legacy oriented identities retain their
    /// saved geometry but share the same picker card.
    public static let allCases: [ScreenFrameStyle] = [
        .none, .windowLight, .windowDark, .browserLight, .browserDark,
        .devicePhone,
    ]

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case Self.none.rawValue: self = .none
        case Self.windowLight.rawValue: self = .windowLight
        case Self.windowDark.rawValue: self = .windowDark
        case Self.browserLight.rawValue: self = .browserLight
        case Self.browserDark.rawValue: self = .browserDark
        // Removed local designs have no chrome; retain only safe decoding.
        case "paperWhite", "graphite": self = .none
        case Self.devicePhone.rawValue: self = .devicePhone
        case Self.deviceTablet.rawValue: self = .deviceTablet
        case Self.devicePhonePortrait.rawValue: self = .devicePhonePortrait
        case Self.devicePhoneLandscape.rawValue: self = .devicePhoneLandscape
        case Self.deviceTabletPortrait.rawValue: self = .deviceTabletPortrait
        case Self.deviceTabletLandscape.rawValue: self = .deviceTabletLandscape
        // These experimental values existed only in an uncommitted local
        // design pass. Map them to the closest core style so those local
        // projects remain openable without retaining six rendering systems.
        case "cyberNeon", "titaniumBevel", "studioRim": self = .windowDark
        case "frostedGlass", "vintageMac", "galleryArt": self = .windowLight
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unsupported screen frame style: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var defaultOuterCornerRadius: Double { defaults.outerRadius }
    public var defaultContentCornerRadius: Double { defaults.contentRadius }

    public var isDeviceFrame: Bool {
        switch self {
        case .devicePhone, .deviceTablet, .devicePhonePortrait,
             .devicePhoneLandscape, .deviceTabletPortrait,
             .deviceTabletLandscape: true
        case .none, .windowLight, .windowDark, .browserLight, .browserDark: false
        }
    }

    public var isBrowserFrame: Bool {
        self == .browserLight || self == .browserDark
    }

    public var isWindowFrame: Bool {
        self == .windowLight || self == .windowDark
    }
}

public enum OpeningSequencePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case converge = "聚拢"
    case sideSlide = "侧滑"
    case light3D = "轻 3D"

    public var id: String { rawValue }
}

public enum OpeningSequenceElement: String, CaseIterable, Codable, Identifiable, Sendable {
    case screen = "屏幕"
    case camera = "摄像头"
    case stickers = "贴图"

    public var id: String { rawValue }
}

public struct OpeningSequence: Codable, Equatable, Sendable {
    /// Every participating element keeps at least this much authored motion
    /// inside the declared total opening duration. Larger requested gaps are
    /// reduced instead of letting a late element miss the opening window and
    /// pop on at its end.
    public static let minimumElementDuration: TimeInterval = 0.18

    public var isEnabled: Bool
    public var preset: OpeningSequencePreset
    public var motionCurve: ElementMotionCurve
    public var duration: TimeInterval
    public var stagger: TimeInterval
    public var includedElements: [OpeningSequenceElement]
    public var elementOrder: [OpeningSequenceElement]

    public init(
        isEnabled: Bool = false,
        preset: OpeningSequencePreset = .light3D,
        motionCurve: ElementMotionCurve = .swift,
        duration: TimeInterval = 2.2,
        stagger: TimeInterval = 0.16,
        includedElements: [OpeningSequenceElement] = OpeningSequenceElement.allCases,
        elementOrder: [OpeningSequenceElement] = [.screen, .camera, .stickers]
    ) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.motionCurve = motionCurve
        self.duration = min(max(duration.isFinite ? duration : 2.2, 0.4), 8)
        self.stagger = min(max(stagger.isFinite ? stagger : 0.16, 0), 1.2)
        self.includedElements = Self.normalized(includedElements, appendingMissing: false)
        self.elementOrder = Self.normalized(elementOrder, appendingMissing: true)
        normalizeTiming()
    }

    public func maximumStagger(for elementCount: Int) -> TimeInterval {
        let gapCount = max(elementCount - 1, 0)
        // With zero or one participant there is no active gap to constrain.
        // Preserve the user's interval so re-enabling another element does
        // not silently reset their authored rhythm.
        guard gapCount > 0 else { return 1.2 }
        return min(
            1.2,
            max(duration - Self.minimumElementDuration, 0) / Double(gapCount)
        )
    }

    public mutating func normalizeTiming() {
        duration = min(max(duration.isFinite ? duration : 2.2, 0.4), 8)
        let maximum = maximumStagger(for: includedElements.count)
        stagger = min(max(stagger.isFinite ? stagger : 0.16, 0), maximum)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case preset
        case motionCurve
        case duration
        case stagger
        case includedElements
        case elementOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            preset: try container.decodeIfPresent(OpeningSequencePreset.self, forKey: .preset)
                ?? .light3D,
            motionCurve: try container.decodeIfPresent(
                ElementMotionCurve.self,
                forKey: .motionCurve
            ) ?? .swift,
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 2.2,
            stagger: try container.decodeIfPresent(TimeInterval.self, forKey: .stagger) ?? 0.16,
            includedElements: try container.decodeIfPresent(
                [OpeningSequenceElement].self,
                forKey: .includedElements
            ) ?? OpeningSequenceElement.allCases,
            elementOrder: try container.decodeIfPresent(
                [OpeningSequenceElement].self,
                forKey: .elementOrder
            ) ?? [.screen, .camera, .stickers]
        )
    }

    private static func normalized(
        _ elements: [OpeningSequenceElement],
        appendingMissing: Bool
    ) -> [OpeningSequenceElement] {
        var seen = Set<OpeningSequenceElement>()
        var result = elements.filter { seen.insert($0).inserted }
        if appendingMissing {
            result.append(contentsOf: OpeningSequenceElement.allCases.filter { !seen.contains($0) })
        }
        return result
    }
}

public enum BackgroundPatternPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case obsidianGrid = "黑曜石网格"
    case engineeringWhiteGrid = "工程白网格"
    case midnightDots = "暗夜星阵"
    case architecturalDots = "建筑极简点"
    case isometricMesh = "立体等角网"

    public var id: String { rawValue }
}

public enum DynamicBackgroundPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case cyberDriftGrid = "赛博微流网格"
    case starfieldDots = "星辉漫步点阵"
    case auroraFluid = "极光流体星云"

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        // The rotating-cross experiment existed in one local development
        // candidate only. Keep those projects openable without retaining its
        // expensive per-frame renderer or exposing the rejected preset.
        if rawValue == "旋转十字星阵" {
            self = .cyberDriftGrid
            return
        }
        guard let preset = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unsupported dynamic background preset: \(rawValue)"
            )
        }
        self = preset
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Keep persisted raw values stable while allowing the visible names to
    /// describe the current authored look more precisely.
    public var displayName: String {
        switch self {
        case .cyberDriftGrid: "流金缓移网格"
        case .starfieldDots: "暖星漫步点阵"
        case .auroraFluid: "蓝白流体云幕"
        }
    }
}

/// The one active background source for a canvas.
///
/// Project-relative custom media and system-absolute wallpaper references stay
/// distinct so user files can travel with a project while Apple-managed media
/// is never copied into the app or project package.
public enum BackgroundSource: Codable, Equatable, Sendable {
    case pattern(BackgroundPatternPreset)
    case dynamicFlow(DynamicBackgroundPreset)
    case projectImage(relativePath: String)
    case systemImage(absolutePath: String)
    case projectVideo(relativePath: String)
    case systemVideo(absolutePath: String)

    public static let safeFallback = BackgroundSource.pattern(.obsidianGrid)

    public var isImage: Bool {
        switch self {
        case .projectImage, .systemImage:
            return true
        case .pattern, .dynamicFlow, .projectVideo, .systemVideo:
            return false
        }
    }

    public var isVideo: Bool {
        switch self {
        case .projectVideo, .systemVideo:
            return true
        case .pattern, .dynamicFlow, .projectImage, .systemImage:
            return false
        }
    }

    public var usesWallpaperMedia: Bool { isImage || isVideo }

    private enum Kind: String, Codable {
        case pattern
        case dynamicFlow
        case projectImage
        case systemImage
        case projectVideo
        case systemVideo
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case patternPreset
        case dynamicPreset
        case relativePath
        case absolutePath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .pattern:
            self = .pattern(
                try container.decode(BackgroundPatternPreset.self, forKey: .patternPreset)
            )
        case .dynamicFlow:
            self = .dynamicFlow(
                try container.decode(DynamicBackgroundPreset.self, forKey: .dynamicPreset)
            )
        case .projectImage:
            self = .projectImage(
                relativePath: try container.decode(String.self, forKey: .relativePath)
            )
        case .systemImage:
            self = .systemImage(
                absolutePath: try container.decode(String.self, forKey: .absolutePath)
            )
        case .projectVideo:
            self = .projectVideo(
                relativePath: try container.decode(String.self, forKey: .relativePath)
            )
        case .systemVideo:
            self = .systemVideo(
                absolutePath: try container.decode(String.self, forKey: .absolutePath)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pattern(preset):
            try container.encode(Kind.pattern, forKey: .kind)
            try container.encode(preset, forKey: .patternPreset)
        case let .dynamicFlow(preset):
            try container.encode(Kind.dynamicFlow, forKey: .kind)
            try container.encode(preset, forKey: .dynamicPreset)
        case let .projectImage(relativePath):
            try container.encode(Kind.projectImage, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        case let .systemImage(absolutePath):
            try container.encode(Kind.systemImage, forKey: .kind)
            try container.encode(absolutePath, forKey: .absolutePath)
        case let .projectVideo(relativePath):
            try container.encode(Kind.projectVideo, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        case let .systemVideo(absolutePath):
            try container.encode(Kind.systemVideo, forKey: .kind)
            try container.encode(absolutePath, forKey: .absolutePath)
        }
    }
}

public enum CameraShape: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case square = "方形"
    case horizontal = "横向"
    case vertical = "纵向"
    case original = "原始比例"
    case circle = "圆形"

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "圆角矩形": self = .horizontal
        case "连续圆角": self = .square
        default: self = CameraShape(rawValue: value) ?? .square
        }
    }
}

public enum ScreenMotionStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case focused = "聚焦"
    case smooth = "平滑"

    public var id: String { rawValue }
}

public enum CursorMotionStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case smooth = "平滑"
    case medium = "适中"
    case rapid = "快速"
    case none = "无"

    public var id: String { rawValue }
}

public enum CursorAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case arrow = "系统箭头"
    case pointingHand = "指向手势"
    case crosshair = "十字准星"
    case hidden = "隐藏"

    public var id: String { rawValue }
}

/// Stable cursor resource identity persisted in `project.json`.
///
/// Display names intentionally live in the app-side catalog. Keeping the
/// storage identifier language-neutral lets labels and artwork evolve without
/// invalidating existing projects.
public struct CursorAssetID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static let systemArrow = CursorAssetID(rawValue: "system.arrow")
    public static let automatic = CursorAssetID(rawValue: "system.automatic")
    public static let systemPointingHand = CursorAssetID(rawValue: "system.pointing-hand")
    public static let systemCrosshair = CursorAssetID(rawValue: "system.crosshair")
    public static let systemIBeam = CursorAssetID(rawValue: "system.ibeam")
    public static let systemOpenHand = CursorAssetID(rawValue: "system.open-hand")
    public static let systemClosedHand = CursorAssetID(rawValue: "system.closed-hand")
    public static let systemNotAllowed = CursorAssetID(rawValue: "system.not-allowed")
    public static let touchDot = CursorAssetID(rawValue: "system.touch-dot")
    public static let hidden = CursorAssetID(rawValue: "system.hidden")

    // 已退役的生成样式 ID：保留常量仅供旧项目解码，资源目录中已无
    // 对应资产，解析时统一回落到系统箭头。
    public static let classicLavender = CursorAssetID(rawValue: "cursor.classic-lavender")
    public static let violetGlass = CursorAssetID(rawValue: "cursor.violet-glass")
    public static let graphiteIvory = CursorAssetID(rawValue: "cursor.graphite-ivory")
    public static let creamCoral = CursorAssetID(rawValue: "cursor.cream-coral")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CursorClickEffectStyle: String, Codable, CaseIterable, Sendable {
    case ripple = "ripple"
    case glow = "glow"
    case pulse = "pulse"
    case burst = "burst"
    case none = "none"

    public var displayName: String {
        switch self {
        case .ripple: return "涟漪扩散"
        case .glow: return "柔和光晕"
        case .pulse: return "弹性双环"
        case .burst: return "聚焦微闪"
        case .none: return "无效果"
        }
    }

    public var duration: Double {
        switch self {
        case .ripple: return 0.36
        case .glow: return 0.32
        case .pulse: return 0.38
        case .burst: return 0.22
        case .none: return 0.0
        }
    }
}

public struct CursorStyle: Codable, Equatable, Sendable {
    public var assetID: CursorAssetID
    public var size: Double
    public var hideWhenIdle: Bool
    public var idleDelay: Double
    public var clickEffectStyle: CursorClickEffectStyle
    public var clickColor: HexColor?
    public var clickOpacity: Double
    public var clickScale: Double
    /// User-facing strength of the hotspot-anchored cursor body swing.
    /// The visible presets run from `2` through `4`; `.none` on the motion
    /// style is the single explicit way to disable the effect.
    public var motionTiltStrength: Double

    public var showsClickEffect: Bool {
        get { clickEffectStyle != .none }
        set {
            if !newValue {
                clickEffectStyle = .none
            } else if clickEffectStyle == .none {
                clickEffectStyle = .ripple
            }
        }
    }

    public init(
        assetID: CursorAssetID = .automatic,
        size: Double = 1.25,
        hideWhenIdle: Bool = false,
        idleDelay: Double = 1.2,
        clickEffectStyle: CursorClickEffectStyle = .ripple,
        clickColor: HexColor? = nil,
        clickOpacity: Double = 0.8,
        clickScale: Double = 1.0,
        motionTiltStrength: Double = 2.0
    ) {
        self.assetID = assetID.rawValue.isEmpty ? .systemArrow : assetID
        self.size = min(max(size, 0.25), 6)
        self.hideWhenIdle = hideWhenIdle
        self.idleDelay = min(max(idleDelay, 0.2), 8)
        self.clickEffectStyle = clickEffectStyle
        self.clickColor = clickColor
        self.clickOpacity = min(max(clickOpacity, 0.05), 1.0)
        self.clickScale = min(max(clickScale, 0.4), 3.0)
        self.motionTiltStrength = min(max(motionTiltStrength, 2), 4)
    }

    public init(
        assetID: CursorAssetID = .automatic,
        size: Double = 1.25,
        hideWhenIdle: Bool = false,
        idleDelay: Double = 1.2,
        showsClickEffect: Bool
    ) {
        self.init(
            assetID: assetID,
            size: size,
            hideWhenIdle: hideWhenIdle,
            idleDelay: idleDelay,
            clickEffectStyle: showsClickEffect ? .ripple : .none,
            clickColor: nil,
            clickOpacity: 0.8,
            clickScale: 1.0
        )
    }

    /// Source-compatibility bridge for callers that still construct the four
    /// cursor choices supported before stable asset identifiers were added.
    public init(
        appearance: CursorAppearance,
        size: Double = 1.25,
        hideWhenIdle: Bool = false,
        idleDelay: Double = 1.2,
        showsClickEffect: Bool = true
    ) {
        self.init(
            assetID: Self.assetID(for: appearance),
            size: size,
            hideWhenIdle: hideWhenIdle,
            idleDelay: idleDelay,
            clickEffectStyle: showsClickEffect ? .ripple : .none,
            clickColor: nil,
            clickOpacity: 0.8,
            clickScale: 1.0
        )
    }

    public init(
        appearance: CursorAppearance,
        size: Double = 1.25,
        hideWhenIdle: Bool = false,
        idleDelay: Double = 1.2,
        clickEffectStyle: CursorClickEffectStyle,
        clickColor: HexColor? = nil,
        clickOpacity: Double = 0.8,
        clickScale: Double = 1.0
    ) {
        self.init(
            assetID: Self.assetID(for: appearance),
            size: size,
            hideWhenIdle: hideWhenIdle,
            idleDelay: idleDelay,
            clickEffectStyle: clickEffectStyle,
            clickColor: clickColor,
            clickOpacity: clickOpacity,
            clickScale: clickScale
        )
    }

    /// Compatibility view for older app code. New persistence and rendering
    /// code must use `assetID`; custom artwork maps to the arrow only when an
    /// old caller explicitly asks for this legacy representation.
    public var appearance: CursorAppearance {
        get {
            switch assetID {
            case .systemPointingHand: return .pointingHand
            case .systemCrosshair: return .crosshair
            case .hidden: return .hidden
            default: return .arrow
            }
        }
        set { assetID = Self.assetID(for: newValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case assetID, appearance, size, hideWhenIdle, idleDelay
        case showsClickEffect, clickEffectStyle, clickColor, clickOpacity, clickScale
        case motionTiltStrength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedAssetID = try container.decodeIfPresent(CursorAssetID.self, forKey: .assetID)
        let legacyAppearance = try container.decodeIfPresent(
            CursorAppearance.self,
            forKey: .appearance
        )
        let decodedStyle = try container.decodeIfPresent(
            CursorClickEffectStyle.self,
            forKey: .clickEffectStyle
        )
        let legacyShowsClickEffect = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsClickEffect
        )
        let effectiveStyle: CursorClickEffectStyle
        if let decodedStyle {
            effectiveStyle = decodedStyle
        } else if let legacyShowsClickEffect {
            effectiveStyle = legacyShowsClickEffect ? .ripple : .none
        } else {
            effectiveStyle = .ripple
        }
        self.init(
            assetID: decodedAssetID ?? Self.assetID(for: legacyAppearance ?? .arrow),
            size: try container.decodeIfPresent(Double.self, forKey: .size) ?? 1.25,
            hideWhenIdle: try container.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? false,
            idleDelay: try container.decodeIfPresent(Double.self, forKey: .idleDelay) ?? 1.2,
            clickEffectStyle: effectiveStyle,
            clickColor: try container.decodeIfPresent(HexColor.self, forKey: .clickColor),
            clickOpacity: try container.decodeIfPresent(Double.self, forKey: .clickOpacity) ?? 0.8,
            clickScale: try container.decodeIfPresent(Double.self, forKey: .clickScale) ?? 1.0,
            motionTiltStrength: try container.decodeIfPresent(
                Double.self,
                forKey: .motionTiltStrength
            ) ?? 2.0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(size, forKey: .size)
        try container.encode(hideWhenIdle, forKey: .hideWhenIdle)
        try container.encode(idleDelay, forKey: .idleDelay)
        try container.encode(showsClickEffect, forKey: .showsClickEffect)
        try container.encode(clickEffectStyle, forKey: .clickEffectStyle)
        try container.encodeIfPresent(clickColor, forKey: .clickColor)
        try container.encode(clickOpacity, forKey: .clickOpacity)
        try container.encode(clickScale, forKey: .clickScale)
    }

    private static func assetID(for appearance: CursorAppearance) -> CursorAssetID {
        switch appearance {
        case .arrow: return .systemArrow
        case .pointingHand: return .systemPointingHand
        case .crosshair: return .systemCrosshair
        case .hidden: return .hidden
        }
    }
}

/// A normalized crop rectangle whose origin is measured from the source's
/// top-left corner. Keeping the crop independent from output resolution makes
/// it stable when the user changes the canvas size or export resolution.
public struct NormalizedCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedCrop()

    public var left: Double { x }
    public var top: Double { y }
    public var right: Double { 1 - x - width }
    public var bottom: Double { 1 - y - height }

    public func clamped(minimumSize: Double = 0.02) -> NormalizedCrop {
        let minimum = min(max(minimumSize, 0.001), 1)
        let safeX = min(max(x, 0), 1 - minimum)
        let safeY = min(max(y, 0), 1 - minimum)
        return NormalizedCrop(
            x: safeX,
            y: safeY,
            width: min(max(width, minimum), 1 - safeX),
            height: min(max(height, minimum), 1 - safeY)
        )
    }

    public static func fromEdges(
        left: Double,
        right: Double,
        top: Double,
        bottom: Double,
        minimumSize: Double = 0.02
    ) -> NormalizedCrop {
        let minimum = min(max(minimumSize, 0.001), 1)
        let safeLeft = min(max(left, 0), 1 - minimum)
        let safeTop = min(max(top, 0), 1 - minimum)
        let safeRight = min(max(right, 0), 1 - safeLeft - minimum)
        let safeBottom = min(max(bottom, 0), 1 - safeTop - minimum)
        return NormalizedCrop(
            x: safeLeft,
            y: safeTop,
            width: 1 - safeLeft - safeRight,
            height: 1 - safeTop - safeBottom
        )
    }
}

public struct CanvasStyle: Codable, Equatable, Sendable {
    public var aspectRatio: CanvasAspectRatio
    public var customAspectRatio: CanvasCustomAspectRatio
    public var backgroundSource: BackgroundSource
    public var padding: Double
    public var contentScale: Double
    public var contentPosition: NormalizedPoint
    public var crop: NormalizedCrop
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var shadowStrength: Double
    public var backgroundBlur: Double
    public var insetOpacity: Double
    public var screenFrame: ScreenFrameStyle
    /// Scales the authored toolbar and bezel measurements of a screen frame
    /// without changing the recorded content itself.
    public var screenFrameScale: Double
    /// Independently scales a window/browser toolbar without changing device
    /// bezels or the recorded content rectangle.
    public var screenFrameToolbarScale: Double
    /// Optional authored-point overrides. `nil` preserves the style's native
    /// geometry so old projects retain their exact silhouette.
    public var screenFrameOuterCornerRadius: Double?
    public var screenFrameContentCornerRadius: Double?
    /// Text is part of the frame decoration and therefore shares screen 3D,
    /// opening motion, preview and export instead of floating above the card.
    public var screenFrameTitle: String
    public var screenFrameBrowserAddress: String
    /// Scales the density / spacing / size of background grids and dot patterns.
    public var patternScale: Double
    /// Controls the opacity / intensity of background patterns and dynamic flows.
    public var patternOpacity: Double

    public init(
        aspectRatio: CanvasAspectRatio = .adaptive,
        customAspectRatio: CanvasCustomAspectRatio = .init(),
        backgroundSource: BackgroundSource = .safeFallback,
        padding: Double = 100,
        contentScale: Double = 1,
        contentPosition: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        crop: NormalizedCrop = .full,
        cornerRadius: Double = 24,
        borderWidth: Double = 0,
        borderColor: HexColor = .white,
        shadowStrength: Double = 0.28,
        backgroundBlur: Double = 0,
        insetOpacity: Double = 0.125,
        screenFrame: ScreenFrameStyle = .none,
        screenFrameScale: Double = 1,
        screenFrameToolbarScale: Double = 1,
        screenFrameOuterCornerRadius: Double? = nil,
        screenFrameContentCornerRadius: Double? = nil,
        screenFrameTitle: String = "",
        screenFrameBrowserAddress: String = "",
        patternScale: Double = 1,
        patternOpacity: Double = 1
    ) {
        self.aspectRatio = aspectRatio
        self.customAspectRatio = customAspectRatio
        self.backgroundSource = backgroundSource
        self.padding = padding
        self.contentScale = contentScale
        self.contentPosition = contentPosition
        self.crop = crop.clamped()
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.shadowStrength = shadowStrength
        self.backgroundBlur = backgroundBlur
        self.insetOpacity = insetOpacity
        self.screenFrame = screenFrame
        self.screenFrameScale = min(max(screenFrameScale, 0.6), 1.6)
        self.screenFrameToolbarScale = min(max(screenFrameToolbarScale, 0.65), 1.6)
        self.screenFrameOuterCornerRadius = screenFrameOuterCornerRadius.map {
            min(max($0, 0), 160)
        }
        self.screenFrameContentCornerRadius = screenFrameContentCornerRadius.map {
            min(max($0, 0), 160)
        }
        self.screenFrameTitle = String(screenFrameTitle.prefix(120))
        self.screenFrameBrowserAddress = String(screenFrameBrowserAddress.prefix(240))
        self.patternScale = min(max(patternScale, 0.4), 6.0)
        self.patternOpacity = min(max(patternOpacity, 0.0), 1.0)
    }

    private enum CodingKeys: String, CodingKey {
        case aspectRatio
        case customAspectRatio
        case backgroundSource
        case padding
        case contentScale
        case contentPosition
        case crop
        case cornerRadius
        case borderWidth
        case borderHex
        case shadowStrength
        case backgroundBlur
        case insetOpacity
        case screenFrame
        case screenFrameScale
        case screenFrameToolbarScale
        case screenFrameOuterCornerRadius
        case screenFrameContentCornerRadius
        case screenFrameTitle
        case screenFrameBrowserAddress
        case patternScale
        case patternOpacity
    }

    public init(from decoder: any Decoder) throws {
        try self.init(
            from: decoder,
            projectSchemaVersion: ProjectSchema.minimumSupportedVersion
        )
    }

    init(from decoder: any Decoder, projectSchemaVersion: Int) throws {
        _ = projectSchemaVersion
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio = try container.decodeIfPresent(CanvasAspectRatio.self, forKey: .aspectRatio) ?? .adaptive
        customAspectRatio = try container.decodeIfPresent(CanvasCustomAspectRatio.self, forKey: .customAspectRatio) ?? .init()
        backgroundSource = try container.decodeIfPresent(
            BackgroundSource.self,
            forKey: .backgroundSource
        ) ?? .safeFallback
        padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? 100
        contentScale = try container.decodeIfPresent(Double.self, forKey: .contentScale) ?? 1
        contentPosition = try container.decodeIfPresent(NormalizedPoint.self, forKey: .contentPosition)
            ?? NormalizedPoint(x: 0.5, y: 0.5)
        crop = try container.decodeIfPresent(NormalizedCrop.self, forKey: .crop)?.clamped() ?? .full
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 24
        borderWidth = try container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        borderColor = try container.decodeIfPresent(HexColor.self, forKey: .borderHex) ?? .white
        shadowStrength = try container.decodeIfPresent(Double.self, forKey: .shadowStrength) ?? 0.28
        backgroundBlur = try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        insetOpacity = try container.decodeIfPresent(Double.self, forKey: .insetOpacity) ?? 0.125
        screenFrame = try container.decodeIfPresent(ScreenFrameStyle.self, forKey: .screenFrame)
            ?? .none
        screenFrameScale = min(max(
            try container.decodeIfPresent(Double.self, forKey: .screenFrameScale) ?? 1,
            0.6
        ), 1.6)
        screenFrameToolbarScale = min(max(
            try container.decodeIfPresent(Double.self, forKey: .screenFrameToolbarScale) ?? 1,
            0.65
        ), 1.6)
        screenFrameOuterCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .screenFrameOuterCornerRadius
        ).map { min(max($0, 0), 160) }
        screenFrameContentCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .screenFrameContentCornerRadius
        ).map { min(max($0, 0), 160) }
        screenFrameTitle = String((try container.decodeIfPresent(
            String.self,
            forKey: .screenFrameTitle
        ) ?? "").prefix(120))
        screenFrameBrowserAddress = String((try container.decodeIfPresent(
            String.self,
            forKey: .screenFrameBrowserAddress
        ) ?? "").prefix(240))
        patternScale = min(max(
            try container.decodeIfPresent(Double.self, forKey: .patternScale) ?? 1,
            0.4
        ), 6.0)
        patternOpacity = min(max(
            try container.decodeIfPresent(Double.self, forKey: .patternOpacity) ?? 1,
            0.0
        ), 1.0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(customAspectRatio, forKey: .customAspectRatio)
        try container.encode(backgroundSource, forKey: .backgroundSource)
        try container.encode(padding, forKey: .padding)
        try container.encode(contentScale, forKey: .contentScale)
        try container.encode(contentPosition, forKey: .contentPosition)
        try container.encode(crop.clamped(), forKey: .crop)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(borderColor, forKey: .borderHex)
        try container.encode(shadowStrength, forKey: .shadowStrength)
        try container.encode(backgroundBlur, forKey: .backgroundBlur)
        try container.encode(insetOpacity, forKey: .insetOpacity)
        try container.encode(screenFrame, forKey: .screenFrame)
        try container.encode(screenFrameScale, forKey: .screenFrameScale)
        try container.encode(screenFrameToolbarScale, forKey: .screenFrameToolbarScale)
        try container.encodeIfPresent(
            screenFrameOuterCornerRadius,
            forKey: .screenFrameOuterCornerRadius
        )
        try container.encodeIfPresent(
            screenFrameContentCornerRadius,
            forKey: .screenFrameContentCornerRadius
        )
        try container.encode(screenFrameTitle, forKey: .screenFrameTitle)
        try container.encode(screenFrameBrowserAddress, forKey: .screenFrameBrowserAddress)
        try container.encode(patternScale, forKey: .patternScale)
        try container.encode(patternOpacity, forKey: .patternOpacity)
    }

}

public struct CanvasDimensions: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public extension CanvasStyle {
    func pixelDimensions(
        resolution: CanvasResolution,
        sourceAspectRatio: Double? = nil,
        sourcePixelSize: CanvasDimensions? = nil
    ) -> CanvasDimensions {
        if resolution == .source {
            return sourcePixelDimensions(sourcePixelSize)
        }
        guard let preset = resolution.presetEdges else {
            return sourcePixelDimensions(sourcePixelSize)
        }
        let shortEdge = preset.short
        switch aspectRatio {
        case .adaptive:
            let ratio = min(max(sourceAspectRatio ?? (16.0 / 9.0), 0.2), 5)
            let longEdge = preset.long
            if ratio >= 1 {
                return CanvasDimensions(
                    width: even(longEdge),
                    height: even(Double(longEdge) / ratio)
                )
            }
            return CanvasDimensions(
                width: even(Double(longEdge) * ratio),
                height: even(longEdge)
            )
        case .landscape:
            return CanvasDimensions(width: shortEdge * 16 / 9, height: shortEdge)
        case .standard:
            return CanvasDimensions(width: shortEdge * 4 / 3, height: shortEdge)
        case .portrait:
            return CanvasDimensions(width: shortEdge, height: shortEdge * 16 / 9)
        case .square:
            return CanvasDimensions(width: shortEdge, height: shortEdge)
        case .standardPortrait:
            return CanvasDimensions(width: shortEdge, height: shortEdge * 4 / 3)
        case .cinema, .cinemaPortrait, .custom:
            let ratio = resolvedFixedAspectRatio ?? 1
            let long = Double(preset.long)
            return ratio >= 1
                ? CanvasDimensions(width: even(long), height: even(long / ratio))
                : CanvasDimensions(width: even(long * ratio), height: even(long))
        }
    }

    /// Resolves the full-quality canvas from the actual recorded pixels. A
    /// crop produces a correspondingly smaller native canvas; fixed aspect
    /// ratios fit inside that cropped pixel envelope and never upscale it.
    private func sourcePixelDimensions(
        _ sourcePixelSize: CanvasDimensions?
    ) -> CanvasDimensions {
        let source = sourcePixelSize ?? CanvasDimensions(width: 1_920, height: 1_080)
        let crop = crop.clamped()
        let croppedWidth = max(Double(source.width) * crop.width, 2)
        let croppedHeight = max(Double(source.height) * crop.height, 2)

        guard aspectRatio != .adaptive else {
            return CanvasDimensions(
                width: even(croppedWidth),
                height: even(croppedHeight)
            )
        }

        let targetRatio = resolvedFixedAspectRatio ?? croppedWidth / croppedHeight
        if croppedWidth / croppedHeight >= targetRatio {
            return CanvasDimensions(
                width: even(croppedHeight * targetRatio),
                height: even(croppedHeight)
            )
        }
        return CanvasDimensions(
            width: even(croppedWidth),
            height: even(croppedWidth / targetRatio)
        )
    }

    private func even(_ value: Double) -> Int {
        max(Int((value / 2).rounded()) * 2, 2)
    }

    private func even(_ value: Int) -> Int {
        max(value - value % 2, 2)
    }
}

public struct AudioStyle: Codable, Equatable, Sendable {
    public var isSystemMuted: Bool
    public var isMicrophoneMuted: Bool
    public var systemVolume: Double {
        didSet { systemVolume = min(max(systemVolume, 0), 1) }
    }
    public var microphoneVolume: Double {
        didSet { microphoneVolume = min(max(microphoneVolume, 0), 1) }
    }

    public init(
        systemVolume: Double = 0.82,
        microphoneVolume: Double = 0.9,
        isSystemMuted: Bool = false,
        isMicrophoneMuted: Bool = false
    ) {
        self.systemVolume = min(max(systemVolume, 0), 1)
        self.microphoneVolume = min(max(microphoneVolume, 0), 1)
        self.isSystemMuted = isSystemMuted
        self.isMicrophoneMuted = isMicrophoneMuted
    }

    private enum CodingKeys: String, CodingKey {
        case systemVolume, microphoneVolume, isSystemMuted, isMicrophoneMuted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            systemVolume: try container.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 0.82,
            microphoneVolume: try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 0.9,
            isSystemMuted: try container.decodeIfPresent(Bool.self, forKey: .isSystemMuted) ?? false,
            isMicrophoneMuted: try container.decodeIfPresent(Bool.self, forKey: .isMicrophoneMuted) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(systemVolume, forKey: .systemVolume)
        try container.encode(microphoneVolume, forKey: .microphoneVolume)
        try container.encode(isSystemMuted, forKey: .isSystemMuted)
        try container.encode(isMicrophoneMuted, forKey: .isMicrophoneMuted)
    }
}

public struct CameraStyle: Codable, Equatable, Sendable {
    public var shape: CameraShape
    public var position: NormalizedPoint
    public var size: Double
    public var borderWidth: Double
    public var shadowStrength: Double
    public var roundness: Double
    public var isMirrored: Bool
    public var isHidden: Bool
    public var scaleDuringZoom: Double
    /// Visual focus inside the camera mask. (0.5, 0.5) is the legacy centred
    /// aspect-fill; this is intentionally independent from `position`.
    public var contentPosition: NormalizedPoint
    /// Additional source zoom inside the camera mask. It never changes the
    /// mask's canvas rect.
    public var contentScale: Double

    public init(
        shape: CameraShape = .square,
        position: NormalizedPoint = NormalizedPoint(x: 0.96, y: 0.47),
        size: Double = 0.29,
        borderWidth: Double = 3,
        shadowStrength: Double = 0.25,
        roundness: Double = 0.5,
        isMirrored: Bool = true,
        isHidden: Bool = false,
        scaleDuringZoom: Double = 0.7,
        contentPosition: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        contentScale: Double = 1
    ) {
        self.shape = shape
        self.position = position
        self.size = size
        self.borderWidth = borderWidth
        self.shadowStrength = shadowStrength
        self.roundness = roundness
        self.isMirrored = isMirrored
        self.isHidden = isHidden
        self.scaleDuringZoom = scaleDuringZoom
        self.contentPosition = contentPosition
        self.contentScale = contentScale
    }

    private enum CodingKeys: String, CodingKey {
        case shape, position, size, borderWidth, shadowStrength
        case roundness, isMirrored, isHidden, scaleDuringZoom
        case contentPosition, contentScale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decodeIfPresent(CameraShape.self, forKey: .shape) ?? .square
        position = try container.decodeIfPresent(NormalizedPoint.self, forKey: .position)
            ?? NormalizedPoint(x: 0.96, y: 0.47)
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 0.29
        borderWidth = try container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 3
        shadowStrength = try container.decodeIfPresent(Double.self, forKey: .shadowStrength) ?? 0.25
        roundness = try container.decodeIfPresent(Double.self, forKey: .roundness) ?? 0.5
        isMirrored = try container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? true
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        scaleDuringZoom = try container.decodeIfPresent(Double.self, forKey: .scaleDuringZoom) ?? 0.7
        contentPosition = try container.decodeIfPresent(
            NormalizedPoint.self,
            forKey: .contentPosition
        ) ?? NormalizedPoint(x: 0.5, y: 0.5)
        contentScale = try container.decodeIfPresent(Double.self, forKey: .contentScale) ?? 1
    }
}

public struct MotionStyle: Codable, Equatable, Sendable {
    public var screen: ScreenMotionStyle
    public var cursor: CursorMotionStyle
    public var screenSpringMass: Double
    public var screenSpringStiffness: Double
    public var screenSpringDamping: Double
    public var cursorSpringMass: Double
    public var cursorSpringStiffness: Double
    public var cursorSpringDamping: Double
    public var defaultZoomEasing: ZoomEasingPreset
    public var defaultZoomTransitionDuration: TimeInterval
    /// Project-owned creation default. Older projects can still inherit the
    /// app's remembered magnification until they author or apply a preset.
    public var defaultZoomScale: Double?
    public var defaultScreenMotion: ScreenMotionCreationStyle?

    public init(
        screen: ScreenMotionStyle = .focused,
        cursor: CursorMotionStyle = .smooth,
        screenSpringMass: Double = 2.4,
        screenSpringStiffness: Double = 210,
        screenSpringDamping: Double = 42,
        cursorSpringMass: Double = 2.8,
        cursorSpringStiffness: Double = 450,
        cursorSpringDamping: Double = 66,
        defaultZoomEasing: ZoomEasingPreset = .spring,
        defaultZoomTransitionDuration: TimeInterval = 0.7,
        defaultZoomScale: Double? = nil,
        defaultScreenMotion: ScreenMotionCreationStyle? = nil
    ) {
        self.screen = screen
        self.cursor = cursor
        self.screenSpringMass = screenSpringMass
        self.screenSpringStiffness = screenSpringStiffness
        self.screenSpringDamping = screenSpringDamping
        self.cursorSpringMass = cursorSpringMass
        self.cursorSpringStiffness = cursorSpringStiffness
        self.cursorSpringDamping = cursorSpringDamping
        self.defaultZoomEasing = defaultZoomEasing
        self.defaultZoomTransitionDuration = min(max(defaultZoomTransitionDuration, 0), 5)
        self.defaultZoomScale = defaultZoomScale
        self.defaultScreenMotion = defaultScreenMotion
    }

    private enum CodingKeys: String, CodingKey {
        case screen, cursor
        case screenSpringMass, screenSpringStiffness, screenSpringDamping
        case cursorSpringMass, cursorSpringStiffness, cursorSpringDamping
        case defaultZoomEasing, defaultZoomTransitionDuration, defaultZoomScale, defaultScreenMotion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            screen: try container.decodeIfPresent(ScreenMotionStyle.self, forKey: .screen) ?? .focused,
            cursor: try container.decodeIfPresent(CursorMotionStyle.self, forKey: .cursor) ?? .smooth,
            screenSpringMass: try container.decodeIfPresent(Double.self, forKey: .screenSpringMass) ?? 2.4,
            screenSpringStiffness: try container.decodeIfPresent(Double.self, forKey: .screenSpringStiffness) ?? 210,
            screenSpringDamping: try container.decodeIfPresent(Double.self, forKey: .screenSpringDamping) ?? 42,
            cursorSpringMass: try container.decodeIfPresent(Double.self, forKey: .cursorSpringMass) ?? 2.8,
            cursorSpringStiffness: try container.decodeIfPresent(Double.self, forKey: .cursorSpringStiffness) ?? 450,
            cursorSpringDamping: try container.decodeIfPresent(Double.self, forKey: .cursorSpringDamping) ?? 66,
            defaultZoomEasing: try container.decodeIfPresent(ZoomEasingPreset.self, forKey: .defaultZoomEasing) ?? .spring,
            defaultZoomTransitionDuration: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .defaultZoomTransitionDuration
            ) ?? 0.7,
            defaultZoomScale: try container.decodeIfPresent(Double.self, forKey: .defaultZoomScale),
            defaultScreenMotion: try container.decodeIfPresent(ScreenMotionCreationStyle.self, forKey: .defaultScreenMotion)
        )
    }
}

/// One camera-clock correction authored against the original screen source
/// clock. `offset` is additional camera source time: positive values advance
/// the visible camera; negative values delay it.
