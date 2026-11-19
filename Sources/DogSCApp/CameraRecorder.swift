import AVFoundation
import AudioToolbox
import Foundation
import RecorderCore
import os
import VideoToolbox

final class CameraRecorder: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "camera-recorder"
    )
    private let session = AVCaptureSession()
    private let synchronizedVideoOutput = AVCaptureVideoDataOutput()
    private let deviceAudioOutput = AVCaptureAudioDataOutput()
    private var deviceAudioWriter: NativeSystemAudioCaptureOutput?
    private var deviceVideoURL: URL?
    private var deviceLastAudioTime: TimeInterval?
    private var deviceLastVideoSize: (width: Int, height: Int)?
    private var captureCodec: CaptureCodec = .h264
    private let sessionQueue = DispatchQueue(label: "cn.laogou.dogsc.camera")
    private let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private let role: MovieCaptureRole
    private var sessionEventMonitor: CameraCaptureSessionEventMonitor?

    // sessionQueue-confined state
    private var activity: CaptureActivity = .idle
    private var startContinuation: (UUID, CheckedContinuation<Void, any Error>)?
    private var stopContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var recordingStartedAtStorage: Date?
    private var isConfigured = false
    private var configuredDeviceUniqueID: String?
    private var configuredCapturesDeviceAudio = false
    private var configuredCaptureResolution: CameraCaptureResolution?
    private var runtimeFormatHandler: (@MainActor (CameraRuntimeFormat) -> Void)?
    private var previewSampleHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private let runtimeFormatMonitor = CameraRuntimeFormatMonitor()
    private let sampleIntegrityGate = CameraSampleIntegrityGate()
    private var unexpectedStopHandler: (@MainActor (any Error) -> Void)?
    private var sampleWriter: AVAssetWriter?
    private var sampleWriterInput: AVAssetWriterInput?
    private var sampleWriterAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let sampleWriterFrameNormalizer = CameraSampleWriterFrameNormalizer()
    private var sampleWriterOutputURL: URL?
    private var sampleWriterFirstHostTime: TimeInterval?
    private var sampleWriterLastRawHostTime: TimeInterval?
    private var sampleWriterResumeUsesSharedClock = false
    private var sampleWriterLastOutputTime: TimeInterval?
    private var sampleWriterFrameDuration: TimeInterval = 1.0 / 30.0
    private var sampleWriterAccumulatedPause: TimeInterval = 0
    private var sampleWriterPauseStartedAt: TimeInterval?
    private var sampleWriterIsPaused = false
    private var sampleWriterIsFinishing = false
    private var configuredCameraWidth: Int?
    private var configuredCameraHeight: Int?
    private var reportedCaptureSessionFailure = false
    private let cameraDiagnostics = CameraCaptureDiagnosticsMonitor()

    init(role: MovieCaptureRole = .camera) {
        self.role = role
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
        sessionEventMonitor = CameraCaptureSessionEventMonitor(session: session) {
            [weak self] event in
            self?.sessionQueue.async { [weak self] in
                self?.handleCaptureSessionEventLocked(event)
            }
        }
        // A file output terminates on a device format change. Consume samples
        // ourselves so iOS renegotiation cannot end the user-visible take.
        synchronizedVideoOutput.alwaysDiscardsLateVideoFrames = true
        synchronizedVideoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        synchronizedVideoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        deviceAudioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        deviceAudioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    var onUnexpectedStop: (@MainActor (any Error) -> Void)? {
        get { syncOnSessionQueue { unexpectedStopHandler } }
        set { syncOnSessionQueue { unexpectedStopHandler = newValue } }
    }

    var onRuntimeFormatChange: (@MainActor (CameraRuntimeFormat) -> Void)? {
        get { syncOnSessionQueue { runtimeFormatHandler } }
        set {
            // Keep callback changes ordered with start/stop, without making the
            // switch wait behind a cold device start or teardown on this queue.
            sessionQueue.async { [self] in runtimeFormatHandler = newValue }
        }
    }

    var onPreviewSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? {
        get { syncOnSessionQueue { previewSampleHandler } }
        set { syncOnSessionQueue { previewSampleHandler = newValue } }
    }

    var recordingStartedAt: Date? {
        syncOnSessionQueue { recordingStartedAtStorage }
    }

    /// Returns file time on the host clock, anchored to the first video sample
    /// and excluding completed pauses for camera and wired-device capture.
    func recordedSourceTime(atHostTime targetHostTime: TimeInterval) -> TimeInterval? {
        syncOnSessionQueue {
            guard activity.ownsRecordingOutput else { return nil }
            if let firstHostTime = sampleWriterFirstHostTime {
                var paused = sampleWriterAccumulatedPause
                if !sampleWriterResumeUsesSharedClock,
                   let pauseStart = sampleWriterPauseStartedAt,
                   targetHostTime > pauseStart {
                    paused += targetHostTime - pauseStart
                }
                return max(targetHostTime - firstHostTime - paused, 0)
            }
            return nil
        }
    }

    func captureDiagnosticsSnapshot() async -> CameraCaptureDiagnostics? {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            return cameraDiagnostics.snapshot
        }
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(returning: cameraDiagnostics.snapshot)
            }
        }
    }

    func startPreview(
        deviceUniqueID: String? = nil,
        captureResolution: CameraCaptureResolution? = nil
    ) async throws {
        guard case .camera = role else { return }
        guard await requestPermission() else {
            throw CameraRecorderError.permissionDenied(role.displayName)
        }
        try Task.checkCancellation()

        let requestID = UUID()
        let cancellation = CaptureCancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                sessionQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        guard !activity.ownsRecordingOutput else {
                            throw CameraRecorderError.recordingFailed(
                                role.displayName,
                                "录制期间不能更换预览设备"
                            )
                        }
                        try configureLocked(
                            deviceUniqueID: deviceUniqueID,
                            capturesDeviceAudio: false,
                            captureResolution: captureResolution
                        )
                        guard !cancellation.isCancelled else {
                            throw CancellationError()
                        }
                        activity = .livePreview(requestID)
                        if !session.isRunning { session.startRunning() }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            sessionQueue.async { [weak self] in
                self?.cancelLivePreviewLocked(requestID: requestID)
            }
        }
    }

    func stopPreview() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopLivePreviewLocked()
                continuation.resume()
            }
        }
    }

    /// Phase transitions such as setup -> editor are synchronous at the UI
    /// boundary. Enqueue the actual AVCaptureSession stop immediately without
    /// forcing that transition to keep an unstructured Swift Task alive.
    func requestPreviewStop() {
        sessionQueue.async { [self] in stopLivePreviewLocked() }
    }

    /// Editor/termination boundaries release the configured device graph, not
    /// merely the running clock. Retaining AVCaptureDeviceInput after
    /// stopRunning() leaves CoreMediaIO device state and buffers resident.
    func requestIdleResourceRelease() {
        sessionQueue.async { [self] in releaseIdleResourcesLocked() }
    }

    func releaseIdleResourcesSynchronously() {
        syncOnSessionQueue { releaseIdleResourcesLocked() }
    }

    func releaseDisconnectedDevice() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard !activity.ownsRecordingOutput else {
                    continuation.resume()
                    return
                }
                releaseIdleResourcesLocked()
                continuation.resume()
            }
        }
    }

    func start(
        to outputURL: URL,
        deviceUniqueID: String? = nil,
        capturesDeviceAudio: Bool = false,
        captureResolution: CameraCaptureResolution? = nil,
        captureCodec: CaptureCodec = .h264
    ) async throws {
        guard await requestPermission() else {
            throw CameraRecorderError.permissionDenied(role.displayName)
        }
        try Task.checkCancellation()

        let requestID = UUID()
        let cancellation = CaptureCancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                sessionQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        guard !activity.ownsRecordingOutput else {
                            throw CameraRecorderError.recordingFailed(
                                role.displayName,
                                "上一次录制尚未结束"
                            )
                        }
                        try configureLocked(
                            deviceUniqueID: deviceUniqueID,
                            capturesDeviceAudio: capturesDeviceAudio,
                            captureResolution: captureResolution
                        )
                        guard !cancellation.isCancelled else {
                            throw CancellationError()
                        }
                        var audioWriter: NativeSystemAudioCaptureOutput?
                        if role == .iosDevice, capturesDeviceAudio {
                            let audioURL = outputURL.deletingLastPathComponent()
                                .appendingPathComponent(".device-audio-\(UUID().uuidString).m4a")
                            audioWriter = try NativeSystemAudioCaptureOutput(outputURL: audioURL)
                        }
                        recordingStartedAtStorage = nil
                        reportedCaptureSessionFailure = false
                        activity = .starting(requestID)
                        startContinuation = (requestID, continuation)
                        resetSampleWriterStateLocked()
                        self.captureCodec = role == .iosDevice ? captureCodec : .h264
                        cameraDiagnostics.beginRecording()
                        sampleWriterOutputURL = outputURL
                        deviceAudioWriter = audioWriter
                        deviceVideoURL = role == .iosDevice ? outputURL : nil
                        deviceLastAudioTime = nil
                        deviceLastVideoSize = nil
                        if !session.isRunning { session.startRunning() }
                        scheduleStartTimeoutLocked(requestID: requestID)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            sessionQueue.async { [weak self] in
                self?.cancelRecordingStartLocked(requestID: requestID)
            }
        }
    }

    func stop() async throws {
        let waiterID = UUID()
        let cancellation = CaptureCancellationFlag()
        var videoFailure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    sessionQueue.async { [self] in
                        guard !cancellation.isCancelled else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        requestStopLocked(waiterID: waiterID, continuation: continuation)
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                cancellation.cancel()
                sessionQueue.async { [weak self] in
                    self?.cancelStopWaiterLocked(waiterID: waiterID)
                }
            }
        } catch { videoFailure = error }
        // Close the independent audio writer even when the video writer fails.
        // A cancelled waiter leaves an active finalizer for the next stop call.
        do { try await finishDeviceAudio() }
        catch {
            Self.logger.error("device audio finalization failed: \(String(describing: error as NSError), privacy: .public)")
            if videoFailure == nil { videoFailure = error }
        }
        if let videoFailure { throw videoFailure }
    }

    func pause() {
        sessionQueue.async { [self] in
            guard case .recording = activity else { return }
            sampleWriterIsPaused = true
            sampleWriterResumeUsesSharedClock = false
            sampleWriterPauseStartedAt = sampleWriterLastRawHostTime
        }
    }

    func resume(at timing: RecordingResumeTiming? = nil) {
        sessionQueue.async { [self] in
            guard case .recording = activity else { return }
            if let timing {
                sampleWriterAccumulatedPause = timing.accumulatedPauseDuration
                sampleWriterPauseStartedAt = timing.hostTime
                sampleWriterResumeUsesSharedClock = true
            }
            sampleWriterIsPaused = false
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The delegate queue is `sessionQueue`; keeping the body nonisolated
        // satisfies the Objective-C protocol while every mutation remains on
        // the recorder's one serial queue.
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if output === deviceAudioOutput {
            appendDeviceAudioLocked(sampleBuffer)
            return
        }
        guard output === synchronizedVideoOutput else { return }
        guard let validated = sampleIntegrityGate.validatedImageBuffer(
            from: sampleBuffer
        ) else {
            cameraDiagnostics.recordInvalidSampleDrop()
            cameraDiagnostics.logIfDue(hostTime: CACurrentMediaTime())
            return
        }
        guard let hostTime = captureSampleHostTime(sampleBuffer, session: session) else {
            cameraDiagnostics.recordInvalidSampleDrop()
            cameraDiagnostics.logIfDue(hostTime: CACurrentMediaTime())
            return
        }
        observeRuntimeFormatLocked(
            sampleBuffer,
            layout: validated.layout,
            hostTime: hostTime
        )
        previewSampleHandler?(sampleBuffer)
        appendSynchronizedCameraSampleLocked(
            sampleBuffer,
            imageBuffer: validated.imageBuffer,
            layout: validated.layout,
            rawTime: hostTime
        )
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard output === synchronizedVideoOutput,
              activity.ownsRecordingOutput,
              !sampleWriterIsPaused else { return }
        let hostTime = captureSampleHostTime(sampleBuffer, session: session)
        cameraDiagnostics.recordSystemDrop(
            sampleBuffer: sampleBuffer,
            hostTime: hostTime
        )
        cameraDiagnostics.logIfDue(hostTime: hostTime ?? CACurrentMediaTime())
    }

    private func observeRuntimeFormatLocked(
        _ sampleBuffer: CMSampleBuffer,
        layout: CameraPixelBufferLayout,
        hostTime: TimeInterval
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard role == .camera,
              let format = runtimeFormatMonitor.observe(
                  sampleBuffer,
                  layout: layout,
                  hostTime: hostTime
              )
        else { return }
        if let runtimeFormatHandler {
            Task { @MainActor in runtimeFormatHandler(format) }
        }
    }

    private func appendSynchronizedCameraSampleLocked(
        _ sampleBuffer: CMSampleBuffer,
        imageBuffer: CVPixelBuffer,
        layout: CameraPixelBufferLayout,
        rawTime: TimeInterval
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !sampleWriterIsFinishing,
              activity.ownsRecordingOutput else { return }
        if sampleWriterIsPaused {
            if sampleWriterPauseStartedAt == nil {
                sampleWriterPauseStartedAt = rawTime
            }
            sampleWriterLastRawHostTime = rawTime
            return
        }
        if let pauseStart = sampleWriterPauseStartedAt {
            if sampleWriterResumeUsesSharedClock {
                guard rawTime >= pauseStart else { return }
                sampleWriterResumeUsesSharedClock = false
            } else {
                sampleWriterAccumulatedPause += max(rawTime - pauseStart, 0)
            }
            sampleWriterPauseStartedAt = nil
            cameraDiagnostics.beginNewIntervalRun()
        }
        cameraDiagnostics.recordReceived(hostTime: rawTime, layout: layout)

        if role == .iosDevice {
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            if deviceLastVideoSize?.width != width || deviceLastVideoSize?.height != height {
                Self.logger.notice("device video sample format=\(width)x\(height); recording continues on fixed writer canvas")
                deviceLastVideoSize = (width, height)
            }
        }

        do {
            if sampleWriter == nil {
                try startSampleWriterLocked(
                    imageBuffer: imageBuffer,
                    sampleBuffer: sampleBuffer
                )
            }
            guard let writer = sampleWriter,
                  let input = sampleWriterInput,
                  let adaptor = sampleWriterAdaptor,
                  writer.status == .writing else { return }

            if sampleWriterFirstHostTime == nil {
                sampleWriterFirstHostTime = rawTime
            }
            let firstHostTime = sampleWriterFirstHostTime ?? rawTime
            let outputTime = max(
                rawTime - firstHostTime - sampleWriterAccumulatedPause,
                0
            )
            let sampleDuration = sampleBuffer.duration.seconds
            if sampleDuration.isFinite,
               sampleDuration >= 1.0 / 120.0,
               sampleDuration <= 1.0 / 10.0 {
                sampleWriterFrameDuration = sampleDuration
            }
            if let previous = sampleWriterLastOutputTime,
               outputTime <= previous {
                // The host-clock PTS is authoritative. Never manufacture time by
                // spacing duplicate/backward samples at an assumed 25/30 FPS;
                // that turns a short camera hiccup into permanent slow motion.
                cameraDiagnostics.recordNonMonotonicTimestampDrop()
                cameraDiagnostics.logIfDue(hostTime: rawTime)
                return
            }

            // Apple requires real-time sample callbacks to finish within one
            // frame budget. Waiting here previously blocked AVCaptureSession for
            // up to one second, created a stale-frame backlog and desynchronized
            // the camera. If hardware encoding is briefly busy, keep elapsed
            // media time and drop only this frame.
            guard input.isReadyForMoreMediaData else {
                cameraDiagnostics.recordEncoderBackpressureDrop()
                cameraDiagnostics.logIfDue(hostTime: rawTime)
                return
            }
            if sampleWriterFrameNormalizer.needsNormalization(imageBuffer) {
                cameraDiagnostics.recordNormalizedFrame()
            }
            let writerImageBuffer = try sampleWriterFrameNormalizer.normalizedImageBuffer(
                imageBuffer,
                adaptor: adaptor,
                roleName: role.displayName
            )
            guard adaptor.append(
                    writerImageBuffer,
                    withPresentationTime: CMTime(
                        seconds: outputTime,
                        preferredTimescale: 90_000
                    )
                  ) else {
                throw writer.error ?? CameraRecorderError.recordingFailed(
                    role.displayName,
                    "摄像头编码器拒绝视频帧"
                )
            }
            sampleWriterLastRawHostTime = rawTime
            sampleWriterLastOutputTime = outputTime
            cameraDiagnostics.recordAppendedFrame()
            cameraDiagnostics.logIfDue(hostTime: rawTime)
            if recordingStartedAtStorage == nil,
               let requestID = activity.recordingRequestID {
                recordingStartedAtStorage = Date()
                if let pending = startContinuation, pending.0 == requestID {
                    startContinuation = nil
                    pending.1.resume()
                }
                if case .starting = activity {
                    activity = .recording(requestID)
                }
            }
        } catch {
            Self.logger.error("capture sample writer failed role=\(String(describing: self.role), privacy: .public) error=\(String(describing: error as NSError), privacy: .public)")
            finishSampleWriterLocked(error: error)
        }
    }

    private func appendDeviceAudioLocked(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard role == .iosDevice, activity.isRecording,
              !sampleWriterIsPaused, !sampleWriterIsFinishing,
              sampleWriterPauseStartedAt == nil,
              let audioWriter = deviceAudioWriter,
              let firstVideoTime = sampleWriterFirstHostTime,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let hostTime = captureSampleHostTime(sampleBuffer, session: session) else { return }
        // Both tracks use the video's pause-free clock. Late device sound may
        // begin at any point without changing the video writer's track format.
        let outputTime = hostTime - firstVideoTime - sampleWriterAccumulatedPause
        guard outputTime.isFinite, outputTime >= 0,
              deviceLastAudioTime.map({ outputTime > $0 }) ?? true,
              let sample = SampleBufferTimeRetimer.retimed(sampleBuffer,
                  to: CMTime(seconds: outputTime, preferredTimescale: 48_000)) else { return }
        deviceLastAudioTime = outputTime
        audioWriter.append(sampleBuffer: sample)
    }

    private func finishDeviceAudio() async throws {
        let assets = syncOnSessionQueue { () -> (NativeSystemAudioCaptureOutput, URL)? in
            guard !activity.ownsRecordingOutput else { return nil }
            defer { deviceAudioWriter = nil; deviceVideoURL = nil; deviceLastAudioTime = nil }
            guard let audio = deviceAudioWriter, let videoURL = deviceVideoURL else { return nil }
            return (audio, videoURL)
        }
        guard let (audio, videoURL) = assets else { return }
        if let result = try await audio.finish() {
            try await RecordingAudioMuxer.muxSystemAudio(
                result, videoStartedAtHostTime: 0, into: videoURL)
        }
        // Keep the separate audio file for recovery if final muxing fails.
        try? FileManager.default.removeItem(at: audio.outputURL)
    }

    private func startSampleWriterLocked(
        imageBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer
    ) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let outputURL = sampleWriterOutputURL else {
            throw CameraRecorderError.recordingFailed(
                role.displayName,
                "摄像头输出路径尚未准备"
            )
        }
        let sourceWidth = CVPixelBufferGetWidth(imageBuffer)
        let sourceHeight = CVPixelBufferGetHeight(imageBuffer)
        let outputDimensions = CameraSampleWriterFrameNormalizer.outputDimensions(
            configuredWidth: role == .camera ? configuredCameraWidth : nil,
            configuredHeight: role == .camera ? configuredCameraHeight : nil,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let width = outputDimensions.width
        let height = outputDimensions.height
        let deliveredDuration = sampleBuffer.duration.seconds
        let expectedFrameRate: Int
        if deliveredDuration.isFinite,
           deliveredDuration >= 1.0 / 240.0,
           deliveredDuration <= 1.0 {
            expectedFrameRate = min(max(Int((1 / deliveredDuration).rounded()), 1), 240)
        } else {
            expectedFrameRate = 30
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let codec: AVVideoCodecType = switch captureCodec {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
        let bitrate = role == .iosDevice
            ? Int(min(max(Double(width) * Double(height) * 60 * 0.25, 16_000_000), 100_000_000))
            : 20_000_000
        let compression: [String: Any] = captureCodec == .proRes422 ? [:] : [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
            AVVideoMaxKeyFrameIntervalKey: expectedFrameRate * 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoEncoderSpecificationKey: [
                    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String:
                        true,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    CVPixelBufferGetPixelFormatType(imageBuffer),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else {
            throw CameraRecorderError.cannotConfigure(role.displayName)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CameraRecorderError.recordingFailed(
                role.displayName,
                "无法启动摄像头硬件编码器"
            )
        }
        writer.startSession(atSourceTime: .zero)
        sampleWriter = writer
        sampleWriterInput = input
        sampleWriterAdaptor = adaptor
        try sampleWriterFrameNormalizer.prepareContract(
            width: width,
            height: height,
            pixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourcePixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer),
            roleName: role.displayName,
            fitsSourceInsideCanvas: role == .iosDevice
        )
        Self.logger.notice(
            "capture writer role=\(String(describing: self.role), privacy: .public) contract=\(width)x\(height) firstSample=\(sourceWidth)x\(sourceHeight) codec=\(codec.rawValue, privacy: .public) bitrate=\(bitrate)"
        )
        let duration = sampleBuffer.duration.seconds
        if duration.isFinite,
           duration >= 1.0 / 120.0,
           duration <= 1.0 / 10.0 {
            sampleWriterFrameDuration = duration
        }
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureLocked(
        deviceUniqueID: String?,
        capturesDeviceAudio: Bool,
        captureResolution: CameraCaptureResolution?
    ) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let device = try CaptureDeviceCatalog.resolveLiveDevice(
            role: role.inputDeviceRole,
            selectedUniqueID: deviceUniqueID
        )

        let hasCurrentOutput = session.outputs.contains { $0 === synchronizedVideoOutput }
        // Both webcams and wired devices can renegotiate their format between
        // preview and recording, so reapply it at every configuration boundary.
        if session.isRunning { session.stopRunning() }
        let input = try AVCaptureDeviceInput(device: device)
        isConfigured = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        for existingInput in session.inputs { session.removeInput(existingInput) }
        guard session.canAddInput(input) else {
            throw CameraRecorderError.cannotConfigure(role.displayName)
        }
        session.addInput(input)
        if !hasCurrentOutput {
            guard session.canAddOutput(synchronizedVideoOutput) else {
                throw CameraRecorderError.cannotConfigure(role.displayName)
            }
            session.addOutput(synchronizedVideoOutput)
        }
        if session.outputs.contains(where: { $0 === deviceAudioOutput }) {
            session.removeOutput(deviceAudioOutput)
        }
        if role == .iosDevice, capturesDeviceAudio {
            guard session.canAddOutput(deviceAudioOutput) else {
                throw CameraRecorderError.cannotConfigure(role.displayName)
            }
            session.addOutput(deviceAudioOutput)
        }
        // Build the complete graph before fixing the native format. Adding
        // an input under .high can otherwise choose a smaller device format.
        if role == .camera {
            if let captureResolution {
                try CameraCaptureDeviceConfigurator.applyCameraFormat(
                    captureResolution,
                    to: device,
                    role: role
                )
            } else {
                // Automatic still selects a deterministic native format. The
                // old condition accidentally made this unreachable for cameras.
                try CameraCaptureDeviceConfigurator.applyPreferredFormat(
                    to: device,
                    role: role
                )
            }
        } else {
            try CameraCaptureDeviceConfigurator.applyPreferredFormat(
                to: device,
                role: role
            )
        }
        if role == .camera {
            // Query locked-duration support only after the output graph exists;
            // support may depend on the complete session configuration. nil is
            // the native/automatic mode and explicitly removes an earlier lock.
            try CameraCaptureDeviceConfigurator.restoreAutomaticCadence(
                to: input,
                device: device
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )
        configuredCameraWidth = Int(dimensions.width)
        configuredCameraHeight = Int(dimensions.height)
        configuredDeviceUniqueID = device.uniqueID
        configuredCapturesDeviceAudio = capturesDeviceAudio
        configuredCaptureResolution = captureResolution
        runtimeFormatMonitor.reset(keepingCapacity: true)
        sampleIntegrityGate.reset()
        isConfigured = true
    }

    private func handleCaptureSessionEventLocked(
        _ event: CameraCaptureSessionEvent
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        switch event {
        case let .runtimeError(error):
            cameraDiagnostics.recordSessionRuntimeError()
            Self.logger.error(
                "camera session runtime error domain=\(error.domain, privacy: .public) code=\(error.code) reason=\(error.localizedDescription, privacy: .public)"
            )
            reportCaptureSessionFailureLocked(
                reason: String(format: appLocalized("摄像头会话运行失败：%@"), error.localizedDescription)
            )
        case .interrupted:
            cameraDiagnostics.recordSessionInterruption()
            Self.logger.error("camera session was interrupted")
            reportCaptureSessionFailureLocked(
                reason: "摄像头被其他应用或系统中断"
            )
        case .interruptionEnded:
            // The capture session may restart automatically. The first sample
            // after that boundary must establish a fresh format/layout instead
            // of inheriting metadata cached before another client took over.
            runtimeFormatMonitor.reset(keepingCapacity: true)
            sampleIntegrityGate.reset()
            Self.logger.notice("camera session interruption ended; sample contract reset")
        }
        cameraDiagnostics.logIfDue(hostTime: CACurrentMediaTime())
    }

    private func reportCaptureSessionFailureLocked(reason: String) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard activity.ownsRecordingOutput,
              !reportedCaptureSessionFailure,
              let unexpectedStopHandler else { return }
        reportedCaptureSessionFailure = true
        let failure = CameraRecorderError.recordingFailed(role.displayName, reason)
        Task { @MainActor in unexpectedStopHandler(failure) }
    }

    private func requestStopLocked(
        waiterID: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        switch activity {
        case .idle, .livePreview:
            if session.isRunning { session.stopRunning() }
            activity = .idle
            continuation.resume()
        case let .starting(requestID), let .recording(requestID):
            stopContinuations[waiterID] = continuation
            activity = .stopping(requestID)
            requestSampleWriterFinishLocked(requestID: requestID)
            scheduleStopTimeoutLocked(requestID: requestID)
        case .stopping:
            stopContinuations[waiterID] = continuation
        }
    }

    private func cancelLivePreviewLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case let .livePreview(activeRequestID) = activity,
              activeRequestID == requestID else { return }
        stopLivePreviewLocked()
    }

    private func stopLivePreviewLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case .livePreview = activity else { return }
        if session.isRunning { session.stopRunning() }
        activity = .idle
    }

    private func releaseIdleResourcesLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !activity.ownsRecordingOutput else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        activity = .idle
        isConfigured = false
        configuredDeviceUniqueID = nil
        configuredCapturesDeviceAudio = false
        configuredCaptureResolution = nil
        configuredCameraWidth = nil
        configuredCameraHeight = nil
        reportedCaptureSessionFailure = false
        runtimeFormatMonitor.reset(keepingCapacity: false)
        sampleIntegrityGate.reset()
    }

    private func cancelRecordingStartLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard activity.recordingRequestID == requestID else { return }
        if let pending = startContinuation, pending.0 == requestID {
            startContinuation = nil
            pending.1.resume(throwing: CancellationError())
        }
        activity = .stopping(requestID)
        requestSampleWriterFinishLocked(requestID: requestID)
        scheduleStopTimeoutLocked(requestID: requestID)
    }

    private func requestSampleWriterFinishLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !sampleWriterIsFinishing else { return }
        sampleWriterIsFinishing = true
        if session.isRunning { session.stopRunning() }
        guard let writer = sampleWriter,
              let input = sampleWriterInput else {
            finishSampleWriterLocked(
                error: CameraRecorderError.recordingFailed(
                    role.displayName,
                    "停止前没有收到摄像头视频帧"
                )
            )
            return
        }
        input.markAsFinished()
        if let last = sampleWriterLastOutputTime {
            writer.endSession(
                atSourceTime: CMTime(
                    seconds: last + sampleWriterFrameDuration,
                    preferredTimescale: 90_000
                )
            )
        }
        let writerID = ObjectIdentifier(writer)
        writer.finishWriting { [weak self, writerID, requestID] in
            self?.sessionQueue.async { [weak self, writerID, requestID] in
                guard let self,
                      case let .stopping(activeRequestID) = self.activity,
                      activeRequestID == requestID,
                      self.sampleWriterIsFinishing,
                      let finishedWriter = self.sampleWriter,
                      ObjectIdentifier(finishedWriter) == writerID else { return }
                // A timed-out writer can finish after a new preview/recording
                // starts. Only this exact stop request may release its graph.
                let error: (any Error)? = finishedWriter.status == .completed
                    ? nil
                    : finishedWriter.error ?? CameraRecorderError.recordingFailed(
                        self.role.displayName,
                        "摄像头文件没有完成封装"
                    )
                self.finishSampleWriterLocked(error: error)
            }
        }
    }

    private func finishSampleWriterLocked(error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let wasStopping: Bool
        if case .stopping = activity { wasStopping = true } else { wasStopping = false }
        let stoppedUnexpectedly = recordingStartedAtStorage != nil
            && !wasStopping
            && startContinuation == nil
        let pendingStart = startContinuation
        startContinuation = nil
        let pendingStops = Array(stopContinuations.values)
        stopContinuations.removeAll()
        if session.isRunning { session.stopRunning() }
        activity = .idle
        if let error {
            sampleWriter?.cancelWriting()
            if let pendingStart {
                pendingStart.1.resume(throwing: error)
            }
            pendingStops.forEach { $0.resume(throwing: error) }
        } else {
            if let pendingStart {
                pendingStart.1.resume(
                    throwing: CameraRecorderError.recordingFailed(
                        role.displayName,
                        "启动完成前摄像头已停止"
                    )
                )
            }
            pendingStops.forEach { $0.resume() }
        }
        resetSampleWriterStateLocked()
        guard stoppedUnexpectedly, let handler = unexpectedStopHandler else { return }
        let failure = error ?? CameraRecorderError.recordingFailed(
            role.displayName,
            "摄像头采集连接已结束"
        )
        Task { @MainActor in handler(failure) }
    }

    private func resetSampleWriterStateLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        cameraDiagnostics.finishRecording()
        sampleWriter = nil
        sampleWriterInput = nil
        sampleWriterAdaptor = nil
        sampleWriterFrameNormalizer.reset()
        sampleWriterOutputURL = nil
        sampleWriterFirstHostTime = nil
        sampleWriterLastRawHostTime = nil
        sampleWriterLastOutputTime = nil
        sampleWriterFrameDuration = 1.0 / 30.0
        sampleWriterAccumulatedPause = 0
        sampleWriterResumeUsesSharedClock = false
        sampleWriterPauseStartedAt = nil
        sampleWriterIsPaused = false
        sampleWriterIsFinishing = false
        reportedCaptureSessionFailure = false
    }

    private func cancelStopWaiterLocked(waiterID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        stopContinuations.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }

    private func scheduleStartTimeoutLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  case let .starting(activeRequestID) = activity,
                  activeRequestID == requestID,
                  let pending = startContinuation,
                  pending.0 == requestID else { return }
            startContinuation = nil
            pending.1.resume(
                throwing: CameraRecorderError.recordingFailed(
                    role.displayName,
                    "5 秒内没有收到启动回调"
                )
            )
            activity = .stopping(requestID)
            requestSampleWriterFinishLocked(requestID: requestID)
            scheduleStopTimeoutLocked(requestID: requestID)
        }
    }

    private func scheduleStopTimeoutLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        sessionQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  case let .stopping(activeRequestID) = activity,
                  activeRequestID == requestID else { return }
            let failure = CameraRecorderError.recordingFailed(
                role.displayName,
                "10 秒内没有完成文件写入"
            )
            if let pending = startContinuation, pending.0 == requestID {
                startContinuation = nil
                pending.1.resume(throwing: failure)
            }
            let pendingStops = Array(stopContinuations.values)
            stopContinuations.removeAll()
            pendingStops.forEach { $0.resume(throwing: failure) }
            sampleWriter?.cancelWriting()
            resetSampleWriterStateLocked()
            if session.isRunning { session.stopRunning() }
            activity = .idle
        }
    }

    private func syncOnSessionQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil { return operation() }
        return sessionQueue.sync(execute: operation)
    }
}

/// See CameraRecorder: the unchecked conformance only bridges Objective-C delegate
/// callbacks. Session, outputs, continuations, monitoring level and lifecycle state
/// all live on one serial queue.
