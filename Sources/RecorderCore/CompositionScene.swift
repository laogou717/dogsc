import Foundation

public struct CompositionRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public struct CompositionPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenSceneEvaluation: Equatable, Sendable {
    public var fittedRect: CompositionRect
    public var baseRect: CompositionRect
    public var finalRect: CompositionRect
    public var manualScale: Double
    public var manualOffset: CompositionPoint
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double
    public var perspective: Double
    public var projectionAnchor: NormalizedPoint
    public var baseCornerRadius: Double
    public var baseBorderWidth: Double
    public var finalCornerRadius: Double
    public var finalBorderWidth: Double
    public var zoom: ZoomSample
    public var viewport: ZoomViewportTransform

    public var projectedQuad: ProjectedScreenQuad {
        // The authored 3D target selects a point inside the recorded screen.
        // Border/chrome travel with that screen, but must not move the pivot
        // away from the selected content merely because their insets differ.
        let anchor = CompositionPoint(
            x: finalRect.x + finalRect.width * projectionAnchor.x,
            y: finalRect.y + finalRect.height * projectionAnchor.y
        )
        return ScreenProjection.project(
            rect: finalRect,
            rotationX: rotationX,
            rotationY: rotationY,
            rotationZ: rotationZ,
            perspective: perspective,
            anchor: anchor
        )
    }
}

public struct ScreenDecorationInsets: Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = max(top, 0)
        self.right = max(right, 0)
        self.bottom = max(bottom, 0)
        self.left = max(left, 0)
    }

    public static let zero = ScreenDecorationInsets()
}

/// Shared screen-frame measurements used before motion layout and again while
/// lowering the final vector chrome. Keeping this formula in one place makes
/// the motion anchor account for the exact same toolbar the renderer draws.
public enum ScreenFrameGeometry {
    public static func decorationInsetsAtScaleOne(
        style: ScreenFrameStyle,
        frameScale: Double,
        toolbarScale: Double = 1,
        fittedWidth: Double,
        fittedHeight: Double,
        styleScale: Double
    ) -> ScreenDecorationInsets {
        guard style != .none else { return .zero }
        let safeStyleScale = max(styleScale, 0.000_1)
        let authoredFrameScale = min(max(frameScale, 0.6), 1.6)
        let authoredToolbarScale = min(max(toolbarScale, 0.65), 1.6)
        let visualScale = safeStyleScale * authoredFrameScale
        switch style {
        case .none:
            return .zero
        case .windowLight, .windowDark, .browserLight, .browserDark:
            let idealHeight = 46 * visualScale * authoredToolbarScale
            return ScreenDecorationInsets(top: min(
                max(idealHeight, 4 * safeStyleScale),
                max(max(fittedHeight, 0) * 0.25, 4 * safeStyleScale)
            ))
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape:
            let shortEdge = max(min(fittedWidth, fittedHeight), 1)
            let bezel = min(max(shortEdge * 0.026 * authoredFrameScale, 2 * safeStyleScale), shortEdge * 0.07)
            return ScreenDecorationInsets(top: bezel, right: bezel, bottom: bezel, left: bezel)
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape:
            let shortEdge = max(min(fittedWidth, fittedHeight), 1)
            let bezel = min(max(shortEdge * 0.035 * authoredFrameScale, 2 * safeStyleScale), shortEdge * 0.08)
            return ScreenDecorationInsets(top: bezel, right: bezel, bottom: bezel, left: bezel)

        }
    }

}

public struct CameraSceneEvaluation: Equatable, Sendable {
    public var rect: CompositionRect
    public var cornerRadius: Double
    public var borderWidth: Double
    public var zoomScale: Double
    public var opacity: Double
    public var fullscreenProgress: Double
}

public struct CompositionSceneEvaluation: Equatable, Sendable {
    public var screen: ScreenSceneEvaluation
    public var camera: CameraSceneEvaluation?
}

/// Pure scene geometry shared by SwiftUI preview and Core Image export.
/// Coordinates use a top-left origin; the Core Image renderer performs only
/// the final Y-axis conversion. Keeping all layout decisions here prevents
/// preview/export drift as editor controls evolve.
public enum CompositionSceneEvaluator {
    /// Visual measurements in the project model are authored against a
    /// 1080-pixel short edge. Scaling them with the output short edge keeps
    /// padding, radii, borders, blur and shadows compositionally identical at
    /// 1080p, 4K and every preview size.
    public static func canonicalStyleScale(
        canvasWidth: Double,
        canvasHeight: Double
    ) -> Double {
        max(min(canvasWidth, canvasHeight), 1) / 1080
    }

    /// The current scene and previous-frame geometry read the same authored
    /// motion tracks. A tiny exact-match cache (Equatable arrays, no
    /// fingerprints) prevents rebuilding their sorted indexes on every frame.
    /// `static let` keeps the reference immutable; the `@unchecked Sendable` +
    /// NSLock boundary matches the export pipeline's shared-state pattern.
    private static let motionTrackCache = MotionTrackCacheStore()

    public static func evaluate(
        project: RecorderProject,
        time: TimeInterval,
        canvasWidth: Double,
        canvasHeight: Double,
        sourceAspectRatio: Double,
        cameraAspectRatio: Double? = nil,
        styleScale: Double = 1,
        automaticZoomFocus: NormalizedPoint? = nil,
        inheritedAutomaticZoomFocus: NormalizedPoint? = nil,
        reanchorAutomaticEntry: Bool = false,
        zoomTrack: ZoomAnimationTrack? = nil,
        screenMotionTrack: ScreenMotionTrack? = nil,
        cameraMotionTrack: CameraMotionTrack? = nil
    ) -> CompositionSceneEvaluation {
        let width = max(canvasWidth, 2)
        let height = max(canvasHeight, 2)
        let scale = max(styleScale, 0.000_1)
        let crop = project.canvas.crop.clamped()
        let croppedAspect = max(sourceAspectRatio * crop.width / crop.height, 0.01)
        let maximumPadding = min(width, height) * 0.42
        let padding = min(max(project.canvas.padding * scale, 0), maximumPadding)
        let availableWidth = max(width - padding * 2, 2)
        let availableHeight = max(height - padding * 2, 2)
        let fittedSize = aspectFit(
            aspectRatio: croppedAspect,
            width: availableWidth,
            height: availableHeight
        )
        let fittedRect = CompositionRect(
            x: (width - fittedSize.width) / 2,
            y: (height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )

        let sampleTime = time.isFinite ? max(time, 0) : 0
        let baseScreenMotion = ScreenMotionState(
            position: project.canvas.contentPosition,
            scale: project.canvas.contentScale
        )
        let borderWidthAtScaleOne = min(max(project.canvas.borderWidth, 0), 60) * scale
        let decorationInsetsAtScaleOne = ScreenFrameGeometry.decorationInsetsAtScaleOne(
            style: project.canvas.screenFrame,
            frameScale: project.canvas.screenFrameScale,
            toolbarScale: project.canvas.screenFrameToolbarScale,
            fittedWidth: fittedRect.width,
            fittedHeight: fittedRect.height,
            styleScale: scale
        )
        let screenMotionSample = (screenMotionTrack ?? motionTrackCache.screenTrack(
            for: project.timeline.screenMotionClips
        )).sampleLayout(
            at: sampleTime,
            base: baseScreenMotion,
            motion: project.motion,
            anchorViewport: ScreenAnchorViewport(
                canvasWidth: width,
                canvasHeight: height,
                fittedWidth: fittedRect.width,
                fittedHeight: fittedRect.height,
                borderWidthAtScaleOne: borderWidthAtScaleOne,
                decorationTopAtScaleOne: decorationInsetsAtScaleOne.top,
                decorationRightAtScaleOne: decorationInsetsAtScaleOne.right,
                decorationBottomAtScaleOne: decorationInsetsAtScaleOne.bottom,
                decorationLeftAtScaleOne: decorationInsetsAtScaleOne.left
            )
        )
        let screenMotion = screenMotionSample.state
        let manualScale = min(max(screenMotion.scale, 0.2), 4)
        // 采样值不做 0...1 钳制：rect 线性过渡的中间态 pos 可能超出
        // （偏移公式对任意实数 pos 成立；持久化目标值已在入库校验 0...1）。
        let positionX = screenMotion.position.x.isFinite ? screenMotion.position.x : 0.5
        let positionY = screenMotion.position.y.isFinite ? screenMotion.position.y : 0.5
        let scaledWidth = fittedRect.width * manualScale
        let scaledHeight = fittedRect.height * manualScale
        let baseBorderWidth = borderWidthAtScaleOne * manualScale
        // MOT-001: position the complete authored screen card, including its
        // outer border. Previously position 0/1 aligned the content edge to
        // the canvas edge, placing the entire outer border outside the canvas.
        // A 3D transition ending at an edge therefore looked as if it switched
        // render paths and deleted the border. Center alignment is unchanged;
        // edge alignment now keeps the near-side border inside the canvas.
        let decoratedWidth = scaledWidth + baseBorderWidth * 2
        let decoratedHeight = scaledHeight + baseBorderWidth * 2
        let offsetX = screenMotionSample.manualOffset?.x
            ?? (positionX - 0.5) * (width - decoratedWidth)
        let offsetY = screenMotionSample.manualOffset?.y
            ?? (positionY - 0.5) * (height - decoratedHeight)
        let baseRect = CompositionRect(
            x: fittedRect.midX - fittedRect.width * manualScale / 2
                + offsetX,
            y: fittedRect.midY - fittedRect.height * manualScale / 2
                + offsetY,
            width: fittedRect.width * manualScale,
            height: fittedRect.height * manualScale
        )

        let zoom = zoomTrack?.sample(
            at: sampleTime,
            motion: project.motion,
            automaticFocus: automaticZoomFocus,
            inheritedAutomaticFocus: inheritedAutomaticZoomFocus,
            reanchorAutomaticEntry: reanchorAutomaticEntry
        ) ?? ZoomInterpolator.sample(
            animations: project.zoomAnimations,
            at: sampleTime,
            motion: project.motion,
            automaticFocus: automaticZoomFocus,
            inheritedAutomaticFocus: inheritedAutomaticZoomFocus,
            reanchorAutomaticEntry: reanchorAutomaticEntry
        )
        let viewport = ZoomViewportTransform.make(from: zoom, crop: crop)
        let finalRect = CompositionRect(
            x: baseRect.midX - baseRect.width * viewport.scale / 2
                + viewport.translation.x * baseRect.width,
            y: baseRect.midY - baseRect.height * viewport.scale / 2
                + viewport.translation.y * baseRect.height,
            width: baseRect.width * viewport.scale,
            height: baseRect.height * viewport.scale
        )
        let screen = ScreenSceneEvaluation(
            fittedRect: fittedRect,
            baseRect: baseRect,
            finalRect: finalRect,
            manualScale: manualScale,
            manualOffset: CompositionPoint(x: offsetX, y: offsetY),
            rotationX: min(max(screenMotion.rotationX, -89), 89),
            rotationY: min(max(screenMotion.rotationY, -89), 89),
            rotationZ: screenMotion.rotationZ,
            perspective: min(max(screenMotion.perspective, 0), 2),
            projectionAnchor: screenMotionSample.projectionAnchor,
            baseCornerRadius: max(project.canvas.cornerRadius, 0) * scale * manualScale,
            baseBorderWidth: baseBorderWidth,
            finalCornerRadius: max(project.canvas.cornerRadius, 0)
                * scale * manualScale * viewport.scale,
            finalBorderWidth: baseBorderWidth * viewport.scale,
            zoom: zoom,
            viewport: viewport
        )

        let camera = cameraAspectRatio.map { aspectRatio in
            let baseCameraMotion = CameraMotionState(
                layout: .shape(project.camera.shape),
                position: project.camera.position,
                size: project.camera.size,
                roundness: project.camera.roundness,
                opacity: 1
            )
            let cameraMotion = (cameraMotionTrack ?? motionTrackCache.cameraTrack(
                for: project.timeline.cameraMotionClips
            )).sample(
                at: sampleTime,
                base: baseCameraMotion,
                cameraAspectRatio: aspectRatio,
                canvasAspectRatio: width / height,
                motion: project.motion
            )
            return evaluateCamera(
                style: project.camera,
                motion: cameraMotion,
                screenZoomScale: zoom.scale,
                canvasWidth: width,
                canvasHeight: height,
                styleScale: scale
            )
        }
        return CompositionSceneEvaluation(screen: screen, camera: camera)
    }

    public static func evaluateCamera(
        style: CameraStyle,
        cameraAspectRatio: Double,
        screenZoomScale: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        styleScale: Double = 1
    ) -> CameraSceneEvaluation {
        let base = CameraMotionState(
            layout: .shape(style.shape),
            position: style.position,
            size: style.size,
            roundness: style.roundness,
            opacity: 1
        )
        let sample = CameraMotionTrack([]).sample(
            at: 0,
            base: base,
            cameraAspectRatio: cameraAspectRatio,
            canvasAspectRatio: max(canvasWidth, 2) / max(canvasHeight, 2)
        )
        return evaluateCamera(
            style: style,
            motion: sample,
            screenZoomScale: screenZoomScale,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            styleScale: styleScale
        )
    }

    /// Resolves a continuous camera-motion sample into final canvas geometry.
    /// Shape changes and fullscreen transitions therefore use the same rect,
    /// radius, border and opacity contract in preview and export.
    public static func evaluateCamera(
        style: CameraStyle,
        motion sample: CameraMotionSample,
        screenZoomScale: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        styleScale: Double = 1
    ) -> CameraSceneEvaluation {
        let width = max(canvasWidth, 2)
        let height = max(canvasHeight, 2)
        let base = min(width, height)
        let zoomProgress = min(max((screenZoomScale - 1) / 0.565, 0), 1)
        let zoomScale = 1 + (style.scaleDuringZoom - 1) * zoomProgress
        let preferredCameraHeight = min(
            max(base * sample.size * zoomScale, 72 * max(styleScale, 0.000_1)),
            // 大目标可以到角：上限放宽到画布的 1.2 倍（此前 0.8 会把
            // "大目标+角落"裁掉，两边的屏幕始终露出来）。
            base * 1.2
        )
        let preferredCameraWidth = preferredCameraHeight * max(sample.aspectRatio, 0.01)
        let fitScale = min(
            1,
            width * 1.2 / max(preferredCameraWidth, 0.000_1),
            height * 1.2 / max(preferredCameraHeight, 0.000_1)
        )
        let cameraWidth = preferredCameraWidth * fitScale
        let cameraHeight = preferredCameraHeight * fitScale
        let positionX = min(max(sample.position.x, 0), 1)
        let positionY = min(max(sample.position.y, 0), 1)
        // 超出画布的相机允许贴着两侧停靠（x 可为负），大目标才能真正覆盖角落。
        let shapedRect = CompositionRect(
            x: positionX * (width - cameraWidth),
            y: positionY * (height - cameraHeight),
            width: cameraWidth,
            height: cameraHeight
        )
        let fullscreenProgress = min(max(sample.fullscreenProgress, 0), 1)
        let rect = CompositionRect(
            x: mix(shapedRect.x, 0, fullscreenProgress),
            y: mix(shapedRect.y, 0, fullscreenProgress),
            width: mix(shapedRect.width, width, fullscreenProgress),
            height: mix(shapedRect.height, height, fullscreenProgress)
        )
        let radius = min(rect.width, rect.height)
            * min(max(sample.cornerFraction, 0), 0.5)
        return CameraSceneEvaluation(
            rect: rect,
            cornerRadius: radius,
            borderWidth: min(max(style.borderWidth, 0), 18)
                * max(styleScale, 0.000_1)
                * (1 - fullscreenProgress),
            zoomScale: zoomScale,
            opacity: min(max(sample.opacity, 0), 1),
            fullscreenProgress: fullscreenProgress
        )
    }

    private static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    private static func aspectFit(
        aspectRatio: Double,
        width: Double,
        height: Double
    ) -> (width: Double, height: Double) {
        let safeAspect = max(aspectRatio, 0.01)
        if width / max(height, 1) > safeAspect {
            return (height * safeAspect, height)
        }
        return (width, width / safeAspect)
    }
}

/// Lock-protected exact-match cache for sorted motion tracks. The evaluator
/// may run concurrently on preview and export threads; a bounded linear scan
/// (≤4 entries) over Equatable clip arrays is far cheaper than re-sorting the
/// tracks for every motion-blur sample.
private final class MotionTrackCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var screenEntries: [(key: [ScreenMotionClip], track: ScreenMotionTrack)] = []
    private var cameraEntries: [(key: [CameraMotionClip], track: CameraMotionTrack)] = []

    func screenTrack(for clips: [ScreenMotionClip]) -> ScreenMotionTrack {
        lock.lock()
        defer { lock.unlock() }
        if let entry = screenEntries.first(where: { $0.key == clips }) {
            return entry.track
        }
        let track = ScreenMotionTrack(clips)
        screenEntries.insert((clips, track), at: 0)
        if screenEntries.count > 4 { screenEntries.removeLast() }
        return track
    }

    func cameraTrack(for clips: [CameraMotionClip]) -> CameraMotionTrack {
        lock.lock()
        defer { lock.unlock() }
        if let entry = cameraEntries.first(where: { $0.key == clips }) {
            return entry.track
        }
        let track = CameraMotionTrack(clips)
        cameraEntries.insert((clips, track), at: 0)
        if cameraEntries.count > 4 { cameraEntries.removeLast() }
        return track
    }
}
