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

private struct EditorCameraSyncAuditionRequest: Equatable {
    let id: UUID
    let outputTime: TimeInterval
    let previousPlaybackTimingRevision: UInt64
}

/// Stable AVFoundation endpoints for one prepared media generation. The render
/// surface may pull pixels from these outputs, but it never owns or reads the
/// players that drive them.
struct EditorPlaybackMediaEndpoints {
    let generation: UInt64
    let screenOutput: AVPlayerItemVideoOutput
    let cameraOutput: AVPlayerItemVideoOutput?
}

/// One immutable display-refresh sample. Scene evaluation and video-output
/// lookup consume this exact value so geometry and pixels cannot independently
/// sample the master player clock.
struct EditorPlaybackRenderTick: Equatable, Sendable {
    let mediaGeneration: UInt64
    let discontinuityID: UInt64
    let outputTime: TimeInterval
    let itemTime: CMTime
    let cameraIsAvailable: Bool
    let isPlaying: Bool
    var sourceFrame: EditorPlaybackSourceFrame? = nil
}

struct EditorPlaybackClockPolicy {
    /// A playhead can rest at the inclusive duration, but source slices are
    /// half-open and their boundary tolerance exceeds a Double's nextDown.
    static func frameLookupTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let end = max(duration - min(0.000_001, max(duration, 0) / 2), 0)
        return min(max(time.isFinite ? time : 0, 0), end)
    }

    static func clampedTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return min(max(time, 0), max(duration, 0))
    }

    static func playbackTime(playerTime: TimeInterval, rate: Double,
                             displayTime: TimeInterval? = nil, duration: TimeInterval,
                             maximumLead: TimeInterval = 1.0 / 30.0) -> TimeInterval? {
        guard rate.isFinite, rate > 0, playerTime.isFinite, playerTime >= 0 else { return nil }
        // A seek can retire the output's host-time mapping. Only a short lead
        // over the audio timebase is a valid presentation prediction.
        if let displayTime, displayTime.isFinite,
           displayTime >= playerTime, displayTime - playerTime <= maximumLead {
            return clampedTime(displayTime, duration: duration)
        }
        return clampedTime(playerTime, duration: duration)
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
    /// Fills the decode/render pipeline at the paused position so the first
    /// audio samples can be heard the moment the clock starts.
    func prerollTransport(atRate rate: Float) async -> Bool
}

extension AVPlayer: EditorPlaybackTransport {
    var item: AVPlayerItem? { currentItem }
    var currentTimeSeconds: TimeInterval { currentTime().seconds }
    var playbackRate: Float { rate }
    var playbackClockIsAdvancing: Bool { timeControlStatus == .playing }

    func playTransport() {
        // The audio-bearing master starts on AVPlayer's ready clock. An
        // external host deadline can advance past audio that is not ready yet.
        automaticallyWaitsToMinimizeStalling = true
        play()
    }
    func playTransportImmediately(atRate rate: Float) { playImmediately(atRate: rate) }
    func playTransport(at itemTime: CMTime, hostTime: CMTime, rate: Float) {
        setRate(rate, time: itemTime, atHostTime: hostTime)
    }
    func pauseTransport() {
        cancelPendingPrerolls()
        pause()
        automaticallyWaitsToMinimizeStalling = false
    }
    func cancelPendingSeeks() { currentItem?.cancelPendingSeeks() }

    func prerollTransport(atRate rate: Float) async -> Bool {
        // Explicit preroll uses a ready, paused transport. pauseTransport
        // disables automatic waiting before this request.
        guard status == .readyToPlay, currentItem?.status == .readyToPlay,
              self.rate == 0, !automaticallyWaitsToMinimizeStalling else { return false }
        return await withCheckedContinuation { continuation in
            preroll(atRate: rate) { continuation.resume(returning: $0) }
        }
    }

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
final class EditorPlaybackRestingClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    func publish(_ value: TimeInterval) {
        if abs(value - time) > 0.000_5 { time = value }
    }
}

/// Canvas-only publication of scrub/hover frame arrivals.
@MainActor
final class EditorPlaybackFrameClock: ObservableObject {
    @Published var revision: UInt64 = 0
}

@MainActor
final class EditorPlaybackController: ObservableObject {
    typealias TransportFactory = (_ item: AVPlayerItem, _ isMuted: Bool) -> any EditorPlaybackTransport
    typealias InitialFrameProvider = @MainActor (
        _ output: AVPlayerItemVideoOutput,
        _ itemTime: CMTime,
        _ preferredTransform: CGAffineTransform
    ) async -> NSImage?
    @Published private(set) var lifecycle: EditorPlaybackLifecycle = .empty {
        didSet { handleCameraSyncAuditionLifecycleChange() }
    }
    // 以下成员的写入放宽到模块内，仅供 EditorPlaybackScrubbing /
    // EditorPlaybackPausedFrames / EditorPlaybackHoverPreview 扩展使用。
    @Published var isPlaying = false {
        didSet {
            if oldValue != isPlaying { notifyNativeTimelineObservers() }
            if !isPlaying { restingClock.publish(latestOutputTime) }
        }
    }
    /// The playhead while it is at rest (paused, after a seek or scrub).
    /// Controls that depend on "where the playhead is" observe this instead
    /// of the per-frame clock, so they stay current without redrawing 60×/s.
    let restingClock = EditorPlaybackRestingClock()
    @Published private(set) var duration: TimeInterval = 0 {
        didSet {
            if oldValue != duration { notifyNativeTimelineObservers() }
        }
    }
    @Published private(set) var endpoints: EditorPlaybackMediaEndpoints?
    @Published var pausedScreenImage: NSImage?
    @Published var pausedCameraImage: NSImage?
    var pausedScreenSegmentID: UUID?
    var pausedCameraSourceID: UUID?
    /// Scrub and hover frames land tens of times per second. Only the canvas
    /// consumes them, so they publish through `frameClock` instead of this
    /// controller, which the editor root, timeline and inspector observe.
    let frameClock = EditorPlaybackFrameClock()
    private(set) var discontinuityID: UInt64 = 0 {
        didSet { frameClock.revision &+= 1 }
    }
    @Published private(set) var errorMessage: String?
    /// Acknowledges that the camera-only timing composition/player has been
    /// installed. Sync audition waits for this value, not merely for the
    /// project/media-session model to publish its new anchors.
    @Published private(set) var cameraTimingRevision: UInt64 = 0 {
        didSet { startPendingCameraSyncAuditionIfReady() }
    }
    /// Latest UI progress report from the independent playback engine. Native
    /// chrome can lag a busy UI without holding back audio or video.
    var latestOutputTime: TimeInterval = 0 {
        didSet {
            if !isPlaying, !scrubIsActive { restingClock.publish(latestOutputTime) }
            if abs(oldValue - latestOutputTime) > 0.000_001 {
                notifyNativeTimelineObservers()
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

    private var allowsTimelineViewportReveal = true

    private var nativeTimelineSnapshot: EditorPlaybackTimelineSnapshot {
        EditorPlaybackTimelineSnapshot(
            outputTime: latestOutputTime,
            duration: duration,
            isPlaying: isPlaying,
            allowsViewportReveal: allowsTimelineViewportReveal
        )
    }

    private func notifyNativeTimelineObservers() {
        nativeTimelineObservers.publish(nativeTimelineSnapshot)
    }

    // 以下传输与令牌成员的读写放宽到模块内，仅供给
    // `EditorPlaybackHoverPreview.swift` 扩展使用；其他代码不得触碰。
    private(set) var primaryPlayer: (any EditorPlaybackTransport)?
    private(set) var cameraPlayer: (any EditorPlaybackTransport)?
    private(set) var preparedMedia: EditorPreparedMedia?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var installedTimelineAudio: PreparedTimelineAudio?
    private var installedAudio = AudioStyle()
    private var installedAudioOverrides: [UUID: PrimarySegmentAudioOverrides] = [:]
    private var installedExternalClips: [AudioClip]?
    private var installedSpeech: [OverlayTiming]?
    private var installToken: UInt64 = 0
    var seekToken: UInt64 = 0
    var playbackStartToken: UInt64 = 0
    var cameraSeekToken: UInt64 = 0
    private var pendingCameraSyncAudition: EditorCameraSyncAuditionRequest?
    private var cameraSyncAuditionTask: Task<Void, Never>?
    private var activeCameraSyncAuditionID: UUID?

    var cameraSyncAuditionIsActive: Bool {
        pendingCameraSyncAudition != nil || activeCameraSyncAuditionID != nil
    }
    var cameraSeekIsPending = false
    private var lastCameraAvailability = false
    var pausedFrameTask: Task<Void, Never>?
    var pausedFrameDecodeToken: UInt64 = 0
    var scrubSeekTask: Task<Void, Never>?
    var scrubSeekCoalescer = EditorScrubSeekCoalescer()
    var scrubIsActive = false
    var scrubSeekGeneration: UInt64 = 0
    var scrubPreviewTime: TimeInterval?
    /// EDT-030 悬浮预览轴：暂停时指针扫过时间线，画布实时显示所指帧，但
    /// 逻辑时钟（`latestOutputTime`、播放头、时间码、总览）保持不动；只有
    /// 传输层被物理 seek 到所指帧。悬浮结束时传输层回到播放头，下一次播
    /// 放、精确暂停帧和导出位置都不被悬浮污染。
    /// 机器实现拆在 `EditorPlaybackHoverPreview.swift` 扩展（架构行数预算）；
    /// 存储属性只能留在主声明里，访问级别随之放宽到模块内，但仍只允许该
    /// 扩展写入。
    var hoverPreviewTime: TimeInterval? {
        didSet { if oldValue != hoverPreviewTime { frameClock.revision &+= 1 } }
    }
    var hoverSeekTask: Task<Void, Never>?
    var hoverSeekCoalescer = EditorScrubSeekCoalescer()
    var hoverSeekGeneration: UInt64 = 0
    var hoverSeekInFlightCount = 0
    var primarySeekIsPending = false // Transport and single-flight scrub lifecycle only.
    /// Every AVAssetImageGenerator backing `pausedFrameTask`. A camera project
    /// owns both a screen and camera generator; cancelling only one leaves the
    /// other decoding a retired seek in the background.
    var pausedFrameRequests: [PausedPreviewFrameRequest] = []
    private(set) var frameRate = 60
    /// Each recording's own capture rate, so an exact paused frame lands on
    /// the grid of the source under the playhead, not the primary recording's.
    private(set) var frameRatesBySource: [UUID: Int] = [:]
    private var deferredPlaybackIntent = false
    private let transportFactory: TransportFactory
    private let audioSourceCache: AudioSourceCache
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
        initialFrameProvider: InitialFrameProvider? = nil,
        audioSourceCache: AudioSourceCache = .shared
    ) {
        self.transportFactory = transportFactory
        suppliedInitialFrameProvider = initialFrameProvider
        self.audioSourceCache = audioSourceCache
    }

    /// The frame grid in force at one output time.
    func frameRate(atOutputTime time: TimeInterval) -> Int {
        guard let id = preparedMedia?.composition.frameMetadata(at: time).recordingSourceID,
              let rate = frameRatesBySource[id] else { return frameRate }
        return max(rate, 1)
    }

    var canPlay: Bool {
        guard case .ready = lifecycle else { return false }
        return primaryPlayer != nil && duration > 0
    }

    func install(
        _ prepared: EditorPreparedMedia?,
        audio: AudioStyle,
        primarySegmentAudioOverrides: [UUID: PrimarySegmentAudioOverrides],
        externalClips: [AudioClip]? = nil,
        speech: [OverlayTiming]? = nil,
        frameRate: Int,
        frameRatesBySource: [UUID: Int] = [:],
        initialTime: TimeInterval? = nil,
        cameraTimingRevision: UInt64 = 0,
        normalizesAudioLoudness: Bool = AppPreferences.isAudioLoudnessNormalizationEnabled
    ) async {
        installToken &+= 1
        let requestedInstall = installToken
        guard let prepared else {
            if primaryPlayer != nil {
                deferredPlaybackIntent = deferredPlaybackIntent || isPlaying
                pause()
                endHoverPreview(restoreTransport: false)
            } else {
                teardownTransport(resetTime: false)
            }
            lifecycle = .preparing
            return
        }
        self.frameRatesBySource = frameRatesBySource
        updateAudio(audio, primarySegmentAudioOverrides: primarySegmentAudioOverrides,
            externalClips: externalClips, speech: speech)
        let sameGeneration = endpoints?.generation == prepared.generation
            && preparedMedia?.generation == prepared.generation
        if sameGeneration, installedTimelineAudio?.normalized == normalizesAudioLoudness {
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
            guard installToken == requestedInstall else { return }
            self.cameraTimingRevision = cameraTimingRevision
            return
        }

        deferredPlaybackIntent = deferredPlaybackIntent || isPlaying
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
        } else {
            teardownTransport(resetTime: false)
        }
        lifecycle = .preparing
        let bundle = prepared.composition
        let showsEarlyFrames = primaryPlayer == nil
        if showsEarlyFrames {
            // Decode the resting picture from originals independently of audio.
            // Playback remains gated on the complete processed sound graph.
            preparedMedia = prepared
            self.frameRate = max(frameRate, 1)
            duration = prepared.outputDuration
            latestOutputTime = EditorPlaybackClockPolicy.clampedTime(initialTime ?? outputTime, duration: duration)
            refreshPausedFrames(at: latestOutputTime)
        }
        let pixelBufferAttributes: [String: any Sendable] = [
            // Keep decoded H.264 frames in the hardware-native NV12 format.
            // Core Image consumes this directly; asking AVPlayer for BGRA
            // inserted a full-frame YCbCr conversion and 2.67x memory traffic
            // before every preview composition.
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let timelineAudio: PreparedTimelineAudio
        do {
            timelineAudio = try await PreparedTimelineAudio.prepare(bundle, normalized: normalizesAudioLoudness,
                reusing: installedTimelineAudio, cache: audioSourceCache)
            try Task.checkCancellation()
            guard installToken == requestedInstall else { return }
        } catch {
            guard !Task.isCancelled, installToken == requestedInstall else { return }
            lifecycle = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            return
        }
        let item = AVPlayerItem(asset: timelineAudio.composition)
        item.videoComposition = bundle.primaryVideoComposition
        item.audioMix = timelineAudio.mix(audio: installedAudio, overrides: installedAudioOverrides,
            externalClips: installedExternalClips, speech: installedSpeech)
        item.audioTimePitchAlgorithm = .spectral
        // Native faders operate on source PCM; no taps or per-play rebuilds.
        let screenOutput = AVPlayerItemVideoOutput(
            pixelBufferAttributes: pixelBufferAttributes
        )
        item.add(screenOutput)
        let player = transportFactory(item, false)

        let reusesCamera = sameGeneration && preparedMedia?.plan.camera == prepared.plan.camera
        let cameraItem = reusesCamera ? nil : bundle.cameraComposition.map { AVPlayerItem(asset: $0) }
        let cameraOutput = reusesCamera ? endpoints?.cameraOutput : cameraItem.map { item in
            let output = AVPlayerItemVideoOutput(
                pixelBufferAttributes: pixelBufferAttributes
            )
            item.add(output)
            return output
        }
        let cameraPlayer = reusesCamera ? self.cameraPlayer : cameraItem.map { transportFactory($0, true) }
        var pendingInitialTime = showsEarlyFrames ? nil : initialTime
        var safeTime: TimeInterval = 0
        var firstScreenImage: NSImage?
        var firstCameraImage: NSImage?
        while true {
            let requestedSeek = seekToken
            let requestedOutputTime = outputTime
            let target = EditorPlaybackClockPolicy.clampedTime(
                pendingInitialTime ?? requestedOutputTime,
                duration: prepared.outputDuration
            )
            pendingInitialTime = nil
            let initialFrameTime = CMTime(seconds: target, preferredTimescale: 60_000)
            _ = await player.seekTransport(
                to: initialFrameTime, toleranceBefore: .zero, toleranceAfter: .zero
            )
            if let cameraPlayer,
               prepared.plan.camera?.contains(outputTime: target) == true {
                _ = await cameraPlayer.seekTransport(
                    to: initialFrameTime, toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
            guard !Task.isCancelled, installToken == requestedInstall else {
                player.pauseTransport()
                cameraPlayer?.pauseTransport()
                return
            }
            if seekToken != requestedSeek
                || abs(outputTime - requestedOutputTime) > 0.000_001 { continue }
            // Keep first-frame protection, but a seek/Q/W during this await
            // owns a newer logical playhead. Chase it instead of committing
            // the earlier target back over the user's next edit.
            let initialScreenTransform = bundle.frameMetadata(at: target).screenTransform
            async let decodedFirstScreen = loadInitialFrame(
                screenOutput, initialFrameTime, initialScreenTransform
            )
            let cameraImage: NSImage?
            if let cameraOutput,
               prepared.plan.camera?.contains(outputTime: target) == true {
                cameraImage = await loadInitialFrame(
                    cameraOutput, initialFrameTime, bundle.frameMetadata(at: target).cameraTransform
                )
            } else {
                cameraImage = nil
            }
            let screenImage = await decodedFirstScreen
            guard !Task.isCancelled, installToken == requestedInstall else {
                player.pauseTransport()
                cameraPlayer?.pauseTransport()
                return
            }
            if seekToken != requestedSeek
                || abs(outputTime - requestedOutputTime) > 0.000_001 { continue }
            safeTime = target
            firstScreenImage = screenImage
            firstCameraImage = cameraImage
            break
        }

        // A ripple rebuild may have no camera pixel yet. Bridge only within
        // the same editor and camera asset, never into an unrelated project.
        let canBridgeCamera = preparedMedia?.request.editorSessionID == prepared.request.editorSessionID
            && pausedCameraSourceID == bundle.frameMetadata(at: safeTime).cameraSlice?.sourceID
            && preparedMedia?.request.cameraInput(for: pausedCameraSourceID) == prepared.request.cameraInput(for: pausedCameraSourceID)
            && prepared.plan.camera?.contains(outputTime: safeTime) == true
        let cameraBridge = canBridgeCamera ? pausedCameraImage : nil
        // Swap the complete transport generation in one MainActor turn. The
        // old endpoints remain renderable until this exact point.
        removeObservers()
        seekToken &+= 1
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cancelPausedFrameDecode()
        primaryPlayer?.pauseTransport()
        self.cameraPlayer?.pauseTransport()
        primaryPlayer?.cancelPendingSeeks()
        self.cameraPlayer?.cancelPendingSeeks()
        installedTimelineAudio = timelineAudio
        primaryPlayer = player
        self.cameraPlayer = cameraPlayer
        primarySeekIsPending = false
        preparedMedia = prepared
        self.frameRate = max(frameRate, 1)
        duration = prepared.outputDuration
        latestOutputTime = safeTime
        pausedScreenSegmentID = bundle.frameMetadata(at: safeTime).screenSlice?.segmentID
        pausedCameraSourceID = bundle.frameMetadata(at: safeTime).cameraSlice?.sourceID
        pausedScreenImage = firstScreenImage
        pausedCameraImage = firstCameraImage ?? cameraBridge
        endpoints = EditorPlaybackMediaEndpoints(
            generation: prepared.generation,
            screenOutput: screenOutput,
            cameraOutput: cameraOutput
        )
        lifecycle = .ready(generation: prepared.generation)
        self.cameraTimingRevision = cameraTimingRevision
        errorMessage = nil
        lastCameraAvailability = cameraIsAvailable(at: safeTime)
        advanceDiscontinuity()
        installObservers(for: item)
        if deferredPlaybackIntent {
            deferredPlaybackIntent = false
            startPlaybackFromCurrentPosition()
        } else if firstScreenImage == nil
            || (prepared.plan.camera?.contains(outputTime: safeTime) == true
                && firstCameraImage == nil) {
            // An exact first pair is already installed in the normal path.
            // Do not immediately start two more full-composition decoders.
            refreshPausedFrames(at: safeTime)
        }
    }

    func updateAudio(_ audio: AudioStyle,
                     primarySegmentAudioOverrides: [UUID: PrimarySegmentAudioOverrides],
                     externalClips: [AudioClip]? = nil, speech: [OverlayTiming]? = nil) {
        guard installedAudio != audio || installedAudioOverrides != primarySegmentAudioOverrides
            || installedExternalClips != externalClips || installedSpeech != speech else { return }
        installedAudio = audio
        installedAudioOverrides = primarySegmentAudioOverrides
        installedExternalClips = externalClips
        installedSpeech = speech
        guard let prepared = installedTimelineAudio else { return }
        primaryPlayer?.item?.audioMix = prepared.mix(audio: audio, overrides: primarySegmentAudioOverrides,
            externalClips: externalClips, speech: speech)
    }

    /// Reviews a camera timing edit only after the rebuilt camera composition
    /// is installed. Owning this sequence beside the sole transport owner lets
    /// inspector and timeline edits share one cancellable audition instead of
    /// racing two independent playback tasks.
    func scheduleCameraSyncAudition(at requestedOutputTime: TimeInterval) {
        cancelCameraSyncAudition()
        pendingCameraSyncAudition = EditorCameraSyncAuditionRequest(
            id: UUID(),
            outputTime: EditorPlaybackClockPolicy.clampedTime(
                requestedOutputTime,
                duration: duration
            ),
            previousPlaybackTimingRevision: cameraTimingRevision
        )
        pause()
        startPendingCameraSyncAuditionIfReady()
    }

    func cancelCameraSyncAudition() {
        let wasActive = cameraSyncAuditionIsActive
        pendingCameraSyncAudition = nil
        activeCameraSyncAuditionID = nil
        cameraSyncAuditionTask?.cancel()
        cameraSyncAuditionTask = nil
        guard wasActive else { return }
        if isPlaying {
            pause()
        } else {
            // An exact seek can still be pending before playback flips to true.
            // Invalidate it as well, otherwise its resume callback can start an
            // audition after the user has already closed sync editing.
            playbackStartToken &+= 1
            seekToken &+= 1
            cameraSeekToken &+= 1
            primarySeekIsPending = false
            cameraSeekIsPending = false
            primaryPlayer?.cancelPendingSeeks()
            cameraPlayer?.cancelPendingSeeks()
        }
    }

    private func handleCameraSyncAuditionLifecycleChange() {
        switch lifecycle {
        case .ready:
            startPendingCameraSyncAuditionIfReady()
        case .failed, .empty:
            cancelCameraSyncAudition()
        case .preparing:
            break
        }
    }

    private func startPendingCameraSyncAuditionIfReady() {
        guard let request = pendingCameraSyncAudition,
              case .ready = lifecycle,
              cameraTimingRevision != request.previousPlaybackTimingRevision else { return }
        pendingCameraSyncAudition = nil
        activeCameraSyncAuditionID = request.id

        let startTime = max(request.outputTime - 0.35, 0)
        let endTime = min(request.outputTime + 1.25, duration)
        seek(to: startTime, pausing: true, resumeAfterCompletion: true)

        cameraSyncAuditionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Use the media clock: exact seek and decoder startup must not
            // consume the short review window.
            for _ in 0..<100 {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
                guard self.activeCameraSyncAuditionID == request.id else { return }
                if self.outputTime >= endTime - 0.015 {
                    self.finishCameraSyncAudition(request)
                    return
                }
            }
            guard self.activeCameraSyncAuditionID == request.id else { return }
            self.finishCameraSyncAudition(request)
        }
    }

    private func finishCameraSyncAudition(
        _ request: EditorCameraSyncAuditionRequest
    ) {
        guard activeCameraSyncAuditionID == request.id else { return }
        pause()
        seek(to: request.outputTime, pausing: true)
        activeCameraSyncAuditionID = nil
        cameraSyncAuditionTask = nil
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
                bundle.frameMetadata(at: target).cameraTransform
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
        let nextCameraSourceID = bundle.frameMetadata(at: target).cameraSlice?.sourceID
        let cameraBridge = pausedCameraSourceID == nextCameraSourceID ? pausedCameraImage : nil
        pausedCameraSourceID = nextCameraSourceID
        pausedCameraImage = firstCameraImage ?? cameraBridge
        self.endpoints = EditorPlaybackMediaEndpoints(
            generation: endpoints.generation,
            screenOutput: endpoints.screenOutput,
            cameraOutput: cameraOutput
        )
        lastCameraAvailability = self.cameraIsAvailable(at: target)
        advanceDiscontinuity()

        guard let replacementPlayer, lastCameraAvailability else { return }
        if isPlaying, let primaryPlayer, primaryPlayer.playbackClockIsAdvancing {
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
        guard isPreviewActive else { return }
        guard canPlay else { return }
        if outputTime >= duration - 0.000_1 {
            seek(to: 0, pausing: true, resumeAfterCompletion: true)
            return
        }
        startPlaybackFromCurrentPosition()
    }

    private func startPlaybackFromCurrentPosition() {
        guard isPreviewActive, canPlay, let primaryPlayer else { return }
        let target = EditorPlaybackClockPolicy.clampedTime(outputTime, duration: duration)
        // Every play request takes ownership from both published and in-flight
        // hover seeks. The logical playhead is the only start position.
        endHoverPreview(restoreTransport: false)
        cancelScrubScheduling()
        scrubIsActive = false
        cancelPausedFrameDecode()
        playbackStartToken &+= 1
        seekToken &+= 1
        cameraSeekToken &+= 1
        let requestedStart = playbackStartToken
        let requestedSeek = seekToken
        let requestedCameraSeek = cameraSeekToken
        let requestedGeneration = endpoints?.generation
        let camera = cameraIsAvailable(at: target) ? cameraPlayer : nil
        primaryPlayer.pauseTransport()
        cameraPlayer?.pauseTransport()
        primaryPlayer.cancelPendingSeeks()
        cameraPlayer?.cancelPendingSeeks()
        primarySeekIsPending = true
        cameraSeekIsPending = camera != nil
        isPlaying = true
        let itemTime = CMTime(seconds: target, preferredTimescale: 60_000)
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.playbackStartToken == requestedStart && self.seekToken == requestedSeek
                && self.cameraSeekToken == requestedCameraSeek
                && self.endpoints?.generation == requestedGeneration && self.isPlaying
        }

        Task { [weak self] in
            guard isCurrent() else { return }
            // Prime the audio-bearing master at the exact cut as well as the
            // camera. Previously only the camera was guaranteed to seek here.
            let primarySeek = Task { @MainActor in
                guard isCurrent() else { return false }
                return await primaryPlayer.seekTransport(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            let cameraSeek = Task { @MainActor in
                guard isCurrent() else { return false }
                return await camera?.seekTransport(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero) ?? true
            }
            let sought = await (primarySeek.value, cameraSeek.value)
            guard let self,
                  self.playbackStartToken == requestedStart,
                  self.seekToken == requestedSeek,
                  self.cameraSeekToken == requestedCameraSeek,
                  self.endpoints?.generation == requestedGeneration,
                  self.isPlaying else { return }
            guard sought.0, sought.1 else {
                self.pause()
                return
            }
            if let camera {
                let cameraPrimed = await camera.prerollTransport(atRate: 1)
                guard self.playbackStartToken == requestedStart,
                      self.seekToken == requestedSeek,
                      self.cameraSeekToken == requestedCameraSeek,
                      self.endpoints?.generation == requestedGeneration,
                      self.isPlaying else { return }
                guard cameraPrimed else {
                    self.pause()
                    return
                }
            }
            self.primarySeekIsPending = false
            self.cameraSeekIsPending = false
            self.pausedScreenImage = nil
            self.pausedCameraImage = nil
            self.latestOutputTime = target
            primaryPlayer.playTransport()
            self.synchronizeCamera(to: target)
        }
    }

    private(set) var isPreviewActive = true

    /// This controller owns editing playback only. Export uses its own media
    /// readers and must not be paused by window visibility or App Nap policy.
    func setPreviewActive(_ active: Bool) {
        guard active != isPreviewActive else { return }
        isPreviewActive = active
        if active {
            refreshPausedFrames(at: outputTime)
        } else {
            deferredPlaybackIntent = false
            endHoverPreview()
            pause()
            playbackStartToken &+= 1
            cameraSeekToken &+= 1
            seekToken &+= 1
            primarySeekIsPending = false
            cameraSeekIsPending = false
            primaryPlayer?.pauseTransport()
            cameraPlayer?.pauseTransport()
            primaryPlayer?.cancelPendingSeeks()
            cameraPlayer?.cancelPendingSeeks()
            cancelPausedFrameDecode()
        }
    }

    func pause(revealingPlayhead: Bool = true) {
        guard isPlaying else { return }
        // Editing a visible timeline object must not scroll away from the
        // pointer merely because editing also stops playback. Carry this
        // intent in the synchronous pause notification, then restore it for
        // the next explicit transport action.
        let previousReveal = allowsTimelineViewportReveal
        allowsTimelineViewportReveal = revealingPlayhead
        defer { allowsTimelineViewportReveal = previousReveal }
        playbackStartToken &+= 1
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        guard let primaryPlayer else {
            isPlaying = false
            return
        }
        let sampled = EditorPlaybackClockPolicy.clampedTime(
            primarySeekIsPending || !primaryPlayer.playbackClockIsAdvancing
                ? outputTime : primaryPlayer.currentTimeSeconds,
            duration: duration
        )
        seekToken &+= 1
        primaryPlayer.cancelPendingSeeks()
        primaryPlayer.pauseTransport()
        cameraPlayer?.pauseTransport()
        primarySeekIsPending = false
        latestOutputTime = sampled
        isPlaying = false
        // Pausing at the transport's current sample is not a timeline
        // discontinuity. Advancing the epoch here invalidated the last valid
        // camera pixel before the exact paused-frame decoder finished, so the
        // camera disappeared for one render whenever Space paused playback.
        // Keep the live frame as the bridge; the exact paused pair replaces it
        // atomically as soon as decoding completes.
        refreshPausedFrames(at: sampled)
    }

    func seek(
        to requestedTime: TimeInterval,
        pausing: Bool = true,
        resumeAfterCompletion: Bool = false,
        loadsPausedFrame: Bool = true
    ) {
        guard let primaryPlayer else {
            seekToken &+= 1
            latestOutputTime = preparedMedia == nil ? requestedTime
                : EditorPlaybackClockPolicy.clampedTime(requestedTime, duration: duration)
            advanceDiscontinuity()
            if loadsPausedFrame { refreshPausedFrames(at: latestOutputTime) }
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


    /// The renderer reads AVFoundation's timebase directly. This snapshot is
    /// replaced on transport/seek changes, never on timeline viewport changes.
    var previewPlaybackSource: PreviewPlaybackSource? {
        guard isPlaying, !primarySeekIsPending, let preparedMedia, let endpoints,
              let player = primaryPlayer as? AVPlayer, let clock = player.currentItem?.timebase else { return nil }
        return PreviewPlaybackSource(clock: clock, cameraPlayer: cameraPlayer as? AVPlayer,
            generation: endpoints.generation, discontinuityID: discontinuityID,
            metadata: preparedMedia.composition.previewMetadata,
            cameraFrameRates: preparedMedia.payload.inventoriesBySource.mapValues { $0.camera.videoFrameRate ?? 30 })
    }

    func acceptPreviewProgress(_ tick: EditorPlaybackRenderTick) {
        guard isPlaying, !primarySeekIsPending, tick.mediaGeneration == endpoints?.generation,
              tick.discontinuityID == discontinuityID else { return }
        latestOutputTime = tick.outputTime
        lastCameraAvailability = tick.cameraIsAvailable
    }

    var stationaryRenderTick: EditorPlaybackRenderTick? {
        guard let generation = endpoints?.generation ?? preparedMedia?.generation else { return nil }
        let time = EditorPlaybackClockPolicy.clampedTime(scrubIsActive ? (scrubPreviewTime ?? outputTime) : outputTime, duration: duration)
        return EditorPlaybackRenderTick(
            mediaGeneration: generation,
            discontinuityID: discontinuityID,
            outputTime: time,
            itemTime: CMTime(seconds: time, preferredTimescale: 60_000),
            cameraIsAvailable: cameraIsAvailable(at: time) || (endpoints == nil && pausedCameraImage != nil),
            isPlaying: false,
            sourceFrame: preparedMedia?.composition.frameMetadata(at: time)
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
        // Control changes may start a primed camera once. Continuous drift and
        // gap handling belong to the render engine, with no UI seek loop.
        if isPlaying {
            if primaryPlayer.playbackClockIsAdvancing {
                cameraPlayer.playTransport(at: CMTime(seconds: primaryPlayer.currentTimeSeconds, preferredTimescale: 60_000),
                    hostTime: CMClockGetTime(CMClockGetHostTimeClock()), rate: primaryPlayer.playbackRate)
            }
            return
        }
        let available = preparedMedia.plan.camera?.contains(outputTime: time) == true
        let cameraFrameRate = preparedMedia.plan.camera?.slice(atOutputTime: time).flatMap {
            preparedMedia.payload.inventoriesBySource[$0.sourceID]?.camera.videoFrameRate
        } ?? 30
        let action = EditorCameraSyncPolicy.action(
            outputTime: time,
            isAvailable: available,
            cameraTime: cameraPlayer.currentTimeSeconds,
            masterRate: 0,
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
                cameraPlayer.playTransport(
                    at: CMTime(seconds: time, preferredTimescale: 60_000),
                    hostTime: CMClockGetTime(CMClockGetHostTimeClock()),
                    rate: rate
                )
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
                if self.isPlaying {
                    self.synchronizeCamera(to: target)
                } else {
                    self.cameraPlayer?.pauseTransport()
                    // Publish the landed auxiliary frame, including hover seeks.
                    self.advanceDiscontinuity()
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
            && preparedMedia?.plan.camera?.contains(outputTime:
                EditorPlaybackClockPolicy.frameLookupTime(time, duration: duration)) == true
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
        installedTimelineAudio = nil
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



}
