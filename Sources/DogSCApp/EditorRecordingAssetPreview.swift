import AVFoundation
import Foundation
import RecorderCore

/// A recording is its screen, camera and microphones, including their source
/// trims. Reuse the programme's media planner rather than previewing just MP4.
@MainActor
enum EditorRecordingAssetPreview {
    struct Result {
        let item: AVPlayerItem
        let camera: AVPlayerItem?
        let screenSize: CGSize
        let cameraSize: CGSize?
        let cameraCrop: NormalizedCrop
        let duration: TimeInterval
    }

    static func load(_ source: RecordingSource, audio: AudioStyle) async throws -> Result {
        func url(_ reference: ProjectMediaReference?) -> URL? {
            reference.map { ProjectFiles.url($0.relativePath) }
        }
        let tracks = try await TimelinePreviewCompositionLoader.loadRecording(
            screenURL: url(source.media.screen), cameraURL: url(source.media.camera),
            microphoneURL: url(source.media.microphone), manifest: source.media,
            pointerEvents: [], cameraContentCrop: source.cameraContentCrop)
        try Task.checkCancellation()
        func range(_ track: LoadedTimelineTrack?) -> MediaTimeRange? {
            track.flatMap { MediaTimeRange(start: $0.timeRange.start.seconds, duration: $0.timeRange.duration.seconds) }
        }
        guard let video = range(tracks.screen) else { throw TimelinePreviewMediaError.invalidTrackRange("主录屏") }
        let id = RecordingSource.primaryID
        let plan = try ProjectTimelineMediaPlan(sourceSequence: .fullRecording, sources: [id: .init(
            manifest: source.media, videoRange: video, systemAudioRange: range(tracks.systemAudio),
            cameraRange: range(tracks.camera), microphoneRange: range(tracks.microphone))])
        let bundle = try TimelineCompositionBuilder.build(plan: plan, sources: [id: tracks])
        let item = AVPlayerItem(asset: bundle.primaryComposition)
        item.audioMix = bundle.resolvedAudioMix(audio: audio, overrides: [:])
        return Result(item: item, camera: bundle.cameraComposition.map { AVPlayerItem(asset: $0) },
            screenSize: tracks.screen.displaySize ?? CGSize(width: 1920, height: 1080),
            cameraSize: tracks.camera?.displaySize, cameraCrop: tracks.cameraContentCrop ?? .full, duration: plan.outputDuration)
    }
}
