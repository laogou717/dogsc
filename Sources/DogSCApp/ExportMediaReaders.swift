import AVFoundation
import Foundation
import OSLog
import RecorderCore

/// A worker may finish after cancellation. Its result stays owned here, so
/// the caller can stop waiting without touching a decoder still in use.
final class ExportPendingResult<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, any Error>?

    func complete(_ result: Result<Value, any Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait(cancellation: ExportCancellationLatch, timeout: TimeInterval = 120,
              timeoutError: any Error) throws -> Value {
        let started = ProcessInfo.processInfo.systemUptime
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancellation.isRequested { throw VideoExporterError.cancelled }
            if let result { return try result.get() }
            if ProcessInfo.processInfo.systemUptime - started >= timeout { throw timeoutError }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

/// AVAssetReader.h forbids cancelReading concurrently with copyNextSampleBuffer.
/// All reader operations use this queue; cancellation releases the caller,
/// while teardown waits behind any outstanding framework read.
final class ExportSampleReader: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let queue = DispatchQueue(label: "cn.laogou.dogsc.export.read", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)

    init(reader: AVAssetReader, output: AVAssetReaderOutput) {
        self.reader = reader
        self.output = output
    }

    var status: AVAssetReader.Status { reader.status }
    var error: (any Error)? { reader.error }

    func startReading() -> Bool { queue.sync { reader.startReading() } }

    func next(cancellation: ExportCancellationLatch, timeoutError: any Error) throws -> CMSampleBuffer? {
        if cancellation.isRequested { throw VideoExporterError.cancelled }
        let pending = ExportPendingResult<CMSampleBuffer?>()
        queue.async { [self] in
            if cancellation.isRequested {
                pending.complete(.failure(VideoExporterError.cancelled))
                return
            }
            let sample = output.copyNextSampleBuffer()
            if sample == nil, reader.status == .failed {
                pending.complete(.failure(reader.error ?? VideoExporterError.exportFailed("读取失败")))
            } else {
                pending.complete(.success(sample))
            }
        }
        return try pending.wait(cancellation: cancellation, timeoutError: timeoutError)
    }

    func cancelReading() {
        queue.async { [self] in reader.cancelReading() }
    }
}

/// Decode each retained slice from its own original track. A single composed
/// track can stall when it switches between H.264/HEVC or different dimensions.
/// The media plan still owns all cut, speed and source-offset calculations.
/// Mutable cursor state belongs exclusively to the export video queue.
final class ExportTimelineVideoReader: @unchecked Sendable {
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "export")
    private let sources: [UUID: LoadedTimelineTrack]
    private let inserted: [String: LoadedTimelineTrack]
    private let offsets: [UUID: TimeInterval]
    private let role: ExportAssetRole
    private var reader: ExportSampleReader?
    private var sliceID: UUID?
    private var sliceOutputStart: TimeInterval?
    private var sourceStart: TimeInterval = 0
    private var sourceEnd: TimeInterval = 0
    private var sourceScale: Double = 1
    private var nextSample: CMSampleBuffer?
    private var currentBuffer: CVPixelBuffer?
    private(set) var frameSourceTime: TimeInterval?
    private var leadingHeldBuffer: CVPixelBuffer?
    private var leadingHeldTime: TimeInterval?
    private var reachedEnd = false

    init(sources: [UUID: LoadedTimelineTrack], inserted: [String: LoadedTimelineTrack] = [:],
         offsets: [UUID: TimeInterval] = [:], role: ExportAssetRole) {
        self.sources = sources
        self.inserted = inserted
        self.offsets = offsets
        self.role = role
    }

    func frame(in slice: TimelineMediaSlice, at outputTime: TimeInterval,
               cancellation: ExportCancellationLatch,
               progress: () -> Void) throws -> CVPixelBuffer? {
        if cancellation.isRequested { throw VideoExporterError.cancelled }
        if sliceID != slice.id || sliceOutputStart != slice.outputStart { try open(slice, at: outputTime) }
        guard let reader else { return nil }
        let target = sourceStart + max(outputTime - slice.outputStart, 0) * sourceScale
        func read() throws -> CMSampleBuffer? {
            guard !reachedEnd else { return nil }
            let error = VideoExporterError.exportFailed(String(format:
                appLocalized("读取%@素材超时（成片 %.2f 秒），导出已停止。"), appLocalized(role.displayName), outputTime))
            while let sample = try reader.next(cancellation: cancellation, timeoutError: error) {
                progress()
                let time = sample.outputPresentationTimeStamp.seconds
                let sampleStart = sample.presentationTimeStamp.seconds
                guard time.isFinite, sampleStart.isFinite else { continue }
                guard time < sourceEnd - 0.000_000_001 else { break }
                if sampleStart < sourceStart - 0.000_000_001 {
                    // Decoder preroll is not a selected frame. Only retain a
                    // frame genuinely spanning the cut as a VFR fallback when
                    // the entire selection contains no new image sample.
                    let end = time + sample.outputDuration.seconds
                    if end.isFinite, end > sourceStart {
                        leadingHeldBuffer = sample.imageBuffer
                        leadingHeldTime = time
                    }
                    continue
                }
                return sample
            }
            reachedEnd = true
            return nil
        }
        if nextSample == nil, currentBuffer == nil { nextSample = try read() }
        while let sample = nextSample,
              sample.outputPresentationTimeStamp.seconds <= target + 0.000_000_001 {
            currentBuffer = sample.imageBuffer ?? currentBuffer
            if sample.imageBuffer != nil { frameSourceTime = sample.outputPresentationTimeStamp.seconds }
            nextSample = try read()
        }
        if currentBuffer == nil, let sample = nextSample {
            currentBuffer = sample.imageBuffer
            frameSourceTime = sample.outputPresentationTimeStamp.seconds
            nextSample = try read()
        }
        if currentBuffer == nil { frameSourceTime = leadingHeldTime }
        return currentBuffer ?? leadingHeldBuffer
    }

    func close() {
        reader?.cancelReading()
        reader = nil
        sliceID = nil
        sliceOutputStart = nil
        nextSample = nil
        currentBuffer = nil
        frameSourceTime = nil
        leadingHeldBuffer = nil
        leadingHeldTime = nil
        reachedEnd = false
    }

    private func open(_ slice: TimelineMediaSlice, at outputTime: TimeInterval) throws {
        close()
        let loaded: LoadedTimelineTrack?
        let offset: TimeInterval
        if let media = slice.media {
            loaded = inserted[media.path]
            offset = loaded?.timeRange.start.seconds ?? 0
        } else {
            loaded = sources[slice.sourceID]
            offset = offsets[slice.sourceID] ?? 0
        }
        guard let loaded else {
            throw VideoExporterError.cannotReadMediaTrack(role: role, media: .video)
        }
        sourceStart = max(offset + slice.sourceStart, loaded.timeRange.start.seconds)
        sourceEnd = min(offset + slice.sourceStart + slice.duration * slice.sourceTimeScale,
                        loaded.timeRange.end.seconds)
        sourceScale = slice.media == nil ? slice.sourceTimeScale : (sourceEnd - sourceStart) / slice.duration
        guard sourceEnd > sourceStart else {
            throw VideoExporterError.unusableMediaRange(role)
        }
        let assetReader = try AVAssetReader(asset: loaded.asset)
        let output = AVAssetReaderTrackOutput(track: loaded.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard assetReader.canAdd(output) else {
            throw VideoExporterError.cannotReadMediaTrack(role: role, media: .video)
        }
        assetReader.add(output)
        // A range export may begin halfway through a long retained slice.
        // Keep a small preroll without decoding the entire preceding take.
        let target = sourceStart + max(outputTime - slice.outputStart, 0) * sourceScale
        let readStart = max(sourceStart, min(target - 0.1, sourceEnd - 1 / 60_000))
        assetReader.timeRange = CMTimeRange(
            start: CMTime(seconds: readStart, preferredTimescale: 1_000_000_000),
            end: CMTime(seconds: sourceEnd, preferredTimescale: 1_000_000_000))
        let reader = ExportSampleReader(reader: assetReader, output: output)
        guard reader.startReading() else {
            throw reader.error ?? VideoExporterError.cannotReadMediaTrack(role: role, media: .video)
        }
        self.reader = reader
        sliceID = slice.id
        sliceOutputStart = slice.outputStart
        Self.logger.info("decode slice \(slice.segmentID.uuidString, privacy: .public), source \(slice.sourceID.uuidString, privacy: .public), output \(slice.outputStart, privacy: .public), input \(self.sourceStart, privacy: .public)...\(self.sourceEnd, privacy: .public)")
    }
}
