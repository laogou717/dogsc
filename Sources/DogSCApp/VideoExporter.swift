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
    case sticker

    var displayName: String {
        switch self {
        case .screenRecording: return "主录屏"
        case .cameraRecording: return "摄像头"
        case .microphoneRecording: return "麦克风"
        case .wallpaper: return "背景素材"
        case .sticker: return "贴图"
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
    case noAudioToExport
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
            return appLocalized("已取消导出。")
        case .cannotCreateSession:
            return appLocalized("无法创建导出会话。")
        case .noAudioToExport:
            return appLocalized("当前剪辑没有可导出的声音。")
        case let .missingAssetReference(role):
            return String(format: appLocalized("项目声明录制了%@，但项目中没有对应的素材路径。请恢复素材后重试。"), appLocalized(role.displayName))
        case let .missingAssetFile(role, path):
            return String(format: appLocalized("%@素材不存在：%@。请恢复或重新定位素材后再导出。"), appLocalized(role.displayName), path)
        case let .unreadableAsset(role, path, reason):
            return String(format: appLocalized("无法读取%@素材 %@：%@"), appLocalized(role.displayName), path, appLocalized(reason))
        case let .missingMediaTrack(role, media):
            return String(format: appLocalized("%@素材中没有可用的%@轨，导出已停止以避免静默丢失内容。"), appLocalized(role.displayName), appLocalized(media.displayName))
        case let .invalidVideoGeometry(role):
            return String(format: appLocalized("%@素材的显示方向或尺寸无效，无法安全导出。"), appLocalized(role.displayName))
        case let .unusableMediaRange(role):
            return String(format: appLocalized("%@素材在成片时间线上没有可用内容，导出已停止。"), appLocalized(role.displayName))
        case let .cannotReadMediaTrack(role, media):
            return String(format: appLocalized("无法为%@素材创建%@读取器，导出已停止。"), appLocalized(role.displayName), appLocalized(media.displayName))
        case let .exportFailed(reason):
            return String(format: appLocalized("导出失败：%@"), appLocalized(reason))
        }
    }
}

struct LoadedVideoAsset {
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
    @Published private(set) var status = ExportStatus()
    private var statusTask: Task<Void, Never>?
    private var jobID: UUID?
    private var startedUptime: TimeInterval = 0
    private var estimator = ExportTimeEstimator()
    private var exportTask: Task<Void, Never>?

    func export(request: EditorExportRequest) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        lastExportURL = nil
        errorMessage = nil
        let currentJobID = UUID()
        jobID = currentJobID
        startedUptime = ProcessInfo.processInfo.systemUptime
        estimator = ExportTimeEstimator()
        status = ExportStatus(audioOnly: request.outputKind == .audio)
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.jobID == currentJobID, self.isExporting else { return }
                self.refreshStatus()
            }
        }
        let cursorSources: [CursorAssetID: CursorRenderSource] = Dictionary(
            uniqueKeysWithValues: CursorAssetLibrary.renderAssets.compactMap { asset in
                guard asset.id != .automatic,
                      let source = asset.renderSource() else { return nil }
                return (asset.id, source)
            }
        )
        let progressRelay = ExportProgressRelay { [weak self] progress in
            guard let self, self.jobID == currentJobID, self.isExporting else { return }
            self.exportProgress = max(self.exportProgress, progress)
        }

        exportTask = Task { [self] in
            // Export is a user-initiated job even when its editor is hidden.
            // Balance the activity on success, failure, and cancellation.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                reason: "正在导出录屏作品")
            defer {
                progressRelay.invalidate()
                ProcessInfo.processInfo.endActivity(activity)
            }
            // The worker writes to a sibling .tmp file and atomically promotes
            // it only on success, so a pre-existing file at the target URL is
            // never truncated or destroyed by a failed or cancelled export.
            do {
                try await Self.performExport(
                    request: request,
                    cursorSources: cursorSources,
                    progressHandler: { progress in
                        progressRelay.submit(progress)
                    },
                    stageHandler: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            guard let self, self.jobID == currentJobID, self.isExporting else { return }
                            self.setStage(stage)
                        }
                    }
                )
                progressRelay.invalidate()
                exportProgress = 1
                lastExportURL = request.outputURL
                AppPreferences.playExportCompletionSound()
            } catch {
                errorMessage = Task.isCancelled ? nil : error.localizedDescription
            }
            progressRelay.invalidate()
            refreshStatus()
            statusTask?.cancel()
            statusTask = nil
            jobID = nil
            isExporting = false
            exportTask = nil
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        setStage(.cancelling)
        exportTask?.cancel()
    }

    private func setStage(_ stage: ExportStage) {
        guard stage.rawValue > status.stage.rawValue else { return }
        status.stage = stage
        estimator.restart(at: ProcessInfo.processInfo.systemUptime - startedUptime, progress: exportProgress)
        refreshStatus()
    }

    private func refreshStatus() {
        let elapsed = max(ProcessInfo.processInfo.systemUptime - startedUptime, 0)
        let estimate = estimator.sample(elapsed: elapsed, progress: exportProgress)
        status.elapsed = elapsed
        status.secondsWithoutProgress = estimate.idle
        status.remaining = status.stage == .processing ? estimate.remaining : nil
    }

    /// An export result belongs to the editor generation that produced it.
    /// Reusing the application-wide exporter for another project must not show
    /// the previous project's file as if the new project had just exported.
    func resetResultForNewEditorSession() {
        guard !isExporting else { return }
        exportProgress = 0
        lastExportURL = nil
        errorMessage = nil
        status = ExportStatus()
    }

    func resetResultForNewExportSelection() {
        resetResultForNewEditorSession()
    }

    nonisolated static func performExport(
        request: EditorExportRequest,
        cursorSources: [CursorAssetID: CursorRenderSource],
        progressHandler: (@Sendable (Double) -> Void)?,
        stageHandler: @escaping @Sendable (ExportStage) -> Void
    ) async throws {
        // The request builder checked these versions on the main thread. Check
        // again here before opening worker-owned AVAssets so a replacement in
        // the scheduling gap cannot produce a mixed-generation export.
        try request.assets.validateCurrentVersions()
        let project = request.project
        guard project.media != nil else {
            throw VideoExporterError.missingAssetReference(.screenRecording)
        }
        if request.outputKind == .video { try await OverlayVideoSource.validateExport(request) }
        let requiredMedia = RequiredProjectMedia(project: project)
        let wallpaperURL = request.assets.wallpaper?.url
        var frozenSources = request.assets.additionalSources
        frozenSources[RecordingSource.primaryID] = EditorExportRecordingAssets(
            source: request.assets.source, camera: request.assets.camera,
            microphone: request.assets.microphone)
        var sourceTracks: [UUID: TimelineRecordingSourceTracks] = [:]
        for (id, assets) in frozenSources {
            try Task.checkCancellation()
            guard let source = project.source(id) else {
                throw EditorExportRequestError.mediaManifestMismatch
            }
            let required = RequiredProjectMedia(project: project, sourceID: id)
            sourceTracks[id] = try await TimelinePreviewCompositionLoader.loadRecording(
                screenURL: assets.source.url, cameraURL: assets.camera?.url,
                microphoneURL: assets.microphone?.url, manifest: source.media,
                pointerEvents: request.mediaPlan.sources[id]?.pointerEvents ?? [],
                cameraContentCrop: source.cameraContentCrop,
                needsCamera: request.outputKind == .video && required.cameraVideo,
                needsMicrophone: required.microphoneAudio, needsSystemAudio: required.systemAudio)
        }
        guard let displayedSourceSize = sourceTracks[RecordingSource.primaryID]?.screen.displaySize else {
            throw VideoExporterError.missingAssetReference(.screenRecording)
        }
        let crop = project.canvas.crop.clamped()
        let sourceAspectRatio = Double(displayedSourceSize.width / max(displayedSourceSize.height, 1))
            * crop.width / crop.height
        let nativeSize = EditorRecordingCanvasGeometry.sourceSize(project: project,
            sizes: sourceTracks.compactMapValues { $0.screen.displaySize })
        let requestedSize = outputSize(for: project.canvas, resolution: project.exportSettings.resolution,
            sourceAspectRatio: sourceAspectRatio, sourcePixelSize: nativeSize)
        let outputDimensions = project.exportSettings.outputDimensions(
            for: CanvasDimensions(width: Int(requestedSize.width), height: Int(requestedSize.height))
        )
        let canvasSize = CGSize(width: outputDimensions.width, height: outputDimensions.height)

        let wallpaperImage: CIImage?
        if request.outputKind == .video, requiredMedia.backgroundImage {
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
        let wallpaperVideo: LoadedVideoAsset?
        if request.outputKind == .video, requiredMedia.backgroundVideo {
            guard let wallpaperURL else {
                throw VideoExporterError.missingAssetReference(.wallpaper)
            }
            wallpaperVideo = try await loadRequiredVideo(
                at: wallpaperURL,
                role: .wallpaper
            )
        } else {
            wallpaperVideo = nil
        }
        var sceneWallpaperImages: [String: CIImage] = [:]
        var sceneWallpaperVideos: [String: LoadedVideoAsset] = [:]
        for source in project.sceneBackgroundSources {
            guard let key = source.sceneResourceKey, let asset = request.assets.sceneWallpapers[key] else { continue }
            if source.isVideo {
                sceneWallpaperVideos[key] = try await loadRequiredVideo(at: asset.url, role: .wallpaper)
            } else {
                guard let image = CIImage(contentsOf: asset.url, options: [.applyOrientationProperty: true]) else {
                    throw VideoExporterError.unreadableAsset(role: .wallpaper, path: asset.url.path, reason: "文件不是可解码的图片。")
                }
                sceneWallpaperImages[key] = image
            }
        }
        var stickerImages: [String: CIImage] = [:]
        stickerImages.reserveCapacity(request.assets.stickers.count)
        for (relativePath, asset) in request.assets.stickers
            where request.outputKind == .video {
            guard let image = CIImage(
                contentsOf: asset.url,
                options: [.applyOrientationProperty: true]
            ) else {
                throw VideoExporterError.unreadableAsset(
                    role: .sticker,
                    path: asset.url.path,
                    reason: "文件不是可解码的图片。"
                )
            }
            stickerImages[relativePath] = image
        }
        let mediaPlan = request.mediaPlan
        if request.outputKind == .video,
           requiredMedia.cameraVideo,
           mediaPlan.camera?.playableDuration ?? 0 <= 0 {
            throw VideoExporterError.unusableMediaRange(.cameraRecording)
        }
        if requiredMedia.microphoneAudio,
           mediaPlan.microphone?.playableDuration ?? 0 <= 0 {
            throw VideoExporterError.unusableMediaRange(.microphoneRecording)
        }
        let insertedVideo = await TimelineCompositionBuilder.loadInsertedVideo(for: mediaPlan.primary)
        let compositionBundle = try TimelineCompositionBuilder.build(
            plan: mediaPlan, sources: sourceTracks,
            audioClips: project.timeline.programAudioClips(audio: project.audio),
            speech: project.timeline.subtitleCues.map(\.timing), insertedVideo: insertedVideo)
        let finalOutputURL = request.outputURL
        // Write to a sibling temporary file and promote it atomically only
        // after the writer completes, so an export failure or cancellation
        // never truncates or destroys a pre-existing file at the target URL.
        let temporaryOutputURL = ExportFileTransaction.makeTemporaryURL(
            for: finalOutputURL
        )
        defer { try? FileManager.default.removeItem(at: temporaryOutputURL) }
        try Task.checkCancellation()
        switch request.outputKind {
        case .video:
            let preparedAudio = try await RenderedExportAudio.prepare(media: compositionBundle,
                project: project, outputRange: request.outputRange,
                normalizesLoudness: request.normalizesAudioLoudness)
            let pipeline = try await DirectExportPipeline(
                media: compositionBundle,
                wallpaperImage: wallpaperImage,
                wallpaperVideo: wallpaperVideo,
                sceneWallpaperImages: sceneWallpaperImages,
                sceneWallpaperVideos: sceneWallpaperVideos,
                stickerImages: stickerImages,
                imageURLs: request.assets.stickers.mapValues(\.url),
                outputURL: temporaryOutputURL,
                canvasSize: canvasSize,
                project: project,
                cursorSources: cursorSources,
                frameRate: project.exportSettings.frameRate,
                outputRange: request.outputRange,
                preparedAudio: preparedAudio,
                stageHandler: stageHandler,
                progressHandler: progressHandler
            )
            stageHandler(.processing)
            try await pipeline.run()
        case .audio:
            let pipeline = try AudioOnlyExportPipeline(
                media: compositionBundle,
                outputURL: temporaryOutputURL,
                project: project,
                outputRange: request.outputRange,
                normalizesAudioLoudness: request.normalizesAudioLoudness,
                progressHandler: progressHandler
            )
            stageHandler(.processing)
            try await pipeline.run()
        }
        stageHandler(.finishing)
        try Task.checkCancellation()
        do {
            try ExportFileTransaction.promote(
                temporaryURL: temporaryOutputURL,
                to: finalOutputURL
            )
        } catch {
            throw VideoExporterError.exportFailed(String(format: appLocalized("写入最终文件失败：%@"), error.localizedDescription))
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
