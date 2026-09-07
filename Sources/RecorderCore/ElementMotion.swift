import Foundation

/// A reusable timing language for authored element entrances and exits.
///
/// Direction and distance still belong to the visual preset (for example a
/// sticker sliding from the left or a screen using the light-3D opening).
/// This value owns only how progress travels through that path, which lets
/// otherwise different elements share a predictable motion rhythm.
public enum ElementMotionCurve: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Slow at both ends. Best for restrained presentation graphics.
    case smooth
    /// Starts decisively and settles gently. This preserves the historical
    /// DogSC sticker/opening rhythm and remains the compatibility default.
    case swift
    /// A softer ease-out with less initial acceleration than ``swift``.
    case gentle

    public var id: String { rawValue }
}

enum ElementMotionEvaluator {
    /// Evaluates a normalized progress value without depending on any render
    /// backend. Exit animation passes its remaining progress (1 -> 0), so the
    /// same curve naturally settles at the target before accelerating away.
    static func progress(_ linearProgress: Double, curve: ElementMotionCurve) -> Double {
        let x = min(max(linearProgress.isFinite ? linearProgress : 0, 0), 1)
        switch curve {
        case .smooth:
            return x * x * x * (x * (x * 6 - 15) + 10)
        case .swift:
            return 1 - pow(1 - x, 4)
        case .gentle:
            return 1 - pow(1 - x, 3)
        }
    }
}
