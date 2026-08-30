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

    public var isPortrait: Bool {
        self == .devicePhonePortrait || self == .deviceTabletPortrait
    }
}

/// Fully evaluated vector chrome. Geometry is expressed in the same top-left
/// canvas coordinates as the screen, so the single renderer can draw it before
/// applying the screen's 3D projection.
public struct FrameScreenChromeScene: Equatable, Sendable {
    public var kind: FrameScreenChromeKind
    public var outerRect: CompositionRect
    public var toolbarRect: CompositionRect
    public var outerCornerRadius: Double
    public var contentCornerRadius: Double
    public var surfaceColor: HexColor
    public var toolbarColor: HexColor
    public var separatorColor: HexColor
    public var fieldColor: HexColor
    public var glyphColor: HexColor

    public init(
        kind: FrameScreenChromeKind,
        outerRect: CompositionRect,
        toolbarRect: CompositionRect,
        outerCornerRadius: Double,
        contentCornerRadius: Double = 0,
        surfaceColor: HexColor,
        toolbarColor: HexColor,
        separatorColor: HexColor,
        fieldColor: HexColor,
        glyphColor: HexColor
    ) {
        self.kind = kind
        self.outerRect = outerRect
        self.toolbarRect = toolbarRect
        self.outerCornerRadius = max(outerCornerRadius, 0)
        self.contentCornerRadius = max(contentCornerRadius, 0)
        self.surfaceColor = surfaceColor
        self.toolbarColor = toolbarColor
        self.separatorColor = separatorColor
        self.fieldColor = fieldColor
        self.glyphColor = glyphColor
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

/// One-frame displacement used by the layer-local motion treatment. Values are
/// authored in the scene's top-left canvas coordinate system.
public struct FrameLayerMotion: Equatable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
    public var strength: Double

    public init(deltaX: Double, deltaY: Double, strength: Double) {
        self.deltaX = deltaX.isFinite ? deltaX : 0
        self.deltaY = deltaY.isFinite ? deltaY : 0
        self.strength = min(max(strength.isFinite ? strength : 0, 0), 1)
    }

    public static let none = FrameLayerMotion(deltaX: 0, deltaY: 0, strength: 0)

    public var distance: Double {
        hypot(deltaX, deltaY) * strength
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
    public var fittedRect: CompositionRect
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
    public var motion: FrameLayerMotion
    public var opacity: Double

    public var projectionRect: CompositionRect {
        decoration.projectionRect ?? finalRect
    }

    public init(
        sourceCrop: NormalizedCrop,
        fittedRect: CompositionRect,
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
        motion: FrameLayerMotion = .none,
        opacity: Double = 1
    ) {
        self.sourceCrop = sourceCrop.clamped()
        self.fittedRect = fittedRect
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
        self.motion = motion
        self.opacity = min(max(opacity, 0), 1)
    }
}

public struct FrameCameraScene: Equatable, Sendable {
    public var rect: CompositionRect
    public var contentFill: CameraContentFillLayout?
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var shadow: FrameShadow?
    public var opacity: Double
    public var isMirrored: Bool
    public var motion: FrameLayerMotion

    public init(
        rect: CompositionRect,
        contentFill: CameraContentFillLayout?,
        cornerRadius: Double,
        borderWidth: Double,
        borderColor: HexColor = .white,
        shadow: FrameShadow?,
        opacity: Double,
        isMirrored: Bool,
        motion: FrameLayerMotion = .none
    ) {
        self.rect = rect
        self.contentFill = contentFill
        self.cornerRadius = max(cornerRadius, 0)
        self.borderWidth = max(borderWidth, 0)
        self.borderColor = borderColor
        self.shadow = shadow
        self.opacity = min(max(opacity, 0), 1)
        self.isMirrored = isMirrored
        self.motion = motion
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
    /// Position inside the cropped screen before screen projection.
    public var normalizedScreenPosition: NormalizedPoint
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
    public var shadow: FrameShadow?
    public var attachment: FrameCursorAttachment
    public var motion: FrameLayerMotion

    public var effectiveClickColor: HexColor {
        clickColor ?? metrics.clickColor
    }

    public init(
        assetID: CursorAssetID,
        metrics: CursorAssetMetrics,
        normalizedScreenPosition: NormalizedPoint,
        layout: CursorRenderLayout,
        isClicking: Bool,
        clickPhase: PointerClickPhase? = nil,
        clickStyle: CursorClickEffectStyle = .ripple,
        clickColor: HexColor? = nil,
        clickOpacity: Double = 0.8,
        clickScale: Double = 1.0,
        rotationRadians: Double = 0,
        shadow: FrameShadow?,
        attachment: FrameCursorAttachment = .screen,
        motion: FrameLayerMotion = .none
    ) {
        self.assetID = assetID
        self.metrics = metrics
        self.normalizedScreenPosition = normalizedScreenPosition
        self.layout = layout
        self.isClicking = isClicking
        self.clickPhase = clickPhase
        self.clickStyle = clickStyle
        self.clickColor = clickColor
        self.clickOpacity = min(max(clickOpacity, 0.05), 1.0)
        self.clickScale = min(max(clickScale, 0.4), 3.0)
        self.rotationRadians = rotationRadians.isFinite ? rotationRadians : 0
        self.shadow = shadow
        self.attachment = attachment
        self.motion = motion
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
    /// applied. Backdrop suppression follows this value so it never exposes a
    /// hard first or last frame merely because the sticker is translucent.
    public var transitionProgress: Double
    public var layerIndex: Int
}

public struct FrameProgressScene: Equatable, Sendable {
    public var placement: ProgressOverlayPlacement
    public var position: NormalizedPoint
    public var width: Double
    public var bandHeight: Double
    public var textSize: Double
    public var thickness: Double
    public var fraction: Double
    public var backgroundColor: HexColor
    public var backgroundOpacity: Double
    public var trackColor: HexColor
    public var fillColor: HexColor
    public var nodeColor: HexColor
    public var textColor: HexColor
    public var chapters: [FrameProgressChapterScene]
    public var opacity: Double
    public var scale: Double
    public var offset: NormalizedPoint
}

public struct FrameProgressChapterScene: Equatable, Sendable {
    public var fraction: Double
    public var title: String

    public init(fraction: Double, title: String) {
        self.fraction = fraction
        self.title = title
    }
}

public enum FrameLayerRole: String, Equatable, Sendable {
    case background
    case screen
    case cursor
    case spotlight
    case camera
    case stickers
    case progress
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
    public var progress: FrameProgressScene?
    public var layerOrder: [FrameLayerRole]

    public init(
        time: TimeInterval,
        canvasSize: CompositionSize,
        color: FrameColorContract,
        background: FrameBackgroundScene,
        screen: FrameScreenScene,
        camera: FrameCameraScene?,
        cursor: FrameCursorScene?,
        stickers: [FrameStickerScene] = [],
        progress: FrameProgressScene? = nil,
        layerOrder: [FrameLayerRole]
    ) {
        self.time = time
        self.canvasSize = canvasSize
        self.color = color
        self.background = background
        self.screen = screen
        self.camera = camera
        self.cursor = cursor
        self.stickers = stickers
        self.progress = progress
        self.layerOrder = layerOrder
    }
}

/// One output-frame request. Motion treatment is already lowered into the
/// scene's moving layers, so preview and export consume one identical scene.
public struct FrameRenderPlan: Equatable, Sendable {
    public var presentationTime: TimeInterval
    public var outputDuration: TimeInterval
    public var frameRate: Int
    public var scene: FrameScene

    public init(
        presentationTime: TimeInterval,
        outputDuration: TimeInterval,
        frameRate: Int,
        scene: FrameScene
    ) {
        self.presentationTime = presentationTime
        self.outputDuration = outputDuration
        self.frameRate = frameRate
        self.scene = scene
    }
}

/// The only project-aware per-frame interpreter. Render backends receive the
/// resulting immutable plan and API-specific media-frame handles separately.
public enum FrameSceneEvaluator {
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
        activePrimaryRange: MediaTimeRange? = nil,
        activeCameraRange: MediaTimeRange? = nil,
        color: FrameColorContract = .sdrDesktop
    ) -> FrameRenderPlan {
        let safeDuration = outputDuration.isFinite ? max(outputDuration, 0) : 0
        let safeTime = presentationTime.isFinite
            ? min(max(presentationTime, 0), safeDuration)
            : 0
        let cameraIsAvailable = activeCameraRange.map {
            safeTime >= $0.start && safeTime < $0.end
        } ?? true
        var current = scene(
            project: project,
            time: safeTime,
            outputDuration: safeDuration,
            canvasSize: canvasSize,
            sourceAspectRatio: sourceAspectRatio,
            cameraSourceSize: cameraIsAvailable ? cameraSourceSize : nil,
            pointerTrack: pointerTrack,
            cursorMetrics: cursorMetrics,
            cursorMetricsByAssetID: cursorMetricsByAssetID,
            zoomTrack: zoomTrack,
            screenMotionTrack: screenMotionTrack,
            cameraMotionTrack: cameraMotionTrack,
            color: color
        )
        let descriptor = project.motion.frameMotionBlur
        // Derive blur from the layer's outgoing motion. Sampling the previous
        // frame left a non-zero trail on the exact animation endpoint, then
        // removed it one frame later; borders and shadows consequently looked
        // as if they popped after the movement had already finished.
        let nextTime = min(
            safeTime + 1 / Double(max(frameRate, 1)),
            safeDuration
        )
        let staysInsidePrimary = activePrimaryRange.map {
            safeTime >= $0.start && safeTime < $0.end
                && nextTime >= $0.start && nextTime < $0.end
        } ?? true
        if descriptor.isEnabled,
           descriptor.strength > 0,
           nextTime > safeTime,
           staysInsidePrimary {
            let nextCameraIsAvailable = activeCameraRange.map {
                nextTime >= $0.start && nextTime < $0.end
            } ?? true
            let next = scene(
                project: project,
                time: nextTime,
                outputDuration: safeDuration,
                canvasSize: canvasSize,
                sourceAspectRatio: sourceAspectRatio,
                cameraSourceSize: nextCameraIsAvailable ? cameraSourceSize : nil,
                pointerTrack: pointerTrack,
                cursorMetrics: cursorMetrics,
                cursorMetricsByAssetID: cursorMetricsByAssetID,
                zoomTrack: zoomTrack,
                screenMotionTrack: screenMotionTrack,
                cameraMotionTrack: cameraMotionTrack,
                color: color
            )
            current = applyingLayerMotion(
                to: current,
                toward: next,
                strength: descriptor.strength
            )
        }
        return FrameRenderPlan(
            presentationTime: safeTime,
            outputDuration: safeDuration,
            frameRate: max(frameRate, 1),
            scene: current
        )
    }

    public static func scene(
        project: RecorderProject,
        time: TimeInterval,
        outputDuration: TimeInterval? = nil,
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
        color: FrameColorContract = .sdrDesktop
    ) -> FrameScene {
        let width = max(canvasSize.width, 2)
        let height = max(canvasSize.height, 2)
        let sampleTime = time.isFinite ? max(time, 0) : 0
        let pointer = pointerEvaluation ?? pointerTrack?.evaluation(
            at: sampleTime,
            motion: project.motion,
            style: project.cursorStyle
        ) ?? PointerTrackEvaluation(position: nil, cursor: nil)
        let resolvedZoomTrack = zoomTrack ?? ZoomAnimationTrack(project.zoomAnimations)
        let activeZoomClip = resolvedZoomTrack.activeClip(at: sampleTime)
        let activeAutomaticClip = activeZoomClip.flatMap {
            $0.origin == .automatic ? $0 : nil
        }
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
                    at: previous.endTime,
                    clip: previous,
                    motion: project.motion
                ) ?? previous.focus
            }
        let cameraAspect = cameraSourceSize.map {
            max($0.width, 1) / max($0.height, 1)
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
            sourceAspectRatio: sourceAspectRatio,
            cameraAspectRatio: cameraAspect,
            styleScale: styleScale,
            automaticZoomFocus: automaticCameraPosition,
            inheritedAutomaticZoomFocus: inheritedAutomaticCameraPosition,
            zoomTrack: resolvedZoomTrack,
            screenMotionTrack: screenMotionTrack,
            cameraMotionTrack: cameraMotionTrack
        )
        // The opening roster must remain stable for its whole duration. Using
        // the current frame's active clips made every earlier element change
        // delay and duration when a sticker or camera appeared mid-opening.
        let hasOpeningSticker = project.timeline.stickerClips.contains {
            $0.timing.startTime <= 0.000_1 && $0.timing.endTime > 0.000_1
        }
        let hasOpeningCamera = (project.media?.camera != nil || cameraSourceSize != nil)
            && !project.camera.isHidden
        let availableOpeningElements = project.openingSequence.elementOrder.filter { element in
            guard project.openingSequence.includedElements.contains(element) else { return false }
            switch element {
            case .screen: return true
            case .progress: return project.timeline.progressOverlay != nil
            case .camera: return hasOpeningCamera
            case .stickers: return hasOpeningSticker
            }
        }
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
        let screen = FrameScreenScene(
            sourceCrop: project.canvas.crop,
            fittedRect: screenGeometry.fittedRect,
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
            opacity: screenOpening.opacity
        )
        let camera = geometry.camera.map { evaluation in
            let opening = openingSample(
                for: .camera,
                sequence: project.openingSequence,
                activeElements: availableOpeningElements,
                at: sampleTime,
                canvasWidth: width,
                canvasHeight: height
            )
            let openingCameraRect = openingRect(evaluation.rect, sample: opening)
            return FrameCameraScene(
                rect: openingCameraRect,
                contentFill: cameraSourceSize.flatMap {
                    let visualFocus = project.camera.contentPosition
                    return CameraContentFill.layout(
                        sourceWidth: $0.width,
                        sourceHeight: $0.height,
                        target: openingCameraRect,
                        // Mirroring happens after crop. Interpret the editor's
                        // horizontal control in the final visual direction.
                        focus: NormalizedPoint(
                            x: project.camera.isMirrored
                                ? 1 - visualFocus.x
                                : visualFocus.x,
                            y: visualFocus.y
                        ),
                        contentScale: project.camera.contentScale
                    )
                },
                cornerRadius: evaluation.cornerRadius * opening.scale,
                borderWidth: evaluation.borderWidth * opening.scale,
                shadow: project.camera.shadowStrength > 0
                    ? FrameShadow(
                        opacity: project.camera.shadowStrength,
                        radius: 14 * styleScale,
                        offset: CompositionPoint(x: 0, y: 8 * styleScale)
                    )
                    : nil,
                opacity: project.camera.isHidden ? 0 : evaluation.opacity * opening.opacity,
                isMirrored: project.camera.isMirrored
            )
        }
        let cursor = cursorScene(
            sample: pointer.cursor,
            project: project,
            metrics: cursorMetrics,
            metricsByAssetID: cursorMetricsByAssetID,
            screen: screen,
            canvasSize: CompositionSize(width: width, height: height),
            styleScale: styleScale
        )
        var stickers = stickerScenes(
            project.timeline.stickerClips,
            at: sampleTime,
            suppressesInitialEntry: project.openingSequence.isEnabled
                && project.openingSequence.includedElements.contains(.stickers)
        )
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
        var progress = project.timeline.progressOverlay.flatMap { overlay in
            progressScene(
                overlay,
                at: sampleTime,
                outputDuration: outputDuration ?? 0
            )
        }
        if var openingProgress = progress {
            var sample = openingSample(
                for: .progress,
                sequence: project.openingSequence,
                activeElements: availableOpeningElements,
                at: sampleTime,
                canvasWidth: width,
                canvasHeight: height
            )
            let baseBandHeight = max(openingProgress.bandHeight * width / 1_920, 24)
            let visualHalfHeight = baseBandHeight * sample.scale / 2
            let progressCenterY: Double = switch openingProgress.placement {
            case .top:
                baseBandHeight / 2
            case .bottom:
                height - baseBandHeight / 2
            case .custom:
                min(
                    max(openingProgress.position.y * height, baseBandHeight / 2),
                    height - baseBandHeight / 2
                )
            }
            let travelMargin = max(height * 0.025, 8)
            switch openingProgress.placement {
            case .top:
                // A finished-film bar is already a long horizontal shape. It
                // should descend as one rigid strip, not shrink and drift like
                // a floating card.
                sample.scale = 1
                sample.offset.y = -(
                    progressCenterY + visualHalfHeight + travelMargin
                ) * sample.remaining
            case .bottom:
                sample.scale = 1
                sample.offset.y = (
                    height - progressCenterY + visualHalfHeight + travelMargin
                ) * sample.remaining
            case .custom:
                // Once the user detaches the bar from an edge there is no
                // meaningful off-canvas direction. Reveal it in place with a
                // compact non-linear scale instead of sweeping a full-width
                // strip across the composition.
                sample.offset = CompositionPoint(x: 0, y: 0)
                sample.scale = 0.84 + 0.16 * (1 - sample.remaining)
            }
            openingProgress.opacity = sample.opacity
            openingProgress.scale = sample.scale
            openingProgress.offset = NormalizedPoint(
                x: sample.offset.x / width,
                y: sample.offset.y / height
            )
            progress = openingProgress
        }
        var order: [FrameLayerRole] = [.background, .screen]
        if cursor != nil { order.append(.cursor) }
        // Spotlight is one dimming effect above the complete base picture,
        // not separate treatments for the wallpaper and screen texture.
        if activeMosaics.contains(where: { $0.style == .spotlight }) {
            order.append(.spotlight)
        }
        if camera != nil, camera?.opacity ?? 0 > 0 { order.append(.camera) }
        if !stickers.isEmpty { order.append(.stickers) }
        if progress != nil { order.append(.progress) }
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
            screen: screen,
            camera: camera,
            cursor: cursor,
            stickers: stickers,
            progress: progress,
            layerOrder: order
        )
    }

    private static func stickerScenes(
        _ clips: [StickerClip],
        at time: TimeInterval,
        suppressesInitialEntry: Bool = false
    ) -> [FrameStickerScene] {
        clips.compactMap { clip in
            guard clip.timing.contains(time) else { return nil }
            let localTime = max(time - clip.timing.startTime, 0)
            let remaining = max(clip.timing.endTime - time, 0)
            // A shortened sticker can be briefer than its authored entry and
            // exit combined. Scale both transitions together instead of
            // letting them overlap and fight for the active transform.
            let requestedEnter = max(clip.enterDuration, 0)
            let requestedExit = max(clip.exitDuration, 0)
            let requestedTransitionDuration = requestedEnter + requestedExit
            let transitionScale = requestedTransitionDuration > clip.timing.duration
                && requestedTransitionDuration > 0
                ? clip.timing.duration / requestedTransitionDuration
                : 1
            let enterDuration = requestedEnter * transitionScale
            let exitDuration = requestedExit * transitionScale
            let suppressesClipEntry = suppressesInitialEntry
                && clip.timing.startTime <= 0.000_1
            let linearEnter = suppressesClipEntry ? 1 : (enterDuration > 0
                ? min(max(localTime / enterDuration, 0), 1)
                : 1)
            let linearExit = exitDuration > 0
                ? min(max(remaining / exitDuration, 0), 1)
                : 1
            // Entry covers a generous off-canvas distance, so a symmetric
            // smoother-step spends too much of the trip at near-constant
            // speed. Ease out decisively into the target; exit uses the
            // complementary ease-in path and accelerates away from it.
            let enterProgress = easeOutQuart(linearEnter)
            let exitProgress = easeInExitQuart(linearExit)
            let exitPreset = clip.exitAnimation ?? clip.animation.automaticExit
            let enterVisibility = clip.animation == .none ? 1 : enterProgress
            let exitVisibility = exitPreset == .none ? 1 : exitProgress
            let visibility = min(enterVisibility, exitVisibility)
            let isExiting = exitDuration > 0 && remaining < exitDuration
            let activePreset = isExiting ? exitPreset : clip.animation
            let activeProgress = isExiting ? exitProgress : enterProgress
            let transform = stickerAnimationTransform(
                preset: activePreset,
                progress: activeProgress,
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
                layerIndex: clip.layerIndex
            )
        }
        .sorted { lhs, rhs in
            lhs.layerIndex == rhs.layerIndex
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.layerIndex < rhs.layerIndex
        }
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

    private static func progressScene(
        _ overlay: ProgressOverlay,
        at time: TimeInterval,
        outputDuration: TimeInterval
    ) -> FrameProgressScene? {
        guard outputDuration.isFinite, outputDuration > 0 else { return nil }
        let fraction = min(max(time / outputDuration, 0), 1)
        var chapters = overlay.chapters
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= outputDuration }
            .sorted { $0.time < $1.time }
        if chapters.first?.time ?? 1 > 0.000_1 {
            chapters.insert(ProgressChapter(time: 0, title: ""), at: 0)
        }
        return FrameProgressScene(
            placement: overlay.placement,
            position: overlay.position,
            width: min(max(overlay.width, 0.05), 1),
            bandHeight: min(max(overlay.bandHeight, 28), 180),
            textSize: min(max(overlay.textSize, 10), 72),
            thickness: max(overlay.thickness, 1),
            fraction: fraction,
            backgroundColor: overlay.backgroundColor,
            backgroundOpacity: min(max(overlay.backgroundOpacity, 0), 1),
            trackColor: overlay.trackColor,
            fillColor: overlay.fillColor,
            nodeColor: overlay.nodeColor,
            textColor: overlay.textColor,
            chapters: chapters.map {
                FrameProgressChapterScene(
                    fraction: $0.time / outputDuration,
                    title: $0.title
                )
            },
            opacity: 1,
            scale: 1,
            offset: NormalizedPoint(x: 0, y: 0)
        )
    }

    private struct OpeningSample {
        var opacity: Double
        var scale: Double
        var offset: CompositionPoint
        var rotationX: Double
        var rotationY: Double
        var perspective: Double
        var remaining: Double

        static let identity = OpeningSample(
            opacity: 1,
            scale: 1,
            offset: CompositionPoint(x: 0, y: 0),
            rotationX: 0,
            rotationY: 0,
            perspective: 0,
            remaining: 0
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
        let eased = 1 - pow(1 - linear, 4)
        let opacity = smootherStep(min(linear * 1.65, 1))
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
        case (.converge, .progress):
            scaleStart = 0.82
            initialOffset = CompositionPoint(x: 0, y: canvasHeight * 0.22)
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
        case (.sideSlide, .progress):
            scaleStart = 1
            initialOffset = CompositionPoint(x: 0, y: canvasHeight * 0.22)
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
        case (.light3D, .progress):
            scaleStart = 0.92
            initialOffset = CompositionPoint(x: 0, y: canvasHeight * 0.20)
            rotationX = 0
            rotationY = 0
            perspective = 0
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
            perspective: perspective,
            remaining: remaining
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

    private static func easeOutQuart(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return 1 - pow(1 - x, 4)
    }

    /// `remainingProgress` travels from 1 to 0 during exit. This curve keeps
    /// the first motion subtle near the target, then accelerates out of frame.
    private static func easeInExitQuart(_ remainingProgress: Double) -> Double {
        let x = min(max(remainingProgress, 0), 1)
        return 1 - pow(1 - x, 4)
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

    private static func applyingLayerMotion(
        to current: FrameScene,
        toward next: FrameScene,
        strength: Double
    ) -> FrameScene {
        var result = current
        let cornerDeltas = zip(
            next.screen.projectedQuad.corners,
            current.screen.projectedQuad.corners
        ).map { nextPoint, currentPoint in
            (
                x: nextPoint.x - currentPoint.x,
                y: nextPoint.y - currentPoint.y
            )
        }
        if let dominant = cornerDeltas.max(by: {
            hypot($0.x, $0.y) < hypot($1.x, $1.y)
        }) {
            result.screen.motion = FrameLayerMotion(
                deltaX: dominant.x,
                deltaY: dominant.y,
                strength: strength
            )
        }
        if let currentCamera = current.camera,
           let nextCamera = next.camera {
            let cameraDeltas = [
                (
                    x: nextCamera.rect.x - currentCamera.rect.x,
                    y: nextCamera.rect.y - currentCamera.rect.y
                ),
                (
                    x: nextCamera.rect.x + nextCamera.rect.width
                        - currentCamera.rect.x - currentCamera.rect.width,
                    y: nextCamera.rect.y - currentCamera.rect.y
                ),
                (
                    x: nextCamera.rect.x + nextCamera.rect.width
                        - currentCamera.rect.x - currentCamera.rect.width,
                    y: nextCamera.rect.y + nextCamera.rect.height
                        - currentCamera.rect.y - currentCamera.rect.height
                ),
                (
                    x: nextCamera.rect.x - currentCamera.rect.x,
                    y: nextCamera.rect.y + nextCamera.rect.height
                        - currentCamera.rect.y - currentCamera.rect.height
                ),
            ]
            let cameraMotion = cameraDeltas.max {
                hypot($0.x, $0.y) < hypot($1.x, $1.y)
            } ?? (x: 0, y: 0)
            result.camera?.motion = FrameLayerMotion(
                deltaX: cameraMotion.x,
                deltaY: cameraMotion.y,
                strength: strength
            )
        }
        if let currentCursor = current.cursor,
           let nextCursor = next.cursor {
            result.cursor?.motion = FrameLayerMotion(
                deltaX: nextCursor.layout.pointer.x - currentCursor.layout.pointer.x,
                deltaY: nextCursor.layout.pointer.y - currentCursor.layout.pointer.y,
                strength: strength
            )
        }
        return result
    }

    private static func screenDecoration(
        style: ScreenFrameStyle,
        frameScale: Double,
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
        let outerCornerRadius: Double = switch style {
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape:
            min(max(34 * scale, 5), min(outerRect.width, outerRect.height) * 0.13)
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape:
            min(max(25 * scale, 4), min(outerRect.width, outerRect.height) * 0.09)
        default: min(max(14 * scale, 2), topInset * 0.48)
        }
        let contentCornerRadius: Double = switch style {
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape:
            min(max(27 * scale, 4), min(geometry.finalRect.width, geometry.finalRect.height) * 0.11)
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape:
            min(max(17 * scale, 3), min(geometry.finalRect.width, geometry.finalRect.height) * 0.065)
        default: 0
        }
        return .chrome(
            FrameScreenChromeScene(
                kind: kind,
                outerRect: outerRect,
                toolbarRect: toolbarRect,
                outerCornerRadius: outerCornerRadius,
                contentCornerRadius: contentCornerRadius,
                surfaceColor: isDark
                    ? HexColor(rgb24: 0x22_23_27)
                    : HexColor(rgb24: 0xEC_ED_F0),
                toolbarColor: isDark
                    ? HexColor(rgb24: 0x31_32_38)
                    : HexColor(rgb24: 0xF4_F4_F6),
                separatorColor: isDark
                    ? HexColor(rgb24: 0x4B_4D_55)
                    : HexColor(rgb24: 0xC9_CA_CE),
                fieldColor: isDark
                    ? HexColor(rgb24: 0x1B_1C_20)
                    : HexColor(rgb24: 0xFF_FF_FF),
                glyphColor: isDark
                    ? HexColor(rgb24: 0xA9_AB_B3)
                    : HexColor(rgb24: 0x7A_7C_84)
            )
        )
    }

    private static func cursorScene(
        sample: PointerSample?,
        project: RecorderProject,
        metrics: CursorAssetMetrics?,
        metricsByAssetID: [CursorAssetID: CursorAssetMetrics],
        screen: FrameScreenScene,
        canvasSize: CompositionSize,
        styleScale: Double
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
        let point = CompositionPoint(
            x: screen.finalRect.x + local.x * screen.finalRect.width,
            y: screen.finalRect.y + local.y * screen.finalRect.height
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
            normalizedScreenPosition: local,
            layout: layout,
            isClicking: sample.isClicking,
            clickPhase: sample.clickPhase,
            clickStyle: project.cursorStyle.clickEffectStyle,
            clickColor: project.cursorStyle.clickColor,
            clickOpacity: project.cursorStyle.clickOpacity,
            clickScale: project.cursorStyle.clickScale,
            rotationRadians: sample.rotationRadians,
            shadow: FrameShadow(
                opacity: 0.42,
                radius: max(layout.size.height * 1.5 / 44, 0.5),
                offset: CompositionPoint(
                    x: 0,
                    y: max(layout.size.height / 44, 0.5)
                )
            )
        )
    }

}
