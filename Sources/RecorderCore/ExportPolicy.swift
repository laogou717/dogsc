import Foundation

/// The post-production state, rather than capture-time switches, decides
/// which optional files are required to render a project.
public struct RequiredProjectMedia: Equatable, Sendable {
    public let screenVideo: Bool
    public let systemAudio: Bool
    public let cameraVideo: Bool
    public let microphoneAudio: Bool
    public let backgroundImage: Bool
    public let backgroundVideo: Bool

    public init(project: RecorderProject) {
        screenVideo = true
        let recordingSegmentIDs: [UUID]
        switch project.timeline.sourceSequence {
        case .fullRecording:
            recordingSegmentIDs = [TimelineMap.fullRecordingSegmentID]
        case let .edited(segments):
            recordingSegmentIDs = segments.map(\.id)
        }
        systemAudio = recordingSegmentIDs.contains { id in
            let overrides = project.timeline.primarySegmentAudioOverrides[id]
            let isMuted = overrides?.isSystemMuted ?? project.audio.isSystemMuted
            let volume = overrides?.systemVolume
                ?? project.audio.systemVolume
            return !isMuted && volume > 0
        }
        cameraVideo = project.media?.camera != nil && !project.camera.isHidden
        microphoneAudio = project.media?.microphone != nil
            && recordingSegmentIDs.contains { id in
                let overrides = project.timeline.primarySegmentAudioOverrides[id]
                let isMuted = overrides?.isMicrophoneMuted
                    ?? project.audio.isMicrophoneMuted
                let volume = overrides?.microphoneVolume
                    ?? project.audio.microphoneVolume
                return !isMuted && volume > 0
            }
        backgroundImage = project.canvas.backgroundSource.isImage
        backgroundVideo = project.canvas.backgroundSource.isVideo
    }
}

/// Shared by the export UI and the encoder so the estimate cannot advertise a
/// different policy from the job that will actually run.
public enum ExportEncodingPolicy {
    public static let audioBitrate = 192_000

    public static func videoBitrate(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> Int {
        let pixels = max(width * height, 1)
        // High-resolution ceilings: the flat 65 Mbps cap (fine for 1080p)
        // visibly bands and blocks screen content at 1440p+ / 4K, where the
        // pixel-count formula alone already asks for 80–165 Mbps.
        let ceiling: Int
        if pixels >= 7_000_000 { // ≈ 4K (3840×2160 = 8.29M)
            ceiling = 130_000_000
        } else if pixels >= 3_500_000 { // ≈ 1440p (2560×1440 = 3.69M)
            ceiling = 100_000_000
        } else {
            ceiling = 65_000_000
        }
        return min(max(pixels * max(frameRate, 1) / 6, 12_000_000), ceiling)
    }
}
