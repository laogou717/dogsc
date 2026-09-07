import AVFoundation
import Foundation
import OSLog
import RecorderCore

enum TimelineCompositionError: LocalizedError, Equatable {
    case emptyPrimaryPlan
    case cannotCreateTrack(String)
    case invalidSlice(role: String, segmentID: UUID)
    case sliceOutsideSource(role: String, segmentID: UUID)
    case insertionFailed(role: String, segmentID: UUID, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyPrimaryPlan:
            return "剪辑后的主录屏时间线为空，无法预览或导出。"
        case let .cannotCreateTrack(role):
            return "无法为\(role)创建剪辑合成轨。"
        case let .invalidSlice(role, _):
            return "\(role)片段的时间范围无效，无法准备预览。"
        case let .sliceOutsideSource(role, _):
            return "\(role)片段超出素材可用范围，请重新调整或还原该片段。"
        case let .insertionFailed(role, _, _):
            return "无法合成\(role)片段。请确认项目素材仍然可读，然后重新打开项目。"
        }
    }
}

/// Immutable AVFoundation media prepared from `ProjectTimelineMediaPlan`.
/// Both preview and export read these same output-clock compositions.
struct TimelineCompositionBundle {
    let plan: ProjectTimelineMediaPlan
    let primaryComposition: AVMutableComposition
    let primaryVideoTrack: AVMutableCompositionTrack
    let primaryVideoTracks: [AVMutableCompositionTrack]
    let primaryVideoComposition: AVVideoComposition?
    let systemAudioTrack: AVMutableCompositionTrack?
    let microphoneAudioTrack: AVMutableCompositionTrack?
    let cameraComposition: AVMutableComposition?
    let cameraVideoTrack: AVMutableCompositionTrack?

    /// Cut-only edits at 1× must remain sample-accurate joins. Running those
    /// joins through a time-pitch processor can soften audio around segment
    /// boundaries even though the user never authored a fade. Only enable the
    /// processor when at least one primary slice is genuinely retimed.
    var requiresAudioTimePitchProcessing: Bool {
        plan.primary.slices.contains {
            abs($0.sourceTimeScale - 1) > 0.000_001
        }
    }

    func primarySegmentAudioMixRanges(
        audio: AudioStyle,
        overrides: [UUID: PrimarySegmentAudioOverrides]
    ) -> [TimelineSegmentAudioMixRange] {
        plan.timelineMap.segments.compactMap { segment in
            guard let outputRange = segment.outputRange else { return nil }
            let segmentOverrides = overrides[segment.id]
                ?? PrimarySegmentAudioOverrides()
            let systemIsMuted = segmentOverrides.isSystemMuted
                ?? audio.isSystemMuted
            let microphoneIsMuted = segmentOverrides.isMicrophoneMuted
                ?? audio.isMicrophoneMuted
            let systemVolume = systemIsMuted
                ? 0
                : segmentOverrides.systemVolume ?? audio.systemVolume
            let microphoneVolume = microphoneIsMuted
                ? 0
                : segmentOverrides.microphoneVolume ?? audio.microphoneVolume
            return TimelineSegmentAudioMixRange(
                segmentID: segment.id,
                range: CMTimeRange(
                    start: CMTime(
                        seconds: outputRange.start,
                        preferredTimescale: 60_000
                    ),
                    duration: CMTime(
                        seconds: outputRange.duration,
                        preferredTimescale: 60_000
                    )
                ),
                systemTrackVolume: Float(min(max(systemVolume, 0), 1)),
                microphoneTrackVolume: Float(min(max(microphoneVolume, 0), 1))
            )
        }
    }

}

struct TimelineSegmentAudioMixRange: Equatable {
    let segmentID: UUID
    let range: CMTimeRange
    let systemTrackVolume: Float
    let microphoneTrackVolume: Float
}

struct TimelineCameraComposition {
    let composition: AVMutableComposition
    let track: AVMutableCompositionTrack
}

enum TimelineCompositionBuilder {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "timeline-composition"
    )

    static func build(
        plan: ProjectTimelineMediaPlan,
        primaryVideoTrack sourceVideoTrack: AVAssetTrack,
        primaryVideoRange: CMTimeRange,
        primaryVideoPreferredTransform: CGAffineTransform,
        systemAudioTrack sourceSystemAudioTrack: AVAssetTrack?,
        systemAudioRange: CMTimeRange?,
        cameraTrack sourceCameraTrack: AVAssetTrack?,
        cameraRange: CMTimeRange?,
        cameraPreferredTransform: CGAffineTransform,
        microphoneTrack sourceMicrophoneTrack: AVAssetTrack?,
        microphoneRange: CMTimeRange?
    ) throws -> TimelineCompositionBundle {
        guard plan.outputDuration.isFinite, plan.outputDuration > 0,
              !plan.primary.slices.isEmpty else {
            throw TimelineCompositionError.emptyPrimaryPlan
        }

        let primaryComposition = AVMutableComposition()
        let primaryVideoTrack = try insert(
            plan: plan.primary,
            sourceTrack: sourceVideoTrack,
            sourceAvailableRange: primaryVideoRange,
            sourceTimeOffset: primaryVideoRange.start.seconds,
            mediaType: .video,
            role: "主轨画面",
            preferredTransform: primaryVideoPreferredTransform,
            into: primaryComposition
        )
        let systemAudioTrack: AVMutableCompositionTrack?
        if let sourceSystemAudioTrack,
           let systemAudioRange,
           let systemAudioPlan = plan.systemAudio,
           !systemAudioPlan.slices.isEmpty {
            systemAudioTrack = try insert(
                plan: systemAudioPlan,
                sourceTrack: sourceSystemAudioTrack,
                sourceAvailableRange: systemAudioRange,
                sourceTimeOffset: 0,
                mediaType: .audio,
                role: "系统声音",
                preferredTransform: nil,
                into: primaryComposition
            )
        } else {
            systemAudioTrack = nil
        }

        let microphoneAudioTrack: AVMutableCompositionTrack?
        if let sourceMicrophoneTrack,
           let microphoneRange,
           let microphonePlan = plan.microphone,
           !microphonePlan.slices.isEmpty {
            microphoneAudioTrack = try insert(
                plan: microphonePlan,
                sourceTrack: sourceMicrophoneTrack,
                sourceAvailableRange: microphoneRange,
                sourceTimeOffset: 0,
                mediaType: .audio,
                role: "麦克风",
                preferredTransform: nil,
                into: primaryComposition
            )
        } else {
            microphoneAudioTrack = nil
        }

        let cameraComposition: AVMutableComposition?
        let cameraVideoTrack: AVMutableCompositionTrack?
        if let sourceCameraTrack,
           let cameraRange,
           let cameraPlan = plan.camera,
           !cameraPlan.slices.isEmpty {
            let composition = AVMutableComposition()
            cameraVideoTrack = try insert(
                plan: cameraPlan,
                sourceTrack: sourceCameraTrack,
                sourceAvailableRange: cameraRange,
                sourceTimeOffset: 0,
                mediaType: .video,
                role: "摄像头",
                preferredTransform: cameraPreferredTransform,
                into: composition
            )
            cameraComposition = composition
        } else {
            cameraComposition = nil
            cameraVideoTrack = nil
        }

        return TimelineCompositionBundle(
            plan: plan,
            primaryComposition: primaryComposition,
            primaryVideoTrack: primaryVideoTrack,
            primaryVideoTracks: [primaryVideoTrack],
            primaryVideoComposition: nil,
            systemAudioTrack: systemAudioTrack,
            microphoneAudioTrack: microphoneAudioTrack,
            cameraComposition: cameraComposition,
            cameraVideoTrack: cameraVideoTrack
        )
    }

    /// Camera-only timing rebuild used by the interactive sync editor. It
    /// reuses the already loaded source track and leaves the audio-bearing
    /// primary composition untouched.
    static func buildCamera(
        plan: TimelineMediaPlan?,
        source: EditorPreparedCameraSource?
    ) throws -> TimelineCameraComposition? {
        guard let plan, !plan.slices.isEmpty, let source else { return nil }
        let composition = AVMutableComposition()
        let track = try insert(
            plan: plan,
            sourceTrack: source.track,
            sourceAvailableRange: source.timeRange,
            sourceTimeOffset: 0,
            mediaType: .video,
            role: "摄像头",
            preferredTransform: source.preferredTransform,
            into: composition
        )
        return TimelineCameraComposition(composition: composition, track: track)
    }

    static func audioMix(
        systemTrack: AVCompositionTrack?,
        systemVolume: Float,
        primarySegmentRanges: [TimelineSegmentAudioMixRange] = [],
        microphoneTrack: AVCompositionTrack?,
        microphoneVolume: Float,
        requiresTimePitchProcessing: Bool = false
    ) -> AVAudioMix? {
        var parameters: [AVAudioMixInputParameters] = []
        if let systemTrack {
            let input = AVMutableAudioMixInputParameters(track: systemTrack)
            input.setVolume(systemVolume, at: .zero)
            if !primarySegmentRanges.isEmpty {
                for segment in primarySegmentRanges
                    .filter({ $0.range.isValid && !$0.range.isEmpty })
                    .sorted(by: { $0.range.start < $1.range.start }) {
                    input.setVolumeRamp(
                        fromStartVolume: segment.systemTrackVolume,
                        toEndVolume: segment.systemTrackVolume,
                        timeRange: segment.range
                    )
                }
            }
            if requiresTimePitchProcessing {
                input.audioTimePitchAlgorithm = .timeDomain
            }
            parameters.append(input)
        }
        if let microphoneTrack {
            let input = AVMutableAudioMixInputParameters(track: microphoneTrack)
            input.setVolume(microphoneVolume, at: .zero)
            for segment in primarySegmentRanges
                .filter({ $0.range.isValid && !$0.range.isEmpty })
                .sorted(by: { $0.range.start < $1.range.start }) {
                input.setVolumeRamp(
                    fromStartVolume: segment.microphoneTrackVolume,
                    toEndVolume: segment.microphoneTrackVolume,
                    timeRange: segment.range
                )
            }
            if requiresTimePitchProcessing {
                input.audioTimePitchAlgorithm = .timeDomain
            }
            parameters.append(input)
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func insert(
        plan: TimelineMediaPlan,
        sourceTrack: AVAssetTrack,
        sourceAvailableRange: CMTimeRange,
        sourceTimeOffset: TimeInterval,
        mediaType: AVMediaType,
        role: String,
        preferredTransform: CGAffineTransform?,
        into composition: AVMutableComposition
    ) throws -> AVMutableCompositionTrack {
        guard let destination = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TimelineCompositionError.cannotCreateTrack(role)
        }
        if let preferredTransform {
            destination.preferredTransform = preferredTransform
        }

        let epsilon = 1.0 / 120_000.0
        for slice in plan.slices {
            let actualSourceStart = sourceTimeOffset + slice.sourceStart
            let sourceDuration = slice.duration * slice.sourceTimeScale
            let actualSourceEnd = actualSourceStart + sourceDuration
            guard slice.outputStart.isFinite,
                  actualSourceStart.isFinite,
                  slice.duration.isFinite,
                  slice.outputStart >= 0,
                  slice.duration > 0 else {
                logger.error(
                    "invalid slice role=\(role, privacy: .public) segment=\(slice.segmentID.uuidString, privacy: .public)"
                )
                throw TimelineCompositionError.invalidSlice(
                    role: role,
                    segmentID: slice.segmentID
                )
            }
            guard actualSourceStart >= sourceAvailableRange.start.seconds - epsilon,
                  actualSourceEnd <= sourceAvailableRange.end.seconds + epsilon else {
                logger.error(
                    "slice outside source role=\(role, privacy: .public) segment=\(slice.segmentID.uuidString, privacy: .public) sourceStart=\(actualSourceStart, privacy: .public) sourceEnd=\(actualSourceEnd, privacy: .public)"
                )
                throw TimelineCompositionError.sliceOutsideSource(
                    role: role,
                    segmentID: slice.segmentID
                )
            }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: actualSourceStart, preferredTimescale: 60_000),
                duration: CMTime(seconds: sourceDuration, preferredTimescale: 60_000)
            )
            let outputStart = CMTime(
                seconds: slice.outputStart,
                preferredTimescale: 60_000
            )
            do {
                try destination.insertTimeRange(
                    sourceRange,
                    of: sourceTrack,
                    at: outputStart
                )
                if abs(slice.sourceTimeScale - 1) > 0.000_001 {
                    destination.scaleTimeRange(
                        CMTimeRange(start: outputStart, duration: sourceRange.duration),
                        toDuration: CMTime(
                            seconds: slice.duration,
                            preferredTimescale: 60_000
                        )
                    )
                }
            } catch {
                logger.error(
                    "composition insertion failed role=\(role, privacy: .public) segment=\(slice.segmentID.uuidString, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
                )
                throw TimelineCompositionError.insertionFailed(
                    role: role,
                    segmentID: slice.segmentID,
                    reason: error.localizedDescription
                )
            }
        }
        return destination
    }
}

enum TimelinePreviewMediaError: LocalizedError {
    case missingPrimaryRecording
    case missingDeclaredMedia(String)
    case missingTrack(String)
    case invalidTrackRange(String)

    var errorDescription: String? {
        switch self {
        case .missingPrimaryRecording:
            return "找不到主录屏素材，无法构建剪辑预览。"
        case let .missingDeclaredMedia(role):
            return "项目声明包含\(role)，但素材文件不可用。"
        case let .missingTrack(role):
            return "\(role)素材中没有可用轨道。"
        case let .invalidTrackRange(role):
            return "\(role)素材的时间范围无效。"
        }
    }
}

private struct LoadedTimelineTrack {
    /// Keep the source alive for as long as its track is used. Returning only
    /// the track from an async loader can make later composition insertion
    /// fail with AVFoundation -11800 / OSStatus -12780.
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let preferredTransform: CGAffineTransform
    let displaySize: CGSize?
}

enum TimelinePreviewCompositionLoader {
    static func prepare(
        request: EditorMediaRequest
    ) async throws -> EditorPreparedMediaPayload {
        try await prepare(
            sourceURL: request.source?.url,
            cameraURL: request.camera?.url,
            microphoneURL: request.microphone?.url,
            sourceSequence: request.sourceSequence,
            mediaManifest: request.mediaManifest,
            pointerEvents: request.pointerEvents
        )
    }

    private static func prepare(
        sourceURL: URL?,
        cameraURL: URL?,
        microphoneURL: URL?,
        sourceSequence: SourceSequence,
        mediaManifest: ProjectMediaManifest?,
        pointerEvents: [PointerEventRecord]
    ) async throws -> EditorPreparedMediaPayload {
        guard let sourceURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TimelinePreviewMediaError.missingPrimaryRecording
        }
        let source = try await loadTrack(
            at: sourceURL,
            mediaType: .video,
            role: "主录屏"
        )
        let declaredCameraURL: URL?
        if mediaManifest?.camera != nil {
            guard let cameraURL,
                  FileManager.default.fileExists(atPath: cameraURL.path) else {
                throw TimelinePreviewMediaError.missingDeclaredMedia("摄像头")
            }
            declaredCameraURL = cameraURL
        } else {
            declaredCameraURL = nil
        }

        let declaredMicrophoneURL: URL?
        if mediaManifest?.microphone != nil {
            guard let microphoneURL,
                  FileManager.default.fileExists(atPath: microphoneURL.path) else {
                throw TimelinePreviewMediaError.missingDeclaredMedia("麦克风")
            }
            declaredMicrophoneURL = microphoneURL
        } else {
            declaredMicrophoneURL = nil
        }

        // These inputs are independent files/metadata queries. Running them
        // serially made the first editor frame wait for source audio, camera
        // metadata, nine exact crop samples and microphone metadata one after
        // another. Structured child tasks preserve cancellation while making
        // project-open latency equal to the slowest branch instead of their sum.
        async let sourceAudioTask = loadOptionalTrack(
            at: sourceURL,
            mediaType: .audio,
            role: "系统声音"
        )
        async let cameraTask = loadTrackIfPresent(
            at: declaredCameraURL,
            mediaType: .video,
            role: "摄像头"
        )
        async let cameraContentCropTask = cameraContentCropIfPresent(
            at: declaredCameraURL
        )
        async let microphoneTask = loadTrackIfPresent(
            at: declaredMicrophoneURL,
            mediaType: .audio,
            role: "麦克风"
        )
        let (sourceAudio, camera, cameraContentCrop, microphone) = try await (
            sourceAudioTask,
            cameraTask,
            cameraContentCropTask,
            microphoneTask
        )

        guard let primaryRange = mediaRange(source.timeRange) else {
            throw TimelinePreviewMediaError.invalidTrackRange("主录屏")
        }
        let mediaPlan = try ProjectTimelineMediaPlan(
            sourceSequence: sourceSequence,
            mediaManifest: mediaManifest,
            primaryVideoRange: primaryRange,
            systemAudioRange: sourceAudio.flatMap { mediaRange($0.timeRange) },
            cameraRange: camera.flatMap { mediaRange($0.timeRange) },
            microphoneRange: microphone.flatMap { mediaRange($0.timeRange) },
            sourcePointerEvents: pointerEvents
        )
        let composition = try TimelineCompositionBuilder.build(
            plan: mediaPlan,
            primaryVideoTrack: source.track,
            primaryVideoRange: source.timeRange,
            primaryVideoPreferredTransform: source.preferredTransform,
            systemAudioTrack: sourceAudio?.track,
            systemAudioRange: sourceAudio?.timeRange,
            cameraTrack: camera?.track,
            cameraRange: camera?.timeRange,
            cameraPreferredTransform: camera?.preferredTransform ?? .identity,
            microphoneTrack: microphone?.track,
            microphoneRange: microphone?.timeRange
        )
        async let sourceDurationTask = assetDuration(at: sourceURL)
        async let cameraDurationTask = assetDurationIfPresent(at: declaredCameraURL)
        async let microphoneDurationTask = assetDurationIfPresent(at: declaredMicrophoneURL)
        let (sourceDuration, cameraDuration, microphoneDuration) = await (
            sourceDurationTask,
            cameraDurationTask,
            microphoneDurationTask
        )
        let sourceInventory = inventory(
            assetDuration: sourceDuration,
            video: source,
            audio: sourceAudio
        )
        let cameraInventory = inventory(
            assetDuration: cameraDuration,
            video: camera,
            audio: nil
        )
        let microphoneInventory = inventory(
            assetDuration: microphoneDuration,
            video: nil,
            audio: microphone
        )
        return EditorPreparedMediaPayload(
            composition: composition,
            inventories: EditorMediaInventories(
                source: sourceInventory,
                camera: cameraInventory,
                microphone: microphoneInventory
            ),
            sourceDisplaySize: source.displaySize ?? CGSize(width: 1_920, height: 1_080),
            cameraDisplaySize: CameraLetterboxAnalysis.croppedDisplaySize(
                camera?.displaySize,
                crop: cameraContentCrop
            ),
            cameraContentCrop: cameraContentCrop,
            cameraSource: camera.map {
                EditorPreparedCameraSource(
                    asset: $0.asset,
                    track: $0.track,
                    timeRange: $0.timeRange,
                    preferredTransform: $0.preferredTransform
                )
            }
        )
    }

    private static func loadTrack(
        at url: URL,
        mediaType: AVMediaType,
        role: String
    ) async throws -> LoadedTimelineTrack {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
            throw TimelinePreviewMediaError.missingTrack(role)
        }
        guard let timeRange = try? await track.load(.timeRange),
              mediaRange(timeRange) != nil else {
            throw TimelinePreviewMediaError.invalidTrackRange(role)
        }
        let preferredTransform = mediaType == .video
            ? ((try? await track.load(.preferredTransform)) ?? .identity)
            : .identity
        let displaySize = await displayedSize(
            for: track,
            mediaType: mediaType,
            preferredTransform: preferredTransform
        )
        return LoadedTimelineTrack(
            asset: asset,
            track: track,
            timeRange: timeRange,
            preferredTransform: preferredTransform,
            displaySize: displaySize
        )
    }

    private static func loadTrackIfPresent(
        at url: URL?,
        mediaType: AVMediaType,
        role: String
    ) async throws -> LoadedTimelineTrack? {
        guard let url else { return nil }
        return try await loadTrack(at: url, mediaType: mediaType, role: role)
    }

    private static func cameraContentCropIfPresent(
        at url: URL?
    ) async -> NormalizedCrop? {
        guard let url else { return nil }
        // 竖屏模式相机/手机可能输出带黑边的画框：检测内容区，几何与渲染
        // 统一按裁剪后的尺寸工作，否则 PIP 里几乎全是黑边。
        return await CameraLetterboxAnalysis.normalizedContentCrop(for: url)
    }

    private static func loadOptionalTrack(
        at url: URL,
        mediaType: AVMediaType,
        role: String
    ) async throws -> LoadedTimelineTrack? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
            return nil
        }
        guard let timeRange = try? await track.load(.timeRange),
              mediaRange(timeRange) != nil else {
            throw TimelinePreviewMediaError.invalidTrackRange(role)
        }
        let preferredTransform = mediaType == .video
            ? ((try? await track.load(.preferredTransform)) ?? .identity)
            : .identity
        let displaySize = await displayedSize(
            for: track,
            mediaType: mediaType,
            preferredTransform: preferredTransform
        )
        return LoadedTimelineTrack(
            asset: asset,
            track: track,
            timeRange: timeRange,
            preferredTransform: preferredTransform,
            displaySize: displaySize
        )
    }

    private static func assetDuration(at url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.duration).seconds).flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
    }

    private static func assetDurationIfPresent(at url: URL?) async -> TimeInterval {
        guard let url else { return 0 }
        return await assetDuration(at: url)
    }

    private static func inventory(
        assetDuration: TimeInterval,
        video: LoadedTimelineTrack?,
        audio: LoadedTimelineTrack?
    ) -> MediaAssetInventory {
        let videoRange = video.flatMap { mediaRange($0.timeRange) }
        let audioRange = audio.flatMap { mediaRange($0.timeRange) }
        let duration = [
            assetDuration,
            videoRange.map { max($0.end, 0) } ?? 0,
            audioRange.map { max($0.end, 0) } ?? 0,
        ].max() ?? 0
        return MediaAssetInventory(
            duration: duration,
            videoWidth: video?.displaySize.map { Double($0.width.rounded()) },
            videoHeight: video?.displaySize.map { Double($0.height.rounded()) },
            videoTimeRange: videoRange,
            audioTimeRange: audioRange
        )
    }

    private static func displayedSize(
        for track: AVAssetTrack,
        mediaType: AVMediaType,
        preferredTransform: CGAffineTransform
    ) async -> CGSize? {
        guard mediaType == .video,
              let naturalSize = try? await track.load(.naturalSize) else { return nil }
        let displayed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
            .size
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        return displayed
    }

    private static func mediaRange(_ range: CMTimeRange) -> MediaTimeRange? {
        guard range.start.isNumeric,
              range.duration.isNumeric else { return nil }
        return MediaTimeRange(
            start: range.start.seconds,
            duration: range.duration.seconds
        )
    }
}
