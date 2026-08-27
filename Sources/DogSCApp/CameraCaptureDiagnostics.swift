import CoreMedia
import CoreVideo
import Foundation
import RecorderCore
import os

struct CameraPixelBufferLayout: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let planeCount: Int
    let planeWidths: [Int]
    let planeHeights: [Int]
    let bytesPerRow: [Int]

    init(_ imageBuffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(imageBuffer)
        height = CVPixelBufferGetHeight(imageBuffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
        if planeCount > 0 {
            planeWidths = (0..<planeCount).map {
                CVPixelBufferGetWidthOfPlane(imageBuffer, $0)
            }
            planeHeights = (0..<planeCount).map {
                CVPixelBufferGetHeightOfPlane(imageBuffer, $0)
            }
            bytesPerRow = (0..<planeCount).map {
                CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, $0)
            }
        } else {
            planeWidths = [width]
            planeHeights = [height]
            bytesPerRow = [CVPixelBufferGetBytesPerRow(imageBuffer)]
        }
    }

    init(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        planeCount: Int,
        planeWidths: [Int],
        planeHeights: [Int],
        bytesPerRow: [Int]
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.planeCount = planeCount
        self.planeWidths = planeWidths
        self.planeHeights = planeHeights
        self.bytesPerRow = bytesPerRow
    }

    /// Validate metadata only. Locking and scanning a 1080p pixel buffer on
    /// the capture callback would itself cause dropped frames.
    var isStructurallyValid: Bool {
        guard width > 0, height > 0,
              !planeWidths.isEmpty,
              planeWidths.count == planeHeights.count,
              planeWidths.count == bytesPerRow.count,
              planeWidths.allSatisfy({ $0 > 0 }),
              planeHeights.allSatisfy({ $0 > 0 }),
              bytesPerRow.allSatisfy({ $0 > 0 }) else { return false }

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return planeCount == 2
                && planeWidths[0] == width
                && planeHeights[0] == height
                && planeWidths[1] * 2 >= width
                && planeHeights[1] * 2 >= height
                && bytesPerRow[0] >= width
                && bytesPerRow[1] >= width
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            return planeCount == 0 && bytesPerRow[0] >= width * 4
        default:
            return planeCount == 0 || planeCount == planeWidths.count
        }
    }

    /// Compares the current buffer's metadata without constructing new Swift
    /// arrays. Stable camera formats therefore reuse one validated layout for
    /// the complete run, while any plane/stride renegotiation rebuilds and
    /// revalidates the contract before preview or encoding sees the sample.
    func matchesMetadata(of imageBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(imageBuffer) == width,
              CVPixelBufferGetHeight(imageBuffer) == height,
              CVPixelBufferGetPixelFormatType(imageBuffer) == pixelFormat,
              CVPixelBufferGetPlaneCount(imageBuffer) == planeCount else { return false }
        if planeCount == 0 {
            return planeWidths.count == 1
                && planeWidths[0] == width
                && planeHeights.count == 1
                && planeHeights[0] == height
                && bytesPerRow.count == 1
                && CVPixelBufferGetBytesPerRow(imageBuffer) == bytesPerRow[0]
        }
        guard planeWidths.count == planeCount,
              planeHeights.count == planeCount,
              bytesPerRow.count == planeCount else { return false }
        for plane in 0..<planeCount {
            guard CVPixelBufferGetWidthOfPlane(imageBuffer, plane) == planeWidths[plane],
                  CVPixelBufferGetHeightOfPlane(imageBuffer, plane) == planeHeights[plane],
                  CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, plane) == bytesPerRow[plane]
            else { return false }
        }
        return true
    }
}

final class CameraSampleIntegrityGate {
    private(set) var cachedLayout: CameraPixelBufferLayout?

    func validatedImageBuffer(
        from sampleBuffer: CMSampleBuffer
    ) -> (imageBuffer: CVPixelBuffer, layout: CameraPixelBufferLayout)? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let layout: CameraPixelBufferLayout
        if let cachedLayout, cachedLayout.matchesMetadata(of: imageBuffer) {
            layout = cachedLayout
        } else {
            layout = CameraPixelBufferLayout(imageBuffer)
        }
        guard layout.isStructurallyValid else { return nil }
        cachedLayout = layout
        return (imageBuffer, layout)
    }

    func reset() {
        cachedLayout = nil
    }
}

enum CameraSystemDropReason: String, Codable, Equatable, Sendable {
    case late
    case outOfBuffers
    case discontinuity
    case unknown
}

struct CameraCaptureDiagnosticsAccumulator: Equatable, Sendable {
    private(set) var receivedFrames = 0
    private(set) var appendedFrames = 0
    private(set) var systemLateDrops = 0
    private(set) var systemOutOfBufferDrops = 0
    private(set) var systemDiscontinuityDrops = 0
    private(set) var systemUnknownDrops = 0
    private(set) var encoderBackpressureDrops = 0
    private(set) var nonMonotonicTimestampDrops = 0
    private(set) var invalidSampleDrops = 0
    private(set) var normalizedFrames = 0
    private(set) var formatChanges = 0
    private(set) var sessionInterruptionCount = 0
    private(set) var sessionRuntimeErrorCount = 0
    private(set) var initialWidth: Int?
    private(set) var initialHeight: Int?
    private(set) var finalWidth: Int?
    private(set) var finalHeight: Int?
    private(set) var initialPixelFormat: UInt32?
    private(set) var finalPixelFormat: UInt32?
    private(set) var initialPlaneCount: Int?
    private(set) var finalPlaneCount: Int?
    private(set) var initialBytesPerRow: [Int]?
    private(set) var finalBytesPerRow: [Int]?
    private(set) var accumulatedActiveElapsed: TimeInterval = 0
    private(set) var intervalRunFirstEventHostTime: TimeInterval?
    private(set) var intervalRunLastEventHostTime: TimeInterval?
    private(set) var lastReceivedHostTime: TimeInterval?
    private(set) var maximumFrameInterval: TimeInterval = 0

    mutating func recordReceived(hostTime: TimeInterval, layout: CameraPixelBufferLayout) {
        guard hostTime.isFinite, layout.isStructurallyValid else { return }
        recordEvent(hostTime: hostTime)
        if let previous = lastReceivedHostTime, hostTime > previous {
            maximumFrameInterval = max(maximumFrameInterval, hostTime - previous)
        }
        lastReceivedHostTime = hostTime
        receivedFrames += 1
        if initialWidth == nil || initialHeight == nil {
            initialWidth = layout.width
            initialHeight = layout.height
            initialPixelFormat = UInt32(layout.pixelFormat)
            initialPlaneCount = layout.planeCount
            initialBytesPerRow = layout.bytesPerRow
        } else if finalWidth != layout.width
            || finalHeight != layout.height
            || finalPixelFormat != UInt32(layout.pixelFormat)
            || finalPlaneCount != layout.planeCount
            || finalBytesPerRow != layout.bytesPerRow {
            formatChanges += 1
        }
        finalWidth = layout.width
        finalHeight = layout.height
        finalPixelFormat = UInt32(layout.pixelFormat)
        finalPlaneCount = layout.planeCount
        finalBytesPerRow = layout.bytesPerRow
    }

    mutating func recordSystemDrop(
        hostTime: TimeInterval?,
        reason: CameraSystemDropReason
    ) {
        if let hostTime, hostTime.isFinite { recordEvent(hostTime: hostTime) }
        switch reason {
        case .late: systemLateDrops += 1
        case .outOfBuffers: systemOutOfBufferDrops += 1
        case .discontinuity: systemDiscontinuityDrops += 1
        case .unknown: systemUnknownDrops += 1
        }
    }

    mutating func recordEncoderBackpressureDrop() {
        encoderBackpressureDrops += 1
    }

    mutating func recordNonMonotonicTimestampDrop() {
        nonMonotonicTimestampDrops += 1
    }

    mutating func recordInvalidSampleDrop() {
        invalidSampleDrops += 1
    }

    mutating func recordNormalizedFrame() {
        normalizedFrames += 1
    }

    mutating func recordAppendedFrame() {
        appendedFrames += 1
    }

    mutating func recordSessionInterruption() {
        sessionInterruptionCount += 1
    }

    mutating func recordSessionRuntimeError() {
        sessionRuntimeErrorCount += 1
    }

    /// A deliberate recording pause is not a capture stall. The first sample
    /// after resume starts a new interval run while elapsed time continues to
    /// be represented by the writer's own pause-compensated clock.
    mutating func beginNewIntervalRun() {
        finishCurrentIntervalRun()
        lastReceivedHostTime = nil
    }

    func snapshot() -> CameraCaptureDiagnostics? {
        let totalDrops = systemLateDrops
            + systemOutOfBufferDrops
            + systemDiscontinuityDrops
            + systemUnknownDrops
            + encoderBackpressureDrops
            + nonMonotonicTimestampDrops
            + invalidSampleDrops
        guard receivedFrames > 0
                || appendedFrames > 0
                || totalDrops > 0
                || sessionInterruptionCount > 0
                || sessionRuntimeErrorCount > 0
        else { return nil }
        let currentRunElapsed = intervalRunFirstEventHostTime.flatMap { first in
            intervalRunLastEventHostTime.map { max($0 - first, 0) }
        } ?? 0
        let elapsed = accumulatedActiveElapsed + currentRunElapsed
        return CameraCaptureDiagnostics(
            receivedFrames: receivedFrames,
            appendedFrames: appendedFrames,
            systemLateDrops: systemLateDrops,
            systemOutOfBufferDrops: systemOutOfBufferDrops,
            systemDiscontinuityDrops: systemDiscontinuityDrops,
            systemUnknownDrops: systemUnknownDrops,
            encoderBackpressureDrops: encoderBackpressureDrops,
            nonMonotonicTimestampDrops: nonMonotonicTimestampDrops,
            invalidSampleDrops: invalidSampleDrops,
            normalizedFrames: normalizedFrames,
            formatChanges: formatChanges,
            initialWidth: initialWidth,
            initialHeight: initialHeight,
            finalWidth: finalWidth,
            finalHeight: finalHeight,
            initialPixelFormat: initialPixelFormat,
            finalPixelFormat: finalPixelFormat,
            initialPlaneCount: initialPlaneCount,
            finalPlaneCount: finalPlaneCount,
            initialBytesPerRow: initialBytesPerRow,
            finalBytesPerRow: finalBytesPerRow,
            elapsed: elapsed,
            maximumFrameInterval: maximumFrameInterval,
            sessionInterruptionCount: sessionInterruptionCount,
            sessionRuntimeErrorCount: sessionRuntimeErrorCount
        )
    }

    private mutating func recordEvent(hostTime: TimeInterval) {
        intervalRunFirstEventHostTime = intervalRunFirstEventHostTime ?? hostTime
        intervalRunLastEventHostTime = max(intervalRunLastEventHostTime ?? hostTime, hostTime)
    }

    private mutating func finishCurrentIntervalRun() {
        if let first = intervalRunFirstEventHostTime,
           let last = intervalRunLastEventHostTime {
            accumulatedActiveElapsed += max(last - first, 0)
        }
        intervalRunFirstEventHostTime = nil
        intervalRunLastEventHostTime = nil
    }
}

/// Owns one recording's diagnostics lifecycle and its rate-limited telemetry.
/// `CameraRecorder` only reports capture events; it no longer coordinates four
/// independent counters/snapshots alongside the recording state machine.
final class CameraCaptureDiagnosticsMonitor {
#if DEBUG
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "camera-recorder"
    )
#endif

    private var current = CameraCaptureDiagnosticsAccumulator()
    private var lastCompleted: CameraCaptureDiagnostics?
#if DEBUG
    private var lastLogged: CameraCaptureDiagnostics?
    private var lastLogHostTime: TimeInterval?
#endif

    var snapshot: CameraCaptureDiagnostics? {
        current.snapshot() ?? lastCompleted
    }

    func beginRecording() {
        current = CameraCaptureDiagnosticsAccumulator()
        lastCompleted = nil
#if DEBUG
        lastLogged = nil
        lastLogHostTime = nil
#endif
    }

    func finishRecording() {
        if let completed = current.snapshot() {
            lastCompleted = completed
        }
        current = CameraCaptureDiagnosticsAccumulator()
#if DEBUG
        lastLogged = nil
        lastLogHostTime = nil
#endif
    }

    func beginNewIntervalRun() {
        current.beginNewIntervalRun()
    }

    func recordReceived(hostTime: TimeInterval, layout: CameraPixelBufferLayout) {
        current.recordReceived(hostTime: hostTime, layout: layout)
    }

    func recordSystemDrop(sampleBuffer: CMSampleBuffer, hostTime: TimeInterval?) {
        current.recordSystemDrop(
            hostTime: hostTime,
            reason: Self.systemDropReason(in: sampleBuffer)
        )
    }

    func recordEncoderBackpressureDrop() {
        current.recordEncoderBackpressureDrop()
    }

    func recordNonMonotonicTimestampDrop() {
        current.recordNonMonotonicTimestampDrop()
    }

    func recordInvalidSampleDrop() {
        current.recordInvalidSampleDrop()
    }

    func recordNormalizedFrame() {
        current.recordNormalizedFrame()
    }

    func recordAppendedFrame() {
        current.recordAppendedFrame()
    }

    func recordSessionInterruption() {
        current.recordSessionInterruption()
    }

    func recordSessionRuntimeError() {
        current.recordSessionRuntimeError()
    }

    func logIfDue(hostTime: TimeInterval) {
#if DEBUG
        guard hostTime.isFinite,
              hostTime - (lastLogHostTime ?? -.infinity) >= 1,
              let diagnostics = current.snapshot() else { return }
        let previous = lastLogged
        let recentReceived = diagnostics.receivedFrames - (previous?.receivedFrames ?? 0)
        let recentAppended = diagnostics.appendedFrames - (previous?.appendedFrames ?? 0)
        let recentSystemDrops = diagnostics.systemDroppedFrames
            - (previous?.systemDroppedFrames ?? 0)
        let recentBackpressure = diagnostics.encoderBackpressureDrops
            - (previous?.encoderBackpressureDrops ?? 0)
        let recentTimestampDrops = diagnostics.nonMonotonicTimestampDrops
            - (previous?.nonMonotonicTimestampDrops ?? 0)
        let recentInvalidSamples = diagnostics.invalidSampleDrops
            - (previous?.invalidSampleDrops ?? 0)
        let message = "camera diagnostic: "
            + "recentReceived=\(max(recentReceived, 0)) "
            + "recentAppended=\(max(recentAppended, 0)) "
            + "recentSystemDropped=\(max(recentSystemDrops, 0)) "
            + "recentEncoderBackpressure=\(max(recentBackpressure, 0)) "
            + "recentTimestampDropped=\(max(recentTimestampDrops, 0)) "
            + "recentInvalidSamples=\(max(recentInvalidSamples, 0)) "
            + "maxGapMs=\(String(format: "%.2f", diagnostics.maximumFrameInterval * 1_000)) "
            + "formatChanges=\(diagnostics.formatChanges) "
            + "normalizedFrames=\(diagnostics.normalizedFrames) "
            + "sessionInterruptions=\(diagnostics.sessionInterruptionCount) "
            + "sessionRuntimeErrors=\(diagnostics.sessionRuntimeErrorCount) "
            + "pixelFormat=\(Self.fourCC(diagnostics.finalPixelFormat)) "
            + "planes=\(diagnostics.finalPlaneCount ?? 0) "
            + "bytesPerRow=\(diagnostics.finalBytesPerRow ?? [])"
        Self.logger.notice("\(message, privacy: .public)")
        lastLogHostTime = hostTime
        lastLogged = diagnostics
#endif
    }

    private static func systemDropReason(
        in sampleBuffer: CMSampleBuffer
    ) -> CameraSystemDropReason {
        guard let reason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) else { return .unknown }
        if CFEqual(reason, kCMSampleBufferDroppedFrameReason_FrameWasLate) { return .late }
        if CFEqual(reason, kCMSampleBufferDroppedFrameReason_OutOfBuffers) {
            return .outOfBuffers
        }
        if CFEqual(reason, kCMSampleBufferDroppedFrameReason_Discontinuity) {
            return .discontinuity
        }
        return .unknown
    }

    private static func fourCC(_ value: UInt32?) -> String {
        guard let value else { return "unknown" }
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
            ?? String(format: "0x%08X", value)
    }
}
