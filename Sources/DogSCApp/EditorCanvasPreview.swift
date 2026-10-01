import AppKit
import AVKit
import Combine
import QuartzCore
import RecorderCore
import SwiftUI

enum OverlayResizeCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft

    var id: String { rawValue }
    var xSign: Double { self == .topLeft || self == .bottomLeft ? -1 : 1 }
    var ySign: Double { self == .topLeft || self == .topRight ? -1 : 1 }
}

struct StickerResizeGestureOrigin {
    let id: UUID
    let width: Double
    let center: CGPoint
    let handle: CGPoint
    let handleRadius: CGFloat
}

struct StickerRotationGestureOrigin {
    let id: UUID
    let rotationDegrees: Double
    let center: CGPoint
    let handle: CGPoint
    let handleAngle: Double
}

struct StickerRotationHandleGeometry {
    let anchor: CGPoint
    let handle: CGPoint
}

private struct CanvasRenderedFrame {
    let playbackTime: TimeInterval
    let layout: CanvasPreviewLayout
}

struct CanvasPreview: View {
    @Environment(\.displayScale) var displayScale
    @Environment(\.editorIsActive) var isEditorActive
    @State private var loadedWallpaperSource: BackgroundSource?
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    let renderProject: RecorderProject
    @Binding var previewResolutionMode: EditorPreviewResolutionMode
    let isCropping: Bool
    /// PRE-033: 时间线分栏拖动进行中。拖动期间预览栅格保持拖动起始尺寸
    /// 冻结，视图本身实时跟随新区域拉伸既有 drawable，松手后一次性按最终
    /// 尺寸重评估——避免每个拖动 tick 都全尺寸重渲染并抖动 drawable 池。
    let isSplitterResizing: Bool
    @Binding var cropDraft: NormalizedCrop
    let wallpaperURLResolver: EditorSessionContext.WallpaperURLResolver
    let projectAssetURLResolver: EditorSessionContext.ProjectAssetURLResolver
    let onCanvasFocused: () -> Void
    let onError: (String) -> Void
    @State var resolvedWallpaperImage: NSImage?
    @State var resolvedWallpaperVideoURL: URL?
    @State var resolvedStickerImages: [String: NSImage] = [:]
    @State var playbackTrackCache: EditorCanvasPlaybackTrackCache
    @State var playbackPlanCache: EditorCanvasPlaybackPlanCache
    @State var effectPrewarmPlanCache: EditorCanvasEffectPrewarmPlanCache
    @State var cropSourceFrameCache: EditorCanvasCropSourceFrameCache
    /// Reuses one Core Image context for all direct-manipulation snapshots in
    /// this editor session. The renderer is released with the canvas instead
    /// of leaving a process-wide GPU cache behind after the project closes.
    @State var dragPreviewRenderer = EditorCanvasDragPreviewRenderer()
    @State var screenDragOrigin: NormalizedPoint?
    @State var screenDragScope: EditorCanvasEditScope?
    @State var screenScaleOrigin: Double?
    @State var screenScaleScope: EditorCanvasEditScope?
    @State var cameraDragOrigin: NormalizedPoint?
    @State var cameraDragScope: EditorCanvasEditScope?
    @State var cameraSizeOrigin: Double?
    @State var cameraSizeScope: EditorCanvasEditScope?
    /// 拖动摄像头期间：暂停帧摄像头图（已按黑边检测裁剪+镜像），由覆盖层即时绘制，
    /// 合成帧暂时不含摄像头层，消除滞后残影。
    @State var cameraDragPreviewImage: NSImage?
    /// 合成帧是否抑制摄像头层。松手时立即恢复合成（带摄像头重渲染），
    /// 覆盖图则保留到合成帧落地回报后再清，杜绝交接期“闪一帧透明”。
    @State var cameraCompositorSuppressed = false
    /// 拖动屏幕素材期间同理：覆盖层即时绘制屏幕内容。
    @State var screenDragPreviewImage: NSImage?
    @State var screenCompositorSuppressed = false
    /// 画布拖动吸附命中的参考线（归一化画布坐标），拖动结束时清空。
    @State var canvasSnapGuideX: Double?
    @State var canvasSnapGuideY: Double?
    @State var cropDragOrigin: NormalizedCrop?
    @State var overlayDragOrigin: NormalizedPoint?
    @State var overlayDragSelection: EditorSelection?
    @State var mosaicDragOrigin: NormalizedOverlayRect?
    @State var mosaicResizeOrigin: NormalizedOverlayRect?
    @State var mosaicResizeCorner: OverlayResizeCorner?
    @State var stickerResizeOrigin: StickerResizeGestureOrigin?
    @State var stickerRotationOrigin: StickerRotationGestureOrigin?
    @State var overlayResizeSelection: EditorSelection?
    /// The canvas owns one hover identity across screen, camera and authored
    /// overlays. Keeping it here prevents every object type from inventing a
    /// slightly different hover state and transition.
    @State var hoveredCanvasSelection: EditorSelection?
    /// 分栏拖动起始时的画布点尺寸；nil 表示不在拖动中。
    @State var splitterResizeFrozenCanvasSize: CGSize?
    /// 非拖动状态下最近一次实际画布尺寸，供拖动起手时冻结。
    @State private var restCanvasSize: CGSize?

    init(
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        renderProject: RecorderProject,
        previewResolutionMode: Binding<EditorPreviewResolutionMode>,
        isCropping: Bool,
        isSplitterResizing: Bool = false,
        cropDraft: Binding<NormalizedCrop>,
        wallpaperURLResolver: @escaping EditorSessionContext.WallpaperURLResolver,
        projectAssetURLResolver: @escaping EditorSessionContext.ProjectAssetURLResolver,
        onCanvasFocused: @escaping () -> Void = {},
        onError: @escaping (String) -> Void
    ) {
        self.editorStore = editorStore
        self.mediaSession = mediaSession
        self.playbackController = playbackController
        self.renderProject = renderProject
        _previewResolutionMode = previewResolutionMode
        self.isCropping = isCropping
        self.isSplitterResizing = isSplitterResizing
        _cropDraft = cropDraft
        self.wallpaperURLResolver = wallpaperURLResolver
        self.projectAssetURLResolver = projectAssetURLResolver
        self.onCanvasFocused = onCanvasFocused
        self.onError = onError
        _playbackTrackCache = State(
            initialValue: EditorCanvasPlaybackTrackCache(
                project: editorStore.previewProject
            )
        )
        _playbackPlanCache = State(
            initialValue: EditorCanvasPlaybackPlanCache()
        )
        _effectPrewarmPlanCache = State(
            initialValue: EditorCanvasEffectPrewarmPlanCache()
        )
        _cropSourceFrameCache = State(
            initialValue: EditorCanvasCropSourceFrameCache()
        )
    }

    var project: RecorderProject { renderProject }

    var sourcePixelSize: CGSize { mediaSession.sourceDisplaySize }

    var sourceAspectRatio: CGFloat {
        let safeHeight = max(sourcePixelSize.height, CGFloat(1))
        return max(sourcePixelSize.width / safeHeight, CGFloat(0.01))
    }

    var hasCameraTrack: Bool { mediaSession.inventories.camera.hasVideo }

    var cameraSourceAspectRatio: CGFloat {
        guard let size = mediaSession.cameraDisplaySize,
              size.width > 0,
              size.height > 0 else { return 4.0 / 3.0 }
        return size.width / size.height
    }

    var editScope: EditorCanvasEditScope {
        EditorCanvasEditScope(selection: editorStore.selection)
    }

    var cameraInteractionScope: EditorCanvasEditScope {
        if case .camera = editScope { return editScope }
        return .camera(.base)
    }

    var isScreenSelectionActive: Bool {
        if case .screen = editScope { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
                let liveCanvasSize = fittedCanvasSize(in: geometry.size)
                // PRE-033: 分栏拖动期间，场景求值与 Metal 栅格冻结在拖动起始
                // 尺寸（CAMetalLayer 自动把既有 drawable 拉伸进新视图边界，
                // 短暂的等比软化远好于每 tick 全尺寸重渲染的闪烁）；视图框
                // 架与定位仍用实时尺寸，松手后一次重评估恢复清晰。
                let rasterCanvasSize = splitterResizeFrozenCanvasSize ?? liveCanvasSize
                // Playback frames are pulled inside SharedRenderedPreviewNSView
                // without publishing SwiftUI state. This snapshot is only for
                // paused editing geometry and static interaction overlays.
                // EDT-030: 时间线悬浮预览激活时画布改看所指帧；播放头、
                // 时间码与总览仍钉在 outputTime 上。
                let activeTick = playbackController.hoverRenderTick
                    ?? playbackController.stationaryRenderTick
                let renderedFrame = makeRenderedFrame(
                    canvasSize: rasterCanvasSize,
                    activeTick: activeTick
                )
                let effectPrewarmPlans = isEditorActive ? makeEffectPrewarmPlans(for: renderedFrame) : []
                let playbackPlanCacheHandle = renderedFrame.flatMap {
                    playbackPlanCache.prepare(
                        around: playbackController.outputTime,
                        using: $0.layout.playbackEvaluation,
                        isPlaying: playbackController.isPlaying,
                        isInteracting: editorStore.interaction != nil || !isEditorActive
                    )
                }

                canvasContent(
                    liveCanvasSize: liveCanvasSize,
                    rasterCanvasSize: rasterCanvasSize,
                    activeTick: activeTick,
                    renderedFrame: renderedFrame,
                    effectPrewarmPlans: effectPrewarmPlans,
                    playbackPlanCacheHandle: playbackPlanCacheHandle
                )
                .frame(width: liveCanvasSize.width, height: liveCanvasSize.height)
                // A projected/zoomed object's transparent hit shape may extend
                // beyond the monitor even when its pixels are clipped below.
                .contentShape(Rectangle())
                .overlay {
                    if !isEditorActive {
                        EditorTheme.sleepingMonitor.allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .onChange(of: liveCanvasSize, initial: true) { _, newSize in
                    // 持续跟踪最新实际尺寸（含拖动期间的逐 tick 值）；拖动
                    // 起手时的冻结基准从中读取，松手后下一次拖动才能拿到
                    // 已经更新过的起点。
                    restCanvasSize = newSize
                }
                .onChange(of: isSplitterResizing) { _, resizing in
                    splitterResizeFrozenCanvasSize = resizing ? restCanvasSize : nil
                }
        }
        .task(id: "\(project.canvas.backgroundSource):\(isEditorActive)") {
            let source = project.canvas.backgroundSource
            guard isEditorActive, loadedWallpaperSource != source else { return }
            guard let url = wallpaperURLResolver(source) else {
                resolvedWallpaperImage = nil
                resolvedWallpaperVideoURL = nil
                loadedWallpaperSource = source
                return
            }
            if source.isVideo {
                // Start preparing the movie immediately, while the selected
                // tile's cached first frame acts as a zero-wait poster. The
                // first live movie pixel replaces it inside the shared
                // renderer instead of exposing the old background or black.
                resolvedWallpaperImage = SystemWallpaperThumbnailLoader.cachedImage(
                    at: url
                )
                resolvedWallpaperVideoURL = url
                if resolvedWallpaperImage == nil {
                    let poster = await SystemWallpaperThumbnailLoader.image(
                        at: url,
                        isVideo: true
                    )
                    guard !Task.isCancelled else { return }
                    resolvedWallpaperImage = poster
                }
                loadedWallpaperSource = source
                return
            }

            resolvedWallpaperVideoURL = nil
            if case .systemImage = source {
                // System HEIC files are commonly 5K/6K and materially slower
                // to decode than bundled JPEGs. Reuse the visible tile now and
                // refine it with the original pixels in the background.
                if let poster = SystemWallpaperThumbnailLoader.cachedImage(at: url) {
                    resolvedWallpaperImage = poster
                } else if let poster = await SystemWallpaperThumbnailLoader.image(
                    at: url,
                    isVideo: false
                ) {
                    guard !Task.isCancelled else { return }
                    resolvedWallpaperImage = poster
                }
            }
            let image = await WallpaperFullImageLoader.image(at: url)
            guard !Task.isCancelled else { return }
            resolvedWallpaperImage = image
            loadedWallpaperSource = source
        }
        .task(id: "\(project.timeline.stickerClips.map(\.relativePath).sorted()):\(isEditorActive)") {
            guard isEditorActive else { return }
            let relativePaths = Set(project.timeline.stickerClips.map(\.relativePath))
            var images: [String: NSImage] = [:]
            images.reserveCapacity(relativePaths.count)
            for relativePath in relativePaths {
                guard let url = projectAssetURLResolver(relativePath) else { continue }
                if let cached = resolvedStickerImages[relativePath] {
                    images[relativePath] = cached
                } else {
                    let image = await WallpaperFullImageLoader.image(at: url)
                    guard !Task.isCancelled else { return }
                    if let image { images[relativePath] = image }
                }
            }
            guard !Task.isCancelled else { return }
            resolvedStickerImages = images
        }
        .onChange(of: playbackController.isPlaying) { _, isPlaying in
            if isPlaying {
                hoveredCanvasSelection = nil
            }
        }
        .onChange(of: editorStore.interaction?.selection) { _, selection in
            if selection != directCanvasManipulationSelection, isDirectCanvasManipulation {
                clearCanvasManipulationPresentation()
            }
        }
        .onChange(of: isEditorActive) { _, active in
            if !active { playbackPlanCache.invalidate() }
        }
        .onDisappear {
            playbackPlanCache.invalidate()
        }
    }

    @ViewBuilder
    private func canvasContent(
        liveCanvasSize: CGSize,
        rasterCanvasSize: CGSize,
        activeTick: EditorPlaybackRenderTick?,
        renderedFrame: CanvasRenderedFrame?,
        effectPrewarmPlans: [FrameRenderPlan],
        playbackPlanCacheHandle: EditorCanvasPlaybackPlanCache.Handle?
    ) -> some View {
        ZStack {
            // This opaque, static plate survives Metal/decoder retirement.
            // Sleep never exposes the workspace grid through the monitor.
            EditorTheme.sleepingMonitor
                .contentShape(Rectangle())
                .onTapGesture(perform: focusCanvas)

            monitorSurface(canvasSize: liveCanvasSize, activeTick: activeTick,
                renderedFrame: renderedFrame, effectPrewarmPlans: effectPrewarmPlans,
                playbackPlanCacheHandle: playbackPlanCacheHandle)
                .allowsHitTesting(false)

            if isCropping {
                cropEditor(canvasSize: liveCanvasSize, sourceAspect: sourceAspectRatio)
                    .transition(.identity)
            } else if let renderedFrame {
                if !isSplitterResizing && isEditorActive {
                    canvasEditingOverlays(renderedFrame: renderedFrame,
                        canvasSize: rasterCanvasSize, activeTick: activeTick)
                }
                if isEditorActive {
                    canvasManipulationFeedback(canvasSize: liveCanvasSize).zIndex(300)
                }
            }
        }
    }

    @ViewBuilder
    private func monitorSurface(canvasSize: CGSize, activeTick: EditorPlaybackRenderTick?,
        renderedFrame: CanvasRenderedFrame?, effectPrewarmPlans: [FrameRenderPlan],
        playbackPlanCacheHandle: EditorCanvasPlaybackPlanCache.Handle?) -> some View {
        let sourceSize = aspectFittedSize(aspectRatio: sourceAspectRatio,
            inside: CGSize(width: max(canvasSize.width - 36, 2), height: max(canvasSize.height - 36, 2)))
        let cropFrame: SharedPreviewPlaybackFrame? = isCropping ? cropSourceFrameCache.frame(
            normalizedProject: cropSourceProject(), size: sourceSize, sourceAspect: sourceAspectRatio
        ) { cropSourceFrame(project: cropSourceProject(), size: sourceSize, sourceAspect: sourceAspectRatio) } : nil
        if let plan = cropFrame?.renderPlan ?? renderedFrame?.layout.renderPlan,
           let scene = cropFrame?.semanticScene ?? renderedFrame?.layout.rasterFrameScene {
            let provider: SharedPreviewPlaybackFrameProvider = { tick in
                if let cropFrame { return cropFrame }
                guard let layout = renderedFrame?.layout else { return SharedPreviewPlaybackFrame(renderPlan: plan, semanticScene: scene) }
                return makePlaybackFrameProvider(evaluation: layout.playbackEvaluation,
                    cacheHandle: playbackPlanCacheHandle)(tick)
            }
            SharedRenderedPreviewView(
                presentationMode: isCropping ? 1 : 0,
                screenOutput: playbackController.endpoints?.screenOutput,
                screenPreferredTransform: playbackController.endpoints?.screenPreferredTransform ?? .identity,
                cameraOutput: playbackController.endpoints?.cameraOutput,
                cameraPreferredTransform: playbackController.endpoints?.cameraPreferredTransform ?? .identity,
                cameraContentCrop: mediaSession.cameraContentCrop,
                renderTick: activeTick,
                usesPausedFrame: !playbackController.isPlaying && playbackController.hoverPreviewTime == nil,
                renderPlan: plan, semanticScene: scene,
                effectPrewarmPlans: isCropping ? [] : effectPrewarmPlans,
                pausedScreenImage: playbackController.pausedScreenImage,
                pausedCameraImage: playbackController.pausedCameraImage,
                wallpaperImage: isCropping ? nil : resolvedWallpaperImage,
                wallpaperVideoURL: isCropping ? nil : resolvedWallpaperVideoURL,
                stickerImages: isCropping ? [:] : resolvedStickerImages,
                suppressCameraContent: isCropping || cameraCompositorSuppressed,
                suppressScreenContent: !isCropping && screenCompositorSuppressed,
                playbackController: playbackController, playbackFrameProvider: provider,
                onCameraContentApplied: clearCameraDragPreviewIfIdle,
                onScreenContentApplied: clearScreenDragPreviewIfIdle
            )
            .frame(width: isCropping ? sourceSize.width : canvasSize.width,
                   height: isCropping ? sourceSize.height : canvasSize.height)
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private func focusCanvas() {
        guard !isCropping else { return }
        onCanvasFocused()
        editorStore.selection = .canvas
    }

    @ViewBuilder
    private func canvasEditingOverlays(
        renderedFrame: CanvasRenderedFrame,
        canvasSize: CGSize,
        activeTick: EditorPlaybackRenderTick?
    ) -> some View {
        let layout = renderedFrame.layout
        let showsEditingOverlays = CanvasPreviewInteractionPolicy.showsEditingOverlays(
            isPlaying: playbackController.isPlaying
        )

        screenSelectionTarget(
            scene: layout.frameScene.screen,
            canvasSize: canvasSize
        )
        .accessibilityHidden(isScreenSelectionActive)

        if showsEditingOverlays,
           case .screen = editScope,
           let contentPosition = editScope.position(in: project),
           let contentScale = editScope.scale(in: project) {
            screenInteractionOverlay(
                scene: layout.frameScene.screen,
                canvasSize: canvasSize,
                contentPosition: contentPosition,
                contentScale: contentScale,
                scope: editScope
            )
            .transaction { $0.animation = nil }
        }

        if showsEditingOverlays {
            mosaicSelectionTargets(
                scene: layout.frameScene,
                canvasSize: canvasSize,
                time: renderedFrame.playbackTime
            )
            // Selection chrome stays above the camera's hit surface when the
            // two overlap; this does not change their rendered pixel order.
            .zIndex({
                if case .mosaic = editorStore.selection { return 150.0 }
                return 0.0
            }())
        }

        if showsEditingOverlays,
           hasCameraTrack,
           !project.camera.isHidden,
           let cameraEvaluation = layout.scene.camera {
            cameraInteractionOverlay(
                in: canvasSize,
                evaluation: cameraEvaluation,
                isAvailable: activeTick?.cameraIsAvailable == true,
                scope: cameraInteractionScope,
                dragPreviewImage: cameraDragPreviewImage
            )
        }

        if showsEditingOverlays,
           case let .screenMotion(id) = editorStore.selection,
           let clip = project.timeline.screenMotionClips.first(where: { $0.id == id }),
           let effect = clip.focusEffect {
            EditorLinearFocusCanvasOverlay(editorStore: editorStore, clipID: id,
                effect: effect, screen: layout.frameScene.screen,
                sourceAspect: sourceAspectRatio, canvasSize: canvasSize,
                onError: onError)
                .id(id).zIndex(250)
        }

        if showsEditingOverlays {
            frontOverlaySelectionTargets(
                scene: layout.frameScene,
                canvasSize: canvasSize,
                time: renderedFrame.playbackTime
            )
            if !isDirectCanvasManipulation {
                overlayQuickEditor(
                    scene: layout.frameScene,
                    canvasSize: canvasSize,
                    time: renderedFrame.playbackTime
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
                .zIndex(200)
            }
        }
    }

    func screenSelectionTarget(
        scene: FrameScreenScene,
        canvasSize: CGSize
    ) -> some View {
        let selection = EditorSelection.screen
        let shape = ProjectedScreenShape(quad: scene.projectedQuad)
        let chrome = isScreenSelectionActive
            ? CanvasObjectInteractionChrome(phase: .idle)
            : canvasObjectChrome(for: selection, isSelected: false)
        return shape
        .fill(chrome.fillColor)
        .contentShape(shape)
        .overlay {
            if chrome.showsOutline {
                shape.stroke(chrome.strokeColor, lineWidth: chrome.lineWidth)
            }
        }
        .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
        .frame(width: canvasSize.width, height: canvasSize.height)
        .onTapGesture {
            onCanvasFocused()
            editorStore.selection = selection
        }
        .onHover {
            updateCanvasHover(selection, hovering: $0)
        }
        .accessibilityLabel("屏幕素材")
        .accessibilityHint("点击以选择屏幕")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            editorStore.selection = selection
        }
    }

    func cropEditor(canvasSize: CGSize, sourceAspect: CGFloat) -> some View {
        let available = CGSize(
            width: max(canvasSize.width - 36, 2),
            height: max(canvasSize.height - 36, 2)
        )
        let sourceSize = aspectFittedSize(aspectRatio: sourceAspect, inside: available)
        let sourceOrigin = CGPoint(
            x: (canvasSize.width - sourceSize.width) / 2,
            y: (canvasSize.height - sourceSize.height) / 2
        )
        let crop = cropDraft.clamped()
        let selectionRect = CGRect(
            x: sourceOrigin.x + CGFloat(crop.x) * sourceSize.width,
            y: sourceOrigin.y + CGFloat(crop.y) * sourceSize.height,
            width: CGFloat(crop.width) * sourceSize.width,
            height: CGFloat(crop.height) * sourceSize.height
        )
        return ZStack(alignment: .topLeading) {
            cropDimming(sourceOrigin: sourceOrigin, sourceSize: sourceSize, selection: selectionRect)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.clear)
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(.white.opacity(0.96), lineWidth: 1.5)
                )
                .frame(width: selectionRect.width, height: selectionRect.height)
                .position(x: selectionRect.midX, y: selectionRect.midY)
                .gesture(cropMoveGesture(sourceSize: sourceSize))
                // Canvas dragging remains the direct-manipulation path. The
                // four named pixel steppers in the inspector are the precise
                // keyboard/VoiceOver path, so this mouse-only layer must not
                // become an inert accessibility stop.
                .accessibilityHidden(true)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                cropHandle(handle, in: selectionRect, sourceSize: sourceSize)
            }

            Text("拖动边缘或四角裁切 · Esc 取消")
                .font(.appUI(.caption, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(.black.opacity(0.76), in: Capsule())
                .position(x: canvasSize.width / 2, y: canvasSize.height - 24)
                .allowsHitTesting(false)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    func cropSourceProject() -> RecorderProject {
        var cropProject = project
        cropProject.canvas = CanvasStyle(
            aspectRatio: .adaptive,
            backgroundSource: .safeFallback,
            padding: 0,
            contentScale: 1,
            contentPosition: NormalizedPoint(x: 0.5, y: 0.5),
            crop: .full,
            cornerRadius: 0,
            borderWidth: 0,
            borderColor: .black,
            shadowStrength: 0,
            backgroundBlur: 0,
            insetOpacity: 0
        )
        cropProject.zoomAnimations = []
        cropProject.timeline.screenMotionClips = []
        cropProject.timeline.cameraMotionClips = []
        cropProject.timeline.mosaicClips = []
        cropProject.timeline.stickerClips = []
        cropProject.openingSequence.isEnabled = false
        cropProject.camera.isHidden = true
        cropProject.cursorStyle.assetID = .hidden
        return cropProject
    }

    func cropSourceScene(
        project cropProject: RecorderProject,
        size: CGSize,
        sourceAspect: CGFloat
    ) -> FrameScene {
        return FrameSceneEvaluator.scene(
            project: cropProject,
            time: 0,
            canvasSize: CompositionSize(
                width: Double(size.width),
                height: Double(size.height)
            ),
            sourceAspectRatio: Double(sourceAspect),
            pointerEvaluation: PointerTrackEvaluation(position: nil, cursor: nil),
            cursorMetrics: nil,
            zoomTrack: ZoomAnimationTrack([])
        )
    }

    func cropSourceFrame(
        project cropProject: RecorderProject,
        size: CGSize,
        sourceAspect: CGFloat
    ) -> SharedPreviewPlaybackFrame {
        let scene = cropSourceScene(
            project: cropProject,
            size: size,
            sourceAspect: sourceAspect
        )
        return SharedPreviewPlaybackFrame(
            renderPlan: FrameRenderPlan(
                presentationTime: scene.time,
                outputDuration: 0,
                frameRate: cropProject.exportSettings.frameRate.rawValue,
                scene: scene
            ),
            semanticScene: scene
        )
    }

    func cropDimming(
        sourceOrigin: CGPoint,
        sourceSize: CGSize,
        selection: CGRect
    ) -> some View {
        let sourceMaxX = sourceOrigin.x + sourceSize.width
        let sourceMaxY = sourceOrigin.y + sourceSize.height
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.57)
                .frame(width: sourceSize.width, height: max(selection.minY - sourceOrigin.y, 0))
                .position(
                    x: sourceOrigin.x + sourceSize.width / 2,
                    y: sourceOrigin.y + max(selection.minY - sourceOrigin.y, 0) / 2
                )
            Color.black.opacity(0.57)
                .frame(width: sourceSize.width, height: max(sourceMaxY - selection.maxY, 0))
                .position(
                    x: sourceOrigin.x + sourceSize.width / 2,
                    y: selection.maxY + max(sourceMaxY - selection.maxY, 0) / 2
                )
            Color.black.opacity(0.57)
                .frame(width: max(selection.minX - sourceOrigin.x, 0), height: selection.height)
                .position(
                    x: sourceOrigin.x + max(selection.minX - sourceOrigin.x, 0) / 2,
                    y: selection.midY
                )
            Color.black.opacity(0.57)
                .frame(width: max(sourceMaxX - selection.maxX, 0), height: selection.height)
                .position(
                    x: selection.maxX + max(sourceMaxX - selection.maxX, 0) / 2,
                    y: selection.midY
                )
        }
        .allowsHitTesting(false)
    }

    func cropHandle(
        _ handle: CropHandle,
        in rect: CGRect,
        sourceSize: CGSize
    ) -> some View {
        let position = cropHandlePosition(handle, in: rect)
        return ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(EditorTheme.mediaAccent, lineWidth: 1.5))
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(position)
            .highPriorityGesture(cropResizeGesture(handle: handle, sourceSize: sourceSize))
            .accessibilityHidden(true)
    }

    func cropHandlePosition(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    func cropMoveGesture(sourceSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cropDragOrigin == nil { cropDragOrigin = cropDraft.clamped() }
                guard let origin = cropDragOrigin else { return }
                let x = min(
                    max(origin.x + Double(value.translation.width / max(sourceSize.width, 1)), 0),
                    1 - origin.width
                )
                let y = min(
                    max(origin.y + Double(value.translation.height / max(sourceSize.height, 1)), 0),
                    1 - origin.height
                )
                cropDraft = NormalizedCrop(x: x, y: y, width: origin.width, height: origin.height)
            }
            .onEnded { _ in cropDragOrigin = nil }
    }

    func cropResizeGesture(handle: CropHandle, sourceSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if cropDragOrigin == nil { cropDragOrigin = cropDraft.clamped() }
                guard let origin = cropDragOrigin else { return }
                let dx = Double(value.translation.width / max(sourceSize.width, 1))
                let dy = Double(value.translation.height / max(sourceSize.height, 1))
                cropDraft = resizedCrop(origin, handle: handle, dx: dx, dy: dy)
            }
            .onEnded { _ in cropDragOrigin = nil }
    }

    func resizedCrop(
        _ origin: NormalizedCrop,
        handle: CropHandle,
        dx: Double,
        dy: Double
    ) -> NormalizedCrop {
        let minimumWidth = max(24 / max(Double(sourcePixelSize.width), 1), 0.02)
        let minimumHeight = max(24 / max(Double(sourcePixelSize.height), 1), 0.02)
        var left = origin.x
        var right = origin.x + origin.width
        var top = origin.y
        var bottom = origin.y + origin.height

        switch handle {
        case .topLeft:
            left = min(max(left + dx, 0), right - minimumWidth)
            top = min(max(top + dy, 0), bottom - minimumHeight)
        case .top:
            top = min(max(top + dy, 0), bottom - minimumHeight)
        case .topRight:
            right = max(min(right + dx, 1), left + minimumWidth)
            top = min(max(top + dy, 0), bottom - minimumHeight)
        case .right:
            right = max(min(right + dx, 1), left + minimumWidth)
        case .bottomRight:
            right = max(min(right + dx, 1), left + minimumWidth)
            bottom = max(min(bottom + dy, 1), top + minimumHeight)
        case .bottom:
            bottom = max(min(bottom + dy, 1), top + minimumHeight)
        case .bottomLeft:
            left = min(max(left + dx, 0), right - minimumWidth)
            bottom = max(min(bottom + dy, 1), top + minimumHeight)
        case .left:
            left = min(max(left + dx, 0), right - minimumWidth)
        }

        return NormalizedCrop(x: left, y: top, width: right - left, height: bottom - top).clamped()
    }

    func aspectFittedSize(aspectRatio: CGFloat, inside bounds: CGSize) -> CGSize {
        let safeAspect = max(aspectRatio, 0.01)
        if bounds.width / max(bounds.height, 1) > safeAspect {
            return CGSize(width: bounds.height * safeAspect, height: bounds.height)
        }
        return CGSize(width: bounds.width, height: bounds.width / safeAspect)
    }

    func screenInteractionOverlay(
        scene: FrameScreenScene,
        canvasSize: CGSize,
        contentPosition: NormalizedPoint,
        contentScale: Double,
        scope: EditorCanvasEditScope
    ) -> some View {
        let quad = scene.projectedQuad
        let shape = ProjectedScreenShape(quad: quad)
        let handle = quad.resizeHandlePoint
        let bounds = quad.bounds
        let scaleReference = max(min(scene.finalRect.width, scene.finalRect.height), 1)
        let selection = scope.selection ?? .screen
        let chrome = canvasObjectChrome(for: selection, isSelected: true)
        let isResizing = screenScaleOrigin != nil

        return ZStack(alignment: .topLeading) {
            if let screenDragPreviewImage {
                // 拖动期间由覆盖层直接绘制屏幕内容：与命中形状同一坐标系，零滞后。
                Image(nsImage: screenDragPreviewImage)
                    .resizable()
                    .frame(width: CGFloat(bounds.width), height: CGFloat(bounds.height))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: CGFloat(scene.cornerRadius),
                            style: .continuous
                        )
                    )
                    .position(x: CGFloat(bounds.midX), y: CGFloat(bounds.midY))
                    .allowsHitTesting(false)
            }
            shape
                .fill(chrome.fillColor)
                .contentShape(shape)
                .overlay {
                    shape.stroke(chrome.strokeColor, lineWidth: chrome.lineWidth)
                }
                .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if screenDragOrigin == nil {
                                guard editorStore.beginCanvasInteraction(
                                    scope: scope,
                                    operation: .move
                                ) else { return }
                                screenDragOrigin = contentPosition
                                screenDragScope = scope
                                screenDragPreviewImage = pausedScreenDragImage(
                                    scope: scope,
                                    scene: scene,
                                    canvasSize: canvasSize
                                )
                                screenCompositorSuppressed = screenDragPreviewImage != nil
                                // 摄像头也改由覆盖层绘制（位于屏幕预览之上），
                                // 否则屏幕预览会盖住合成帧里的摄像头，层级错乱。
                                if screenCompositorSuppressed {
                                    cameraDragPreviewImage = pausedCameraDragImage(
                                        canvasSize: canvasSize
                                    )
                                    cameraCompositorSuppressed = cameraDragPreviewImage != nil
                                }
                            }
                            guard let origin = screenDragOrigin,
                                  let interactionScope = screenDragScope else { return }
                            // 与 CompositionScene 统一语义（内容的几分之几对齐画布
                            // 的几分之几）配套：像素位移按 offset 对 pos 的导数
                            // （画布尺寸 − 内容尺寸）换算；放大时为负值——抓取内容
                            // 右拖等于可见区域左移，始终跟手。
                            let xTravel = abs(canvasSize.width - CGFloat(scene.baseRect.width)) < 1
                                ? 1
                                : canvasSize.width - CGFloat(scene.baseRect.width)
                            let yTravel = abs(canvasSize.height - CGFloat(scene.baseRect.height)) < 1
                                ? 1
                                : canvasSize.height - CGFloat(scene.baseRect.height)
                            let proposed = NormalizedPoint(
                                x: min(max(origin.x + Double(value.translation.width / xTravel), 0), 1),
                                y: min(max(origin.y + Double(value.translation.height / yTravel), 0), 1)
                            )
                            // 屏幕素材吸附画布中心
                            let snapped = CanvasSnapMath.snapped(
                                proposed,
                                anchorsX: [0.5],
                                anchorsY: [0.5],
                                thresholdX: CanvasSnapMath.normalizedThreshold(
                                    along: xTravel
                                ),
                                thresholdY: CanvasSnapMath.normalizedThreshold(
                                    along: yTravel
                                )
                            )
                            canvasSnapGuideX = snapped.guideX
                            canvasSnapGuideY = snapped.guideY
                            editorStore.updateCanvasPosition(
                                snapped.point,
                                scope: interactionScope
                            )
                        }
                        .onEnded { _ in
                            if screenDragOrigin != nil {
                                commitCanvasInteraction(
                                    actionName: scope == .screen(.base)
                                        ? "移动屏幕素材"
                                        : "调整屏幕 3D 位置"
                                )
                            }
                            screenDragOrigin = nil
                            screenDragScope = nil
                            screenCompositorSuppressed = false
                            cameraCompositorSuppressed = false
                            scheduleScreenDragPreviewClear()
                            scheduleCameraDragPreviewClear()
                            canvasSnapGuideX = nil
                            canvasSnapGuideY = nil
                        }
                )
                .onHover {
                    updateCanvasHover(selection, hovering: $0)
                }
                .accessibilityLabel("屏幕素材")
                .accessibilityHint("拖动以移动素材")
                .accessibilityValue(
                    "水平 \(Int(contentPosition.x * 100))%，垂直 \(Int(contentPosition.y * 100))%"
                )
                .accessibilityAddTraits([.isButton, .isSelected])
                .accessibilityAction {
                    if let selection = scope.selection {
                        editorStore.selection = selection
                    }
                }

            ZStack {
                Circle()
                    .fill(EditorTheme.mediaAccent)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .frame(width: 16, height: 16)
                    .shadow(
                        color: isResizing
                            ? EditorTheme.mediaAccent.opacity(0.34)
                            : .black.opacity(0.45),
                        radius: isResizing ? 6 : 3,
                        y: isResizing ? 0 : 1
                    )
            }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .position(x: CGFloat(handle.x), y: CGFloat(handle.y))
                .scaleEffect(isResizing ? 1.08 : 1)
                .animation(SpringMotion.interactive, value: isResizing)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if screenScaleOrigin == nil {
                                guard editorStore.beginCanvasInteraction(
                                    scope: scope,
                                    operation: .resize
                                ) else { return }
                                screenScaleOrigin = contentScale
                                screenScaleScope = scope
                                screenDragPreviewImage = pausedScreenDragImage(
                                    scope: scope,
                                    scene: scene,
                                    canvasSize: canvasSize
                                )
                                screenCompositorSuppressed = screenDragPreviewImage != nil
                                if screenCompositorSuppressed {
                                    cameraDragPreviewImage = pausedCameraDragImage(
                                        canvasSize: canvasSize
                                    )
                                    cameraCompositorSuppressed = cameraDragPreviewImage != nil
                                }
                            }
                            guard let origin = screenScaleOrigin,
                                  let interactionScope = screenScaleScope else { return }
                            let delta = quad.semanticResizeDelta(
                                translation: CompositionPoint(
                                    x: Double(value.translation.width),
                                    y: Double(value.translation.height)
                                ),
                                referenceLength: scaleReference
                            )
                            let limits = scope == .screen(.base)
                                ? 0.7...2.2
                                : 0.25...4
                            editorStore.updateCanvasScale(
                                min(
                                    max(origin + delta * 1.35, limits.lowerBound),
                                    limits.upperBound
                                ),
                                scope: interactionScope
                            )
                        }
                        .onEnded { _ in
                            if screenScaleOrigin != nil {
                                commitCanvasInteraction(
                                    actionName: scope == .screen(.base)
                                        ? "缩放屏幕素材"
                                        : "调整屏幕 3D 大小"
                                )
                            }
                            screenScaleOrigin = nil
                            screenScaleScope = nil
                            screenCompositorSuppressed = false
                            cameraCompositorSuppressed = false
                            scheduleScreenDragPreviewClear()
                            scheduleCameraDragPreviewClear()
                        }
                )
                .accessibilityHidden(true)

        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    @ViewBuilder
    func cameraInteractionOverlay(
        in size: CGSize,
        evaluation: CameraSceneEvaluation,
        isAvailable: Bool,
        scope: EditorCanvasEditScope,
        dragPreviewImage: NSImage?
    ) -> some View {
        let effectiveSize = scope.scale(in: project) ?? project.camera.size
        let effectivePosition = scope.position(in: project) ?? project.camera.position
        let isSelected: Bool = {
            if case .camera = editScope { return true }
            return false
        }()
        let selection = scope.selection ?? .camera
        let chrome = canvasObjectChrome(for: selection, isSelected: isSelected)
        let isResizing = cameraSizeOrigin != nil
        let base = min(size.width, size.height)
        let width = CGFloat(evaluation.rect.width)
        let height = CGFloat(evaluation.rect.height)
        let x = CGFloat(evaluation.rect.midX) - size.width / 2
        let y = CGFloat(evaluation.rect.midY) - size.height / 2
        let cameraBorderWidth = CGFloat(evaluation.borderWidth)
        let cameraOuterSize = CGSize(
            width: width + cameraBorderWidth * 2,
            height: height + cameraBorderWidth * 2
        )
        let cameraOuterRadius = CGFloat(evaluation.cornerRadius) + cameraBorderWidth

        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cameraOuterRadius, style: .continuous)
                .fill(chrome.fillColor)
            .frame(width: cameraOuterSize.width, height: cameraOuterSize.height)
            .overlay {
                if let dragPreviewImage {
                    // 拖动期间由覆盖层直接绘制摄像头内容：与选择框同一坐标系，
                    // 零滞后；合成帧此时不含摄像头层（suppressCameraContent）。
                    Image(nsImage: dragPreviewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: CGFloat(evaluation.cornerRadius),
                                style: .continuous
                            )
                        )
                        .overlay {
                            if cameraBorderWidth > 0.5 {
                                RoundedRectangle(
                                    cornerRadius: CGFloat(evaluation.cornerRadius),
                                    style: .continuous
                                )
                                .stroke(.white, lineWidth: cameraBorderWidth)
                            }
                        }
                        .frame(width: cameraOuterSize.width, height: cameraOuterSize.height)
                        .allowsHitTesting(false)
                }
                if chrome.showsOutline {
                    RoundedRectangle(cornerRadius: cameraOuterRadius, style: .continuous)
                        .stroke(chrome.strokeColor, lineWidth: chrome.lineWidth)
                }
            }
            .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
            .contentShape(RoundedRectangle(cornerRadius: cameraOuterRadius, style: .continuous))
            .gesture(
                // 必须用全局坐标系：覆盖层本身会跟随拖动移动，局部坐标系会随视图
                // 一起动，translation 被自身移动污染形成正反馈振荡（拖得越远越抖）。
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard cameraSizeOrigin == nil else { return }
                        if cameraDragOrigin == nil {
                            guard editorStore.beginCanvasInteraction(
                                scope: scope,
                                operation: .move
                            ) else { return }
                            cameraDragOrigin = effectivePosition
                            cameraDragScope = scope
                            cameraDragPreviewImage = pausedCameraDragImage(
                                canvasSize: size
                            )
                            cameraCompositorSuppressed = cameraDragPreviewImage != nil
                        }
                        guard let origin = cameraDragOrigin,
                              let interactionScope = cameraDragScope else { return }
                        let proposed = NormalizedPoint(
                            x: min(
                                max(
                                    origin.x
                                        + Double(value.translation.width / max(size.width - width, 1)),
                                    0
                                ),
                                1
                            ),
                            y: min(
                                max(
                                    origin.y
                                        + Double(value.translation.height / max(size.height - height, 1)),
                                    0
                                ),
                                1
                            )
                        )
                        // 摄像头吸附画布中心与四边停靠位
                        let snapped = CanvasSnapMath.snapped(
                            proposed,
                            anchorsX: [0, 0.5, 1],
                            anchorsY: [0, 0.5, 1],
                            thresholdX: CanvasSnapMath.normalizedThreshold(
                                along: size.width - width
                            ),
                            thresholdY: CanvasSnapMath.normalizedThreshold(
                                along: size.height - height
                            )
                        )
                        canvasSnapGuideX = snapped.guideX
                        canvasSnapGuideY = snapped.guideY
                        editorStore.updateCanvasPosition(
                            snapped.point,
                            scope: interactionScope
                        )
                    }
                    .onEnded { _ in
                        if cameraDragOrigin != nil {
                            commitCanvasInteraction(
                                actionName: scope == .camera(.base)
                                    ? "移动摄像头"
                                    : "调整摄像运动位置"
                            )
                        }
                        cameraDragOrigin = nil
                        cameraDragScope = nil
                        // 立刻让合成帧带摄像头重渲染；覆盖图保留到落地回调或超时兜底
                        cameraCompositorSuppressed = false
                        scheduleCameraDragPreviewClear()
                        canvasSnapGuideX = nil
                        canvasSnapGuideY = nil
                    }
            )
            .onHover {
                updateCanvasHover(selection, hovering: $0)
            }
            .accessibilityLabel("摄像头画面")
            .accessibilityHint("拖动以移动，拖右下角圆点调整大小")
            .accessibilityValue(
                "水平 \(Int(effectivePosition.x * 100))%，"
                    + "垂直 \(Int(effectivePosition.y * 100))%，"
                    + "大小 \(Int(effectiveSize * 100))%"
            )
            .accessibilityAddTraits(
                isSelected ? [.isButton, .isSelected] : .isButton
            )
            .accessibilityAction {
                if let selection = scope.selection {
                    editorStore.selection = selection
                }
            }

            if isSelected {
                ZStack {
                    Circle()
                        .fill(EditorTheme.mediaAccent)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                        .shadow(
                            color: isResizing
                                ? EditorTheme.mediaAccent.opacity(0.34)
                                : .black.opacity(0.45),
                            radius: isResizing ? 6 : 3,
                            y: isResizing ? 0 : 1
                        )
                }
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .offset(x: 15, y: 15)
                    .scaleEffect(isResizing ? 1.08 : 1)
                    .animation(SpringMotion.interactive, value: isResizing)
                    .gesture(
                        // 同摄像头拖动：把手随视图移动，必须全局坐标系避免振荡。
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                cameraDragOrigin = nil
                                cameraDragScope = nil
                                if cameraSizeOrigin == nil {
                                    guard editorStore.beginCanvasInteraction(
                                        scope: scope,
                                        operation: .resize
                                    ) else { return }
                                    cameraSizeOrigin = effectiveSize
                                    cameraSizeScope = scope
                                    cameraDragPreviewImage = pausedCameraDragImage(
                                        canvasSize: size
                                    )
                                    cameraCompositorSuppressed = cameraDragPreviewImage != nil
                                }
                                guard let origin = cameraSizeOrigin,
                                      let interactionScope = cameraSizeScope else { return }
                                let delta = Double(
                                    (value.translation.width + value.translation.height)
                                        / max(base, 1)
                                )
                                let limits = scope == .camera(.base)
                                    ? 0.05...0.8
                                    : 0.05...1
                                editorStore.updateCanvasScale(
                                    min(max(origin + delta * 1.2, limits.lowerBound), limits.upperBound),
                                    scope: interactionScope
                                )
                            }
                            .onEnded { _ in
                                if cameraSizeOrigin != nil {
                                    commitCanvasInteraction(
                                        actionName: scope == .camera(.base)
                                            ? "调整摄像头大小"
                                            : "调整摄像运动大小"
                                    )
                                }
                                cameraSizeOrigin = nil
                                cameraSizeScope = nil
                                cameraCompositorSuppressed = false
                                scheduleCameraDragPreviewClear()
                            }
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(width: cameraOuterSize.width, height: cameraOuterSize.height)
        .offset(x: x, y: y)
        .opacity(isAvailable ? evaluation.opacity : 0)
        // 摄像头不可用/隐藏的时间段：透明 overlay 不得继续拦截画布拖拽与点选。
        .allowsHitTesting(isAvailable)
    }

    private func clearCameraDragPreviewIfIdle() {
        // 合成帧已带着摄像头内容落地，覆盖图可以退出了。
        guard cameraDragOrigin == nil else { return }
        guard cameraSizeOrigin == nil else { return }
        cameraDragPreviewImage = nil
    }

    private func clearScreenDragPreviewIfIdle() {
        guard screenDragOrigin == nil else { return }
        guard screenScaleOrigin == nil else { return }
        screenDragPreviewImage = nil
    }

    private func makePlaybackFrameProvider(
        evaluation: CanvasPlaybackEvaluationContext,
        cacheHandle: EditorCanvasPlaybackPlanCache.Handle?
    ) -> SharedPreviewPlaybackFrameProvider {
        { tick in
            if let cacheHandle,
               let cached = playbackPlanCache.frame(
                   at: tick.outputTime,
                   handle: cacheHandle
               ) {
                return evaluation.refreshingCursor(in: cached, at: tick.outputTime)
            }
            return evaluation.playbackFrame(at: tick.outputTime)
        }
    }

    private func makeRenderedFrame(
        canvasSize: CGSize,
        activeTick: EditorPlaybackRenderTick?
    ) -> CanvasRenderedFrame? {
        // Crop mode owns a separate, deliberately flat source-only renderer.
        guard !isCropping else { return nil }
        let renderScale = previewRenderScale(for: canvasSize)
        let playbackTracks = playbackTrackCache.tracks(for: project, outputDuration: mediaSession.outputDuration)
        let playbackTime = interactionPreviewTime()
            ?? activeTick?.outputTime
            ?? playbackController.outputTime
        let layout = previewLayout(
            canvasSize: canvasSize,
            renderScale: renderScale,
            playbackTime: playbackTime,
            tracks: playbackTracks
        )
        return CanvasRenderedFrame(playbackTime: playbackTime, layout: layout)
    }

    private func interactionPreviewTime() -> TimeInterval? {
        guard let selection = editorStore.interaction?.selection else { return nil }
        switch selection {
        case let .cameraMotion(id):
            guard let clip = project.timeline.cameraMotionClips.first(where: { $0.id == id }) else {
                return nil
            }
            return clip.timing.endTime - 0.001
        case let .screenMotion(id):
            guard let clip = project.timeline.screenMotionClips.first(where: { $0.id == id }) else {
                return nil
            }
            return clip.timing.endTime - 0.001
        // Overlays are manipulated on the frame the user is already viewing.
        case .mosaic, .sticker:
            return nil
        default:
            return nil
        }
    }

    private func makeEffectPrewarmPlans(
        for renderedFrame: CanvasRenderedFrame?
    ) -> [FrameRenderPlan] {
        guard !playbackController.isPlaying,
              editorStore.interaction == nil,
              !isCropping,
              let renderedFrame else { return [] }
        return effectPrewarmPlanCache.plans(
            around: renderedFrame.playbackTime,
            using: renderedFrame.layout.playbackEvaluation
        )
    }

}
