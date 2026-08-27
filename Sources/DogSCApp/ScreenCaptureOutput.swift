import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import RecorderCore
import ScreenCaptureKit
import VideoToolbox

/// Serializes re-entrant async framework calls. An actor alone is not enough
/// because actor methods may interleave at `await`; this gate deliberately
/// holds ownership until the complete ScreenCaptureKit update returns.
actor AsyncOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum ScreenRecorderError: LocalizedError {
    case alreadyActive(RecordingRunID)
    case runNotActive(RecordingRunID)
    case permissionDenied
    case noDisplay
    case displayUnavailable(UInt32)
    case noWindow
    case unsupportedSource
    case invalidArea
    case cannotCreateWriter
    case noFrames
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyActive:
            return "录制器已经绑定到另一次录制，不能重复启动。"
        case .runNotActive:
            return "这次录制已结束或已被替换。"
        case .permissionDenied:
            return "没有屏幕录制权限。请在系统设置中允许后重新启动。"
        case .noDisplay:
            return "没有找到可录制的显示器。"
        case .displayUnavailable:
            return "已选择的显示器已断开，请重新选择。"
        case .noWindow:
            return "没有找到所选窗口，请重新选择。"
        case .unsupportedSource:
            return "此录制源不能由屏幕录制器处理。"
        case .invalidArea:
            return "录制区域无效，请重新选择。"
        case .cannotCreateWriter:
            return "无法创建视频写入器。"
        case .noFrames:
            return "没有收到可写入的视频帧。"
        case let .recordingFailed(reason):
            return "屏幕录制写入失败：\(reason)"
        }
    }
}

struct CaptureOutputTerminalEvent: @unchecked Sendable {
    let run: ScreenRecorderRunToken
    let stage: CaptureOutputTerminalStage
    let error: any Error
}

/// Keeps ScreenCaptureKit's delivery callback non-blocking while bounding the
/// number of retained IOSurfaces. AVAssetWriterInput.append may briefly block;
/// doing that work directly on SCK's sample queue caused upstream frame loss
/// that never appeared in `writerDroppedFrames`.
final class PendingSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var pending = 0
    private var dropped = 0

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

    var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}

/// Core Media sample buffers are immutable/ref-counted for the lifetime of a
/// stream callback, but the SDK does not declare the CF wrapper Sendable.
/// Retaining it in this explicit boundary is required to move the sample from
/// ScreenCaptureKit's delivery queue to our serial writer queue.
struct RetainedSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

final class CaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "screen-recorder"
    )

    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let writerQueue = DispatchQueue(
        label: "cn.laogou.dogsc.capture-writer",
        // REC-001/REC-004: a real 54.7-second A/B showed that lowering this
        // serial append path to userInitiated reduced complete SCK delivery to
        // 28.126 fps. Keep the latency-sensitive append path interactive; a
        // later real separate-process A/B also failed to improve SCK delivery.
        qos: .userInteractive
    )
    private let videoIngress = PendingSampleGate(limit: 8)
    private let audioIngress = PendingSampleGate(limit: 16)
    private let targetFrameRate: OutputFrameRate
    private let run: ScreenRecorderRunToken
    private let onTerminalFailure: (CaptureOutputTerminalEvent) -> Void
    private var hasStartedSession = false
    private var isFinishing = false
    private var receivedFrameCount = 0
    private var deliveredFrameCount = 0
    private var writerDroppedFrameCount = 0
    private var idleFrameCount = 0
#if DEBUG
    private var lastDiagnosticLogTime: TimeInterval = 0
    private var lastDiagnosticReceivedFrameCount = 0
    private var lastDiagnosticDeliveredFrameCount = 0
    private var lastDiagnosticIdleFrameCount = 0
    private var lastDiagnosticWriterDropCount = 0
#endif
    private var droppedAudioSampleCount = 0
    private var receivedAudioSampleBufferCount = 0
    private var appendedAudioSampleBufferCount = 0
    private var audioWriterBackpressureDrops = 0
    private var audioInvalidTimestampDrops = 0
    private var audioNonMonotonicTimestampDrops = 0
    private var audioFormatChangeDrops = 0
    private var audioOtherDrops = 0
    private var firstAudioPresentationTime: TimeInterval?
    private var lastDiagnosticAudioPresentationTime: TimeInterval?
    private var maximumAudioSampleInterval: TimeInterval = 0
    private var skipsNextAudioDiagnosticInterval = false
    private var firstReceivedVideoTime: CMTime?
    private var lastReceivedVideoTime: CMTime?
    private var lastRawVideoTime: CMTime?
    private var lastAudioPresentationTime: CMTime?
    /// First accepted audio sample's format. System audio routing changes
    /// (an app starts/stops playback, sample rate changes) can switch SCK's
    /// audio sample format mid-recording; AVAssetWriter performs no automatic
    /// audio conversion, and appending an unexpected format permanently fails
    /// the whole writer — video included. We verify the format up front and
    /// drop (then permanently degrade) mismatched audio instead.
    private var expectedAudioFormatDescription: CMFormatDescription?
    /// Once audio has failed or changed format, keep writing video and drop
    /// all further system-audio samples: the audio track is auxiliary and
    /// must never take the whole recording down.
    private var audioDegraded = false
    private var maximumFrameInterval: TimeInterval = 0
    /// REC-001/REC-002: retain ordered gaps, not just an average or a maximum.
    /// One hour at 60 fps is about 1.7 MiB of Doubles, small enough to preserve
    /// exact percentile and consecutive-stall evidence for the whole run.
    private var frameIntervals: [TimeInterval] = []
    /// The once-per-second logger sorts only this bounded recent window. The
    /// complete run is sorted once, during finish, so diagnostics never become
    /// an increasing recording-time CPU cost.
#if DEBUG
    private var recentFrameIntervals: [TimeInterval] = []
#endif
    private var isPaused = false
    private var isAwaitingResumeVideo = false
    private var pauseStartRawVideoTime: CMTime?
    private var accumulatedPauseDuration: CMTime = .zero
    /// SCK delivers absolute host-time PTS (~9 days of uptime, e.g. 816764s).
    /// AVAssetWriter's fragment writer misbehaves under such huge timestamps
    /// (encoder-side -16341, triggered exactly when SCK's PTS jitters on app
    /// launch / clicks). All frames are normalized to relative time from the
    /// first frame (0-based), matching the convention of standard media files.
    private var sessionStartRawTime: CMTime?
    private var terminalError: (any Error)?
    private var terminalState = CaptureOutputTerminalState()
    private var firstFrameWallTime: Date?
    private var captureEndWallTime: Date?
    private var pauseStartWallTime: Date?
    private var accumulatedPausedWallDuration: TimeInterval = 0
    private var firstFrameContinuation: CheckedContinuation<Date, any Error>?
    private let captureColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// ScreenCaptureKit is asked to convert the desktop into SDR sRGB. The
    /// gamut primaries and YCbCr matrix remain BT.709, but desktop SDR uses the
    /// IEC sRGB transfer curve. Retagging those code values as BT.709 without a
    /// pixel conversion lifts the midtones and produces the observed grey look.
    private static let captureVideoColorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    init(
        run: ScreenRecorderRunToken,
        outputURL: URL,
        width: Int,
        height: Int,
        frameRate: OutputFrameRate,
        codec: CaptureCodec,
        recordsSystemAudio: Bool,
        onTerminalFailure: @escaping (CaptureOutputTerminalEvent) -> Void
    ) throws {
        self.run = run
        self.outputURL = outputURL
        self.targetFrameRate = frameRate
        self.onTerminalFailure = onTerminalFailure
        // ProRes 需要 .mov 容器；H.264 保持 .mp4。
        writer = try AVAssetWriter(
            outputURL: outputURL,
            fileType: codec.usesMOVContainer ? .mov : .mp4
        )
        // 分片间隔 10 秒（原 2 秒）：最小复现实验证明 2 秒短分片会触发
        // MovieHeaderMaker 的 composition-offset 错误（-16341），
        // 10 秒或不分片稳定。fragmented 能力保留（异常退出可恢复，
        // 代价是异常时最多丢失最后 10 秒）。
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let settings: [String: Any]
        let bitrate: Int
        switch codec {
        case .proRes422:
            // ProRes 422：视觉无损级、无码率参数（固定质量），
            // Apple silicon 有独立 ProRes 硬件编码器。
            settings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoColorPropertiesKey: Self.captureVideoColorProperties,
            ]
            bitrate = 0
        case .hevc, .h264:
            // Match capture quality to the same resolution/fps-aware policy
            // as export. HEVC is the native-resolution default because this
            // Mac exposes a hardware 5K HEVC encoder but no hardware 5K H.264
            // encoder. H.264 remains an explicit <=4K compatibility mode.
            bitrate = ExportEncodingPolicy.videoBitrate(
                width: width,
                height: height,
                frameRate: frameRate.rawValue
            )
            let avCodec: AVVideoCodecType = codec == .hevc ? .hevc : .h264
            let profileLevel: String = codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                : AVVideoProfileLevelH264HighAutoLevel
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                // REC-002: this configures encoder capacity only. Capture is
                // still VFR: every complete SCK sample keeps its real PTS and
                // no callback is filtered to this 60 fps quality target.
                AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
                // 关键帧间隔 1 秒：关键帧密集便于编辑器任意位置精确寻帧
                // （拖播放头/seek 时最多只需解码 1 秒前置帧）。
                AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue,
                AVVideoProfileLevelKey: profileLevel,
                kVTCompressionPropertyKey_RealTime as String: true,
                // 禁 B 帧：真实环境（音视频双轨 + 分片）实测证明这是稳定组合。
                // B 帧重排在真实环境（音视频交错 + fragmented 分片边界）下
                // 会偶发 MovieHeaderMaker composition-offset 错误（-16341）——
                // 02:26 复测失败证实。分片间隔 10 秒进一步降低触发概率。
                AVVideoAllowFrameReorderingKey: false,
            ]
            if codec == .hevc {
                // REC-003: AverageBitRate is only a soft target. The hardware
                // encoder undershot a requested 130 Mbps to 9.45 Mbps in a
                // real 5120x2666 recording, visibly softening small UI text
                // even though the native pixel dimensions survived.
                // Keep hardware real-time encoding, but make visual quality a
                // first-class rate-control constraint instead of hoping that a
                // high soft bitrate target will be consumed.
                compression[
                    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality
                        as String
                ] = false
                if #available(macOS 27.0, *) {
                    // Unlike the older generic Quality hint, CQF is explicitly
                    // defined to maintain consistent visual quality across
                    // simple and complex frames, with or without bitrate limits.
                    // The project deliberately builds with the macOS 26 SDK for
                    // deployment compatibility, so use the public CFString value
                    // here; the symbol itself was added to the macOS 27 SDK.
                    compression["ConstantQualityFactor"] = Float(0.90)
                } else {
                    // Deployment fallback for systems before CQF. This remains
                    // a quality constraint, not a lower-resolution substitute.
                    compression[kVTCompressionPropertyKey_Quality as String] = Float(0.90)
                }
            }
            let encoderSpecification: [String: Any]
            if codec == .hevc {
                // NAT-001/REC-001: never silently fall back to a 5K software
                // encoder. A missing hardware path must fail visibly instead
                // of recreating the observed ~23 fps 5K H.264 fallback.
                encoderSpecification = [
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
                        as String: true,
                ]
            } else {
                encoderSpecification = [
                    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder
                        as String: true,
                ]
            }
            settings = [
                AVVideoCodecKey: avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                // REC-003: SCK supplies the native Retina surface. Keep the
                // only resolution change here, at the encoder boundary, so a
                // 5K desktop is not first softened by SCK and then compressed.
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoColorPropertiesKey: Self.captureVideoColorProperties,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoEncoderSpecificationKey: encoderSpecification,
            ]
        }

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true

        if recordsSystemAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audioInput?.expectsMediaDataInRealTime = true
        } else {
            audioInput = nil
        }

        guard writer.canAdd(videoInput) else { throw ScreenRecorderError.cannotCreateWriter }
        writer.add(videoInput)
        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw ScreenRecorderError.cannotCreateWriter
            }
            writer.add(audioInput)
        }
        let message = "capture writer started size=\(width)x\(height) "
            + "qualityTarget=\(frameRate.rawValue)fps "
            + "codec=\(codec.rawValue) "
            + "bitrate=\(bitrate) systemAudio=\(recordsSystemAudio)"
        Self.logger.notice("\(message, privacy: .public)")
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            guard videoIngress.claim() else { return }
            let receivedAt = Date()
            let retained = RetainedSampleBuffer(value: sampleBuffer)
            writerQueue.async { [self] in
                defer { videoIngress.complete() }
                guard !isFinishing, terminalError == nil else { return }
                appendVideo(retained.value, receivedAt: receivedAt)
            }
        case .audio:
            guard audioIngress.claim() else { return }
            let retained = RetainedSampleBuffer(value: sampleBuffer)
            writerQueue.async { [self] in
                defer { audioIngress.complete() }
                guard !isFinishing, terminalError == nil else { return }
                appendAudio(retained.value)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private func appendVideo(
        _ sampleBuffer: CMSampleBuffer,
        receivedAt: Date
    ) {
        // ScreenCaptureKit can emit idle/blank transition samples before the
        // first composited frame. They are valid CMSampleBuffers but contain no
        // encodable image data; handing one to AVAssetWriter permanently fails
        // the writer with kFigAssetWriterError_NoSampleMediaData.
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        guard isCompleteScreenFrame(sampleBuffer) else {
            // 静止内容时 SCK 只交付 idle 状态帧：计数以反映真实交付率
            // （悬浮窗据此区分“画面静止”与“编码瓶颈”）。
            idleFrameCount += 1
            return
        }
        let deliveredWallTimeCandidate = firstFrameWallTime == nil ? receivedAt : nil
        let rawPresentationTime = sampleBuffer.presentationTimeStamp
        lastRawVideoTime = rawPresentationTime
        guard !isPaused else { return }

        if isAwaitingResumeVideo, let pauseStartRawVideoTime {
            let expectedNextFrame = CMTime(
                value: 1,
                timescale: CMTimeScale(targetFrameRate.rawValue)
            )
            let interruption = rawPresentationTime - pauseStartRawVideoTime - expectedNextFrame
            if interruption.isValid, interruption > .zero {
                accumulatedPauseDuration = accumulatedPauseDuration + interruption
            }
            self.pauseStartRawVideoTime = nil
            isAwaitingResumeVideo = false
        }

        guard !isAwaitingResumeVideo else { return }
        // 首帧归一化 + 暂停补偿合并为单一偏移：所有帧 PTS 从 0 开始，
        // 避免巨大 host-time PTS 触发 AVAssetWriter fragment 写入 bug。
        let sessionStart = sessionStartRawTime ?? sampleBuffer.presentationTimeStamp
        sessionStartRawTime = sessionStart
        let totalOffset = accumulatedPauseDuration + sessionStart
        guard let adjustedBuffer = SampleBufferTimeRetimer.retimed(
            sampleBuffer,
            subtracting: totalOffset
        ) else { return }
        let presentationTime = adjustedBuffer.presentationTimeStamp
        if let lastReceivedVideoTime, presentationTime < lastReceivedVideoTime {
            // SCK 在系统事件（显示器切换、时钟重同步、应用切换）后可能短暂
            // 回退 PTS。非单调帧交给 AVAssetWriter 会直接让 writer 进入
            // failed 状态，整段录制被终止——必须在此丢弃而不是交给 writer。
            let message = "discarding non-monotonic video PTS "
                + "\(presentationTime.seconds) < \(lastReceivedVideoTime.seconds)"
            Self.logger.notice("\(message, privacy: .public)")
            writerDroppedFrameCount += 1
            return
        }
        receivedFrameCount += 1
        if firstReceivedVideoTime == nil {
            firstReceivedVideoTime = presentationTime
        }
        if let lastReceivedVideoTime {
            let interval = CMTimeGetSeconds(presentationTime - lastReceivedVideoTime)
            if interval.isFinite, interval > 0 {
                maximumFrameInterval = max(maximumFrameInterval, interval)
                frameIntervals.append(interval)
#if DEBUG
                recentFrameIntervals.append(interval)
#endif
            }
        }
        lastReceivedVideoTime = presentationTime
        if !hasStartedSession {
            guard writer.startWriting() else {
                let error = writer.error
                    ?? ScreenRecorderError.recordingFailed("编码器无法开始写入")
                recordTerminalFailure(error, stage: .writerStart)
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
        }

        if writer.status == .failed {
            recordTerminalFailure(
                writer.error ?? ScreenRecorderError.recordingFailed("视频编码器已失效"),
                stage: .videoAppend
            )
            return
        }
        guard videoInput.isReadyForMoreMediaData else {
            writerDroppedFrameCount += 1
            return
        }
        if let imageBuffer = CMSampleBufferGetImageBuffer(adjustedBuffer) {
            applyCaptureColorAttachments(to: imageBuffer)
        }
        if videoInput.append(adjustedBuffer) {
            deliveredFrameCount += 1
            if firstFrameWallTime == nil, let wallTime = deliveredWallTimeCandidate {
                firstFrameWallTime = wallTime
                let continuation = firstFrameContinuation
                firstFrameContinuation = nil
                continuation?.resume(returning: wallTime)
            }
        } else if writer.status == .failed || writer.error != nil {
            writerDroppedFrameCount += 1
            // 记录失败帧的元数据：SCK 区域采集可能交付尺寸/格式异常的帧。
            let frameWidth = adjustedBuffer.imageBuffer.flatMap {
                CVPixelBufferGetWidth($0)
            } ?? -1
            let frameHeight = adjustedBuffer.imageBuffer.flatMap {
                CVPixelBufferGetHeight($0)
            } ?? -1
            let message = "video append failed with writer error; "
                + "frame=\(frameWidth)x\(frameHeight) "
                + "pts=\(String(format: "%.4f", presentationTime.seconds)) "
                + "writerStatus=\(writer.status.rawValue)"
            Self.logger.error("\(message, privacy: .public)")
            recordTerminalFailure(
                writer.error ?? ScreenRecorderError.recordingFailed("视频帧写入失败"),
                stage: .videoAppend
            )
        } else {
            // append 返回 false 且 writer 未失败 = 输入此刻瞬时背压（AVFoundation
            // 契约），不是致命错误：丢弃本帧、等下一个样本，绝不能因此终止录制。
            // 否则菜单模态循环等主线程阻塞导致的积压会误判为写入失败，
            // 整段录制被意外停止。
            writerDroppedFrameCount += 1
        }
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        ScreenCaptureFrameMetadata.status(of: sampleBuffer) == .complete
    }

    private func applyCaptureColorAttachments(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        if let colorSpace = captureColorSpace {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferCGColorSpaceKey,
                colorSpace,
                .shouldPropagate
            )
        }
    }

    private func failFirstFrameWaiter(with error: any Error) {
        guard let continuation = firstFrameContinuation else { return }
        firstFrameContinuation = nil
        continuation.resume(throwing: error)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isPaused,
              hasStartedSession,
              let audioInput else { return }
        receivedAudioSampleBufferCount += 1
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            audioOtherDrops += 1
            return
        }
        if audioDegraded {
            // 系统音频已经失败/格式变化：永久丢弃，视频继续。
            droppedAudioSampleCount += 1
            audioOtherDrops += 1
            return
        }
        let sampleFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
        if let expected = expectedAudioFormatDescription,
           !CFEqual(sampleFormat, expected) {
            let message = "system audio format changed mid-recording; "
                + "degrading audio to keep the video recording"
            Self.logger.notice("\(message, privacy: .public)")
            audioDegraded = true
            droppedAudioSampleCount += 1
            audioFormatChangeDrops += 1
            return
        }
        if expectedAudioFormatDescription == nil {
            expectedAudioFormatDescription = sampleFormat
        }
        if isAwaitingResumeVideo, let pauseStartRawVideoTime {
            // 视频侧仍停留在暂停前的最后一帧（静止桌面不会产生 complete 帧）。
            // 用恢复后首个音频样本的 PTS 测量暂停时长，让系统声音在视频帧恢复前
            // 就能继续写入，而不是被无限期丢弃。pauseStartRawVideoTime 被清 nil 后，
            // 视频侧首个 complete 帧到达时不会重复累加。
            let expectedNextFrame = CMTime(
                value: 1,
                timescale: CMTimeScale(targetFrameRate.rawValue)
            )
            let interruption = sampleBuffer.presentationTimeStamp
                - pauseStartRawVideoTime
                - expectedNextFrame
            if interruption.isValid, interruption > .zero {
                accumulatedPauseDuration = accumulatedPauseDuration + interruption
            }
            self.pauseStartRawVideoTime = nil
            isAwaitingResumeVideo = false
        }
        // 与视频共享同一归一化基准（首帧相对时间，避免巨大 host-time PTS）。
        let rawAudioTime = sampleBuffer.presentationTimeStamp.seconds
        if rawAudioTime.isFinite {
            if let lastDiagnosticAudioPresentationTime,
               !skipsNextAudioDiagnosticInterval {
                maximumAudioSampleInterval = max(
                    maximumAudioSampleInterval,
                    rawAudioTime - lastDiagnosticAudioPresentationTime
                )
            }
            firstAudioPresentationTime = firstAudioPresentationTime ?? rawAudioTime
            lastDiagnosticAudioPresentationTime = rawAudioTime
            skipsNextAudioDiagnosticInterval = false
        } else {
            droppedAudioSampleCount += 1
            audioInvalidTimestampDrops += 1
            return
        }
        guard let sessionStartRawTime,
              let adjustedBuffer = SampleBufferTimeRetimer.retimed(
                  sampleBuffer,
                  subtracting: accumulatedPauseDuration + sessionStartRawTime
              )
        else {
            droppedAudioSampleCount += 1
            audioOtherDrops += 1
            return
        }
        let audioTime = adjustedBuffer.presentationTimeStamp
        if let lastAudioPresentationTime, audioTime < lastAudioPresentationTime {
            // 与视频同源：PTS 回退帧直接丢弃，避免 writer failed。
            droppedAudioSampleCount += 1
            audioNonMonotonicTimestampDrops += 1
            return
        }
        if let lastReceivedVideoTime {
            // 音视频时钟交叉保护：SCK 系统音频时钟可能失步（PTS 大幅落后视频）。
            // AVAssetWriter 的媒体排序器会因音视频时间错乱直接 failed（-16341），
            // 必须在写入前拦截：音频时钟失步就降级系统音频，保住视频。
            let audioLag = CMTimeGetSeconds(lastReceivedVideoTime - audioTime)
            if audioLag.isFinite, audioLag > 2.0 {
                let message = "system audio clock lags video by "
                    + "\(String(format: "%.2f", audioLag))s; degrading audio "
                    + "to keep the video recording"
                Self.logger.notice("\(message, privacy: .public)")
                audioDegraded = true
                droppedAudioSampleCount += 1
                audioOtherDrops += 1
                return
            }
        }
        lastAudioPresentationTime = audioTime
        if writer.status == .failed {
            recordTerminalFailure(
                writer.error ?? ScreenRecorderError.recordingFailed("系统声音编码器已失效"),
                stage: .audioAppend
            )
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            droppedAudioSampleCount += 1
            audioWriterBackpressureDrops += 1
            return
        }
        guard audioInput.append(adjustedBuffer) else {
            if writer.status == .failed || writer.error != nil {
                // 记录失败时的音频样本元数据，供 Console.app 定位 -16341 根因。
                let message = "audio append failed with writer error; "
                    + "pts=\(String(format: "%.4f", audioTime.seconds)) "
                    + "videoPts=\(String(format: "%.4f", lastReceivedVideoTime?.seconds ?? -1)) "
                    + "samples=\(CMSampleBufferGetNumSamples(adjustedBuffer)) "
                    + "writerStatus=\(writer.status.rawValue)"
                Self.logger.error("\(message, privacy: .public)")
                recordTerminalFailure(
                    writer.error ?? ScreenRecorderError.recordingFailed("系统声音写入失败"),
                    stage: .audioAppend
                )
            } else {
                // append 失败但 writer 未死：永久降级系统音频（而不是只丢一帧
                // 重试——同一格式问题会反复失败并可能最终搞挂 writer）。
                let message = "system audio append failed; "
                    + "degrading audio to keep the video recording"
                Self.logger.notice("\(message, privacy: .public)")
                audioDegraded = true
                droppedAudioSampleCount += 1
                audioOtherDrops += 1
            }
            return
        }
        appendedAudioSampleBufferCount += 1
    }

    private func recordTerminalFailure(
        _ error: any Error,
        stage: CaptureOutputTerminalStage
    ) {
        guard terminalState.claim(stage) else { return }
        let failure = CaptureOutputTerminalFailure(stage: stage, underlyingError: error)
        terminalError = failure
        // 记录完整底层错误，供 Console.app 排查 writer 真实失败原因。
        let nsError = error as NSError
        let diagnostic = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? "—"
        let underlying = nsError.userInfo[NSUnderlyingErrorKey].map {
            String(describing: $0)
        } ?? "—"
        let message = "terminal failure stage=\(String(describing: stage)) "
            + "domain=\(nsError.domain) code=\(nsError.code) "
            + "description=\(nsError.localizedDescription) "
            + "diagnostic=\(diagnostic) underlying=\(underlying)"
        Self.logger.error("\(message, privacy: .public)")
        failFirstFrameWaiter(with: failure)
        onTerminalFailure(CaptureOutputTerminalEvent(
            run: run,
            stage: stage,
            error: failure
        ))
    }

    func setPaused(_ paused: Bool) async {
        let requestedAt = Date()
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                guard !isFinishing, isPaused != paused else {
                    continuation.resume()
                    return
                }
                if paused {
                    isPaused = true
                    // A deliberate pause is not a system-audio delivery stall.
                    skipsNextAudioDiagnosticInterval = true
                    pauseStartRawVideoTime = lastRawVideoTime
                    pauseStartWallTime = requestedAt
                } else {
                    isPaused = false
                    isAwaitingResumeVideo = pauseStartRawVideoTime != nil
                    if let pauseStartWallTime {
                        accumulatedPausedWallDuration += max(
                            requestedAt.timeIntervalSince(pauseStartWallTime),
                            0
                        )
                        self.pauseStartWallTime = nil
                    }
                }
                continuation.resume()
            }
        }
    }

    /// How long `finish()` waits for the encoder before cancelling and
    /// reporting failure, so a wedged VideoToolbox session cannot leave the
    /// app in `.finishing` forever.
    private static let finishWritingTimeout: TimeInterval = 15

    func finish() async throws -> FrameRateMeasurement? {
        let requestedEndWallTime = Date()
        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [self] in
                guard !isFinishing else {
                    continuation.resume(
                        throwing: ScreenRecorderError.recordingFailed("录制文件正在结束写入")
                    )
                    return
                }
                isFinishing = true
                captureEndWallTime = requestedEndWallTime
                if let terminalError {
                    writer.cancelWriting()
                    continuation.resume(throwing: terminalError)
                    return
                }
                guard hasStartedSession else {
                    writer.cancelWriting()
                    continuation.resume(throwing: ScreenRecorderError.noFrames)
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()

                // Both finish paths resume exactly once, from @Sendable
                // callbacks, so the one-shot claim lives behind a lock.
                let resumeOnce = FinishResumeOnce(continuation)

                writer.finishWriting { [self] in
                    writerQueue.async { [self] in
                        if writer.status == .completed {
                            resumeOnce.resume(.success(
                                measurement(includeIntervalDiagnostics: true)
                            ))
                        } else {
                            resumeOnce.resume(.failure(
                                writer.error
                                    ?? ScreenRecorderError.recordingFailed("编码器没有完成文件写入")
                            ))
                        }
                    }
                }
                writerQueue.asyncAfter(
                    deadline: .now() + Self.finishWritingTimeout
                ) { [self] in
                    writer.cancelWriting()
                    resumeOnce.resume(.failure(
                        ScreenRecorderError.recordingFailed("编码器没有在期限内完成文件写入")
                    ))
                }
            }
        }
    }

    func currentMeasurement() async -> FrameRateMeasurement? {
        let requestedAt = Date()
        return await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                continuation.resume(returning: measurement(at: requestedAt))
            }
        }
    }

    func droppedAudioSamples() async -> Int {
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                continuation.resume(
                    returning: droppedAudioSampleCount + audioIngress.droppedCount
                )
            }
        }
    }

    func currentAudioDiagnostics() async -> AudioCaptureDiagnostics? {
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                let ingressDrops = audioIngress.droppedCount
                guard receivedAudioSampleBufferCount > 0
                        || appendedAudioSampleBufferCount > 0
                        || ingressDrops > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let elapsed: TimeInterval
                if let firstAudioPresentationTime,
                   let lastDiagnosticAudioPresentationTime {
                    elapsed = max(
                        lastDiagnosticAudioPresentationTime
                            - firstAudioPresentationTime
                            - accumulatedPauseDuration.seconds,
                        0
                    )
                } else {
                    elapsed = 0
                }
                continuation.resume(returning: AudioCaptureDiagnostics(
                    receivedSampleBuffers: receivedAudioSampleBufferCount + ingressDrops,
                    appendedSampleBuffers: appendedAudioSampleBufferCount,
                    ingressDrops: ingressDrops,
                    writerBackpressureDrops: audioWriterBackpressureDrops,
                    invalidTimestampDrops: audioInvalidTimestampDrops,
                    nonMonotonicTimestampDrops: audioNonMonotonicTimestampDrops,
                    formatChangeDrops: audioFormatChangeDrops,
                    otherDrops: audioOtherDrops,
                    elapsed: elapsed,
                    maximumSampleInterval: maximumAudioSampleInterval
                ))
            }
        }
    }

    func currentTerminalError() async -> (any Error)? {
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                continuation.resume(returning: terminalError)
            }
        }
    }

    func failStartup(with error: any Error) {
        writerQueue.async { [self] in
            guard terminalError == nil, !isFinishing else { return }
            terminalError = error
            failFirstFrameWaiter(with: error)
        }
    }

    func waitForFirstFrame(timeout: TimeInterval = 5) async throws -> Date {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [self] in
                if let terminalError {
                    continuation.resume(throwing: terminalError)
                    return
                }
                if let firstFrameWallTime {
                    continuation.resume(returning: firstFrameWallTime)
                    return
                }
                guard firstFrameContinuation == nil else {
                    continuation.resume(
                        throwing: ScreenRecorderError.recordingFailed("正在等待首帧")
                    )
                    return
                }
                firstFrameContinuation = continuation
                writerQueue.asyncAfter(deadline: .now() + timeout) { [self] in
                    guard let continuation = firstFrameContinuation else { return }
                    firstFrameContinuation = nil
                    continuation.resume(throwing: ScreenRecorderError.noFrames)
                }
            }
        }
    }

    func firstFrameHostTime() async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                let seconds = sessionStartRawTime?.seconds
                continuation.resume(
                    returning: seconds?.isFinite == true ? seconds : nil
                )
            }
        }
    }

    private func measurement(
        at wallTime: Date? = nil,
        includeIntervalDiagnostics: Bool = false
    ) -> FrameRateMeasurement? {
        guard let firstFrameWallTime else { return nil }
        // 用墙钟时长而不是 PTS 跨度：SCK 交付的时间戳抖动会让 PTS 区间
        // 高估瞬时帧率（悬浮窗曾显示 120 而实际文件只有 37fps）。
        // 结束录制后，finishWriting 的编码器排空时间不能算作采集时长；暂停
        // 区间同样不参与有效帧率，否则长暂停会被误报成严重掉帧。
        let measurementEnd = captureEndWallTime ?? wallTime ?? Date()
        let activePauseDuration = pauseStartWallTime.map {
            max(measurementEnd.timeIntervalSince($0), 0)
        } ?? 0
        let elapsed = measurementEnd.timeIntervalSince(firstFrameWallTime)
            - accumulatedPausedWallDuration
            - activePauseDuration
        guard elapsed > 0, receivedFrameCount + idleFrameCount > 0 else { return nil }
        let intervalDiagnostics: FrameIntervalDiagnostics
        if includeIntervalDiagnostics {
            intervalDiagnostics = FrameIntervalDiagnostics(consuming: &frameIntervals)
        } else {
            intervalDiagnostics = .empty
        }
        let measurement = FrameRateMeasurement(
            target: targetFrameRate,
            receivedFrames: receivedFrameCount,
            deliveredFrames: deliveredFrameCount,
            writerDroppedFrames: writerDroppedFrameCount + videoIngress.droppedCount,
            idleFrames: idleFrameCount,
            elapsed: elapsed,
            maxFrameInterval: maximumFrameInterval,
            intervalDiagnostics: intervalDiagnostics
        )
        logDiagnosticIfDue(measurement)
        return measurement
    }

    /// Once per second, publish the capture pipeline's real numbers so the
    /// console can separate display limits, encoder throughput and idle
    /// content when diagnosing a low delivered frame rate.
    private func logDiagnosticIfDue(_ measurement: FrameRateMeasurement) {
#if DEBUG
        let now = CACurrentMediaTime()
        let recentElapsed = lastDiagnosticLogTime > 0
            ? now - lastDiagnosticLogTime
            : measurement.elapsed
        guard recentElapsed >= 1.0 else { return }
        let recentReceived = measurement.receivedFrames - lastDiagnosticReceivedFrameCount
        let recentDelivered = measurement.deliveredFrames - lastDiagnosticDeliveredFrameCount
        let recentIdle = measurement.idleFrames - lastDiagnosticIdleFrameCount
        let recentWriterDrops = measurement.writerDroppedFrames - lastDiagnosticWriterDropCount
        let recentGaps = FrameIntervalDiagnostics(consuming: &recentFrameIntervals)
        recentFrameIntervals.removeAll(keepingCapacity: true)
        lastDiagnosticLogTime = now
        lastDiagnosticReceivedFrameCount = measurement.receivedFrames
        lastDiagnosticDeliveredFrameCount = measurement.deliveredFrames
        lastDiagnosticIdleFrameCount = measurement.idleFrames
        lastDiagnosticWriterDropCount = measurement.writerDroppedFrames
        let sckComplete = Double(max(recentReceived, 0)) / recentElapsed
        let idle = Double(max(recentIdle, 0)) / recentElapsed
        let delivered = Double(max(recentDelivered, 0)) / recentElapsed
        let message = "capture diagnostic: "
            + "target=\(measurement.target.rawValue)fps "
            + "recentSCKComplete=\(String(format: "%.1f", sckComplete))fps "
            + "recentIdle=\(String(format: "%.1f", idle))fps "
            + "recentDelivered=\(String(format: "%.1f", delivered))fps "
            + "recentWriterDropped=\(max(recentWriterDrops, 0)) "
            + "recentGapP95=\(String(format: "%.2f", recentGaps.p95 * 1_000))ms "
            + "recentGapP99=\(String(format: "%.2f", recentGaps.p99 * 1_000))ms "
            + "recentGapsOver33ms=\(recentGaps.over33Milliseconds) "
            + "recentLongestOver33msRun="
            + "\(recentGaps.maximumConsecutiveOver33Milliseconds)"
        Self.logger.notice("\(message, privacy: .public)")
#endif
    }
}
