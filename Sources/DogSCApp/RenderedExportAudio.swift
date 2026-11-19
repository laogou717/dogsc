import AVFoundation
import Foundation
import RecorderCore

/// Export-only PCM mixing. Editing never waits for this file or invalidates it.
final class RenderedExportAudio: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func loadSource() async throws -> LoadedTimelineTrack {
        try await TimelinePreviewCompositionLoader.loadTrack(at: url, mediaType: .audio, role: "成片声音")
    }

    static func prepare(media: TimelineCompositionBundle, project: RecorderProject,
                        outputRange: MediaTimeRange? = nil, normalizesLoudness: Bool = true,
                        includeExternalAudio: Bool = true, cache: AudioSourceCache = .shared,
                        isolation: isolated (any Actor)? = #isolation) async throws -> RenderedExportAudio? {
        let prepared = try await PreparedTimelineAudio.prepare(media, normalized: normalizesLoudness, cache: cache)
        guard !prepared.tracks(includeExternalAudio: includeExternalAudio).isEmpty else { return nil }
        let directory = AudioWorkspace.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("export.caf")
        let cancellation = ExportCancellationLatch()
        return try await withTaskCancellationHandler {
            do {
                try renderMix(prepared: prepared, project: project, includeExternalAudio: includeExternalAudio,
                    range: outputRange ?? MediaTimeRange(start: 0, duration: media.plan.outputDuration)!,
                    to: url, cancellation: cancellation)
                try Task.checkCancellation()
                return RenderedExportAudio(url: url, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } onCancel: { cancellation.request() }
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000, channels: 2, interleaved: true)!

    private static func renderMix(prepared: PreparedTimelineAudio, project: RecorderProject, includeExternalAudio: Bool,
                                  range: MediaTimeRange, to url: URL, cancellation: ExportCancellationLatch) throws {
        let reader = try AVAssetReader(asset: prepared.composition)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: range.end, preferredTimescale: 48_000))
        // Read automation from its origin. AVAssetReader ramps from its
        // initial volume on a partial read; seeking directly into a muted
        // segment can otherwise leak the first few milliseconds of sound.
        let output = AVAssetReaderAudioMixOutput(audioTracks: prepared.tracks(includeExternalAudio: includeExternalAudio),
            audioSettings: format.settings)
        output.audioMix = prepared.mix(audio: project.audio, overrides: project.timeline.primarySegmentAudioOverrides,
            externalClips: project.timeline.programAudioClips, speech: project.timeline.subtitleCues.map(\.timing),
            includeExternalAudio: includeExternalAudio)
        output.audioTimePitchAlgorithm = .spectral
        guard reader.canAdd(output) else { throw failure("无法准备成片混音") }
        reader.add(output)
        let samples = ExportSampleReader(reader: reader, output: output)
        guard samples.startReading() else { throw reader.error ?? failure("无法读取成片混音") }
        defer { samples.cancelReading() }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: true)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
        memset(silence.mutableAudioBufferList.pointee.mBuffers.mData!, 0, 8_192 * 8)
        let totalFrames = Int64((range.duration * 48_000).rounded())
        var written: Int64 = 0
        func pad(to target: Int64) throws {
            while written < target {
                try Task.checkCancellation()
                silence.frameLength = AVAudioFrameCount(min(target - written, 8_192))
                try file.write(from: silence)
                written += Int64(silence.frameLength)
            }
        }
        while let sample = try samples.next(cancellation: cancellation,
            timeoutError: failure("成片混音读取超时，导出已停止。")) {
            try Task.checkCancellation()
            let timestamp = sample.presentationTimeStamp.seconds
            guard timestamp.isFinite else { throw failure("成片声音时间戳无效") }
            let start = Int64(((timestamp - range.start) * 48_000).rounded())
            // Preserve leading/internal silence, selected-range offsets and
            // partial first buffers instead of concatenating decoded packets.
            try pad(to: min(max(start, 0), totalFrames))
            let skip = max(written - start, 0)
            let count = min(Int64(sample.numSamples) - skip, totalFrames - written)
            guard count > 0 else { continue }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,
                at: Int32(skip), frameCount: Int32(count), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw failure("无法读取成片 PCM 声音：\(status)") }
            try file.write(from: buffer)
            written += count
        }
        guard reader.status == .completed else { throw reader.error ?? failure("成片混音读取未完成") }
        try pad(to: totalFrames)
    }

    private static func failure(_ message: String) -> VideoExporterError { .exportFailed(message) }
}
