import Foundation

/// Explicit opt-in temporal motion blur.
///
/// The old `MotionStyle.motionBlur` scalar is a decode/compatibility value and
/// must never silently enable an effect for existing projects. Renderers only
/// consume this descriptor when `isEnabled` is true.
public struct MotionBlurDescriptor: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Exposure interval expressed like a camera shutter. 180° samples half of
    /// one output-frame interval; 360° samples one full frame interval.
    public var shutterAngle: Double
    /// Deterministic temporal samples consumed by both preview and export.
    /// Raising this value improves accumulation quality at a proportional
    /// rendering cost.
    public var sampleCount: Int

    public init(
        isEnabled: Bool = false,
        shutterAngle: Double = 180,
        sampleCount: Int = 8
    ) {
        self.isEnabled = isEnabled
        self.shutterAngle = min(max(shutterAngle.isFinite ? shutterAngle : 180, 0), 360)
        self.sampleCount = min(max(sampleCount, 2), 32)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case shutterAngle
        case sampleCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            shutterAngle: try container.decodeIfPresent(Double.self, forKey: .shutterAngle) ?? 180,
            sampleCount: try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 8
        )
    }
}

public struct MotionBlurSample: Equatable, Sendable {
    public var time: TimeInterval
    public var weight: Double

    public init(time: TimeInterval, weight: Double) {
        self.time = time
        self.weight = weight
    }
}

/// Shared temporal sampling policy. Samples trail the presentation time so a
/// real-time preview never needs a future decoded frame; export uses the same
/// shutter interval and therefore cannot produce a different motion shape.
///
/// MOT-002/PRE-004/PRE-007: UI recordings need a readable current image under
/// motion. Treating every historical pose as equally opaque turns black text
/// into a pale box blur when a large zoom and 3D move overlap; increasing the
/// preview raster cannot recover that lost contrast. The presentation sample
/// therefore remains the visual anchor and the shutter angle controls the
/// strength of the trailing history. At 180 degrees the current pose owns 75%
/// of the frame; at the maximum 360 degrees it still owns 50%.
public enum MotionBlurSampler {
    public static func samples(
        at presentationTime: TimeInterval,
        frameRate: Int,
        duration: TimeInterval,
        descriptor: MotionBlurDescriptor
    ) -> [MotionBlurSample] {
        let safeTime = presentationTime.isFinite ? max(presentationTime, 0) : 0
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        let clampedTime = min(safeTime, safeDuration)
        guard descriptor.isEnabled,
              frameRate > 0,
              descriptor.shutterAngle > 0 else {
            return [MotionBlurSample(time: clampedTime, weight: 1)]
        }

        let sampleCount = min(max(descriptor.sampleCount, 2), 32)
        let exposure = descriptor.shutterAngle / 360 / Double(frameRate)
        let trailStrength = min(max(descriptor.shutterAngle / 360, 0), 1) * 0.5
        let historyCount = sampleCount - 1
        let historyWeight = trailStrength / Double(historyCount)
        var samples = (0..<historyCount).map { index in
            let phase = (Double(index) + 0.5) / Double(historyCount)
            let sampleTime = clampedTime - exposure + exposure * phase
            return MotionBlurSample(
                time: min(max(sampleTime, 0), safeDuration),
                weight: historyWeight
            )
        }
        samples.append(MotionBlurSample(
            time: clampedTime,
            weight: 1 - trailStrength
        ))
        return samples
    }
}
