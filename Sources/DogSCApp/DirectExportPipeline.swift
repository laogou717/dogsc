import AVFoundation
import CoreImage
import Foundation
import RecorderCore
import VideoToolbox

enum ExportVideoCodecPolicy {
    /// H.264 hardware encoders on macOS are not a reliable 5K target. Keep the
    /// broadly compatible codec through 4K and use hardware-accelerated HEVC
    /// when source-native output exceeds that envelope.
    static func codec(width: Int, height: Int) -> AVVideoCodecType {
        max(width, height) > 4_096 ? .hevc : .h264
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
    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let sourcePreferredTransform: CGAffineTransform
    private let audioReader: AVAssetReader?
    private let audioOutput: AVAssetReaderOutput?
    private let cameraReader: AVAssetReader?
    private let cameraOutput: AVAssetReaderTrackOutput?
    private let cameraPreferredTransform: CGAffineTransform
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
    private let wallpaperImage: CIImage?
    private let cursorSource: CursorRenderSource?
    private let pointerTrack: ProjectPointerTrack
    private let zoomTrack: ZoomAnimationTrack
    private let screenMotionTrack: ScreenMotionTrack
    private let cameraMotionTrack: CameraMotionTrack
    private let cameraContentCrop: NormalizedCrop?
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
    private let stateLock = NSLock()
    private let completionLock = NSLock()
    private var pipelineError: (any Error)?
    private var videoFinished = false
    private var audioFinished = false
    private var videoGroupEntered = false
    private var audioGroupEntered = false
    private let cancellation = ExportCancellationLatch()
    private var frameIndex = 0
    private var currentPixelBuffer: CVPixelBuffer?
    private var nextVideoSample: CMSampleBuffer?
    private var didReadFirstVideoSample = false
    private var currentPrimarySegmentID: UUID?
    private var currentCameraPixelBuffer: CVPixelBuffer?
    private var nextCameraSample: CMSampleBuffer?
    private var didReadFirstCameraSample = false
    private var currentCameraSegmentID: UUID?
    /// Consecutive transient backpressure failures (append / pixel pool).
    /// Reset on every successful append; a sustained run terminates the job
    /// instead of busy-looping inside readiness callbacks.
    private var transientBackpressureCount = 0

    init(
        media: TimelineCompositionBundle,
        wallpaperImage: CIImage?,
        outputURL: URL,
        canvasSize: CGSize,
        project: RecorderProject,
        cursorSource: CursorRenderSource?,
        frameRate: OutputFrameRate,
        cameraContentCrop: NormalizedCrop? = nil,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws {
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
        let outputFrameSchedule = try OutputFrameSchedule(
            duration: media.plan.outputDuration,
            frameRate: frameRate
        )
        self.outputFrameSchedule = outputFrameSchedule
        // This CMTime only limits asset reading. Frame count and output PTS
        // remain exclusively owned by OutputFrameSchedule above.
        let readerDuration = CMTime(
            seconds: outputFrameSchedule.duration,
            preferredTimescale: 1_000_000_000
        )
        self.primaryPlan = media.plan.primary
        self.cameraPlan = media.plan.camera
        self.sourcePreferredTransform = media.primaryVideoTrack.preferredTransform
        self.cameraPreferredTransform = media.cameraVideoTrack?.preferredTransform ?? .identity
        self.wallpaperImage = wallpaperImage
        self.cursorSource = cursorSource
        self.pointerTrack = media.plan.pointer
        self.zoomTrack = ZoomAnimationTrack(project.zoomAnimations)
        self.screenMotionTrack = ScreenMotionTrack(project.timeline.screenMotionClips)
        self.cameraMotionTrack = CameraMotionTrack(project.timeline.cameraMotionClips)
        self.cameraContentCrop = cameraContentCrop
        self.progressHandler = progressHandler
        reader = try AVAssetReader(asset: media.primaryComposition)
        reader.timeRange = CMTimeRange(start: .zero, duration: readerDuration)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        videoOutput = AVAssetReaderTrackOutput(
            track: media.primaryVideoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw VideoExporterError.cannotReadMediaTrack(
                role: .screenRecording,
                media: .video
            )
        }
        reader.add(videoOutput)

        if let cameraComposition = media.cameraComposition,
           let cameraTrack = media.cameraVideoTrack {
            let reader = try AVAssetReader(asset: cameraComposition)
            let output = AVAssetReaderTrackOutput(
                track: cameraTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw VideoExporterError.cannotReadMediaTrack(
                    role: .cameraRecording,
                    media: .video
                )
            }
            reader.add(output)
            cameraReader = reader
            cameraOutput = output
        } else {
            cameraReader = nil
            cameraOutput = nil
        }

        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        let bitrate = ExportEncodingPolicy.videoBitrate(
            width: width,
            height: height,
            frameRate: frameRate.rawValue
        )
        let codec = ExportVideoCodecPolicy.codec(width: width, height: height)
        let profileLevel: String = codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel as String
            : AVVideoProfileLevelH264HighAutoLevel
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
            AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue * 2,
            AVVideoProfileLevelKey: profileLevel,
            AVVideoAllowFrameReorderingKey: false,
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

        let outputAudioTracks = [
            media.systemAudioTrack,
            media.microphoneAudioTrack,
        ].compactMap { $0 }
        if !outputAudioTracks.isEmpty {
            let reader = try AVAssetReader(asset: media.primaryComposition)
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: outputAudioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.audioMix = TimelineCompositionBuilder.audioMix(
                systemTrack: media.systemAudioTrack,
                systemVolume: project.audio.isSystemMuted
                    ? 0
                    : Float(min(max(project.audio.systemVolume, 0), 1)),
                microphoneTrack: media.microphoneAudioTrack,
                microphoneVolume: project.audio.isMicrophoneMuted
                    ? 0
                    : Float(min(max(project.audio.microphoneVolume, 0), 1))
            )
            guard reader.canAdd(output) else {
                throw VideoExporterError.exportFailed("无法创建麦克风混音读取器")
            }
            reader.add(output)
            audioReader = reader
            audioOutput = output

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
            audioOutput = nil
            audioInput = nil
        }
    }

    func run() async throws {
        try Task.checkCancellation()
        guard writer.startWriting() else {
            throw writer.error ?? VideoExporterError.exportFailed("编码器无法启动")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? VideoExporterError.exportFailed("读取器无法启动")
        }
        if let cameraReader, !cameraReader.startReading() {
            reader.cancelReading()
            writer.cancelWriting()
            throw cameraReader.error ?? VideoExporterError.exportFailed("摄像头素材无法读取")
        }
        if let audioReader, !audioReader.startReading() {
            reader.cancelReading()
            cameraReader?.cancelReading()
            writer.cancelWriting()
            throw audioReader.error ?? VideoExporterError.exportFailed("混音素材无法读取")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                completionLock.lock()
                if cancellation.isRequested {
                    completionLock.unlock()
                    continuation.resume(throwing: VideoExporterError.cancelled)
                    return
                }
                group.enter()
                videoGroupEntered = true
                if audioInput != nil, audioOutput != nil {
                    group.enter()
                    audioGroupEntered = true
                }
                completionLock.unlock()

                videoInput.requestMediaDataWhenReady(
                    on: videoQueue
                ) { [self] in
                    processVideo()
                }

                if let audioInput, audioOutput != nil {
                    audioInput.requestMediaDataWhenReady(
                        on: audioQueue
                    ) { [self] in
                        processAudio()
                    }
                }

                group.notify(
                    queue: DispatchQueue(label: "cn.laogou.dogsc.export.finish")
                ) { [self] in
                    if let pipelineError = currentError() {
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: pipelineError)
                        return
                    }
                    if reader.status == .failed {
                        writer.cancelWriting()
                        continuation.resume(
                            throwing: reader.error ?? VideoExporterError.exportFailed("读取失败")
                        )
                        return
                    }
                    if let audioReader, audioReader.status == .failed {
                        writer.cancelWriting()
                        continuation.resume(
                            throwing: audioReader.error
                                ?? VideoExporterError.exportFailed("混音读取失败")
                        )
                        return
                    }
                    if let cameraReader, cameraReader.status == .failed {
                        writer.cancelWriting()
                        continuation.resume(
                            throwing: cameraReader.error
                                ?? VideoExporterError.exportFailed("摄像头素材读取失败")
                        )
                        return
                    }
                    writer.finishWriting { [self] in
                        if writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(
                                throwing: writer.error
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
        let durationSeconds = outputFrameSchedule.duration
        let totalFrames = outputFrameSchedule.frameCount
        guard totalFrames > 0 else {
            finishVideo(error: nil)
            return
        }
        if !didReadFirstVideoSample {
            nextVideoSample = videoOutput.copyNextSampleBuffer()
            didReadFirstVideoSample = true
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
                if reader.status == .failed {
                    finishVideo(error: reader.error
                        ?? VideoExporterError.exportFailed("主素材读取失败"))
                    return
                }
                if let cameraReader, cameraReader.status == .failed {
                    finishVideo(error: cameraReader.error
                        ?? VideoExporterError.exportFailed("摄像头素材读取失败"))
                    return
                }
                guard let outputFrame = outputFrameSchedule.frame(at: frameIndex) else {
                    finishVideo(error: VideoExporterError.exportFailed("输出帧时间表越界"))
                    return
                }
                let targetTime = CMTime(
                    value: outputFrame.presentationTimeValue,
                    timescale: outputFrame.presentationTimescale
                )
                guard let slice = primaryPlan.slice(atOutputTime: targetTime.seconds) else {
                    finishVideo(error: VideoExporterError.exportFailed("成片时间没有对应的主录屏片段"))
                    return
                }
                if currentPrimarySegmentID != slice.segmentID {
                    currentPrimarySegmentID = slice.segmentID
                    currentPixelBuffer = nil
                    discardVideoSamples(before: slice.outputStart)
                }
                while let sample = nextVideoSample,
                      sample.presentationTimeStamp <= targetTime,
                      sample.presentationTimeStamp.seconds < slice.outputEnd {
                    currentPixelBuffer = sample.imageBuffer
                    nextVideoSample = videoOutput.copyNextSampleBuffer()
                }

                if currentPixelBuffer == nil,
                   let sample = nextVideoSample,
                   sample.presentationTimeStamp.seconds >= slice.outputStart,
                   sample.presentationTimeStamp.seconds < slice.outputEnd {
                    currentPixelBuffer = sample.imageBuffer
                }

                guard let sourcePixelBuffer = currentPixelBuffer else {
                    finishVideo(error: VideoExporterError.exportFailed("没有读到可渲染的视频帧"))
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
                    preferredTransform: sourcePreferredTransform
                )
                let activeCameraSlice = cameraPlan?.slice(atOutputTime: targetTime.seconds)
                let cameraImage = cameraPixelBuffer(at: targetTime).map { pixelBuffer in
                    let oriented = VideoExporter.orientVideoFrameForDisplay(
                        CIImage(cvPixelBuffer: pixelBuffer),
                        preferredTransform: cameraPreferredTransform
                    )
                    guard let cameraContentCrop else { return oriented }
                    // 与编辑预览一致：带黑边的摄像头素材按内容区裁剪，
                    // 几何（extent）与画面同时收缩。
                    return CameraLetterboxAnalysis.cropped(oriented, to: cameraContentCrop)
                }
                let primaryRange = MediaTimeRange(
                    start: slice.outputStart,
                    duration: slice.duration
                )
                let cameraRange = activeCameraSlice.flatMap {
                    MediaTimeRange(start: $0.outputStart, duration: $0.duration)
                }
                let normalizedSource = sourceImage.transformed(
                    by: CGAffineTransform(
                        translationX: -sourceImage.extent.minX,
                        y: -sourceImage.extent.minY
                    )
                )
                let renderPlan = FrameSceneEvaluator.renderPlan(
                    project: project,
                    presentationTime: targetTime.seconds,
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
                    cursorMetrics: cursorSource?.metrics,
                    zoomTrack: zoomTrack,
                    screenMotionTrack: screenMotionTrack,
                    cameraMotionTrack: cameraMotionTrack,
                    activePrimaryRange: primaryRange,
                    activeCameraRange: cameraRange
                )
                let resources = SharedFrameRenderResources(
                    screen: sourceImage,
                    camera: cameraImage,
                    wallpaper: wallpaperImage,
                    cursor: cursorSource?.image
                )
                let canvasRect = CGRect(origin: .zero, size: canvasSize)
                guard let outputImage = WeightedFrameCompositor.composite(
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

                guard adaptor.append(destinationBuffer, withPresentationTime: targetTime) else {
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

        if frameIndex >= totalFrames {
            finishVideo(error: nil)
        }
    }

    private var isCancellationRequested: Bool {
        cancellation.isRequested
    }

    private func cameraPixelBuffer(at time: CMTime) -> CVPixelBuffer? {
        guard let cameraOutput else { return nil }
        guard let slice = cameraPlan?.slice(atOutputTime: time.seconds) else {
            currentCameraPixelBuffer = nil
            currentCameraSegmentID = nil
            return nil
        }

        if !didReadFirstCameraSample {
            nextCameraSample = cameraOutput.copyNextSampleBuffer()
            didReadFirstCameraSample = true
        }
        if currentCameraSegmentID != slice.segmentID {
            let previousFrame = currentCameraPixelBuffer
            currentCameraSegmentID = slice.segmentID
            discardCameraSamples(before: slice.outputStart)
            let firstFrameInNextSlice: CVPixelBuffer? = nextCameraSample.flatMap { sample in
                let sampleTime = sample.presentationTimeStamp.seconds
                guard sampleTime >= slice.outputStart,
                      sampleTime < slice.outputEnd else { return nil }
                return sample.imageBuffer
            }
            currentCameraPixelBuffer = ExportCameraCutContinuity.frame(
                previous: previousFrame,
                firstFrameInNextSlice: firstFrameInNextSlice
            )
        }
        while let sample = nextCameraSample,
              sample.presentationTimeStamp <= time,
              sample.presentationTimeStamp.seconds < slice.outputEnd {
            currentCameraPixelBuffer = sample.imageBuffer
            nextCameraSample = cameraOutput.copyNextSampleBuffer()
        }
        if currentCameraPixelBuffer == nil,
           let sample = nextCameraSample,
           sample.presentationTimeStamp.seconds >= slice.outputStart,
           sample.presentationTimeStamp.seconds < slice.outputEnd {
            currentCameraPixelBuffer = sample.imageBuffer
        }
        return currentCameraPixelBuffer
    }

    private func discardVideoSamples(before outputTime: TimeInterval) {
        while let sample = nextVideoSample,
              sample.presentationTimeStamp.seconds < outputTime {
            nextVideoSample = videoOutput.copyNextSampleBuffer()
        }
    }

    private func discardCameraSamples(before outputTime: TimeInterval) {
        while let sample = nextCameraSample,
              sample.presentationTimeStamp.seconds < outputTime {
            nextCameraSample = cameraOutput?.copyNextSampleBuffer()
        }
    }

    private func processAudio() {
        guard !hasAudioFinished, let audioInput, let audioOutput else { return }
        while !hasAudioFinished,
              !isCancellationRequested,
              audioInput.isReadyForMoreMediaData {
            guard let sample = audioOutput.copyNextSampleBuffer() else {
                finishAudio(error: nil)
                return
            }
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
        if let error { setError(error) }
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
        if let error { setError(error) }
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
        completionLock.lock()
        cancellation.request()
        completionLock.unlock()
        setError(VideoExporterError.cancelled)
        reader.cancelReading()
        cameraReader?.cancelReading()
        audioReader?.cancelReading()
        videoQueue.async { [self] in finishVideo(error: nil) }
        if audioInput != nil {
            audioQueue.async { [self] in finishAudio(error: nil) }
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
