import AppKit
import AVFoundation
import CoreImage
import Metal
import os
import QuartzCore
import RecorderCore

/// All mutable frame/resource state below belongs to renderQueue. UI updates
/// arrive as immutable snapshots; frame scheduling never waits for MainActor.
final class SharedPreviewEngine: NSObject, @unchecked Sendable {
    let mailbox = PreviewEngineMailbox()
    private var activeRevision: UInt64 = 0
    private var activeEpoch: UInt64 = 0
    private var assetRootURL: URL?
    private var layer: CAMetalLayer?
    var bounds = CGRect.zero
    var backingScale: CGFloat = 2
    private var liveMotionDrag: MotionElementEditor.LiveDrag?
    private var currentDrawable: (any CAMetalDrawable)?
    var onDrawablePresented: (@Sendable (CFTimeInterval, TimeInterval) -> Void)?
    var onProgress: (@Sendable (EditorPlaybackRenderTick) -> Void)?
    var onFrameReady: (@Sendable (PreviewFrameReadiness) -> Void)?
    var onRetired: (@Sendable (PreviewLayerRetirementRequest) -> Void)?
    private var isPointerPreview = false
    private var pausedRetryAttempt = 0
    private var cameraSeekPending = false
    private var cameraSeekSerial: UInt64 = 0
    private var pendingRetirement: PreviewLayerRetirementRequest?
    private lazy var displayDriver = PreviewDisplayDriver { [weak self] frame in
        guard let self else { return }
        guard let frame else {
            self.renderQueue.async { [weak self] in self?.drawableUnavailable() }
            return
        }
        if self.mailbox.request(frame) { self.enqueueDrain() }
    }

    func configure(_ input: PreviewEngineInput) {
        if mailbox.configure(input) { enqueueDrain() }
    }
    private func enqueueDrain() {
        renderQueue.async { [weak self] in self?.drain() }
    }
    private func drain() {
        let work = mailbox.take()
        if let configuration = work.configuration {
            let input = configuration.input
            activeRevision = configuration.revision; activeEpoch = configuration.epoch
            isPointerPreview = input.isPointerPreview
            pausedRetryAttempt = 0
            layer = input.layer; bounds = input.bounds; backingScale = input.backingScale
            assetRootURL = input.assetRootURL
            presentationIsSuspended = input.suspended
            if playbackSource?.clock !== input.source?.clock
                || playbackSource?.cameraPlayer !== input.source?.cameraPlayer
                || playbackSource?.discontinuityID != input.source?.discontinuityID {
                cameraSeekSerial &+= 1; cameraSeekPending = false
            }
            playbackSource = input.source; playbackFrameProvider = input.provider
            liveMotionDrag = input.liveDrag
            motionStarts = input.motionStarts.sorted { $0.time < $1.time }
            lastMotionWarmTime = -.infinity
            if pendingRetirement?.generation != previewRetirementGeneration { pendingRetirement = nil }
            displayDriver.configure(layer: layer, active: !input.suspended && input.source != nil && !input.paused)
            update(screenOutput: input.screenOutput, cameraOutput: input.cameraOutput,
                renderTick: input.tick, usesPausedFrame: input.paused,
                renderPlan: input.plan, semanticScene: input.scene, effectPrewarmPlans: input.prewarm,
                pausedScreenImage: input.pausedScreen, pausedCameraImage: input.pausedCamera,
                wallpaperImage: input.wallpaper, wallpaperVideoURL: input.wallpaperVideo,
                sceneWallpapers: input.sceneWallpapers, defaultWallpaperKey: input.defaultWallpaperKey,
                stickerImages: input.stickers, suppressCameraContent: input.suppressCamera,
                suppressScreenContent: input.suppressScreen)
            if !input.suspended { prewarmMotions(at: input.source?.tick(target: CACurrentMediaTime())?.outputTime ?? input.scene.time) }
        }
        if let request = pendingRetirement, request.generation == previewRetirementGeneration,
           let frame = work.frame, frame.drawable.layer === request.layer,
           frame.drawable.texture.width == 2, frame.drawable.texture.height == 2 {
            pendingRetirement = nil
            presentTinyRetirementDrawable(request, drawable: frame.drawable)
            return
        }
        guard !presentationIsSuspended else { return }
        if work.frame != nil, let source = playbackSource, CMTimebaseGetEffectiveRate(source.clock) <= 0 {
            source.cameraPlayer?.pause()
            wallpaperVideoPlayback.synchronize(to: nil)
        }
        if let frame = work.frame, frame.drawable.layer === layer,
           let source = playbackSource, let provider = playbackFrameProvider,
           activeEpoch == presentationEpochID,
           let tick = source.tick(target: frame.presentationTime) {
            synchronizeCamera(source, tick: tick)
            prewarmMotions(at: tick.outputTime)
            let began = CACurrentMediaTime()
            let evaluated = provider(tick)
            applyFrameContract(renderTick: tick, usesPausedFrame: false,
                renderPlan: evaluated.renderPlan, semanticScene: evaluated.semanticScene, effectPrewarmPlans: [])
            currentDiagnosticFrame = frameDiagnostics?.beginFrame(epoch: activeEpoch, outputTime: tick.outputTime,
                target: frame.presentationTime, evaluationMS: (CACurrentMediaTime() - began) * 1_000)
            currentDrawable = frame.drawable
            renderCurrentFrame()
            currentDrawable = nil
            // Chrome reports the audio clock now, not the future time of a
            // buffered drawable, so Play does not jump the visible playhead.
            if let progress = source.tick(target: CACurrentMediaTime()) { onProgress?(progress) }
        } else if playbackSource == nil {
            if work.redraw { lastSubmittedSignature = nil }
            if let frame = work.frame, frame.drawable.layer === layer {
                currentDrawable = frame.drawable
            }
            renderCurrentFrame()
            currentDrawable = nil
        }
    }
    func redraw() {
        if mailbox.request() { enqueueDrain() }
    }
    func suspend() {
        let epoch = mailbox.interrupt()
        renderQueue.async { [weak self] in
            guard let self, self.presentationEpochID == epoch else { return }
            self.presentationIsSuspended = true
            self.displayDriver.configure(layer: self.layer, active: false)
            self.lastSubmittedSignature = nil
        }
    }
    func invalidate() {
        mailbox.interrupt()
        renderQueue.async { [self] in
            presentationIsSuspended = true
            displayDriver.invalidate()
            pendingRetirement = nil
            clearResources()
            playbackSource = nil; playbackFrameProvider = nil; layer = nil
        }
    }
    func retire(_ request: PreviewLayerRetirementRequest) {
        renderQueue.async { [weak self] in
            guard let self, request.generation == self.previewRetirementGeneration else { return }
            guard let previewLayer = request.layer, previewLayer.device != nil else {
                self.finishTinyRetirementDrawable(request)
                return
            }
            self.pendingRetirement = request
            previewLayer.drawableSize = CGSize(width: 2, height: 2)
            self.displayDriver.configure(layer: previewLayer, active: false)
            self.displayDriver.requestFrame()
        }
    }
    private func drawableUnavailable() {
        if let request = pendingRetirement {
            pendingRetirement = nil
            finishTinyRetirementDrawable(request)
        } else {
            retryStationaryFrame(revision: activeRevision, epoch: activeEpoch)
        }
    }
    private func didCompleteRender(job: PreviewRenderJob, presented: Bool) {
        guard job.presentationEpochID == presentationEpochID else { return }
        guard presented else {
            renderQueue.async { [weak self] in self?.retryStationaryFrame(revision: job.generation, epoch: job.presentationEpochID) }
            return
        }
        let event = PreviewFrameReadiness(epoch: job.presentationEpochID, revision: job.generation,
            includesCamera: job.includesCamera, includesScreen: job.includesScreen)
        if mailbox.claimReadiness(event) { onFrameReady?(event) }
    }
    private func retryStationaryFrame(revision: UInt64, epoch: UInt64) {
        guard revision == activeRevision, epoch == presentationEpochID else { return }
        lastSubmittedSignature = nil
        guard playbackSource == nil, !presentationIsSuspended, pausedRetryAttempt < 5 else { return }
        pausedRetryAttempt += 1
        let delay = 0.016 * Double(pausedRetryAttempt)
        renderQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.activeRevision == revision, self.presentationEpochID == epoch else { return }
            self.renderCurrentFrame()
        }
    }
    private func assetURL(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return assetRootURL?.appendingPathComponent(path) ?? URL(fileURLWithPath: path)
    }
    private func applyingLiveDrag(_ edits: [String: MotionElementEdit], for target: MotionElementTarget) -> [String: MotionElementEdit] {
        guard let drag = liveMotionDrag, drag.target == target else { return edits }
        var result = edits
        for id in drag.ids {
            var edit = result[id] ?? MotionElementEdit()
            edit.dx = (edit.dx + Double(drag.offset.width)).rounded()
            edit.dy = (edit.dy + Double(drag.offset.height)).rounded()
            result[id] = edit
        }
        return result
    }
    private func synchronizeCamera(_ source: PreviewPlaybackSource, tick: EditorPlaybackRenderTick) {
        guard tick.cameraIsAvailable, let player = source.cameraPlayer else { return }
        let clockTime = CMTimebaseGetTime(source.clock)
        let action = EditorCameraSyncPolicy.action(outputTime: clockTime.seconds, isAvailable: true,
            cameraTime: player.currentTime().seconds,
            masterRate: Float(CMTimebaseGetEffectiveRate(source.clock)),
            cameraRate: player.rate, cameraFrameRate: tick.sourceFrame?.cameraSlice.flatMap { source.cameraFrameRates[$0.sourceID] } ?? 30,
            hasPendingSeek: cameraSeekPending, force: false)
        switch action {
        case let .matchRate(rate):
            player.setRate(rate, time: clockTime, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        case let .seek(time, tolerance):
            cameraSeekPending = true; cameraSeekSerial &+= 1
            let serial = cameraSeekSerial, epoch = activeEpoch
            let amount = CMTime(seconds: tolerance, preferredTimescale: 60_000)
            player.seek(to: CMTime(seconds: time, preferredTimescale: 60_000), toleranceBefore: amount, toleranceAfter: amount) { [weak self] finished in
                self?.renderQueue.async { [weak self] in
                    guard let self, self.cameraSeekSerial == serial else { return }
                    self.cameraSeekPending = false
                    guard finished, self.activeEpoch == epoch, self.presentationEpochID == epoch,
                          CMTimebaseGetEffectiveRate(source.clock) > 0 else { return }
                    player.setRate(Float(CMTimebaseGetEffectiveRate(source.clock)), time: CMTimebaseGetTime(source.clock),
                        atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
                }
            }
        case .none, .waitForPendingSeek, .pauseAndHide: break
        }
    }

    private var playbackSource: PreviewPlaybackSource?
    var playbackFrameProvider: SharedPreviewPlaybackFrameProvider?
    // 以下成员放宽到模块内访问，仅供 SharedPreviewLayerRetirement /
    // SharedPreviewRenderPipeline 扩展使用。
    private var presentationIsSuspended = true
    private var screenOutput: AVPlayerItemVideoOutput?
    private var cameraOutput: AVPlayerItemVideoOutput?
    var renderTick: EditorPlaybackRenderTick?
    private var usesPausedFrame = false
    private var renderPlan: FrameRenderPlan?
    var semanticScene: FrameScene?
    private var effectPrewarmPlans: [FrameRenderPlan] = []
    private var suppressCameraContent = false
    private var suppressScreenContent = false
    private var screenFrame: CIImage?
    private var screenFrameSegmentID: UUID?
    private var screenFrameGeneration: UInt64?
    private var pausedScreenFrameSegmentID: UUID?
    private var cameraFrameSourceID: UUID?
    private var pausedCameraFrameSourceID: UUID?
    private var cameraFrame: CIImage?
    private let cameraBeautyTracker = CameraBeautyTracker()
    private var cameraFrameMediaGeneration: UInt64?
    private var cameraFrameDiscontinuityID: UInt64?
    private var pausedScreenImage: CIImage?
    private var pausedScreenFrame: CIImage?
    private var pausedCameraImage: CIImage?
    private var pausedCameraFrame: CIImage?
    private func selectSceneWallpaper(_ source: BackgroundSource) {
        let resource = source.sceneResourceKey.flatMap { sceneWallpapers[$0] }
        let isDefault = source.sceneResourceKey == defaultWallpaperKey && source.usesWallpaperMedia
        let image = resource?.image ?? (isDefault ? defaultWallpaperImage : nil)
        let videoURL = resource?.videoURL ?? (isDefault ? defaultWallpaperVideoURL : nil)
        guard wallpaperImage !== image || wallpaperVideoURL != videoURL else { return }
        wallpaperImage = image
        wallpaperVideoURL = videoURL
        wallpaperFrame = image
        wallpaperVideoHasLiveFrame = false
        wallpaperVideoPlayback.synchronize(to: nil)
        if let videoURL, let player = sceneWallpaperPlayers[videoURL] {
            wallpaperVideoPlayback = player
        } else {
            wallpaperVideoPlayback = PreviewWallpaperVideoPlayback(enqueue: { [weak self] action in self?.renderQueue.async(execute: action) })
        }
        wallpaperRevision &+= 1
        preparedBackgroundCache.reset()
        contentRevision &+= 1
    }

    private var wallpaperImage: CIImage?
    private var wallpaperFrame: CIImage?
    private var wallpaperVideoURL: URL?
    private var wallpaperVideoHasLiveFrame = false
    private lazy var wallpaperVideoPlayback = PreviewWallpaperVideoPlayback(enqueue: { [weak self] action in self?.renderQueue.async(execute: action) })
    private var sceneWallpapers: [String: PreviewSceneWallpaper] = [:]
    private var sceneWallpaperPlayers: [URL: PreviewWallpaperVideoPlayback] = [:]
    private var defaultWallpaperKey: String?
    private var defaultWallpaperImage: CIImage?
    private var defaultWallpaperVideoURL: URL?
    private var stickerImages: [String: CIImage] = [:]
    private var stickerFrames: [String: CIImage] = [:]
    var animationBuffers: [UUID: PreviewMotionFrames] = [:]
    var insertedMotionBuffers: [UUID: PreviewMotionFrames] = [:]
    var warmedAnimationIDs = Set<UUID>()
    var warmedMainIDs = Set<UUID>()
    var motionStarts: [PreviewMotionStart] = []
    var lastMotionWarmTime = -Double.infinity
    /// EDT-054: latest overlay-video frame per clip and the source time it shows.
    private var videoFrames: [UUID: (path: String, time: TimeInterval, image: CIImage?)] = [:]
    private var videoRequests: [UUID: (path: String, token: UUID)] = [:]
    private var wallpaperRevision: UInt64 = 0
    private var preparedBackgroundCache = PreviewPreparedBackgroundCache()
    private var cursorAssetID: CursorAssetID?
    private var cursorFrame: CIImage?
    private var contentRevision: UInt64 = 0
    var lastSubmittedSignature: PreviewVisualSignature?
    private var lastSubmittedPrewarmPlans: [FrameRenderPlan] = []
    private let frameDiagnostics = PreviewFrameDiagnostics.configured()
    private var currentDiagnosticFrame: PreviewFrameDiagnostics.Frame?

    private var colorContract: FrameColorContract?
    private var colorProfile: CoreImageFrameColorProfile?

    /// Decode pulls, resources, scene evaluation and GPU submission have one
    /// serial owner, without a MainActor acknowledgment between frames.
    /// Drain temporary Core Image/Metal Objective-C objects after each job,
    /// rather than inheriting a worker pool with no per-job drain. Submitted
    /// GPU commands retain their own resources until completion.
    let renderQueue = DispatchQueue(
        label: "cn.laogou.dogsc.preview-render",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    var renderGeneration: UInt64 { mailbox.configurationRevision }
    var presentationEpochID: UInt64 { mailbox.epoch }
    var previewRetirementGeneration: UInt64 { mailbox.retirementGeneration }
    /// 仅 renderQueue 访问的上下文缓存。
    var queueContext: CIContext?
    var queueColorContract: FrameColorContract?
    var queueCommandQueue: MTLCommandQueue?
    var queuePreparedEffectSignatures = Set<
        PreviewEffectPrewarmSignature
    >()

    private func clearResources() {
        animationBuffers.values.forEach { $0.reset() }
        animationBuffers.removeAll()
        insertedMotionBuffers.values.forEach { $0.reset() }; insertedMotionBuffers.removeAll()
        wallpaperVideoPlayback.invalidate()
        sceneWallpaperPlayers.values.forEach { $0.invalidate() }
        sceneWallpaperPlayers.removeAll()
        screenFrame = nil; cameraFrame = nil
        pausedScreenFrame = nil; pausedCameraFrame = nil
        wallpaperFrame = nil; stickerFrames.removeAll()
        videoFrames.removeAll(); videoRequests.removeAll()
        preparedBackgroundCache.reset()
        queueContext?.clearCaches()
        queueContext = nil; queueCommandQueue = nil; queueColorContract = nil
        queuePreparedEffectSignatures.removeAll()
    }

    func update(
        screenOutput: AVPlayerItemVideoOutput?,
        cameraOutput: AVPlayerItemVideoOutput?,
        renderTick: EditorPlaybackRenderTick?,
        usesPausedFrame: Bool,
        renderPlan: FrameRenderPlan,
        semanticScene: FrameScene,
        effectPrewarmPlans: [FrameRenderPlan],
        pausedScreenImage: CIImage?,
        pausedCameraImage: CIImage?,
        wallpaperImage: CIImage?,
        wallpaperVideoURL: URL?,
        sceneWallpapers: [String: PreviewSceneWallpaper],
        defaultWallpaperKey: String?,
        stickerImages: [String: CIImage],
        suppressCameraContent: Bool,
        suppressScreenContent: Bool
    ) {
        if self.screenOutput !== screenOutput {
            self.screenOutput = screenOutput
            // A ripple edit replaces the AVPlayerItemVideoOutput before the
            // replacement decoder necessarily owns a pixel buffer. Keep the
            // last immutable CIImage visible until the new output (or the
            // exact paused-frame decoder) publishes its first frame. Clearing
            // it here exposed CAMetalLayer's black fallback on every cut.
            contentRevision &+= 1
        }
        if self.cameraOutput !== cameraOutput {
            self.cameraOutput = cameraOutput
            // The camera transport is rebuilt independently from the screen
            // transport. Retaining its last decoded frame avoids a one-frame
            // camera disappearance while both replacement players seek.
            contentRevision &+= 1
        }
        if self.pausedScreenImage !== pausedScreenImage {
            self.pausedScreenImage = pausedScreenImage
            pausedScreenFrame = pausedScreenImage
            pausedScreenFrameSegmentID = renderTick?.sourceFrame?.screenSlice?.segmentID
            contentRevision &+= 1
        }
        if self.pausedCameraImage !== pausedCameraImage {
            self.pausedCameraImage = pausedCameraImage
            pausedCameraFrame = pausedCameraImage
            pausedCameraFrameSourceID = renderTick?.sourceFrame?.cameraSlice?.sourceID
            contentRevision &+= 1
        }
        self.defaultWallpaperKey = defaultWallpaperKey
        defaultWallpaperImage = wallpaperImage
        defaultWallpaperVideoURL = wallpaperVideoURL
        self.sceneWallpapers = sceneWallpapers
        let urls = Set(sceneWallpapers.values.compactMap(\.videoURL) + [wallpaperVideoURL].compactMap { $0 })
        for url in Array(sceneWallpaperPlayers.keys) where !urls.contains(url) {
            sceneWallpaperPlayers.removeValue(forKey: url)?.invalidate()
        }
        for url in urls where sceneWallpaperPlayers[url] == nil {
            let player = PreviewWallpaperVideoPlayback(enqueue: { [weak self] action in self?.renderQueue.async(execute: action) })
            player.configure(url: url)
            player.onFrameAvailable = { [weak self] in self?.renderCurrentFrame() }
            sceneWallpaperPlayers[url] = player
        }
        let stickerImagesChanged = self.stickerImages.count != stickerImages.count
            || stickerImages.contains { key, image in
                self.stickerImages[key] !== image
            }
        if stickerImagesChanged {
            self.stickerImages = stickerImages
            stickerFrames = stickerImages.compactMapValues {
                $0
            }
            contentRevision &+= 1
        }
        if self.suppressCameraContent != suppressCameraContent
            || self.suppressScreenContent != suppressScreenContent {
            contentRevision &+= 1
        }

        self.suppressCameraContent = suppressCameraContent
        self.suppressScreenContent = suppressScreenContent
        applyFrameContract(
            renderTick: renderTick,
            usesPausedFrame: usesPausedFrame,
            renderPlan: renderPlan,
            semanticScene: semanticScene,
            effectPrewarmPlans: effectPrewarmPlans
        )
        if playbackSource == nil { renderCurrentFrame() }
    }

    private func applyFrameContract(
        renderTick: EditorPlaybackRenderTick?,
        usesPausedFrame: Bool,
        renderPlan: FrameRenderPlan,
        semanticScene: FrameScene,
        effectPrewarmPlans: [FrameRenderPlan]
    ) {
        if self.renderTick?.mediaGeneration != renderTick?.mediaGeneration {
            // The controller swaps a fully prepared transport generation in
            // one turn, but AVPlayerItemVideoOutput can still need a display
            // refresh before `copyPixelBuffer` succeeds. Preserve the last
            // submitted resources across that hand-off; the first decoded
            // replacement frame atomically supersedes them below.
            contentRevision &+= 1
        } else if self.renderTick?.discontinuityID != renderTick?.discontinuityID {
            // PRE-003/PRE-005: a transport discontinuity changes time, not the
            // media resource. Keep the last valid frame visible until the
            // async exact paused frame or the first resumed video-output frame
            // arrives. Clearing it here created a deterministic black flash on
            // every play/pause transition.
            contentRevision &+= 1
        }
        if colorContract != semanticScene.color {
            colorContract = semanticScene.color
            colorProfile = try? CoreImageFrameColorProfile(contract: semanticScene.color)
            contentRevision &+= 1
        }
        self.renderTick = renderTick
        selectSceneWallpaper(semanticScene.background.source)
        wallpaperVideoPlayback.synchronize(to: renderTick, audioClock: playbackSource?.clock)
        self.usesPausedFrame = usesPausedFrame
        if usesPausedFrame { currentDiagnosticFrame = nil }
        self.renderPlan = renderPlan
        self.semanticScene = semanticScene
        self.effectPrewarmPlans = effectPrewarmPlans.map(
            SharedPreviewFramePipeline.rasterPlan
        )
    }

    func renderCurrentFrame() {
        guard !presentationIsSuspended else { return }
        if playbackSource != nil && currentDrawable == nil { return }
        guard let renderPlan, let semanticScene, let colorProfile else { return }
        // Cursor, camera and subtitles share the same GPU frame and clock.
        // Playback has no per-frame AppKit/Core Animation layer transaction.
        if let assetID = renderPlan.scene.cursor?.assetID,
           cursorAssetID != assetID || cursorFrame == nil {
            cursorAssetID = assetID
            cursorFrame = CursorAssetLibrary.resolvedAsset(for: assetID)?.renderSource()?.image
            contentRevision &+= 1
        }

        if let renderTick, let screenOutput,
           let decoded = decodedFrame(
               output: screenOutput,
               itemTime: renderTick.itemTime,
               preferredTransform: renderTick.sourceFrame?.screenTransform ?? .identity,
               allowCachedFrame: screenFrame != nil && screenFrameSegmentID == renderTick.sourceFrame?.screenSlice?.segmentID,
               validSlice: renderTick.sourceFrame?.screenSlice
           ) {
            screenFrame = decoded
            screenFrameSegmentID = renderTick.sourceFrame?.screenSlice?.segmentID
            screenFrameGeneration = renderTick.mediaGeneration
            contentRevision &+= 1
        }
        if renderTick?.cameraIsAvailable == true, renderTick?.sourceFrame?.usesPrimaryFrameForCamera != true,
           let renderTick,
           let cameraOutput,
           let decoded = decodedFrame(
               output: cameraOutput,
               itemTime: renderTick.itemTime,
               preferredTransform: renderTick.sourceFrame?.cameraTransform ?? .identity,
               allowCachedFrame: cameraFrame != nil && cameraFrameSourceID == renderTick.sourceFrame?.cameraSlice?.sourceID,
               validSlice: renderTick.sourceFrame?.cameraSlice
           ) {
            cameraFrame = decoded
            cameraFrameSourceID = renderTick.sourceFrame?.cameraSlice?.sourceID
            cameraFrameMediaGeneration = renderTick.mediaGeneration
            cameraFrameDiscontinuityID = renderTick.discontinuityID
            contentRevision &+= 1
        }
        if let renderTick,
           let videoWallpaperFrame = wallpaperVideoPlayback.copyFrame(
               at: renderTick.outputTime
           ) {
            wallpaperFrame = videoWallpaperFrame
            wallpaperVideoHasLiveFrame = true
            wallpaperRevision &+= 1
            preparedBackgroundCache.reset()
            contentRevision &+= 1
        }
        // Preserve an exact paused decode as the live-output fallback. The
        // controller intentionally releases its CIImage when playback starts;
        // retaining the CIImage here bridges that release to the decoder's
        // first resumed pixel without presenting an empty drawable.
        if usesPausedFrame, let pausedScreenFrame,
           pausedScreenFrameSegmentID == renderTick?.sourceFrame?.screenSlice?.segmentID {
            screenFrame = pausedScreenFrame
            screenFrameSegmentID = pausedScreenFrameSegmentID
            screenFrameGeneration = renderTick?.mediaGeneration
        }
        // Keep the last presented drawable until this slice owns a frame.
        // Reusing its pixels with the next source's crop/geometry causes a
        // one-frame flash of the wrong recording at a source boundary.
        if let renderTick,
           screenFrameSegmentID != renderTick.sourceFrame?.screenSlice?.segmentID
            || screenFrameGeneration != renderTick.mediaGeneration {
            if playbackSource == nil { retryStationaryFrame(revision: activeRevision, epoch: activeEpoch) }
            return
        }
        var screen = screenFrame
        if suppressScreenContent, let current = screen {
            // 屏幕素材拖动抑制：几何不变但内容透明，由 SwiftUI 覆盖层即时绘制。
            screen = CIImage(color: .clear).cropped(to: current.extent)
        }
        guard let screen else {
            // Do not fall back to the retired SwiftUI layer compositor.
            // A precise paused frame or the first video-output frame will
            // populate this surface as soon as AVFoundation makes it ready.
            if playbackSource == nil { retryStationaryFrame(revision: activeRevision, epoch: activeEpoch) }
            return
        }
        let cameraResource: CIImage? = {
            guard !suppressCameraContent else { return nil }
            guard let renderTick, renderTick.cameraIsAvailable else { return nil }
            if renderTick.sourceFrame?.usesPrimaryFrameForCamera == true, let frame = screenFrame {
                return renderTick.sourceFrame?.cameraContentCrop.map { CameraLetterboxAnalysis.cropped(frame, to: $0) } ?? frame
            }
            let currentSourceID = renderTick.sourceFrame?.cameraSlice?.sourceID
            if usesPausedFrame, let pausedCameraFrame, pausedCameraFrameSourceID == currentSourceID {
                cameraFrame = pausedCameraFrame
                cameraFrameSourceID = currentSourceID
                cameraFrameMediaGeneration = renderTick.mediaGeneration
                cameraFrameDiscontinuityID = renderTick.discontinuityID
            }
            let cachedFrameBelongsToCurrentEpoch = cameraFrameSourceID == currentSourceID &&
                PreviewCameraFrameContinuityPolicy.canUseCachedFrame(
                    cachedMediaGeneration: cameraFrameMediaGeneration,
                    cachedDiscontinuityID: cameraFrameDiscontinuityID,
                    currentMediaGeneration: renderTick.mediaGeneration,
                    currentDiscontinuityID: renderTick.discontinuityID,
                    presentationIsPaused: !renderTick.isPlaying
                )
            let frame = cachedFrameBelongsToCurrentEpoch ? cameraFrame : nil
            guard let frame, let cameraContentCrop = renderTick.sourceFrame?.cameraContentCrop else { return frame }
            return CameraLetterboxAnalysis.cropped(frame, to: cameraContentCrop)
        }()
        let animations = animationResources(for: semanticScene)
        let insertedMotion = insertedMotionResource(for: semanticScene)
        let videos = videoResources(for: semanticScene)
        // Keep the last complete drawable while the incoming video's first frame decodes.
        guard !animations.pending, insertedMotion?.pending != true, !videos.pending else { return }
        var resources = SharedFrameRenderResources(
            screen: screen,
            camera: cameraResource,
            wallpaper: wallpaperFrame,
            cursor: cursorFrame,
            stickers: stickerFrames,
            animations: animations.images,
            preparedBackground: preparedBackgroundCache.image(
                scene: semanticScene.background,
                canvasSize: semanticScene.canvasSize,
                wallpaperSource: wallpaperFrame,
                wallpaperRevision: wallpaperRevision
            )
        )
        let beautyTime = renderTick?.sourceFrame?.cameraSlice?.sourceTime(atOutputTime: semanticScene.time) ?? semanticScene.time
        resources.cameraBeauty = CameraBeautyFrame(tracker: cameraBeautyTracker, time: beautyTime,
            sourceID: renderTick?.sourceFrame?.cameraSlice?.sourceID,
            mediaGeneration: renderTick?.mediaGeneration ?? 0, discontinuityID: renderTick?.discontinuityID ?? 0)
        resources.videos = videos.images
        for sticker in semanticScene.stickers {
            resources.timedStickers[sticker.id] = ImageMediaFrameCache.shared.frame(
                at: assetURL(sticker.relativePath), time: sticker.sourceTime)
        }
        resources.insertedMotion = insertedMotion?.image
        resources.insertedImage = suppressScreenContent ? nil : semanticScene.insertedImage.flatMap {
            ImageMediaFrameCache.shared.frame(at: assetURL($0.sourcePath), time: $0.localTime)
        }
        let cameraIsPrimaryPicture = !semanticScene.layerOrder.contains(.screen)
        if cameraIsPrimaryPicture, renderTick?.cameraIsAvailable == true, semanticScene.camera == nil {
            // The transport can finish preparing before the view receives
            // the camera geometry. Its next configuration supplies the scene.
            return
        }
        if !suppressCameraContent, renderTick?.cameraIsAvailable == true,
           (semanticScene.camera?.opacity ?? 0) > 0, cameraResource == nil {
            // A camera-only recording or a template's aperture needs its
            // subject before presentation. An independent PIP retains the
            // existing bounded stationary retry and live playback policy.
            let needsCamera = cameraIsPrimaryPicture || semanticScene.animations.contains(where: \.hostsCamera)
            if needsCamera || (playbackSource == nil && cameraOutput != nil && (isPointerPreview || pausedRetryAttempt < 5)) {
                if playbackSource == nil {
                    retryStationaryFrame(revision: activeRevision, epoch: activeEpoch)
                }
                return
            }
        }
        // PRE-007: `semanticScene` is already evaluated at the selected raster
        // size. Flow mode therefore owns a deliberate 1× view raster, while
        // full mode owns a source-native drawable; CAMetalLayer scales either
        // into the same view bounds. Rendering a full scene straight into a
        // smaller drawable would only rename the old low mode without reducing
        // the expensive composition work.
        guard let previewLayer = layer,
              previewLayer.device != nil else { return }
        let destinationPixelSize = CanvasPreviewRasterPolicy.drawablePixelSize(rasterCanvasSize: semanticScene.canvasSize)
        if previewLayer.isHidden || previewLayer.contentsScale != backingScale
            || previewLayer.drawableSize != destinationPixelSize
            || previewLayer.colorspace !== colorProfile.outputColorSpace {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.isHidden = false
            previewLayer.contentsScale = backingScale
            previewLayer.drawableSize = destinationPixelSize
            previewLayer.colorspace = colorProfile.outputColorSpace
            CATransaction.commit()
            CATransaction.flush()
        }
        guard let drawable = currentDrawable else {
            displayDriver.requestFrame()
            return
        }
        let signature = PreviewVisualSignature(
            plan: renderPlan,
            contentRevision: contentRevision,
            backingScale: backingScale,
            destinationPixelSize: destinationPixelSize,
            colorContract: semanticScene.color,
            insertedImageFrame: resources.insertedImage
        )
        guard signature != lastSubmittedSignature
            || (usesPausedFrame && effectPrewarmPlans != lastSubmittedPrewarmPlans)
        else { return }
        lastSubmittedSignature = signature
        lastSubmittedPrewarmPlans = effectPrewarmPlans
        let job = PreviewRenderJob(
            generation: activeRevision,
            drawable: drawable,
            presentationEpochID: activeEpoch,
            diagnostics: currentDiagnosticFrame?.enqueued(),
            plan: renderPlan,
            effectPrewarmPlans: usesPausedFrame ? effectPrewarmPlans : [],
            resources: resources,
            canvasSize: semanticScene.canvasSize,
            destinationPixelSize: destinationPixelSize,
            colorProfile: colorProfile,
            colorContract: semanticScene.color,
            metalLayer: previewLayer,
            isPausedFrame: usesPausedFrame,
            includesCamera: !suppressCameraContent && ((semanticScene.camera?.opacity ?? 0) <= 0.001 || resources.camera != nil),
            includesScreen: !suppressScreenContent
                && (semanticScene.insertedMotion == nil || resources.insertedMotion != nil)
                && (semanticScene.insertedImage == nil || resources.insertedImage != nil)
        )
        let submitted = renderDrawable(for: job, renderCompletion: { [weak self] presented in
            self?.didCompleteRender(job: job, presented: presented)
        })
        if !submitted { retryStationaryFrame(revision: job.generation, epoch: job.presentationEpochID) }
    }

    private func decodedFrame(
        output: AVPlayerItemVideoOutput,
        itemTime: CMTime,
        preferredTransform: CGAffineTransform,
        allowCachedFrame: Bool,
        validSlice: TimelineMediaSlice?
    ) -> CIImage? {
        // CanvasPreview evaluates FrameScene from this exact controller tick.
        // The surface must never resample either transport clock independently.
        guard itemTime.isNumeric else { return nil }
        guard output.hasNewPixelBuffer(forItemTime: itemTime) || !allowCachedFrame else {
            return nil
        }
        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) else { return nil }
        if let validSlice, displayTime.isNumeric,
           validSlice.sourceTime(atOutputTime: displayTime.seconds) == nil { return nil }
        return SharedPreviewFramePipeline.orientedFrame(
            CIImage(cvPixelBuffer: pixelBuffer),
            preferredTransform: preferredTransform
        )
    }


}

extension SharedPreviewEngine {
    /// Share one preview allowance between all active HTML clips, including
    /// full-screen graphics. Large Retina frames must not multiply the budget.
    private func motionMemoryBudget(for scene: FrameScene) -> Int {
        let live = (semanticScene?.animations.count ?? 0) + (semanticScene?.insertedMotion == nil ? 0 : 1)
        return 128 * 1_024 * 1_024 / max(live + warmedAnimationIDs.count + warmedMainIDs.count, 1)
    }

    /// Overlay and main-track HTML use the same bounded, integer-indexed
    /// lookahead. Playback consumes ready frames rather than requesting one
    /// remote web snapshot after each displayed frame.
    private func animationResources(for scene: FrameScene) -> (images: [UUID: CIImage], pending: Bool) {
        let live = Set(scene.animations.map(\.id)).union(warmedAnimationIDs)
        for id in Array(animationBuffers.keys) where !live.contains(id) {
            animationBuffers.removeValue(forKey: id)?.reset()
        }
        var images: [UUID: CIImage] = [:]
        var pending = false
        for animation in scene.animations {
            let sample = animationResource(animation, in: scene)
            images[animation.id] = sample.image
            pending = pending || sample.pending
        }
        return (images, pending)
    }
    func animationResource(_ animation: FrameAnimationScene, in scene: FrameScene) -> PreviewMotionFrames.Sample {
            let buffer = animationBuffers[animation.id] ?? makeMotionBuffer()
            animationBuffers[animation.id] = buffer
            let backing = backingScale
            let onScreen = bounds.width > 1
                ? min(bounds.width * backing / max(CGFloat(scene.canvasSize.width), 1), 1) : 1
            let width = max((CGFloat(scene.canvasSize.width) * CGFloat(animation.width) * onScreen).rounded(), 2)
            let size = CGSize(width: width,
                height: max((width * CGFloat(scene.canvasSize.height) / max(CGFloat(scene.canvasSize.width), 1)).rounded(), 2))
            let edits = applyingLiveDrag(animation.elementEdits, for: .overlay(animation.id))
            return buffer.sample(path: assetURL(animation.sourcePath).path,
                properties: animation.properties, edits: edits, time: animation.localTime, size: size,
                memoryBudget: motionMemoryBudget(for: scene), exact: playbackSource == nil,
                playbackEpoch: playbackSource == nil ? nil : activeEpoch
            ) { [weak self] in
                guard let self else { return }
                self.contentRevision &+= 1
                self.renderCurrentFrame()
            }
    }

}

extension SharedPreviewEngine {
    func insertedMotionResource(for scene: FrameScene, segmentID: UUID? = nil) -> PreviewMotionFrames.Sample? {
        let current = renderTick?.sourceFrame?.screenSlice?.segmentID
        let keep = warmedMainIDs.union([current, segmentID].compactMap { $0 })
        for id in Array(insertedMotionBuffers.keys) where !keep.contains(id) {
            insertedMotionBuffers.removeValue(forKey: id)?.reset()
        }
        guard let motion = scene.insertedMotion, let id = segmentID ?? current else { return nil }
        let buffer = insertedMotionBuffers[id] ?? makeMotionBuffer()
        insertedMotionBuffers[id] = buffer
        let full = HTMLMotion.insertedPixelSize(scene)
        let backing = backingScale
        let onScreen = bounds.width > 1 ? bounds.width * backing / max(CGFloat(scene.canvasSize.width), 1) : 1
        let scale = min(onScreen, 1)
        let size = CGSize(width: max((full.width * scale).rounded(), 2), height: max((full.height * scale).rounded(), 2))
        let edits = applyingLiveDrag(motion.elementEdits, for: .mainTrack(id))
        return buffer.sample(path: assetURL(motion.sourcePath).path,
            properties: motion.properties, edits: edits, time: motion.localTime, size: size,
            memoryBudget: motionMemoryBudget(for: scene), exact: playbackSource == nil,
            playbackEpoch: playbackSource == nil ? nil : activeEpoch
        ) { [weak self] in
            guard let self else { return }
            self.contentRevision &+= 1
            self.renderCurrentFrame()
        }
    }

    /// Overlay video frames available now; stale ones are requested and the
    /// surface redraws when they land.
    func videoResources(for scene: FrameScene) -> (images: [UUID: CIImage], pending: Bool) {
        let live = Set(scene.videos.map(\.id))
        videoFrames = videoFrames.filter { live.contains($0.key) }
        videoRequests = videoRequests.filter { live.contains($0.key) }
        var images: [UUID: CIImage] = [:]
        var pending = false
        for video in scene.videos {
            let id = video.id, path = assetURL(video.sourcePath).path
            let step = video.sourceTime
            let cached = videoFrames[id].flatMap { $0.path == path ? $0 : nil }
            images[id] = cached?.image
            guard cached?.time != step else { continue }
            pending = pending || cached == nil || usesPausedFrame
            guard videoRequests[id]?.path != path else { continue }
            let token = UUID()
            videoRequests[id] = (path, token)
            Task.detached { [weak self] in
                let image = await VideoOverlayDecoder.shared.frame(clip: id, path: path, at: step)
                self?.renderQueue.async { [weak self] in
                    guard let self, self.videoRequests[id]?.token == token else { return }
                    self.videoRequests.removeValue(forKey: id)
                    self.videoFrames[id] = (path, step, image ?? cached?.image)
                    self.contentRevision &+= 1
                    self.renderCurrentFrame()
                }
            }
        }
        return (images, pending)
    }
}

extension SharedPreviewEngine {
    /// WindowServer keeps the most recently presented drawable as the window's
    /// visual backing even after AppKit dismantles the layer. Replace that
    /// front buffer with a transparent 2×2 surface first, so the retained
    /// snapshot costs kilobytes instead of one 53 MB 5K IOSurface.
    func presentTinyRetirementDrawable(
        _ request: PreviewLayerRetirementRequest,
        drawable: any CAMetalDrawable
    ) {
        guard request.generation == previewRetirementGeneration,
              let previewLayer = request.layer else { return }
        guard let device = previewLayer.device else {
            finishTinyRetirementDrawable(request)
            return
        }
        if queueCommandQueue == nil {
            queueCommandQueue = device.makeCommandQueue()
        }
        guard drawable.layer === previewLayer,
              let commandQueue = queueCommandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            finishTinyRetirementDrawable(request)
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            finishTinyRetirementDrawable(request)
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self, request] _ in
            self?.finishTinyRetirementDrawable(request)
        }
        commandBuffer.commit()
    }

    func finishTinyRetirementDrawable(_ request: PreviewLayerRetirementRequest) {
        onRetired?(request)
    }
}
