import Foundation

/// Persistable evidence for one real-time audio writer. Audio callbacks are
/// packet based, so counts describe sample buffers rather than PCM frames.
public struct AudioCaptureDiagnostics: Codable, Equatable, Sendable {
    public let receivedSampleBuffers: Int
    public let appendedSampleBuffers: Int
    public let ingressDrops: Int
    public let writerBackpressureDrops: Int
    public let invalidTimestampDrops: Int
    public let nonMonotonicTimestampDrops: Int
    public let formatChangeDrops: Int
    public let otherDrops: Int
    public let elapsed: TimeInterval
    public let maximumSampleInterval: TimeInterval

    public init(
        receivedSampleBuffers: Int,
        appendedSampleBuffers: Int,
        ingressDrops: Int = 0,
        writerBackpressureDrops: Int = 0,
        invalidTimestampDrops: Int = 0,
        nonMonotonicTimestampDrops: Int = 0,
        formatChangeDrops: Int = 0,
        otherDrops: Int = 0,
        elapsed: TimeInterval,
        maximumSampleInterval: TimeInterval = 0
    ) {
        self.receivedSampleBuffers = max(receivedSampleBuffers, 0)
        self.appendedSampleBuffers = max(appendedSampleBuffers, 0)
        self.ingressDrops = max(ingressDrops, 0)
        self.writerBackpressureDrops = max(writerBackpressureDrops, 0)
        self.invalidTimestampDrops = max(invalidTimestampDrops, 0)
        self.nonMonotonicTimestampDrops = max(nonMonotonicTimestampDrops, 0)
        self.formatChangeDrops = max(formatChangeDrops, 0)
        self.otherDrops = max(otherDrops, 0)
        self.elapsed = max(elapsed.isFinite ? elapsed : 0, 0)
        self.maximumSampleInterval = max(
            maximumSampleInterval.isFinite ? maximumSampleInterval : 0,
            0
        )
    }

    public var totalDroppedSampleBuffers: Int {
        ingressDrops
            + writerBackpressureDrops
            + invalidTimestampDrops
            + nonMonotonicTimestampDrops
            + formatChangeDrops
            + otherDrops
    }

    public var appendedSampleBuffersPerSecond: Double {
        guard elapsed > 0 else { return 0 }
        return Double(appendedSampleBuffers) / elapsed
    }
}
