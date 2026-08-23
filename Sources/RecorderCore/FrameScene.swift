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

    public init(source: BackgroundSource, blurRadius: Double) {
        self.source = source
        self.blurRadius = max(blurRadius, 0)
    }
}

public enum FrameScreenChromeKind: Equatable, Sendable {
    case window
    case browser
}

/// Fully evaluated vector chrome. Geometry is expressed in the same top-left
/// canvas coordinates as the screen, so the single renderer can draw it before
/// applying the screen's 3D projection.
public struct FrameScreenChromeScene: Equatable, Sendable {
    public var kind: FrameScreenChromeKind
    public var outerRect: CompositionRect
    public var toolbarRect: CompositionRect
    public var outerCornerRadius: Double
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
        decoration: FrameScreenDecoration = .none
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

    public init(
        rect: CompositionRect,
        contentFill: CameraContentFillLayout?,
        cornerRadius: Double,
        borderWidth: Double,
        borderColor: HexColor = .white,
        shadow: FrameShadow?,
        opacity: Double,
        isMirrored: Bool
    ) {
        self.rect = rect
        self.contentFill = contentFill
        self.cornerRadius = max(cornerRadius, 0)
        self.borderWidth = max(borderWidth, 0)
        self.borderColor = borderColor
        self.shadow = shadow
        self.opacity = min(max(opacity, 0), 1)
        self.isMirrored = isMirrored
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
    public var shadow: FrameShadow?
    public var attachment: FrameCursorAttachment

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
        shadow: FrameShadow?,
        attachment: FrameCursorAttachment = .screen
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
        self.shadow = shadow
        self.attachment = attachment
    }
}

public enum FrameLayerRole: String, Equatable, Sendable {
    case background
    case screen
    case cursor
    case camera
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
    public var layerOrder: [FrameLayerRole]

    public init(
        time: TimeInterval,
        canvasSize: CompositionSize,
        color: FrameColorContract,
        background: FrameBackgroundScene,
        screen: FrameScreenScene,
        camera: FrameCameraScene?,
        cursor: FrameCursorScene?,
        layerOrder: [FrameLayerRole]
    ) {
        self.time = time
        self.canvasSize = canvasSize
        self.color = color
        self.background = background
        self.screen = screen
        self.camera = camera
        self.cursor = cursor
        self.layerOrder = layerOrder
    }
}

public struct FrameSceneSample: Equatable, Sendable {
    public var scene: FrameScene
    public var weight: Double

    public init(scene: FrameScene, weight: Double) {
        self.scene = scene
        self.weight = weight
    }
}

/// One output-frame request, including the complete temporal sample plan used
/// for motion blur. Preview and export can lower media-decoding quality, but
/// must preserve these sample times and weights for parity.
public struct FrameRenderPlan: Equatable, Sendable {
    public var presentationTime: TimeInterval
    public var outputDuration: TimeInterval
    public var frameRate: Int
    public var samples: [FrameSceneSample]

    public init(
        presentationTime: TimeInterval,
        outputDuration: TimeInterval,
        frameRate: Int,
        samples: [FrameSceneSample]
    ) {
        self.presentationTime = presentationTime
        self.outputDuration = outputDuration
        self.frameRate = frameRate
        self.samples = samples
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
        let temporalSamples = boundedTemporalSamples(
            MotionBlurSampler.samples(
                at: safeTime,
                frameRate: frameRate,
                duration: safeDuration,
                descriptor: project.motion.frameMotionBlur
            ),
            activeRange: activePrimaryRange
        )
        let samples = temporalSamples.map { sample in
            let cameraIsAvailable = activeCameraRange.map {
                sample.time >= $0.start && sample.time < $0.end
            } ?? true
            return FrameSceneSample(
                scene: scene(
                    project: project,
                    time: sample.time,
                    canvasSize: canvasSize,
                    sourceAspectRatio: sourceAspectRatio,
                    cameraSourceSize: cameraIsAvailable ? cameraSourceSize : nil,
                    pointerTrack: pointerTrack,
                    cursorMetrics: cursorMetrics,
                    zoomTrack: zoomTrack,
                    screenMotionTrack: screenMotionTrack,
                    cameraMotionTrack: cameraMotionTrack,
                    color: color
                ),
                weight: sample.weight
            )
        }
        return FrameRenderPlan(
            presentationTime: safeTime,
            outputDuration: safeDuration,
            frameRate: max(frameRate, 1),
            samples: samples
        )
    }

    public static func scene(
        project: RecorderProject,
        time: TimeInterval,
        canvasSize: CompositionSize,
        sourceAspectRatio: Double,
        cameraSourceSize: CompositionSize? = nil,
        pointerTrack: ProjectPointerTrack? = nil,
        pointerEvaluation: PointerTrackEvaluation? = nil,
        cursorMetrics: CursorAssetMetrics? = nil,
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
        let screenShadow: FrameShadow? = project.canvas.shadowStrength > 0
            ? FrameShadow(
                opacity: project.canvas.shadowStrength,
                radius: 22 * styleScale * geometry.screen.manualScale
                    * geometry.screen.viewport.scale,
                offset: CompositionPoint(
                    x: 0,
                    y: 12 * styleScale * geometry.screen.manualScale
                        * geometry.screen.viewport.scale
                )
            )
            : nil
        let decoration = screenDecoration(
            style: project.canvas.screenFrame,
            geometry: geometry.screen,
            styleScale: styleScale
        )
        let projectionRect = decoration.projectionRect ?? geometry.screen.finalRect
        let projectedQuad = ScreenProjection.project(
            rect: projectionRect,
            rotationX: geometry.screen.rotationX,
            rotationY: geometry.screen.rotationY,
            rotationZ: geometry.screen.rotationZ,
            perspective: geometry.screen.perspective
        )
        let screen = FrameScreenScene(
            sourceCrop: project.canvas.crop,
            fittedRect: geometry.screen.fittedRect,
            baseRect: geometry.screen.baseRect,
            finalRect: geometry.screen.finalRect,
            projectedQuad: projectedQuad,
            cornerRadius: geometry.screen.finalCornerRadius,
            borderWidth: geometry.screen.finalBorderWidth,
            borderColor: project.canvas.borderColor,
            borderOpacity: project.canvas.insetOpacity,
            shadow: screenShadow,
            decoration: decoration
        )
        let camera = geometry.camera.map { evaluation in
            FrameCameraScene(
                rect: evaluation.rect,
                contentFill: cameraSourceSize.flatMap {
                    let visualFocus = project.camera.contentPosition
                    return CameraContentFill.layout(
                        sourceWidth: $0.width,
                        sourceHeight: $0.height,
                        target: evaluation.rect,
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
                cornerRadius: evaluation.cornerRadius,
                borderWidth: evaluation.borderWidth,
                shadow: project.camera.shadowStrength > 0
                    ? FrameShadow(
                        opacity: project.camera.shadowStrength,
                        radius: 14 * styleScale,
                        offset: CompositionPoint(x: 0, y: 8 * styleScale)
                    )
                    : nil,
                opacity: project.camera.isHidden ? 0 : evaluation.opacity,
                isMirrored: project.camera.isMirrored
            )
        }
        let cursor = cursorScene(
            sample: pointer.cursor,
            project: project,
            metrics: cursorMetrics,
            screen: screen,
            canvasSize: CompositionSize(width: width, height: height),
            styleScale: styleScale
        )
        var order: [FrameLayerRole] = [.background, .screen]
        if cursor != nil { order.append(.cursor) }
        if camera != nil, camera?.opacity ?? 0 > 0 { order.append(.camera) }
        return FrameScene(
            time: sampleTime,
            canvasSize: CompositionSize(width: width, height: height),
            color: color,
            background: FrameBackgroundScene(
                source: project.canvas.backgroundSource,
                blurRadius: project.canvas.backgroundBlur * styleScale
            ),
            screen: screen,
            camera: camera,
            cursor: cursor,
            layerOrder: order
        )
    }

    private static func screenDecoration(
        style: ScreenFrameStyle,
        geometry: ScreenSceneEvaluation,
        styleScale: Double
    ) -> FrameScreenDecoration {
        guard style != .none else { return .none }
        let scale = max(
            styleScale * geometry.manualScale * geometry.viewport.scale,
            0.000_1
        )
        let idealHeight = 46 * scale
        let toolbarHeight = min(
            max(idealHeight, 4 * styleScale),
            max(geometry.finalRect.height * 0.25, 4 * styleScale)
        )
        let outerRect = CompositionRect(
            x: geometry.finalRect.x,
            y: geometry.finalRect.y - toolbarHeight,
            width: geometry.finalRect.width,
            height: geometry.finalRect.height + toolbarHeight
        )
        // A slight overlap fills the source's rounded top-corner cutouts while
        // preserving the exact content rectangle and crop calculation.
        let toolbarRect = CompositionRect(
            x: outerRect.x,
            y: outerRect.y,
            width: outerRect.width,
            height: toolbarHeight + min(2 * scale, toolbarHeight * 0.08)
        )
        let isDark = style == .windowDark || style == .browserDark
        let kind: FrameScreenChromeKind = switch style {
        case .browserLight, .browserDark: .browser
        case .windowLight, .windowDark, .none: .window
        }
        return .chrome(
            FrameScreenChromeScene(
                kind: kind,
                outerRect: outerRect,
                toolbarRect: toolbarRect,
                outerCornerRadius: min(
                    max(14 * scale, 2),
                    toolbarHeight * 0.48
                ),
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
        screen: FrameScreenScene,
        canvasSize: CompositionSize,
        styleScale: Double
    ) -> FrameCursorScene? {
        guard let sample, let metrics else { return nil }
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
            assetID: project.cursorStyle.assetID,
            metrics: metrics,
            normalizedScreenPosition: local,
            layout: layout,
            isClicking: sample.isClicking,
            clickPhase: sample.clickPhase,
            clickStyle: project.cursorStyle.clickEffectStyle,
            clickColor: project.cursorStyle.clickColor,
            clickOpacity: project.cursorStyle.clickOpacity,
            clickScale: project.cursorStyle.clickScale,
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

    /// Motion-blur samples must not read frames from the retained segment that
    /// precedes a ripple cut. Duplicate boundary samples are merged so weights
    /// remain normalized and deterministic.
    private static func boundedTemporalSamples(
        _ samples: [MotionBlurSample],
        activeRange: MediaTimeRange?
    ) -> [MotionBlurSample] {
        guard let activeRange else { return samples }
        // The overwhelmingly common frame is already wholly inside its
        // retained primary segment. Rebuilding an array, reducing its weights
        // and mapping it again on every preview tick is useful only when the
        // exposure window actually crosses a ripple cut. This also makes the
        // blur-disabled one-sample path allocation-free after sampling.
        if samples.allSatisfy({
            $0.time >= activeRange.start && $0.time <= activeRange.end
        }) {
            return samples
        }
        var merged: [MotionBlurSample] = []
        merged.reserveCapacity(samples.count)
        for sample in samples {
            let time = min(max(sample.time, activeRange.start), activeRange.end)
            if let last = merged.last, abs(last.time - time) < 0.000_000_1 {
                merged[merged.count - 1].weight += sample.weight
            } else {
                merged.append(MotionBlurSample(time: time, weight: sample.weight))
            }
        }
        let total = merged.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        return merged.map { MotionBlurSample(time: $0.time, weight: $0.weight / total) }
    }
}
