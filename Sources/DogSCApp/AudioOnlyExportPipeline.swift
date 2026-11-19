import AVFoundation
import Foundation
import RecorderCore

/// Exports the same cut, retimed and per-segment mixed audio heard in the
/// editor without starting the video renderer or encoding a placeholder frame.
final class AudioOnlyExportPipeline: @unchecked Sendable {
    private var session: AVAssetExportSession!
    private let media: TimelineCompositionBundle
    private let project: RecorderProject
    private let outputRange: MediaTimeRange?
    private let voiceOnly: Bool
    private let normalizesAudioLoudness: Bool
    private let audioSourceCache: AudioSourceCache
    private let outputURL: URL
    private let progressHandler: (@Sendable (Double) -> Void)?

    init(
        media: TimelineCompositionBundle,
        outputURL: URL,
        project: RecorderProject,
        outputRange: MediaTimeRange? = nil,
        voiceOnly: Bool = false,
        normalizesAudioLoudness: Bool = AppPreferences.isAudioLoudnessNormalizationEnabled,
        audioSourceCache: AudioSourceCache = .shared,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws {
        let tracks = voiceOnly ? media.recordingAudioTracks : media.mixedAudioTracks
        guard !tracks.isEmpty else {
            throw VideoExporterError.noAudioToExport
        }
        self.media = media
        self.project = project
        self.outputRange = outputRange
        self.voiceOnly = voiceOnly
        self.normalizesAudioLoudness = normalizesAudioLoudness
        self.audioSourceCache = audioSourceCache
        self.outputURL = outputURL
        self.progressHandler = progressHandler
    }

    func run() async throws {
        try Task.checkCancellation()
        progressHandler?(0)
        guard let preparedAudio = try await RenderedExportAudio.prepare(media: media,
            project: project, outputRange: outputRange,
            normalizesLoudness: !voiceOnly && normalizesAudioLoudness,
            includeExternalAudio: !voiceOnly, cache: audioSourceCache) else { throw VideoExporterError.noAudioToExport }
        defer { withExtendedLifetime(preparedAudio) {} }
        let source = try await preparedAudio.loadSource()
        guard let preparedSession = AVAssetExportSession(asset: source.asset,
            presetName: AVAssetExportPresetAppleM4A) else { throw VideoExporterError.cannotCreateSession }
        session = preparedSession
        session.shouldOptimizeForNetworkUse = true
        let progressTask = Task { [self] in
            while !Task.isCancelled {
                progressHandler?(
                    min(max(Double(session.progress), 0), 0.99)
                )
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await session.export(to: outputURL, as: .m4a)
            } onCancel: { [self] in
                session.cancelExport()
            }
        } catch {
            if Task.isCancelled {
                throw VideoExporterError.cancelled
            }
            throw VideoExporterError.exportFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        progressHandler?(1)
    }
}
