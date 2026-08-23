import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

struct MediaAssetInventory: Equatable, Sendable {
    var duration: TimeInterval
    var videoWidth: Double?
    var videoHeight: Double?
    var videoTimeRange: MediaTimeRange?
    var audioTimeRange: MediaTimeRange?
    var videoFrameRate: Double? = nil

    var hasVideo: Bool { videoTimeRange != nil }
    var hasAudio: Bool { audioTimeRange != nil }

    static let empty = MediaAssetInventory(
        duration: 0,
        videoWidth: nil,
        videoHeight: nil,
        videoTimeRange: nil,
        audioTimeRange: nil
    )
}

enum MediaAnalysisError: Error, LocalizedError {
    case missingAudioTrack
    case cannotReadAudio
    case unsupportedAudioFormat
    case invalidAudioTimeRange
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            return "媒体中没有可用的音频轨。"
        case .cannotReadAudio:
            return "无法创建音频读取器。"
        case .unsupportedAudioFormat:
            return "音频轨格式无法用于波形分析。"
        case .invalidAudioTimeRange:
            return "音频轨的时间范围为空或无效。"
        case let .readerFailed(message):
            return "音频分析失败：\(message)"
        }
    }
}

struct TimestampedWaveformAccumulator: Equatable, Sendable {
    let timeRange: MediaTimeRange
    private(set) var peaks: [Double]

    init(timeRange: MediaTimeRange, sampleCount: Int) {
        self.timeRange = timeRange
        peaks = Array(repeating: 0, count: max(sampleCount, 1))
    }

    mutating func record(peak: Double, atPresentationTime timestamp: TimeInterval) {
        guard peak.isFinite,
              peak >= 0,
              let bucket = timeRange.bucketIndex(
                forPresentationTime: timestamp,
                bucketCount: peaks.count
              ) else { return }
        peaks[bucket] = max(peaks[bucket], peak)
    }

    /// Records one interleaved PCM buffer by contiguous waveform buckets.
    ///
    /// The previous implementation converted every decoded frame back into a
    /// presentation timestamp and then divided by the full track duration to
    /// rediscover its bucket. A several-minute 48 kHz recording performs tens
    /// of millions of those identical mappings. Bucket boundaries are linear,
    /// so derive the frame interval for each touched bucket once and scan the
    /// underlying Int16 samples directly. The maximum over every channel and
    /// frame is mathematically identical to taking a per-frame channel maximum
    /// and then a bucket maximum.
    mutating func record(
        interleavedPCM pcm: UnsafeBufferPointer<Int16>,
        channels: Int,
        sampleRate: Double,
        startingAt presentationTime: TimeInterval
    ) throws {
        guard channels > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              presentationTime.isFinite,
              !pcm.isEmpty else { return }
        let frameCount = pcm.count / channels
        guard frameCount > 0 else { return }

        let bufferEnd = presentationTime + Double(frameCount) / sampleRate
        let clippedStart = max(presentationTime, timeRange.start)
        let clippedEnd = min(bufferEnd, timeRange.end)
        guard clippedStart < clippedEnd else { return }

        let bucketCount = peaks.count
        let bucketDuration = timeRange.duration / Double(bucketCount)
        guard bucketDuration.isFinite, bucketDuration > 0 else { return }

        let firstBucket = min(max(
            Int(floor((clippedStart - timeRange.start) / bucketDuration)),
            0
        ), bucketCount - 1)
        // Use half a source frame to keep the end-exclusive boundary inside
        // the final touched bucket without relying on a fixed time epsilon.
        let finalIncludedTime = max(
            clippedStart,
            clippedEnd - 0.5 / sampleRate
        )
        let lastBucket = min(max(
            Int(floor((finalIncludedTime - timeRange.start) / bucketDuration)),
            0
        ), bucketCount - 1)
        guard firstBucket <= lastBucket else { return }

        for bucket in firstBucket...lastBucket {
            if bucket & 63 == 0 { try Task.checkCancellation() }
            let bucketStart = timeRange.start + Double(bucket) * bucketDuration
            let bucketEnd = bucketStart + bucketDuration
            let startFrame = waveformFrameBoundary(
                at: bucketStart,
                relativeTo: presentationTime,
                sampleRate: sampleRate,
                frameCount: frameCount
            )
            let endFrame = waveformFrameBoundary(
                at: bucketEnd,
                relativeTo: presentationTime,
                sampleRate: sampleRate,
                frameCount: frameCount
            )
            guard startFrame < endFrame else { continue }

            let sampleStart = startFrame * channels
            let sampleEnd = min(endFrame * channels, pcm.count)
            guard let baseAddress = pcm.baseAddress else { continue }
            var magnitude: Int32 = 0
            var cursor = baseAddress.advanced(by: sampleStart)
            let end = baseAddress.advanced(by: sampleEnd)
            while cursor < end {
                let value = Int32(cursor.pointee)
                magnitude = max(magnitude, value >= 0 ? value : -value)
                cursor = cursor.advanced(by: 1)
            }
            peaks[bucket] = max(peaks[bucket], Double(magnitude) / 32_768.0)
        }
    }

    private func waveformFrameBoundary(
        at time: TimeInterval,
        relativeTo presentationTime: TimeInterval,
        sampleRate: Double,
        frameCount: Int
    ) -> Int {
        // Subtract a tiny scale-relative tolerance so an exact PCM boundary
        // represented as 4799.999999999 or 4800.000000001 maps identically.
        let rawFrame = (time - presentationTime) * sampleRate
        let tolerance = max(abs(rawFrame), 1) * Double.ulpOfOne * 16
        return min(max(Int(ceil(rawFrame - tolerance)), 0), frameCount)
    }

    var normalizedSamples: [Double] {
        peaks.map { rawPeak in
            let noiseFloor = 0.012
            guard rawPeak > noiseFloor else { return 0 }
            let elevated = (rawPeak - noiseFloor) / (1.0 - noiseFloor)
            let curved = pow(elevated, 0.95)
            return min(max(curved, 0), 1)
        }
    }
}

/// Read-only media inspection used by the editor. Timeline availability is
/// derived from the files that actually exist, never from the recorder setup
/// toggles that happened to be active when the project was created.
enum MediaAnalyzer {
    static func inspect(_ url: URL?) async -> MediaAssetInventory {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }

        let asset = AVURLAsset(url: url)
        let assetDuration = (try? await asset.load(.duration).seconds)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let videoTimeRange = await timeRange(for: videoTracks.first)
        let audioTimeRange = await timeRange(for: audioTracks.first)

        var width: Double?
        var height: Double?
        var frameRate: Double?
        if videoTimeRange != nil,
           let videoTrack = videoTracks.first,
           let naturalSize = try? await videoTrack.load(.naturalSize),
           let transform = try? await videoTrack.load(.preferredTransform) {
            let displayed = CGRect(origin: .zero, size: naturalSize)
                .applying(transform)
                .standardized
                .size
            if displayed.width > 0, displayed.height > 0 {
                width = displayed.width.rounded()
                height = displayed.height.rounded()
            }
            if let nominal = try? await videoTrack.load(.nominalFrameRate),
               nominal.isFinite,
               nominal > 0 {
                frameRate = Double(nominal)
            }
        }

        let validAssetDuration = assetDuration.flatMap { duration -> TimeInterval? in
            guard duration.isFinite, duration > 0 else { return nil }
            return duration
        } ?? 0
        let duration = [
            validAssetDuration,
            videoTimeRange.map { max($0.end, 0) } ?? 0,
            audioTimeRange.map { max($0.end, 0) } ?? 0,
        ].max() ?? 0

        return MediaAssetInventory(
            duration: duration,
            videoWidth: width,
            videoHeight: height,
            videoTimeRange: videoTimeRange,
            audioTimeRange: audioTimeRange,
            videoFrameRate: frameRate
        )
    }

    /// Produces normalized peak samples from the actual PCM stream. Silence is
    /// represented as zero; the UI must not manufacture a minimum green bar.
    static func waveform(_ url: URL?, sampleCount: Int = 160) async throws -> [Double] {
        let count = max(sampleCount, 1)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw MediaAnalysisError.missingAudioTrack
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaAnalysisError.missingAudioTrack
        }
        guard let trackTimeRange = await timeRange(for: track) else {
            throw MediaAnalysisError.invalidAudioTimeRange
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            throw MediaAnalysisError.unsupportedAudioFormat
        }

        let sampleRate = max(streamDescription.pointee.mSampleRate, 1)
        let channels = max(Int(streamDescription.pointee.mChannelsPerFrame), 1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaAnalysisError.cannotReadAudio }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaAnalysisError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var accumulator = TimestampedWaveformAccumulator(
            timeRange: trackTimeRange,
            sampleCount: count
        )
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let presentationTime = sampleBuffer.presentationTimeStamp.seconds
            guard presentationTime.isFinite else { continue }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &pointer
            )
            guard status == kCMBlockBufferNoErr, let pointer, totalLength >= MemoryLayout<Int16>.size else {
                continue
            }

            let rawBuffer = UnsafeRawBufferPointer(start: pointer, count: totalLength)
            let pcm = rawBuffer.bindMemory(to: Int16.self)
            try accumulator.record(
                interleavedPCM: pcm,
                channels: channels,
                sampleRate: sampleRate,
                startingAt: presentationTime
            )
        }

        if reader.status == .failed {
            throw MediaAnalysisError.readerFailed(reader.error?.localizedDescription ?? "未知错误")
        }

        return accumulator.normalizedSamples
    }

    private static func timeRange(for track: AVAssetTrack?) async -> MediaTimeRange? {
        guard let track,
              let range = try? await track.load(.timeRange),
              range.start.isNumeric,
              range.duration.isNumeric else { return nil }
        return MediaTimeRange(
            start: range.start.seconds,
            duration: range.duration.seconds
        )
    }
}
