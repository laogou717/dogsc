import Foundation

/// A media track's position on its asset timeline.
///
/// Keeping this type independent from Core Media lets the editor, timeline and
/// exporter share one validated time-domain value without leaking `CMTime` into
/// persisted project state or SwiftUI code.
public struct MediaTimeRange: Equatable, Sendable {
    public let start: TimeInterval
    public let duration: TimeInterval

    public init?(start: TimeInterval, duration: TimeInterval) {
        let end = start + duration
        guard start.isFinite,
              duration.isFinite,
              duration > 0,
              end.isFinite else { return nil }
        self.start = start
        self.duration = duration
    }

    public var end: TimeInterval {
        start + duration
    }

    /// Maps an absolute presentation timestamp into a fixed-size timeline
    /// bucket. The range is end-exclusive, matching Core Media time ranges.
    public func bucketIndex(
        forPresentationTime timestamp: TimeInterval,
        bucketCount: Int
    ) -> Int? {
        guard bucketCount > 0,
              timestamp.isFinite,
              timestamp >= start,
              timestamp < end else { return nil }
        let normalized = (timestamp - start) / duration
        return min(max(Int(normalized * Double(bucketCount)), 0), bucketCount - 1)
    }
}
