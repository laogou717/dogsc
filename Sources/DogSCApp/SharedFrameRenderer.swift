import AppKit
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
    var stickers: [String: CIImage]
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
        stickers: [String: CIImage] = [:],
        preparedBackground: CIImage? = nil
    ) {
        self.screen = screen
        self.camera = camera
        self.wallpaper = wallpaper
        self.cursor = cursor
        self.stickers = stickers
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

    /// Renders the scene over a caller-provided background. Moving layers use
    /// their evaluated one-frame displacement; the canvas background remains
    /// sharp and is never re-rendered as blur history.
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

        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
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
                    over: transparent,
                    canvasRect: canvasRect
                ) else { return result }
                result = SharedFrameOverlayRenderer.motionBlurred(
                    renderedScreen,
                    motion: scene.screen.motion,
                    canvasRect: canvasRect
                ).composited(over: result).cropped(to: canvasRect)
            case .cursor:
                // A projected screen owns its cursor so both are lowered by
                // the same homography. The identity fast path deliberately
                // retains the former separate cursor composition.
                if projectsScreen && hasAttachedCursor { continue }
                guard let cursorScene = scene.cursor,
                      let cursorImage = resources.cursor else { continue }
                let cursorLayer = SharedFrameCursorRenderer.render(
                    source: cursorImage,
                    scene: cursorScene,
                    over: transparent,
                    canvasRect: canvasRect
                )
                result = SharedFrameOverlayRenderer.motionBlurred(
                    cursorLayer,
                    motion: cursorScene.motion,
                    canvasRect: canvasRect
                ).composited(over: result).cropped(to: canvasRect)
            case .spotlight:
                result = applyingSpotlights(
                    scene.screen.mosaics,
                    source: resources.screen,
                    screen: scene.screen,
                    to: result,
                    canvasRect: canvasRect
                )
            case .camera:
                guard let cameraScene = scene.camera,
                      cameraScene.opacity > 0,
                      let cameraImage = resources.camera else { continue }
                let cameraLayer = renderCamera(
                    source: cameraImage,
                    scene: cameraScene,
                    over: transparent,
                    canvasRect: canvasRect
                )
                result = SharedFrameOverlayRenderer.motionBlurred(
                    cameraLayer,
                    motion: cameraScene.motion,
                    canvasRect: canvasRect
                ).composited(over: result).cropped(to: canvasRect)
            case .stickers:
                guard !scene.stickers.isEmpty else { continue }
                let blur = scene.stickers.map(\.backdropBlur).max() ?? 0
                if blur > 0.01 {
                    result = result.clampedToExtent()
                        .applyingFilter(
                            "CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: blur]
                        )
                        .cropped(to: canvasRect)
                }
                for sticker in scene.stickers {
                    guard let source = resources.stickers[sticker.relativePath] else {
                        continue
                    }
                    result = SharedFrameOverlayRenderer.renderSticker(
                        source: source,
                        scene: sticker,
                        over: result,
                        canvasRect: canvasRect
                    )
                }
            case .progress:
                guard let progress = scene.progress else { continue }
                result = SharedFrameOverlayRenderer.renderProgress(
                    progress,
                    over: result,
                    canvasRect: canvasRect
                )
            }
        }
        return result.cropped(to: canvasRect)
    }

    /// Spotlight is a single effect over the complete base composite. At this
    /// point the wallpaper, recorded pixels, screen chrome, border, shadow and
    /// cursor already form one image; camera, stickers and progress have not
    /// yet been drawn. The authored source rectangle is transformed through
    /// the same crop, zoom and perspective geometry as the recorded screen.
    private nonisolated static func applyingSpotlights(
        _ mosaics: [FrameMosaicScene],
        source: CIImage,
        screen: FrameScreenScene,
        to base: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        let spotlights = mosaics.filter {
            $0.style == .spotlight && $0.transitionProgress > 0.001
        }
        guard !spotlights.isEmpty else { return base }

        let normalizedSource = normalized(source)
        let sourceExtent = normalizedSource.extent
        let cropRect = sourceCropRect(
            sourceExtent: sourceExtent,
            crop: screen.sourceCrop
        )
        guard cropRect.width > 1, cropRect.height > 1 else { return base }

        let baseRect = coreImageRect(
            from: screen.baseRect,
            canvasHeight: canvasRect.height
        )
        let finalRect = coreImageRect(
            from: screen.finalRect,
            canvasHeight: canvasRect.height
        )
        guard baseRect.width > 0, baseRect.height > 0,
              finalRect.width > 0, finalRect.height > 0 else { return base }

        let fitScale = min(
            baseRect.width / cropRect.width,
            baseRect.height / cropRect.height
        )
        let zoomScale = finalRect.width / baseRect.width
        let finalScale = fitScale * zoomScale
        guard finalScale.isFinite, finalScale > 0 else { return base }
        let placedCropRect = CGRect(
            x: finalRect.midX - cropRect.width * finalScale / 2,
            y: finalRect.midY - cropRect.height * finalScale / 2,
            width: cropRect.width * finalScale,
            height: cropRect.height * finalScale
        )

        let visibleScreenMask: CIImage = switch screen.decoration {
        case .none:
            roundedMask(rect: finalRect, radius: screen.cornerRadius)
        case .chrome:
            CIImage(color: .white).cropped(to: finalRect)
        }
        let identityProjection = isIdentityProjection(screen)
        let projectionRect = coreImageRect(
            from: screen.projectionRect,
            canvasHeight: canvasRect.height
        )
        let mapping = identityProjection
            ? nil
            : projectionMapping(
                projectedQuad: screen.projectedQuad,
                canvasHeight: canvasRect.height
            )
        var focusMask = CIImage(color: .clear).cropped(to: canvasRect)
        var hasVisibleFocus = false

        for spotlight in spotlights {
            let normalizedRect = spotlight.sourceRect.clamped()
            let authoredRect = CGRect(
                x: sourceExtent.minX + sourceExtent.width * normalizedRect.x,
                y: sourceExtent.minY + sourceExtent.height
                    * (1 - normalizedRect.y - normalizedRect.height),
                width: sourceExtent.width * normalizedRect.width,
                height: sourceExtent.height * normalizedRect.height
            )
            let visibleRect = authoredRect.intersection(cropRect)
            guard !visibleRect.isNull,
                  visibleRect.width > 1,
                  visibleRect.height > 1 else { continue }

            let authoredRadius = min(authoredRect.width, authoredRect.height)
                * spotlight.cornerRadius
            let sourceMask = roundedMask(
                rect: authoredRect,
                radius: authoredRadius
            )
            let placedMask = sourceMask
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(
                    translationX: -cropRect.minX,
                    y: -cropRect.minY
                ))
                .transformed(by: CGAffineTransform(
                    scaleX: finalScale,
                    y: finalScale
                ))
                .transformed(by: CGAffineTransform(
                    translationX: placedCropRect.minX,
                    y: placedCropRect.minY
                ))
            let maskExtent = placedMask.extent.intersection(finalRect)
            guard !maskExtent.isNull,
                  maskExtent.width > 0,
                  maskExtent.height > 0 else { continue }
            let clippedMask = placedMask.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear)
                        .cropped(to: maskExtent),
                    kCIInputMaskImageKey: visibleScreenMask,
                ]
            ).cropped(to: maskExtent)
            let outputMask: CIImage
            if identityProjection {
                outputMask = clippedMask
            } else if let projected = perspectiveTransform(
                clippedMask,
                sourceRect: projectionRect,
                contentExtent: clippedMask.extent,
                mapping: mapping
            ) {
                outputMask = projected
            } else {
                continue
            }
            let progress = spotlight.transitionProgress
            let transitioningMask = outputMask.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: progress, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: progress, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: progress, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: progress),
                ]
            )
            focusMask = transitioningMask
                .composited(over: focusMask)
                .cropped(to: canvasRect)
            hasVisibleFocus = true
        }
        guard hasVisibleFocus else { return base }

        let styleScale = max(min(canvasRect.width, canvasRect.height), 1) / 1_080
        let blurRadius = spotlights.reduce(0.0) { radius, spotlight in
            max(
                radius,
                (4 + spotlight.intensity * 44)
                    * styleScale
                    * spotlight.transitionProgress
            )
        }
        let softenedBase = base.clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: blurRadius]
            )
            .cropped(to: canvasRect)
        let dimming = spotlights.map {
            $0.spotlightDimming * $0.transitionProgress
        }.max() ?? 0
        let softenedOutside: CIImage
        if dimming > 0.001 {
            softenedOutside = CIImage(
                color: CIColor(red: 0, green: 0, blue: 0, alpha: dimming)
            )
            .cropped(to: canvasRect)
            .composited(over: softenedBase)
            .cropped(to: canvasRect)
        } else {
            softenedOutside = softenedBase
        }
        return base.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: softenedOutside,
                kCIInputMaskImageKey: focusMask,
            ]
        ).cropped(to: canvasRect)
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
        let normalizedSource = SharedFrameOverlayRenderer.applyingMosaics(
            scene.mosaics,
            to: normalized(source)
        )
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

        // Picture rounding belongs to the plain-picture style. Once window or
        // browser chrome is selected, recorded pixels fill the opening and the
        // independent chrome silhouette clips the complete card exactly once.
        let finalMask: CIImage = switch scene.decoration {
        case .none:
            roundedMask(rect: finalRect, radius: scene.cornerRadius)
        case .chrome:
            CIImage(color: .white).cropped(to: finalRect)
        }
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
                .applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: transparent,
                        kCIInputMaskImageKey: projectionMask,
                    ]
                )
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

        let attachedCursor: SharedFrameCursorLayer? = if let cursorScene = attachedCursorScene,
                                             let cursorSource = attachedCursorSource {
            SharedFrameCursorRenderer.layer(
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
            // its 8×8 homography once, then reuse it for native pixels, chrome,
            // border and an attached cursor.
            let projectionMapping = projectionMapping(
                projectedQuad: scene.projectedQuad,
                canvasHeight: canvasRect.height
            )
            // Clip rounded corners in native source coordinates before the
            // single perspective pass. Projecting a second full-card mask
            // would add another perspective kernel in full-resolution preview.
            let nativeClippedSource: CIImage
            switch scene.decoration {
            case .none:
                let sourceCornerRadius = scene.cornerRadius
                    / max(finalScale, 0.000_1)
                let nativeMask = roundedMask(
                    rect: croppedSource.extent,
                    radius: sourceCornerRadius
                )
                let nativeTransparent = CIImage(color: .clear)
                    .cropped(to: croppedSource.extent)
                nativeClippedSource = croppedSource.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: nativeTransparent,
                        kCIInputMaskImageKey: nativeMask,
                    ]
                )
            case .chrome:
                nativeClippedSource = croppedSource
            }
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
                    if let projectedMask = perspectiveTransform(
                        projectionMask,
                        sourceRect: projectionRect,
                        contentExtent: projectionRect,
                        mapping: projectionMapping
                    ) {
                        projected = projected.applyingFilter(
                            "CIBlendWithMask",
                            parameters: [
                                kCIInputBackgroundImageKey: CIImage(color: .clear)
                                    .cropped(to: canvasRect),
                                kCIInputMaskImageKey: projectedMask,
                            ]
                        )
                    }
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
