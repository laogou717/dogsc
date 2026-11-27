import Foundation

/// Backend-neutral size used by the immutable frame contract.
public struct CompositionSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var shortEdge: Double { min(width, height) }
}

/// Explicit color intent for every preview and export frame. Render backends
/// may use different APIs, but they must not choose device-dependent defaults.
public enum FrameColorSpace: String, Equatable, Sendable {
    case linearSRGB
    case sRGB
}

public struct FrameColorContract: Equatable, Sendable {
    public var workingSpace: FrameColorSpace
    public var outputSpace: FrameColorSpace
    public var isHDR: Bool

    public init(
        workingSpace: FrameColorSpace = .linearSRGB,
        outputSpace: FrameColorSpace = .sRGB,
        isHDR: Bool = false
    ) {
        self.workingSpace = workingSpace
        self.outputSpace = outputSpace
        self.isHDR = isHDR
    }

    /// Desktop SDR is captured through ScreenCaptureKit's explicit sRGB
    /// conversion. Rec.709 and sRGB share the same primaries but not the same
    /// transfer curve, so the transfer intent must not be collapsed to
    /// "Rec.709" and later changed by metadata alone.
    public static let sdrDesktop = FrameColorContract()
}

public struct FrameShadow: Equatable, Sendable {
    public var color: HexColor
    public var opacity: Double
    public var radius: Double
    /// Top-left-origin canvas coordinates; positive Y moves the shadow down.
    public var offset: CompositionPoint

    public init(
        color: HexColor = .black,
        opacity: Double,
        radius: Double,
        offset: CompositionPoint
    ) {
        self.color = color
        self.opacity = min(max(opacity, 0), 1)
        self.radius = max(radius, 0)
        self.offset = offset
    }
}

public struct FrameBackgroundScene: Equatable, Sendable {
    public var source: BackgroundSource
    /// Blur radius in output-canvas pixels.
    public var blurRadius: Double
    public var patternScale: Double
    public var patternOpacity: Double

    public init(
        source: BackgroundSource,
        blurRadius: Double,
        patternScale: Double = 1.0,
        patternOpacity: Double = 1.0
    ) {
        self.source = source
        self.blurRadius = max(blurRadius, 0)
        self.patternScale = max(patternScale, 0.1)
        self.patternOpacity = min(max(patternOpacity, 0), 1)
    }
}

public enum FrameScreenChromeKind: Equatable, Sendable {
    case window
    case browser
    case devicePhonePortrait
    case devicePhoneLandscape
    case deviceTabletPortrait
    case deviceTabletLandscape

    public var isDevice: Bool {
        switch self {
        case .window, .browser: false
        case .devicePhonePortrait, .devicePhoneLandscape,
             .deviceTabletPortrait, .deviceTabletLandscape: true
        }
    }

    public var isPhone: Bool {
        self == .devicePhonePortrait || self == .devicePhoneLandscape
    }

}

/// Fully evaluated vector chrome. Geometry is expressed in the same top-left
/// canvas coordinates as the screen, so the single renderer can draw it before
/// applying the screen's 3D projection.
public struct FrameScreenChromeScene: Equatable, Sendable {
    public var kind: FrameScreenChromeKind
    public var outerRect: CompositionRect
    public var toolbarRect: CompositionRect
    public var contentRect: CompositionRect
    public var outerCornerRadius: Double
    public var contentCornerRadius: Double
    public var surfaceColor: HexColor
    public var toolbarColor: HexColor
    public var separatorColor: HexColor
    public var fieldColor: HexColor
    public var glyphColor: HexColor
    public var title: String
    public var browserAddress: String

    public init(
        kind: FrameScreenChromeKind,
        outerRect: CompositionRect,
        toolbarRect: CompositionRect,
        contentRect: CompositionRect? = nil,
        outerCornerRadius: Double,
        contentCornerRadius: Double = 0,
        surfaceColor: HexColor,
        toolbarColor: HexColor,
        separatorColor: HexColor,
        fieldColor: HexColor,
        glyphColor: HexColor,
        title: String = "",
        browserAddress: String = ""
    ) {
        self.kind = kind
        self.outerRect = outerRect
        self.toolbarRect = toolbarRect
        self.contentRect = contentRect ?? outerRect
        self.outerCornerRadius = max(outerCornerRadius, 0)
        self.contentCornerRadius = max(contentCornerRadius, 0)
        self.surfaceColor = surfaceColor
        self.toolbarColor = toolbarColor
        self.separatorColor = separatorColor
        self.fieldColor = fieldColor
        self.glyphColor = glyphColor
        self.title = String(title.prefix(120))
        self.browserAddress = String(browserAddress.prefix(240))
    }
}

/// Decorations are deliberately evaluated into `FrameScene`. The renderer
/// never reads `CanvasStyle` or chooses a visual preset on its own.
public enum FrameScreenDecoration: Equatable, Sendable {
    case none
    case chrome(FrameScreenChromeScene)

    public var projectionRect: CompositionRect? {
        switch self {
        case .none: nil
        case let .chrome(chrome): chrome.outerRect
        }
    }
}

public struct FrameMosaicScene: Equatable, Sendable {
    public var sourceRect: NormalizedOverlayRect
    public var cornerRadius: Double
    public var style: MosaicEffectStyle
    public var intensity: Double
    public var spotlightDimming: Double
    /// Eased visibility shared by blur or spotlight dimming during interval edges.
    public var transitionProgress: Double

    public init(
        sourceRect: NormalizedOverlayRect,
        cornerRadius: Double,
        style: MosaicEffectStyle,
        intensity: Double,
        spotlightDimming: Double = 0.22,
        transitionProgress: Double = 1
    ) {
        self.sourceRect = sourceRect.clamped()
        self.cornerRadius = min(max(cornerRadius.isFinite ? cornerRadius : 0, 0), 0.5)
        self.style = style
        self.intensity = min(max(intensity.isFinite ? intensity : 0.5, 0), 1)
        self.spotlightDimming = min(
            max(spotlightDimming.isFinite ? spotlightDimming : 0.22, 0),
            0.75
        )
        self.transitionProgress = min(
            max(transitionProgress.isFinite ? transitionProgress : 1, 0),
            1
        )
    }
}

public struct FrameScreenScene: Equatable, Sendable {
    public var sourceCrop: NormalizedCrop
    public var baseRect: CompositionRect
    public var finalRect: CompositionRect
    public var projectedQuad: ProjectedScreenQuad
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var borderOpacity: Double
    public var shadow: FrameShadow?
    public var decoration: FrameScreenDecoration
    public var mosaics: [FrameMosaicScene]
    public var focusEffect: FrameFocusScene?
    public var opacity: Double
    /// EDT-054: an inserted video fills the screen frame (cover), since its
    /// aspect differs from the recording the frame is shaped for.
    public var fillsFrame = false
    /// The source keeps its own aspect while the surrounding card morphs.
    public var contentAspectRatio: Double? = nil

    public var sourceContentRect: CompositionRect {
        guard let aspect = contentAspectRatio, aspect > 0 else { return finalRect }
        let fitsWidth = (aspect >= finalRect.width / max(finalRect.height, 0.001)) != fillsFrame
        let width = fitsWidth ? finalRect.width : finalRect.height * aspect
        let height = fitsWidth ? finalRect.width / aspect : finalRect.height
        return CompositionRect(x: finalRect.x + (finalRect.width - width) / 2,
            y: finalRect.y + (finalRect.height - height) / 2, width: width, height: height)
    }

    public var projectionRect: CompositionRect {
        decoration.projectionRect ?? finalRect
    }

    public init(
        sourceCrop: NormalizedCrop,
        baseRect: CompositionRect,
        finalRect: CompositionRect,
        projectedQuad: ProjectedScreenQuad,
        cornerRadius: Double,
        borderWidth: Double,
        borderColor: HexColor,
        borderOpacity: Double,
        shadow: FrameShadow?,
        decoration: FrameScreenDecoration = .none,
        mosaics: [FrameMosaicScene] = [],
        focusEffect: FrameFocusScene? = nil,
        opacity: Double = 1
    ) {
        self.sourceCrop = sourceCrop.clamped()
        self.baseRect = baseRect
        self.finalRect = finalRect
        self.projectedQuad = projectedQuad
        self.cornerRadius = max(cornerRadius, 0)
        self.borderWidth = max(borderWidth, 0)
        self.borderColor = borderColor
        self.borderOpacity = min(max(borderOpacity, 0), 1)
        self.shadow = shadow
        self.decoration = decoration
        self.mosaics = mosaics
        self.focusEffect = focusEffect
        self.opacity = min(max(opacity, 0), 1)
    }
}

public struct FrameCameraScene: Equatable, Sendable {
    /// The video immediately beneath this camera inset in paint order.
    public var insetVideoID: UUID?
    /// A normally foreground camera sits just below this video, still above
    /// graphics on lower tracks. A fullscreen talking head stays on the base.
    public var coveringVideoID: UUID?
    public var rect: CompositionRect
    public var contentFill: CameraContentFillLayout?
    public var sourceFocus = NormalizedPoint(x: 0.5, y: 0.5)
    public var contentScale: Double = 1
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var shadow: FrameShadow?
    public var opacity: Double
    public var isMirrored: Bool
    public var beauty: CameraBeautySettings
    public var usesCircularCorners: Bool

    public init(
        rect: CompositionRect,
        contentFill: CameraContentFillLayout?,
        cornerRadius: Double,
        borderWidth: Double,
        borderColor: HexColor = .white,
        shadow: FrameShadow?,
        opacity: Double,
        isMirrored: Bool,
        beauty: CameraBeautySettings = CameraBeautySettings(),
        usesCircularCorners: Bool = false,
        sourceFocus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5), contentScale: Double = 1
    ) {
        self.rect = rect
        self.contentFill = contentFill
        self.sourceFocus = sourceFocus
        self.contentScale = contentScale
        self.cornerRadius = max(cornerRadius, 0)
        self.borderWidth = max(borderWidth, 0)
        self.borderColor = borderColor
        self.shadow = shadow
        self.opacity = min(max(opacity, 0), 1)
        self.isMirrored = isMirrored
        self.beauty = beauty
        self.usesCircularCorners = usesCircularCorners
    }
}

public enum FrameCursorAttachment: Equatable, Sendable {
    /// The cursor is authored in the recorded-screen coordinate space and must
    /// be transformed with that decorated layer, including future 3D motion.
    case screen
}

public struct FrameCursorScene: Equatable, Sendable {
    public var assetID: CursorAssetID
    public var metrics: CursorAssetMetrics
    /// Canonical 2D layout. It also supplies local size/hotspot metrics when a
    /// backend attaches the cursor to a projected screen texture.
    public var layout: CursorRenderLayout
    public var isClicking: Bool
    public var clickPhase: PointerClickPhase?
    public var clickStyle: CursorClickEffectStyle
    public var clickColor: HexColor?
    public var clickOpacity: Double
    public var clickScale: Double
    public var rotationRadians: Double
    /// Hotspot-anchored scale of the cursor bitmap only (click effects keep
    /// their own geometry). 1 means at rest.
    public var pressScale: Double
    public var shadow: FrameShadow?
    public var attachment: FrameCursorAttachment

    public var effectiveClickColor: HexColor {
        clickColor ?? metrics.clickColor
    }

    public init(
        assetID: CursorAssetID,
        metrics: CursorAssetMetrics,
        layout: CursorRenderLayout,
        isClicking: Bool,
        clickPhase: PointerClickPhase? = nil,
        clickStyle: CursorClickEffectStyle = .ripple,
        clickColor: HexColor? = nil,
        clickOpacity: Double = 0.8,
        clickScale: Double = 1.0,
        rotationRadians: Double = 0,
        pressScale: Double = 1,
        shadow: FrameShadow?,
        attachment: FrameCursorAttachment = .screen
    ) {
        self.assetID = assetID
        self.metrics = metrics
        self.layout = layout
        self.isClicking = isClicking
        self.clickPhase = clickPhase
        self.clickStyle = clickStyle
        self.clickColor = clickColor
        self.clickOpacity = min(max(clickOpacity, 0.05), 1.0)
        self.clickScale = min(max(clickScale, 0.4), 3.0)
        self.rotationRadians = rotationRadians.isFinite ? rotationRadians : 0
        self.pressScale = pressScale.isFinite && pressScale > 0 ? pressScale : 1
        self.shadow = shadow
        self.attachment = attachment
    }
}

public struct FrameStickerScene: Equatable, Sendable {
    public var id: UUID
    public var relativePath: String
    public var position: NormalizedPoint
    public var width: Double
    public var rotationRadians: Double
    public var opacity: Double
    public var scale: Double
    public var offset: NormalizedPoint
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var shadowOpacity: Double
    public var shadowRadius: Double
    public var shadowOffset: CompositionPoint
    public var backdropBlur: Double
    public var backdropBlurIncludesCamera: Bool
    public var hidesScreen: Bool
    public var hidesCamera: Bool
    /// Entrance/exit visibility before the user's authored sticker opacity is
    /// applied. Joined background treatment lives separately in the frame
    /// backdrop so two partially visible images cannot expose the recording.
    public var transitionProgress: Double
    public var layerIndex: Int
    public var sourceTime: TimeInterval = 0
}

public enum FrameLayerRole: String, Equatable, Sendable {
    case background
    case screen
    case cursor
    case spotlight
    case camera
    case stickers
    case animations
    case subtitles
    case videos
}

/// One overlay video at this frame (EDT-054).
public struct FrameVideoScene: Equatable, Sendable {
    public var maskShape: VideoMaskShape
    public var maskCornerRadius: Double
    public var maskRadiusFraction: Double {
        switch maskShape {
        case .rectangle: 0
        case .rounded: maskCornerRadius
        case .circle: 0.5
        }
    }

    public var contentPosition: NormalizedPoint
    public var contentScale: Double
    public var id: UUID
    public var sourcePath: String
    public var sourceTime: TimeInterval
    public var position: NormalizedPoint
    public var width: Double
    public var aspect: Double
    public var opacity: Double
    public var layerIndex: Int

    public init(clip: VideoClip, at time: TimeInterval) {
        id = clip.id
        sourcePath = clip.sourcePath
        let mapped = clip.sourceStart + max(time - clip.timing.startTime, 0) * clip.playbackRate
        // A valid half-open tail can round onto the exclusive source boundary.
        if let end = clip.sourceFileEnd, mapped >= end, mapped <= end + VideoClip.sourceTimeTolerance {
            sourceTime = end.nextDown
        } else {
            sourceTime = mapped
        }
        position = clip.position
        width = clip.width
        maskShape = clip.maskShape
        maskCornerRadius = clip.maskCornerRadius
        contentPosition = clip.contentPosition
        contentScale = clip.contentScale
        aspect = clip.maskAspect
        opacity = clip.opacity
        layerIndex = clip.layerIndex
    }

    /// A translucent video or the empty corners outside a mask can still
    /// show the camera. Only a fully covered camera bounds counts as a cut.
    func covers(_ rect: CompositionRect, on canvas: CompositionSize) -> Bool {
        guard opacity >= 1 else { return false }
        let w = width * canvas.width, h = w * aspect
        let x = position.x * canvas.width, y = position.y * canvas.height
        let radius = maskRadiusFraction * min(w, h)
        let dx = abs(rect.midX - x) + rect.width / 2 - w / 2
        let dy = abs(rect.midY - y) + rect.height / 2 - h / 2
        guard dx <= 0.000001, dy <= 0.000001 else { return false }
        return hypot(max(0, dx + radius), max(0, dy + radius)) <= radius + 0.000001
    }

    mutating func applyZoom(_ sample: ZoomSample, sourceAspect: Double, canvasAspect: Double) {
        guard sample.scale > 1 || sample.framingProgress > 0 else { return }
        // The focus picker shows the original media. Map that point through the user's
        // existing crop before animating the whole card, including its rounded mask.
        guard let fill = CameraContentFill.layout(sourceWidth: 1, sourceHeight: sourceAspect,
            target: .init(x: 0, y: 0, width: 1, height: aspect), focus: contentPosition,
            contentScale: contentScale, overscan: 1) else { return }
        let visible = fill.visibleSource
        let crop = NormalizedCrop(x: visible.x, y: visible.y / sourceAspect,
                                  width: visible.width, height: visible.height / sourceAspect)
        let height = width * aspect * canvasAspect
        guard width > 0, height > 0 else { return }
        let canvas = CompositionRect(x: 0.5 - position.x / width, y: 0.5 - position.y / height,
                                     width: 1 / width, height: 1 / height)
        let coversCanvas = canvas.x >= -0.000001 && canvas.y >= -0.000001
            && canvas.x + canvas.width <= 1.000001 && canvas.y + canvas.height <= 1.000001
        let transform = ZoomViewportTransform.make(from: sample, crop: crop, covering: coversCanvas ? canvas : nil)
        position.x += transform.translation.x * width
        position.y += transform.translation.y * height
        width *= transform.scale
    }
}

/// The subtitle line visible at this frame, with its style (EDT-054).
public struct FrameSubtitleScene: Equatable, Sendable {
    public var cueID: UUID
    public var text: String
    public var secondaryText: String?
    public var style: SubtitleStyle
    /// Seconds since the cue began and until it ends, for entrances/exits.
    public var elapsed: TimeInterval
    public var remaining: TimeInterval
}

/// One Rive motion graphic at this frame. `localTime` is clip-local and is
/// quantised to the plan's frame grid by the renderer, never advanced freely.
public struct FrameAnimationScene: Equatable, Sendable {
    public var playbackRate: Double
    public var id: UUID
    public var sourcePath: String
    public var artboard: String?
    public var stateMachine: String?
    public var localTime: TimeInterval
    public var position: NormalizedPoint
    public var width: Double
    public var opacity: Double
    public var properties: [String: AnimationPropertyValue]
    public var layerIndex: Int
    public var elementEdits: [String: MotionElementEdit]
    public var hostsCamera = false
    /// The fixed hole and its presentation position in canvas coordinates.
    /// Both exclude the native underlay's antialiasing bleed.
    public struct MovingMatte: Equatable, Sendable {
        public var aperture, presented: CompositionRect
        public var cornerRadius, reveal: Double
    }
    public var movingMatte: MovingMatte?

    public init(clip: AnimationClip, at time: TimeInterval) {
        id = clip.id
        sourcePath = clip.sourcePath
        artboard = clip.artboard
        stateMachine = clip.stateMachine
        localTime = max(time - clip.timing.startTime, 0) * clip.playbackRate + max(clip.timeOffset, 0)
        playbackRate = clip.playbackRate
        position = clip.position
        width = clip.width
        opacity = clip.opacity
        properties = clip.properties
        layerIndex = clip.layerIndex
        elementEdits = clip.elementEdits
    }
}

/// EDT-071: an HTML motion on the main track at this frame. Its picture
/// replaces the screen source, so the screen's framing (full canvas or the
/// recording's frame style) applies to it like to any inserted video.
public struct FrameInsertedMotionScene: Equatable, Sendable {
    public var playbackRate: Double = 1
    public var sourcePath: String
    public var localTime: TimeInterval
    public var properties: [String: AnimationPropertyValue]
    public var elementEdits: [String: MotionElementEdit]

    public init(sourcePath: String, localTime: TimeInterval, properties: [String: AnimationPropertyValue],
                elementEdits: [String: MotionElementEdit] = [:], playbackRate: Double = 1) {
        self.sourcePath = sourcePath
        self.localTime = localTime
        self.properties = properties
        self.elementEdits = elementEdits
        self.playbackRate = playbackRate
    }
}

/// An original still/GIF evaluated on the inserted segment's source clock.
public struct FrameInsertedImageScene: Equatable, Sendable {
    public var sourcePath: String
    public var localTime: TimeInterval

    public init(sourcePath: String, localTime: TimeInterval) {
        self.sourcePath = sourcePath
        self.localTime = localTime
    }
}

/// Complete immutable interpretation of one project time. A renderer may read
/// media frames and this value, but must never read `RecorderProject` directly.
public struct FrameScene: Equatable, Sendable {
    public var time: TimeInterval
    public var canvasSize: CompositionSize
    public var color: FrameColorContract
    public var background: FrameBackgroundScene
    public var screen: FrameScreenScene
    public var camera: FrameCameraScene?
    public var cursor: FrameCursorScene?
    public var stickers: [FrameStickerScene]
    public var stickerBackdrop: FrameStickerBackdropScene
    public var animations: [FrameAnimationScene]
    public var subtitle: FrameSubtitleScene?
    public var videos: [FrameVideoScene]
    public var layerOrder: [FrameLayerRole]
    public var cameraBeforeVisualOverlays: Bool {
        layerOrder.prefix { $0 != .animations && $0 != .videos && $0 != .stickers }.contains(.camera)
    }
    public var insertedMotion: FrameInsertedMotionScene?
    public var insertedImage: FrameInsertedImageScene?

    public init(
        time: TimeInterval,
        canvasSize: CompositionSize,
        color: FrameColorContract,
        background: FrameBackgroundScene,
        screen: FrameScreenScene,
        camera: FrameCameraScene?,
        cursor: FrameCursorScene?,
        stickers: [FrameStickerScene] = [],
        stickerBackdrop: FrameStickerBackdropScene? = nil,
        animations: [FrameAnimationScene] = [],
        subtitle: FrameSubtitleScene? = nil,
        videos: [FrameVideoScene] = [],
        layerOrder: [FrameLayerRole],
        insertedMotion: FrameInsertedMotionScene? = nil,
        insertedImage: FrameInsertedImageScene? = nil
    ) {
        self.time = time
        self.canvasSize = canvasSize
        self.color = color
        self.background = background
        self.screen = screen
        self.camera = camera
        self.cursor = cursor
        self.stickers = stickers
        self.stickerBackdrop = stickerBackdrop ?? FrameStickerBackdropScene(stickers: stickers)
        self.animations = animations
        self.subtitle = subtitle
        self.videos = videos
        self.layerOrder = layerOrder
        self.insertedMotion = insertedMotion
        self.insertedImage = insertedImage
    }
}

/// One output-frame request. Preview and export consume one identical scene.
public struct FrameRenderPlan: Equatable, Sendable {
    public var outputDuration: TimeInterval
    public var frameRate: Int
    public var scene: FrameScene

    public init(
        outputDuration: TimeInterval,
        frameRate: Int,
        scene: FrameScene
    ) {
        self.outputDuration = outputDuration
        self.frameRate = frameRate
        self.scene = scene
    }
}

/// The only project-aware per-frame interpreter. Render backends receive the
/// resulting immutable plan and API-specific media-frame handles separately.
public enum FrameSceneEvaluator {
    /// A preview may reuse an expensive video-frame plan at 30/60 Hz, but the
    /// pointer still belongs to the display-link clock. Re-evaluate only its
    /// recorded path, visibility, shape and click phase against that plan's
    /// screen geometry; never quantize those to the cached video-frame time.
    public static func refreshingCursor(
        in plan: FrameRenderPlan,
        at presentationTime: TimeInterval,
        project: RecorderProject,
        pointerTrack: ProjectPointerTrack?,
        cursorMetrics: CursorAssetMetrics?,
        cursorMetricsByAssetID: [CursorAssetID: CursorAssetMetrics],
        zoomTrack: ZoomAnimationTrack
    ) -> FrameRenderPlan {
        let project = project.sceneProject(atOutputTime: presentationTime)
        let time = presentationTime.isFinite
            ? min(max(presentationTime, 0), plan.outputDuration) : 0
        let activeAutomaticClip = zoomTrack.forTarget(.recording).activeClip(at: time).flatMap {
            $0.origin == .automatic ? $0 : nil
        }
        let pointer = pointerTrack?.evaluation(
            at: time,
            motion: project.motion,
            style: project.cursorStyle,
            automaticEntry: activeAutomaticClip
        )
        var result = plan
        if result.scene.insertedImage != nil,
           let playback = project.timeline.insertedPlayback(atOutputTime: time) {
            // Native image animation follows the media clock, independently
            // of the low-rate video stand-in and cached geometry samples.
            result.scene.insertedImage?.localTime = playback.localTime
        }
        // Keep the cached video/background phase. Advancing scene.time here
        // would also re-render a full-canvas animated wallpaper at cursor Hz.
        result.scene.cursor = result.scene.insertedImage != nil ? nil : cursorScene(
            sample: pointer?.cursor,
            project: project,
            metrics: cursorMetrics,
            metricsByAssetID: cursorMetricsByAssetID,
            screen: plan.scene.screen,
            canvasSize: plan.scene.canvasSize
        )
        result.scene.layerOrder.removeAll { $0 == .cursor }
        if result.scene.cursor != nil,
           let screenIndex = result.scene.layerOrder.firstIndex(of: .screen) {
            result.scene.layerOrder.insert(.cursor, at: screenIndex + 1)
        }
        return result
    }

    public static func renderPlan(
        project: RecorderProject,
        presentationTime: TimeInterval,
        outputDuration: TimeInterval,
        frameRate: Int,
        canvasSize: CompositionSize,
        sourceAspectRatio: Double,
        cameraSourceSize: CompositionSize? = nil,
        pointerTrack: ProjectPointerTrack? = nil,
        cursorMetrics: CursorAssetMetrics? = nil,
        cursorMetricsByAssetID: [CursorAssetID: CursorAssetMetrics] = [:],
        zoomTrack: ZoomAnimationTrack? = nil,
        screenMotionTrack: ScreenMotionTrack? = nil,
        cameraMotionTrack: CameraMotionTrack? = nil,
        stickerTrack: StickerTransitionTrack? = nil,
        cameraTimeline: TimelineMediaPlan? = nil,
        recordingSourceID: UUID? = nil,
        geometrySourceAspectRatio: Double? = nil,
        layoutAspectRatio: Double? = nil,
        color: FrameColorContract = .sdrDesktop
    ) -> FrameRenderPlan {
        let safeDuration = outputDuration.isFinite ? max(outputDuration, 0) : 0
        let safeTime = presentationTime.isFinite
            ? min(max(presentationTime, 0), safeDuration)
            : 0
        let current = scene(
            project: project,
            time: safeTime,
            outputDuration: safeDuration,
            frameRate: frameRate,
            canvasSize: canvasSize,
            sourceAspectRatio: sourceAspectRatio,
            cameraSourceSize: cameraSourceSize,
            pointerTrack: pointerTrack,
            cursorMetrics: cursorMetrics,
            cursorMetricsByAssetID: cursorMetricsByAssetID,
            zoomTrack: zoomTrack,
            screenMotionTrack: screenMotionTrack,
            cameraMotionTrack: cameraMotionTrack,
            stickerTrack: stickerTrack,
            cameraTimeline: cameraTimeline,
            recordingSourceID: recordingSourceID,
            geometrySourceAspectRatio: geometrySourceAspectRatio,
            layoutAspectRatio: layoutAspectRatio,
            color: color
        )
        return FrameRenderPlan(
            outputDuration: safeDuration,
            frameRate: max(frameRate, 1),
            scene: current
        )
    }

    public static func scene(
        project: RecorderProject,
        time: TimeInterval,
        outputDuration: TimeInterval? = nil,
        frameRate: Int? = nil,
        canvasSize: CompositionSize,
        sourceAspectRatio: Double,
        cameraSourceSize: CompositionSize? = nil,
        pointerTrack: ProjectPointerTrack? = nil,
        pointerEvaluation: PointerTrackEvaluation? = nil,
        cursorMetrics: CursorAssetMetrics? = nil,
        cursorMetricsByAssetID: [CursorAssetID: CursorAssetMetrics] = [:],
        zoomTrack: ZoomAnimationTrack? = nil,
        screenMotionTrack: ScreenMotionTrack? = nil,
        cameraMotionTrack: CameraMotionTrack? = nil,
        stickerTrack: StickerTransitionTrack? = nil,
        cameraTimeline: TimelineMediaPlan? = nil,
        recordingSourceID: UUID? = nil,
        geometrySourceAspectRatio: Double? = nil,
        layoutAspectRatio: Double? = nil,
        color: FrameColorContract = .sdrDesktop
    ) -> FrameScene {
        let width = max(canvasSize.width, 2)
        let height = max(canvasSize.height, 2)
        // Let the media plan decide membership at fractional recording cuts,
        // including when sampling the camera on either side of a transition.
        let cameraSourceSize = cameraTimeline?.contains(outputTime: time) == false ? nil : cameraSourceSize
        let cameraAspect = cameraSourceSize.map { max($0.width, 1) / max($0.height, 1) }
        // Resolve both sides against the authored global defaults. Applying
        // the incoming override first would erase an outgoing inherited style.
        let boundary = project.timeline.recordingSegmentBoundary(atOutputTime: time)
        let settledCanvas = project.screenCanvas(atOutputTime: time, recordingSourceID: recordingSourceID, boundary: boundary)
        let settledCamera = project.settledCamera(atOutputTime: time, boundary: boundary, cameraTimeline: cameraTimeline)
        let cameraBase = cameraAspect.flatMap {
            project.cameraAppearanceTransitionSample(atOutputTime: time, cameraAspectRatio: $0,
                canvasAspectRatio: width / height, boundary: boundary, cameraTimeline: cameraTimeline)
        }
        let sourceProject = project
        var project = project
        boundary.segment?.sceneStyle?.apply(to: &project)
        project.canvas = settledCanvas
        project.camera = settledCamera
        let insertedMedia = boundary.segment?.media
        let sourceAspectRatio = insertedMedia?.sourceAspectRatio ?? sourceAspectRatio
        let geometrySourceAspectRatio = insertedMedia?.imagePath != nil ? nil : geometrySourceAspectRatio
        if insertedMedia?.imagePath != nil, insertedMedia?.usesFrameStyle == false {
            // A flat image still uses the fitted source geometry, padding and
            // authored transform. Only recording frame chrome is omitted.
            project.canvas.cornerRadius = 0
            project.canvas.borderWidth = 0
            project.canvas.shadowStrength = 0
            project.canvas.screenFrame = .none
        }
        // The opening roster belongs to the recording that starts the output,
        // and `project.media` is about to become the current frame's source.
        let openingSourceID = project.openingRecordingSourceID
        let openingDeclaresCamera = project.openingDeclaresCamera
        let activeSource = (recordingSourceID ?? boundary.segment?.resolvedSourceID).flatMap { project.source($0) }
        if let source = activeSource {
            project.media = source.media
        }
        let sampleTime = time.isFinite ? max(time, 0) : 0
        let allZooms = zoomTrack?.bounded(to: outputDuration)
            ?? ZoomAnimationTrack(project.zoomAnimations, outputDuration: outputDuration)
        let resolvedZoomTrack = allZooms.forTarget(.recording)
        let resolvedStickerTrack = stickerTrack ?? StickerTransitionTrack(project.timeline.stickerClips)
        let suppressesFirstStickerEntry = project.openingSequence.isEnabled
            && project.openingSequence.includedElements.contains(.stickers)
        let resolvedScreenTrack = screenMotionTrack ?? ScreenMotionTrack(project.timeline.screenMotionClips)
        let activeZoomClip = resolvedZoomTrack.activeClip(at: sampleTime)
        let activeAutomaticClip = activeZoomClip.flatMap {
            $0.origin == .automatic ? $0 : nil
        }
        let reanchorsAtCut = activeAutomaticClip.map {
            pointerTrack?.automaticEntryStartsAfterCut($0) ?? false
        } ?? false
        let pointer = (reanchorsAtCut ? nil : pointerEvaluation) ?? pointerTrack?.evaluation(
            at: sampleTime,
            motion: project.motion,
            style: project.cursorStyle,
            automaticEntry: activeAutomaticClip
        ) ?? PointerTrackEvaluation(position: nil, cursor: nil)
        // CAM-001...CAM-004: the click group supplies stable initial framing.
        // Pointer activity can move that framing only after its recent range
        // crosses the safe zone, through a separate cached screen spring.
        let automaticCameraPosition = activeAutomaticClip.map { clip in
            pointerTrack?.automaticCameraFocus(
                at: sampleTime,
                clip: clip,
                motion: project.motion
            ) ?? clip.focus
        }
        let inheritedAutomaticCameraPosition: NormalizedPoint? = activeZoomClip
            .flatMap { resolvedZoomTrack.adjacentPreviousClip(to: $0) }
            .flatMap { previous in
                guard previous.origin == .automatic else { return nil }
                return pointerTrack?.automaticCameraFocus(
                    at: max(previous.startTime, previous.endTime.nextDown),
                    clip: previous,
                    motion: project.motion
                ) ?? previous.focus
            }
        let styleScale = CompositionSceneEvaluator.canonicalStyleScale(
            canvasWidth: width,
            canvasHeight: height
        )
        let geometry = CompositionSceneEvaluator.evaluate(
            project: project,
            time: sampleTime,
            canvasWidth: width,
            canvasHeight: height,
            sourceAspectRatio: geometrySourceAspectRatio ?? sourceAspectRatio,
            layoutAspectRatio: layoutAspectRatio,
            cameraAspectRatio: cameraAspect,
            styleScale: styleScale,
            automaticZoomFocus: automaticCameraPosition,
            inheritedAutomaticZoomFocus: inheritedAutomaticCameraPosition,
            reanchorAutomaticEntry: reanchorsAtCut,
            zoomTrack: resolvedZoomTrack,
            screenMotionTrack: resolvedScreenTrack,
            cameraMotionTrack: cameraMotionTrack,
            cameraMotionBase: cameraBase
        )
        // The opening roster must remain stable for its whole duration. Using
        // the current frame's active clips made every earlier element change
        // delay and duration when a sticker or camera appeared mid-opening.
        let hasOpeningSticker = project.timeline.stickerClips.contains {
            $0.timing.startTime <= 0.000_1 && $0.timing.endTime > 0.000_1
        }
        // A camera size measured on another recording's segment says nothing
        // about the opening, so it only counts for the opening's own source.
        let hasOpeningCamera = (openingDeclaresCamera
            || (cameraSourceSize != nil && openingSourceID == (recordingSourceID ?? RecordingSource.primaryID)))
            && !project.camera.isHidden
        let availableOpeningElements = project.openingSequence.participatingElements(
            hasCamera: hasOpeningCamera, hasOpeningSticker: hasOpeningSticker
        )
        let screenOpening = openingSample(
            for: .screen,
            sequence: project.openingSequence,
            activeElements: availableOpeningElements,
            at: sampleTime,
            canvasWidth: width,
            canvasHeight: height
        )
        var screenGeometry = geometry.screen
        screenGeometry.finalRect = openingRect(
            screenGeometry.finalRect,
            sample: screenOpening
        )
        screenGeometry.finalCornerRadius *= screenOpening.scale
        screenGeometry.finalBorderWidth *= screenOpening.scale
        screenGeometry.rotationX += screenOpening.rotationX
        screenGeometry.rotationY += screenOpening.rotationY
        screenGeometry.perspective = min(
            max(screenGeometry.perspective + screenOpening.perspective, 0),
            2
        )
        let screenShadow: FrameShadow? = project.canvas.shadowStrength > 0
            ? FrameShadow(
                opacity: project.canvas.shadowStrength,
                radius: 22 * styleScale * screenGeometry.manualScale
                    * screenGeometry.viewport.scale * screenOpening.scale,
                offset: CompositionPoint(
                    x: 0,
                    y: 12 * styleScale * screenGeometry.manualScale
                        * screenGeometry.viewport.scale * screenOpening.scale
                )
            )
            : nil
        let decoration = screenDecoration(
            style: project.canvas.screenFrame,
            frameScale: project.canvas.screenFrameScale,
            toolbarScale: project.canvas.screenFrameToolbarScale,
            outerCornerRadius: project.canvas.screenFrameOuterCornerRadius,
            contentCornerRadius: project.canvas.screenFrameContentCornerRadius,
            title: project.canvas.screenFrameTitle,
            browserAddress: project.canvas.screenFrameBrowserAddress,
            geometry: screenGeometry,
            styleScale: styleScale,
            groupScale: screenOpening.scale
        )
        let projectionRect = decoration.projectionRect ?? screenGeometry.finalRect
        // The inspector point addresses recorded content. The complete chrome,
        // border and shadow share its projection, but asymmetric decoration
        // must never reinterpret 0/0 as the outer toolbar corner.
        let projectionAnchor = CompositionPoint(
            x: screenGeometry.finalRect.x
                + screenGeometry.finalRect.width
                    * screenGeometry.projectionAnchor.x,
            y: screenGeometry.finalRect.y
                + screenGeometry.finalRect.height
                    * screenGeometry.projectionAnchor.y
        )
        let projectedQuad = ScreenProjection.project(
            rect: projectionRect,
            rotationX: screenGeometry.rotationX,
            rotationY: screenGeometry.rotationY,
            rotationZ: screenGeometry.rotationZ,
            perspective: screenGeometry.perspective,
            anchor: projectionAnchor
        )
        let activeMosaics: [FrameMosaicScene] = project.timeline.mosaicClips.compactMap { clip in
            guard clip.timing.contains(sampleTime) else { return nil }
            return FrameMosaicScene(
                sourceRect: clip.sourceRect,
                cornerRadius: clip.cornerRadius,
                style: clip.style,
                intensity: clip.intensity,
                spotlightDimming: clip.spotlightDimming,
                transitionProgress: overlayEffectProgress(
                    timing: clip.timing,
                    style: clip.transitionStyle,
                    enterDuration: clip.transitionInDuration,
                    exitDuration: clip.transitionOutDuration,
                    at: sampleTime
                )
            )
        }
        var screen = FrameScreenScene(
            sourceCrop: project.canvas.crop,
            baseRect: screenGeometry.baseRect,
            finalRect: screenGeometry.finalRect,
            projectedQuad: projectedQuad,
            cornerRadius: screenGeometry.finalCornerRadius,
            borderWidth: screenGeometry.finalBorderWidth,
            borderColor: project.canvas.borderColor,
            borderOpacity: project.canvas.insetOpacity,
            shadow: screenShadow,
            decoration: decoration,
            mosaics: activeMosaics,
            focusEffect: FocusEffectEvaluator.scene(
                zoom: activeZoomClip, screen: resolvedScreenTrack.activeClip(at: sampleTime),
                zoomFocus: geometry.screen.zoom.focus, crop: project.canvas.crop,
                pointer: pointer.position, time: sampleTime, motion: project.motion
            ),
            opacity: screenOpening.opacity
        )
        if let geometrySourceAspectRatio, abs(geometrySourceAspectRatio - sourceAspectRatio) > 0.000_001 {
            let crop = project.canvas.crop.clamped()
            screen.contentAspectRatio = sourceAspectRatio * crop.width / crop.height
        }
        let rate = max(1, frameRate ?? project.exportSettings.frameRate.rawValue)
        let hostTime = cameraAspect == nil ? sampleTime : sourceProject.cameraHostSampleTime(
            at: sampleTime, boundary: boundary, frameRate: rate, cameraTimeline: cameraTimeline)
        func animationTime(_ clip: AnimationClip) -> TimeInterval {
            clip.cameraSlot?.isValid == true ? hostTime : sampleTime
        }
        let activeAnimations = project.timeline.animationClips
            .filter { $0.opacity > 0 && $0.timing.contains(animationTime($0)) }
            .sorted(by: MotionCameraSlot.layerOrder)
        var animations = activeAnimations.map { FrameAnimationScene(clip: $0, at: animationTime($0)) }
        let cameraOnly = insertedMedia == nil && (activeSource?.capture.source ?? project.capture.source) == .cameraOnly
        let cameraIsFullscreen = geometry.camera.map {
            abs($0.rect.x) < 0.001 && abs($0.rect.y) < 0.001
                && abs($0.rect.width - width) < 0.001 && abs($0.rect.height - height) < 0.001
        } ?? false
        func controlsCamera(_ clip: VideoClip) -> Bool {
            clip.opacity > 0 && (clip.cameraMode == .hidden || clip.requestsCameraInset(
                cameraOnlyFullscreen: cameraOnly && cameraIsFullscreen, canvasAspect: width / height))
        }
        func videoTime(_ clip: VideoClip) -> TimeInterval {
            hostTime != sampleTime && controlsCamera(clip) ? hostTime : sampleTime
        }
        let activeVideos = project.timeline.videoClips
            .filter { project.timeline.presentsVideo($0, at: videoTime($0)) }
            .sorted(by: VideoClip.layerOrder)
        let host = MotionCameraSlot.Host.visible(video: activeVideos.last(where: controlsCamera),
            motion: activeAnimations.last { $0.cameraSlot?.isValid == true })
        let cameraHost: AnimationClip?
        let insetVideo: VideoClip?
        switch host {
        case let .motion(clip): cameraHost = clip; insetVideo = nil
        case let .video(clip): cameraHost = nil; insetVideo = clip.cameraMode == .hidden ? nil : clip
        case nil: cameraHost = nil; insetVideo = nil
        }
        let nativeCameraIsBackground = cameraOnly && cameraIsFullscreen
        let coveringVideo = host == nil && !nativeCameraIsBackground
            ? activeVideos.first { $0.cameraMode == .videoInFront } : nil
        let camera = geometry.camera.map { native in
            let base = MotionCameraSlot.Placement(rect: native.rect, radius: native.cornerRadius,
                contentPosition: settledCamera.contentPosition, contentScale: settledCamera.contentScale,
                borderWidth: native.borderWidth)
            let placement: MotionCameraSlot.Placement
            if let host, !host.hidesCamera, let cameraAspect {
                let videos = project.timeline.videoClips.filter(controlsCamera).sorted(by: VideoClip.layerOrder)
                let slots = project.timeline.animationClips.filter { $0.cameraSlot?.isValid == true && $0.opacity > 0 }
                    .sorted(by: MotionCameraSlot.layerOrder)
                func cameraVisible(at edge: Double, owner: MotionCameraSlot.Host?, target: MotionCameraSlot.Placement) -> Bool {
                    guard edge >= 0, edge < (outputDuration ?? .infinity) else { return false }
                    let cut = sourceProject.timeline.recordingSegmentBoundary(atOutputTime: edge)
                    if case .edited = sourceProject.timeline.sourceSequence, cut.segment == nil { return false }
                    guard sourceProject.hasVisibleCamera(in: cut.segment, at: edge, cameraTimeline: cameraTimeline)
                    else { return false }
                    let edgeMotion = cut.segment?.sceneStyle?.motion ?? sourceProject.motion
                    if !project.timeline.cameraMotionClips.isEmpty {
                        let track = cameraMotionTrack ?? CameraMotionTrack(project.timeline.cameraMotionClips)
                        let style = cut.segment?.sceneStyle?.camera ?? sourceProject.camera
                        let sample = track.sample(at: edge, base: CameraMotionState(base: style),
                            cameraAspectRatio: cameraAspect, canvasAspectRatio: width / height, motion: edgeMotion)
                        if sample.opacity <= 0 { return false }
                    }
                    if !project.timeline.stickerClips.isEmpty,
                       resolvedStickerTrack.sample(at: edge, suppressesInitialEntry: suppressesFirstStickerEntry)
                            .backdrop.cameraSuppression >= 0.999 { return false }
                    let ordered = project.timeline.videoClips.filter { project.timeline.presentsVideo($0, at: edge) }
                        .sorted(by: VideoClip.layerOrder)
                    let inFront: ArraySlice<VideoClip>
                    switch owner {
                    case let .motion(clip):
                        inFront = ordered.drop { $0.layerIndex <= clip.layerIndex }
                    case let .video(clip):
                        inFront = ordered.drop { !VideoClip.layerOrder(clip, $0) }
                    case nil:
                        let id = cut.segment?.resolvedSourceID ?? RecordingSource.primaryID
                        let source = sourceProject.source(id)?.capture.source ?? sourceProject.capture.source
                        if source == .cameraOnly && target.rect.width >= width && target.rect.height >= height {
                            inFront = ordered[...]
                        } else {
                            inFront = ordered.drop { $0.cameraMode != .videoInFront }
                        }
                    }
                    return !inFront.contains { clip in
                        var frame = FrameVideoScene(clip: clip, at: edge)
                        if clip.id == ordered.last?.id {
                            frame.applyZoom(allZooms.forTarget(.overlayVideo).sample(at: edge, motion: edgeMotion),
                                            sourceAspect: clip.aspect, canvasAspect: width / height)
                        }
                        return frame.covers(target.rect, on: canvasSize)
                    }
                }
                placement = MotionCameraSlot.placement(at: hostTime, frameRate: rate, host: host, videos: videos, slots: slots,
                    videoStart: project.timeline.videoPresentationStart, native: base, cameraVisible: cameraVisible) { owner in
                    var pose = base
                    switch owner {
                    case let .motion(clip):
                        guard let slot = clip.cameraSlot else { return base }
                        pose.rect = slot.rect(in: .init(width: width, height: height), clip: clip)
                        pose.radius = slot.radius * min(pose.rect.width, pose.rect.height)
                        pose.contentPosition = slot.contentPosition ?? base.contentPosition
                        pose.contentScale = slot.contentScale ?? base.contentScale
                    case .video:
                        // During a base fullscreen-to-shape cut the native rect
                        // still includes a fullscreen blend. Keep the inset shaped
                        // on both sides of that cut.
                        guard settledCamera.isFullscreen || cameraBase != nil else { return base }
                        var state = CameraMotionState(base: settledCamera)
                        state.layout = .shape(settledCamera.shape)
                        let track = cameraMotionTrack ?? CameraMotionTrack(project.timeline.cameraMotionClips)
                        let insetBase = sourceProject.cameraAppearanceTransitionSample(atOutputTime: sampleTime,
                            cameraAspectRatio: cameraAspect, canvasAspectRatio: width / height, boundary: boundary, cameraTimeline: cameraTimeline, asInset: true)
                        let sample = track.sample(at: sampleTime, base: state, cameraAspectRatio: cameraAspect,
                            canvasAspectRatio: width / height, motion: project.motion, baseSample: insetBase)
                        let target = CompositionSceneEvaluator.evaluateCamera(style: settledCamera, motion: sample,
                            screenZoomScale: geometry.screen.zoom.scale, canvasWidth: width, canvasHeight: height, styleScale: styleScale)
                        pose.rect = target.rect
                        pose.radius = target.cornerRadius
                        pose.borderWidth = target.borderWidth
                    }
                    return pose
                }
            } else {
                placement = base
            }
            let opening = openingSample(
                for: .camera,
                sequence: project.openingSequence,
                activeElements: availableOpeningElements,
                at: sampleTime,
                canvasWidth: width,
                canvasHeight: height
            )
            let openingCameraRect = openingRect(placement.rect, sample: opening)
            if let cameraHost, let slot = cameraHost.cameraSlot,
               let index = animations.lastIndex(where: { $0.id == cameraHost.id }) {
                animations[index].hostsCamera = true
                if placement.cameraReveal > 0 {
                    animations[index].movingMatte = .init(
                        aperture: slot.rect(in: .init(width: width, height: height), clip: cameraHost),
                        presented: openingCameraRect,
                        cornerRadius: placement.radius * opening.scale,
                        reveal: placement.cameraReveal)
                }
            }
            let visualFocus = placement.contentPosition
            let mirrored = settledCamera.isMirrored
            let sourceFocus = NormalizedPoint(x: mirrored ? 1 - visualFocus.x : visualFocus.x,
                                              y: visualFocus.y)
            var frame = FrameCameraScene(
                rect: openingCameraRect,
                contentFill: cameraSourceSize.flatMap {
                    CameraContentFill.layout(sourceWidth: $0.width, sourceHeight: $0.height,
                                             target: openingCameraRect, focus: sourceFocus, contentScale: placement.contentScale)
                },
                cornerRadius: placement.radius * opening.scale,
                borderWidth: placement.borderWidth * opening.scale,
                shadow: project.camera.shadowStrength > 0
                    ? FrameShadow(
                        opacity: project.camera.shadowStrength,
                        radius: 14 * styleScale,
                        offset: CompositionPoint(x: 0, y: 8 * styleScale)
                    )
                    : nil,
                opacity: project.camera.isHidden || host?.hidesCamera == true ? 0 : native.opacity * opening.opacity,
                isMirrored: mirrored,
                beauty: project.camera.beauty,
                usesCircularCorners: cameraHost?.cameraSlot?.aboveGraphics == false,
                sourceFocus: sourceFocus, contentScale: placement.contentScale
            )
            frame.insetVideoID = insetVideo?.id
            frame.coveringVideoID = coveringVideo?.id
            return frame
        }
        let cursor = cursorScene(
            sample: pointer.cursor,
            project: project,
            metrics: cursorMetrics,
            metricsByAssetID: cursorMetricsByAssetID,
            screen: screen,
            canvasSize: CompositionSize(width: width, height: height)
        )
        let stickerSample = stickerScenes(
            resolvedStickerTrack, at: sampleTime, suppressesInitialEntry: suppressesFirstStickerEntry
        )
        var stickers = stickerSample.stickers
        let stickerOpening = openingSample(
            for: .stickers,
            sequence: project.openingSequence,
            activeElements: availableOpeningElements,
            at: sampleTime,
            canvasWidth: width,
            canvasHeight: height
        )
        stickers = stickers.map { scene in
            var result = scene
            result.offset = NormalizedPoint(
                x: scene.offset.x + stickerOpening.offset.x / width,
                y: scene.offset.y + stickerOpening.offset.y / height
            )
            result.scale *= stickerOpening.scale
            result.opacity *= stickerOpening.opacity
            return result
        }
        let cameraBehindOverlays = cameraHost?.cameraSlot.map { !$0.aboveGraphics }
            ?? (coveringVideo != nil || (insetVideo == nil && nativeCameraIsBackground))
        var order: [FrameLayerRole] = cameraOnly ? [.background] : [.background, .screen]
        if cameraBehindOverlays, let camera, camera.opacity > 0 { order.append(.camera) }
        if cursor != nil { order.append(.cursor) }
        // Spotlight is one dimming effect above the complete base picture,
        // not separate treatments for the wallpaper and screen texture.
        if screen.focusEffect != nil || activeMosaics.contains(where: { $0.style == .spotlight }) {
            order.append(.spotlight)
        }
        var videos = activeVideos.map { FrameVideoScene(clip: $0, at: videoTime($0)) }
        if let top = activeVideos.last {
            let zoom = allZooms.forTarget(.overlayVideo).sample(at: sampleTime, motion: project.motion)
            videos[videos.count - 1].applyZoom(zoom, sourceAspect: top.aspect, canvasAspect: width / height)
        }
        if !videos.isEmpty { order.append(.videos) }
        if !stickers.isEmpty { order.append(.stickers) }
        if !animations.isEmpty { order.append(.animations) }
        if !cameraBehindOverlays, let camera, camera.opacity > 0 { order.append(.camera) }
        let subtitle = project.timeline.subtitleCues
            .first { $0.timing.contains(sampleTime) && !$0.text.isEmpty }
            .map {
                FrameSubtitleScene(
                    cueID: $0.id,
                    text: $0.text,
                    secondaryText: project.timeline.subtitleStyle.showsSecondary ? $0.secondaryText : nil,
                    style: project.timeline.subtitleStyle,
                    elapsed: max(sampleTime - $0.timing.startTime, 0),
                    remaining: max($0.timing.endTime - sampleTime, 0)
                )
            }
        if subtitle != nil { order.append(.subtitles) }
        // EDT-054: inside a main-track inserted video the recording's camera,
        // cursor and regions do not apply. An explicitly scoped preset may
        // supply this occurrence's own crop without borrowing the recording's.
        let playback = boundary.insertedPlayback(at: sampleTime)
        let inserted = playback?.media
        let insertedNow = inserted != nil
        var presentedScreen = screen
        if cameraOnly { presentedScreen.opacity = 0 }
        if let inserted {
            presentedScreen.sourceCrop = boundary.segment?.sceneStyle?.canvas.crop ?? .full
            presentedScreen.mosaics = []
            presentedScreen.focusEffect = nil
            presentedScreen.fillsFrame = inserted.imagePath == nil
            // EDT-067: by default a main-track insert (title card, black)
            // covers the whole canvas with no frame styling.
            if !inserted.usesFrameStyle, inserted.imagePath == nil {
                // Start with the same cover framing as legacy full-canvas
                // inserts, then transform the actual source rectangle. Scaling
                // down can reveal the whole image instead of a cropped tile.
                let aspect = max(sourceAspectRatio * presentedScreen.sourceCrop.width
                    / max(presentedScreen.sourceCrop.height, 0.001), 0.001)
                let scale = min(max(project.canvas.contentScale, 0.25), 4)
                let imageWidth = max(width, height * aspect) * scale
                let imageHeight = imageWidth / aspect
                let rect = CompositionRect(
                    x: (width - imageWidth) * project.canvas.contentPosition.x,
                    y: (height - imageHeight) * project.canvas.contentPosition.y,
                    width: imageWidth, height: imageHeight)
                presentedScreen.baseRect = rect
                presentedScreen.finalRect = rect
                presentedScreen.projectedQuad = ProjectedScreenQuad(
                    topLeft: CompositionPoint(x: rect.x, y: rect.y),
                    topRight: CompositionPoint(x: rect.x + rect.width, y: rect.y),
                    bottomRight: CompositionPoint(x: rect.x + rect.width, y: rect.y + rect.height),
                    bottomLeft: CompositionPoint(x: rect.x, y: rect.y + rect.height))
                presentedScreen.cornerRadius = 0
                presentedScreen.borderWidth = 0
                presentedScreen.shadow = nil
                presentedScreen.decoration = .none
            }
        }
        return FrameScene(
            time: sampleTime,
            canvasSize: CompositionSize(width: width, height: height),
            color: color,
            background: FrameBackgroundScene(
                source: project.canvas.backgroundSource,
                blurRadius: project.canvas.backgroundBlur * styleScale,
                patternScale: project.canvas.patternScale,
                patternOpacity: project.canvas.patternOpacity
            ),
            screen: presentedScreen,
            camera: insertedNow ? nil : camera,
            cursor: insertedNow ? nil : cursor,
            stickers: stickers,
            stickerBackdrop: stickerSample.backdrop,
            animations: animations,
            subtitle: subtitle,
            videos: videos,
            layerOrder: order,
            insertedMotion: playback.flatMap { playback in
                playback.media.motionPath.map {
                    FrameInsertedMotionScene(sourcePath: $0, localTime: playback.localTime, properties: playback.media.properties,
                                             elementEdits: playback.media.elementEdits, playbackRate: playback.playbackRate)
                }
            },
            insertedImage: playback.flatMap { playback in
                playback.media.imagePath.map {
                    FrameInsertedImageScene(sourcePath: $0, localTime: playback.localTime)
                }
            }
        )
    }

    private static func stickerScenes(
        _ track: StickerTransitionTrack,
        at time: TimeInterval,
        suppressesInitialEntry: Bool = false
    ) -> (stickers: [FrameStickerScene], backdrop: FrameStickerBackdropScene) {
        let sample = track.sample(at: time, suppressesInitialEntry: suppressesInitialEntry)
        let stickers = sample.stickers.map { sample in
            let clip = sample.clip
            let visibility = sample.visibility
            let transform = stickerAnimationTransform(
                preset: sample.preset,
                progress: sample.progress,
                position: clip.position,
                width: clip.width
            )
            return FrameStickerScene(
                id: clip.id,
                relativePath: clip.relativePath,
                position: clip.position,
                width: min(max(clip.width, 0.02), 2),
                rotationRadians: clip.rotationDegrees * .pi / 180,
                opacity: min(max(clip.opacity, 0), 1) * visibility,
                scale: transform.scale,
                offset: transform.offset,
                cornerRadius: max(clip.cornerRadius, 0),
                borderWidth: max(clip.borderWidth, 0),
                borderColor: clip.borderColor,
                shadowOpacity: min(max(clip.shadowOpacity, 0), 1),
                shadowRadius: max(clip.shadowRadius, 0),
                shadowOffset: CompositionPoint(
                    x: clip.shadowOffsetX,
                    y: clip.shadowOffsetY
                ),
                backdropBlur: max(clip.backdropBlur, 0) * visibility,
                backdropBlurIncludesCamera: clip.backdropBlurIncludesCamera,
                hidesScreen: clip.hidesScreen,
                hidesCamera: clip.hidesCamera,
                transitionProgress: visibility,
                layerIndex: clip.layerIndex,
                sourceTime: clip.sourceStart + max(time - clip.timing.startTime, 0) * clip.playbackRate
            )
        }
        return (stickers, sample.backdrop)
    }

    /// Sticker motion deliberately travels from outside the canvas instead of
    /// shifting by a token 8%. `progress` is eased before it reaches this
    /// function, so entry and exit share one continuous, non-linear path.
    private static func stickerAnimationTransform(
        preset: StickerAnimationPreset,
        progress: Double,
        position: NormalizedPoint,
        width: Double
    ) -> (scale: Double, offset: NormalizedPoint) {
        let p = min(max(progress, 0), 1)
        let travel = 1 - p
        // Keep the historical generous off-canvas travel for normal stickers,
        // but extend it when a user makes the card unusually wide so no edge
        // remains visible at progress zero.
        let halfExtent = max(width, 0.02) / 2
        let outsideLeading = min(-0.85, -halfExtent - 0.06)
        let outsideTrailing = max(1.85, 1 + halfExtent + 0.06)
        let left = outsideLeading - position.x
        let right = outsideTrailing - position.x
        let top = outsideLeading - position.y
        let bottom = outsideTrailing - position.y
        var offset = NormalizedPoint(x: 0, y: 0)
        var scale = 1.0
        switch preset {
        case .none, .fade:
            break
        case .pop:
            // The target stays stable while the card accelerates out of a
            // smaller footprint; smootherStep avoids the old linear-looking
            // scale and keeps the final frame exactly at 1×.
            scale = 0.72 + p * 0.28
        case .slideLeft:
            offset.x = left * travel
        case .slideRight:
            offset.x = right * travel
        case .slideUp:
            offset.y = top * travel
        case .slideDown:
            offset.y = bottom * travel
        case .slideTopLeft:
            offset.x = left * travel
            offset.y = top * travel
        case .slideTopRight:
            offset.x = right * travel
            offset.y = top * travel
        case .slideBottomLeft:
            offset.x = left * travel
            offset.y = bottom * travel
        case .slideBottomRight:
            offset.x = right * travel
            offset.y = bottom * travel
        }
        return (scale, offset)
    }

    private struct OpeningSample {
        var opacity: Double
        var scale: Double
        var offset: CompositionPoint
        var rotationX: Double
        var rotationY: Double
        var perspective: Double

        static let identity = OpeningSample(
            opacity: 1,
            scale: 1,
            offset: CompositionPoint(x: 0, y: 0),
            rotationX: 0,
            rotationY: 0,
            perspective: 0
        )
    }

    private static func openingSample(
        for element: OpeningSequenceElement,
        sequence: OpeningSequence,
        activeElements: [OpeningSequenceElement],
        at time: TimeInterval,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> OpeningSample {
        guard sequence.isEnabled,
              time < sequence.duration,
              let index = activeElements.firstIndex(of: element) else {
            return .identity
        }
        let effectiveStagger = min(
            sequence.stagger,
            sequence.maximumStagger(for: activeElements.count)
        )
        let lastDelay = effectiveStagger * Double(max(activeElements.count - 1, 0))
        let itemDuration = max(
            sequence.duration - lastDelay,
            OpeningSequence.minimumElementDuration
        )
        let start = effectiveStagger * Double(index)
        let linear = min(max((time - start) / itemDuration, 0), 1)
        let eased = ElementMotionEvaluator.progress(linear, curve: sequence.motionCurve)
        let opacity = ElementMotionEvaluator.progress(
            min(linear * 1.65, 1),
            curve: sequence.motionCurve
        )
        let remaining = 1 - eased
        // Translation settles quickly enough to feel responsive, while a 3D
        // pose needs to remain visible after the card enters the canvas. The
        // former shared quartic falloff reduced tilt to almost zero before the
        // first useful on-canvas frame.
        let rotationRemaining = pow(1 - linear, 1.5)
        let overshoot = 1 + 1.35 * pow(linear - 1, 3) + 0.35 * pow(linear - 1, 2)
        let scaleStart: Double
        let initialOffset: CompositionPoint
        let rotationX: Double
        let rotationY: Double
        let perspective: Double
        switch (sequence.preset, element) {
        case (.converge, .screen):
            scaleStart = 0.72
            initialOffset = CompositionPoint(x: -canvasWidth * 1.05, y: -canvasHeight * 0.62)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.converge, .camera):
            scaleStart = 0.58
            initialOffset = CompositionPoint(x: canvasWidth * 1.12, y: canvasHeight * 0.72)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.converge, .stickers):
            scaleStart = 0.62
            initialOffset = CompositionPoint(x: -canvasWidth * 1.30, y: -canvasHeight * 0.70)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.sideSlide, .screen):
            scaleStart = 0.94
            initialOffset = CompositionPoint(x: -canvasWidth * 1.12, y: 0)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.sideSlide, .camera):
            scaleStart = 0.88
            initialOffset = CompositionPoint(x: canvasWidth * 1.15, y: 0)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.sideSlide, .stickers):
            scaleStart = 0.9
            initialOffset = CompositionPoint(x: -canvasWidth * 1.35, y: 0)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.light3D, .screen):
            scaleStart = 0.80
            initialOffset = CompositionPoint(x: -canvasWidth * 1.05, y: canvasHeight * 0.08)
            rotationX = 9 * rotationRemaining
            rotationY = -22 * rotationRemaining
            perspective = 0.72 * rotationRemaining
        case (.light3D, .camera):
            scaleStart = 0.72
            initialOffset = CompositionPoint(x: canvasWidth * 1.10, y: canvasHeight * 0.16)
            rotationX = 0
            rotationY = 0
            perspective = 0
        case (.light3D, .stickers):
            scaleStart = 0.76
            initialOffset = CompositionPoint(x: -canvasWidth * 1.30, y: -canvasHeight * 0.12)
            rotationX = 0
            rotationY = 0
            perspective = 0
        }
        let settledScale = min(max(overshoot, 0), 1.04)
        return OpeningSample(
            opacity: opacity,
            scale: scaleStart + (settledScale - scaleStart) * eased,
            offset: CompositionPoint(
                x: initialOffset.x * remaining,
                y: initialOffset.y * remaining
            ),
            rotationX: rotationX,
            rotationY: rotationY,
            perspective: perspective
        )
    }

    private static func openingRect(
        _ rect: CompositionRect,
        sample: OpeningSample
    ) -> CompositionRect {
        let width = rect.width * sample.scale
        let height = rect.height * sample.scale
        return CompositionRect(
            x: rect.midX - width / 2 + sample.offset.x,
            y: rect.midY - height / 2 + sample.offset.y,
            width: width,
            height: height
        )
    }

    private static func smootherStep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// Keep privacy and presentation semantics explicit. Ordinary redaction
    /// defaults to `.none`; authored linear/smooth transitions are evaluated
    /// identically by preview and export, with independently hard edges when
    /// either duration is zero.
    private static func overlayEffectProgress(
        timing: OverlayTiming,
        style: MosaicTransitionStyle,
        enterDuration: TimeInterval,
        exitDuration: TimeInterval,
        at time: TimeInterval
    ) -> Double {
        guard timing.duration > 0 else { return 0 }
        guard style != .none else { return 1 }
        let elapsed = max(time - timing.startTime, 0)
        let remaining = max(timing.endTime - time, 0)
        let linearEnter = enterDuration > 0
            ? min(max(elapsed / enterDuration, 0), 1)
            : 1
        let linearExit = exitDuration > 0
            ? min(max(remaining / exitDuration, 0), 1)
            : 1
        let enter: Double
        let exit: Double
        switch style {
        case .none:
            return 1
        case .linear:
            enter = linearEnter
            exit = linearExit
        case .smooth:
            enter = smootherStep(linearEnter)
            exit = smootherStep(linearExit)
        }
        return min(enter, exit)
    }

    private static func screenDecoration(
        style: ScreenFrameStyle,
        frameScale: Double,
        toolbarScale: Double,
        outerCornerRadius: Double?,
        contentCornerRadius: Double?,
        title: String,
        browserAddress: String,
        geometry: ScreenSceneEvaluation,
        styleScale: Double,
        groupScale: Double = 1
    ) -> FrameScreenDecoration {
        guard style != .none else { return .none }
        let authoredFrameScale = min(max(frameScale, 0.6), 1.6)
        let motionScale = max(
            geometry.manualScale * geometry.viewport.scale * groupScale,
            0.000_1
        )
        let scale = max(
            styleScale * motionScale * authoredFrameScale,
            0.000_1
        )
        let authoredInsets = ScreenFrameGeometry.decorationInsetsAtScaleOne(
            style: style,
            frameScale: frameScale,
            toolbarScale: toolbarScale,
            fittedWidth: geometry.fittedRect.width,
            fittedHeight: geometry.fittedRect.height,
            styleScale: styleScale
        )
        let topInset = authoredInsets.top * motionScale
        let rightInset = authoredInsets.right * motionScale
        let bottomInset = authoredInsets.bottom * motionScale
        let leftInset = authoredInsets.left * motionScale
        let outerRect = CompositionRect(
            x: geometry.finalRect.x - leftInset,
            y: geometry.finalRect.y - topInset,
            width: geometry.finalRect.width + leftInset + rightInset,
            height: geometry.finalRect.height + topInset + bottomInset
        )
        // A slight overlap fills the source's rounded top-corner cutouts while
        // preserving the exact content rectangle and crop calculation.
        let toolbarRect = CompositionRect(
            x: outerRect.x,
            y: outerRect.y,
            width: outerRect.width,
            height: topInset + min(2 * scale, topInset * 0.08)
        )
        let isDark = style == .windowDark || style == .browserDark
            || style == .devicePhone || style == .deviceTablet
            || style == .devicePhonePortrait || style == .devicePhoneLandscape
            || style == .deviceTabletPortrait || style == .deviceTabletLandscape
        let kind: FrameScreenChromeKind = switch style {
        case .browserLight, .browserDark: .browser
        case .devicePhone:
            geometry.finalRect.width >= geometry.finalRect.height
                ? .devicePhoneLandscape : .devicePhonePortrait
        case .deviceTablet:
            geometry.finalRect.width >= geometry.finalRect.height
                ? .deviceTabletLandscape : .deviceTabletPortrait
        case .devicePhonePortrait: .devicePhonePortrait
        case .devicePhoneLandscape: .devicePhoneLandscape
        case .deviceTabletPortrait: .deviceTabletPortrait
        case .deviceTabletLandscape: .deviceTabletLandscape
        case .windowLight, .windowDark, .none: .window
        }
        let authoredOuterRadius = min(max(
            outerCornerRadius ?? style.defaultOuterCornerRadius,
            0
        ), 160)
        let authoredContentRadius = min(max(
            contentCornerRadius ?? style.defaultContentCornerRadius,
            0
        ), 160)
        let resolvedOuterRadius: Double
        let resolvedContentRadius: Double
        if kind.isDevice {
            let contentShortEdge = min(geometry.finalRect.width, geometry.finalRect.height)
            let bezel = min(topInset, leftInset)
            let nativeContentRadius = contentShortEdge * (kind.isPhone ? 0.145 : 0.034)
            let contentFactor = authoredContentRadius / max(style.defaultContentCornerRadius, 1)
            let outerFactor = authoredOuterRadius / max(style.defaultOuterCornerRadius, 1)
            resolvedContentRadius = nativeContentRadius * contentFactor
            resolvedOuterRadius = (nativeContentRadius + bezel) * outerFactor
        } else {
            resolvedContentRadius = authoredContentRadius * scale
            resolvedOuterRadius = authoredOuterRadius * scale
        }
        let outerCornerRadius = min(
            resolvedOuterRadius,
            min(outerRect.width, outerRect.height) / 2
        )
        let contentCornerRadius = min(
            resolvedContentRadius,
            min(geometry.finalRect.width, geometry.finalRect.height) / 2
        )
        return .chrome(
            FrameScreenChromeScene(
                kind: kind,
                outerRect: outerRect,
                toolbarRect: toolbarRect,
                contentRect: geometry.finalRect,
                outerCornerRadius: outerCornerRadius,
                contentCornerRadius: contentCornerRadius,
                surfaceColor: isDark
                    ? HexColor(rgb24: 0x1E_1E_21)
                    : HexColor(rgb24: 0xEE_EE_F0),
                toolbarColor: isDark
                    ? HexColor(rgb24: 0x2C_2C_30)
                    : HexColor(rgb24: 0xF7_F7_F8),
                separatorColor: isDark
                    ? HexColor(rgb24: 0x16_16_18)
                    : HexColor(rgb24: 0xDD_DD_E1),
                fieldColor: isDark
                    ? HexColor(rgb24: 0x3B_3B_40)
                    : HexColor(rgb24: 0xE8_E8_EC),
                glyphColor: isDark
                    ? HexColor(rgb24: 0xA4_A4_AB)
                    : HexColor(rgb24: 0x6E_6E_76),
                title: title,
                browserAddress: browserAddress
            )
        )
    }

    private static func cursorScene(
        sample: PointerSample?,
        project: RecorderProject,
        metrics: CursorAssetMetrics?,
        metricsByAssetID: [CursorAssetID: CursorAssetMetrics],
        screen: FrameScreenScene,
        canvasSize: CompositionSize
    ) -> FrameCursorScene? {
        guard let sample else { return nil }
        let assetID = project.cursorStyle.assetID == .automatic
            ? (sample.recordedCursorAssetID ?? .systemArrow)
            : project.cursorStyle.assetID
        guard let metrics = metricsByAssetID[assetID] ?? metrics else { return nil }
        let crop = screen.sourceCrop.clamped()
        let local = NormalizedPoint(
            x: (sample.location.x - crop.x) / crop.width,
            y: (sample.location.y - crop.y) / crop.height
        )
        guard (0...1).contains(local.x), (0...1).contains(local.y) else { return nil }
        let content = screen.sourceContentRect
        let point = CompositionPoint(
            x: content.x + local.x * content.width,
            y: content.y + local.y * content.height
        )
        guard let layout = CursorRenderGeometry.layout(
            pointer: point,
            canvasShortEdge: canvasSize.shortEdge,
            styleSize: project.cursorStyle.size,
            metrics: metrics
        ) else { return nil }
        return FrameCursorScene(
            assetID: assetID,
            metrics: metrics,
            layout: layout,
            isClicking: sample.isClicking,
            clickPhase: sample.clickPhase,
            clickStyle: project.cursorStyle.clickEffectStyle,
            clickColor: project.cursorStyle.clickColor,
            clickOpacity: project.cursorStyle.clickOpacity,
            clickScale: project.cursorStyle.clickScale,
            rotationRadians: sample.rotationRadians,
            pressScale: sample.pressScale,
            shadow: FrameShadow(
                opacity: 0.42,
                radius: max(layout.clickEffectHeight * 1.5 / 44, 0.5),
                offset: CompositionPoint(
                    x: 0,
                    y: max(layout.clickEffectHeight / 44, 0.5)
                )
            )
        )
    }

}
