import Foundation

/// Shared forward/inverse mapping for screen placement and canvas dragging.
public struct ScreenPlacementAxis: Equatable, Sendable {
    public var leadingCenter: Double
    public var middleCenter: Double
    public var trailingCenter: Double

    public init(canvasLength: Double, contentLength: Double, fittedCenter: Double,
                leadingInset: Double, trailingInset: Double) {
        leadingCenter = contentLength / 2 + leadingInset
        trailingCenter = canvasLength - contentLength / 2 - trailingInset
        // Keep the mapping invertible when an enlarged card crosses canvas size.
        let authoredCenter = fittedCenter + (leadingInset - trailingInset) / 2
        middleCenter = min(max(authoredCenter, min(leadingCenter, trailingCenter)),
                           max(leadingCenter, trailingCenter))
    }

    public func center(at position: Double) -> Double {
        position <= 0.5
            ? leadingCenter + position * 2 * (middleCenter - leadingCenter)
            : middleCenter + (position - 0.5) * 2 * (trailingCenter - middleCenter)
    }

    public func position(for center: Double) -> Double {
        let direction: Double = trailingCenter >= leadingCenter ? 1 : -1
        if center * direction <= middleCenter * direction {
            let travel = middleCenter - leadingCenter
            return abs(travel) > 0.000_1 ? (center - leadingCenter) / (travel * 2) : 0.5
        }
        let travel = trailingCenter - middleCenter
        return abs(travel) > 0.000_1 ? 0.5 + (center - middleCenter) / (travel * 2) : 0.5
    }

    public func travel(at position: Double) -> Double {
        let distance = position <= 0.5
            ? 2 * (middleCenter - leadingCenter)
            : 2 * (trailingCenter - middleCenter)
        return abs(distance) < 1 ? 1 : distance
    }
}
