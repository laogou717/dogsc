import AVFoundation
import AudioToolbox
import Foundation
import os

struct RollingHostTimeWindow {
    let capacity: Int
    private var values: [TimeInterval] = []
    private var startIndex = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        values.reserveCapacity(self.capacity)
    }

    var count: Int { values.count }

    var first: TimeInterval? {
        guard !values.isEmpty else { return nil }
        return values[startIndex]
    }

    var last: TimeInterval? {
        guard !values.isEmpty else { return nil }
        if values.count < capacity { return values.last }
        return values[(startIndex + values.count - 1) % capacity]
    }

    mutating func append(_ value: TimeInterval) {
        if values.count < capacity {
            values.append(value)
            return
        }
        values[startIndex] = value
        startIndex = (startIndex + 1) % capacity
    }

    mutating func reset(keepingCapacity: Bool) {
        values.removeAll(keepingCapacity: keepingCapacity)
        startIndex = 0
    }
}

/// Owns the rolling cadence window used to report the format that a camera is
/// actually delivering. Keeping this state outside `CameraRecorder` makes the
/// capture session responsible for orchestration rather than telemetry math.
final class CameraRuntimeFormatMonitor {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "camera-runtime-format"
    )

    private var sampleHostTimes = RollingHostTimeWindow(capacity: 31)
    private var lastReportedFormat: CameraRuntimeFormat?
    private var lastReportHostTime: TimeInterval?

    func observe(
        _ sampleBuffer: CMSampleBuffer,
        layout: CameraPixelBufferLayout,
        hostTime: TimeInterval
    ) -> CameraRuntimeFormat? {
        guard layout.isStructurallyValid, hostTime.isFinite else { return nil }

        sampleHostTimes.append(hostTime)

        let deliveredDuration = sampleBuffer.duration.seconds
        var framesPerSecond = deliveredDuration.isFinite && deliveredDuration > 0
            ? 1 / deliveredDuration
            : 0
        if sampleHostTimes.count >= 8,
           let first = sampleHostTimes.first,
           let last = sampleHostTimes.last,
           last > first {
            framesPerSecond = Double(sampleHostTimes.count - 1) / (last - first)
        }
        guard framesPerSecond.isFinite, framesPerSecond > 0 else { return nil }

        let format = CameraRuntimeFormat(
            width: layout.width,
            height: layout.height,
            framesPerSecond: (framesPerSecond * 10).rounded() / 10
        )
        if let previous = lastReportedFormat {
            let dimensionsChanged = previous.width != format.width
                || previous.height != format.height
            let enoughTimeElapsed = hostTime - (lastReportHostTime ?? -.infinity) >= 1
            let cadenceChanged = abs(previous.framesPerSecond - format.framesPerSecond) >= 0.5
            guard dimensionsChanged || (enoughTimeElapsed && cadenceChanged) else { return nil }
        }
        lastReportedFormat = format
        lastReportHostTime = hostTime
        log(format: format, layout: layout)
        return format
    }

    func reset(keepingCapacity: Bool) {
        sampleHostTimes.reset(keepingCapacity: keepingCapacity)
        lastReportedFormat = nil
        lastReportHostTime = nil
    }

    private func log(format: CameraRuntimeFormat, layout: CameraPixelBufferLayout) {
        let message = "camera sample size=\(format.width)x\(format.height) "
            + "pixelFormat=\(Self.fourCC(layout.pixelFormat)) planes=\(layout.planeCount) "
            + "bytesPerRow=\(layout.bytesPerRow) fps=\(format.framesPerSecond)"
        Self.logger.notice("\(message, privacy: .public)")
    }

    private static func fourCC(_ value: OSType) -> String {
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
