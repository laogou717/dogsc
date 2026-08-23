import AppKit
import AVFoundation
import CoreImage
import Foundation
import RecorderCore

enum ExportAssetRole: String, Equatable, Sendable {
    case screenRecording
    case cameraRecording
    case microphoneRecording
    case wallpaper

    var displayName: String {
        switch self {
        case .screenRecording: return "主录屏"
        case .cameraRecording: return "摄像头"
        case .microphoneRecording: return "麦克风"
        case .wallpaper: return "背景图片"
        }
    }
}

enum ExportMediaKind: String, Equatable, Sendable {
    case video
    case audio

    var displayName: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        }
    }
}

enum VideoExporterError: LocalizedError, Equatable, Sendable {
    case cancelled
    case cannotCreateSession
    case missingAssetReference(ExportAssetRole)
    case missingAssetFile(role: ExportAssetRole, path: String)
    case unreadableAsset(role: ExportAssetRole, path: String, reason: String)
    case missingMediaTrack(role: ExportAssetRole, media: ExportMediaKind)
    case invalidVideoGeometry(role: ExportAssetRole)
    case unusableMediaRange(ExportAssetRole)
    case cannotReadMediaTrack(role: ExportAssetRole, media: ExportMediaKind)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消导出。"
        case .cannotCreateSession:
            return "无法创建视频导出会话。"
        case let .missingAssetReference(role):
            return "项目声明录制了\(role.displayName)，但项目中没有对应的素材路径。请恢复素材后重试。"
        case let .missingAssetFile(role, path):
            return "\(role.displayName)素材不存在：\(path)。请恢复或重新定位素材后再导出。"
        case let .unreadableAsset(role, path, reason):
            return "无法读取\(role.displayName)素材 \(path)：\(reason)"
        case let .missingMediaTrack(role, media):
            return "\(role.displayName)素材中没有可用的\(media.displayName)轨，导出已停止以避免静默丢失内容。"
        case let .invalidVideoGeometry(role):
            return "\(role.displayName)素材的显示方向或尺寸无效，无法安全导出。"
        case let .unusableMediaRange(role):
            return "\(role.displayName)素材在成片时间线上没有可用内容，导出已停止。"
        case let .cannotReadMediaTrack(role, media):
            return "无法为\(role.displayName)素材创建\(media.displayName)读取器，导出已停止。"
        case let .exportFailed(reason):
            return "导出失败：\(reason)"
        }
    }
}

private struct LoadedVideoAsset {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
}

private struct LoadedAudioAsset {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
}

@MainActor
final class VideoExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var errorMessage: String?
    private var exportTask: Task<Void, Never>?

    func export(request: EditorExportRequest) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        lastExportURL = nil
        errorMessage = nil
        let cursorSource = CursorAssetLibrary.resolvedAsset(
            for: request.project.cursorStyle.assetID
        )?.renderSource()
        let progressRelay = ExportProgressRelay { [weak self] progress in
            self?.exportProgress = progress
        }

        exportTask = Task { [self] in
            defer { progressRelay.invalidate() }
            // The worker writes to a sibling .tmp file and atomically promotes
            // it only on success, so a pre-existing file at the target URL is
            // never truncated or destroyed by a failed or cancelled export.
            do {
                try await Self.performExport(
                    request: request,
                    cursorSource: cursorSource,
                    progressHandler: { progress in
                        progressRelay.submit(progress)
                    }
                )
                progressRelay.invalidate()
                exportProgress = 1
                lastExportURL = request.outputURL
                AppPreferences.playExportCompletionSound()
            } catch {
                errorMessage = Task.isCancelled ? nil : error.localizedDescription
            }
            isExporting = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    nonisolated private static func performExport(
        request: EditorExportRequest,
        cursorSource: CursorRenderSource?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        // The request builder checked these versions on the main thread. Check
        // again here before opening worker-owned AVAssets so a replacement in
        // the scheduling gap cannot produce a mixed-generation export.
        try request.assets.validateCurrentVersions()
        let project = request.project
        guard project.media != nil else {
            throw VideoExporterError.missingAssetReference(.screenRecording)
        }
        let requiredMedia = RequiredProjectMedia(project: project)
        let sourceURL = request.assets.source.url
        let cameraURL = request.assets.camera?.url
        let microphoneURL = request.assets.microphone?.url
        let wallpaperURL = request.assets.wallpaper?.url
        let source = try await loadRequiredVideo(
            at: sourceURL,
            role: .screenRecording
        )
        let displayedSourceSize = displayedVideoSize(
            naturalSize: source.naturalSize,
            preferredTransform: source.preferredTransform
        )
        let crop = project.canvas.crop.clamped()
        let sourceAspectRatio = Double(
            displayedSourceSize.width / max(displayedSourceSize.height, 1)
        ) * crop.width / crop.height
        let canvasSize = outputSize(
            for: project.canvas,
            resolution: project.exportSettings.resolution,
            sourceAspectRatio: sourceAspectRatio,
            sourcePixelSize: displayedSourceSize
        )

        let audioTrack: AVAssetTrack?
        let systemAudioTimeRange: CMTimeRange?
        let audioTracks = requiredMedia.systemAudio
            ? try await loadTracks(
                from: source.asset,
                mediaType: .audio,
                role: .screenRecording,
                url: sourceURL
            )
            : []
        if let embeddedAudioTrack = audioTracks.first {
            audioTrack = embeddedAudioTrack
            do {
                systemAudioTimeRange = try await embeddedAudioTrack.load(.timeRange)
            } catch {
                throw unreadableAssetError(role: .screenRecording, url: sourceURL, error: error)
            }
        } else {
            audioTrack = nil
            systemAudioTimeRange = nil
        }
        // The file inventory is authoritative in post-production. Capture
        // preferences can be stale after recovery, import, or an older project
        // migration; they must not make an otherwise valid video-only screen
        // recording impossible to export.

        let camera: LoadedVideoAsset?
        if requiredMedia.cameraVideo {
            guard let cameraURL else {
                throw VideoExporterError.missingAssetReference(.cameraRecording)
            }
            camera = try await loadRequiredVideo(at: cameraURL, role: .cameraRecording)
        } else {
            camera = nil
        }

        let microphone: LoadedAudioAsset?
        if requiredMedia.microphoneAudio {
            guard let microphoneURL else {
                throw VideoExporterError.missingAssetReference(.microphoneRecording)
            }
            microphone = try await loadRequiredAudio(at: microphoneURL, role: .microphoneRecording)
        } else {
            microphone = nil
        }

        let wallpaperImage: CIImage?
        if requiredMedia.backgroundImage {
            guard let wallpaperURL else {
                throw VideoExporterError.missingAssetReference(.wallpaper)
            }
            try validateRequiredFile(at: wallpaperURL, role: .wallpaper)
            guard let image = CIImage(
                contentsOf: wallpaperURL,
                options: [.applyOrientationProperty: true]
            ) else {
                throw VideoExporterError.unreadableAsset(
                    role: .wallpaper,
                    path: wallpaperURL.path,
                    reason: "文件不是可解码的图片。"
                )
            }
            wallpaperImage = image
        } else {
            wallpaperImage = nil
        }
        let mediaPlan = request.mediaPlan
        if requiredMedia.cameraVideo,
           mediaPlan.camera?.playableDuration ?? 0 <= 0 {
            throw VideoExporterError.unusableMediaRange(.cameraRecording)
        }
        if requiredMedia.microphoneAudio,
           mediaPlan.microphone?.playableDuration ?? 0 <= 0 {
            throw VideoExporterError.unusableMediaRange(.microphoneRecording)
        }
        let compositionBundle = try TimelineCompositionBuilder.build(
            plan: mediaPlan,
            primaryVideoTrack: source.track,
            primaryVideoRange: source.timeRange,
            primaryVideoPreferredTransform: source.preferredTransform,
            systemAudioTrack: audioTrack,
            systemAudioRange: systemAudioTimeRange,
            cameraTrack: camera?.track,
            cameraRange: camera?.timeRange,
            cameraPreferredTransform: camera?.preferredTransform ?? .identity,
            microphoneTrack: microphone?.track,
            microphoneRange: microphone?.timeRange
        )
        // 与编辑预览一致：摄像头素材带黑边时统一裁掉，保证导出与预览一致。
        let cameraContentCrop: NormalizedCrop?
        if requiredMedia.cameraVideo, let cameraURL {
            cameraContentCrop = await CameraLetterboxAnalysis.normalizedContentCrop(
                for: cameraURL
            )
        } else {
            cameraContentCrop = nil
        }
        let finalOutputURL = request.outputURL
        // Write to a sibling temporary file and promote it atomically only
        // after the writer completes, so an export failure or cancellation
        // never truncates or destroys a pre-existing file at the target URL.
        let temporaryOutputURL = finalOutputURL
            .deletingLastPathComponent()
            .appendingPathComponent(finalOutputURL.lastPathComponent + ".tmp")
        let pipeline = try DirectExportPipeline(
            media: compositionBundle,
            wallpaperImage: wallpaperImage,
            outputURL: temporaryOutputURL,
            canvasSize: canvasSize,
            project: project,
            cursorSource: cursorSource,
            frameRate: project.exportSettings.frameRate,
            cameraContentCrop: cameraContentCrop,
            progressHandler: progressHandler
        )
        do {
            try Task.checkCancellation()
            try await pipeline.run()
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutputURL)
            throw error
        }
        do {
            if FileManager.default.fileExists(atPath: finalOutputURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    finalOutputURL,
                    withItemAt: temporaryOutputURL
                )
            } else {
                try FileManager.default.moveItem(at: temporaryOutputURL, to: finalOutputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutputURL)
            throw VideoExporterError.exportFailed("写入最终文件失败：\(error.localizedDescription)")
        }
    }

    /// `naturalSize` is encoded-pixel geometry. The editor and exporter must
    /// use this display geometry after applying the track orientation matrix.
    nonisolated static func displayedVideoSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Applies `preferredTransform` to decoded pixels and moves the resulting
    /// image back to a zero-based extent so downstream crop math stays stable.
    nonisolated static func orientVideoFrameForDisplay(
        _ image: CIImage,
        preferredTransform: CGAffineTransform
    ) -> CIImage {
        let oriented = image.transformed(by: preferredTransform)
        let extent = oriented.extent.standardized
        return oriented.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
    }

    nonisolated private static func loadRequiredVideo(
        at url: URL,
        role: ExportAssetRole
    ) async throws -> LoadedVideoAsset {
        try validateRequiredFile(at: url, role: role)
        let asset = AVURLAsset(url: url)
        let tracks = try await loadTracks(
            from: asset,
            mediaType: .video,
            role: role,
            url: url
        )
        guard let track = tracks.first else {
            throw VideoExporterError.missingMediaTrack(role: role, media: .video)
        }

        do {
            let timeRange = try await track.load(.timeRange)
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let displaySize = displayedVideoSize(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            )
            guard displaySize.width.isFinite, displaySize.height.isFinite,
                  displaySize.width > 0, displaySize.height > 0 else {
                throw VideoExporterError.invalidVideoGeometry(role: role)
            }
            guard timeRange.start.isNumeric,
                  timeRange.duration.isNumeric,
                  timeRange.start.seconds.isFinite,
                  timeRange.duration.seconds.isFinite,
                  timeRange.duration.seconds > 0 else {
                throw VideoExporterError.unusableMediaRange(role)
            }
            return LoadedVideoAsset(
                asset: asset,
                track: track,
                timeRange: timeRange,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            )
        } catch let error as VideoExporterError {
            throw error
        } catch {
            throw unreadableAssetError(role: role, url: url, error: error)
        }
    }

    nonisolated private static func loadRequiredAudio(
        at url: URL,
        role: ExportAssetRole
    ) async throws -> LoadedAudioAsset {
        try validateRequiredFile(at: url, role: role)
        let asset = AVURLAsset(url: url)
        let tracks = try await loadTracks(
            from: asset,
            mediaType: .audio,
            role: role,
            url: url
        )
        guard let track = tracks.first else {
            throw VideoExporterError.missingMediaTrack(role: role, media: .audio)
        }

        do {
            let timeRange = try await track.load(.timeRange)
            guard timeRange.start.isNumeric,
                  timeRange.duration.isNumeric,
                  timeRange.start.seconds.isFinite,
                  timeRange.duration.seconds.isFinite,
                  timeRange.duration.seconds > 0 else {
                throw VideoExporterError.unusableMediaRange(role)
            }
            return LoadedAudioAsset(asset: asset, track: track, timeRange: timeRange)
        } catch let error as VideoExporterError {
            throw error
        } catch {
            throw unreadableAssetError(role: role, url: url, error: error)
        }
    }

    nonisolated private static func loadTracks(
        from asset: AVAsset,
        mediaType: AVMediaType,
        role: ExportAssetRole,
        url: URL
    ) async throws -> [AVAssetTrack] {
        do {
            return try await asset.loadTracks(withMediaType: mediaType)
        } catch {
            throw unreadableAssetError(role: role, url: url, error: error)
        }
    }

    nonisolated private static func validateRequiredFile(
        at url: URL,
        role: ExportAssetRole
    ) throws {
        guard url.isFileURL else {
            throw VideoExporterError.unreadableAsset(
                role: role,
                path: url.absoluteString,
                reason: "素材不是本地文件。"
            )
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw VideoExporterError.missingAssetFile(role: role, path: url.path)
        }
        guard !isDirectory.boolValue else {
            throw VideoExporterError.unreadableAsset(
                role: role,
                path: url.path,
                reason: "素材路径指向文件夹。"
            )
        }
    }

    nonisolated private static func unreadableAssetError(
        role: ExportAssetRole,
        url: URL,
        error: Error
    ) -> VideoExporterError {
        VideoExporterError.unreadableAsset(
            role: role,
            path: url.path,
            reason: error.localizedDescription
        )
    }

    nonisolated static func render(
        source: CIImage,
        cameraSource: CIImage? = nil,
        wallpaperSource: CIImage? = nil,
        cursorSource: CursorRenderSource? = nil,
        pointerEvents: [PointerEventRecord] = [],
        pointerTrack: PointerTrack? = nil,
        projectPointerTrack: ProjectPointerTrack? = nil,
        zoomTrack: ZoomAnimationTrack? = nil,
        at time: TimeInterval,
        canvasSize: CGSize,
        project: RecorderProject
    ) -> CIImage {
        let normalizedSource = source.transformed(
            by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
        )
        let pointerEvaluation = projectPointerTrack?.evaluation(
            at: time,
            motion: project.motion,
            style: project.cursorStyle
        ) ?? (pointerTrack ?? PointerTrack(pointerEvents)).evaluation(
            at: time,
            motion: project.motion,
            style: project.cursorStyle
        )
        let activeCameraSource = project.media?.camera == nil ? nil : cameraSource
        let frameScene = FrameSceneEvaluator.scene(
            project: project,
            time: time,
            canvasSize: CompositionSize(
                width: canvasSize.width,
                height: canvasSize.height
            ),
            sourceAspectRatio: normalizedSource.extent.width / max(normalizedSource.extent.height, 1),
            cameraSourceSize: activeCameraSource.map {
                CompositionSize(width: $0.extent.width, height: $0.extent.height)
            },
            pointerTrack: projectPointerTrack,
            pointerEvaluation: pointerEvaluation,
            cursorMetrics: cursorSource?.metrics,
            zoomTrack: zoomTrack
        )
        return SharedFrameRenderer.render(
            scene: frameScene,
            resources: SharedFrameRenderResources(
                screen: source,
                camera: activeCameraSource,
                wallpaper: wallpaperSource,
                cursor: cursorSource?.image
            )
        )
    }

    nonisolated private static func outputSize(
        for style: CanvasStyle,
        resolution: CanvasResolution,
        sourceAspectRatio: Double? = nil,
        sourcePixelSize: CGSize? = nil
    ) -> CGSize {
        let dimensions = style.pixelDimensions(
            resolution: resolution,
            sourceAspectRatio: sourceAspectRatio,
            sourcePixelSize: sourcePixelSize.map {
                CanvasDimensions(
                    width: max(Int($0.width.rounded()), 2),
                    height: max(Int($0.height.rounded()), 2)
                )
            }
        )
        return CGSize(width: dimensions.width, height: dimensions.height)
    }

}
