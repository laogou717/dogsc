import AVFoundation
import Foundation
import os
import RecorderCore
import ScreenCaptureKit

enum NativeScreenRecordingBackendPolicy {
    /// REC-002/REC-003: Apple defines `.nominal` as one logical point to one
    /// captured pixel. A cropped area and an independent window both request
    /// `contentRect * pointPixelScale` output pixels; using `.nominal` there can
    /// first rasterize at point resolution and then enlarge that softer image
    /// into the requested Retina-sized surface. Keep those focused sources at
    /// `.best`. Full-display recording deliberately remains `.nominal`: its
    /// 5K HEVC path is already the dominant WindowServer workload and uses
    /// Apple's direct writer, while the user has not reported full-display
    /// softness.
    static func captureResolution(for source: CaptureSource) -> SCCaptureResolutionType {
        switch source {
        case .window, .area:
            .best
        case .display, .device:
            .nominal
        }
    }

    /// REC-001/REC-004/NAT-001: full-display HEVC is the expensive path where
    /// moving every 5K IOSurface through our own callback, timestamp rewrite
    /// and AVAssetWriter queue was measurably starving ScreenCaptureKit. On
    /// macOS 15+, let `SCRecordingOutput` hand those frames directly to Apple's
    /// HEVC writer. A metadata-only monitor still observes the real SCK PTS for
    /// diagnostics and the shared audio/pointer epoch.
    ///
    /// Keep independent-window HEVC on our controllable writer: that path is
    /// already close to 60 fps and depends on `.best` Retina capture semantics.
    /// The proven native H.264 compatibility path remains limited to <=30 fps.
    static func canUseNativeWriter(
        source: CaptureSource,
        codec: CaptureCodec,
        requestedFramesPerSecond: Int,
        recordsSystemAudio: Bool,
        nativeAPIIsAvailable: Bool
    ) -> Bool {
        _ = recordsSystemAudio
        guard nativeAPIIsAvailable else { return false }
        if codec == .h264 {
            return requestedFramesPerSecond <= 30
        }
        return codec == .hevc
            && (source == .display || source == .area)
            && requestedFramesPerSecond <= 60
    }

    static func videoCodecType(for codec: CaptureCodec) -> AVVideoCodecType? {
        switch codec {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: nil
        }
    }

    @available(macOS 15.0, *)
    static func nativeCodecIsAvailable(_ codec: CaptureCodec) -> Bool {
        guard let codecType = videoCodecType(for: codec) else { return false }
        return SCRecordingOutputConfiguration().availableVideoCodecTypes.contains(codecType)
    }

    /// REC-001/REC-003: compatibility H.264 stays inside the hardware
    /// encoder's proven 4K operating envelope. HEVC and explicit ProRes keep
    /// the source's native Retina dimensions.
    /// A real 5120x2880/60 recording on the target Studio Display produced only
    /// 1,029 frames in 44.975 seconds (22.88 fps). Preserving unencoded 5K
    /// pixels is not useful when the recording has already lost most frames.
    /// HEVC is the default full-resolution hardware path; ProRes remains the
    /// higher-bandwidth near-lossless option.
    static func captureDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        codec: CaptureCodec,
        usesNativeWriter: Bool,
        legacyH264Maximum: CaptureDimensions
    ) -> CaptureDimensions {
        _ = usesNativeWriter
        if codec != .h264 {
            return CaptureDimensions.h264Compatible(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                maximumWidth: sourceWidth,
                maximumHeight: sourceHeight
            )
        }
        return CaptureDimensions.h264Compatible(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            maximumWidth: legacyH264Maximum.width,
            maximumHeight: legacyH264Maximum.height
        )
    }

    /// REC-003: ScreenCaptureKit must deliver the native Retina surface even
    /// when the final H.264 file stays inside the hardware encoder's 4K
    /// envelope. Asking SCK for the encoded size performs an early desktop
    /// downsample; a later 1.6x/2x edit then enlarges pixels that have already
    /// lost small-text and one-pixel-edge detail. The writer owns the single
    /// native-to-encoded resize instead.
    static func streamSurfaceDimensions(
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CaptureDimensions {
        CaptureDimensions.h264Compatible(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            maximumWidth: sourceWidth,
            maximumHeight: sourceHeight
        )
    }

}

protocol NativeScreenRecordingSegmentProtocol: AnyObject, Sendable {
    var outputURL: URL { get }
    var startedAtHostTime: TimeInterval? { get }
    func waitForStart(timeout: TimeInterval) async throws -> Date
    func waitForFinish(timeout: TimeInterval) async throws
}

@available(macOS 15.0, *)
final class NativeScreenRecordingSegment: NSObject,
    SCRecordingOutputDelegate, NativeScreenRecordingSegmentProtocol, @unchecked Sendable {
    let outputURL: URL
    private let videoCodecType: AVVideoCodecType
    lazy var recordingOutput: SCRecordingOutput = {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = outputURL
        configuration.outputFileType = .mp4
        configuration.videoCodecType = videoCodecType
        return SCRecordingOutput(configuration: configuration, delegate: self)
    }()

    private let lock = NSLock()
    private var startResult: Result<Date, any Error>?
    private var finishResult: Result<Void, any Error>?
    private var startWaiters: [UUID: CheckedContinuation<Date, any Error>] = [:]
    private var finishWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var startedAtHostTimeStorage: TimeInterval?
    private let onFailure: @Sendable (any Error) -> Void

    var startedAtHostTime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return startedAtHostTimeStorage
    }

    init(
        outputURL: URL,
        codec: CaptureCodec,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        self.outputURL = outputURL
        videoCodecType = NativeScreenRecordingBackendPolicy.videoCodecType(for: codec) ?? .h264
        self.onFailure = onFailure
        super.init()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        lock.lock()
        startedAtHostTimeStorage = hostTime.isFinite ? hostTime : nil
        lock.unlock()
        resolveStart(.success(Date()))
    }

    func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        resolveStart(.failure(error))
        resolveFinish(.failure(error))
        onFailure(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolveFinish(.success(()))
    }

    func waitForStart(timeout: TimeInterval) async throws -> Date {
        try await withThrowingTaskGroup(of: Date.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await self.awaitStart() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ScreenRecorderError.noFrames
            }
            let result = try await group.next() ?? Date()
            return result
        }
    }

    func waitForFinish(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await self.awaitFinish() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ScreenRecorderError.recordingFailed("苹果原生录制没有按时完成文件写入")
            }
            _ = try await group.next()
        }
    }

    private func awaitStart() async throws -> Date {
        // A task-group timeout also waits for its losing child. Removing that
        // child's waiter is what makes the timeout an actual bounded wait.
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let startResult {
                    lock.unlock()
                    continuation.resume(with: startResult)
                } else if Task<Never, Never>.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    startWaiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelStartWaiter(waiterID)
        }
    }

    private func awaitFinish() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let finishResult {
                    lock.unlock()
                    continuation.resume(with: finishResult)
                } else if Task<Never, Never>.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    finishWaiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelFinishWaiter(waiterID)
        }
    }

    private func cancelStartWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = startWaiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelFinishWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = finishWaiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func resolveStart(_ result: Result<Date, any Error>) {
        lock.lock()
        guard startResult == nil else {
            lock.unlock()
            return
        }
        startResult = result
        let waiters = Array(startWaiters.values)
        startWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }

    private func resolveFinish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard finishResult == nil else {
            lock.unlock()
            return
        }
        finishResult = result
        let waiters = Array(finishWaiters.values)
        finishWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }
}

struct NativeScreenFirstFrame: Sendable {
    let wallTime: Date
    let hostTime: TimeInterval
}

/// A metadata-only companion to `SCRecordingOutput`.
///
/// It never retains an IOSurface and never submits a frame to another encoder.
/// Its only job is to preserve the exact first ScreenCaptureKit PTS used by
/// pointer/system-audio alignment and to keep the existing live FPS diagnosis
/// useful after the heavy custom writer has been removed from display HEVC.
@available(macOS 15.0, *)
final class NativeScreenFrameMonitor: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let target: OutputFrameRate
    private var firstFrame: NativeScreenFirstFrame?
    private var firstHostTime: TimeInterval?
    private var lastObservedHostTime: TimeInterval?
    private var lastCompleteHostTime: TimeInterval?
    private var receivedFrames = 0
    private var idleFrames = 0
    private var maximumFrameInterval: TimeInterval = 0
    private var pausedDuration: TimeInterval = 0
    private var pauseStartedAtHostTime: TimeInterval?
    private var firstFrameWaiters: [
        UUID: CheckedContinuation<NativeScreenFirstFrame, any Error>
    ] = [:]

    init(target: OutputFrameRate) {
        self.target = target
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let status = ScreenCaptureFrameMetadata.status(of: sampleBuffer)
        else { return }

        let hostTime = sampleBuffer.presentationTimeStamp.seconds
        guard hostTime.isFinite else { return }

        var observedFirstFrame: NativeScreenFirstFrame?
        var waiters: [CheckedContinuation<NativeScreenFirstFrame, any Error>] = []
        lock.lock()
        guard pauseStartedAtHostTime == nil else {
            lock.unlock()
            return
        }

        switch status {
        case .complete:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                lock.unlock()
                return
            }
            if firstFrame == nil {
                let observed = NativeScreenFirstFrame(wallTime: Date(), hostTime: hostTime)
                firstFrame = observed
                firstHostTime = hostTime
                observedFirstFrame = observed
                waiters = Array(firstFrameWaiters.values)
                firstFrameWaiters.removeAll(keepingCapacity: false)
            }
            if let lastCompleteHostTime {
                let interval = hostTime - lastCompleteHostTime
                if interval.isFinite, interval > 0 {
                    maximumFrameInterval = max(maximumFrameInterval, interval)
                }
            }
            lastCompleteHostTime = hostTime
            lastObservedHostTime = hostTime
            receivedFrames += 1
        case .idle:
            guard firstFrame != nil else {
                lock.unlock()
                return
            }
            lastObservedHostTime = hostTime
            idleFrames += 1
        default:
            break
        }
        lock.unlock()

        if let observedFirstFrame {
            for waiter in waiters {
                waiter.resume(returning: observedFirstFrame)
            }
        }
    }

    func waitForFirstFrame(timeout: TimeInterval) async throws -> NativeScreenFirstFrame {
        try await withThrowingTaskGroup(of: NativeScreenFirstFrame.self) { group in
            group.addTask { try await self.awaitFirstFrame() }
            group.addTask {
                try await Task.sleep(for: .seconds(max(timeout, 0)))
                throw ScreenRecorderError.noFrames
            }
            defer { group.cancelAll() }
            guard let observed = try await group.next() else {
                throw ScreenRecorderError.noFrames
            }
            return observed
        }
    }

    func setPaused(_ paused: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard now.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if paused {
            if pauseStartedAtHostTime == nil { pauseStartedAtHostTime = now }
        } else if let pauseStartedAtHostTime {
            pausedDuration += max(now - pauseStartedAtHostTime, 0)
            self.pauseStartedAtHostTime = nil
            lastCompleteHostTime = nil
        }
    }

    func measurement() -> FrameRateMeasurement? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstHostTime,
              let lastObservedHostTime,
              receivedFrames > 0 else { return nil }
        let elapsed = max(lastObservedHostTime - firstHostTime - pausedDuration, 0)
        return FrameRateMeasurement(
            target: target,
            receivedFrames: receivedFrames,
            deliveredFrames: receivedFrames,
            idleFrames: idleFrames,
            elapsed: elapsed,
            maxFrameInterval: maximumFrameInterval
        )
    }

    private func awaitFirstFrame() async throws -> NativeScreenFirstFrame {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let firstFrame {
                    lock.unlock()
                    continuation.resume(returning: firstFrame)
                } else if Task<Never, Never>.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    firstFrameWaiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelFirstFrameWaiter(waiterID)
        }
    }

    private func cancelFirstFrameWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = firstFrameWaiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

}

struct NativeSystemAudioCaptureResult: Sendable {
    let outputURL: URL
    /// Raw ScreenCaptureKit PTS on Core Media's host clock. The native video
    /// start delegate records the same clock so the final mux can preserve the
    /// audio lead/lag instead of guessing from wall-clock callback dates.
    let firstRawPresentationTime: TimeInterval
    let diagnostics: AudioCaptureDiagnostics

    var droppedSampleCount: Int { diagnostics.totalDroppedSampleBuffers }
}

/// Audio-only companion for `SCRecordingOutput`.
///
/// REC-001/REC-002/REC-004: system audio must not force desktop frames back
/// through a second 4K encoder. Keeping this writer audio-only makes its load
/// negligible, while raw host-clock PTS and pause compensation preserve A/V
/// alignment when the AAC track is later muxed into the native H.264 file.
final class NativeSystemAudioCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    fileprivate static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "native-system-audio"
    )
    private static let finishWritingTimeout: TimeInterval = 15

    let outputURL: URL

    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let writerQueue = DispatchQueue(
        label: "cn.laogou.dogsc.native-system-audio-writer",
        qos: .userInitiated
    )
    private let ingress = NativeAudioPendingSampleGate(limit: 32)
    private var hasStartedSession = false
    private var isFinishing = false
    private var isPaused = false
    private var isAwaitingResumeSample = false
    private var expectedResumeRawTime: CMTime?
    private var accumulatedPauseDuration: CMTime = .zero
    private var firstRawPresentationTime: CMTime?
    private var lastRawPresentationTime: CMTime?
    private var lastRawDuration: CMTime = .zero
    private var lastAdjustedPresentationTime: CMTime?
    private var expectedFormatDescription: CMFormatDescription?
    private var receivedSampleBufferCount = 0
    private var appendedSampleBufferCount = 0
    private var writerBackpressureDrops = 0
    private var invalidTimestampDrops = 0
    private var nonMonotonicTimestampDrops = 0
    private var formatChangeDrops = 0
    private var otherDrops = 0
    private var firstDiagnosticRawTime: TimeInterval?
    private var lastDiagnosticRawTime: TimeInterval?
    private var maximumDiagnosticSampleInterval: TimeInterval = 0
    private var skipsNextDiagnosticSampleInterval = false
    private var terminalError: (any Error)?

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
        )
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw ScreenRecorderError.cannotCreateWriter
        }
        writer.add(audioInput)
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        append(sampleBuffer: sampleBuffer)
    }

    /// Accepts either a ScreenCaptureKit audio sample or a PCM sample copied
    /// from a Core Audio process tap. The writer and pause/mux clock stay shared
    /// so switching the capture source does not create a second timing model.
    func append(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            ingress.recordInvalid()
            return
        }
        guard ingress.claim() else { return }
        let retained = NativeAudioRetainedSampleBuffer(value: sampleBuffer)
        writerQueue.async { [self] in
            defer { ingress.complete() }
            guard !isFinishing, terminalError == nil else { return }
            append(retained.value)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard !isPaused else { return }
        receivedSampleBufferCount += 1
        let rawTime = sampleBuffer.presentationTimeStamp
        guard rawTime.isNumeric else {
            invalidTimestampDrops += 1
            return
        }

        let rawSeconds = rawTime.seconds
        if let lastDiagnosticRawTime, !skipsNextDiagnosticSampleInterval {
            maximumDiagnosticSampleInterval = max(
                maximumDiagnosticSampleInterval,
                rawSeconds - lastDiagnosticRawTime
            )
        }
        firstDiagnosticRawTime = firstDiagnosticRawTime ?? rawSeconds
        lastDiagnosticRawTime = rawSeconds
        skipsNextDiagnosticSampleInterval = false

        let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        if let expectedFormatDescription,
           !CFEqual(format, expectedFormatDescription) {
            terminalError = ScreenRecorderError.recordingFailed(
                "系统声音格式在录制中发生变化"
            )
            formatChangeDrops += 1
            return
        }
        if expectedFormatDescription == nil {
            expectedFormatDescription = format
        }

        if isAwaitingResumeSample, let expectedResumeRawTime {
            let interruption = rawTime - expectedResumeRawTime
            if interruption.isNumeric, interruption > .zero {
                accumulatedPauseDuration = accumulatedPauseDuration + interruption
            }
            self.expectedResumeRawTime = nil
            isAwaitingResumeSample = false
        }

        let firstRawTime = firstRawPresentationTime ?? rawTime
        firstRawPresentationTime = firstRawTime
        guard let adjusted = SampleBufferTimeRetimer.retimed(
            sampleBuffer,
            subtracting: firstRawTime + accumulatedPauseDuration
        ) else {
            otherDrops += 1
            return
        }
        let adjustedTime = adjusted.presentationTimeStamp
        if let lastAdjustedPresentationTime,
           adjustedTime < lastAdjustedPresentationTime {
            nonMonotonicTimestampDrops += 1
            return
        }

        if !hasStartedSession {
            guard writer.startWriting() else {
                otherDrops += 1
                terminalError = writer.error
                    ?? ScreenRecorderError.recordingFailed("系统声音编码器无法启动")
                return
            }
            writer.startSession(atSourceTime: .zero)
            hasStartedSession = true
        }
        guard writer.status != .failed else {
            otherDrops += 1
            terminalError = writer.error
                ?? ScreenRecorderError.recordingFailed("系统声音编码器已失效")
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            writerBackpressureDrops += 1
            return
        }
        guard audioInput.append(adjusted) else {
            otherDrops += 1
            if writer.status == .failed || writer.error != nil {
                terminalError = writer.error
                    ?? ScreenRecorderError.recordingFailed("系统声音写入失败")
            }
            return
        }

        lastRawPresentationTime = rawTime
        let duration = sampleBuffer.duration
        lastRawDuration = duration.isNumeric && duration > .zero ? duration : .zero
        lastAdjustedPresentationTime = adjustedTime
        appendedSampleBufferCount += 1
    }

    func setPaused(_ paused: Bool) async {
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                guard !isFinishing, isPaused != paused else {
                    continuation.resume()
                    return
                }
                if paused {
                    isPaused = true
                    skipsNextDiagnosticSampleInterval = true
                    if let lastRawPresentationTime {
                        expectedResumeRawTime = lastRawPresentationTime + lastRawDuration
                    }
                } else {
                    isPaused = false
                    isAwaitingResumeSample = expectedResumeRawTime != nil
                }
                continuation.resume()
            }
        }
    }

    func finish() async throws -> NativeSystemAudioCaptureResult? {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [self] in
                guard !isFinishing else {
                    continuation.resume(throwing: ScreenRecorderError.recordingFailed(
                        "系统声音文件正在结束写入"
                    ))
                    return
                }
                isFinishing = true
                if let terminalError {
                    writer.cancelWriting()
                    continuation.resume(throwing: terminalError)
                    return
                }
                guard hasStartedSession,
                      let firstRawPresentationTime else {
                    writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                audioInput.markAsFinished()
                let resumeOnce = NativeAudioFinishResumeOnce(continuation)
                writer.finishWriting { [self] in
                    writerQueue.async { [self] in
                        if writer.status == .completed {
                            resumeOnce.resume(.success(NativeSystemAudioCaptureResult(
                                outputURL: outputURL,
                                firstRawPresentationTime: firstRawPresentationTime.seconds,
                                diagnostics: diagnosticsLocked()
                            )))
                        } else {
                            resumeOnce.resume(.failure(
                                writer.error
                                    ?? ScreenRecorderError.recordingFailed(
                                        "系统声音文件没有完成写入"
                                    )
                            ))
                        }
                    }
                }
                writerQueue.asyncAfter(
                    deadline: .now() + Self.finishWritingTimeout
                ) { [self] in
                    writer.cancelWriting()
                    resumeOnce.resume(.failure(ScreenRecorderError.recordingFailed(
                        "系统声音文件没有在期限内完成写入"
                    )))
                }
            }
        }
    }

    func currentDiagnostics() async -> AudioCaptureDiagnostics? {
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                continuation.resume(
                    returning: hasDiagnosticEvidenceLocked() ? diagnosticsLocked() : nil
                )
            }
        }
    }

    private func hasDiagnosticEvidenceLocked() -> Bool {
        receivedSampleBufferCount > 0
            || appendedSampleBufferCount > 0
            || ingress.droppedCount > 0
            || ingress.invalidCount > 0
    }

    private func diagnosticsLocked() -> AudioCaptureDiagnostics {
        let ingressDrops = ingress.droppedCount
        let invalidIngress = ingress.invalidCount
        let elapsed: TimeInterval
        if let firstDiagnosticRawTime, let lastDiagnosticRawTime {
            elapsed = max(
                lastDiagnosticRawTime
                    - firstDiagnosticRawTime
                    - accumulatedPauseDuration.seconds,
                0
            )
        } else {
            elapsed = 0
        }
        return AudioCaptureDiagnostics(
            receivedSampleBuffers: receivedSampleBufferCount + ingressDrops + invalidIngress,
            appendedSampleBuffers: appendedSampleBufferCount,
            ingressDrops: ingressDrops,
            writerBackpressureDrops: writerBackpressureDrops,
            invalidTimestampDrops: invalidTimestampDrops,
            nonMonotonicTimestampDrops: nonMonotonicTimestampDrops,
            formatChangeDrops: formatChangeDrops,
            otherDrops: otherDrops + invalidIngress,
            elapsed: elapsed,
            maximumSampleInterval: maximumDiagnosticSampleInterval
        )
    }

}

private final class NativeAudioPendingSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var pending = 0
    private var dropped = 0
    private var invalid = 0

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending < limit else {
            dropped += 1
            return false
        }
        pending += 1
        return true
    }

    func complete() {
        lock.lock()
        pending = max(pending - 1, 0)
        lock.unlock()
    }

    func recordInvalid() {
        lock.lock()
        invalid += 1
        lock.unlock()
    }

    var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }


    var invalidCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invalid
    }
}

private struct NativeAudioRetainedSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

private final class NativeAudioFinishResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<NativeSystemAudioCaptureResult?, any Error>

    init(_ continuation: CheckedContinuation<NativeSystemAudioCaptureResult?, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<NativeSystemAudioCaptureResult?, any Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
enum NativeScreenRecordingFinalizer {
    static func sortAndRemoveDuplicatePresentationTimes(
        _ times: inout [TimeInterval]
    ) {
        times.removeAll { !$0.isFinite }
        times.sort()
        guard times.count > 1 else { return }
        var writeIndex = 1
        for readIndex in 1..<times.count where times[readIndex] != times[writeIndex - 1] {
            times[writeIndex] = times[readIndex]
            writeIndex += 1
        }
        if writeIndex < times.count {
            times.removeLast(times.count - writeIndex)
        }
    }

    static func measurement(
        at url: URL,
        target: OutputFrameRate
    ) async throws -> FrameRateMeasurement {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScreenRecorderError.noFrames
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw ScreenRecorderError.recordingFailed("无法读取苹果原生录制帧")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ScreenRecorderError.recordingFailed("无法分析苹果原生录制")
        }

        var orderedTimes: [TimeInterval] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = sample.presentationTimeStamp.seconds
            if pts.isFinite { orderedTimes.append(pts) }
        }
        // Compressed H.264 samples can arrive from AVAssetReader in decode
        // order. Sort presentation timestamps before deriving frame gaps or B
        // frames turn into false 100ms stalls and halve the measured cadence.
        // Sort and uniquify the no-longer-needed storage in place: a long
        // native recording must not allocate a Set plus another full array at
        // the exact moment the user is waiting for finalization.
        sortAndRemoveDuplicatePresentationTimes(&orderedTimes)
        guard orderedTimes.count > 1,
              let firstPTS = orderedTimes.first,
              let lastPTS = orderedTimes.last else {
            throw ScreenRecorderError.noFrames
        }
        var intervals = zip(orderedTimes, orderedTimes.dropFirst()).compactMap {
            let interval = $1 - $0
            return interval.isFinite && interval > 0 ? interval : nil
        }
        let elapsed = lastPTS - firstPTS
        guard elapsed.isFinite, elapsed > 0 else { throw ScreenRecorderError.noFrames }
        let diagnostics = FrameIntervalDiagnostics(consuming: &intervals)
        return FrameRateMeasurement(
            target: target,
            receivedFrames: orderedTimes.count,
            deliveredFrames: orderedTimes.count,
            elapsed: elapsed,
            maxFrameInterval: diagnostics.maximum,
            intervalDiagnostics: diagnostics
        )
    }

    static func concatenate(
        _ segmentURLs: [URL],
        to finalURL: URL
    ) async throws {
        guard !segmentURLs.isEmpty else { throw ScreenRecorderError.noFrames }
        if segmentURLs.count == 1 {
            let only = segmentURLs[0].standardizedFileURL
            if only != finalURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: only, to: finalURL)
            }
            return
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ScreenRecorderError.recordingFailed("无法建立原生录制视频拼接轨")
        }
        var compositionAudio: AVMutableCompositionTrack?
        var insertionTime = CMTime.zero
        for url in segmentURLs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration > .zero,
                  let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ScreenRecorderError.noFrames
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            try compositionVideo.insertTimeRange(range, of: video, at: insertionTime)
            if insertionTime == .zero {
                compositionVideo.preferredTransform = try await video.load(.preferredTransform)
            }
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                if compositionAudio == nil {
                    compositionAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try compositionAudio?.insertTimeRange(range, of: audio, at: insertionTime)
            }
            insertionTime = insertionTime + duration
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ScreenRecorderError.recordingFailed("无法建立原生录制无损拼接器")
        }
        let temporaryURL = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".native-merged-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await exporter.export(to: temporaryURL, as: .mp4)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        }
        for segmentURL in segmentURLs where segmentURL.standardizedFileURL != finalURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: segmentURL)
        }
    }

    /// Adds the independently captured AAC track without touching the native
    /// H.264 samples. Both timestamps come from Core Media's host clock, so a
    /// stream that starts just before/after the first native frame is trimmed or
    /// offset by the measured amount instead of being snapped to zero.
    static func muxSystemAudio(
        _ audio: NativeSystemAudioCaptureResult,
        videoStartedAtHostTime: TimeInterval,
        into videoURL: URL
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audio.outputURL)
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        guard videoDuration.isNumeric, videoDuration > .zero,
              audioDuration.isNumeric, audioDuration > .zero,
              let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ScreenRecorderError.recordingFailed("原生录制的音视频轨道不完整")
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ScreenRecorderError.recordingFailed("无法建立原生录制音视频封装轨")
        }

        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideo,
            at: .zero
        )
        compositionVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let rawOffset = audio.firstRawPresentationTime - videoStartedAtHostTime
        guard rawOffset.isFinite else {
            throw ScreenRecorderError.recordingFailed("系统声音与视频的主时钟无效")
        }
        let audioStartsAfterVideo = max(rawOffset, 0)
        let audioSourceStart = max(-rawOffset, 0)
        let destinationStart = CMTime(seconds: audioStartsAfterVideo, preferredTimescale: 48_000)
        let sourceStart = CMTime(seconds: audioSourceStart, preferredTimescale: 48_000)
        let maximumDuration = min(
            max(videoDuration.seconds - audioStartsAfterVideo, 0),
            max(audioDuration.seconds - audioSourceStart, 0)
        )
        guard maximumDuration > 0 else {
            throw ScreenRecorderError.recordingFailed("系统声音与视频时间范围没有重叠")
        }
        try compositionAudio.insertTimeRange(
            CMTimeRange(
                start: sourceStart,
                duration: CMTime(seconds: maximumDuration, preferredTimescale: 48_000)
            ),
            of: sourceAudio,
            at: destinationStart
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ScreenRecorderError.recordingFailed("无法建立原生录制无损封装器")
        }
        let temporaryURL = videoURL.deletingLastPathComponent().appendingPathComponent(
            ".native-av-mux-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await exporter.export(to: temporaryURL, as: .mp4)
        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: temporaryURL)
        let message = "muxed independent system audio offset="
            + "\(String(format: "%.4f", rawOffset))s "
            + "duration=\(String(format: "%.3f", maximumDuration))s "
            + "dropped=\(audio.droppedSampleCount)"
        NativeSystemAudioCaptureOutput.logger.notice("\(message, privacy: .public)")
    }
}
