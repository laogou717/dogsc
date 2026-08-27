import AVFoundation
import AudioToolbox
import Foundation
import RecorderCore
import os
import VideoToolbox

final class MicrophoneRecorder: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "microphone-recorder"
    )
    private let session = AVCaptureSession()
    private let levelOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "cn.laogou.dogsc.microphone")
    private let sessionQueueKey = DispatchSpecificKey<UInt8>()

    // sessionQueue-confined state
    private var activity: CaptureActivity = .idle
    private var startContinuation: (UUID, CheckedContinuation<Void, any Error>)?
    private var stopContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var recordingStartedAtStorage: Date?
    private var configuredDeviceUniqueID: String?
    /// Meter reads originate on the main actor while audio capture and AAC
    /// appends run on `sessionQueue`. Do not make the UI synchronously wait for
    /// that whole queue just to copy one scalar; a writer append or device
    /// transition could otherwise stall the complete recorder toolbar.
    private let normalizedInputLevelState = OSAllocatedUnfairLock(initialState: 0.0)
    private var unexpectedStopHandler: (@MainActor (any Error) -> Void)?
    private var recordingOutputURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var expectedRecordingFormatDescription: CMFormatDescription?
    private var firstRecordedSampleTime: CMTime?
    private var firstRawPresentationTime: CMTime?
    private var lastRawPresentationTime: CMTime?
    private var lastRawDuration: CMTime = .zero
    private var accumulatedRawPauseDuration: CMTime = .zero
    private var expectedResumeRawTime: CMTime?
    private var isAwaitingResumeSample = false
    private var writerHasSamples = false
    private var droppedSamples = 0
    private var receivedSampleBuffers = 0
    private var appendedSampleBuffers = 0
    private var writerBackpressureDrops = 0
    private var invalidTimestampDrops = 0
    private var nonMonotonicTimestampDrops = 0
    private var formatChangeDrops = 0
    private var otherSampleDrops = 0
    private var firstDiagnosticHostTime: TimeInterval?
    private var lastDiagnosticHostTime: TimeInterval?
    private var maximumDiagnosticSampleInterval: TimeInterval = 0
    private var skipsNextDiagnosticSampleInterval = false
    private var lastCompletedDiagnostics: AudioCaptureDiagnostics?
    private var recordingIsPaused = false
    private var recordedPauseStartedAt: TimeInterval?
    private var recordedAccumulatedPause: TimeInterval = 0

    override init() {
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
        levelOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    /// A mid-recording device disconnect (USB microphone pulled) ends the
    /// track without any explicit stop. Surface it so the app can warn the
    /// user instead of silently shipping a recording without microphone audio.
    var onUnexpectedStop: (@MainActor (any Error) -> Void)? {
        get { syncOnSessionQueue { unexpectedStopHandler } }
        set { syncOnSessionQueue { unexpectedStopHandler = newValue } }
    }

    var recordingStartedAt: Date? {
        syncOnSessionQueue { recordingStartedAtStorage }
    }

    func captureDiagnosticsSnapshot() async -> AudioCaptureDiagnostics? {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            return currentDiagnosticsLocked() ?? lastCompletedDiagnostics
        }
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(
                    returning: currentDiagnosticsLocked() ?? lastCompletedDiagnostics
                )
            }
        }
    }

    func recordedSourceTime(atHostTime targetHostTime: TimeInterval) -> TimeInterval? {
        syncOnSessionQueue {
            guard activity.ownsRecordingOutput,
                  let firstRecordedSampleTime,
                  firstRecordedSampleTime.isNumeric,
                  firstRecordedSampleTime.seconds.isFinite else { return nil }
            var paused = recordedAccumulatedPause
            if let recordedPauseStartedAt,
               targetHostTime > recordedPauseStartedAt {
                paused += targetHostTime - recordedPauseStartedAt
            }
            // PRE-SYNC-004: map the microphone from its actual first sample on
            // the same host clock used by camera and ScreenCaptureKit. The old
            // `recordedDuration - callback wall time` estimate included file
            // output buffering latency and produced a different permanent trim
            // for camera and microphone.
            return max(targetHostTime - firstRecordedSampleTime.seconds - paused, 0)
        }
    }

    func startMonitoring(deviceUniqueID: String? = nil) async throws {
        guard await requestPermission() else {
            throw MicrophoneRecorderError.permissionDenied
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
                            throw MicrophoneRecorderError.recordingFailed(
                                "录制期间不能更换麦克风"
                            )
                        }
                        try configureLocked(deviceUniqueID: deviceUniqueID)
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
                self?.cancelMonitoringLocked(requestID: requestID)
            }
        }
    }

    func stopMonitoring() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopLiveMonitoringLocked()
                continuation.resume()
            }
        }
    }

    func requestMonitoringStop() {
        sessionQueue.async { [self] in stopLiveMonitoringLocked() }
    }

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

    func normalizedInputLevel() -> Double {
        normalizedInputLevelState.withLock { $0 }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let inputLevel = Self.inputLevel(from: sampleBuffer)
            ?? Self.inputLevel(from: connection.audioChannels)
            ?? 0
        normalizedInputLevelState.withLock { $0 = inputLevel }
        guard activity.recordingRequestID != nil else { return }
        do {
            try appendRecordingSampleLocked(sampleBuffer)
        } catch {
            failRecordingLocked(error, reportsUnexpectedStop: activity.isRecording)
        }
    }

    func start(to outputURL: URL, deviceUniqueID: String? = nil) async throws {
        guard await requestPermission() else {
            throw MicrophoneRecorderError.permissionDenied
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
                            throw MicrophoneRecorderError.recordingFailed(
                                "上一次麦克风录制尚未结束"
                            )
                        }
                        try configureLocked(deviceUniqueID: deviceUniqueID)
                        guard !cancellation.isCancelled else {
                            throw CancellationError()
                        }
                        resetRecordingStateLocked(cancelWriter: true)
                        lastCompletedDiagnostics = nil
                        if FileManager.default.fileExists(atPath: outputURL.path) {
                            try FileManager.default.removeItem(at: outputURL)
                        }
                        recordingOutputURL = outputURL
                        activity = .starting(requestID)
                        startContinuation = (requestID, continuation)
                        if !session.isRunning { session.startRunning() }
                        Self.logger.notice(
                            "microphone start requested device=\(deviceUniqueID ?? "automatic", privacy: .public)"
                        )
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

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func stop() async throws {
        let waiterID = UUID()
        let cancellation = CaptureCancellationFlag()
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
    }

    func pause() {
        sessionQueue.async { [self] in
            guard case .recording = activity, !recordingIsPaused else { return }
            recordingIsPaused = true
            // A deliberate pause is not an audio delivery stall.
            skipsNextDiagnosticSampleInterval = true
            if let lastRawPresentationTime {
                expectedResumeRawTime = lastRawPresentationTime + lastRawDuration
            }
            recordedPauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        }
    }

    func resume() {
        sessionQueue.async { [self] in
            guard case .recording = activity, recordingIsPaused else { return }
            let resumedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if let recordedPauseStartedAt {
                recordedAccumulatedPause += max(resumedAt - recordedPauseStartedAt, 0)
                self.recordedPauseStartedAt = nil
            }
            recordingIsPaused = false
            isAwaitingResumeSample = expectedResumeRawTime != nil
        }
    }

    private func configureLocked(deviceUniqueID: String?) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let device = try CaptureDeviceCatalog.resolveLiveDevice(
            role: .microphone,
            selectedUniqueID: deviceUniqueID
        )

        let hasConnectedInput = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .contains { $0.uniqueID == device.uniqueID && $0.isConnected }
        let hasLevelOutput = session.outputs.contains { $0 === levelOutput }
        if configuredDeviceUniqueID == device.uniqueID,
           hasConnectedInput,
           hasLevelOutput {
            return
        }

        if session.isRunning { session.stopRunning() }
        let input = try AVCaptureDeviceInput(device: device)
        configuredDeviceUniqueID = nil
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for existingInput in session.inputs { session.removeInput(existingInput) }
        guard session.canAddInput(input) else {
            throw MicrophoneRecorderError.recordingFailed("无法配置所选麦克风")
        }
        session.addInput(input)
        if !hasLevelOutput {
            guard session.canAddOutput(levelOutput) else {
                throw MicrophoneRecorderError.recordingFailed("无法创建麦克风电平监听")
            }
            session.addOutput(levelOutput)
        }
        configuredDeviceUniqueID = device.uniqueID
        resetNormalizedInputLevel()
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
            resetNormalizedInputLevel()
            continuation.resume()
        case let .starting(requestID):
            stopContinuations[waiterID] = continuation
            activity = .stopping(requestID)
            if let pending = startContinuation, pending.0 == requestID {
                startContinuation = nil
                pending.1.resume(throwing: CancellationError())
            }
            finishWriterLocked(requestID: requestID)
        case let .recording(requestID):
            stopContinuations[waiterID] = continuation
            activity = .stopping(requestID)
            finishWriterLocked(requestID: requestID)
        case .stopping:
            stopContinuations[waiterID] = continuation
        }
    }

    private func cancelMonitoringLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case let .livePreview(activeRequestID) = activity,
              activeRequestID == requestID else { return }
        stopLiveMonitoringLocked()
    }

    private func stopLiveMonitoringLocked() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case .livePreview = activity else { return }
        if session.isRunning { session.stopRunning() }
        activity = .idle
        resetNormalizedInputLevel()
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
        configuredDeviceUniqueID = nil
        resetNormalizedInputLevel()
        resetRecordingStateLocked(cancelWriter: true)
    }

    private func cancelRecordingStartLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard activity.recordingRequestID == requestID else { return }
        if let pending = startContinuation, pending.0 == requestID {
            startContinuation = nil
            pending.1.resume(throwing: CancellationError())
        }
        activity = .stopping(requestID)
        finishWriterLocked(requestID: requestID)
    }

    private func cancelStopWaiterLocked(waiterID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        stopContinuations.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }

    /// The metering UI and the recording file deliberately consume this same
    /// `AVCaptureAudioDataOutput` sample. The former two-output design waited
    /// for a file-output delegate and a data-output sample independently; some
    /// USB devices opened one branch without ever completing the other, leaving
    /// preparation stuck or an unfinalized M4A writing after the editor opened.
    private func appendRecordingSampleLocked(_ sampleBuffer: CMSampleBuffer) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let requestID: UUID
        switch activity {
        case let .starting(id), let .recording(id):
            requestID = id
        case .idle, .livePreview, .stopping:
            return
        }
        guard !recordingIsPaused else { return }
        receivedSampleBuffers += 1
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            droppedSamples += 1
            otherSampleDrops += 1
            return
        }
        let rawTime = sampleBuffer.presentationTimeStamp
        guard rawTime.isNumeric else {
            droppedSamples += 1
            invalidTimestampDrops += 1
            return
        }
        if let lastRawPresentationTime, rawTime < lastRawPresentationTime {
            droppedSamples += 1
            nonMonotonicTimestampDrops += 1
            return
        }
        let sampleFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        if let expectedRecordingFormatDescription,
           !CFEqual(sampleFormatDescription, expectedRecordingFormatDescription) {
            droppedSamples += 1
            formatChangeDrops += 1
            throw MicrophoneRecorderError.recordingFailed("麦克风格式在录制中发生变化")
        }
        expectedRecordingFormatDescription = expectedRecordingFormatDescription
            ?? sampleFormatDescription
        let diagnosticHostTime = rawTime.seconds
        if diagnosticHostTime.isFinite {
            if let lastDiagnosticHostTime, !skipsNextDiagnosticSampleInterval {
                maximumDiagnosticSampleInterval = max(
                    maximumDiagnosticSampleInterval,
                    diagnosticHostTime - lastDiagnosticHostTime
                )
            }
            firstDiagnosticHostTime = firstDiagnosticHostTime ?? diagnosticHostTime
            lastDiagnosticHostTime = diagnosticHostTime
            skipsNextDiagnosticSampleInterval = false
        }

        if isAwaitingResumeSample, let expectedResumeRawTime {
            let interruption = rawTime - expectedResumeRawTime
            if interruption.isNumeric, interruption > .zero {
                accumulatedRawPauseDuration = accumulatedRawPauseDuration + interruption
            }
            self.expectedResumeRawTime = nil
            isAwaitingResumeSample = false
        }

        if writer == nil {
            try createWriterLocked(from: sampleBuffer)
        }
        guard let writer, let writerInput else {
            throw MicrophoneRecorderError.recordingFailed("麦克风编码器未就绪")
        }
        let firstRaw = firstRawPresentationTime ?? rawTime
        firstRawPresentationTime = firstRaw
        guard let adjusted = SampleBufferTimeRetimer.retimed(
            sampleBuffer,
            subtracting: firstRaw + accumulatedRawPauseDuration
        ) else {
            otherSampleDrops += 1
            throw MicrophoneRecorderError.recordingFailed("无法对齐麦克风样本时间戳")
        }
        guard writer.status == .writing else {
            throw writer.error ?? MicrophoneRecorderError.recordingFailed(
                "麦克风编码器未处于写入状态"
            )
        }
        guard writerInput.isReadyForMoreMediaData else {
            droppedSamples += 1
            writerBackpressureDrops += 1
            return
        }
        guard writerInput.append(adjusted) else {
            otherSampleDrops += 1
            throw writer.error ?? MicrophoneRecorderError.recordingFailed("麦克风样本写入失败")
        }

        writerHasSamples = true
        appendedSampleBuffers += 1
        lastRawPresentationTime = rawTime
        let duration = sampleBuffer.duration
        lastRawDuration = duration.isNumeric && duration > .zero ? duration : .zero

        if firstRecordedSampleTime == nil,
           let hostTime = captureSampleHostTime(sampleBuffer, session: session) {
            firstRecordedSampleTime = CMTime(
                seconds: hostTime,
                preferredTimescale: 1_000_000_000
            )
            recordingStartedAtStorage = Date()
            if let pending = startContinuation, pending.0 == requestID {
                startContinuation = nil
                activity = .recording(requestID)
                pending.1.resume()
                Self.logger.notice(
                    "microphone first sample committed hostTime=\(hostTime, privacy: .public)"
                )
            }
        }
    }

    private func createWriterLocked(from sampleBuffer: CMSampleBuffer) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let outputURL = recordingOutputURL,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )?.pointee else {
            throw MicrophoneRecorderError.recordingFailed("无法读取麦克风音频格式")
        }
        let sampleRate = basicDescription.mSampleRate.isFinite
            && basicDescription.mSampleRate > 0
            ? basicDescription.mSampleRate : 48_000
        let channels = max(Int(basicDescription.mChannelsPerFrame), 1)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels > 1 ? 192_000 : 128_000,
            ],
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(input) else {
            throw MicrophoneRecorderError.recordingFailed("无法创建麦克风 AAC 音轨")
        }
        assetWriter.add(input)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? MicrophoneRecorderError.recordingFailed(
                "无法启动麦克风 AAC 编码器"
            )
        }
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        writerInput = input
        Self.logger.notice(
            "microphone writer started sampleRate=\(sampleRate, privacy: .public) channels=\(channels, privacy: .public)"
        )
    }

    private func finishWriterLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case let .stopping(activeRequestID) = activity,
              activeRequestID == requestID else { return }
        guard let writer, let writerInput, writerHasSamples else {
            completeStopLocked(requestID: requestID, result: .success(()))
            return
        }
        writerInput.markAsFinished()
        scheduleStopTimeoutLocked(requestID: requestID)
        writer.finishWriting { [weak self] in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                guard let completedWriter = self.writer else {
                    self.completeStopLocked(
                        requestID: requestID,
                        result: .failure(MicrophoneRecorderError.recordingFailed(
                            "麦克风编码器在封装期间已释放"
                        ))
                    )
                    return
                }
                if completedWriter.status == .completed {
                    Self.logger.notice(
                        "microphone writer completed droppedSamples=\(self.droppedSamples, privacy: .public)"
                    )
                    self.completeStopLocked(requestID: requestID, result: .success(()))
                } else {
                    self.completeStopLocked(
                        requestID: requestID,
                        result: .failure(completedWriter.error ?? MicrophoneRecorderError.recordingFailed(
                            "麦克风文件没有完成封装"
                        ))
                    )
                }
            }
        }
    }

    private func completeStopLocked(
        requestID: UUID,
        result: Result<Void, any Error>
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard case let .stopping(activeRequestID) = activity,
              activeRequestID == requestID else { return }
        if session.isRunning { session.stopRunning() }
        let pendingStops = Array(stopContinuations.values)
        stopContinuations.removeAll()
        if let completed = currentDiagnosticsLocked() {
            lastCompletedDiagnostics = completed
        }
        activity = .idle
        resetNormalizedInputLevel()
        resetRecordingStateLocked(cancelWriter: false)
        switch result {
        case .success:
            pendingStops.forEach { $0.resume() }
        case let .failure(error):
            pendingStops.forEach { $0.resume(throwing: error) }
        }
    }

    private func failRecordingLocked(
        _ error: any Error,
        reportsUnexpectedStop: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let failure = error as? MicrophoneRecorderError
            ?? MicrophoneRecorderError.recordingFailed(error.localizedDescription)
        if let pending = startContinuation {
            startContinuation = nil
            pending.1.resume(throwing: failure)
        }
        let pendingStops = Array(stopContinuations.values)
        stopContinuations.removeAll()
        pendingStops.forEach { $0.resume(throwing: failure) }
        if let completed = currentDiagnosticsLocked() {
            lastCompletedDiagnostics = completed
        }
        writer?.cancelWriting()
        if session.isRunning { session.stopRunning() }
        activity = .idle
        resetNormalizedInputLevel()
        resetRecordingStateLocked(cancelWriter: false)
        guard reportsUnexpectedStop, let handler = unexpectedStopHandler else { return }
        Task { @MainActor in handler(failure) }
    }

    private func resetRecordingStateLocked(cancelWriter: Bool) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if cancelWriter,
           let writer,
           writer.status == .unknown || writer.status == .writing {
            writer.cancelWriting()
        }
        writer = nil
        writerInput = nil
        expectedRecordingFormatDescription = nil
        recordingOutputURL = nil
        recordingStartedAtStorage = nil
        firstRecordedSampleTime = nil
        firstRawPresentationTime = nil
        lastRawPresentationTime = nil
        lastRawDuration = .zero
        accumulatedRawPauseDuration = .zero
        expectedResumeRawTime = nil
        isAwaitingResumeSample = false
        writerHasSamples = false
        droppedSamples = 0
        receivedSampleBuffers = 0
        appendedSampleBuffers = 0
        writerBackpressureDrops = 0
        invalidTimestampDrops = 0
        nonMonotonicTimestampDrops = 0
        formatChangeDrops = 0
        otherSampleDrops = 0
        firstDiagnosticHostTime = nil
        lastDiagnosticHostTime = nil
        maximumDiagnosticSampleInterval = 0
        skipsNextDiagnosticSampleInterval = false
        recordingIsPaused = false
        recordedPauseStartedAt = nil
        recordedAccumulatedPause = 0
    }

    private func resetNormalizedInputLevel() {
        normalizedInputLevelState.withLock { $0 = 0 }
    }

    private func currentDiagnosticsLocked() -> AudioCaptureDiagnostics? {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard receivedSampleBuffers > 0 || appendedSampleBuffers > 0 else { return nil }
        let elapsed: TimeInterval
        if let firstDiagnosticHostTime, let lastDiagnosticHostTime {
            elapsed = max(
                lastDiagnosticHostTime
                    - firstDiagnosticHostTime
                    - recordedAccumulatedPause,
                0
            )
        } else {
            elapsed = 0
        }
        return AudioCaptureDiagnostics(
            receivedSampleBuffers: receivedSampleBuffers,
            appendedSampleBuffers: appendedSampleBuffers,
            writerBackpressureDrops: writerBackpressureDrops,
            invalidTimestampDrops: invalidTimestampDrops,
            nonMonotonicTimestampDrops: nonMonotonicTimestampDrops,
            formatChangeDrops: formatChangeDrops,
            otherDrops: otherSampleDrops,
            elapsed: elapsed,
            maximumSampleInterval: maximumDiagnosticSampleInterval
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
                throwing: MicrophoneRecorderError.recordingFailed(
                    "5 秒内没有收到并写入首个有效音频样本"
                )
            )
            activity = .idle
            if session.isRunning { session.stopRunning() }
            resetRecordingStateLocked(cancelWriter: true)
        }
    }

    private func scheduleStopTimeoutLocked(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        sessionQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  case let .stopping(activeRequestID) = activity,
                  activeRequestID == requestID else { return }
            writer?.cancelWriting()
            completeStopLocked(
                requestID: requestID,
                result: .failure(MicrophoneRecorderError.recordingFailed(
                    "10 秒内没有完成音频文件封装"
                ))
            )
        }
    }

    private static func inputLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let format = formatPointer.pointee
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel > 0 else { return nil }

        var contiguousLength = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr,
        let dataPointer,
        contiguousLength > 0 else { return nil }

        let flags = format.mFormatFlags
        let bits = Int(format.mBitsPerChannel)
        let meanSquare: Double
        if flags & kAudioFormatFlagIsFloat != 0, bits == 32 {
            let count = contiguousLength / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else if flags & kAudioFormatFlagIsFloat != 0, bits == 64 {
            let count = contiguousLength / MemoryLayout<Double>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Double.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = samples[index]
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, bits == 16 {
            let count = contiguousLength / MemoryLayout<Int16>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(samples[index]) / Double(Int16.max)
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, bits == 32 {
            let count = contiguousLength / MemoryLayout<Int32>.size
            guard count > 0 else { return nil }
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Int32.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(samples[index]) / Double(Int32.max)
                sum += sample * sample
            }
            meanSquare = sum / Double(count)
        } else {
            return nil
        }

        let rootMeanSquare = sqrt(max(meanSquare, 0))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
        return normalizedLevel(fromDecibels: decibels)
    }

    private static func inputLevel(from channels: [AVCaptureAudioChannel]) -> Double? {
        let finiteLevels = channels
            .map { Double($0.averagePowerLevel) }
            .filter(\.isFinite)
        guard let strongestLevel = finiteLevels.max() else { return nil }
        return normalizedLevel(fromDecibels: strongestLevel)
    }

    private static func normalizedLevel(fromDecibels decibels: Double) -> Double {
        let floorLevel = -52.0
        guard decibels > floorLevel else { return 0 }
        let normalized = (decibels - floorLevel) / -floorLevel
        return min(max(pow(normalized, 0.62), 0), 1)
    }

    private func syncOnSessionQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil { return operation() }
        return sessionQueue.sync(execute: operation)
    }
}
