import AppKit
import AVFoundation
import CoreImage
import Metal
import os
import QuartzCore
import RecorderCore
import SwiftUI

struct SharedRenderedPreviewView: NSViewRepresentable {
    let screenOutput: AVPlayerItemVideoOutput?
    let screenPreferredTransform: CGAffineTransform
    let cameraOutput: AVPlayerItemVideoOutput?
    let cameraPreferredTransform: CGAffineTransform
    let cameraContentCrop: NormalizedCrop?
    let renderTick: EditorPlaybackRenderTick?
    let usesPausedFrame: Bool
    /// The exact evaluated frame contract used by export.
    let renderPlan: FrameRenderPlan
    /// Evaluation at the playhead. This drives colour/resource identity while
    /// interaction overlays use the corresponding scene in `CanvasPreviewLayout`.
    let semanticScene: FrameScene
    var perspectivePrewarmPlan: FrameRenderPlan? = nil
    let pausedScreenImage: NSImage?
    let pausedCameraImage: NSImage?
    let wallpaperImage: NSImage?
    let wallpaperVideoURL: URL?
    let stickerImages: [String: NSImage]
    /// 拖动摄像头期间由 SwiftUI 覆盖层直接绘制摄像头内容（与选择框同坐标、零滞后），
    /// 合成帧里暂时不含摄像头层，避免滞后残影（拖得越远越明显的“闪烁/两个影”）。
    let suppressCameraContent: Bool
    let suppressScreenContent: Bool
    var playbackController: EditorPlaybackController? = nil
    var playbackFrameProvider: SharedPreviewPlaybackFrameProvider? = nil
    var onCameraContentApplied: (() -> Void)? = nil
    var onScreenContentApplied: (() -> Void)? = nil

    func makeNSView(context: Context) -> SharedRenderedPreviewNSView {
        let view = SharedRenderedPreviewNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: SharedRenderedPreviewNSView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: SharedRenderedPreviewNSView, coordinator: Void) {
        view.invalidate()
    }

    private func update(_ view: SharedRenderedPreviewNSView) {
        view.update(
            screenOutput: screenOutput,
            screenPreferredTransform: screenPreferredTransform,
            cameraOutput: cameraOutput,
            cameraPreferredTransform: cameraPreferredTransform,
            cameraContentCrop: cameraContentCrop,
            renderTick: renderTick,
            usesPausedFrame: usesPausedFrame,
            renderPlan: renderPlan,
            semanticScene: semanticScene,
            perspectivePrewarmPlan: perspectivePrewarmPlan,
            pausedScreenImage: pausedScreenImage,
            pausedCameraImage: pausedCameraImage,
            wallpaperImage: wallpaperImage,
            wallpaperVideoURL: wallpaperVideoURL,
            stickerImages: stickerImages,
            suppressCameraContent: suppressCameraContent,
            suppressScreenContent: suppressScreenContent
        )
        view.configurePlayback(
            controller: playbackController,
            frameProvider: playbackFrameProvider
        )
        view.onCameraContentApplied = onCameraContentApplied
        view.onScreenContentApplied = onScreenContentApplied
    }
}

@MainActor
final class SharedRenderedPreviewNSView: NSView {
    #if DEBUG
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "editor-preview"
    )
    #endif
    weak var playbackController: EditorPlaybackController?
    private var playbackFrameProvider: SharedPreviewPlaybackFrameProvider?
    private let windowVisibilityController = SharedPreviewWindowVisibilityController()
    // 以下成员放宽到模块内访问，仅供 SharedPreviewLayerRetirement /
    // SharedPreviewRenderPipeline 扩展使用。
    var presentationIsSuspended: Bool { windowVisibilityController.isSuspended }
    private var screenOutput: AVPlayerItemVideoOutput?
    private var screenPreferredTransform = CGAffineTransform.identity
    private var cameraOutput: AVPlayerItemVideoOutput?
    private var cameraPreferredTransform = CGAffineTransform.identity
    private var cameraContentCrop: NormalizedCrop?
    private var renderTick: EditorPlaybackRenderTick?
    private var usesPausedFrame = false
    private var renderPlan: FrameRenderPlan?
    private var semanticScene: FrameScene?
    private var perspectivePrewarmPlan: FrameRenderPlan?
    private var suppressCameraContent = false
    private var suppressScreenContent = false
    var onCameraContentApplied: (() -> Void)?
    var onScreenContentApplied: (() -> Void)?
    /// 上一帧应用时的内容包含状态：只有相邻两帧包含状态一致才允许交叉淡化，
    /// 否则“无摄像头→有摄像头”会被淡化成一次淡入闪烁（松手闪帧的根因）。
    private var lastAppliedIncludesCamera: Bool?
    private var lastAppliedIncludesScreen: Bool?
    /// 渲染在途/脏标记（仅主线程访问）：3D 播放等高频输入下队列不积压。
    /// Match CAMetalLayer's triple-buffered drawable pool. Completion is
    /// reported only after the presentation command finishes, so a two-frame
    /// cap still starved this 60 Hz producer at roughly 45 fps on a 120 Hz
    /// display even though CPU/GPU work itself was below budget.
    private var renderInFlightCount = 0
    private let maximumRenderInFlightCount = 3
    var renderDirty = false
    /// Back-pressure coalesces to the newest scene. Preserve that scene's
    /// display deadline as well, otherwise the catch-up frame falls back to an
    /// immediate presentation and recreates the visible burst after a stall.
    private var renderDirtyPresentationHostTime: CFTimeInterval?
    private var lastLayoutSize = CGSize.zero
    let cursorClickGradientLayer = CAGradientLayer()
    let cursorClickLayer = CAShapeLayer()
    let cursorClickSecondaryLayer = CAShapeLayer()
    let cursorClickAccentLayer = CAShapeLayer()
    let cursorImageLayer = CALayer()
    private var cursorOverlayAppearance: PreviewCursorOverlayAppearance?
    /// Contents are rasterized at the on-screen pixel size (vector-supported,
    /// so zooms stay crisp). Only the size, not the 60-120 Hz position,
    /// invalidates the cache.
    private var cursorContentsSignature: PreviewCursorContentsSignature?

    private var screenFrame: CIImage?
    private var cameraFrame: CIImage?
    private var pausedScreenImage: NSImage?
    private var pausedScreenFrame: CIImage?
    private var pausedCameraImage: NSImage?
    private var pausedCameraFrame: CIImage?
    private var wallpaperImage: NSImage?
    private var wallpaperFrame: CIImage?
    private var wallpaperVideoURL: URL?
    private var wallpaperVideoHasLiveFrame = false
    private let wallpaperVideoPlayback = PreviewWallpaperVideoPlayback()
    private var stickerImages: [String: NSImage] = [:]
    private var stickerFrames: [String: CIImage] = [:]
    private var wallpaperRevision: UInt64 = 0
    private var preparedBackgroundCache = PreviewPreparedBackgroundCache()
    private var cursorAssetID: CursorAssetID?
    private var cursorFrame: CIImage?
    private var contentRevision: UInt64 = 0
    var lastSubmittedSignature: PreviewVisualSignature?
    #if DEBUG
    private var cadenceWindowStartedAt = CACurrentMediaTime()
    private var cadenceDisplayTicks = 0
    private var cadenceSubmittedFrames = 0
    private var cadencePresentedFrames = 0
    private var cadenceCoalescedFrames = 0
    #endif

    private var colorContract: FrameColorContract?
    private var colorProfile: CoreImageFrameColorProfile?

    /// 合成与栅格化在专用串行队列上进行：update() 每次只取帧并入队，
    /// 主线程不再随每次状态变更同步渲染整幅画面（拖动不跟手/颤动的根因）。
    let renderQueue = DispatchQueue(
        label: "cn.laogou.dogsc.preview-render",
        qos: .userInitiated
    )
    /// 主线程写入、renderQueue 读取（仅作过期启发式判断，UInt64 对齐读写在
    /// ARM 上是原子的；最严格的一致性由主线程应用前的最终比较兜底）。
    nonisolated(unsafe) var renderGeneration: UInt64 = 0
    /// Identity is main-actor state; the aligned UInt64 token is the only value
    /// read by the render queue. Do not share the multi-word identity itself
    /// across queues, because a pause could otherwise be observed half-written.
    private var presentationEpochIdentity = PreviewPresentationEpoch(
        mediaGeneration: nil,
        discontinuityID: nil,
        isPlaying: false
    )
    nonisolated(unsafe) var presentationEpochID: UInt64 = 0
    /// Main actor issues/cancels retirement generations; the render queue reads
    /// this aligned token before touching a layer whose window may have resumed.
    nonisolated(unsafe) var previewRetirementGeneration: UInt64 = 0
    /// 仅 renderQueue 访问的上下文缓存。
    nonisolated(unsafe) var queueContext: CIContext?
    nonisolated(unsafe) var queueColorContract: FrameColorContract?
    nonisolated(unsafe) var queueCommandQueue: MTLCommandQueue?
    nonisolated(unsafe) var queueDidPrewarmPerspective = false
    nonisolated(unsafe) var queuePrewarmedPerspectiveSignatures = Set<
        PreviewPerspectivePrewarmSignature
    >()

    override func makeBackingLayer() -> CALayer {
        Self.makePreviewMetalLayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        cursorClickGradientLayer.type = .radial
        cursorClickGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        cursorClickGradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        cursorClickGradientLayer.zPosition = 997
        cursorClickGradientLayer.isHidden = true
        cursorClickSecondaryLayer.fillColor = NSColor.clear.cgColor
        cursorClickSecondaryLayer.zPosition = 998
        cursorClickAccentLayer.fillColor = NSColor.clear.cgColor
        cursorClickAccentLayer.zPosition = 999
        cursorClickLayer.fillColor = NSColor.clear.cgColor
        cursorClickLayer.zPosition = 1_000
        cursorImageLayer.contentsGravity = .resize
        cursorImageLayer.shadowColor = NSColor.black.cgColor
        cursorImageLayer.zPosition = 1_001
        layer?.addSublayer(cursorClickGradientLayer)
        layer?.addSublayer(cursorClickSecondaryLayer)
        layer?.addSublayer(cursorClickAccentLayer)
        layer?.addSublayer(cursorClickLayer)
        layer?.addSublayer(cursorImageLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func invalidate() {
        windowVisibilityController.invalidate()
        playbackController = nil
        playbackFrameProvider = nil
        screenOutput = nil
        cameraOutput = nil
        pausedScreenImage = nil
        pausedScreenFrame = nil
        pausedCameraImage = nil
        pausedCameraFrame = nil
        screenFrame = nil
        cameraFrame = nil
        wallpaperImage = nil
        wallpaperFrame = nil
        wallpaperVideoURL = nil
        wallpaperVideoHasLiveFrame = false
        wallpaperVideoPlayback.invalidate()
        stickerImages = [:]
        stickerFrames = [:]
        wallpaperRevision &+= 1
        preparedBackgroundCache.reset()
        ContinuousCornerMask.resetCache()
        cursorFrame = nil
        cursorAssetID = nil
        cursorOverlayAppearance = nil
        cursorContentsSignature = nil
        cursorImageLayer.contents = nil
        cursorImageLayer.isHidden = true
        cursorClickGradientLayer.isHidden = true
        cursorClickLayer.isHidden = true
        cursorClickSecondaryLayer.isHidden = true
        cursorClickAccentLayer.isHidden = true
        renderPlan = nil
        semanticScene = nil
        perspectivePrewarmPlan = nil
        colorContract = nil
        colorProfile = nil
        onCameraContentApplied = nil
        onScreenContentApplied = nil
        renderGeneration &+= 1
        presentationEpochIdentity = PreviewPresentationEpoch(
            mediaGeneration: nil,
            discontinuityID: nil,
            isPlaying: false
        )
        presentationEpochID &+= 1
        renderDirty = false
        renderInFlightCount = 0
        lastSubmittedSignature = nil
        lastAppliedIncludesCamera = false
        lastAppliedIncludesScreen = false
        suspendPreviewBackingLayer()

        // Queue-owned Core Image/Metal caches are not MainActor state. Clear
        // them after every already-enqueued render job so closing the editor
        // cannot leave a 4K texture cache resident behind another application.
        renderQueue.async { [self] in
            // Releasing the Swift CIContext reference alone does not force its
            // private intermediate pool to abandon purgeable IOSurfaces. A
            // single low-resolution editor visit otherwise leaves roughly
            // 115 MB of full-canvas Core Image surfaces in the recorder phase.
            queueContext?.clearCaches()
            queueContext = nil
            queueColorContract = nil
            queueCommandQueue = nil
            queueDidPrewarmPerspective = false
            queuePrewarmedPerspectiveSignatures.removeAll(keepingCapacity: false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowVisibilityController.attach(to: self)
    }


    override func layout() {
        super.layout()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        renderCurrentFrame()
    }

    func configurePlayback(
        controller: EditorPlaybackController?,
        frameProvider: SharedPreviewPlaybackFrameProvider?
    ) {
        playbackController = controller
        playbackFrameProvider = frameProvider
        windowVisibilityController.updatePlaybackState()
    }

    func playbackDisplayLinkDidFire(_ link: CADisplayLink) {
        guard let playbackController,
              playbackController.isPlaying,
              let playbackFrameProvider
        else { return }
        let itemTimeForDisplay = screenOutput?.itemTime(
            forHostTime: link.targetTimestamp
        )
        guard let tick = playbackController.renderTick(
            itemTimeForDisplay: itemTimeForDisplay,
            uptime: link.targetTimestamp
        ) else { return }
        // The controller sampled one canonical clock above. Give the visible
        // frame first access to this display-link budget, then move the native
        // playhead/overview/time label from the exact same sample.
        defer { playbackController.flushDeferredNativeTimelineNotification() }
        #if DEBUG
        cadenceDisplayTicks += 1
        #endif
        let frame = playbackFrameProvider(tick)
        applyFrameContract(
            renderTick: tick,
            usesPausedFrame: false,
            renderPlan: frame.renderPlan,
            semanticScene: frame.semanticScene,
            perspectivePrewarmPlan: nil
        )
        renderCurrentFrame(presentationHostTime: link.targetTimestamp)
        #if DEBUG
        logCadenceIfDue()
        #endif
    }

    func update(
        screenOutput: AVPlayerItemVideoOutput?,
        screenPreferredTransform: CGAffineTransform,
        cameraOutput: AVPlayerItemVideoOutput?,
        cameraPreferredTransform: CGAffineTransform,
        cameraContentCrop: NormalizedCrop?,
        renderTick: EditorPlaybackRenderTick?,
        usesPausedFrame: Bool,
        renderPlan: FrameRenderPlan,
        semanticScene: FrameScene,
        perspectivePrewarmPlan: FrameRenderPlan?,
        pausedScreenImage: NSImage?,
        pausedCameraImage: NSImage?,
        wallpaperImage: NSImage?,
        wallpaperVideoURL: URL?,
        stickerImages: [String: NSImage],
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
            pausedScreenFrame = Self.ciImage(from: pausedScreenImage)
            contentRevision &+= 1
        }
        if self.pausedCameraImage !== pausedCameraImage {
            self.pausedCameraImage = pausedCameraImage
            pausedCameraFrame = Self.ciImage(from: pausedCameraImage)
            contentRevision &+= 1
        }
        if self.wallpaperImage !== wallpaperImage {
            self.wallpaperImage = wallpaperImage
            if wallpaperVideoURL == nil || !wallpaperVideoHasLiveFrame {
                wallpaperFrame = Self.ciImage(from: wallpaperImage)
            }
            wallpaperRevision &+= 1
            preparedBackgroundCache.reset()
            contentRevision &+= 1
        }
        if self.wallpaperVideoURL != wallpaperVideoURL {
            self.wallpaperVideoURL = wallpaperVideoURL
            wallpaperVideoHasLiveFrame = false
            wallpaperVideoPlayback.configure(url: wallpaperVideoURL)
            // Keep the selected movie's cached first frame visible while its
            // hardware decoder is preparing. The first live pixel atomically
            // supersedes this poster below.
            wallpaperFrame = Self.ciImage(from: wallpaperImage)
            wallpaperRevision &+= 1
            preparedBackgroundCache.reset()
            contentRevision &+= 1
        }
        wallpaperVideoPlayback.onFrameAvailable = { [weak self] in
            self?.renderCurrentFrame()
        }
        let stickerImagesChanged = self.stickerImages.count != stickerImages.count
            || stickerImages.contains { key, image in
                self.stickerImages[key] !== image
            }
        if stickerImagesChanged {
            self.stickerImages = stickerImages
            stickerFrames = stickerImages.compactMapValues {
                Self.ciImage(from: $0)
            }
            contentRevision &+= 1
        }
        if self.cameraContentCrop != cameraContentCrop
            || self.suppressCameraContent != suppressCameraContent
            || self.suppressScreenContent != suppressScreenContent {
            contentRevision &+= 1
        }

        self.screenPreferredTransform = screenPreferredTransform
        self.cameraPreferredTransform = cameraPreferredTransform
        self.cameraContentCrop = cameraContentCrop
        self.suppressCameraContent = suppressCameraContent
        self.suppressScreenContent = suppressScreenContent
        applyFrameContract(
            renderTick: renderTick,
            usesPausedFrame: usesPausedFrame,
            renderPlan: renderPlan,
            semanticScene: semanticScene,
            perspectivePrewarmPlan: perspectivePrewarmPlan
        )
        renderCurrentFrame()
    }

    private func applyFrameContract(
        renderTick: EditorPlaybackRenderTick?,
        usesPausedFrame: Bool,
        renderPlan: FrameRenderPlan,
        semanticScene: FrameScene,
        perspectivePrewarmPlan: FrameRenderPlan?
    ) {
        let planCursorAssetID = renderPlan.scene.cursor?.assetID
            ?? semanticScene.cursor?.assetID
        if cursorAssetID != planCursorAssetID {
            cursorAssetID = planCursorAssetID
            cursorFrame = planCursorAssetID
                .flatMap { CursorAssetLibrary.resolvedAsset(for: $0) }
                .flatMap { $0.renderSource()?.image }
            contentRevision &+= 1
        }
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
        if renderTick?.cameraIsAvailable != true {
            if cameraFrame != nil { contentRevision &+= 1 }
            cameraFrame = nil
        }
        if colorContract != semanticScene.color {
            colorContract = semanticScene.color
            colorProfile = try? CoreImageFrameColorProfile(contract: semanticScene.color)
            contentRevision &+= 1
        }
        self.renderTick = renderTick
        wallpaperVideoPlayback.synchronize(to: renderTick)
        self.usesPausedFrame = usesPausedFrame
        let nextPresentationEpoch = PreviewPresentationEpoch(
            mediaGeneration: renderTick?.mediaGeneration,
            discontinuityID: renderTick?.discontinuityID,
            isPlaying: !usesPausedFrame && renderTick?.isPlaying == true
        )
        if nextPresentationEpoch != presentationEpochIdentity {
            presentationEpochIdentity = nextPresentationEpoch
            presentationEpochID &+= 1
        }
        self.renderPlan = renderPlan
        self.semanticScene = semanticScene
        self.perspectivePrewarmPlan = perspectivePrewarmPlan.map(
            SharedPreviewFramePipeline.rasterPlan
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func renderCurrentFrame(
        presentationHostTime: CFTimeInterval? = nil
    ) {
        if !renderDirty {
            renderDirtyPresentationHostTime = nil
        }
        guard !presentationIsSuspended else { return }
        guard let renderPlan, let semanticScene, let colorProfile else {
            layer?.isHidden = true
            return
        }
        let separatesCursor = SharedPreviewFramePipeline.canSeparateCursor(
            in: renderPlan
        )
        updateCursorOverlay(
            scene: semanticScene,
            separatesCursor: separatesCursor
        )

        if let renderTick, let screenOutput,
           let decoded = decodedFrame(
               output: screenOutput,
               itemTime: renderTick.itemTime,
               preferredTransform: screenPreferredTransform,
               allowCachedFrame: screenFrame != nil
           ) {
            screenFrame = decoded
            contentRevision &+= 1
        }
        if renderTick?.cameraIsAvailable == true,
           let renderTick,
           let cameraOutput,
           let decoded = decodedFrame(
               output: cameraOutput,
               itemTime: renderTick.itemTime,
               preferredTransform: cameraPreferredTransform,
               allowCachedFrame: cameraFrame != nil
           ) {
            cameraFrame = decoded
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
        // controller intentionally releases its NSImage when playback starts;
        // retaining the CIImage here bridges that release to the decoder's
        // first resumed pixel without presenting an empty drawable.
        if usesPausedFrame, let pausedScreenFrame {
            screenFrame = pausedScreenFrame
        }
        var screen = usesPausedFrame
            ? (pausedScreenFrame ?? screenFrame)
            : screenFrame
        if suppressScreenContent, let current = screen {
            // 屏幕素材拖动抑制：几何不变但内容透明，由 SwiftUI 覆盖层即时绘制。
            screen = CIImage(color: .clear).cropped(to: current.extent)
        }
        guard let screen else {
            // Do not fall back to the retired SwiftUI layer compositor.
            // A precise paused frame or the first video-output frame will
            // populate this surface as soon as AVFoundation makes it ready.
            layer?.isHidden = true
            return
        }
        let cameraResource: CIImage? = {
            guard !suppressCameraContent else { return nil }
            guard renderTick?.cameraIsAvailable == true else { return nil }
            if usesPausedFrame, let pausedCameraFrame {
                cameraFrame = pausedCameraFrame
            }
            let frame = usesPausedFrame
                ? (pausedCameraFrame ?? cameraFrame)
                : cameraFrame
            guard let frame, let cameraContentCrop else { return frame }
            return CameraLetterboxAnalysis.cropped(frame, to: cameraContentCrop)
        }()
        let resources = SharedFrameRenderResources(
            screen: screen,
            camera: cameraResource,
            wallpaper: wallpaperFrame,
            // The independent Core Animation cursor is already visible above
            // this surface. Passing no cursor resource makes the shared
            // compositor skip that layer without cloning every scene merely
            // to delete its cursor fields.
            cursor: separatesCursor ? nil : cursorFrame,
            stickers: stickerFrames,
            preparedBackground: preparedBackgroundCache.image(
                scene: semanticScene.background,
                canvasSize: semanticScene.canvasSize,
                wallpaperSource: wallpaperFrame,
                wallpaperRevision: wallpaperRevision
            )
        )

        // PRE-007: `semanticScene` is already evaluated at the selected raster
        // size. Flow mode therefore owns a deliberate 1× view raster, while
        // full mode owns a source-native drawable; CAMetalLayer scales either
        // into the same view bounds. Rendering a full scene straight into a
        // smaller drawable would only rename the old low mode without reducing
        // the expensive composition work.
        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        guard let previewLayer = layer as? CAMetalLayer,
              previewLayer.device != nil else { return }
        previewLayer.isHidden = false
        previewLayer.contentsScale = backingScale
        let destinationPixelSize = CanvasPreviewRasterPolicy.drawablePixelSize(
            rasterCanvasSize: semanticScene.canvasSize
        )
        if previewLayer.drawableSize != destinationPixelSize {
            previewLayer.drawableSize = destinationPixelSize
        }
        if previewLayer.colorspace !== colorProfile.outputColorSpace {
            previewLayer.colorspace = colorProfile.outputColorSpace
        }
        let signature = PreviewVisualSignature(
            plan: renderPlan,
            separatesCursor: separatesCursor,
            contentRevision: contentRevision,
            backingScale: backingScale,
            destinationPixelSize: destinationPixelSize,
            colorContract: semanticScene.color
        )
        guard signature != lastSubmittedSignature else { return }
        // 最多一个在途渲染：渲染跟不上输入（如 3D 播放每帧都推新任务）时
        // 只记脏标记，完成后追渲染最新状态，队列绝不积压、延迟不滚雪球。
        // MOT-001: inspector sliders can publish dozens of full-resolution 3D
        // paused frames before the user presses Play. Only one paused render
        // may wait on the serial compositor; playback keeps triple buffering.
        // This prevents a changed transition duration from making playback
        // wait behind a backlog of obsolete paused 3D frames.
        let allowedInFlightCount = PreviewRenderBackpressurePolicy.maximumInFlight(
            isPausedFrame: usesPausedFrame,
            playbackLimit: maximumRenderInFlightCount
        )
        guard renderInFlightCount < allowedInFlightCount else {
            renderDirty = true
            renderDirtyPresentationHostTime = presentationHostTime
            #if DEBUG
            cadenceCoalescedFrames += 1
            #endif
            return
        }
        renderInFlightCount += 1
        #if DEBUG
        cadenceSubmittedFrames += 1
        #endif
        lastSubmittedSignature = signature
        renderGeneration &+= 1
        let job = PreviewRenderJob(
            generation: renderGeneration,
            presentationEpochID: presentationEpochID,
            presentationHostTime: presentationHostTime,
            plan: renderPlan,
            perspectivePrewarmPlan: usesPausedFrame ? perspectivePrewarmPlan : nil,
            resources: resources,
            canvasSize: semanticScene.canvasSize,
            destinationPixelSize: destinationPixelSize,
            colorProfile: colorProfile,
            colorContract: semanticScene.color,
            metalLayer: previewLayer,
            isPausedFrame: usesPausedFrame,
            includesCamera: !suppressCameraContent,
            includesScreen: !suppressScreenContent
        )
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderDrawable(
                for: job,
                submissionCompletion: { [weak self] submitted in
                    DispatchQueue.main.async { [weak self] in
                        self?.finishRenderSubmission(
                            job: job,
                            submitted: submitted
                        )
                    }
                },
                presentationCompletion: { [weak self] presented in
                    DispatchQueue.main.async { [weak self] in
                        self?.finishRenderPresentation(
                            job: job,
                            presented: presented
                        )
                    }
                }
            )
        }
    }

    /// PRE-002/CUR-002: update the synthetic pointer as two tiny Core
    /// Animation layers. Publishing its 60 Hz position through @State forced
    /// SwiftUI to lay out the complete editor window (including the timeline)
    /// on every display refresh. The raster compositor still owns the cursor
    /// whenever perspective or camera overlap makes separation inequivalent.
    private func updateCursorOverlay(
        scene: FrameScene,
        separatesCursor: Bool
    ) {
        guard separatesCursor,
              let cursor = scene.cursor,
              scene.canvasSize.width > 0,
              scene.canvasSize.height > 0,
              bounds.width > 0,
              bounds.height > 0
        else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorImageLayer.isHidden = true
            cursorClickGradientLayer.isHidden = true
            cursorClickLayer.isHidden = true
            cursorClickSecondaryLayer.isHidden = true
            cursorClickAccentLayer.isHidden = true
            CATransaction.commit()
            return
        }

        let scaleX = bounds.width / scene.canvasSize.width
        let scaleY = bounds.height / scene.canvasSize.height
        let layout = cursor.layout
        guard let screenProjection = scene.screen.projectedQuad.projector(
            from: scene.screen.projectionRect
        ) else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorImageLayer.isHidden = true
            cursorClickGradientLayer.isHidden = true
            cursorClickLayer.isHidden = true
            cursorClickSecondaryLayer.isHidden = true
            cursorClickAccentLayer.isHidden = true
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let appearance = PreviewCursorOverlayAppearance(cursor: cursor)
        if cursorOverlayAppearance != appearance {
            cursorImageLayer.shadowOpacity = Float(
                appearance.shadow?.opacity ?? 0
            )
            cursorImageLayer.shadowRadius = appearance.shadow?.radius ?? 0
            cursorImageLayer.shadowOffset = CGSize(
                width: appearance.shadow?.offset.x ?? 0,
                height: -(appearance.shadow?.offset.y ?? 0)
            )
            cursorOverlayAppearance = appearance
        }
        let imageRect = CompositionRect(
            x: layout.origin.x,
            y: layout.origin.y,
            width: layout.size.width,
            height: layout.size.height
        )
        guard applyProjectedGeometry(
            to: cursorImageLayer,
            rect: imageRect,
            projection: screenProjection,
            scaleX: scaleX,
            scaleY: scaleY,
            rotationRadians: cursor.rotationRadians,
            rotationAnchor: layout.pointer
        ) else {
            cursorImageLayer.isHidden = true
            cursorClickGradientLayer.isHidden = true
            cursorClickLayer.isHidden = true
            cursorClickSecondaryLayer.isHidden = true
            cursorClickAccentLayer.isHidden = true
            CATransaction.commit()
            return
        }
        // The layer transform maps canvas units to view points. Rasterize the
        // contents at the exact on-screen pixel size so the pointer stays
        // crisp while the user zooms (system bitmap + vector fallback), and
        // re-rasterize only when that size actually changes.
        let transform = cursorImageLayer.affineTransform()
        let viewScale = max(
            hypot(transform.a, transform.b),
            hypot(transform.c, transform.d)
        )
        let backingScale = window?.backingScaleFactor ?? 2
        let pixelWidth = max(
            Int(ceil(imageRect.width * viewScale * backingScale)),
            1
        )
        let pixelHeight = max(
            Int(ceil(imageRect.height * viewScale * backingScale)),
            1
        )
        let contentsSignature = PreviewCursorContentsSignature(
            assetID: appearance.assetID,
            width: pixelWidth,
            height: pixelHeight
        )
        if cursorContentsSignature != contentsSignature {
            guard let contents = CursorAssetLibrary
                .resolvedAsset(for: appearance.assetID)?
                .rasterizedPixelImage(
                    width: pixelWidth,
                    height: pixelHeight
                ) else {
                cursorImageLayer.contents = nil
                cursorImageLayer.isHidden = true
                cursorClickGradientLayer.isHidden = true
                cursorClickLayer.isHidden = true
                cursorClickSecondaryLayer.isHidden = true
                cursorClickAccentLayer.isHidden = true
                CATransaction.commit()
                return
            }
            cursorImageLayer.contents = contents
            cursorImageLayer.contentsScale = backingScale
            cursorContentsSignature = contentsSignature
        }
        cursorImageLayer.isHidden = false

        if cursor.isClicking {
            let progress = cursor.clickPhase?.progress ?? 0.25
            let components = appearance.clickColor.components
            if let clickGeom = CursorRenderGeometry.clickGeometry(
                style: cursor.clickStyle,
                progress: progress,
                baseHeight: layout.size.height,
                opacityMultiplier: cursor.clickOpacity,
                scaleMultiplier: cursor.clickScale
            ) {
                if cursor.clickStyle == .glow {
                    let primaryDiameter = clickGeom.primaryDiameter
                    let primaryRect = CompositionRect(
                        x: layout.pointer.x - primaryDiameter / 2,
                        y: layout.pointer.y - primaryDiameter / 2,
                        width: primaryDiameter,
                        height: primaryDiameter
                    )
                    if applyProjectedGeometry(
                        to: cursorClickGradientLayer,
                        rect: primaryRect,
                        projection: screenProjection,
                        scaleX: scaleX,
                        scaleY: scaleY
                    ) {
                        cursorClickGradientLayer.colors = [
                            NSColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: clickGeom.primaryOpacity).cgColor,
                            NSColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: clickGeom.primaryOpacity * 0.40).cgColor,
                            NSColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: 0.0).cgColor
                        ]
                        cursorClickGradientLayer.locations = [0.0, 0.48, 1.0]
                        cursorClickGradientLayer.cornerRadius = primaryDiameter * min(scaleX, scaleY) / 2
                        cursorClickGradientLayer.masksToBounds = true
                        cursorClickGradientLayer.isHidden = false
                    } else {
                        cursorClickGradientLayer.isHidden = true
                    }
                    cursorClickLayer.isHidden = true
                    cursorClickSecondaryLayer.isHidden = true
                    cursorClickAccentLayer.isHidden = true
                } else {
                    cursorClickGradientLayer.isHidden = true

                    // 1. Primary shape
                    if clickGeom.primaryDiameter > 0 && clickGeom.primaryOpacity > 0.001 {
                        let primaryDiameter = clickGeom.primaryDiameter
                        let primaryRect = CompositionRect(
                            x: layout.pointer.x - primaryDiameter / 2,
                            y: layout.pointer.y - primaryDiameter / 2,
                            width: primaryDiameter,
                            height: primaryDiameter
                        )
                        if applyProjectedGeometry(
                            to: cursorClickLayer,
                            rect: primaryRect,
                            projection: screenProjection,
                            scaleX: scaleX,
                            scaleY: scaleY
                        ) {
                            if clickGeom.primaryIsFilled {
                                cursorClickLayer.fillColor = NSColor(
                                    srgbRed: components.red,
                                    green: components.green,
                                    blue: components.blue,
                                    alpha: clickGeom.primaryOpacity
                                ).cgColor
                                cursorClickLayer.strokeColor = nil
                                cursorClickLayer.lineWidth = 0
                            } else {
                                cursorClickLayer.fillColor = nil
                                cursorClickLayer.strokeColor = NSColor(
                                    srgbRed: components.red,
                                    green: components.green,
                                    blue: components.blue,
                                    alpha: clickGeom.primaryOpacity
                                ).cgColor
                                cursorClickLayer.lineWidth = clickGeom.primaryLineWidth
                            }
                            if clickGeom.primaryGlowRadius > 0 {
                                cursorClickLayer.shadowColor = NSColor(
                                    srgbRed: components.red,
                                    green: components.green,
                                    blue: components.blue,
                                    alpha: 1.0
                                ).cgColor
                                cursorClickLayer.shadowRadius = clickGeom.primaryGlowRadius
                                cursorClickLayer.shadowOpacity = Float(min(clickGeom.primaryOpacity * 0.75, 0.9))
                                cursorClickLayer.shadowOffset = .zero
                            } else {
                                cursorClickLayer.shadowOpacity = 0
                            }
                            cursorClickLayer.path = CGPath(
                                ellipseIn: CGRect(x: 0, y: 0, width: primaryDiameter, height: primaryDiameter),
                                transform: nil
                            )
                            cursorClickLayer.isHidden = false
                        } else {
                            cursorClickLayer.isHidden = true
                        }
                    } else {
                        cursorClickLayer.isHidden = true
                    }

                    // 2. Secondary shape (spark dot, inner ring, or inner bounce bubble)
                    if clickGeom.secondaryDiameter > 0 && clickGeom.secondaryOpacity > 0.001 {
                        let secDiameter = clickGeom.secondaryDiameter
                        let secRect = CompositionRect(
                            x: layout.pointer.x - secDiameter / 2,
                            y: layout.pointer.y - secDiameter / 2,
                            width: secDiameter,
                            height: secDiameter
                        )
                        if applyProjectedGeometry(
                            to: cursorClickSecondaryLayer,
                            rect: secRect,
                            projection: screenProjection,
                            scaleX: scaleX,
                            scaleY: scaleY
                        ) {
                            if clickGeom.secondaryIsFilled {
                                cursorClickSecondaryLayer.fillColor = NSColor(
                                    srgbRed: components.red,
                                    green: components.green,
                                    blue: components.blue,
                                    alpha: clickGeom.secondaryOpacity
                                ).cgColor
                                cursorClickSecondaryLayer.strokeColor = nil
                                cursorClickSecondaryLayer.lineWidth = 0
                            } else {
                                cursorClickSecondaryLayer.fillColor = nil
                                cursorClickSecondaryLayer.strokeColor = NSColor(
                                    srgbRed: components.red,
                                    green: components.green,
                                    blue: components.blue,
                                    alpha: clickGeom.secondaryOpacity
                                ).cgColor
                                cursorClickSecondaryLayer.lineWidth = clickGeom.secondaryLineWidth
                            }
                            if clickGeom.secondaryGlowRadius > 0 {
                                cursorClickSecondaryLayer.shadowColor = NSColor(
                                    srgbRed: components.red,
                                    green: components.green,
                                    blue: components.blue,
                                    alpha: 1.0
                                ).cgColor
                                cursorClickSecondaryLayer.shadowRadius = clickGeom.secondaryGlowRadius
                                cursorClickSecondaryLayer.shadowOpacity = Float(min(clickGeom.secondaryOpacity * 0.75, 0.9))
                                cursorClickSecondaryLayer.shadowOffset = .zero
                            } else {
                                cursorClickSecondaryLayer.shadowOpacity = 0
                            }
                            cursorClickSecondaryLayer.path = CGPath(
                                ellipseIn: CGRect(x: 0, y: 0, width: secDiameter, height: secDiameter),
                                transform: nil
                            )
                            cursorClickSecondaryLayer.isHidden = false
                        } else {
                            cursorClickSecondaryLayer.isHidden = true
                        }
                    } else {
                        cursorClickSecondaryLayer.isHidden = true
                    }

                    // 3. Accent burst layer
                    if clickGeom.accentSize > 0 && clickGeom.accentOpacity > 0.001 && clickGeom.accentOffset > 0 {
                        let accentFootprint = (clickGeom.accentOffset + clickGeom.accentSize) * 2
                        let accentRect = CompositionRect(
                            x: layout.pointer.x - accentFootprint / 2,
                            y: layout.pointer.y - accentFootprint / 2,
                            width: accentFootprint,
                            height: accentFootprint
                        )
                        if applyProjectedGeometry(
                            to: cursorClickAccentLayer,
                            rect: accentRect,
                            projection: screenProjection,
                            scaleX: scaleX,
                            scaleY: scaleY
                        ) {
                            let center = accentFootprint / 2
                            let path = CGMutablePath()
                            let offset = clickGeom.accentOffset
                            let sz = clickGeom.accentSize
                            path.addEllipse(in: CGRect(x: center - sz / 2, y: center - offset - sz / 2, width: sz, height: sz))
                            path.addEllipse(in: CGRect(x: center - sz / 2, y: center + offset - sz / 2, width: sz, height: sz))
                            path.addEllipse(in: CGRect(x: center - offset - sz / 2, y: center - sz / 2, width: sz, height: sz))
                            path.addEllipse(in: CGRect(x: center + offset - sz / 2, y: center - sz / 2, width: sz, height: sz))
                            cursorClickAccentLayer.fillColor = NSColor(
                                srgbRed: components.red,
                                green: components.green,
                                blue: components.blue,
                                alpha: clickGeom.accentOpacity
                            ).cgColor
                            cursorClickAccentLayer.strokeColor = nil
                            cursorClickAccentLayer.path = path
                            cursorClickAccentLayer.isHidden = false
                        } else {
                            cursorClickAccentLayer.isHidden = true
                        }
                    } else {
                        cursorClickAccentLayer.isHidden = true
                    }
                }
            } else {
                cursorClickGradientLayer.isHidden = true
                cursorClickLayer.isHidden = true
                cursorClickSecondaryLayer.isHidden = true
                cursorClickAccentLayer.isHidden = true
            }
        } else {
            cursorClickGradientLayer.isHidden = true
            cursorClickLayer.isHidden = true
            cursorClickSecondaryLayer.isHidden = true
            cursorClickAccentLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Applies the screen's exact projective mapping at the four corners of a
    /// small overlay, then lowers that local patch to an affine CALayer basis.
    /// A pointer is only a few dozen pixels wide, so this preserves the visible
    /// 3D orientation while avoiding a full-canvas perspective render for each
    /// display-link tick.
    private func applyProjectedGeometry(
        to layer: CALayer,
        rect: CompositionRect,
        projection: ProjectedScreenPointMapper,
        scaleX: CGFloat,
        scaleY: CGFloat,
        rotationRadians: Double = 0,
        rotationAnchor: CompositionPoint? = nil
    ) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }

        func rotatedPoint(_ point: CompositionPoint) -> CompositionPoint {
            guard let rotationAnchor,
                  rotationRadians.isFinite,
                  abs(rotationRadians) > 0.000_1 else { return point }

            // Composition coordinates grow downward, whereas Core Image's
            // export canvas grows upward. Negating the scene angle here keeps
            // this independent preview layer visually identical to export.
            let angle = -rotationRadians
            let cosine = cos(angle)
            let sine = sin(angle)
            let deltaX = point.x - rotationAnchor.x
            let deltaY = point.y - rotationAnchor.y
            return CompositionPoint(
                x: rotationAnchor.x + deltaX * cosine - deltaY * sine,
                y: rotationAnchor.y + deltaX * sine + deltaY * cosine
            )
        }

        func projectedViewPoint(_ point: CompositionPoint) -> CGPoint? {
            guard let projected = projection.project(rotatedPoint(point)) else {
                return nil
            }
            return CGPoint(
                x: projected.x * scaleX,
                y: bounds.height - projected.y * scaleY
            )
        }

        guard let bottomLeft = projectedViewPoint(CompositionPoint(
                  x: rect.x,
                  y: rect.y + rect.height
              )),
              let bottomRight = projectedViewPoint(CompositionPoint(
                  x: rect.x + rect.width,
                  y: rect.y + rect.height
              )),
              let topLeft = projectedViewPoint(CompositionPoint(
                  x: rect.x,
                  y: rect.y
              )) else { return false }

        layer.anchorPoint = CGPoint(x: 0, y: 0)
        layer.bounds = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        layer.position = bottomLeft
        layer.setAffineTransform(CGAffineTransform(
            a: (bottomRight.x - bottomLeft.x) / rect.width,
            b: (bottomRight.y - bottomLeft.y) / rect.width,
            c: (topLeft.x - bottomLeft.x) / rect.height,
            d: (topLeft.y - bottomLeft.y) / rect.height,
            tx: 0,
            ty: 0
        ))
        return true
    }

    @MainActor
    private func finishRenderSubmission(
        job: PreviewRenderJob,
        submitted: Bool
    ) {
        renderInFlightCount = max(renderInFlightCount - 1, 0)
        if !submitted {
            // A failed submission must be eligible for retry.
            lastSubmittedSignature = nil
            renderDirty = true
        }
        // A slot means "CPU composition submitted to Metal", not "the GPU has
        // finished presenting". Tying this release to command completion made
        // the 60 Hz producer wait on the window server and capped it near
        // 45 fps. CAMetalLayer.nextDrawable() remains the bounded GPU back-
        // pressure point, while this queue still coalesces CPU jobs.
        if renderDirty {
            renderDirty = false
            let presentationHostTime = renderDirtyPresentationHostTime
            renderDirtyPresentationHostTime = nil
            renderCurrentFrame(presentationHostTime: presentationHostTime)
        }
    }

    private func finishRenderPresentation(
        job: PreviewRenderJob,
        presented: Bool
    ) {
        #if DEBUG
        if presented { cadencePresentedFrames += 1 }
        #endif
        if presented, renderGeneration == job.generation {
            if job.includesCamera { onCameraContentApplied?() }
            if job.includesScreen { onScreenContentApplied?() }
            lastAppliedIncludesCamera = job.includesCamera
            lastAppliedIncludesScreen = job.includesScreen
        }
    }

    #if DEBUG
    private func logCadenceIfDue() {
        let now = CACurrentMediaTime()
        let elapsed = now - cadenceWindowStartedAt
        guard elapsed >= 1 else { return }
        let ticks = Double(cadenceDisplayTicks) / elapsed
        let submitted = Double(cadenceSubmittedFrames) / elapsed
        let presented = Double(cadencePresentedFrames) / elapsed
        let message = "preview cadence: "
            + "displayTicks=\(String(format: "%.1f", ticks))fps "
            + "submitted=\(String(format: "%.1f", submitted))fps "
            + "presented=\(String(format: "%.1f", presented))fps "
            + "coalesced=\(cadenceCoalescedFrames) "
            + "inFlight=\(renderInFlightCount)"
        Self.logger.notice("\(message, privacy: .public)")
        cadenceWindowStartedAt = now
        cadenceDisplayTicks = 0
        cadenceSubmittedFrames = 0
        cadencePresentedFrames = 0
        cadenceCoalescedFrames = 0
    }
    #endif

    private func decodedFrame(
        output: AVPlayerItemVideoOutput,
        itemTime: CMTime,
        preferredTransform: CGAffineTransform,
        allowCachedFrame: Bool
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
        return SharedPreviewFramePipeline.orientedFrame(
            CIImage(cvPixelBuffer: pixelBuffer),
            preferredTransform: preferredTransform
        )
    }

    private static func ciImage(from image: NSImage?) -> CIImage? {
        guard let image else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) {
            return CIImage(cgImage: cgImage)
        }
        return image.tiffRepresentation.flatMap(CIImage.init(data:))
    }
}
