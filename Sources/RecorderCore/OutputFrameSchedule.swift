import Foundation

/// The single source of truth for an exported video's frame count and PTS values.
///
/// The schedule is end-exclusive: frame `n` exists exactly when
/// `0 <= n / frameRate < duration`. Presentation timestamps are derived from an
/// integer tick grid instead of accumulated floating-point frame durations.
public struct OutputFrameSchedule: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let presentationTimeValue: Int64
        public let presentationTimescale: Int32


        fileprivate init(
            presentationTimeValue: Int64,
            presentationTimescale: Int32
        ) {
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

        let count = Self.firstFrameIndex(atOrAfter: duration, frameRate: frameRate.rawValue)
        let frameCount = Int(count)

        if frameCount > 0 {
            let lastFrameIndex = Int64(frameCount - 1)
            guard lastFrameIndex <= Int64.max / ticksPerFrame else {
                throw Error.durationTooLong
            }
        }

        self.duration = duration
        self.frameCount = frameCount
        self.ticksPerFrame = ticksPerFrame
    }

    /// Also locates the displayed frames on either side of a camera handoff.
    static func firstFrameIndex(atOrAfter time: TimeInterval, frameRate: Int) -> Double {
        let scaled = time * Double(frameRate)
        // Values such as (1 / 90) * 90 are conceptually integral but can be a
        // handful of binary floating-point ulps away on a different platform or
        // after timeline arithmetic. Snap only that representation noise; unlike
        // a fixed epsilon, this cannot erase a real sub-1/60000-second tail.
        let nearest = scaled.rounded()
        return abs(scaled - nearest) <= 4 * max(scaled.ulp, nearest.ulp) ? nearest : scaled.rounded(.up)
    }

    public func frame(at index: Int) -> Frame? {
        guard index >= 0, index < frameCount else { return nil }
        return Frame(
            presentationTimeValue: Int64(index) * ticksPerFrame,
            presentationTimescale: Self.presentationTimescale
        )
    }
}
