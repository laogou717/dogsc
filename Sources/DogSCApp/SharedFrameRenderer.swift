import CoreImage
import Foundation
import RecorderCore
import SwiftUI

/// API-specific media frames consumed by the shared Core Image compositor.
/// Project state and timeline interpretation deliberately do not cross this
/// boundary; all geometry and visual values live in the immutable `FrameScene`.
struct SharedFrameRenderResources: @unchecked Sendable {
    var screen: CIImage
    var camera: CIImage?
    var wallpaper: CIImage?
    var cursor: CIImage?
    /// A caller-owned, already-lowered canvas background. The editor keeps
    /// this immutable CIImage alive across playback frames so Core Image can
    /// retain one GPU intermediate instead of uploading and blurring the same
    /// wallpaper again for every decoded video frame. Export leaves it nil and
    /// therefore keeps its existing frame-local lowering contract.
    var preparedBackground: CIImage?

    init(
        screen: CIImage,
        camera: CIImage? = nil,
        wallpaper: CIImage? = nil,
        cursor: CIImage? = nil,
        preparedBackground: CIImage? = nil
    ) {
        self.screen = screen
        self.camera = camera
        self.wallpaper = wallpaper
        self.cursor = cursor
        self.preparedBackground = preparedBackground
    }
}

/// The single Core Image lowering of a backend-neutral `FrameScene`.
///
/// A screen-attached cursor is composited into the decorated screen layer
/// before that layer is projected. Preview and export therefore share one
/// perspective implementation, while the camera remains an independent top
/// layer. An axis-aligned quad takes the original 2D path byte-for-byte.
enum SharedFrameRenderer {
    nonisolated static func render(
        scene: FrameScene,
        resources: SharedFrameRenderResources
    ) -> CIImage {
        render(scene: scene, resources: resources, over: nil)
    }

    /// Renders the scene over a caller-provided background. The compositor
    /// renders the (time-invariant) wallpaper/gradient background once per
    /// output frame and reuses it across every motion-blur sample, avoiding
    /// `sampleCount - 1` full-canvas Gaussian blurs per frame at 4K/120 FPS.
    nonisolated static func render(
        scene: FrameScene,
        resources: SharedFrameRenderResources,
        over background: CIImage?
    ) -> CIImage {
        let canvasRect = CGRect(
            x: 0,
            y: 0,
            width: max(scene.canvasSize.width, 2),
            height: max(scene.canvasSize.height, 2)
        )
        var result = background
            ?? resources.preparedBackground
            ?? backgroundImage(
                scene: scene.background,
                canvasRect: canvasRect,
                wallpaperSource: resources.wallpaper
            )

        let hasAttachedCursor = scene.layerOrder.contains(.cursor)
            && scene.cursor?.attachment == .screen
            && resources.cursor != nil
        let projectsScreen = !isIdentityProjection(scene.screen)

        for role in scene.layerOrder where role != .background {
            switch role {
            case .background:
                break
            case .screen:
                guard let renderedScreen = renderScreen(
                    source: resources.screen,
                    scene: scene.screen,
                    attachedCursorScene: projectsScreen && hasAttachedCursor
                        ? scene.cursor
                        : nil,
                    attachedCursorSource: projectsScreen && hasAttachedCursor
                        ? resources.cursor
                        : nil,
                    over: result,
                    canvasRect: canvasRect
                ) else { return result }
                result = renderedScreen
            case .cursor:
                // A projected screen owns its cursor so both are lowered by
                // the same homography. The identity fast path deliberately
                // retains the former separate cursor composition.
                if projectsScreen && hasAttachedCursor { continue }
                guard let cursorScene = scene.cursor,
                      let cursorImage = resources.cursor else { continue }
                result = renderCursor(
                    source: cursorImage,
                    scene: cursorScene,
                    over: result,
                    canvasRect: canvasRect
                )
            case .camera:
                guard let cameraScene = scene.camera,
                      cameraScene.opacity > 0,
                      let cameraImage = resources.camera else { continue }
                result = renderCamera(
                    source: cameraImage,
                    scene: cameraScene,
                    over: result,
                    canvasRect: canvasRect
                )
            }
        }
        return result.cropped(to: canvasRect)
    }

    nonisolated static func coreImageRect(
        from rect: CompositionRect,
        canvasHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.x,
            y: Double(canvasHeight) - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    nonisolated static func sourceCropRect(
        sourceExtent: CGRect,
        crop: NormalizedCrop
    ) -> CGRect {
        let safeCrop = crop.clamped()
        return CGRect(
            x: sourceExtent.width * safeCrop.x,
            y: sourceExtent.height * (1 - safeCrop.y - safeCrop.height),
            width: sourceExtent.width * safeCrop.width,
            height: sourceExtent.height * safeCrop.height
        ).intersection(sourceExtent)
    }

    private nonisolated static func renderScreen(
        source: CIImage,
        scene: FrameScreenScene,
        attachedCursorScene: FrameCursorScene?,
        attachedCursorSource: CIImage?,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage? {
        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        let normalizedSource = normalized(source)
        let cropRect = sourceCropRect(
            sourceExtent: normalizedSource.extent,
            crop: scene.sourceCrop
        )
        guard cropRect.width > 1, cropRect.height > 1 else { return nil }
        let croppedSource = normalizedSource
            .cropped(to: cropRect)
            .transformed(
                by: CGAffineTransform(
                    translationX: -cropRect.minX,
                    y: -cropRect.minY
                )
            )

        let baseRect = coreImageRect(
            from: scene.baseRect,
            canvasHeight: canvasRect.height
        )
        let finalRect = coreImageRect(
            from: scene.finalRect,
            canvasHeight: canvasRect.height
        )
        guard baseRect.width > 0, baseRect.height > 0,
              finalRect.width > 0, finalRect.height > 0 else { return nil }

        let fitScale = min(
            baseRect.width / max(croppedSource.extent.width, 1),
            baseRect.height / max(croppedSource.extent.height, 1)
        )
        // Reconstruct the former viewport transform from the canonical base and
        // final rectangles. This retains the exact 2D lowering while keeping
        // viewport-specific project state out of the renderer boundary.
        let zoomScale = finalRect.width / baseRect.width
        // EXP-001 / PRE-006: map the original cropped source straight into the
        // final zoomed rectangle. The former path first fitted and masked at
        // `baseRect`, then enlarged that intermediate image; small text was
        // therefore downsampled before a 1.6x/2x zoom. One combined transform
        // retains every source pixel until the final output sampling pass.
        let finalScale = fitScale * zoomScale
        let transformed = croppedSource
            .transformed(
                by: CGAffineTransform(scaleX: finalScale, y: finalScale)
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: finalRect.midX
                        - croppedSource.extent.width * finalScale / 2,
                    y: finalRect.midY
                        - croppedSource.extent.height * finalScale / 2
                )
            )

        let finalMask = roundedMask(rect: finalRect, radius: scene.cornerRadius)
        let crispSource = transformed.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: finalMask,
            ]
        )

        let projectionRect = coreImageRect(
            from: scene.projectionRect,
            canvasHeight: canvasRect.height
        )
        let projectionCornerRadius: Double
        let projectionMask: CIImage
        let chromeLayer: CIImage?
        var decoratedLayer: CIImage
        switch scene.decoration {
        case .none:
            projectionCornerRadius = scene.cornerRadius
            projectionMask = finalMask
            chromeLayer = nil
            decoratedLayer = crispSource
        case let .chrome(chrome):
            projectionCornerRadius = chrome.outerCornerRadius
            projectionMask = roundedMask(
                rect: projectionRect,
                radius: chrome.outerCornerRadius
            )
            let layer = screenChromeLayer(chrome, canvasRect: canvasRect)
            chromeLayer = layer
            decoratedLayer = crispSource.composited(over: layer)
        }
        var projectionSourceRect = projectionRect
        var borderLayer: CIImage?

        if scene.borderWidth > 0 {
            let borderRect = projectionRect.insetBy(
                dx: -scene.borderWidth,
                dy: -scene.borderWidth
            )
            let borderMask = roundedMask(
                rect: borderRect,
                radius: projectionCornerRadius + scene.borderWidth
            )
            let border = coloredLayer(
                color: CIColor(scene.borderColor, alpha: scene.borderOpacity),
                mask: borderMask,
                canvasRect: borderRect
            )
            borderLayer = border
            // MOT-001: put one outer surface behind the already-clipped screen.
            // The former ring path added SourceOut + a full-canvas mask to the
            // very first perspective frame, causing a border-only shader/allocation
            // spike as 3D motion began. The visible result is identical: opaque
            // screen/chrome covers the center and only the outer rim remains.
            decoratedLayer = decoratedLayer.composited(over: border)
            projectionSourceRect = projectionSourceRect.union(borderRect)
        }

        let attachedCursor: CursorLayer? = if let cursorScene = attachedCursorScene,
                                             let cursorSource = attachedCursorSource {
            cursorLayer(
                source: cursorSource,
                scene: cursorScene,
                canvasRect: canvasRect
            )
        } else {
            nil
        }
        if let cursor = attachedCursor {
            decoratedLayer = cursor.image.composited(over: decoratedLayer)
            projectionSourceRect = projectionSourceRect.union(cursor.footprint)
        }

        let identityProjection = isIdentityProjection(scene)
        let projectedLayer: CIImage
        if identityProjection {
            // Do not send ordinary 2D frames through a perspective filter:
            // this preserves the previous sampling, border and antialiasing.
            projectedLayer = decoratedLayer
        } else {
            // Every screen sublayer shares the exact same authored quad. Solve
            // its 8×8 homography once for this temporal sample, then reuse it
            // for native pixels, chrome, border and an attached cursor. The old
            // path solved and allocated the matrix independently for each
            // sublayer (up to 128 solves for one 32-sample blur frame).
            let projectionMapping = projectionMapping(
                projectedQuad: scene.projectedQuad,
                canvasHeight: canvasRect.height
            )
            // Clip rounded corners in native source coordinates before the
            // single perspective sample. Projecting a second full-card mask
            // would preserve sharpness but add another perspective kernel to
            // every temporal sample in full-resolution preview.
            let sourceCornerRadius = scene.cornerRadius / max(finalScale, 0.000_1)
            let nativeMask = roundedMask(
                rect: croppedSource.extent,
                radius: sourceCornerRadius
            )
            let nativeTransparent = CIImage(color: .clear).cropped(to: croppedSource.extent)
            let nativeClippedSource = croppedSource.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: nativeTransparent,
                    kCIInputMaskImageKey: nativeMask,
                ]
            )
            if let directSource = directPerspectiveTransform(
                nativeClippedSource,
                canonicalDestinationRect: transformed.extent,
                projectionRect: projectionRect,
                mapping: projectionMapping
            ) {
                // PRE-006 / EXP-001: the recorded pixels travel from their native
                // crop straight to the final 3D quad. The former path first enlarged
                // them into `finalRect`, blended chrome/border/cursor, then sampled
                // that raster a second time through the perspective filter. Text and
                // one-pixel UI edges therefore became pale and soft in both full
                // preview and export. Masks and vector decoration may be projected
                // independently; the screen texture itself must be sampled once.
                var projected = directSource
                if let chromeLayer,
                   let projectedChrome = perspectiveTransform(
                       chromeLayer,
                       sourceRect: projectionRect,
                       contentExtent: projectionRect,
                       mapping: projectionMapping
                   ) {
                    projected = projected.composited(over: projectedChrome)
                }
                if let borderLayer,
                   let projectedBorder = perspectiveTransform(
                       borderLayer,
                       sourceRect: projectionRect,
                       contentExtent: borderLayer.extent,
                       mapping: projectionMapping
                   ) {
                    projected = projected.composited(over: projectedBorder)
                }
                if let cursor = attachedCursor,
                   let projectedCursor = perspectiveTransform(
                       cursor.image,
                       sourceRect: projectionRect,
                       contentExtent: cursor.footprint,
                       mapping: projectionMapping
                   ) {
                    projected = projectedCursor.composited(over: projected)
                }
                projectedLayer = projected
            } else {
                // Invalid or degenerate authored geometry must never blank a
                // recording. Falling back to the canonical 2D layer is safer
                // than returning an empty Core Image graph.
                projectedLayer = decoratedLayer
            }
        }

        var screenLayer = CIImage(color: .clear).cropped(to: canvasRect)
        if let shadow = scene.shadow, shadow.opacity > 0 {
            let shadowMask: CIImage
            if identityProjection {
                // This is exactly the former 2D shadow source. The projected
                // path below instead derives its shadow from post-warp alpha.
                shadowMask = projectionMask
            } else {
                shadowMask = alphaMask(projectedLayer)
            }
            let translatedShadow = shadowMask
                .transformed(
                    by: CGAffineTransform(
                        translationX: shadow.offset.x,
                        y: -shadow.offset.y
                    )
                )
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: shadow.radius]
                )
                .cropped(to: canvasRect)
            screenLayer = coloredLayer(
                color: CIColor(shadow.color, alpha: shadow.opacity),
                mask: translatedShadow,
                canvasRect: canvasRect
            ).composited(over: screenLayer)
        }
        screenLayer = projectedLayer.composited(over: screenLayer)
        return screenLayer.composited(over: background).cropped(to: canvasRect)
    }

    /// Draws original vector chrome with no bundled third-party artwork. The
    /// result is clipped once to the evaluated outer shape, then travels with
    /// the screen through the same homography as content, border and cursor.
    private nonisolated static func screenChromeLayer(
        _ chrome: FrameScreenChromeScene,
        canvasRect: CGRect
    ) -> CIImage {
        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        let outerRect = coreImageRect(
            from: chrome.outerRect,
            canvasHeight: canvasRect.height
        )
        let toolbarRect = coreImageRect(
            from: chrome.toolbarRect,
            canvasHeight: canvasRect.height
        )
        let outerMask = roundedMask(
            rect: outerRect,
            radius: chrome.outerCornerRadius
        )
        let surface = coloredLayer(
            color: CIColor(chrome.surfaceColor),
            mask: outerMask,
            canvasRect: canvasRect
        )
        let toolbarMask = CIImage(color: .white)
            .cropped(to: toolbarRect)
        let toolbar = coloredLayer(
            color: CIColor(chrome.toolbarColor),
            mask: toolbarMask,
            canvasRect: canvasRect
        )
        var layer = toolbar.composited(over: surface)

        let separatorHeight = max(toolbarRect.height * 0.035, 0.75)
        let separatorRect = CGRect(
            x: toolbarRect.minX,
            y: toolbarRect.minY,
            width: toolbarRect.width,
            height: separatorHeight
        )
        layer = CIImage(color: CIColor(chrome.separatorColor))
            .cropped(to: separatorRect)
            .composited(over: layer)

        let controlDiameter = min(
            max(toolbarRect.height * 0.23, 1.5),
            toolbarRect.height * 0.32
        )
        let controlMargin = max(toolbarRect.height * 0.31, controlDiameter)
        let controlSpacing = controlDiameter * 1.62
        let controlColors = [
            HexColor(rgb24: 0xFF_5F_57),
            HexColor(rgb24: 0xFE_BC_2E),
            HexColor(rgb24: 0x28_C8_40),
        ]
        for (index, color) in controlColors.enumerated() {
            let rect = CGRect(
                x: toolbarRect.minX + controlMargin + CGFloat(index) * controlSpacing,
                y: toolbarRect.midY - controlDiameter / 2,
                width: controlDiameter,
                height: controlDiameter
            )
            let control = coloredLayer(
                color: CIColor(color),
                mask: roundedMask(rect: rect, radius: controlDiameter / 2),
                canvasRect: canvasRect
            )
            layer = control.composited(over: layer)
        }

        let controlsEnd = toolbarRect.minX + controlMargin
            + controlSpacing * 2 + controlDiameter
        switch chrome.kind {
        case .window:
            let titleWidth = min(toolbarRect.width * 0.22, toolbarRect.height * 3.2)
            let titleHeight = max(toolbarRect.height * 0.11, 1)
            let titleRect = CGRect(
                x: toolbarRect.midX - titleWidth / 2,
                y: toolbarRect.midY - titleHeight / 2,
                width: titleWidth,
                height: titleHeight
            )
            layer = coloredLayer(
                color: CIColor(chrome.glyphColor, alpha: 0.38),
                mask: roundedMask(rect: titleRect, radius: titleHeight / 2),
                canvasRect: canvasRect
            ).composited(over: layer)
        case .browser:
            let fieldMargin = max(toolbarRect.height * 0.28, 2)
            let fieldX = controlsEnd + fieldMargin
            let fieldWidth = max(toolbarRect.maxX - fieldMargin - fieldX, 2)
            let fieldHeight = max(toolbarRect.height * 0.52, 2)
            let fieldRect = CGRect(
                x: fieldX,
                y: toolbarRect.midY - fieldHeight / 2,
                width: fieldWidth,
                height: fieldHeight
            )
            layer = coloredLayer(
                color: CIColor(chrome.fieldColor),
                mask: roundedMask(rect: fieldRect, radius: fieldHeight / 2),
                canvasRect: canvasRect
            ).composited(over: layer)
            let glyphDiameter = max(fieldHeight * 0.22, 1)
            let glyphRect = CGRect(
                x: fieldRect.minX + fieldHeight * 0.34,
                y: fieldRect.midY - glyphDiameter / 2,
                width: glyphDiameter,
                height: glyphDiameter
            )
            layer = coloredLayer(
                color: CIColor(chrome.glyphColor, alpha: 0.62),
                mask: roundedMask(rect: glyphRect, radius: glyphDiameter / 2),
                canvasRect: canvasRect
            ).composited(over: layer)
        }

        return layer.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: outerMask,
            ]
        )
    }

    private nonisolated static func renderCamera(
        source: CIImage,
        scene: FrameCameraScene,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        let contentRect = coreImageRect(
            from: scene.rect,
            canvasHeight: canvasRect.height
        )
        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        let cameraMask = roundedMask(rect: contentRect, radius: scene.cornerRadius)
        let borderOuterRect = contentRect.insetBy(
            dx: -scene.borderWidth,
            dy: -scene.borderWidth
        )
        let borderOuterMask = roundedMask(
            rect: borderOuterRect,
            radius: scene.cornerRadius + scene.borderWidth
        )
        var cameraLayer = transparent

        if let shadow = scene.shadow, shadow.opacity > 0 {
            let shadowMask = borderOuterMask
                .transformed(
                    by: CGAffineTransform(
                        translationX: shadow.offset.x,
                        y: -shadow.offset.y
                    )
                )
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: shadow.radius]
                )
                .cropped(to: canvasRect)
            cameraLayer = coloredLayer(
                color: CIColor(shadow.color, alpha: shadow.opacity),
                mask: shadowMask,
                canvasRect: canvasRect
            ).composited(over: cameraLayer)
        }

        if scene.borderWidth > 0 {
            let border = coloredLayer(
                color: CIColor(scene.borderColor),
                mask: ringMask(
                    outer: borderOuterMask,
                    inner: cameraMask,
                    canvasRect: canvasRect
                ),
                canvasRect: canvasRect
            )
            cameraLayer = border.composited(over: cameraLayer)
        }

        let normalizedSource = normalized(source)
        guard let fill = scene.contentFill ?? CameraContentFill.layout(
            sourceWidth: normalizedSource.extent.width,
            sourceHeight: normalizedSource.extent.height,
            target: scene.rect
        ) else { return background }
        // `cameraDisplaySize` comes from the track contract, while the decoded
        // CIImage can expose a slightly different extent after clean-aperture
        // handling or letterbox cropping. Scaling the whole decoded extent by
        // the track-derived factor leaves a transparent strip whenever those
        // sizes differ. Map the normalized visible source aperture onto the
        // actual decoded extent first, then fill the target exactly.
        guard let sourceCrop = cameraSourceCropRect(
            sourceExtent: normalizedSource.extent,
            layout: fill
        ) else { return background }
        let scaleX = contentRect.width / sourceCrop.width
        let scaleY = contentRect.height / sourceCrop.height
        var placed = normalizedSource
            .cropped(to: sourceCrop)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(
                translationX: -sourceCrop.minX,
                y: -sourceCrop.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: contentRect.minX,
                y: contentRect.minY
            ))
            .cropped(to: contentRect)
        if scene.isMirrored {
            let axis = CGFloat(fill.mirrorAxisX)
            placed = placed
                .transformed(by: CGAffineTransform(translationX: -axis, y: 0))
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: axis, y: 0))
        }
        let clipped = placed.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: cameraMask,
            ]
        )
        cameraLayer = clipped.composited(over: cameraLayer)
        let visibleLayer = scene.opacity >= 0.999
            ? cameraLayer
            : cameraLayer.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: scene.opacity),
                ]
            )
        return visibleLayer.composited(over: background).cropped(to: canvasRect)
    }

    /// Converts the track-authored, top-left visible aperture into the actual
    /// Core Image extent delivered for this frame. Ratios are intentional:
    /// clean-aperture and decoder extents need not equal the track natural size.
    nonisolated static func cameraSourceCropRect(
        sourceExtent: CGRect,
        layout: CameraContentFillLayout
    ) -> CGRect? {
        let declared = layout.source
        let visible = layout.visibleSource
        guard sourceExtent.width.isFinite,
              sourceExtent.height.isFinite,
              sourceExtent.width > 0,
              sourceExtent.height > 0,
              declared.width.isFinite,
              declared.height.isFinite,
              declared.width > 0,
              declared.height > 0 else { return nil }
        let x = (visible.x - declared.x) / declared.width
        let y = (visible.y - declared.y) / declared.height
        let width = visible.width / declared.width
        let height = visible.height / declared.height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }
        let crop = CGRect(
            x: sourceExtent.minX + sourceExtent.width * x,
            y: sourceExtent.minY + sourceExtent.height * (1 - y - height),
            width: sourceExtent.width * width,
            height: sourceExtent.height * height
        ).intersection(sourceExtent)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }
        return crop
    }

    private nonisolated static func renderCursor(
        source: CIImage,
        scene: FrameCursorScene,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        guard let layer = cursorLayer(
            source: source,
            scene: scene,
            canvasRect: canvasRect
        ) else { return background }
        return layer.image.composited(over: background).cropped(to: canvasRect)
    }

    private struct CursorLayer {
        var image: CIImage
        var footprint: CGRect
    }

    private nonisolated static func cursorLayer(
        source: CIImage,
        scene: FrameCursorScene,
        canvasRect: CGRect
    ) -> CursorLayer? {
        let normalizedSource = normalized(source)
        guard normalizedSource.extent.width > 0,
              normalizedSource.extent.height > 0 else { return nil }
        let layout = scene.layout
        let scaled = normalizedSource.transformed(
            by: CGAffineTransform(
                scaleX: layout.size.width / normalizedSource.extent.width,
                y: layout.size.height / normalizedSource.extent.height
            )
        )
        let placed = scaled.transformed(
            by: CGAffineTransform(
                translationX: layout.origin.x,
                y: Double(canvasRect.maxY) - layout.origin.y - layout.size.height
            )
        )

        var layer = placed
        var footprint = placed.extent
        if scene.isClicking {
            let pointer = CGPoint(
                x: layout.pointer.x,
                y: Double(canvasRect.maxY) - layout.pointer.y
            )
            let progress = scene.clickPhase?.progress ?? 0.25
            let effectiveColor = scene.effectiveClickColor
            if let clickGeom = CursorRenderGeometry.clickGeometry(
                style: scene.clickStyle,
                progress: progress,
                baseHeight: layout.size.height,
                opacityMultiplier: scene.clickOpacity,
                scaleMultiplier: scene.clickScale
            ) {
                var clickLayerAccum: CIImage?

                if scene.clickStyle == .glow {
                    let diameter = CGFloat(clickGeom.primaryDiameter)
                    let outerRect = CGRect(
                        x: pointer.x - diameter / 2,
                        y: pointer.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    let r = diameter / 2
                    if let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                        "inputCenter": CIVector(x: pointer.x, y: pointer.y),
                        "inputRadius0": 0.0,
                        "inputRadius1": r,
                        "inputColor0": CIColor(effectiveColor, alpha: CGFloat(clickGeom.primaryOpacity)),
                        "inputColor1": CIColor(effectiveColor, alpha: 0.0)
                    ])?.outputImage?.cropped(to: outerRect) {
                        clickLayerAccum = gradient
                        footprint = footprint.union(outerRect)
                    }
                } else {
                    // Render secondary shape first (spark dot, inner ring, or bounce bubble)
                    if clickGeom.secondaryDiameter > 0 && clickGeom.secondaryOpacity > 0.001 {
                        let secDiameter = CGFloat(clickGeom.secondaryDiameter)
                        let secOuterRect = CGRect(
                            x: pointer.x - secDiameter / 2,
                            y: pointer.y - secDiameter / 2,
                            width: secDiameter,
                            height: secDiameter
                        )
                        let secImage: CIImage
                        if clickGeom.secondaryIsFilled {
                            secImage = coloredLayer(
                                color: CIColor(effectiveColor, alpha: CGFloat(clickGeom.secondaryOpacity)),
                                mask: roundedMask(rect: secOuterRect, radius: secDiameter / 2),
                                canvasRect: canvasRect
                            )
                        } else {
                            let secInnerRect = secOuterRect.insetBy(
                                dx: CGFloat(clickGeom.secondaryLineWidth),
                                dy: CGFloat(clickGeom.secondaryLineWidth)
                            )
                            secImage = coloredLayer(
                                color: CIColor(effectiveColor, alpha: CGFloat(clickGeom.secondaryOpacity)),
                                mask: ringMask(
                                    outer: roundedMask(rect: secOuterRect, radius: secDiameter / 2),
                                    inner: roundedMask(rect: secInnerRect, radius: max(secInnerRect.width / 2, 0)),
                                    canvasRect: canvasRect
                                ),
                                canvasRect: canvasRect
                            )
                        }
                        clickLayerAccum = secImage
                        footprint = footprint.union(secOuterRect)
                    }

                    // Render accent burst dots (for burst style)
                    if clickGeom.accentSize > 0 && clickGeom.accentOpacity > 0.001 && clickGeom.accentOffset > 0 {
                        let sz = CGFloat(clickGeom.accentSize)
                        let offset = CGFloat(clickGeom.accentOffset)
                        let accentPositions = [
                            CGPoint(x: pointer.x, y: pointer.y - offset),
                            CGPoint(x: pointer.x, y: pointer.y + offset),
                            CGPoint(x: pointer.x - offset, y: pointer.y),
                            CGPoint(x: pointer.x + offset, y: pointer.y),
                        ]
                        for pos in accentPositions {
                            let dotRect = CGRect(x: pos.x - sz / 2, y: pos.y - sz / 2, width: sz, height: sz)
                            let dotImg = coloredLayer(
                                color: CIColor(effectiveColor, alpha: CGFloat(clickGeom.accentOpacity)),
                                mask: roundedMask(rect: dotRect, radius: sz / 2),
                                canvasRect: canvasRect
                            )
                            clickLayerAccum = clickLayerAccum?.composited(over: dotImg) ?? dotImg
                            footprint = footprint.union(dotRect)
                        }
                    }

                    // Render primary shape (outer ring, main pulse ring, etc.)
                    if clickGeom.primaryDiameter > 0 && clickGeom.primaryOpacity > 0.001 {
                        let diameter = CGFloat(clickGeom.primaryDiameter)
                        let outerRect = CGRect(
                            x: pointer.x - diameter / 2,
                            y: pointer.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                        let primaryImage: CIImage
                        if clickGeom.primaryIsFilled {
                            primaryImage = coloredLayer(
                                color: CIColor(effectiveColor, alpha: CGFloat(clickGeom.primaryOpacity)),
                                mask: roundedMask(rect: outerRect, radius: diameter / 2),
                                canvasRect: canvasRect
                            )
                        } else {
                            let innerRect = outerRect.insetBy(
                                dx: CGFloat(clickGeom.primaryLineWidth),
                                dy: CGFloat(clickGeom.primaryLineWidth)
                            )
                            primaryImage = coloredLayer(
                                color: CIColor(effectiveColor, alpha: CGFloat(clickGeom.primaryOpacity)),
                                mask: ringMask(
                                    outer: roundedMask(rect: outerRect, radius: diameter / 2),
                                    inner: roundedMask(rect: innerRect, radius: max(innerRect.width / 2, 0)),
                                    canvasRect: canvasRect
                                ),
                                canvasRect: canvasRect
                            )
                        }
                        clickLayerAccum = clickLayerAccum != nil ? primaryImage.composited(over: clickLayerAccum!) : primaryImage
                        footprint = footprint.union(outerRect)
                    }
                }

                if let clickLayerAccum {
                    layer = placed.composited(over: clickLayerAccum)
                }
            } else {
                let diameter = CGFloat(layout.clickDiameter) * CGFloat(scene.clickScale)
                let outerRect = CGRect(
                    x: pointer.x - diameter / 2,
                    y: pointer.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                let innerRect = outerRect.insetBy(
                    dx: layout.clickLineWidth,
                    dy: layout.clickLineWidth
                )
                let ring = coloredLayer(
                    color: CIColor(effectiveColor, alpha: CGFloat(scene.clickOpacity)),
                    mask: ringMask(
                        outer: roundedMask(rect: outerRect, radius: diameter / 2),
                        inner: roundedMask(rect: innerRect, radius: innerRect.width / 2),
                        canvasRect: canvasRect
                    ),
                    canvasRect: canvasRect
                )
                layer = placed.composited(over: ring)
                footprint = footprint.union(outerRect)
            }
        }
        return CursorLayer(
            image: layer.cropped(to: footprint),
            footprint: footprint
        )
    }

    /// The tolerance is intentionally sub-pixel. Authored zero rotations are
    /// mathematically exact, while negligible floating-point residue from an
    /// animation endpoint should not introduce an extra resampling pass.
    nonisolated static func isIdentityProjection(
        _ scene: FrameScreenScene,
        tolerance: Double = 0.35
    ) -> Bool {
        let rect = scene.projectionRect
        guard rect.width > 0, rect.height > 0 else { return true }
        let expected = ProjectedScreenQuad(
            topLeft: CompositionPoint(x: rect.x, y: rect.y),
            topRight: CompositionPoint(x: rect.x + rect.width, y: rect.y),
            bottomRight: CompositionPoint(
                x: rect.x + rect.width,
                y: rect.y + rect.height
            ),
            bottomLeft: CompositionPoint(x: rect.x, y: rect.y + rect.height)
        )
        let actual = scene.projectedQuad
        let values = [
            actual.topLeft.x, actual.topLeft.y,
            actual.topRight.x, actual.topRight.y,
            actual.bottomRight.x, actual.bottomRight.y,
            actual.bottomLeft.x, actual.bottomLeft.y,
        ]
        guard values.allSatisfy(\.isFinite) else { return true }
        return approximatelyEqual(actual.topLeft, expected.topLeft, tolerance: tolerance)
            && approximatelyEqual(actual.topRight, expected.topRight, tolerance: tolerance)
            && approximatelyEqual(
                actual.bottomRight,
                expected.bottomRight,
                tolerance: tolerance
            )
            && approximatelyEqual(
                actual.bottomLeft,
                expected.bottomLeft,
                tolerance: tolerance
            )
    }

    private nonisolated static func approximatelyEqual(
        _ lhs: CompositionPoint,
        _ rhs: CompositionPoint,
        tolerance: Double
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    /// Maps `sourceRect` to `projectedQuad`. `contentExtent` may extend beyond
    /// the screen rectangle (border/cursor); its destination corners are
    /// extrapolated with the same homography so those pixels are not clipped.
    private nonisolated static func perspectiveTransform(
        _ image: CIImage,
        sourceRect: CGRect,
        contentExtent: CGRect,
        mapping: UnitSquareHomography?
    ) -> CIImage? {
        guard sourceRect.width > 0, sourceRect.height > 0,
              contentExtent.width > 0, contentExtent.height > 0,
              let mapping,
              let contentDestination = projectedDestinationQuad(
                  for: contentExtent,
                  relativeTo: sourceRect,
                  mapping: mapping
              ) else { return nil }

        return perspectiveTransform(
            image.cropped(to: contentExtent),
            inputExtent: contentExtent,
            destination: contentDestination
        )
    }

    /// Samples native recorded pixels once into a canonical sub-rectangle of
    /// the projected screen card. `canonicalDestinationRect` is expressed in
    /// the same pre-projection coordinates as `projectionRect`; the input image
    /// remains at source resolution until Core Image evaluates this warp.
    private nonisolated static func directPerspectiveTransform(
        _ image: CIImage,
        canonicalDestinationRect: CGRect,
        projectionRect: CGRect,
        mapping: UnitSquareHomography?
    ) -> CIImage? {
        guard image.extent.width > 0, image.extent.height > 0,
              projectionRect.width > 0, projectionRect.height > 0,
              canonicalDestinationRect.width > 0,
              canonicalDestinationRect.height > 0 else { return nil }
        guard let mapping,
              let contentDestination = projectedDestinationQuad(
                  for: canonicalDestinationRect,
                  relativeTo: projectionRect,
                  mapping: mapping
              ) else { return nil }
        return perspectiveTransform(
            image,
            inputExtent: image.extent,
            destination: contentDestination
        )
    }

    private nonisolated static func projectionMapping(
        projectedQuad: ProjectedScreenQuad,
        canvasHeight: CGFloat
    ) -> UnitSquareHomography? {
        UnitSquareHomography(destination: CoreImageQuad(
            topLeft: coreImagePoint(projectedQuad.topLeft, canvasHeight: canvasHeight),
            topRight: coreImagePoint(projectedQuad.topRight, canvasHeight: canvasHeight),
            bottomRight: coreImagePoint(
                projectedQuad.bottomRight,
                canvasHeight: canvasHeight
            ),
            bottomLeft: coreImagePoint(
                projectedQuad.bottomLeft,
                canvasHeight: canvasHeight
            )
        ))
    }

    private nonisolated static func projectedDestinationQuad(
        for contentRect: CGRect,
        relativeTo sourceRect: CGRect,
        mapping: UnitSquareHomography
    ) -> CoreImageQuad? {
        func projectedPoint(x: CGFloat, y: CGFloat) -> CGPoint? {
            mapping.map(
                x: (x - sourceRect.minX) / sourceRect.width,
                y: (y - sourceRect.minY) / sourceRect.height
            )
        }

        guard let topLeft = projectedPoint(
            x: contentRect.minX,
            y: contentRect.maxY
        ), let topRight = projectedPoint(
            x: contentRect.maxX,
            y: contentRect.maxY
        ), let bottomRight = projectedPoint(
            x: contentRect.maxX,
            y: contentRect.minY
        ), let bottomLeft = projectedPoint(
            x: contentRect.minX,
            y: contentRect.minY
        ) else { return nil }

        return CoreImageQuad(
            topLeft: topLeft,
            topRight: topRight,
            bottomRight: bottomRight,
            bottomLeft: bottomLeft
        )
    }

    private nonisolated static func perspectiveTransform(
        _ image: CIImage,
        inputExtent: CGRect,
        destination: CoreImageQuad
    ) -> CIImage? {
        return image
            .cropped(to: inputExtent)
            .applyingFilter(
                "CIPerspectiveTransformWithExtent",
                parameters: [
                    "inputExtent": CIVector(cgRect: inputExtent),
                    "inputTopLeft": CIVector(cgPoint: destination.topLeft),
                    "inputTopRight": CIVector(cgPoint: destination.topRight),
                    "inputBottomRight": CIVector(cgPoint: destination.bottomRight),
                    "inputBottomLeft": CIVector(cgPoint: destination.bottomLeft),
                ]
            )
    }

    private nonisolated static func coreImagePoint(
        _ point: CompositionPoint,
        canvasHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: Double(canvasHeight) - point.y)
    }

    private nonisolated static func alphaMask(_ image: CIImage) -> CIImage {
        let alpha = CIVector(x: 0, y: 0, z: 0, w: 1)
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": alpha,
                "inputGVector": alpha,
                "inputBVector": alpha,
                "inputAVector": alpha,
            ]
        )
    }

    private struct CoreImageQuad {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint
    }

    /// Projective mapping from unit-square Core Image coordinates into the
    /// destination quadrilateral. Solving the eight homography coefficients
    /// lets the renderer extrapolate the same transform to an outer border or
    /// a cursor whose sprite reaches beyond the screen rectangle.
    private struct UnitSquareHomography {
        private var coefficients: [Double]

        init?(destination: CoreImageQuad) {
            let correspondences: [(Double, Double, CGPoint)] = [
                (0, 1, destination.topLeft),
                (1, 1, destination.topRight),
                (1, 0, destination.bottomRight),
                (0, 0, destination.bottomLeft),
            ]
            var system = [[Double]]()
            system.reserveCapacity(8)
            for (x, y, point) in correspondences {
                let u = Double(point.x)
                let v = Double(point.y)
                guard x.isFinite, y.isFinite, u.isFinite, v.isFinite else {
                    return nil
                }
                system.append([
                    x, y, 1, 0, 0, 0, -u * x, -u * y, u,
                ])
                system.append([
                    0, 0, 0, x, y, 1, -v * x, -v * y, v,
                ])
            }
            guard let solution = Self.solve(system) else { return nil }
            coefficients = solution
        }

        func map(x: CGFloat, y: CGFloat) -> CGPoint? {
            let x = Double(x)
            let y = Double(y)
            let denominator = coefficients[6] * x + coefficients[7] * y + 1
            guard denominator.isFinite, abs(denominator) > 0.000_000_001 else {
                return nil
            }
            let projectedX = (
                coefficients[0] * x + coefficients[1] * y + coefficients[2]
            ) / denominator
            let projectedY = (
                coefficients[3] * x + coefficients[4] * y + coefficients[5]
            ) / denominator
            guard projectedX.isFinite, projectedY.isFinite else { return nil }
            return CGPoint(x: projectedX, y: projectedY)
        }

        private static func solve(_ augmented: [[Double]]) -> [Double]? {
            let count = 8
            guard augmented.count == count,
                  augmented.allSatisfy({ $0.count == count + 1 }) else {
                return nil
            }
            var matrix = augmented
            for column in 0..<count {
                guard let pivotRow = (column..<count).max(by: {
                    abs(matrix[$0][column]) < abs(matrix[$1][column])
                }), abs(matrix[pivotRow][column]) > 0.000_000_000_001 else {
                    return nil
                }
                if pivotRow != column {
                    matrix.swapAt(pivotRow, column)
                }
                let pivot = matrix[column][column]
                for index in column...count {
                    matrix[column][index] /= pivot
                }
                for row in 0..<count where row != column {
                    let factor = matrix[row][column]
                    if abs(factor) <= 0.000_000_000_001 { continue }
                    for index in column...count {
                        matrix[row][index] -= factor * matrix[column][index]
                    }
                }
            }
            let result = matrix.map { $0[count] }
            return result.allSatisfy(\.isFinite) ? result : nil
        }
    }

    nonisolated static func backgroundImage(
        scene: FrameBackgroundScene,
        canvasRect: CGRect,
        wallpaperSource: CIImage?
    ) -> CIImage {
        if scene.source.isImage, let wallpaperSource {
            let normalizedSource = normalized(wallpaperSource)
            let scale = max(
                canvasRect.width / max(normalizedSource.extent.width, 1),
                canvasRect.height / max(normalizedSource.extent.height, 1)
            )
            let scaled = normalizedSource.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
            var background = scaled
                .transformed(
                    by: CGAffineTransform(
                        translationX: canvasRect.midX - scaled.extent.midX,
                        y: canvasRect.midY - scaled.extent.midY
                    )
                )
                .cropped(to: canvasRect)
            if scene.blurRadius > 0 {
                background = background
                    .clampedToExtent()
                    .applyingFilter(
                        "CIGaussianBlur",
                        parameters: [kCIInputRadiusKey: scene.blurRadius]
                    )
                    .cropped(to: canvasRect)
            }
            return background
        }

        let colors: (CIColor, CIColor)
        switch scene.source {
        case .gradient(.aurora):
            colors = (
                CIColor(HexColor(rgb24: 0x6A_5A_E0)),
                CIColor(HexColor(rgb24: 0x2D_B7_D3))
            )
        case .gradient(.twilight):
            colors = (
                CIColor(HexColor(rgb24: 0x30_2B_63)),
                CIColor(HexColor(rgb24: 0xD7_6D_77))
            )
        case .gradient(.sunrise):
            colors = (
                CIColor(HexColor(rgb24: 0xFF_8A_5B)),
                CIColor(HexColor(rgb24: 0xFF_D5_6B))
            )
        case .gradient(.graphite):
            colors = (
                CIColor(HexColor(rgb24: 0x12_15_1C)),
                CIColor(HexColor(rgb24: 0x45_4B_58))
            )
        case let .solidColor(hex):
            return CIImage(color: CIColor(hex)).cropped(to: canvasRect)
        case .bundledImage, .projectImage, .systemImage:
            colors = (
                CIColor(.defaultBackground),
                CIColor(HexColor(rgb24: 0x12_15_1C))
            )
        }
        return CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: canvasRect.minX, y: canvasRect.maxY),
                "inputPoint1": CIVector(x: canvasRect.maxX, y: canvasRect.minY),
                "inputColor0": colors.0,
                "inputColor1": colors.1,
            ]
        )?.outputImage?.cropped(to: canvasRect)
            ?? CIImage(color: colors.0).cropped(to: canvasRect)
    }

    private nonisolated static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
    }

    private nonisolated static func roundedMask(
        rect: CGRect,
        radius: CGFloat
    ) -> CIImage {
        ContinuousCornerMask.mask(rect: rect, radius: radius)
    }

    private nonisolated static func coloredLayer(
        color: CIColor,
        mask: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        let foreground = CIImage(color: color).cropped(to: canvasRect)
        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        return foreground.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask,
            ]
        )
    }

    private nonisolated static func ringMask(
        outer: CIImage,
        inner: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        outer.applyingFilter(
            "CISourceOutCompositing",
            parameters: [kCIInputBackgroundImageKey: inner]
        )
        .cropped(to: canvasRect)
    }
}

private extension CIColor {
    convenience init(_ color: HexColor, alpha: CGFloat = 1) {
        let components = color.components
        self.init(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: alpha
        )
    }
}
