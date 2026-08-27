import Foundation

/// Layer-local transform motion blur. New recordings enable it by default,
/// while an existing project's persisted switch is always respected.
public struct MotionBlurDescriptor: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Product-facing 0...1 multiplier applied to the per-frame layer motion.
    public var strength: Double

    public init(
        isEnabled: Bool = true,
        strength: Double = 0.5
    ) {
        self.isEnabled = isEnabled
        self.strength = min(max(strength.isFinite ? strength : 0.5, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case strength
        // Version 8 compatibility. These keys are decoded but never emitted.
        case shutterAngle
        case sampleCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyShutter = try container.decodeIfPresent(
            Double.self,
            forKey: .shutterAngle
        )
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            strength: try container.decodeIfPresent(Double.self, forKey: .strength)
                ?? min(max((legacyShutter ?? 180) / 360, 0), 1)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(strength, forKey: .strength)
    }
}
