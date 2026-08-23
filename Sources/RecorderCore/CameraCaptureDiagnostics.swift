import Foundation

/// Persistable evidence for one camera recording. It lives in RecorderCore so
/// the standalone project-store verifier and the signed App share the exact
/// same recovery-manifest schema.
public struct CameraCaptureDiagnostics: Codable, Equatable, Sendable {
    public let receivedFrames: Int
    public let appendedFrames: Int
    public let systemLateDrops: Int
    public let systemOutOfBufferDrops: Int
    public let systemDiscontinuityDrops: Int
    public let systemUnknownDrops: Int
    public let encoderBackpressureDrops: Int
    public let nonMonotonicTimestampDrops: Int
    /// Samples rejected before preview/encoding because Core Media had not
    /// made their data ready or the CVPixelBuffer layout was structurally
    /// incomplete. Keeping this separate from device/system drops identifies
    /// reconnect and format-renegotiation failures after a recording ends.
    public let invalidSampleDrops: Int
    public let normalizedFrames: Int
    public let formatChanges: Int
    public let initialWidth: Int?
    public let initialHeight: Int?
    public let finalWidth: Int?
    public let finalHeight: Int?
    public let initialPixelFormat: UInt32?
    public let finalPixelFormat: UInt32?
    public let initialPlaneCount: Int?
    public let finalPlaneCount: Int?
    public let initialBytesPerRow: [Int]?
    public let finalBytesPerRow: [Int]?
    public let elapsed: TimeInterval
    public let maximumFrameInterval: TimeInterval
    /// AVCaptureSession stopped delivering because the device was interrupted
    /// (for example another client took the camera).
    public let sessionInterruptionCount: Int
    /// Runtime failures reported by AVCaptureSession's notification channel.
    public let sessionRuntimeErrorCount: Int

    public init(
        receivedFrames: Int,
        appendedFrames: Int,
        systemLateDrops: Int,
        systemOutOfBufferDrops: Int,
        systemDiscontinuityDrops: Int,
        systemUnknownDrops: Int,
        encoderBackpressureDrops: Int,
        nonMonotonicTimestampDrops: Int,
        invalidSampleDrops: Int = 0,
        normalizedFrames: Int,
        formatChanges: Int,
        initialWidth: Int?,
        initialHeight: Int?,
        finalWidth: Int?,
        finalHeight: Int?,
        initialPixelFormat: UInt32? = nil,
        finalPixelFormat: UInt32? = nil,
        initialPlaneCount: Int? = nil,
        finalPlaneCount: Int? = nil,
        initialBytesPerRow: [Int]? = nil,
        finalBytesPerRow: [Int]? = nil,
        elapsed: TimeInterval,
        maximumFrameInterval: TimeInterval,
        sessionInterruptionCount: Int = 0,
        sessionRuntimeErrorCount: Int = 0
    ) {
        self.receivedFrames = receivedFrames
        self.appendedFrames = appendedFrames
        self.systemLateDrops = systemLateDrops
        self.systemOutOfBufferDrops = systemOutOfBufferDrops
        self.systemDiscontinuityDrops = systemDiscontinuityDrops
        self.systemUnknownDrops = systemUnknownDrops
        self.encoderBackpressureDrops = encoderBackpressureDrops
        self.nonMonotonicTimestampDrops = nonMonotonicTimestampDrops
        self.invalidSampleDrops = invalidSampleDrops
        self.normalizedFrames = normalizedFrames
        self.formatChanges = formatChanges
        self.initialWidth = initialWidth
        self.initialHeight = initialHeight
        self.finalWidth = finalWidth
        self.finalHeight = finalHeight
        self.initialPixelFormat = initialPixelFormat
        self.finalPixelFormat = finalPixelFormat
        self.initialPlaneCount = initialPlaneCount
        self.finalPlaneCount = finalPlaneCount
        self.initialBytesPerRow = initialBytesPerRow
        self.finalBytesPerRow = finalBytesPerRow
        self.elapsed = elapsed
        self.maximumFrameInterval = maximumFrameInterval
        self.sessionInterruptionCount = sessionInterruptionCount
        self.sessionRuntimeErrorCount = sessionRuntimeErrorCount
    }

    public var systemDroppedFrames: Int {
        systemLateDrops
            + systemOutOfBufferDrops
            + systemDiscontinuityDrops
            + systemUnknownDrops
    }

    public var applicationDroppedFrames: Int {
        encoderBackpressureDrops
            + nonMonotonicTimestampDrops
            + invalidSampleDrops
    }

    public var receivedFramesPerSecond: Double {
        guard elapsed > 0, receivedFrames > 1 else { return 0 }
        return Double(receivedFrames - 1) / elapsed
    }

    public var appendedFramesPerSecond: Double {
        guard elapsed > 0, appendedFrames > 1 else { return 0 }
        return Double(appendedFrames - 1) / elapsed
    }


    private enum CodingKeys: String, CodingKey {
        case receivedFrames, appendedFrames
        case systemLateDrops, systemOutOfBufferDrops
        case systemDiscontinuityDrops, systemUnknownDrops
        case encoderBackpressureDrops, nonMonotonicTimestampDrops
        case invalidSampleDrops, normalizedFrames, formatChanges
        case initialWidth, initialHeight, finalWidth, finalHeight
        case initialPixelFormat, finalPixelFormat
        case initialPlaneCount, finalPlaneCount
        case initialBytesPerRow, finalBytesPerRow
        case elapsed, maximumFrameInterval
        case sessionInterruptionCount, sessionRuntimeErrorCount
    }

    /// Recovery manifests written before the integrity gate do not contain the
    /// new layout fields. Decode those projects with neutral defaults instead
    /// of turning diagnostics evolution into a project compatibility break.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        receivedFrames = try values.decode(Int.self, forKey: .receivedFrames)
        appendedFrames = try values.decode(Int.self, forKey: .appendedFrames)
        systemLateDrops = try values.decode(Int.self, forKey: .systemLateDrops)
        systemOutOfBufferDrops = try values.decode(Int.self, forKey: .systemOutOfBufferDrops)
        systemDiscontinuityDrops = try values.decode(Int.self, forKey: .systemDiscontinuityDrops)
        systemUnknownDrops = try values.decode(Int.self, forKey: .systemUnknownDrops)
        encoderBackpressureDrops = try values.decode(Int.self, forKey: .encoderBackpressureDrops)
        nonMonotonicTimestampDrops = try values.decode(
            Int.self,
            forKey: .nonMonotonicTimestampDrops
        )
        invalidSampleDrops = try values.decodeIfPresent(
            Int.self,
            forKey: .invalidSampleDrops
        ) ?? 0
        normalizedFrames = try values.decode(Int.self, forKey: .normalizedFrames)
        formatChanges = try values.decode(Int.self, forKey: .formatChanges)
        initialWidth = try values.decodeIfPresent(Int.self, forKey: .initialWidth)
        initialHeight = try values.decodeIfPresent(Int.self, forKey: .initialHeight)
        finalWidth = try values.decodeIfPresent(Int.self, forKey: .finalWidth)
        finalHeight = try values.decodeIfPresent(Int.self, forKey: .finalHeight)
        initialPixelFormat = try values.decodeIfPresent(UInt32.self, forKey: .initialPixelFormat)
        finalPixelFormat = try values.decodeIfPresent(UInt32.self, forKey: .finalPixelFormat)
        initialPlaneCount = try values.decodeIfPresent(Int.self, forKey: .initialPlaneCount)
        finalPlaneCount = try values.decodeIfPresent(Int.self, forKey: .finalPlaneCount)
        initialBytesPerRow = try values.decodeIfPresent([Int].self, forKey: .initialBytesPerRow)
        finalBytesPerRow = try values.decodeIfPresent([Int].self, forKey: .finalBytesPerRow)
        elapsed = try values.decode(TimeInterval.self, forKey: .elapsed)
        maximumFrameInterval = try values.decode(
            TimeInterval.self,
            forKey: .maximumFrameInterval
        )
        sessionInterruptionCount = try values.decodeIfPresent(
            Int.self,
            forKey: .sessionInterruptionCount
        ) ?? 0
        sessionRuntimeErrorCount = try values.decodeIfPresent(
            Int.self,
            forKey: .sessionRuntimeErrorCount
        ) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(receivedFrames, forKey: .receivedFrames)
        try values.encode(appendedFrames, forKey: .appendedFrames)
        try values.encode(systemLateDrops, forKey: .systemLateDrops)
        try values.encode(systemOutOfBufferDrops, forKey: .systemOutOfBufferDrops)
        try values.encode(systemDiscontinuityDrops, forKey: .systemDiscontinuityDrops)
        try values.encode(systemUnknownDrops, forKey: .systemUnknownDrops)
        try values.encode(encoderBackpressureDrops, forKey: .encoderBackpressureDrops)
        try values.encode(nonMonotonicTimestampDrops, forKey: .nonMonotonicTimestampDrops)
        try values.encode(invalidSampleDrops, forKey: .invalidSampleDrops)
        try values.encode(normalizedFrames, forKey: .normalizedFrames)
        try values.encode(formatChanges, forKey: .formatChanges)
        try values.encodeIfPresent(initialWidth, forKey: .initialWidth)
        try values.encodeIfPresent(initialHeight, forKey: .initialHeight)
        try values.encodeIfPresent(finalWidth, forKey: .finalWidth)
        try values.encodeIfPresent(finalHeight, forKey: .finalHeight)
        try values.encodeIfPresent(initialPixelFormat, forKey: .initialPixelFormat)
        try values.encodeIfPresent(finalPixelFormat, forKey: .finalPixelFormat)
        try values.encodeIfPresent(initialPlaneCount, forKey: .initialPlaneCount)
        try values.encodeIfPresent(finalPlaneCount, forKey: .finalPlaneCount)
        try values.encodeIfPresent(initialBytesPerRow, forKey: .initialBytesPerRow)
        try values.encodeIfPresent(finalBytesPerRow, forKey: .finalBytesPerRow)
        try values.encode(elapsed, forKey: .elapsed)
        try values.encode(maximumFrameInterval, forKey: .maximumFrameInterval)
        try values.encode(sessionInterruptionCount, forKey: .sessionInterruptionCount)
        try values.encode(sessionRuntimeErrorCount, forKey: .sessionRuntimeErrorCount)
    }
}
