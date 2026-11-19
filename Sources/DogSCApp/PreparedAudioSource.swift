import Accelerate
import AVFoundation
import Darwin
import Foundation

/// Immutable, processed original audio. Its clock and lease survive every cut.
final class PreparedAudioSource: @unchecked Sendable {
    let url: URL
    let originalRange: CMTimeRange
    let peak: Float
    let profile: AudioLoudnessAnalyzer.Profile
    private let directory: URL
    private let persistent: Bool
    private let lease: Int32?

    private init(url: URL, range: CMTimeRange, peak: Float,
                 profile: AudioLoudnessAnalyzer.Profile, directory: URL, persistent: Bool = false, lease: Int32? = nil) {
        self.url = url
        originalRange = range
        self.peak = peak
        self.profile = profile
        self.directory = directory
        self.persistent = persistent
        self.lease = lease
    }
    deinit {
        if let lease { close(lease) }
        if !persistent { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Metadata: Codable {
        let version: Int
        let key: AudioSourceKey
        let start: Int64
        let startScale: Int32
        let duration: Int64
        let durationScale: Int32
        let bytes: Int64
        let peak: Float
        let profile: AudioLoudnessAnalyzer.Profile
    }

    static func restore(_ key: AudioSourceKey, at directory: URL) -> PreparedAudioSource? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.version == AudioSourceDiskCache.formatVersion, metadata.key == key,
              metadata.startScale > 0, metadata.durationScale > 0, metadata.duration > 0,
              metadata.peak.isFinite, metadata.peak >= 0,
              metadata.profile.calibrationGain.isFinite, metadata.profile.calibrationGain >= 1,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("source.caf").path)[.size] as? NSNumber)?.int64Value,
              bytes == metadata.bytes, let lease = try? AudioSourceDiskCache.sharedLease(at: directory) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        return PreparedAudioSource(url: directory.appendingPathComponent("source.caf"),
            range: CMTimeRange(start: CMTime(value: metadata.start, timescale: metadata.startScale),
                duration: CMTime(value: metadata.duration, timescale: metadata.durationScale)),
            peak: metadata.peak, profile: metadata.profile, directory: directory, persistent: true, lease: lease)
    }

    func publish(_ key: AudioSourceKey, to destination: URL) throws -> PreparedAudioSource {
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let metadata = Metadata(version: AudioSourceDiskCache.formatVersion, key: key,
            start: originalRange.start.value, startScale: originalRange.start.timescale,
            duration: originalRange.duration.value, durationScale: originalRange.duration.timescale,
            bytes: bytes, peak: peak, profile: profile)
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        let lease = try AudioSourceDiskCache.sharedLease(at: directory)
        do { try FileManager.default.moveItem(at: directory, to: destination) }
        catch { close(lease); throw error }
        return PreparedAudioSource(url: destination.appendingPathComponent("source.caf"), range: originalRange,
            peak: peak, profile: profile, directory: destination, persistent: true, lease: lease)
    }

    func loadSource() async throws -> LoadedTimelineTrack {
        let loaded = try await TimelinePreviewCompositionLoader.loadTrack(at: url, mediaType: .audio, role: "声音")
        return LoadedTimelineTrack(asset: loaded.asset, track: loaded.track, timeRange: originalRange,
            preferredTransform: .identity, displaySize: nil)
    }

    static func render(_ key: AudioSourceKey) async throws -> PreparedAudioSource? {
        try key.validate()
        let originalURL = URL(fileURLWithPath: key.file.standardizedPath)
        let asset = AVURLAsset(url: originalURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first(where: { $0.trackID == key.trackID })
        else { throw VideoExporterError.exportFailed("找不到声音轨道") }
        let range = try await track.load(.timeRange)
        try Task.checkCancellation()
        let directory = AudioWorkspace.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("source.caf")
        let cancellation = ExportCancellationLatch()
        return try await withTaskCancellationHandler {
            do {
                let decoded = try decode(asset: asset, track: track, range: range, to: outputURL,
                    measuresLoudness: key.boostsLoudness, cancellation: cancellation)
                let profile = decoded.profile
                var peak = decoded.peak
                if profile.calibrationGain > 1 {
                    let masteredURL = directory.appendingPathComponent("normalized.caf")
                    peak = try master(from: outputURL, to: masteredURL, gain: profile.calibrationGain)
                    try FileManager.default.removeItem(at: outputURL)
                    try FileManager.default.moveItem(at: masteredURL, to: outputURL)
                }
                try Task.checkCancellation()
                try key.validate()
                return PreparedAudioSource(url: outputURL, range: range, peak: peak, profile: profile, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } onCancel: { cancellation.request() }
    }

    private static func decode(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, to url: URL,
                               measuresLoudness: Bool, cancellation: ExportCancellationLatch) throws -> (peak: Float, profile: AudioLoudnessAnalyzer.Profile) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let samples = ExportSampleReader(reader: reader, output: output)
        guard samples.startReading() else { throw reader.error ?? VideoExporterError.exportFailed("声音读取失败") }
        defer { samples.cancelReading() }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let meter = measuresLoudness ? AudioLoudnessAnalyzer.Meter() : nil
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
        memset(silence.mutableAudioBufferList.pointee.mBuffers.mData!, 0, 8_192 * 8)
        var written: Int64 = 0
        var peak: Float = 0
        var buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)!
        // A 44.1 kHz source end can fall between 48 kHz frames. Cover that
        // fractional final frame so original source ranges remain insertable.
        let total = Int64((range.end.seconds * 48_000).rounded(.up))
        func pad(to target: Int64) throws {
            while written < target {
                try Task.checkCancellation()
                silence.frameLength = AVAudioFrameCount(min(target - written, 8_192))
                try file.write(from: silence)
                written += Int64(silence.frameLength)
            }
        }
        while let sample = try samples.next(cancellation: cancellation,
            timeoutError: VideoExporterError.exportFailed("声音读取超时")) {
            try Task.checkCancellation()
            let start = Int64((sample.presentationTimeStamp.seconds * 48_000).rounded())
            try pad(to: min(max(start, 0), total))
            let skip = max(written - start, 0)
            let count = min(Int64(sample.numSamples) - skip, total - written)
            guard count > 0 else { continue }
            if buffer.frameCapacity < count {
                buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            }
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(skip),
                frameCount: Int32(count), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            meter?.consume(buffer)
            var blockPeak: Float = 0
            vDSP_maxmgv(buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self),
                1, &blockPeak, vDSP_Length(count * 2))
            peak = max(peak, blockPeak)
            try file.write(from: buffer)
            written += count
        }
        guard reader.status == .completed else { throw reader.error ?? VideoExporterError.exportFailed("声音读取未完成") }
        try pad(to: total)
        return (peak, meter?.profile ?? .unity)
    }

    private static func master(from source: URL, to destination: URL, gain: Float) throws -> Float {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: true)
        let output = try AVAudioFile(forWriting: destination, settings: input.processingFormat.settings,
            commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384)!
        let processor = AudioSourceProcessor(gain: gain)
        var peak: Float = 0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw VideoExporterError.exportFailed("声音缓存读取中断") }
            processor.process(buffer)
            var current: Float = 0
            vDSP_maxmgv(buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self),
                1, &current, vDSP_Length(buffer.frameLength) * 2)
            peak = max(peak, current)
            try output.write(from: buffer)
        }
        return peak
    }
}
