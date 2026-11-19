import Foundation

/// Only the physical travel changes; bindings, stored values and exact entry
/// remain in the parameter's original units.
enum EditorSliderScale {
    case linear
    case logarithmic(knee: Double)

    func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        let delta = min(max(value - range.lowerBound, 0), span)
        switch self {
        case .linear: return delta / span
        case let .logarithmic(knee):
            let knee = max(knee, 0.000001)
            return log1p(delta / knee) / log1p(span / knee)
        }
    }

    func value(_ fraction: Double, in range: ClosedRange<Double>) -> Double {
        let fraction = min(max(fraction, 0), 1)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        switch self {
        case .linear: return range.lowerBound + fraction * span
        case let .logarithmic(knee):
            let knee = max(knee, 0.000001)
            return min(range.lowerBound + knee * expm1(fraction * log1p(span / knee)), range.upperBound)
        }
    }

}

extension EditorSliderValueFormat {
    func sliderScale(in range: ClosedRange<Double>) -> EditorSliderScale {
        guard range.lowerBound >= 0 else { return .linear }
        switch self {
        case .multiplier: return .logarithmic(knee: 1)
        case .seconds: return .logarithmic(knee: 0.5)
        case .points: return .logarithmic(knee: max((range.upperBound - range.lowerBound) / 8, 1))
        // Opacity, volume, positions and signed angles retain meaningful
        // quarter/centre marks instead of giving 50% a surprising location.
        default: return .linear
        }
    }
}
