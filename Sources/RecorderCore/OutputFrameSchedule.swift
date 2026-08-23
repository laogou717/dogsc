import Foundation

/// The single source of truth for an exported video's frame count and PTS values.
///
/// The schedule is end-exclusive: frame `n` exists exactly when
/// `0 <= n / frameRate < duration`. Presentation timestamps are derived from an
/// integer tick grid instead of accumulated floating-point frame durations.
public struct OutputFrameSchedule: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let index: Int
        public let presentationTimeValue: Int64
        public let presentationTimescale: Int32

        public var presentationTimeSeconds: TimeInterval {
            TimeInterval(presentationTimeValue) / TimeInterval(presentationTimescale)
        }

        fileprivate init(
            index: Int,
            presentationTimeValue: Int64,
            presentationTimescale: Int32
        ) {
            self.index = index
            self.presentationTimeValue = presentationTimeValue
            self.presentationTimescale = presentationTimescale
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidDuration
        case durationTooLong
    }

    /// 90,000 is exactly divisible by every supported output rate: 60, 90, and 120.
    public static let presentationTimescale: Int32 = 90_000

    public let duration: TimeInterval
    public let frameRate: OutputFrameRate
    public let frameCount: Int
    public let ticksPerFrame: Int64

    public init(duration: TimeInterval, frameRate: OutputFrameRate) throws {
        guard duration.isFinite, duration >= 0 else {
            throw Error.invalidDuration
        }

        let timescale = Int64(Self.presentationTimescale)
        let rate = Int64(frameRate.rawValue)
        precondition(timescale.isMultiple(of: rate))

        let ticksPerFrame = timescale / rate
        let scaledDuration = duration * TimeInterval(frameRate.rawValue)
        let maximumFrameCount = Int64.max / ticksPerFrame + 1
        guard scaledDuration.isFinite,
              scaledDuration <= TimeInterval(maximumFrameCount) else {
            throw Error.durationTooLong
        }

        // Values such as (1 / 90) * 90 are conceptually integral but can be a
        // handful of binary floating-point ulps away on a different platform or
        // after timeline arithmetic. Snap only that representation noise; unlike
        // a fixed epsilon, this cannot erase a real sub-1/60000-second tail.
        let nearestInteger = scaledDuration.rounded()
        let boundaryTolerance = max(
            scaledDuration.ulp * 4,
            nearestInteger.ulp * 4
        )
        let boundarySafeDuration = abs(scaledDuration - nearestInteger) <= boundaryTolerance
            ? nearestInteger
            : scaledDuration
        let frameCount = boundarySafeDuration > 0
            ? Int(boundarySafeDuration.rounded(.up))
            : 0

        if frameCount > 0 {
            let lastFrameIndex = Int64(frameCount - 1)
            guard lastFrameIndex <= Int64.max / ticksPerFrame else {
                throw Error.durationTooLong
            }
        }

        self.duration = duration
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.ticksPerFrame = ticksPerFrame
    }

    public func frame(at index: Int) -> Frame? {
        guard index >= 0, index < frameCount else { return nil }
        return Frame(
            index: index,
            presentationTimeValue: Int64(index) * ticksPerFrame,
            presentationTimescale: Self.presentationTimescale
        )
    }
}
