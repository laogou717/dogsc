import Foundation

public struct CameraBeautySettings: Codable, Equatable, Sendable {
    public var smoothing: Double { didSet { smoothing = Self.strength(smoothing) } }
    public var whitening: Double { didSet { whitening = Self.strength(whitening) } }
    public var isEnabled: Bool { smoothing > 0 || whitening > 0 }

    public init(smoothing: Double = 0, whitening: Double = 0) {
        self.smoothing = Self.strength(smoothing)
        self.whitening = Self.strength(whitening)
    }

    private enum CodingKeys: String, CodingKey { case smoothing, whitening }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(smoothing: try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0,
                  whitening: try c.decodeIfPresent(Double.self, forKey: .whitening) ?? 0)
    }

    private static func strength(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
