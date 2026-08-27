import AppKit
import AVFoundation
import Combine
import CoreImage
import QuartzCore
import RecorderCore

enum EditorPlaybackLifecycle: Equatable {
    case empty
    case preparing
    case ready(generation: UInt64)
    case failed(String)
}

/// Stable AVFoundation endpoints for one prepared media generation. The render
/// surface may pull pixels from these outputs, but it never owns or reads the
/// players that drive them.
struct EditorPlaybackMediaEndpoints {
    let generation: UInt64
    let screenOutput: AVPlayerItemVideoOutput
    let screenPreferredTransform: CGAffineTransform
    let cameraOutput: AVPlayerItemVideoOutput?
    let cameraPreferredTransform: CGAffineTransform
}

/// One immutable display-refresh sample. Scene evaluation and video-output
/// lookup consume this exact value so geometry and pixels cannot independently
/// sample the master player clock.
struct EditorPlaybackRenderTick: Equatable {
    let mediaGeneration: UInt64
    let discontinuityID: UInt64
    let outputTime: TimeInterval
    let itemTime: CMTime
    let cameraIsAvailable: Bool
    let isPlaying: Bool
}

struct EditorPlaybackClockPolicy {
    static func clampedTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return min(max(time, 0), max(duration, 0))
    }

    static func resolvedTime(
        playerTime: TimeInterval,
        anchorTime: TimeInterval,
        anchorUptime: TimeInterval,
        uptime: TimeInterval,
        rate: Float,
        transportIsAdvancing: Bool,
        duration: TimeInterval
    ) -> TimeInterval {
        // PRE-SYNC-001: the audio-bearing AVPlayer is the editor's master
        // clock. Its currentTime is a continuous item timebase; VFR changes
        // when a new pixel buffer is available, not the speed of this clock.
        // Predicting a second display-link clock here let preview video run
        // ahead while audio was still following AVPlayer, which is perceived
        // as lip-sync drift and can leave a cached camera frame on screen.
        if playerTime.isFinite, playerTime >= 0 {
            return clampedTime(playerTime, duration: duration)
        }

        // Keep a monotonic fallback only for the short interval in which
        // AVFoundation cannot vend a numeric item time (item replacement or
        // initial preparation). It must never override a valid media clock.
        let safeRate = rate > 0 && transportIsAdvancing ? Double(rate) : 0
        return clampedTime(
            anchorTime + max(uptime - anchorUptime, 0) * safeRate,
            duration: duration
        )
    }

}

struct EditorScrubSeekCoalescer: Equatable {
    private(set) var pendingTarget: TimeInterval?

    mutating func update(_ target: TimeInterval) {
        pendingTarget = target
    }

    mutating func takePending() -> TimeInterval? {
        defer { pendingTarget = nil }
        return pendingTarget
    }

    mutating func cancel() {
        pendingTarget = nil
    }
}

enum EditorCameraSyncAction: Equatable {
    case pauseAndHide
    case waitForPendingSeek
    case seek(TimeInterval, tolerance: TimeInterval)
    case matchRate(Float)
    case none
}

struct EditorCameraSyncPolicy {
    static func action(
        outputTime: TimeInterval,
        isAvailable: Bool,
        cameraTime: TimeInterval,
        masterRate: Float,
        cameraRate: Float,
        cameraFrameRate: Double,
        hasPendingSeek: Bool,
        force: Bool
    ) -> EditorCameraSyncAction {
        guard isAvailable else { return .pauseAndHide }
        guard !hasPendingSeek || force else { return .waitForPendingSeek }
        // SYNC-002: camera clocks must be judged at the camera's cadence, not
        // at the 60 FPS screen/export cadence. Project 02 has a healthy 25 FPS
        // camera stream (40 ms frames); the old 16.7 ms threshold interpreted
        // ordinary frame holds as drift and repeatedly exact-seeked the camera,
        // visibly freezing a speaking frame. Leave 1.5 camera frames for
        // cadence/jitter and only repair material drift.
        let safeCameraFrameRate = max(cameraFrameRate, 1)
        let tolerance = max(1.5 / safeCameraFrameRate, 0.040)
        if force || !cameraTime.isFinite || abs(cameraTime - outputTime) > tolerance {
            return .seek(outputTime, tolerance: tolerance / 2)
        }
        if masterRate == 0 {
            return cameraRate == 0 ? .none : .matchRate(0)
        }
        return cameraRate == masterRate ? .none : .matchRate(masterRate)
    }
}

@MainActor
protocol EditorPlaybackTransport: AnyObject {
    var item: AVPlayerItem? { get }
    var currentTimeSeconds: TimeInterval { get }
    var playbackRate: Float { get }
    var playbackClockIsAdvancing: Bool { get }
    func playTransport()
    func playTransportImmediately(atRate rate: Float)
    func playTransport(
        at itemTime: CMTime,
        hostTime: CMTime,
        rate: Float
    )
    func pauseTransport()
    func cancelPendingSeeks()
    func seekTransport(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) async -> Bool
}

extension AVPlayer: EditorPlaybackTransport {
    var item: AVPlayerItem? { currentItem }
    var currentTimeSeconds: TimeInterval { currentTime().seconds }
    var playbackRate: Float { rate }
    var playbackClockIsAdvancing: Bool { timeControlStatus == .playing }

    func playTransport() { play() }
    func playTransportImmediately(atRate rate: Float) { playImmediately(atRate: rate) }
    func playTransport(at itemTime: CMTime, hostTime: CMTime, rate: Float) {
        setRate(rate, time: itemTime, atHostTime: hostTime)
    }
    func pauseTransport() { pause() }
    func cancelPendingSeeks() { currentItem?.cancelPendingSeeks() }

    func seekTransport(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            seek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter
            ) { continuation.resume(returning: $0) }
        }
    }
}

/// The editor's sole AVPlayer transport owner. Media analysis/composition stay
/// in EditorMediaSession; project evaluation and pixel composition stay in the
/// scene/renderer layers.
@MainActor
final class EditorPlaybackController: ObservableObject {
    typealias TransportFactory = (_ item: AVPlayerItem, _ isMuted: Bool) -> any EditorPlaybackTransport
    typealias InitialFrameProvider = @MainActor (
        _ output: AVPlayerItemVideoOutput,
        _ itemTime: CMTime,
        _ preferredTransform: CGAffineTransform
    ) async -> NSImage?
    @Published private(set) var lifecycle: EditorPlaybackLifecycle = .empty
    // 以下成员的写入放宽到模块内，仅供 EditorPlaybackScrubbing /
    // EditorPlaybackPausedFrames / EditorPlaybackHoverPreview 扩展使用。
    @Published var isPlaying = false {
        didSet {
            if oldValue != isPlaying { notifyNativeTimelineObservers() }
        }
    }
    @Published private(set) var duration: TimeInterval = 0 {
        didSet {
            if oldValue != duration { notifyNativeTimelineObservers() }
        }
    }
    @Published private(set) var endpoints: EditorPlaybackMediaEndpoints?
    @Published var pausedScreenImage: NSImage?
    @Published var pausedCameraImage: NSImage?
    @Published private(set) var discontinuityID: UInt64 = 0
    @Published private(set) var errorMessage: String?
    /// Acknowledges that the camera-only timing composition/player has been
    /// installed. Sync audition waits for this value, not merely for the
    /// project/media-session model to publish its new anchors.
    @Published private(set) var cameraTimingRevision: UInt64 = 0
    /// Latest transport time without ObservableObject publication. The canvas
    /// display link samples it once, then native timeline layers receive that
    /// snapshot through the observer hub; publishing through SwiftUI laid out
    /// the entire editor on every refresh.
    private var defersNativeTimelineNotification = false
    private var nativeTimelineNotificationIsPending = false
    var latestOutputTime: TimeInterval = 0 {
        didSet {
            if abs(oldValue - latestOutputTime) > 0.000_001 {
                if defersNativeTimelineNotification {
                    nativeTimelineNotificationIsPending = true
                } else {
                    notifyNativeTimelineObservers()
                }
            }
        }
    }
    var outputTime: TimeInterval { latestOutputTime }

    /// The canvas owns the editor's only display link. Native time labels and
    /// timeline layers receive that sampled clock instead of creating three
    /// more run-loop sources that wake the main thread independently.
    private let nativeTimelineObservers = EditorPlaybackTimelineObserverHub()

    func addNativeTimelineObserver(_ observer: any EditorPlaybackTimelineObserver) {
        nativeTimelineObservers.add(observer, current: nativeTimelineSnapshot)
    }

    func removeNativeTimelineObserver(_ observer: any EditorPlaybackTimelineObserver) {
        nativeTimelineObservers.remove(observer)
    }

    private var nativeTimelineSnapshot: EditorPlaybackTimelineSnapshot {
        EditorPlaybackTimelineSnapshot(
            outputTime: latestOutputTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private func notifyNativeTimelineObservers() {
        nativeTimelineObservers.publish(nativeTimelineSnapshot)
    }

    /// The display-link frame gives visual composition first use of the sampled
    /// clock. Native playheads and labels still consume that exact snapshot in
    /// the same callback, but only after the frame has been evaluated and queued.
    /// Seek, pause and other non-display-link mutations continue to publish
    /// immediately through `latestOutputTime.didSet`.
    func flushDeferredNativeTimelineNotification() {
        guard nativeTimelineNotificationIsPending else { return }
        nativeTimelineNotificationIsPending = false
        notifyNativeTimelineObservers()
    }

    // 以下传输与令牌成员的读写放宽到模块内，仅供给
    // `EditorPlaybackHoverPreview.swift` 扩展使用；其他代码不得触碰。
    private(set) var primaryPlayer: (any EditorPlaybackTransport)?
    private(set) var cameraPlayer: (any EditorPlaybackTransport)?
    private(set) var preparedMedia: EditorPreparedMedia?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var installToken: UInt64 = 0
    var seekToken: UInt64 = 0
    var playbackStartToken: UInt64 = 0
    var cameraSeekToken: UInt64 = 0
    var cameraSeekIsPending = false
    private var lastCameraAvailability = false
    private var playbackAnchorTime: TimeInterval = 0
    private var playbackAnchorUptime: TimeInterval = 0
    var pausedFrameTask: Task<Void, Never>?
    var pausedFrameDecodeToken: UInt64 = 0
    var scrubSeekTask: Task<Void, Never>?
    var scrubSeekCoalescer = EditorScrubSeekCoalescer()
    var scrubIsActive = false
    /// EDT-030 悬浮预览轴：暂停时指针扫过时间线，画布实时显示所指帧，但
    /// 逻辑时钟（`latestOutputTime`、播放头、时间码、总览）保持不动；只有
    /// 传输层被物理 seek 到所指帧。悬浮结束时传输层回到播放头，下一次播
    /// 放、精确暂停帧和导出位置都不被悬浮污染。
    /// 机器实现拆在 `EditorPlaybackHoverPreview.swift` 扩展（架构行数预算）；
    /// 存储属性只能留在主声明里，访问级别随之放宽到模块内，但仍只允许该
    /// 扩展写入。
    @Published var hoverPreviewTime: TimeInterval?
    var hoverSeekTask: Task<Void, Never>?
    var hoverSeekCoalescer = EditorScrubSeekCoalescer()
    private var primarySeekIsPending = false
    /// Every AVAssetImageGenerator backing `pausedFrameTask`. A camera project
    /// owns both a screen and camera generator; cancelling only one leaves the
    /// other decoding a retired seek in the background.
    var pausedFrameRequests: [PausedPreviewFrameRequest] = []
    private(set) var frameRate = 60
    private var cameraFrameRate: Double = 30
    private var deferredPlaybackIntent = false
    private let transportFactory: TransportFactory
    private let suppliedInitialFrameProvider: InitialFrameProvider?
    private lazy var initialFrameColorProfile = try? CoreImageFrameColorProfile(
        contract: .sdrDesktop
    )
    /// One raster context per editor, shared by every media-generation handoff.
    /// EditorView owns this controller as a StateObject, so closing the editor
    /// still releases the context instead of creating an app-lifetime cache.
    private lazy var initialFrameContext: CIContext = initialFrameColorProfile?
        .makeContext(cacheIntermediates: false)
        ?? CIContext(options: [.cacheIntermediates: false])

    init(
        transportFactory: @escaping TransportFactory = { item, isMuted in
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            player.isMuted = isMuted
            player.actionAtItemEnd = .pause
            return player
        },
        initialFrameProvider: InitialFrameProvider? = nil
    ) {
        self.transportFactory = transportFactory
        suppliedInitialFrameProvider = initialFrameProvider
    }

    var canPlay: Bool {
        guard case .ready = lifecycle else { return false }
        return primaryPlayer != nil && duration > 0
    }

    func install(
        _ prepared: EditorPreparedMedia?,
        audio: AudioStyle,
        frameRate: Int,
        initialTime: TimeInterval? = nil,
        cameraTimingRevision: UInt64 = 0
    ) async {
        installToken &+= 1
        let requestedInstall = installToken
        guard let prepared else {
            teardownTransport(resetTime: false)
            lifecycle = .preparing
            return
        }
        if endpoints?.generation == prepared.generation,
           preparedMedia?.generation == prepared.generation {
            if preparedMedia?.plan.camera != prepared.plan.camera
                || preparedMedia?.request.mediaManifest?.camera
                    != prepared.request.mediaManifest?.camera {
                await installCameraTimingUpdate(
                    prepared,
                    requestedInstall: requestedInstall
                )
            } else {
                preparedMedia = prepared
            }
            self.frameRate = max(frameRate, 1)
            cameraFrameRate = prepared.inventories.camera.videoFrameRate ?? 30
            guard installToken == requestedInstall else { return }
            self.cameraTimingRevision = cameraTimingRevision
            updateAudio(audio)
            return
        }

        // PRE-008: hold the last valid generation while the replacement items
        // seek. Clearing endpoints here made every split/delete expose the
        // renderer's black fallback until the new players became ready.
        if primaryPlayer != nil, endpoints != nil {
            playbackStartToken &+= 1
            seekToken &+= 1
            cameraSeekToken &+= 1
            cameraSeekIsPending = false
            cancelScrubScheduling()
            scrubIsActive = false
            cancelPausedFrameDecode()
            let heldTime = EditorPlaybackClockPolicy.clampedTime(
                isPlaying ? (primaryPlayer?.currentTimeSeconds ?? outputTime) : outputTime,
                duration: duration
            )
            primaryPlayer?.pauseTransport()
            cameraPlayer?.pauseTransport()
            primaryPlayer?.cancelPendingSeeks()
            cameraPlayer?.cancelPendingSeeks()
            isPlaying = false
            latestOutputTime = heldTime
            resetPlaybackAnchor(to: heldTime)
        } else {
            teardownTransport(resetTime: false)
        }
        lifecycle = .preparing
        let bundle = prepared.composition
        let pixelBufferAttributes: [String: any Sendable] = [
            // Keep decoded H.264 frames in the hardware-native NV12 format.
            // Core Image consumes this directly; asking AVPlayer for BGRA
            // inserted a full-frame YCbCr conversion and 2.67x memory traffic
            // before every preview composition.
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let item = AVPlayerItem(asset: bundle.primaryComposition)
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = Self.previewAudioMix(for: audio, bundle: bundle)
        let screenOutput = AVPlayerItemVideoOutput(
            pixelBufferAttributes: pixelBufferAttributes
        )
        item.add(screenOutput)
        let player = transportFactory(item, false)

        let cameraItem = bundle.cameraComposition.map { AVPlayerItem(asset: $0) }
        let cameraOutput = cameraItem.map { item in
            let output = AVPlayerItemVideoOutput(
                pixelBufferAttributes: pixelBufferAttributes
            )
            item.add(output)
            return output
        }
        let cameraPlayer = cameraItem.map { transportFactory($0, true) }
        let safeTime = EditorPlaybackClockPolicy.clampedTime(
            initialTime ?? outputTime,
            duration: prepared.outputDuration
        )
        _ = await player.seekTransport(
            to: CMTime(seconds: safeTime, preferredTimescale: 60_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if let cameraPlayer,
           prepared.plan.camera?.contains(outputTime: safeTime) == true {
            _ = await cameraPlayer.seekTransport(
                to: CMTime(seconds: safeTime, preferredTimescale: 60_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        // A completed player seek does not guarantee that
        // AVPlayerItemVideoOutput can vend the first pixel immediately. Decode
        // one exact screen frame before exposing the new transport as ready;
        // otherwise an immediate Space press can cancel the asynchronous
        // paused decode and reveal CAMetalLayer's black fallback.
        let initialFrameTime = CMTime(
            seconds: safeTime,
            preferredTimescale: 60_000
        )
        let screenPreferredTransform = bundle.primaryVideoTrack.preferredTransform
        let cameraPreferredTransform = bundle.cameraVideoTrack?.preferredTransform ?? .identity
        async let decodedFirstScreen = loadInitialFrame(
            screenOutput,
            initialFrameTime,
            screenPreferredTransform
        )
        let firstCameraImage: NSImage?
        if let cameraOutput,
           prepared.plan.camera?.contains(outputTime: safeTime) == true {
            firstCameraImage = await loadInitialFrame(
                cameraOutput,
                initialFrameTime,
                cameraPreferredTransform
            )
        } else {
            firstCameraImage = nil
        }
        let firstScreenImage = await decodedFirstScreen
        guard !Task.isCancelled, installToken == requestedInstall else {
            player.pauseTransport()
            cameraPlayer?.pauseTransport()
            return
        }

        // Swap the complete transport generation in one MainActor turn. The
        // old endpoints remain renderable until this exact point.
        removeObservers()
        primaryPlayer?.pauseTransport()
        self.cameraPlayer?.pauseTransport()
        primaryPlayer = player
        self.cameraPlayer = cameraPlayer
        preparedMedia = prepared
        self.frameRate = max(frameRate, 1)
        cameraFrameRate = prepared.inventories.camera.videoFrameRate ?? 30
        duration = prepared.outputDuration
        latestOutputTime = safeTime
        pausedScreenImage = firstScreenImage
        pausedCameraImage = firstCameraImage
        endpoints = EditorPlaybackMediaEndpoints(
            generation: prepared.generation,
            screenOutput: screenOutput,
            screenPreferredTransform: screenPreferredTransform,
            cameraOutput: cameraOutput,
            cameraPreferredTransform: cameraPreferredTransform
        )
        lifecycle = .ready(generation: prepared.generation)
        self.cameraTimingRevision = cameraTimingRevision
        errorMessage = nil
        lastCameraAvailability = cameraIsAvailable(at: safeTime)
        advanceDiscontinuity()
        resetPlaybackAnchor(to: safeTime)
        installObservers(for: item)
        if deferredPlaybackIntent {
            deferredPlaybackIntent = false
            startPlaybackFromCurrentPosition()
        } else {
            refreshPausedFrames(at: safeTime)
        }
    }

    func updateAudio(_ audio: AudioStyle) {
        guard let preparedMedia else { return }
        primaryPlayer?.item?.audioMix = Self.previewAudioMix(
            for: audio,
            bundle: preparedMedia.composition
        )
    }

    /// Replaces only the camera transport after a sync-anchor edit. The
    /// audio-bearing primary player and its video output remain untouched, so
    /// repeated lip-sync nudges cannot blank the canvas or rebuild long audio
    /// compositions.
    private func installCameraTimingUpdate(
        _ prepared: EditorPreparedMedia,
        requestedInstall: UInt64
    ) async {
        guard let endpoints else {
            preparedMedia = prepared
            return
        }
        let bundle = prepared.composition
        let pixelBufferAttributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let cameraItem = bundle.cameraComposition.map { AVPlayerItem(asset: $0) }
        let cameraOutput = cameraItem.map { item in
            let output = AVPlayerItemVideoOutput(
                pixelBufferAttributes: pixelBufferAttributes
            )
            item.add(output)
            return output
        }
        let replacementPlayer = cameraItem.map { transportFactory($0, true) }
        let target = EditorPlaybackClockPolicy.clampedTime(outputTime, duration: duration)
        let cameraIsAvailable = prepared.plan.camera?.contains(outputTime: target) == true
        if let replacementPlayer, cameraIsAvailable {
            _ = await replacementPlayer.seekTransport(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        let firstCameraImage: NSImage?
        if let cameraOutput, cameraIsAvailable {
            firstCameraImage = await loadInitialFrame(
                cameraOutput,
                CMTime(seconds: target, preferredTimescale: 60_000),
                bundle.cameraVideoTrack?.preferredTransform ?? .identity
            )
        } else {
            firstCameraImage = nil
        }
        guard !Task.isCancelled, installToken == requestedInstall else {
            replacementPlayer?.pauseTransport()
            return
        }

        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        cameraPlayer?.pauseTransport()
        cameraPlayer = replacementPlayer
        preparedMedia = prepared
        cameraFrameRate = prepared.inventories.camera.videoFrameRate ?? 30
        pausedCameraImage = firstCameraImage ?? pausedCameraImage
        self.endpoints = EditorPlaybackMediaEndpoints(
            generation: endpoints.generation,
            screenOutput: endpoints.screenOutput,
            screenPreferredTransform: endpoints.screenPreferredTransform,
            cameraOutput: cameraOutput,
            cameraPreferredTransform: bundle.cameraVideoTrack?.preferredTransform ?? .identity
        )
        lastCameraAvailability = self.cameraIsAvailable(at: target)
        advanceDiscontinuity()

        guard let replacementPlayer, lastCameraAvailability else { return }
        if isPlaying, let primaryPlayer {
            let currentMasterTime = EditorPlaybackClockPolicy.clampedTime(
                primaryPlayer.currentTimeSeconds,
                duration: duration
            )
            let sharedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: 0.010, preferredTimescale: 60_000)
            replacementPlayer.playTransport(
                at: CMTime(seconds: currentMasterTime, preferredTimescale: 60_000),
                hostTime: sharedHostTime,
                rate: primaryPlayer.playbackRate
            )
        } else {
            replacementPlayer.pauseTransport()
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Normal editor transport intent. A timeline edit may temporarily put the
    /// replacement composition in `.preparing`; Space must survive that short
    /// window instead of being swallowed or forwarded to a focused control.
    func togglePlaybackFromUserIntent() {
        if canPlay {
            deferredPlaybackIntent = false
            togglePlayback()
            return
        }
        if case .preparing = lifecycle {
            deferredPlaybackIntent.toggle()
        }
    }

    func play() {
        guard canPlay else { return }
        if outputTime >= duration - 0.000_1 {
            seek(to: 0, pausing: true, resumeAfterCompletion: true)
            return
        }
        startPlaybackFromCurrentPosition()
    }

    private func startPlaybackFromCurrentPosition() {
        guard canPlay, let primaryPlayer else { return }
        if hoverPreviewTime != nil {
            // 悬浮预览期间传输层物理位置停在所指帧；无摄像头路径的
            // playTransport() 会从该位置起播。先走“精确 seek + 完成后
            // 恢复播放”的既有编排，从播放头起播。
            endHoverPreview(restoreTransport: false)
            seek(to: outputTime, pausing: true, resumeAfterCompletion: true)
            return
        }
        cancelScrubScheduling()
        scrubIsActive = false
        primarySeekIsPending = false
        cancelPausedFrameDecode()
        playbackStartToken &+= 1
        let requestedStart = playbackStartToken
        let requestedGeneration = endpoints?.generation
        let target = EditorPlaybackClockPolicy.clampedTime(outputTime, duration: duration)
        isPlaying = true

        // SYNC-001: the audio-bearing master must not start while the separate
        // camera player is still seeking. After a ripple edit the camera item
        // needs a fresh exact seek; starting the master first permanently puts
        // the camera behind by that seek's wall-clock latency.
        guard let cameraPlayer, cameraIsAvailable(at: target) else {
            pausedScreenImage = nil
            pausedCameraImage = nil
            resetPlaybackAnchor(to: target)
            primaryPlayer.playTransport()
            synchronizeCamera(to: target, force: true)
            return
        }

        primaryPlayer.pauseTransport()
        cameraPlayer.pauseTransport()
        cameraPlayer.cancelPendingSeeks()
        cameraSeekToken &+= 1
        let requestedCameraSeek = cameraSeekToken
        cameraSeekIsPending = true
        Task { [weak self] in
            let finished = await cameraPlayer.seekTransport(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard let self,
                  self.playbackStartToken == requestedStart,
                  self.cameraSeekToken == requestedCameraSeek,
                  self.endpoints?.generation == requestedGeneration else { return }
            self.cameraSeekIsPending = false
            guard finished, self.isPlaying, self.cameraIsAvailable(at: target) else {
                self.isPlaying = false
                self.primaryPlayer?.pauseTransport()
                self.cameraPlayer?.pauseTransport()
                self.refreshPausedFrames(at: target)
                return
            }
            self.pausedScreenImage = nil
            self.pausedCameraImage = nil
            self.resetPlaybackAnchor(to: target)
            // SYNC-002: schedule both independent AVPlayers against one future
            // host-clock instant. Two immediate play calls merely happen near
            // each other; `setRate(_:time:atHostTime:)` gives them the same
            // native clock edge and prevents a cut/rebuild from baking in the
            // call/decoder latency between camera and microphone playback.
            let itemTime = CMTime(seconds: target, preferredTimescale: 60_000)
            let sharedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: 0.015, preferredTimescale: 60_000)
            self.primaryPlayer?.playTransport(
                at: itemTime,
                hostTime: sharedHostTime,
                rate: 1
            )
            self.cameraPlayer?.playTransport(
                at: itemTime,
                hostTime: sharedHostTime,
                rate: 1
            )
        }
    }

    func pause() {
        guard isPlaying else { return }
        playbackStartToken &+= 1
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        guard let primaryPlayer else {
            isPlaying = false
            return
        }
        let sampled = EditorPlaybackClockPolicy.clampedTime(
            primaryPlayer.currentTimeSeconds,
            duration: duration
        )
        primaryPlayer.pauseTransport()
        cameraPlayer?.pauseTransport()
        isPlaying = false
        primarySeekIsPending = false
        latestOutputTime = sampled
        resetPlaybackAnchor(to: sampled)
        advanceDiscontinuity()
        refreshPausedFrames(at: sampled)
    }

    func seek(
        to requestedTime: TimeInterval,
        pausing: Bool = true,
        resumeAfterCompletion: Bool = false,
        loadsPausedFrame: Bool = true
    ) {
        guard let primaryPlayer else {
            latestOutputTime = requestedTime
            return
        }
        // 显式 seek（键盘步进、点击标尺等）接管传输层，悬浮预览立即让位。
        endHoverPreview(restoreTransport: false)
        let target = EditorPlaybackClockPolicy.clampedTime(requestedTime, duration: duration)
        playbackStartToken &+= 1
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        seekToken &+= 1
        let requestedSeek = seekToken
        let requestedGeneration = endpoints?.generation
        primarySeekIsPending = true
        if pausing {
            primaryPlayer.pauseTransport()
            cameraPlayer?.pauseTransport()
            isPlaying = false
        }
        primaryPlayer.cancelPendingSeeks()
        cancelPausedFrameDecode()
        // 保留上一张暂停帧继续显示：异步精确 seek + 新帧解码完成前不黑屏，
        // 快速拖动播放头时旧帧短暂停留远比全程黑帧好。
        latestOutputTime = target
        resetPlaybackAnchor(to: target)
        advanceDiscontinuity()
        Task { [weak self] in
            let finished = await primaryPlayer.seekTransport(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard let self,
                  self.seekToken == requestedSeek,
                  self.endpoints?.generation == requestedGeneration else { return }
            self.primarySeekIsPending = false
            guard finished else { return }
            self.latestOutputTime = target
            self.resetPlaybackAnchor(to: target)
            if resumeAfterCompletion {
                self.startPlaybackFromCurrentPosition()
            } else if !self.isPlaying {
                self.synchronizeCamera(to: target, force: true)
                if loadsPausedFrame {
                    self.refreshPausedFrames(at: target, seekToken: requestedSeek)
                } else {
                    // A throttled scrub seek is already decoded by AVPlayer.
                    // Publish only after it lands so the stationary surface
                    // pulls that frame without launching another generator.
                    self.advanceDiscontinuity()
                }
            }
        }
    }


    /// Called by the canvas display link. When the video output can translate
    /// the display's target host time into its item time, that value is the
    /// canonical clock for both scene evaluation and pixel-buffer lookup.
    /// Falling back to `AVPlayer.currentTime()` is reserved for the short
    /// hand-off where the output timebase is not yet numeric.
    func renderTick(
        itemTimeForDisplay: CMTime? = nil,
        uptime: TimeInterval = CACurrentMediaTime()
    ) -> EditorPlaybackRenderTick? {
        guard let primaryPlayer, let endpoints else { return nil }
        let sampledPlayerTime = primaryPlayer.currentTimeSeconds
        let displayItemSeconds = itemTimeForDisplay?.seconds
        let time: TimeInterval
        if let displayItemSeconds,
           displayItemSeconds.isFinite,
           displayItemSeconds >= 0 {
            time = EditorPlaybackClockPolicy.clampedTime(
                displayItemSeconds,
                duration: duration
            )
        } else {
            time = EditorPlaybackClockPolicy.resolvedTime(
                playerTime: sampledPlayerTime,
                anchorTime: playbackAnchorTime,
                anchorUptime: playbackAnchorUptime,
                uptime: uptime,
                rate: primaryPlayer.playbackRate,
                transportIsAdvancing: primaryPlayer.playbackClockIsAdvancing,
                duration: duration
            )
        }
        if sampledPlayerTime.isFinite, sampledPlayerTime >= 0 {
            resetPlaybackAnchor(to: time, uptime: uptime)
        }
        defersNativeTimelineNotification = true
        latestOutputTime = time
        defersNativeTimelineNotification = false
        let availability = cameraIsAvailable(at: time)
        if availability != lastCameraAvailability {
            lastCameraAvailability = availability
            advanceDiscontinuity()
        }
        synchronizeCamera(to: time)
        return EditorPlaybackRenderTick(
            mediaGeneration: endpoints.generation,
            discontinuityID: discontinuityID,
            outputTime: time,
            itemTime: CMTime(seconds: time, preferredTimescale: 60_000),
            cameraIsAvailable: availability,
            isPlaying: isPlaying
        )
    }

    var stationaryRenderTick: EditorPlaybackRenderTick? {
        guard let endpoints else { return nil }
        let time = EditorPlaybackClockPolicy.clampedTime(outputTime, duration: duration)
        return EditorPlaybackRenderTick(
            mediaGeneration: endpoints.generation,
            discontinuityID: discontinuityID,
            outputTime: time,
            itemTime: CMTime(seconds: time, preferredTimescale: 60_000),
            cameraIsAvailable: cameraIsAvailable(at: time),
            isPlaying: false
        )
    }

    func invalidate() {
        installToken &+= 1
        deferredPlaybackIntent = false
        cancelScrubScheduling()
        scrubIsActive = false
        primarySeekIsPending = false
        teardownTransport(resetTime: true)
        // `cacheIntermediates: false` prevents graph caching, but Core Image
        // can still retain render-target IOSurfaces used to turn the first
        // player pixel buffer into an NSImage. The controller may outlive the
        // visible SwiftUI tree briefly during AppKit window teardown, so clear
        // that private pool at the explicit editor lifecycle boundary.
        initialFrameContext.clearCaches()
        lifecycle = .empty
        cameraTimingRevision = 0
        errorMessage = nil
    }

    func synchronizeCamera(to time: TimeInterval, force: Bool = false) {
        guard let primaryPlayer, let cameraPlayer, let preparedMedia else { return }
        let available = preparedMedia.plan.camera?.contains(outputTime: time) == true
        let action = EditorCameraSyncPolicy.action(
            outputTime: time,
            isAvailable: available,
            cameraTime: cameraPlayer.currentTimeSeconds,
            masterRate: primaryPlayer.playbackRate,
            cameraRate: cameraPlayer.playbackRate,
            cameraFrameRate: cameraFrameRate,
            hasPendingSeek: cameraSeekIsPending,
            force: force
        )
        switch action {
        case .pauseAndHide:
            cameraPlayer.pauseTransport()
            cameraSeekToken &+= 1
            cameraSeekIsPending = false
        case .waitForPendingSeek, .none:
            break
        case let .matchRate(rate):
            if rate == 0 {
                cameraPlayer.pauseTransport()
            } else {
                cameraPlayer.playTransportImmediately(atRate: rate)
            }
        case let .seek(target, tolerance):
            cameraSeekToken &+= 1
            let requestedCameraSeek = cameraSeekToken
            let requestedGeneration = endpoints?.generation
            cameraSeekIsPending = true
            if force { cameraPlayer.cancelPendingSeeks() }
            let toleranceTime = CMTime(seconds: tolerance, preferredTimescale: 60_000)
            Task { [weak self] in
                let finished = await cameraPlayer.seekTransport(
                    to: CMTime(seconds: target, preferredTimescale: 60_000),
                    toleranceBefore: force ? .zero : toleranceTime,
                    toleranceAfter: force ? .zero : toleranceTime
                )
                guard let self,
                      self.cameraSeekToken == requestedCameraSeek,
                      self.endpoints?.generation == requestedGeneration else { return }
                self.cameraSeekIsPending = false
                guard finished else {
                    // seek 失败：相机停在陈旧位置。强制暂停，避免过期帧继续
                    // 参与合成；下一次同步周期会自然重试。
                    self.cameraPlayer?.pauseTransport()
                    return
                }
                guard self.cameraIsAvailable(at: target) else { return }
                if self.isPlaying, let primaryPlayer = self.primaryPlayer {
                    // PRE-SYNC-002: the master kept advancing while the
                    // camera's asynchronous seek decoded. Resuming from the
                    // original `target` bakes that seek latency into every
                    // subsequent frame. Rejoin at the master's *current* item
                    // time on one future host-clock edge instead.
                    let currentMasterTime = EditorPlaybackClockPolicy.clampedTime(
                        primaryPlayer.currentTimeSeconds,
                        duration: self.duration
                    )
                    let sharedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                        + CMTime(seconds: 0.010, preferredTimescale: 60_000)
                    self.cameraPlayer?.playTransport(
                        at: CMTime(
                            seconds: currentMasterTime,
                            preferredTimescale: 60_000
                        ),
                        hostTime: sharedHostTime,
                        rate: primaryPlayer.playbackRate
                    )
                } else {
                    self.cameraPlayer?.pauseTransport()
                }
            }
        }
    }

    private func installObservers(for item: AVPlayerItem) {
        removeObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.seek(to: 0, pausing: true) }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error)?.localizedDescription ?? "预览播放失败"
            Task { @MainActor in
                guard let self else { return }
                self.primaryPlayer?.pauseTransport()
                self.cameraPlayer?.pauseTransport()
                self.playbackStartToken &+= 1
                self.cameraSeekToken &+= 1
                self.cameraSeekIsPending = false
                self.isPlaying = false
                self.deferredPlaybackIntent = false
                self.lifecycle = .failed(message)
                self.errorMessage = message
            }
        }
    }

    func cameraIsAvailable(at time: TimeInterval) -> Bool {
        cameraPlayer != nil
            && preparedMedia?.plan.camera?.contains(outputTime: time) == true
    }


    private func loadInitialFrame(
        _ output: AVPlayerItemVideoOutput,
        _ itemTime: CMTime,
        _ preferredTransform: CGAffineTransform
    ) async -> NSImage? {
        if let suppliedInitialFrameProvider {
            return await suppliedInitialFrameProvider(
                output,
                itemTime,
                preferredTransform
            )
        }
        return await Self.waitForInitialFrame(
            output: output,
            itemTime: itemTime,
            preferredTransform: preferredTransform,
            context: initialFrameContext,
            outputColorSpace: initialFrameColorProfile?.outputColorSpace
        )
    }

    /// Wait for the player output that will drive live preview; do not start a
    /// second AVAssetImageGenerator over a long audio-bearing composition.
    /// The latter made opening a long project run an offline mix end to end.
    private static func waitForInitialFrame(
        output: AVPlayerItemVideoOutput,
        itemTime: CMTime,
        preferredTransform: CGAffineTransform,
        context: CIContext,
        outputColorSpace: CGColorSpace?
    ) async -> NSImage? {
        func imageIfAvailable() -> NSImage? {
            guard let pixelBuffer = output.copyPixelBuffer(
                forItemTime: itemTime,
                itemTimeForDisplay: nil
            ) else { return nil }
            var image = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: preferredTransform)
            let extent = image.extent.integral
            guard !extent.isEmpty, !extent.isInfinite else { return nil }
            image = image.transformed(
                by: CGAffineTransform(
                    translationX: -extent.minX,
                    y: -extent.minY
                )
            )
            let normalizedExtent = image.extent.integral
            let cgImage: CGImage?
            if let outputColorSpace {
                cgImage = context.createCGImage(
                    image,
                    from: normalizedExtent,
                    format: .BGRA8,
                    colorSpace: outputColorSpace
                )
            } else {
                cgImage = context.createCGImage(image, from: normalizedExtent)
            }
            guard let cgImage else { return nil }
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        if Task.isCancelled { return nil }
        if let image = imageIfAvailable() { return image }

        let waiter = InitialFrameMediaDataWaiter(output: output)
        guard await waiter.wait(timeout: .milliseconds(520)) else { return nil }

        // AVFoundation deliberately delivers the callback shortly before the
        // sample. A bounded tail handles that documented advance interval;
        // the normal path succeeds immediately and the old 75-wakeup polling
        // loop is gone.
        for attempt in 0..<10 {
            if Task.isCancelled { return nil }
            if let image = imageIfAvailable() { return image }
            if attempt < 9 {
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        return nil
    }

    private func teardownTransport(resetTime: Bool) {
        playbackStartToken &+= 1
        cancelScrubScheduling()
        scrubIsActive = false
        endHoverPreview(restoreTransport: false)
        primarySeekIsPending = false
        cancelPausedFrameDecode()
        removeObservers()
        primaryPlayer?.pauseTransport()
        cameraPlayer?.pauseTransport()
        primaryPlayer = nil
        cameraPlayer = nil
        preparedMedia = nil
        endpoints = nil
        pausedScreenImage = nil
        pausedCameraImage = nil
        isPlaying = false
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        duration = 0
        if resetTime {
            latestOutputTime = 0
        }
        advanceDiscontinuity()
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
    }

    func advanceDiscontinuity() {
        discontinuityID &+= 1
    }

    func resetPlaybackAnchor(
        to time: TimeInterval,
        uptime: TimeInterval = CACurrentMediaTime()
    ) {
        playbackAnchorTime = time.isFinite ? max(time, 0) : 0
        playbackAnchorUptime = uptime
    }

    private static func previewAudioMix(
        for audio: AudioStyle,
        bundle: TimelineCompositionBundle
    ) -> AVAudioMix? {
        TimelineCompositionBuilder.audioMix(
            systemTrack: bundle.systemAudioTrack,
            systemVolume: audio.isSystemMuted
                ? 0
                : Float(min(max(audio.systemVolume, 0), 1)),
            microphoneTrack: bundle.microphoneAudioTrack,
            microphoneVolume: audio.isMicrophoneMuted
                ? 0
                : Float(min(max(audio.microphoneVolume, 0), 1))
        )
    }
}
