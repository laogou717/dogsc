import AppKit
import AVFoundation
import CoreImage
import Metal
import os
import QuartzCore
import RecorderCore
import SwiftUI

struct SharedRenderedPreviewView: NSViewRepresentable {
    var presentationMode = 0
    var assetRootURL: URL? = nil
    var motionStarts: [PreviewMotionStart] = []
    let screenOutput: AVPlayerItemVideoOutput?
    let cameraOutput: AVPlayerItemVideoOutput?
    let renderTick: EditorPlaybackRenderTick?
    /// The exact evaluated frame contract used by export.
    let renderPlan: FrameRenderPlan
    /// Evaluation at the playhead. This drives colour/resource identity while
    /// interaction overlays use the corresponding scene in `CanvasPreviewLayout`.
    let semanticScene: FrameScene
    var effectPrewarmPlans: [FrameRenderPlan] = []
    let pausedScreenImage: NSImage?
    let pausedCameraImage: NSImage?
    let wallpaperImage: NSImage?
    let wallpaperVideoURL: URL?
    var sceneWallpapers: [String: EditorSceneWallpaper] = [:]
    var defaultWallpaperKey: String? = nil
    let stickerImages: [String: NSImage]
    /// 拖动摄像头期间由 SwiftUI 覆盖层直接绘制摄像头内容（与选择框同坐标、零滞后），
    /// 合成帧里暂时不含摄像头层，避免滞后残影（拖得越远越明显的“闪烁/两个影”）。
    let suppressCameraContent: Bool
    let suppressScreenContent: Bool
    var playbackController: EditorPlaybackController? = nil
    var playbackFrameProvider: SharedPreviewPlaybackFrameProvider? = nil
    var onCameraContentApplied: (() -> Void)? = nil
    var onScreenContentApplied: (() -> Void)? = nil
    var onSleepCoverChanged: PreviewSleepCoverHandler? = nil

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
        view.onSleepCoverChanged = onSleepCoverChanged
        view.preparePresentationTransition()
        view.configurePlayback(
            controller: playbackController,
            frameProvider: playbackFrameProvider
        )
        view.update(
            screenOutput: screenOutput,
            cameraOutput: cameraOutput,
            renderTick: renderTick,
            renderPlan: renderPlan,
            semanticScene: semanticScene,
            effectPrewarmPlans: effectPrewarmPlans,
            pausedScreenImage: pausedScreenImage,
            pausedCameraImage: pausedCameraImage,
            wallpaperImage: wallpaperImage,
            wallpaperVideoURL: wallpaperVideoURL,
            sceneWallpapers: sceneWallpapers,
            defaultWallpaperKey: defaultWallpaperKey,
            stickerImages: stickerImages,
            suppressCameraContent: suppressCameraContent,
            suppressScreenContent: suppressScreenContent,
            assetRootURL: assetRootURL, motionStarts: motionStarts
        )
        view.onCameraContentApplied = onCameraContentApplied
        view.onScreenContentApplied = onScreenContentApplied
    }
}

@MainActor
final class SharedRenderedPreviewNSView: NSView {
    weak var playbackController: EditorPlaybackController?
    private var previousPlaying: Bool?
    private var playbackFrameProvider: SharedPreviewPlaybackFrameProvider?
    let engine = SharedPreviewEngine()
    private let windowVisibilityController = SharedPreviewWindowVisibilityController()
    private var input: PreviewEngineInput?
    private var imageCache: [ObjectIdentifier: (NSImage, CIImage)] = [:]
    private var usedImages = Set<ObjectIdentifier>()
    var onCameraContentApplied: (() -> Void)?
    var onScreenContentApplied: (() -> Void)?
    var onSleepCoverChanged: PreviewSleepCoverHandler?
    var presentationIsSuspended: Bool { windowVisibilityController.isSuspended }
    var presentationEpochID: UInt64 { engine.mailbox.epoch }
    var previewRetirementGeneration: UInt64 { engine.mailbox.retirementGeneration }

    override func makeBackingLayer() -> CALayer { Self.makePreviewMetalLayer() }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        _ = CursorAssetLibrary.renderAssets // Capture system cursor images on AppKit's thread.
        let progress = EditorMainDelivery<EditorPlaybackRenderTick> { [weak self] tick in
            self?.playbackController?.acceptPreviewProgress(tick)
        }
        let presented = EditorMainDelivery<PreviewFrameReadiness> { [weak self] event in
            guard let self, self.presentationEpochID == event.epoch else { return }
            self.windowVisibilityController.previewFrameBecameReady(epochID: event.epoch)
            WindowAppearanceTransition.previewFramePresented()
            if event.revision == self.engine.mailbox.configurationRevision {
                if event.includesCamera { self.onCameraContentApplied?() }
                if event.includesScreen { self.onScreenContentApplied?() }
            }
        }
        engine.onProgress = { progress.send($0) }
        engine.onFrameReady = { presented.send($0) }
        engine.onRetired = { [weak self] request in
            EditorMainRunLoop.perform { [weak self] in
                guard let self, let layer = request.layer else { return }
                self.finalizePreviewBackingLayerRetirement(layer, generation: request.generation)
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        guard input?.bounds != bounds else { return }
        renderCurrentFrame()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowVisibilityController.attach(to: self)
        if window != nil {
            MotionElementEditor.onLiveDragChange = { [weak self] in self?.renderCurrentFrame() }
        }
    }
    func configurePlayback(controller: EditorPlaybackController?, frameProvider: SharedPreviewPlaybackFrameProvider?) {
        if playbackController !== controller {
            playbackController?.removeNativeTimelineObserver(self)
            playbackController = controller
            previousPlaying = nil
            controller?.addNativeTimelineObserver(self)
        }
        playbackFrameProvider = frameProvider
    }
    func preparePresentationTransition() { layer?.removeAnimation(forKey: "cropPresentation") }
    func suspendRendering() { engine.suspend() }
    func invalidate() {
        windowVisibilityController.invalidate()
        playbackController?.removeNativeTimelineObserver(self)
        playbackController = nil; playbackFrameProvider = nil; input = nil
        imageCache.removeAll()
        engine.invalidate()
        // A dismantled view releases its backing layer. Retirement is for a
        // suspended view that stays alive, not a second job after shutdown.
        wantsLayer = false
    }
    func renderCurrentFrame() {
        guard var input else { return }
        // Geometry and live drag updates reuse the last scene. A pause needs
        // a new scene and tick from update(), not that scene at a new mode.
        if input.source != nil, playbackController?.isPlaying == false { return }
        input.layer = layer as? CAMetalLayer
        input.bounds = bounds
        input.backingScale = window?.backingScaleFactor ?? 2
        input.suspended = presentationIsSuspended
        input.liveDrag = MotionElementEditor.liveDrag
        self.input = input
        engine.configure(input)
    }
    func update(screenOutput: AVPlayerItemVideoOutput?, cameraOutput: AVPlayerItemVideoOutput?,
                renderTick: EditorPlaybackRenderTick?,
                renderPlan: FrameRenderPlan, semanticScene: FrameScene, effectPrewarmPlans: [FrameRenderPlan],
                pausedScreenImage: NSImage?, pausedCameraImage: NSImage?, wallpaperImage: NSImage?,
                wallpaperVideoURL: URL?, sceneWallpapers: [String: EditorSceneWallpaper], defaultWallpaperKey: String?,
                stickerImages: [String: NSImage], suppressCameraContent: Bool, suppressScreenContent: Bool, assetRootURL: URL? = nil, motionStarts: [PreviewMotionStart] = []) {
        usedImages.removeAll(keepingCapacity: true)
        let pausedScreen = convert(pausedScreenImage), pausedCamera = convert(pausedCameraImage)
        let wallpaper = convert(wallpaperImage)
        let wallpapers = sceneWallpapers.mapValues { PreviewSceneWallpaper(image: convert($0.image), videoURL: $0.videoURL) }
        let stickers = stickerImages.compactMapValues { convert($0) }
        imageCache = imageCache.filter { usedImages.contains($0.key) }
        let source = playbackController?.previewPlaybackSource
        // Play intent arrives before the transport has finished seeking. Use
        // the paused pixels until there is a live source to replace them.
        let usesPausedFrame = source == nil && playbackController?.hoverPreviewTime == nil
        input = PreviewEngineInput(layer: layer as? CAMetalLayer, bounds: bounds,
            backingScale: window?.backingScaleFactor ?? 2, suspended: presentationIsSuspended,
            source: source, provider: playbackFrameProvider,
            screenOutput: screenOutput, cameraOutput: cameraOutput, tick: renderTick, paused: usesPausedFrame,
            plan: renderPlan, scene: semanticScene, prewarm: effectPrewarmPlans,
            pausedScreen: pausedScreen, pausedCamera: pausedCamera, wallpaper: wallpaper,
            wallpaperVideo: wallpaperVideoURL, sceneWallpapers: wallpapers, defaultWallpaperKey: defaultWallpaperKey,
            stickers: stickers, suppressCamera: suppressCameraContent, suppressScreen: suppressScreenContent,
            liveDrag: MotionElementEditor.liveDrag, assetRootURL: assetRootURL?.standardizedFileURL, motionStarts: motionStarts)
        if let input { engine.configure(input) }
    }
    private func convert(_ image: NSImage?) -> CIImage? {
        guard let image else { return nil }
        let id = ObjectIdentifier(image)
        usedImages.insert(id)
        if let cached = imageCache[id] { return cached.1 }
        var rect = CGRect(origin: .zero, size: image.size)
        let converted = image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(CIImage.init(cgImage:))
            ?? image.tiffRepresentation.flatMap(CIImage.init(data:))
        if let converted { imageCache[id] = (image, converted) }
        return converted
    }
}

extension SharedRenderedPreviewNSView: EditorPlaybackTimelineObserver {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot) {
        if previousPlaying == true && !snapshot.isPlaying { engine.suspend() }
        previousPlaying = snapshot.isPlaying
    }
}
