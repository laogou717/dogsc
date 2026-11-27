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
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @StateObject private var sleepPresentation = EditorCanvasSleepPresentation()
    @State private var loadedWallpaperSource: BackgroundSource?
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    @ObservedObject var motionElementEditor = MotionElementEditor.shared
    @ObservedObject private var frameClock: EditorPlaybackFrameClock
    @ObservedObject private var timelinePreview: EditorTimelineInteractionState
    private let baseRenderProject: RecorderProject
    var renderProject: RecorderProject {
        var result = timelinePreview.project(for: editorStore.interaction?.id) ?? baseRenderProject
        if let transientAspectRatio, !isCropping {
            result.canvas.aspectRatio = .custom
            result.canvas.customAspectRatio = .init(width: Double(transientAspectRatio), height: 1)
        }
        return result
    }
    /// Non-nil only while the stage morphs between two aspect ratios: the
    /// preview renders `renderProject` with this transient custom ratio.
    /// Preview-only; the project and undo history never see it.
    let transientAspectRatio: CGFloat?
    @Binding var previewResolutionMode: EditorPreviewResolutionMode
    let isCropping: Bool
    /// Export thumbnails contain project pixels, never editor selection chrome.
    let showsEditingControls: Bool
    /// PRE-033: 时间线分栏拖动进行中。拖动期间预览栅格保持拖动起始尺寸
    /// 冻结，视图本身实时跟随新区域拉伸既有 drawable，松手后一次性按最终
    /// 尺寸重评估——避免每个拖动 tick 都全尺寸重渲染并抖动 drawable 池。
    let isSplitterResizing: Bool
    @Binding var cropDraft: NormalizedCrop
    let wallpaperURLResolver: EditorSessionContext.WallpaperURLResolver
    let assetRootURL: URL?
    let projectAssetURLResolver: EditorSessionContext.ProjectAssetURLResolver
    let onCanvasFocused: () -> Void
    let onError: (String) -> Void
    @State var resolvedSceneWallpapers: [String: EditorSceneWallpaper] = [:]
    @State var resolvedWallpaperImage: NSImage?
    @State var resolvedWallpaperVideoURL: URL?
    @State var resolvedStickerImages: [String: NSImage] = [:]
    @State var quickEditorMeasuredWidths: [String: CGFloat] = [:]
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
    /// The 3D gizmo's drag: the screen-motion clip and its pose at press.
    @State var screenTiltOrigin: (id: UUID, x: Double, y: Double)?
    @State var isScreenTiltGizmoHovered = false
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
    @State var overlayPressPreviousSelection: EditorSelection?
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
        transientAspectRatio: CGFloat? = nil,
        previewResolutionMode: Binding<EditorPreviewResolutionMode>,
        isCropping: Bool,
        isSplitterResizing: Bool = false,
        showsEditingControls: Bool = true,
        cropDraft: Binding<NormalizedCrop>,
        wallpaperURLResolver: @escaping EditorSessionContext.WallpaperURLResolver,
        projectAssetURLResolver: @escaping EditorSessionContext.ProjectAssetURLResolver,
        assetRootURL: URL? = nil,
        onCanvasFocused: @escaping () -> Void = {},
        onError: @escaping (String) -> Void
    ) {
        self.editorStore = editorStore
        self.mediaSession = mediaSession
        self.playbackController = playbackController
        self.frameClock = playbackController.frameClock
        self.transientAspectRatio = transientAspectRatio
        self.baseRenderProject = renderProject
        _timelinePreview = ObservedObject(wrappedValue: editorStore.timelinePreview)
        _previewResolutionMode = previewResolutionMode
        self.isCropping = isCropping
        self.isSplitterResizing = isSplitterResizing
        self.showsEditingControls = showsEditingControls
        _cropDraft = cropDraft
        self.wallpaperURLResolver = wallpaperURLResolver
        self.projectAssetURLResolver = projectAssetURLResolver
        self.assetRootURL = assetRootURL
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
    var interactionSceneProject: RecorderProject {
        project.sceneProject(forSegmentID: project.timeline.recordingSegment(atOutputTime: playbackController.latestOutputTime)?.id)
    }

    var currentRecordingSourceID: UUID? {
        mediaSession.sourceID(at: playbackController.hoverPreviewTime ?? playbackController.outputTime)
    }
    var sourcePixelSize: CGSize {
        currentRecordingSourceID.flatMap { mediaSession.sourceDisplaySize(for: $0) } ?? mediaSession.primarySourceDisplaySize
    }

    var sourceAspectRatio: CGFloat {
        let safeHeight = max(sourcePixelSize.height, CGFloat(1))
        return max(sourcePixelSize.width / safeHeight, CGFloat(0.01))
    }

    var hasCameraTrack: Bool { currentRecordingSourceID.map { mediaSession.inventories(for: $0).camera.hasVideo } ?? false }

    var cameraSourceAspectRatio: CGFloat {
        guard let id = currentRecordingSourceID, let size = mediaSession.cameraDisplaySize(for: id),
              size.width > 0,
              size.height > 0 else { return 4.0 / 3.0 }
        return size.width / size.height
    }

    var editScope: EditorCanvasEditScope {
        if case let .primarySegment(id) = editorStore.selection,
           id == insertedImageSegmentID {
            return .screen(.base)
        }
        return EditorCanvasEditScope(selection: editorStore.selection)
    }

    var insertedImageSegmentID: UUID? {
        let segment = project.timeline.recordingSegment(atOutputTime: playbackController.latestOutputTime)
        return segment?.media?.imagePath != nil ? segment?.id : nil
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
                // A shape morph re-evaluates every display frame; prewarming
                // and plan caching for a ratio that lives 16 ms would only
                // compete with the visible frame.
                let isMorphing = transientAspectRatio != nil
                let effectPrewarmPlans = isEditorActive && !isMorphing ? makeEffectPrewarmPlans(for: renderedFrame) : []
                let playbackPlanCacheHandle = renderedFrame.flatMap {
                    playbackPlanCache.prepare(
                        around: playbackController.outputTime,
                        using: $0.layout.playbackEvaluation,
                        isPlaying: playbackController.isPlaying,
                        isInteracting: editorStore.interaction != nil || !isEditorActive || isMorphing
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
                    // While the window is in the background the live picture
                    // is retired to save power. The cover is a calm resting
                    // plate with one quiet note, not a grey veil.
                    EditorCanvasRestingCover(
                        image: sleepPresentation.isPresenting ? playbackController.pausedScreenImage : nil
                    )
                        .opacity(sleepPresentation.opacity)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(EditorTheme.chrome(0.08), lineWidth: 0.5))
                .overlay {
                    // Editing chrome belongs to the workspace, not the
                    // rendered monitor's pixel crop (especially in portrait).
                    if showsEditingControls && !isCropping && !isSplitterResizing
                        && isEditorActive && !isDirectCanvasManipulation,
                       let renderedFrame,
                       CanvasPreviewInteractionPolicy.showsEditingOverlays(
                        isPlaying: playbackController.isPlaying
                       ) {
                        overlayQuickEditor(
                            scene: renderedFrame.layout.frameScene,
                            canvasSize: rasterCanvasSize,
                            availableSize: geometry.size,
                            time: renderedFrame.playbackTime
                        )
                        .frame(width: liveCanvasSize.width, height: liveCanvasSize.height)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showsEditingControls {
                        RecordingSourceCanvasBadge(project: project, mediaSession: mediaSession,
                            playback: playbackController, isCropping: isCropping,
                            rename: editorStore.renameRecordingSource).padding(10)
                    }
                }
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
        .task(id: "\(project.sceneBackgroundSources):\(isEditorActive)") {
            if isEditorActive { await loadSceneWallpapers() }
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
        .onChange(of: elementEditingTarget, initial: true) { _, target in
            if let target { motionElementEditor.begin(target) } else { motionElementEditor.end() }
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
            sleepPresentation.invalidate()
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
            EditorCanvasRestingCover(showsNote: false)
                .contentShape(Rectangle())
                .onTapGesture(perform: focusCanvas)

            monitorSurface(canvasSize: liveCanvasSize, activeTick: activeTick,
                renderedFrame: renderedFrame, effectPrewarmPlans: effectPrewarmPlans,
                playbackPlanCacheHandle: playbackPlanCacheHandle)
                .allowsHitTesting(false)

            if showsEditingControls && isCropping {
                cropEditor(canvasSize: liveCanvasSize, sourceAspect: sourceAspectRatio)
                    .modifier(EditorCropReveal())
                    .transition(.identity)
            } else if showsEditingControls, let renderedFrame {
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
            normalizedProject: cropSourceProject(), size: sourceSize, sourceAspect: sourceAspectRatio,
            time: playbackController.latestOutputTime
        ) { cropSourceFrame(project: cropSourceProject(), size: sourceSize, sourceAspect: sourceAspectRatio) } : nil
        if let plan = cropFrame?.renderPlan ?? renderedFrame?.layout.renderPlan,
           let scene = cropFrame?.semanticScene ?? renderedFrame?.layout.rasterFrameScene {
            let normalProvider = renderedFrame.map {
                makePlaybackFrameProvider(evaluation: $0.layout.playbackEvaluation,
                                          cacheHandle: playbackPlanCacheHandle)
            }
            let provider: SharedPreviewPlaybackFrameProvider = { tick in
                if let cropFrame { return cropFrame }
                return normalProvider?(tick) ?? SharedPreviewPlaybackFrame(renderPlan: plan, semanticScene: scene)
            }
            SharedRenderedPreviewView(
                presentationMode: isCropping ? 1 : 0,
                assetRootURL: assetRootURL,
                motionStarts: project.timeline.animationClips.map { PreviewMotionStart(time: $0.timing.startTime) }
                    + (renderedFrame?.layout.playbackEvaluation.primaryPlan?.slices.compactMap { slice in
                        slice.media?.motionPath == nil ? nil : PreviewMotionStart(time: slice.outputStart, segmentID: slice.segmentID)
                    } ?? []),
                screenOutput: playbackController.endpoints?.screenOutput,
                cameraOutput: playbackController.endpoints?.cameraOutput,
                renderTick: activeTick,
                renderPlan: plan, semanticScene: scene,
                effectPrewarmPlans: isCropping ? [] : effectPrewarmPlans,
                pausedScreenImage: playbackController.pausedScreenSegmentID == activeTick?.sourceFrame?.screenSlice?.segmentID
                    ? playbackController.pausedScreenImage : nil,
                pausedCameraImage: playbackController.pausedCameraSourceID == activeTick?.sourceFrame?.cameraSlice?.sourceID
                    ? playbackController.pausedCameraImage : nil,
                wallpaperImage: isCropping ? nil : resolvedWallpaperImage,
                wallpaperVideoURL: isCropping ? nil : resolvedWallpaperVideoURL,
                sceneWallpapers: isCropping ? [:] : resolvedSceneWallpapers,
                defaultWallpaperKey: project.canvas.backgroundSource.sceneResourceKey,
                stickerImages: isCropping ? [:] : resolvedStickerImages,
                suppressCameraContent: isCropping || cameraCompositorSuppressed,
                suppressScreenContent: !isCropping && screenCompositorSuppressed,
                playbackController: playbackController, playbackFrameProvider: provider,
                onCameraContentApplied: clearCameraDragPreviewIfIdle,
                onScreenContentApplied: clearScreenDragPreviewIfIdle,
                onSleepCoverChanged: { covered, completion in
                    sleepPresentation.setCovered(covered, reducesMotion: reducesMotion,
                        completion: completion)
                }
            )
            .frame(width: isCropping ? sourceSize.width : canvasSize.width,
                   height: isCropping ? sourceSize.height : canvasSize.height)
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private func focusCanvas() {
        guard showsEditingControls, !isCropping else { return }
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

        let layers = layout.frameScene.layerOrder
        if layers.contains(.screen) {
            screenSelectionTarget(scene: layout.frameScene.screen, canvasSize: canvasSize)
                .accessibilityHidden(isScreenSelectionActive)
        }

        // EDT-073: a main-track HTML motion's elements sit where its picture
        // does — above the screen target, below every overlay, subtitle and
        // the camera — so those stay clickable on top of it.
        if showsEditingOverlays, case .mainTrack = motionElementEditor.target {
            motionElementLayer(layout: layout, canvasSize: canvasSize)
        }

        if showsEditingOverlays, layers.contains(.screen),
           case .screen = editScope,
           let contentPosition = editScope.position(in: interactionSceneProject),
           let contentScale = editScope.scale(in: interactionSceneProject) {
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

        if showsEditingOverlays {
            frontOverlaySelectionTargets(
                scene: layout.frameScene,
                canvasSize: canvasSize) {
                cameraTarget(in: layout.frameScene, canvasSize: canvasSize, activeTick: activeTick, scope: cameraInteractionScope)
                    .zIndex(layout.frameScene.cameraHitLayer)
            }
            .zIndex({
                if case .sticker = editorStore.selection { return 150.0 }
                // Match the hit order to a camera rendered directly on the background.
                return layers.prefix(2).elementsEqual([.background, .camera]) ? 1.0 : 0.0
            }())
        }

        if showsEditingOverlays, case let .animation(id) = editorStore.selection,
           let selected = layout.frameScene.animations.first(where: { $0.id == id }) {
            animationHandles(selected, canvasSize: canvasSize).zIndex(240)
        }

        if showsEditingOverlays, case .overlay = motionElementEditor.target {
            motionElementLayer(layout: layout, canvasSize: canvasSize)
                .zIndex(160)
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
    }

    @ViewBuilder
    private func motionElementLayer(layout: CanvasPreviewLayout, canvasSize: CGSize) -> some View {
        if let target = motionElementEditor.target,
           let placement = MotionElementPlacement.resolve(target, scene: layout.frameScene, canvasSize: canvasSize) {
            MotionElementEditingLayer(editorStore: editorStore, editor: motionElementEditor, placement: placement,
                                      canvasSize: canvasSize, accent: EditorTheme.accent)
        }
    }

    /// Whose elements are pickable on the canvas right now (EDT-073).
    var elementEditingTarget: MotionElementTarget? {
        guard !playbackController.isPlaying, !isCropping else { return nil }
        if case let .animation(id) = editorStore.selection,
           let clip = editorStore.project.timeline.animationClips.first(where: { $0.id == id }),
           HTMLMotion.isHTMLMotion(clip.sourcePath), clip.timing.contains(playbackController.outputTime) {
            return .overlay(id)
        }
        return insertedMotionSegmentID().map { .mainTrack($0) }
    }

    /// The main-track segment under the playhead, when it plays an HTML motion.
    func insertedMotionSegmentID() -> UUID? {
        guard case let .edited(segments) = editorStore.project.timeline.sourceSequence else { return nil }
        let time = playbackController.outputTime
        var start: TimeInterval = 0
        for segment in segments {
            let end = start + segment.outputDuration
            if time >= start, time < end { return segment.media?.motionPath != nil ? segment.id : nil }
            start = end
        }
        return nil
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
        .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
                .animation(.easeOut(duration: 0.18), value: chrome.phase)
        .frame(width: canvasSize.width, height: canvasSize.height)
        .onTapGesture {
            onCanvasFocused()
            // EDT-073: inside a main-track HTML motion the picture is that
            // clip, not the recording.
            editorStore.selection = (insertedMotionSegmentID() ?? insertedImageSegmentID)
                .map { .primarySegment($0) } ?? selection
        }
        .onHover {
            updateCanvasHover(selection, hovering: $0)
        }
        .accessibilityLabel("屏幕素材")
        .accessibilityHint("点击以选择屏幕")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            editorStore.selection = (insertedMotionSegmentID() ?? insertedImageSegmentID)
                .map { .primarySegment($0) } ?? selection
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
        let isDragging = cropDragOrigin != nil
        return ZStack(alignment: .topLeading) {
            cropDimming(sourceOrigin: sourceOrigin, sourceSize: sourceSize, selection: selectionRect)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                // Rule of thirds appears only while the frame is moving.
                .overlay {
                    Path { path in
                        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                            path.move(to: CGPoint(x: selectionRect.width * fraction, y: 0))
                            path.addLine(to: CGPoint(x: selectionRect.width * fraction, y: selectionRect.height))
                            path.move(to: CGPoint(x: 0, y: selectionRect.height * fraction))
                            path.addLine(to: CGPoint(x: selectionRect.width, y: selectionRect.height * fraction))
                        }
                    }
                    .stroke(.white.opacity(isDragging ? 0.42 : 0), lineWidth: 0.5)
                    .animation(SpringMotion.hover, value: isDragging)
                    .allowsHitTesting(false)
                }
                .overlay {
                    Rectangle()
                        .strokeBorder(EditorTheme.accent, lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                        .allowsHitTesting(false)
                }
                .frame(width: selectionRect.width, height: selectionRect.height)
                .position(x: selectionRect.midX, y: selectionRect.midY)
                .gesture(cropMoveGesture(sourceSize: sourceSize))
                .editorCursor(.openHand)
                // Canvas dragging remains the direct-manipulation path. The
                // margin fields in the inspector are the precise
                // keyboard/VoiceOver path, so this mouse-only layer must not
                // become an inert accessibility stop.
                .accessibilityHidden(true)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                cropHandle(handle, in: selectionRect, sourceSize: sourceSize)
            }

            if isDragging {
                EditorCanvasPill {
                    Text(EditorCropGeometry.pixelSizeText(crop, source: sourcePixelSize))
                        .font(.appUI(size: 12, weight: .semibold).monospacedDigit())
                }
                .position(cropSizeChipPosition(for: selectionRect, canvasSize: canvasSize))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(SpringMotion.micro, value: isDragging)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// Below the frame when there is room, otherwise above it, otherwise
    /// just inside its bottom edge.
    func cropSizeChipPosition(for rect: CGRect, canvasSize: CGSize) -> CGPoint {
        let x = min(max(rect.midX, 60), max(canvasSize.width - 60, 60))
        if rect.maxY + 34 <= canvasSize.height { return CGPoint(x: x, y: rect.maxY + 20) }
        if rect.minY - 34 >= 0 { return CGPoint(x: x, y: rect.minY - 20) }
        return CGPoint(x: x, y: rect.maxY - 24)
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
        cropProject.timeline.sourceSequence = cropProject.timeline.sourceSequence.withoutSceneStyles
        cropProject.zoomAnimations = []
        cropProject.timeline.screenMotionClips = []
        cropProject.timeline.cameraMotionClips = []
        cropProject.timeline.mosaicClips = []
        cropProject.timeline.stickerClips = []
        cropProject.timeline.animationClips = []
        cropProject.timeline.videoClips = []
        cropProject.timeline.subtitleCues = []
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
        // The frame being cropped is the one under the playhead, so the
        // scene is evaluated there too (never the opening at 0 s).
        var scene = FrameSceneEvaluator.scene(
            project: cropProject,
            time: playbackController.latestOutputTime,
            canvasSize: CompositionSize(
                width: Double(size.width),
                height: Double(size.height)
            ),
            sourceAspectRatio: Double(sourceAspect),
            pointerEvaluation: PointerTrackEvaluation(position: nil, cursor: nil),
            cursorMetrics: nil,
            zoomTrack: ZoomAnimationTrack([])
        )
        scene.insertedMotion = nil
        return scene
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
        Path { path in
            path.addRect(CGRect(origin: sourceOrigin, size: sourceSize))
            path.addRect(selection)
        }
        .fill(Color.black.opacity(0.52), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    func cropHandle(
        _ handle: CropHandle,
        in rect: CGRect,
        sourceSize: CGSize
    ) -> some View {
        let position = cropHandlePosition(handle, in: rect)
        return CropHandleGlyph(handle: handle)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .editorCursor(cropCursor(for: handle))
            .position(position)
            .highPriorityGesture(cropResizeGesture(handle: handle, sourceSize: sourceSize))
            .accessibilityHidden(true)
    }

    func cropCursor(for handle: CropHandle) -> NSCursor {
        switch handle {
        case .top, .bottom: .resizeUpDown
        case .left, .right: .resizeLeftRight
        case .topLeft, .topRight, .bottomRight, .bottomLeft: .crosshair
        }
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
                EditorDragFrameCoalescer.shared.submit {
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
}
            .onEnded { _ in
                EditorDragFrameCoalescer.shared.flush(); cropDragOrigin = nil }
    }

    func cropResizeGesture(handle: CropHandle, sourceSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                EditorDragFrameCoalescer.shared.submit {
                if cropDragOrigin == nil { cropDragOrigin = cropDraft.clamped() }
                guard let origin = cropDragOrigin else { return }
                let dx = Double(value.translation.width / max(sourceSize.width, 1))
                let dy = Double(value.translation.height / max(sourceSize.height, 1))
                cropDraft = resizedCrop(origin, handle: handle, dx: dx, dy: dy)
            }
}
            .onEnded { _ in
                EditorDragFrameCoalescer.shared.flush(); cropDragOrigin = nil }
    }

    func resizedCrop(
        _ origin: NormalizedCrop,
        handle: CropHandle,
        dx: Double,
        dy: Double
    ) -> NormalizedCrop {
        let minimumWidth = max(24 / max(Double(sourcePixelSize.width), 1), 0.02)
        let minimumHeight = max(24 / max(Double(sourcePixelSize.height), 1), 0.02)
        // ⇧ while dragging a corner keeps the current shape; a locked ratio
        // from the inspector always applies.
        let lockedRatio = EditorCropAspectLock.shared.aspect.normalizedRatio(source: sourcePixelSize)
            ?? (NSEvent.modifierFlags.contains(.shift) ? origin.width / max(origin.height, 0.0001) : nil)
        return EditorCropGeometry.resized(
            origin, handle: handle, dx: dx, dy: dy, ratio: lockedRatio,
            minimumWidth: minimumWidth, minimumHeight: minimumHeight
        )
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
        var handle = quad.resizeHandlePoint
        if project.timeline.insertedMedia(atOutputTime: playbackController.latestOutputTime) != nil {
            // A cover-fitted portrait/square source can extend beyond the
            // canvas. Keep its resize handle reachable in the visible viewport.
            handle = CompositionPoint(
                x: min(max(handle.x, 6), max(Double(canvasSize.width) - 6, 6)),
                y: min(max(handle.y, 6), max(Double(canvasSize.height) - 6, 6)))
        }
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
                .animation(.easeOut(duration: 0.18), value: chrome.phase)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                EditorDragFrameCoalescer.shared.submit {
                            if screenDragOrigin == nil {
                                guard beginSceneCanvasInteraction(
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
}
                        .onEnded { _ in
                EditorDragFrameCoalescer.shared.flush()
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
                    String(
                        format: appLocalized("水平 %ld%%，垂直 %ld%%"),
                        Int(contentPosition.x * 100),
                        Int(contentPosition.y * 100)
                    )
                )
                .accessibilityAddTraits([.isButton, .isSelected])
                .accessibilityAction {
                    if let selection = scope.selection {
                        editorStore.selection = selection
                    }
                }

            EditorCanvasHandle(
                active: isResizing
            )
                .position(x: CGFloat(handle.x), y: CGFloat(handle.y))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                EditorDragFrameCoalescer.shared.submit {
                            if screenScaleOrigin == nil {
                                guard beginSceneCanvasInteraction(
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
                                && project.timeline.insertedMedia(atOutputTime: playbackController.latestOutputTime) == nil
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
}
                        .onEnded { _ in
                EditorDragFrameCoalescer.shared.flush()
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

            // Linear-focus clips keep their own centre handle instead.
            if case let .screen(.motion(id)) = scope,
               project.timeline.screenMotionClips.first(where: { $0.id == id })?.focusEffect == nil {
                screenTiltGizmo(clipID: id, quad: quad)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// 屏幕 3D · 选中后: a round handle in the middle of the projected screen.
    /// Drag it to tilt (up/down = X, left/right = Y); the frame follows in
    /// perspective. The float bar above offers the four presets.
    func screenTiltGizmo(clipID: UUID, quad: ProjectedScreenQuad) -> some View {
        let center = CGPoint(
            x: CGFloat(quad.corners.map(\.x).reduce(0, +) / 4),
            y: CGFloat(quad.corners.map(\.y).reduce(0, +) / 4)
        )
        let active = screenTiltOrigin != nil || isScreenTiltGizmoHovered
        return ZStack {
            Circle()
                .fill(Color.black.opacity(active ? 0.08 : 0.001))
            Circle()
                .strokeBorder(EditorTheme.accent.opacity(0.85),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .shadow(color: .black.opacity(0.25), radius: 1)
            Circle()
                .fill(EditorTheme.accent)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2).padding(-2))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .scaleEffect(screenTiltOrigin != nil ? 1.06 : 1)
        .animation(SpringMotion.micro, value: active)
        .position(center)
        .onHover { isScreenTiltGizmoHovered = $0 }
        .editorCursor(screenTiltOrigin == nil ? .openHand : .closedHand)
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    EditorDragFrameCoalescer.shared.submit {
                        if screenTiltOrigin == nil {
                            guard let clip = project.timeline.screenMotionClips.first(where: { $0.id == clipID }) else { return }
                            editorStore.cancelInteraction()
                            editorStore.beginInteraction(tool: .editScreenMotion, selection: .screenMotion(clipID))
                            screenTiltOrigin = (clipID, clip.target.rotationX, clip.target.rotationY)
                        }
                        guard let origin = screenTiltOrigin else { return }
                        let x = min(max(origin.x - Double(value.translation.height) * EditorTiltPad.dragGain,
                                        -EditorTiltPad.maximumX), EditorTiltPad.maximumX)
                        let y = min(max(origin.y + Double(value.translation.width) * EditorTiltPad.dragGain,
                                        -EditorTiltPad.maximumY), EditorTiltPad.maximumY)
                        editorStore.updateInteraction { project in
                            guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == origin.id }) else { return }
                            project.timeline.screenMotionClips[index].target.rotationX = x
                            project.timeline.screenMotionClips[index].target.rotationY = y
                        }
                    }
                }
                .onEnded { _ in
                    EditorDragFrameCoalescer.shared.flush()
                    if screenTiltOrigin != nil {
                        commitCanvasInteraction(actionName: "调整屏幕 3D 倾斜")
                    }
                    screenTiltOrigin = nil
                }
        )
        .help(appLocalized("拖动倾斜"))
        .accessibilityLabel(appLocalized("3D 姿态"))
        .accessibilityHint(appLocalized("拖动倾斜"))
    }

    @ViewBuilder
    private func cameraTarget(in scene: FrameScene, canvasSize: CGSize, activeTick: EditorPlaybackRenderTick?,
                              scope: EditorCanvasEditScope) -> some View {
        if let camera = scene.camera, camera.opacity > 0,
           hasCameraTrack || activeTick?.sourceFrame?.usesPrimaryFrameForCamera == true {
            cameraInteractionOverlay(in: canvasSize,
                evaluation: CameraSceneEvaluation(rect: camera.rect, cornerRadius: camera.cornerRadius,
                    borderWidth: camera.borderWidth, opacity: camera.opacity),
                isAvailable: activeTick?.cameraIsAvailable == true, scope: scope, dragPreviewImage: cameraDragPreviewImage,
                allowsDetachedPreview: scene.videos.isEmpty && scene.animations.isEmpty && scene.stickers.isEmpty && scene.subtitle == nil)
        }
    }

    @ViewBuilder
    func cameraInteractionOverlay(
        in size: CGSize,
        evaluation: CameraSceneEvaluation,
        isAvailable: Bool,
        scope: EditorCanvasEditScope,
        dragPreviewImage: NSImage?,
        allowsDetachedPreview: Bool = true
    ) -> some View {
        let effectiveSize = scope.scale(in: interactionSceneProject) ?? interactionSceneProject.camera.size
        let effectivePosition = scope.position(in: interactionSceneProject) ?? interactionSceneProject.camera.position
        let selection = scope.selection ?? .camera
        let isSelected = editorStore.selection == selection
        let chrome = canvasObjectChrome(for: selection, isSelected: isSelected)
        let isResizing = cameraSizeOrigin != nil
        let base = min(size.width, size.height)
        let width = CGFloat(evaluation.rect.width)
        let height = CGFloat(evaluation.rect.height)
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
                EditorDragFrameCoalescer.shared.submit {
                        guard cameraSizeOrigin == nil else { return }
                        if cameraDragOrigin == nil {
                            guard beginSceneCanvasInteraction(
                                scope: scope,
                                operation: .move
                            ) else { return }

                            cameraDragOrigin = effectivePosition
                            cameraDragScope = scope
                            cameraDragPreviewImage = allowsDetachedPreview ? pausedCameraDragImage(
                                canvasSize: size
                            ) : nil
                            cameraCompositorSuppressed = cameraDragPreviewImage != nil
                        }
                        guard let origin = cameraDragOrigin,
                              let interactionScope = cameraDragScope else { return }
                        guard hypot(value.translation.width, value.translation.height) >= 2 else { return }
                        let base = Double(min(size.width, size.height))
                        let travelX = size.width - width - CGFloat(CompositionSceneEvaluator.cameraEdgeInset(
                            canvas: Double(size.width), camera: Double(width), base: base,
                            style: interactionSceneProject.camera, styleScale: Double(previewRenderScale(for: size)))) * 2
                        let travelY = size.height - height - CGFloat(CompositionSceneEvaluator.cameraEdgeInset(
                            canvas: Double(size.height), camera: Double(height), base: base,
                            style: interactionSceneProject.camera, styleScale: Double(previewRenderScale(for: size)))) * 2
                        let proposed = NormalizedPoint(
                            x: min(
                                max(
                                    origin.x
                                        + Double(value.translation.width / max(travelX, 1)),
                                    0
                                ),
                                1
                            ),
                            y: min(
                                max(
                                    origin.y
                                        + Double(value.translation.height / max(travelY, 1)),
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
}
                    .onEnded { _ in
                EditorDragFrameCoalescer.shared.flush()
                        if cameraDragOrigin != nil {
                            commitCanvasInteraction(
                                actionName: scope.isCameraMotion ? "调整摄像运动位置" : "移动摄像头"
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
            .onHover { updateCanvasHover(selection, hovering: $0) }
            .contextMenu {
                Button {
                    editorStore.selection = .camera
                    editorStore.sceneEditingSegmentID = project.timeline.recordingSegment(atOutputTime: playbackController.latestOutputTime)?.id
                    let mirrored = editorCameraBinding(store: editorStore, keyPath: \.isMirrored,
                        actionName: "切换摄像头镜像", onError: onError)
                    mirrored.wrappedValue.toggle()
                } label: {
                    Label(appLocalized("镜像摄像头"), systemImage: interactionSceneProject.camera.isMirrored ? "checkmark" : "flip.horizontal")
                }
            }
            .accessibilityLabel("摄像头画面")
            .accessibilityHint("拖动以移动，拖右下角圆点调整大小")
            .accessibilityValue(
                String(
                    format: appLocalized("水平 %ld%%，垂直 %ld%%，大小 %ld%%"),
                    Int(effectivePosition.x * 100),
                    Int(effectivePosition.y * 100),
                    Int(effectiveSize * 100)
                )
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
                EditorCanvasHandle(
                    active: isResizing
                )
                    .offset(x: 15, y: 15)
                    .gesture(
                        // 同摄像头拖动：把手随视图移动，必须全局坐标系避免振荡。
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                EditorDragFrameCoalescer.shared.submit {
                                cameraDragOrigin = nil
                                cameraDragScope = nil
                                if cameraSizeOrigin == nil {
                                    guard beginSceneCanvasInteraction(
                                        scope: scope,
                                        operation: .resize
                                    ) else { return }
                                    cameraSizeOrigin = effectiveSize
                                    cameraSizeScope = scope
                                    cameraDragPreviewImage = allowsDetachedPreview ? pausedCameraDragImage(
                                        canvasSize: size
                                    ) : nil
                                    cameraCompositorSuppressed = cameraDragPreviewImage != nil
                                }
                                guard let origin = cameraSizeOrigin,
                                      let interactionScope = cameraSizeScope else { return }
                                let delta = Double(
                                    (value.translation.width + value.translation.height)
                                        / max(base, 1)
                                )
                                let limits = scope.isCameraMotion ? 0.05...1 : 0.05...0.8
                                editorStore.updateCanvasScale(
                                    min(max(origin + delta * 1.2, limits.lowerBound), limits.upperBound),
                                    scope: interactionScope
                                )
                            }
}
                            .onEnded { _ in
                EditorDragFrameCoalescer.shared.flush()
                                if cameraSizeOrigin != nil {
                                    commitCanvasInteraction(
                                        actionName: scope.isCameraMotion ? "调整摄像运动大小" : "调整摄像头大小"
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
        .position(x: evaluation.rect.midX, y: evaluation.rect.midY)
        .frame(width: size.width, height: size.height)
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
        let frames = playbackPlanCache.snapshot(handle: cacheHandle)
        return { tick in
            let index = Int((max(tick.outputTime, 0) * Double(PreviewAnimationCadence.framesPerSecond)).rounded())
            if let cached = frames[index] {
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
        let playbackTracks = playbackTrackCache.tracks(for: project, outputDuration: mediaSession.outputDuration)
        let playbackTime = interactionPreviewTime()
            ?? activeTick?.outputTime
            ?? playbackController.outputTime
        let layout = previewLayout(
            canvasSize: canvasSize,
            playbackTime: playbackTime,
            tracks: playbackTracks
        )
        return CanvasRenderedFrame(playbackTime: playbackTime, layout: layout)
    }

    private func interactionPreviewTime() -> TimeInterval? {
        guard !playbackController.scrubIsActive, playbackController.hoverPreviewTime == nil,
              let selection = editorStore.interaction?.selection else { return nil }
        switch selection {
        case let .zoom(id):
            guard showsEditingControls, !playbackController.isPlaying,
                  let clip = project.timeline.zoomClips.first(where: { $0.id == id }),
                  clip.origin == .manual, clip.target == .recording else { return nil }
            // Inspect the fully entered composition without seeking the media
            // or changing the authored animation. Stay strictly inside this
            // clip: its exact end can already select an adjacent next zoom.
            return clip.endTime.nextDown
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


/// The plate shown where the live canvas is paused or not yet drawn. When a
/// paused frame exists it stays as a soft, frosted memory of the picture so
/// the monitor never turns into an empty slab; a small note says why.
struct EditorCanvasRestingCover: View {
    var image: NSImage? = nil
    var showsNote = true

    var body: some View {
        ZStack {
            EditorTheme.stage
            if let image, let frosted = Self.frosted(image) {
                // A 40 px copy enlarged with smooth interpolation reads as
                // frosted glass without running a blur filter every frame.
                Color.clear
                    .overlay { Image(nsImage: frosted).resizable().interpolation(.high).scaledToFill() }
                    .overlay { EditorTheme.stage.opacity(0.5) }
                    .clipped()
            }
            if showsNote {
                HStack(spacing: 6) {
                    AppLineIcon(kind: .pause, size: 11)
                    Text("预览已暂停")
                        .font(.appUI(size: 12, weight: .medium))
                }
                .foregroundStyle(EditorTheme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(EditorTheme.panelSurface, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).strokeBorder(EditorTheme.islandOutline, lineWidth: 1) }
            }
        }
    }

    @MainActor private static var frostedCache: (source: ObjectIdentifier, image: NSImage)?

    @MainActor private static func frosted(_ image: NSImage) -> NSImage? {
        let key = ObjectIdentifier(image)
        if let cached = frostedCache, cached.source == key { return cached.image }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let width = 40
        let height = max(Int((40 * image.size.height / image.size.width).rounded()), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: width, height: height))
        small.addRepresentation(rep)
        frostedCache = (key, small)
        return small
    }
}


/// Selection-frame handles: short white L-brackets hugging each corner and
/// small white bars at the edge midpoints, each with a thin accent rim so
/// they read on light and dark footage alike.
private struct CropHandleGlyph: View {
    let handle: CropHandle
    @State private var hovered = false

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let arm: CGFloat = hovered ? 12 : 10
            let bar: CGFloat = hovered ? 9 : 7
            var path = Path()
            switch handle {
            case .topLeft:
                path.move(to: CGPoint(x: c.x, y: c.y + arm)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x + arm, y: c.y))
            case .topRight:
                path.move(to: CGPoint(x: c.x - arm, y: c.y)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x, y: c.y + arm))
            case .bottomRight:
                path.move(to: CGPoint(x: c.x, y: c.y - arm)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x - arm, y: c.y))
            case .bottomLeft:
                path.move(to: CGPoint(x: c.x + arm, y: c.y)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x, y: c.y - arm))
            case .top, .bottom:
                path.move(to: CGPoint(x: c.x - bar, y: c.y)); path.addLine(to: CGPoint(x: c.x + bar, y: c.y))
            case .left, .right:
                path.move(to: CGPoint(x: c.x, y: c.y - bar)); path.addLine(to: CGPoint(x: c.x, y: c.y + bar))
            }
            context.stroke(path, with: .color(EditorTheme.accent),
                           style: StrokeStyle(lineWidth: 4.5, lineCap: .square, lineJoin: .miter))
            context.stroke(path, with: .color(.white),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .square, lineJoin: .miter))
        }
        .frame(width: 30, height: 30)
        .onHover { hovered = $0 }
        .animation(SpringMotion.micro, value: hovered)
    }
}

/// After the window's crossfade into crop mode, the frame settles in from
/// slightly larger, so the crop reads as a frame closing around the picture.
private struct EditorCropReveal: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || RecorderMotion.reduces ? 1 : 0)
            .onAppear {
                withAnimation(SpringMotion.fade) { shown = true }
            }
    }
}
