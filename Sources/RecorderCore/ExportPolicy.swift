import Foundation

/// The post-production state, rather than capture-time switches, decides
/// which optional files are required to render a project.
public struct RequiredProjectMedia: Equatable, Sendable {
    public let systemAudio: Bool
    public let cameraVideo: Bool
    public let microphoneAudio: Bool
    public let backgroundImage: Bool
    public let backgroundVideo: Bool

    public init(project: RecorderProject, sourceID: UUID? = nil) {
        let recordingSegments: [(id: UUID, sourceID: UUID)]
        switch project.timeline.sourceSequence {
        case .fullRecording:
            recordingSegments = [(TimelineMap.fullRecordingSegmentID, RecordingSource.primaryID)]
        case let .edited(segments):
            recordingSegments = segments.filter { $0.media == nil }.map { ($0.id, $0.resolvedSourceID) }
        }
        let selected = recordingSegments.filter { sourceID == nil || $0.sourceID == sourceID }
        systemAudio = selected.contains { segment in
            let overrides = project.timeline.primarySegmentAudioOverrides[segment.id]
            let isMuted = overrides?.isSystemMuted ?? project.audio.isSystemMuted
            let volume = overrides?.systemVolume
                ?? project.audio.systemVolume
            return !isMuted && volume > 0
        }
        cameraVideo = selected.contains {
            !(project.timeline.recordingSegment(id: $0.id)?.sceneStyle?.camera.isHidden ?? project.camera.isHidden)
                && project.source($0.sourceID)?.media.camera != nil
        }
        microphoneAudio = selected.contains { segment in
                guard project.source(segment.sourceID)?.media.microphone != nil else { return false }
                let overrides = project.timeline.primarySegmentAudioOverrides[segment.id]
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
        frameRate: Int,
        codec: ExportVideoCodec = .h264,
        quality: ExportQuality = .high
    ) -> Int {
        // H.264 SDR delivery targets at 30/60 fps. Interpolate by actual
        // encoded pixel count so portrait, square and native sizes follow
        // the same budget rather than depending on a resolution label.
        let anchors: [(pixels: Double, fps30: Double, fps60: Double)] = [
            (1_280 * 720, 5_000_000, 7_500_000),
            (1_920 * 1_080, 8_000_000, 12_000_000),
            (2_560 * 1_440, 16_000_000, 24_000_000),
            (3_840 * 2_160, 40_000_000, 55_000_000),
        ]
        let pixels = Double(max(width, 1)) * Double(max(height, 1))
        let fps = Double(max(frameRate, 1))
        func rate(at anchor: (pixels: Double, fps30: Double, fps60: Double)) -> Double {
            if fps <= 30 { return anchor.fps30 * fps / 30 }
            if fps >= 60 { return anchor.fps60 * fps / 60 }
            return anchor.fps30 + (anchor.fps60 - anchor.fps30) * (fps - 30) / 30
        }
        var referenceRate = rate(at: anchors[0]) * pixels / anchors[0].pixels
        if let upperIndex = anchors.firstIndex(where: { $0.pixels >= pixels }), upperIndex > 0 {
            let lower = anchors[upperIndex - 1]
            let upper = anchors[upperIndex]
            let fraction = (pixels - lower.pixels) / (upper.pixels - lower.pixels)
            referenceRate = rate(at: lower) + (rate(at: upper) - rate(at: lower)) * fraction
        } else if pixels > anchors[anchors.count - 1].pixels {
            let last = anchors[anchors.count - 1]
            referenceRate = rate(at: last) * pixels / last.pixels
        }
        let qualityScale: Double
        switch quality {
        case .compact: qualityScale = 0.6
        case .high: qualityScale = 1
        case .maximum: qualityScale = 1.5
        }
        let codecScale = codec == .hevc ? 0.75 : 1.0
        return Int(max(referenceRate * qualityScale * codecScale, 250_000).rounded())
    }
}

/// Capture keeps its editing-quality budget independently of delivery presets.
public enum CaptureEncodingPolicy {
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
