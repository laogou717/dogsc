import AVFoundation
import CoreImage
import Foundation
import OSLog
import RecorderCore
import VideoToolbox

enum ExportVideoCodecPolicy {
    static func codec(width: Int, height: Int, selection: ExportVideoCodec? = nil) -> AVVideoCodecType {
        let chosen = selection ?? ExportSettings().resolvedVideoCodec(
            for: CanvasDimensions(width: width, height: height)
        )
        return chosen == .hevc ? .hevc : .h264
    }
}

/// A cut between two retained timeline segments is not a camera-availability
/// gap. Keep a valid frame across that boundary until the new composition
/// slice can provide its first decoded frame. Clearing the frame at every cut
/// makes the camera layer transparent for ordinary VFR/decode latency.
enum ExportCameraCutContinuity {
    static func frame<Frame>(previous: Frame?, firstFrameInNextSlice: Frame?) -> Frame? {
        firstFrameInNextSlice ?? previous
    }
}

/// One lock owner for cancellation visibility across the task, video queue
/// and audio queue. The pipeline's completion lock protects group membership;
/// it must not double as a cancellation flag on one queue while another queue
/// reads that flag under an unrelated lock.
final class ExportCancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}

/// Owns one immutable export job and all serialized AVFoundation writer state.
final class DirectExportPipeline: @unchecked Sendable {
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "export")
    private let videoReader: ExportTimelineVideoReader
    private let recordingSources: [UUID: TimelineRecordingSourceTracks]
    private let insertedSources: [String: LoadedTimelineTrack]
    private let preparedAudio: RenderedExportAudio?
    private let audioReader: ExportSampleReader?
    private let cameraReader: ExportTimelineVideoReader?
    private let motionSession = ExportHTMLMotionSession()
    private let videoDecoder = VideoOverlayDecoder()
    private let aspectTransitions: RecordingAspectTransitions
    private let primaryPlan: TimelineMediaPlan
    private let cameraPlan: TimelineMediaPlan?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let canvasSize: CGSize
    private let project: RecorderProject
    private let frameRate: OutputFrameRate
    private let outputFrameSchedule: OutputFrameSchedule
    private let renderRange: MediaTimeRange
    private let projectOutputDuration: TimeInterval
    private let sceneWallpaperImages: [String: CIImage]
    private let sceneWallpaperReaders: [String: ExportLoopingWallpaperVideoReader]
    private let wallpaperImage: CIImage?
    private let wallpaperVideoReader: ExportLoopingWallpaperVideoReader?
    private let stickerImages: [String: CIImage]
    private let imageURLs: [String: URL]
    private let cursorSources: [CursorAssetID: CursorRenderSource]
    private let cursorMetricsByAssetID: [CursorAssetID: CursorAssetMetrics]
    private let pointerTrack: ProjectPointerTrack
    private let zoomTrack: ZoomAnimationTrack
    private let screenMotionTrack: ScreenMotionTrack
    private let cameraMotionTrack: CameraMotionTrack
    private let stickerTrack: StickerTransitionTrack
    private let stageHandler: @Sendable (ExportStage) -> Void
    private let progressHandler: (@Sendable (Double) -> Void)?
    private let colorProfile: CoreImageFrameColorProfile
    private let context: CIContext
    private let group = DispatchGroup()
    private let videoQueue = DispatchQueue(
        label: "cn.laogou.dogsc.export.video",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "cn.laogou.dogsc.export.audio",
        qos: .userInitiated
    )
    private let finishQueue = DispatchQueue(label: "cn.laogou.dogsc.export.finish")
    private let stateLock = NSLock()
    private let completionLock = NSLock()
    private var pipelineError: (any Error)?
    private var videoFinished = false
    private var audioFinished = false
    private var videoGroupEntered = false
    private var audioGroupEntered = false
    private var workersStarted = false
    private let cancellation = ExportCancellationLatch()
    private var watchdog: ExportActivityWatchdog?
    private var frameIndex = 0
    private var currentCameraPixelBuffer: CVPixelBuffer?
    private var currentCameraSourceID: UUID?
    private let cameraBeautyTracker = CameraBeautyTracker()
    /// Consecutive transient backpressure failures (append / pixel pool).
    /// Reset on every successful append; a sustained run terminates the job
    /// instead of busy-looping inside readiness callbacks.
    private var transientBackpressureCount = 0

    init(
        media: TimelineCompositionBundle,
        wallpaperImage: CIImage?,
        wallpaperVideo: LoadedVideoAsset?,
        sceneWallpaperImages: [String: CIImage] = [:],
        sceneWallpaperVideos: [String: LoadedVideoAsset] = [:],
        stickerImages: [String: CIImage] = [:],
        imageURLs: [String: URL] = [:],
        outputURL: URL,
        canvasSize: CGSize,
        project: RecorderProject,
        cursorSources: [CursorAssetID: CursorRenderSource],
        frameRate: OutputFrameRate,
        outputRange: MediaTimeRange? = nil,
        preparedAudio: RenderedExportAudio? = nil,
        stageHandler: @escaping @Sendable (ExportStage) -> Void = { _ in },
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let audioSource = try await preparedAudio?.loadSource()
        let colorProfile: CoreImageFrameColorProfile
        do {
            colorProfile = try CoreImageFrameColorProfile(contract: .sdrDesktop)
        } catch {
            throw VideoExporterError.exportFailed(error.localizedDescription)
        }
        self.colorProfile = colorProfile
        context = colorProfile.makeContext(cacheIntermediates: false)
        self.canvasSize = canvasSize
        self.project = project
        self.frameRate = frameRate
        let renderRange = outputRange ?? MediaTimeRange(
            start: 0,
            duration: media.plan.outputDuration
        )!
        self.renderRange = renderRange
        self.preparedAudio = preparedAudio
        projectOutputDuration = media.plan.outputDuration
        let outputFrameSchedule = try OutputFrameSchedule(
            duration: renderRange.duration,
            frameRate: frameRate
        )
        self.outputFrameSchedule = outputFrameSchedule
        // This CMTime only limits asset reading. Frame count and output PTS
        // remain exclusively owned by OutputFrameSchedule above.
        let readerDuration = CMTime(
            seconds: outputFrameSchedule.duration,
            preferredTimescale: 1_000_000_000
        )
        self.aspectTransitions = RecordingAspectTransitions(primary: media.plan.primary,
            sourceAspectRatios: media.recordingSources.compactMapValues { tracks in
                tracks.screen.displaySize.map { Double($0.width / max($0.height, 1)) }
            }, crops: Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.crop) }),
            frameStyles: Dictionary(uniqueKeysWithValues: project.sources.map {
                ($0.id, $0.screenAppearance?.screenFrame ?? project.canvas.screenFrame)
            }), segmentStyles: project.segmentSceneStyles, segmentCrops: project.segmentCrops)
        self.primaryPlan = outputRange.map { TimelineMediaPlan(clipping: media.plan.primary, to: $0) }
            ?? media.plan.primary
        self.cameraPlan = media.plan.camera.map { plan in
            outputRange.map { TimelineMediaPlan(clipping: plan, to: $0) } ?? plan
        }
        self.recordingSources = media.recordingSources
        self.insertedSources = media.insertedSources
        self.sceneWallpaperImages = sceneWallpaperImages
        self.sceneWallpaperReaders = try sceneWallpaperVideos.mapValues { try ExportLoopingWallpaperVideoReader(source: $0) }
        self.wallpaperImage = wallpaperImage
        wallpaperVideoReader = try wallpaperVideo.map {
            try ExportLoopingWallpaperVideoReader(source: $0)
        }
        self.stickerImages = stickerImages
        self.imageURLs = imageURLs
        self.cursorSources = cursorSources
        cursorMetricsByAssetID = cursorSources.mapValues(\.metrics)
        self.pointerTrack = media.plan.pointer
        self.zoomTrack = ZoomAnimationTrack(project.zoomAnimations, outputDuration: media.plan.outputDuration)
        self.screenMotionTrack = ScreenMotionTrack(project.timeline.screenMotionClips)
        self.cameraMotionTrack = CameraMotionTrack(project.timeline.cameraMotionClips)
        self.stickerTrack = StickerTransitionTrack(project.timeline.stickerClips)
        self.stageHandler = stageHandler
        self.progressHandler = progressHandler
        videoReader = ExportTimelineVideoReader(sources: media.recordingSources.mapValues(\.screen),
            inserted: media.insertedSources, offsets: media.plan.sourceTimeOffsets, role: .screenRecording)
        let cameras = media.recordingSources.compactMapValues(\.camera)
        cameraReader = cameras.isEmpty || media.plan.camera == nil ? nil
            : ExportTimelineVideoReader(sources: cameras, role: .cameraRecording)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        let selectedCodec = project.exportSettings.resolvedVideoCodec(
            for: CanvasDimensions(width: width, height: height)
        )
        let bitrate = ExportEncodingPolicy.videoBitrate(
            width: width,
            height: height,
            frameRate: frameRate.rawValue,
            codec: selectedCodec,
            quality: project.exportSettings.quality
        )
        let codec = ExportVideoCodecPolicy.codec(width: width, height: height, selection: selectedCodec)
        let profileLevel: String = codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel as String
            : AVVideoProfileLevelH264HighAutoLevel
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
            AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue * 2,
            AVVideoProfileLevelKey: profileLevel,
            AVVideoAllowFrameReorderingKey: true,
        ]
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: colorProfile.avVideoColorProperties,
                AVVideoEncoderSpecificationKey: [
                    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = 90_000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw VideoExporterError.exportFailed("无法创建硬件视频编码轨")
        }
        writer.add(videoInput)

        let outputAudioTracks = media.mixedAudioTracks
        if !outputAudioTracks.isEmpty {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ]
            guard let audioSource else {
                throw VideoExporterError.exportFailed("导出混音尚未准备完成")
            }
            let reader = try AVAssetReader(asset: audioSource.asset)
            let output = AVAssetReaderTrackOutput(track: audioSource.track, outputSettings: settings)
            reader.timeRange = CMTimeRange(start: .zero, duration: readerDuration)
            guard reader.canAdd(output) else {
                throw VideoExporterError.exportFailed("无法创建混音读取器")
            }
            reader.add(output)
            audioReader = ExportSampleReader(reader: reader, output: output)

            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: ExportEncodingPolicy.audioBitrate,
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw VideoExporterError.exportFailed("无法创建 AAC 混音编码轨")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioReader = nil
            audioInput = nil
        }
    }

    func run() async throws {
        try Task.checkCancellation()
        guard writer.startWriting() else {
            throw writer.error ?? VideoExporterError.exportFailed("编码器无法启动")
        }
        writer.startSession(atSourceTime: .zero)
        if let audioReader, !audioReader.startReading() {
            if writer.status == .writing { writer.cancelWriting() }
            throw audioReader.error ?? VideoExporterError.exportFailed("混音素材无法读取")
        }

        watchdog = ExportActivityWatchdog { [weak self] in
            self?.requestStop(error: VideoExporterError.exportFailed(
                "媒体处理已超过 120 秒没有进展，导出已停止。请重试导出。"
            ))
        }
        defer {
            watchdog?.cancel()
            Task { @MainActor [motionSession] in motionSession.close() }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                completionLock.lock()
                if cancellation.isRequested {
                    completionLock.unlock()
                    audioReader?.cancelReading()
                    if writer.status == .writing { writer.cancelWriting() }
                    continuation.resume(throwing: currentError() ?? VideoExporterError.cancelled)
                    return
                }
                group.enter()
                videoGroupEntered = true
                if audioInput != nil, audioReader != nil {
                    group.enter()
                    audioGroupEntered = true
                }
                videoInput.requestMediaDataWhenReady(
                    on: videoQueue
                ) { [self] in
                    processVideo()
                }

                if let audioInput, audioReader != nil {
                    audioInput.requestMediaDataWhenReady(
                        on: audioQueue
                    ) { [self] in
                        processAudio()
                    }
                }
                workersStarted = true
                completionLock.unlock()

                group.notify(
                    queue: finishQueue
                ) { [self] in
                    if let pipelineError = currentError() {
                        audioReader?.cancelReading()
                        if writer.status == .writing { writer.cancelWriting() }
                        continuation.resume(throwing: pipelineError)
                        return
                    }
                    if let audioReader, audioReader.status == .failed {
                        if writer.status == .writing { writer.cancelWriting() }
                        continuation.resume(
                            throwing: audioReader.error
                                ?? VideoExporterError.exportFailed("混音读取失败")
                        )
                        return
                    }
                    watchdog?.recordProgress()
                    guard writer.status == .writing else {
                        continuation.resume(throwing: writer.error
                            ?? VideoExporterError.exportFailed("编码器结束异常"))
                        return
                    }
                    stageHandler(.finishing)
                    // The final encoded frame/audio packet can extend past a
                    // non-frame-aligned selection. End the file at the authored
                    // boundary, rather than at the end of that packet.
                    writer.endSession(atSourceTime: CMTime(
                        seconds: outputFrameSchedule.duration,
                        preferredTimescale: 1_000_000_000
                    ))
                    writer.finishWriting { [self] in
                        if let error = currentError() {
                            continuation.resume(throwing: error)
                        } else if writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(
                                throwing: currentError() ?? writer.error
                                    ?? VideoExporterError.exportFailed("编码器结束异常")
                            )
                        }
                    }
                }
            }
        } onCancel: { [self] in
            requestCancellation()
        }
    }

    private func processVideo() {
        guard !hasVideoFinished else { return }
        let durationSeconds = projectOutputDuration
        let totalFrames = outputFrameSchedule.frameCount
        guard totalFrames > 0 else {
            finishVideo(error: nil)
            return
        }
        while !hasVideoFinished,
              !isCancellationRequested,
              videoInput.isReadyForMoreMediaData,
              frameIndex < totalFrames {
            var transientFailure = false
            autoreleasepool {
                if writer.status == .failed {
                    finishVideo(error: writer.error
                        ?? VideoExporterError.exportFailed("视频编码器已失效"))
                    return
                }
                guard let outputFrame = outputFrameSchedule.frame(at: frameIndex) else {
                    finishVideo(error: VideoExporterError.exportFailed("输出帧时间表越界"))
                    return
                }
                let outputTime = CMTime(
                    value: outputFrame.presentationTimeValue,
                    timescale: outputFrame.presentationTimescale
                )
                // Keep the authored Double clock for all scene lookups. A
                // CMTime round trip at the first frame could leave motion and
                // appearance on the preceding segment while video had advanced.
                let targetSeconds = min(
                    renderRange.start + outputTime.seconds,
                    renderRange.end - min(0.000_000_01, renderRange.duration / 2)
                )
                guard let slice = primaryPlan.slice(atOutputTime: targetSeconds) else {
                    finishVideo(error: VideoExporterError.exportFailed("成片时间没有对应的主录屏片段"))
                    return
                }
                let sourcePixelBuffer: CVPixelBuffer
                let cameraBuffer: CVPixelBuffer?
                do {
                    guard let frame = try videoReader.frame(in: slice, at: targetSeconds,
                        cancellation: cancellation, progress: { watchdog?.recordProgress() }) else {
                        throw VideoExporterError.exportFailed("没有读到可渲染的视频帧")
                    }
                    sourcePixelBuffer = frame
                    cameraBuffer = try cameraPixelBuffer(at: targetSeconds)
                } catch {
                    finishVideo(error: error)
                    return
                }
                guard let pool = adaptor.pixelBufferPool else {
                    // 编码器背压的瞬时状态：结束本批，等待下一次 readiness 回调重试。
                    transientFailure = true
                    return
                }

                var destinationBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer)
                guard status == kCVReturnSuccess, let destinationBuffer else {
                    // 缓冲池瞬时耗尽同属背压：交给下一次回调重试。
                    transientFailure = true
                    return
                }

                let sourceImage = VideoExporter.orientVideoFrameForDisplay(
                    CIImage(cvPixelBuffer: sourcePixelBuffer),
                    preferredTransform: slice.media.flatMap { insertedSources[$0.path]?.preferredTransform }
                        ?? recordingSources[slice.sourceID]?.screen.preferredTransform ?? .identity
                )
                let cameraImage = cameraBuffer.map { pixelBuffer in
                    let oriented = VideoExporter.orientVideoFrameForDisplay(
                        CIImage(cvPixelBuffer: pixelBuffer),
                        preferredTransform: cameraPlan?.slice(atOutputTime: targetSeconds)
                            .flatMap { recordingSources[$0.sourceID]?.camera?.preferredTransform } ?? .identity
                    )
                    guard let cameraSlice = cameraPlan?.slice(atOutputTime: targetSeconds),
                          let cameraContentCrop = recordingSources[cameraSlice.sourceID]?.cameraContentCrop else { return oriented }
                    // 与编辑预览一致：带黑边的摄像头素材按内容区裁剪，
                    // 几何（extent）与画面同时收缩。
                    return CameraLetterboxAnalysis.cropped(oriented, to: cameraContentCrop)
                }
                let normalizedSource = sourceImage.transformed(
                    by: CGAffineTransform(
                        translationX: -sourceImage.extent.minX,
                        y: -sourceImage.extent.minY
                    )
                )
                let renderPlan = FrameSceneEvaluator.renderPlan(
                    project: project,
                    presentationTime: targetSeconds,
                    outputDuration: durationSeconds,
                    frameRate: frameRate.rawValue,
                    canvasSize: CompositionSize(
                        width: canvasSize.width,
                        height: canvasSize.height
                    ),
                    sourceAspectRatio: normalizedSource.extent.width
                        / max(normalizedSource.extent.height, 1),
                    cameraSourceSize: cameraImage.map {
                        CompositionSize(width: $0.extent.width, height: $0.extent.height)
                    },
                    pointerTrack: pointerTrack,
                    cursorMetrics: cursorSources[project.cursorStyle.assetID]?.metrics,
                    cursorMetricsByAssetID: cursorMetricsByAssetID,
                    zoomTrack: zoomTrack,
                    screenMotionTrack: screenMotionTrack,
                    cameraMotionTrack: cameraMotionTrack,
                    stickerTrack: stickerTrack,
                    cameraTimeline: cameraPlan,
                    recordingSourceID: slice.media == nil ? slice.sourceID : nil,
                    geometrySourceAspectRatio: aspectTransitions.sourceAspectRatio(
                        atOutputTime: targetSeconds, sourceID: slice.media == nil ? slice.sourceID : nil)
                )
                let cursorSource = renderPlan.scene.cursor.flatMap {
                    cursorSources[$0.assetID]
                }
                let wallpaperFrame: CIImage?
                do {
                    if let key = renderPlan.scene.background.source.sceneResourceKey,
                       sceneWallpaperReaders[key] != nil || sceneWallpaperImages[key] != nil {
                        wallpaperFrame = try sceneWallpaperReaders[key]?.frame(at: targetSeconds) ?? sceneWallpaperImages[key]
                    } else {
                        wallpaperFrame = try wallpaperVideoReader?.frame(at: targetSeconds) ?? wallpaperImage
                    }
                } catch {
                    finishVideo(error: error)
                    return
                }
                var resources = SharedFrameRenderResources(
                    screen: sourceImage, camera: cameraImage, wallpaper: wallpaperFrame,
                    cursor: cursorSource?.image, stickers: stickerImages, animations: [:])
                do {
                    resources.animations = try animationImages(for: renderPlan.scene, at: targetSeconds)
                    resources.videos = try videoImages(for: renderPlan.scene, at: targetSeconds)
                    let cameraSlice = cameraPlan?.slice(atOutputTime: targetSeconds)
                    resources.cameraBeauty = CameraBeautyFrame(tracker: cameraBeautyTracker,
                        time: cameraSlice?.sourceTime(atOutputTime: targetSeconds) ?? targetSeconds,
                        sourceID: cameraSlice?.sourceID)
                    for sticker in renderPlan.scene.stickers {
                        if let url = imageURLs[sticker.relativePath] {
                            resources.timedStickers[sticker.id] = ImageMediaFrameCache.shared.frame(at: url, time: sticker.sourceTime)
                        }
                    }
                    resources.insertedMotion = try insertedMotionImage(for: renderPlan.scene, at: targetSeconds)
                    if let image = renderPlan.scene.insertedImage {
                        guard let url = imageURLs[image.sourcePath],
                              let frame = ImageMediaFrameCache.shared.frame(at: url, time: image.localTime) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        resources.insertedImage = frame
                    }
                } catch {
                    finishVideo(error: error)
                    return
                }
                let canvasRect = CGRect(origin: .zero, size: canvasSize)
                guard let outputImage = SharedFrameCompositor.composite(
                    renderPlan,
                    resources: resources,
                    extent: canvasRect
                ) else {
                    finishVideo(error: VideoExporterError.exportFailed("无法合成输出帧"))
                    return
                }
                colorProfile.applyAttachments(to: destinationBuffer)
                context.render(
                    outputImage,
                    to: destinationBuffer,
                    bounds: canvasRect,
                    colorSpace: colorProfile.outputColorSpace
                )

                guard adaptor.append(destinationBuffer, withPresentationTime: outputTime) else {
                    if writer.status == .failed || writer.error != nil {
                        finishVideo(error: writer.error
                            ?? VideoExporterError.exportFailed("写入视频帧失败"))
                    } else {
                        // 输入此刻不能接收数据（瞬时背压），不设错误：等待下一次回调重试。
                        transientFailure = true
                    }
                    return
                }
                frameIndex += 1
                watchdog?.recordProgress()
                transientBackpressureCount = 0
                if frameIndex == totalFrames
                    || frameIndex.isMultiple(of: max(frameRate.rawValue / 10, 1)) {
                    progressHandler?(Double(frameIndex) / Double(totalFrames))
                }
            }
            guard !transientFailure else {
                transientBackpressureCount += 1
                guard transientBackpressureCount < 32 else {
                    finishVideo(error: VideoExporterError.exportFailed("编码器持续未就绪，导出中止"))
                    return
                }
                return
            }
        }

        if frameIndex >= totalFrames || isCancellationRequested {
            finishVideo(error: nil)
        }
    }

    private var isCancellationRequested: Bool {
        cancellation.isRequested
    }

    private func videoImages(for scene: FrameScene, at outputTime: Double) throws -> [UUID: CIImage] {
        guard !scene.videos.isEmpty else { return [:] }
        let pending = ExportPendingResult<[UUID: CIImage]>()
        let task = Task { [videoDecoder] in
            var images: [UUID: CIImage] = [:]
            for video in scene.videos {
                if Task.isCancelled { break }
                if let image = await videoDecoder.frame(clip: video.id, path: video.sourcePath, at: video.sourceTime) {
                    images[video.id] = image
                }
            }
            pending.complete(.success(images))
        }
        defer { task.cancel() }
        return try pending.wait(cancellation: cancellation, timeout: 30,
            timeoutError: renderTimeout(at: outputTime))
    }

    /// Preview and export own different pages. A preview seek cannot overwrite
    /// the time/properties between the export's seek and snapshot.
    private func animationImages(for scene: FrameScene, at outputTime: Double) throws -> [UUID: CIImage] {
        guard !scene.animations.isEmpty else { return [:] }
        let pending = ExportPendingResult<[UUID: CIImage]>()
        let fps = Double(max(frameRate.rawValue, 1))
        let canvas = canvasSize
        let task = Task { @MainActor [motionSession] in
            var images: [UUID: CIImage] = [:]
            for animation in scene.animations where HTMLMotion.isHTMLMotion(animation.sourcePath) {
                if Task.isCancelled { break }
                let width = max(canvas.width * CGFloat(animation.width), 2)
                let size = CGSize(width: width, height: max(width * canvas.height / max(canvas.width, 1), 2))
                let time = (animation.localTime * fps + 1e-6).rounded(.down) / fps
                guard let image = await motionSession.frame(path: ProjectFiles.resolve(animation.sourcePath),
                    properties: animation.properties, time: time, pixelSize: size, edits: animation.elementEdits) else {
                    pending.complete(.failure(motionRenderFailure(animation.sourcePath)))
                    return
                }
                images[animation.id] = image
            }
            pending.complete(.success(images))
        }
        defer { task.cancel() }
        return try pending.wait(cancellation: cancellation, timeout: 30,
            timeoutError: renderTimeout(at: outputTime))
    }

    private func insertedMotionImage(for scene: FrameScene, at outputTime: Double) throws -> CIImage? {
        guard let motion = scene.insertedMotion else { return nil }
        let pending = ExportPendingResult<CIImage?>()
        let fps = Double(max(frameRate.rawValue, 1))
        let task = Task { @MainActor [motionSession] in
            let time = (motion.localTime * fps + 1e-6).rounded(.down) / fps
            guard let image = await motionSession.frame(path: ProjectFiles.resolve(motion.sourcePath),
                properties: motion.properties, time: time, pixelSize: HTMLMotion.insertedPixelSize(scene),
                edits: motion.elementEdits) else {
                pending.complete(.failure(motionRenderFailure(motion.sourcePath)))
                return
            }
            pending.complete(.success(image))
        }
        defer { task.cancel() }
        return try pending.wait(cancellation: cancellation, timeout: 30,
            timeoutError: renderTimeout(at: outputTime))
    }

    private func renderTimeout(at time: Double) -> VideoExporterError {
        .exportFailed(String(format: appLocalized("画面渲染超时（成片 %.2f 秒），导出已停止。"), time))
    }

    private func motionRenderFailure(_ path: String) -> VideoExporterError {
        .exportFailed(String(format: appLocalized("无法渲染动效：%@"), URL(fileURLWithPath: path).lastPathComponent))
    }

    private func cameraPixelBuffer(at time: TimeInterval) throws -> CVPixelBuffer? {
        // A source whose camera is hidden across every one of its segments is
        // never loaded, yet the plan still carries that source's camera slices.
        // Read it as "no camera here" instead of failing the whole export.
        guard let cameraReader, let slice = cameraPlan?.slice(atOutputTime: time),
              recordingSources[slice.sourceID]?.camera != nil else {
            self.cameraReader?.close()
            currentCameraPixelBuffer = nil
            currentCameraSourceID = nil
            return nil
        }
        let previous = currentCameraSourceID == slice.sourceID ? currentCameraPixelBuffer : nil
        currentCameraSourceID = slice.sourceID
        let frame = try cameraReader.frame(in: slice, at: time, cancellation: cancellation,
            progress: { watchdog?.recordProgress() })
        currentCameraPixelBuffer = ExportCameraCutContinuity.frame(previous: previous, firstFrameInNextSlice: frame)
        return currentCameraPixelBuffer
    }

    private func processAudio() {
        guard !hasAudioFinished, let audioInput, let audioReader else { return }
        while !hasAudioFinished,
              !isCancellationRequested,
              audioInput.isReadyForMoreMediaData {
            let sample: CMSampleBuffer
            do {
                guard let next = try audioReader.next(cancellation: cancellation,
                    timeoutError: VideoExporterError.exportFailed("混音读取超时，导出已停止。")) else {
                    finishAudio(error: audioReader.error)
                    return
                }
                sample = next
            } catch {
                finishAudio(error: error)
                return
            }
            watchdog?.recordProgress()
            guard audioInput.append(sample) else {
                finishAudio(error: writer.error ?? VideoExporterError.exportFailed("写入音频失败"))
                return
            }
        }
        if isCancellationRequested {
            finishAudio(error: nil)
        }
    }

    private func finishVideo(error: (any Error)?) {
        completionLock.lock()
        guard !videoFinished else {
            completionLock.unlock()
            return
        }
        videoFinished = true
        let shouldLeave = videoGroupEntered
        completionLock.unlock()
        if let error { requestStop(error: error) }
        videoReader.close()
        cameraReader?.close()
        videoInput.markAsFinished()
        if shouldLeave { group.leave() }
    }

    private func finishAudio(error: (any Error)?) {
        completionLock.lock()
        guard !audioFinished else {
            completionLock.unlock()
            return
        }
        audioFinished = true
        let shouldLeave = audioGroupEntered
        completionLock.unlock()
        if let error { requestStop(error: error) }
        audioReader?.cancelReading()
        audioInput?.markAsFinished()
        if shouldLeave { group.leave() }
    }

    private var hasVideoFinished: Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        return videoFinished
    }

    private var hasAudioFinished: Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        return audioFinished
    }

    private func requestCancellation() {
        requestStop(error: VideoExporterError.cancelled)
    }

    /// Publish the cause before waking either worker. A failure on one input
    /// must also release the other input; otherwise the completion group can
    /// wait forever for a writer that will never become ready again.
    private func requestStop(error: any Error) {
        completionLock.lock()
        guard !cancellation.isRequested else {
            completionLock.unlock()
            return
        }
        setError(error)
        cancellation.request()
        let shouldFinish = workersStarted
        completionLock.unlock()
        Self.logger.error("export stopped: \(error.localizedDescription, privacy: .public)")
        guard shouldFinish else { return }
        // Workers stop waiting through the latch. Readers are then closed on
        // their own serial queues, after any in-flight sample copy has returned.
        videoQueue.async { [self] in finishVideo(error: nil) }
        if audioInput != nil {
            audioQueue.async { [self] in finishAudio(error: nil) }
        }
        group.notify(queue: finishQueue) { [self] in
            if writer.status == .writing { writer.cancelWriting() }
        }
    }

    private func setError(_ error: any Error) {
        stateLock.lock()
        if pipelineError == nil { pipelineError = error }
        stateLock.unlock()
    }

    private func currentError() -> (any Error)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pipelineError
    }
}
