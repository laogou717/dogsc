import Foundation

/// Authored against the canonical 1080-point short edge. Selecting a different
/// style starts from its design, rather than carrying another frame's overrides.
public struct ScreenFrameDefaults: Equatable, Sendable {
    public let frameScale: Double
    public let toolbarScale: Double
    public let outerRadius: Double
    public let contentRadius: Double
    public let shadowStrength: Double
    public let borderWidth: Double
    public let borderColor: HexColor

    public init(frameScale: Double = 1, toolbarScale: Double = 1,
                outerRadius: Double, contentRadius: Double,
                shadowStrength: Double = 0.24, borderWidth: Double = 0,
                borderColor: HexColor = .white) {
        self.frameScale = frameScale; self.toolbarScale = toolbarScale
        self.outerRadius = outerRadius; self.contentRadius = contentRadius
        self.shadowStrength = shadowStrength; self.borderWidth = borderWidth
        self.borderColor = borderColor
    }
}

public extension ScreenFrameStyle {
    var defaults: ScreenFrameDefaults {
        switch self {
        case .none: .init(outerRadius: 24, contentRadius: 24, shadowStrength: 0.28)
        case .windowLight: .init(toolbarScale: 0.90, outerRadius: 18, contentRadius: 0, shadowStrength: 0.22)
        case .windowDark: .init(toolbarScale: 0.90, outerRadius: 18, contentRadius: 0, shadowStrength: 0.30)
        case .browserLight: .init(toolbarScale: 1.08, outerRadius: 22, contentRadius: 0, shadowStrength: 0.22)
        case .browserDark: .init(toolbarScale: 1.08, outerRadius: 22, contentRadius: 0, shadowStrength: 0.30)
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape:
            .init(frameScale: 0.90, outerRadius: 64, contentRadius: 40, shadowStrength: 0.24)
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape:
            .init(outerRadius: 48, contentRadius: 24, shadowStrength: 0.24)
        }
    }
}

public extension CanvasStyle {
    mutating func applyScreenFrameStyle(_ style: ScreenFrameStyle) {
        let preset = style.defaults
        screenFrame = style
        screenFrameScale = preset.frameScale
        screenFrameToolbarScale = preset.toolbarScale
        screenFrameOuterCornerRadius = preset.outerRadius
        screenFrameContentCornerRadius = preset.contentRadius
        cornerRadius = preset.contentRadius
        borderWidth = preset.borderWidth
        borderColor = preset.borderColor
        shadowStrength = preset.shadowStrength
        // Title/address are authored content, not geometry presets. Crop,
        // placement, canvas ratio and background also belong to other tools.
    }
}
