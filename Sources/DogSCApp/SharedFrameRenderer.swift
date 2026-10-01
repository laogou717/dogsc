import AppKit
import CoreImage
import CoreText
import CoreImage.CIFilterBuiltins
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

/// Pattern tiles are immutable Core Image recipes shared by preview and export.
/// Only the affine phase changes during playback, so recreating a CGContext and
/// CGImage for every display tick would waste the preview frame budget.
private final class BackgroundPatternTileCache: @unchecked Sendable {
    private let storage: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    func image(for key: NSString, create: () -> CIImage?) -> CIImage? {
        if let cached = storage.object(forKey: key) { return cached }
        guard let created = create() else { return nil }
        let cost = max(Int(created.extent.width * created.extent.height * 4), 1)
        storage.setObject(created, forKey: key, cost: cost)
        return created
    }
}

private final class ScreenChromeTextCache: @unchecked Sendable {
    private let storage: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    func image(for key: NSString, create: () -> CIImage?) -> CIImage? {
        if let cached = storage.object(forKey: key) { return cached }
        guard let created = create() else { return nil }
        storage.setObject(
            created,
            forKey: key,
            cost: max(Int(created.extent.width * created.extent.height * 4), 1)
        )
        return created
    }
}

/// The single Core Image lowering of a backend-neutral `FrameScene`.
///
/// A screen-attached cursor is composited into the decorated screen layer
/// before that layer is projected. Preview and export therefore share one
/// perspective implementation, while the camera remains an independent top
/// layer. An axis-aligned quad takes the original 2D path byte-for-byte.
enum SharedFrameRenderer {
    private static let backgroundPatternTileCache = BackgroundPatternTileCache()
    private static let screenChromeTextCache = ScreenChromeTextCache()

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
                wallpaperSource: resources.wallpaper,
                time: scene.time
            )

        let hasAttachedCursor = scene.layerOrder.contains(.cursor)
            && scene.cursor?.attachment == .screen
            && resources.cursor != nil
        let projectsScreen = !isIdentityProjection(scene.screen)
        let screenSuppression = scene.stickerBackdrop.screenSuppression
        let cameraSuppression = scene.stickerBackdrop.cameraSuppression
        let screenVisibility = (1 - min(max(screenSuppression, 0), 1))
            * scene.screen.opacity
        let cameraVisibility = 1 - min(max(cameraSuppression, 0), 1)

        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        var compositeBeforeCamera: CIImage?
        var visibleCameraLayer: CIImage?
        for role in scene.layerOrder where role != .background {
            switch role {
            case .background:
                break
            case .screen:
                guard screenVisibility > 0.001 else { continue }
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
                result = applyingOpacity(
                    renderedScreen,
                    screenVisibility
                ).composited(over: result).cropped(to: canvasRect)
            case .cursor:
                // A projected screen owns its cursor so both are lowered by
                // the same homography. The identity fast path deliberately
                // retains the former separate cursor composition.
                if projectsScreen && hasAttachedCursor { continue }
                guard screenVisibility > 0.001 else { continue }
                guard let cursorScene = scene.cursor,
                      let cursorImage = resources.cursor else { continue }
                let cursorLayer = SharedFrameCursorRenderer.render(
                    source: cursorImage,
                    scene: cursorScene,
                    over: transparent,
                    canvasRect: canvasRect
                )
                result = applyingOpacity(
                    cursorLayer,
                    screenVisibility
                ).composited(over: result).cropped(to: canvasRect)
            case .spotlight:
                guard screenVisibility > 0.001 else { continue }
                result = applyingFocusEffect(
                    scene.screen.focusEffect, source: resources.screen,
                    screen: scene.screen, to: result, canvasRect: canvasRect
                )
                result = applyingSpotlights(
                    scene.screen.mosaics,
                    source: resources.screen,
                    screen: scene.screen,
                    to: result,
                    canvasRect: canvasRect
                )
            case .camera:
                compositeBeforeCamera = result
                visibleCameraLayer = nil
                guard cameraVisibility > 0.001 else { continue }
                guard let cameraScene = scene.camera,
                      cameraScene.opacity > 0,
                      let cameraImage = resources.camera else { continue }
                let cameraLayer = renderCamera(
                    source: cameraImage,
                    scene: cameraScene,
                    over: transparent,
                    canvasRect: canvasRect
                )
                visibleCameraLayer = applyingOpacity(
                    cameraLayer,
                    cameraVisibility
                )
                result = visibleCameraLayer!
                    .composited(over: result)
                    .cropped(to: canvasRect)
            case .stickers:
                guard !scene.stickers.isEmpty else { continue }
                // A sticker normally softens the canvas/screen composite but
                // leaves the independently-authored camera crisp. Only clips
                // that explicitly opt in soften the camera layer. Rebuild the
                // two layers here instead of blurring the already-flattened
                // result, which made that distinction impossible.
                // "Hide screen" means the authored canvas background is the
                // actual backdrop. Do not blur that background again with a
                // sticker's screen-blur control. If another sticker requests
                // blur at the same time, ease that blur away with the same
                // suppression phase instead of switching it abruptly.
                let requestedScreenBlur = scene.stickerBackdrop.screenBlur
                let baseBlur = requestedScreenBlur
                    * (1 - min(max(screenSuppression, 0), 1))
                let cameraBlur = scene.stickerBackdrop.cameraBlur
                var stickerBackdrop = compositeBeforeCamera ?? result
                if baseBlur > 0.01 {
                    stickerBackdrop = stickerBackdrop.clampedToExtent()
                        .applyingFilter(
                            "CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: baseBlur]
                        )
                        .cropped(to: canvasRect)
                }
                if var cameraLayer = visibleCameraLayer {
                    if cameraBlur > 0.01 {
                        cameraLayer = cameraLayer.clampedToExtent()
                            .applyingFilter(
                                "CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: cameraBlur]
                            )
                            .cropped(to: canvasRect)
                    }
                    stickerBackdrop = cameraLayer
                        .composited(over: stickerBackdrop)
                        .cropped(to: canvasRect)
                }
                result = stickerBackdrop
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
            }
        }
        return result.cropped(to: canvasRect)
    }

    private nonisolated static func applyingOpacity(
        _ image: CIImage,
        _ opacity: Double
    ) -> CIImage {
        let alpha = min(max(opacity, 0), 1)
        guard alpha < 0.999 else { return image }
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ]
        )
    }

    /// Spotlight is a single dimming layer over the complete base composite.
    /// At this point the wallpaper, recorded pixels, screen chrome, border,
    /// shadow and cursor already form one image; camera, stickers and progress
    /// have not yet been drawn. The authored source rectangle stays untouched
    /// while everything outside it is darkened through the same crop, zoom and
    /// perspective geometry as the recorded screen.
    private nonisolated static func applyingFocusEffect(
        _ focus: FrameFocusScene?, source: CIImage, screen: FrameScreenScene,
        to base: CIImage, canvasRect: CGRect
    ) -> CIImage {
        guard let focus, focus.progress > 0.001 else { return base }
        let sourceExtent = normalized(source).extent
        let crop = sourceCropRect(sourceExtent: sourceExtent, crop: screen.sourceCrop)
        let finalRect = coreImageRect(from: screen.finalRect, canvasHeight: canvasRect.height)
        let baseRect = coreImageRect(from: screen.baseRect, canvasHeight: canvasRect.height)
        guard crop.width > 1, crop.height > 1, baseRect.width > 0 else { return base }
        let sourcePoint = CGPoint(x: focus.center.x * sourceExtent.width,
                                  y: (1 - focus.center.y) * sourceExtent.height)
        guard crop.contains(sourcePoint) else { return base }
        let scale = min(baseRect.width / crop.width, baseRect.height / crop.height)
            * finalRect.width / baseRect.width
        let placed = CGRect(x: finalRect.midX - crop.width * scale / 2,
                            y: finalRect.midY - crop.height * scale / 2,
                            width: crop.width * scale, height: crop.height * scale)
        let point = CGPoint(x: placed.minX + (sourcePoint.x - crop.minX) * scale,
                            y: placed.minY + (sourcePoint.y - crop.minY) * scale)
        let radius = focus.effect.clearHalfWidth(shortEdge: min(placed.width, placed.height))
        let projectionRect = coreImageRect(from: screen.projectionRect, canvasHeight: canvasRect.height)
        let sourceMask: CIImage?
        if focus.effect.shape == .linear {
            let angle = (focus.effect.angleDegrees ?? 0) * .pi / 180
            // Angle follows the source image's top-left coordinates.
            let normal = CGPoint(x: -sin(angle), y: -cos(angle))
            let feather = focus.effect.featherWidth(shortEdge: min(placed.width, placed.height))
            func halfPlane(_ sign: CGFloat) -> CIImage? {
                CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: point.x + normal.x * radius * sign,
                                            y: point.y + normal.y * radius * sign),
                    "inputPoint1": CIVector(x: point.x + normal.x * (radius + feather) * sign,
                                            y: point.y + normal.y * (radius + feather) * sign),
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black,
                ])?.outputImage
            }
            if let positive = halfPlane(1), let negative = halfPlane(-1) {
                sourceMask = positive.applyingFilter("CIMinimumCompositing",
                    parameters: [kCIInputBackgroundImageKey: negative])
            } else { sourceMask = nil }
        } else {
            sourceMask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: point),
                "inputRadius0": radius,
                "inputRadius1": radius + max(radius * focus.effect.softness * 1.5, 0.5),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])?.outputImage
        }
        guard let sourceMask else { return base }
        let mask: CIImage
        if isIdentityProjection(screen) {
            mask = sourceMask.cropped(to: canvasRect)
        } else {
            let mapping = projectionMapping(projectedQuad: screen.projectedQuad,
                                            canvasHeight: canvasRect.height)
            guard let projected = perspectiveTransform(
                sourceMask.cropped(to: projectionRect), sourceRect: projectionRect,
                contentExtent: projectionRect, mapping: mapping
            ) else { return base }
            mask = projected.composited(over: CIImage(color: .black).cropped(to: canvasRect))
        }
        let amount = focus.progress
        let blurRadius = focus.effect.blur * 28 * min(canvasRect.width, canvasRect.height) / 1080
        var outside = base
        if blurRadius > 0.01 {
            // Only the intentionally defocused branch uses a bounded working
            // raster. The clear region still samples the original full image.
            let blurScale = min(1, 1600 / max(canvasRect.width, canvasRect.height))
            let working = base.transformed(by: CGAffineTransform(scaleX: blurScale, y: blurScale))
            // Feather is coverage: original pixels inside the solid lines,
            // one linear transition to the fixed defocused image at the dashed
            // lines. Applying the same ramp to both radius and coverage made
            // the former effect quadratic and disconnected from its guides.
            outside = working.clampedToExtent().applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: blurRadius * blurScale])
            outside = outside.transformed(by: CGAffineTransform(scaleX: 1 / blurScale, y: 1 / blurScale))
                .cropped(to: canvasRect)
        }
        if focus.effect.dimming > 0 {
            outside = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: focus.effect.dimming))
                .cropped(to: canvasRect).composited(over: outside)
        }
        let focused = base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: outside,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: canvasRect)
        return applyingOpacity(focused, amount).composited(over: base).cropped(to: canvasRect)
    }

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
        case let .chrome(chrome):
            chrome.contentCornerRadius > 0
                ? roundedMask(rect: finalRect, radius: chrome.contentCornerRadius)
                : CIImage(color: .white).cropped(to: finalRect)
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
            // The focus itself is always the untouched base image. Transition
            // timing only fades the outside dimming opacity; it must never
            // darken or soften the area the user explicitly selected.
            focusMask = outputMask
                .composited(over: focusMask)
                .cropped(to: canvasRect)
            hasVisibleFocus = true
        }
        guard hasVisibleFocus else { return base }

        let dimming = spotlights.map {
            $0.spotlightDimming * $0.transitionProgress
        }.max() ?? 0
        guard dimming > 0.001 else { return base }
        let dimmedOutside = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: dimming)
        )
        .cropped(to: canvasRect)
        .composited(over: base)
        .cropped(to: canvasRect)
        return base.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: dimmedOutside,
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

        let projectionRect = coreImageRect(
            from: scene.projectionRect,
            canvasHeight: canvasRect.height
        )
        let projectionCornerRadius: Double = switch scene.decoration {
        case .none: scene.cornerRadius
        case let .chrome(chrome): chrome.outerCornerRadius
        }

        // The native 3D path below owns its own card/masks. Do not eagerly
        // rasterize zoomed output-space masks and chrome just to discard them.
        // These frame-local helpers preserve the exact 2D/fallback geometry,
        // but allocate only the surfaces actually consumed by that path.
        var cachedContentMask: CIImage?
        func contentMask() -> CIImage {
            if let cachedContentMask { return cachedContentMask }
            let mask: CIImage = switch scene.decoration {
            case .none:
                roundedMask(rect: finalRect, radius: scene.cornerRadius)
            case let .chrome(chrome):
                chrome.contentCornerRadius > 0
                    ? roundedMask(rect: finalRect, radius: chrome.contentCornerRadius)
                    : CIImage(color: .white).cropped(to: finalRect)
            }
            cachedContentMask = mask
            return mask
        }

        var cachedProjectionMask: CIImage?
        func projectionMask() -> CIImage {
            if let cachedProjectionMask { return cachedProjectionMask }
            let mask: CIImage = switch scene.decoration {
            case .none: contentMask()
            case let .chrome(chrome):
                roundedMask(rect: projectionRect, radius: chrome.outerCornerRadius)
            }
            cachedProjectionMask = mask
            return mask
        }

        var cachedChromeLayer: CIImage?
        func chromeLayer() -> CIImage? {
            if let cachedChromeLayer { return cachedChromeLayer }
            guard case let .chrome(chrome) = scene.decoration else { return nil }
            let layer = screenChromeLayer(
                chrome, canvasRect: canvasRect, renderExtent: projectionRect
            )
            cachedChromeLayer = layer
            return layer
        }

        var cachedBorderLayer: CIImage?
        func borderLayer() -> CIImage? {
            if let cachedBorderLayer { return cachedBorderLayer }
            guard scene.borderWidth > 0 else { return nil }
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
            cachedBorderLayer = border
            return border
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
        func decoratedLayer() -> CIImage {
            let mask = contentMask()
            // Transparent canvas-sized backings made a moving 2D card carry
            // the complete output raster into every later blend and shadow.
            // Keep the same output-space mask and source sampling, but discard
            // only pixels that are already clear outside their intersection.
            let contentExtent = transformed.extent.intersection(mask.extent)
            var layer = transformed.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear)
                        .cropped(to: contentExtent),
                    kCIInputMaskImageKey: mask,
                ]
            ).cropped(to: contentExtent)
            if let chrome = chromeLayer() {
                let outerMask = projectionMask()
                let cardExtent = layer.extent.union(chrome.extent)
                    .intersection(outerMask.extent)
                layer = layer.composited(over: chrome).applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear)
                            .cropped(to: cardExtent),
                        kCIInputMaskImageKey: outerMask,
                    ]
                ).cropped(to: cardExtent)
            }
            // Preserve the existing outside border behind the clipped card.
            if let border = borderLayer() { layer = layer.composited(over: border) }
            if let cursor = attachedCursor { layer = cursor.image.composited(over: layer) }
            return layer
        }

        let identityProjection = isIdentityProjection(scene)
        let projectedLayer: CIImage
        if identityProjection {
            // Do not send ordinary 2D frames through a perspective filter:
            // this preserves the previous sampling, border and antialiasing.
            projectedLayer = decoratedLayer()
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
            if case .chrome = scene.decoration,
               let unifiedCard = unifiedDecoratedPerspectiveTransform(
                   nativeSource: nativeClippedSource,
                   finalRect: finalRect,
                   projectionRect: projectionRect,
                   chromeScene: scene.decoration,
                   projectionCornerRadius: projectionCornerRadius,
                   borderWidth: scene.borderWidth,
                   borderColor: scene.borderColor,
                   borderOpacity: scene.borderOpacity,
                   attachedCursor: attachedCursor,
                   mapping: projectionMapping,
                   canvasRect: canvasRect
               ) {
                // Window/device chrome is structural, not an overlay. Lower it,
                // the recorded pixels, border and attached cursor into one
                // native-resolution card, then run exactly one perspective
                // transform. Separate perspective passes share coordinates but
                // can still produce antialiased seams along a tilted edge.
                projectedLayer = unifiedCard
            } else if let directSource = directPerspectiveTransform(
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
                if let chromeLayer = chromeLayer(),
                   let projectedChrome = perspectiveTransform(
                       chromeLayer,
                       sourceRect: projectionRect,
                       contentExtent: projectionRect,
                       mapping: projectionMapping
                ) {
                    projected = projected.composited(over: projectedChrome)
                    if let projectedMask = perspectiveTransform(
                        projectionMask(),
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
                if let borderLayer = borderLayer(),
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
                projectedLayer = decoratedLayer()
            }
        }

        var screenLayer = projectedLayer
        if let shadow = scene.shadow, shadow.opacity > 0 {
            let shadowMask: CIImage
            if identityProjection {
                // This is exactly the former 2D shadow source. The projected
                // path below instead derives its shadow from post-warp alpha.
                shadowMask = projectionMask()
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
            let shadowLayer = coloredLayer(
                color: CIColor(shadow.color, alpha: shadow.opacity),
                mask: translatedShadow,
                canvasRect: canvasRect
            )
            screenLayer = projectedLayer.composited(over: shadowLayer)
        }
        // Do not expand a small opening card back into a transparent 5K
        // image before the caller applies its entrance opacity. Projection,
        // attached decoration and the complete Gaussian support are retained
        // until this final, existing canvas boundary.
        let visibleExtent = screenLayer.extent.intersection(canvasRect)
        guard !visibleExtent.isEmpty, !visibleExtent.isNull else {
            return CIImage(color: .clear).cropped(to: .zero)
        }
        return screenLayer
            .composited(over: background.cropped(to: visibleExtent))
            .cropped(to: visibleExtent)
    }

    /// Draws original vector chrome with no bundled third-party artwork. The
    /// result is clipped once to the evaluated outer shape, then travels with
    /// the screen through the same homography as content, border and cursor.
    private nonisolated static func screenChromeLayer(
        _ chrome: FrameScreenChromeScene,
        canvasRect: CGRect,
        renderExtent: CGRect,
        coordinateTransform: CGAffineTransform = .identity
    ) -> CIImage {
        // `outerRect` is allowed to extend outside the output canvas before a
        // 3D projection. Cropping vector chrome to `canvasRect` here amputates
        // those off-canvas source pixels before the tilt can move them back
        // into view, leaving the background visible through the card. Generate
        // the complete authored card first; only the final composite is clipped
        // to the output canvas.
        let layerExtent = renderExtent.standardized
        let transformScaleX = hypot(
            coordinateTransform.a,
            coordinateTransform.b
        )
        let transformScaleY = hypot(
            coordinateTransform.c,
            coordinateTransform.d
        )
        let radiusScale = max(min(transformScaleX, transformScaleY), 0.000_1)
        let transparent = CIImage(color: .clear).cropped(to: layerExtent)
        let outerRect = coreImageRect(
            from: chrome.outerRect,
            canvasHeight: canvasRect.height
        ).applying(coordinateTransform).standardized
        let toolbarRect = coreImageRect(
            from: chrome.toolbarRect,
            canvasHeight: canvasRect.height
        ).applying(coordinateTransform).standardized
        let outerCornerRadius = chrome.outerCornerRadius * radiusScale
        let outerMask = roundedMask(
            rect: outerRect,
            radius: outerCornerRadius
        )
        let surface = coloredLayer(
            color: CIColor(chrome.surfaceColor),
            mask: outerMask,
            canvasRect: layerExtent
        )
        if chrome.kind.isDevice {
            // A restrained, original graphite chassis: continuous metal rim,
            // uniform bezel and no sensor notch drawn over recorded pixels.
            let metal = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: outerRect.minX, y: outerRect.maxY),
                "inputPoint1": CIVector(x: outerRect.maxX, y: outerRect.minY),
                "inputColor0": CIColor(red: 0.52, green: 0.54, blue: 0.56),
                "inputColor1": CIColor(red: 0.17, green: 0.18, blue: 0.20),
            ])?.outputImage?.cropped(to: layerExtent) ?? surface
            let rim = max(min(outerRect.width, outerRect.height) * 0.006, 0.8)
            let innerRect = outerRect.insetBy(dx: rim, dy: rim)
            let innerMask = roundedMask(rect: innerRect, radius: max(outerCornerRadius - rim, 0))
            var deviceLayer = coloredLayer(color: CIColor(red: 0.055, green: 0.06, blue: 0.065),
                mask: innerMask, canvasRect: layerExtent).composited(over: metal)
            let highlightWidth = max(min(outerRect.width, outerRect.height) * 0.006, 0.8)
            let highlightRect = outerRect.insetBy(dx: highlightWidth * 0.7, dy: highlightWidth * 0.7)
            deviceLayer = coloredLayer(
                color: CIColor(chrome.separatorColor, alpha: 0.42),
                mask: ringMask(
                    outer: roundedMask(rect: outerRect, radius: outerCornerRadius),
                    inner: roundedMask(
                        rect: highlightRect,
                        radius: max(outerCornerRadius - highlightWidth, 0)
                    ),
                    canvasRect: layerExtent
                ),
                canvasRect: layerExtent
            ).composited(over: deviceLayer)
            return deviceLayer.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: outerMask,
                ]
            )
        }
        let toolbarMask = CIImage(color: .white)
            .cropped(to: toolbarRect)
        let toolbar = coloredLayer(
            color: CIColor(chrome.toolbarColor),
            mask: toolbarMask,
            canvasRect: layerExtent
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
                canvasRect: layerExtent
            )
            layer = control.composited(over: layer)
        }

        let controlsEnd = toolbarRect.minX + controlMargin
            + controlSpacing * 2 + controlDiameter
        switch chrome.kind {
        case .window:
            let title = chrome.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let textLayer = screenChromeTextLayer(
                text: title,
                color: chrome.glyphColor,
                fontSize: max(toolbarRect.height * 0.30, 5),
                weight: .medium,
                maximumWidth: max(toolbarRect.width * 0.46, 2),
                center: CGPoint(x: toolbarRect.midX, y: toolbarRect.midY),
                clipRect: toolbarRect
            ) {
                layer = textLayer.composited(over: layer)
            } else {
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
                    canvasRect: layerExtent
                ).composited(over: layer)
            }
        case .browser:
            let fieldMargin = max(toolbarRect.height * 0.28, 2)
            let availableMinX = controlsEnd + fieldMargin
            let availableMaxX = toolbarRect.maxX - fieldMargin
            let availableWidth = max(availableMaxX - availableMinX, 2)
            let fieldHeight = max(toolbarRect.height * 0.44, 2)
            let address = chrome.browserAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let fontSize = max(fieldHeight * 0.38, 5)
            let textWidth = screenChromeTextImage(text: address, color: chrome.glyphColor,
                fontSize: fontSize, weight: .regular)?.extent.width ?? 0
            // Balanced room for the small leading glyph and a matching right
            // inset. Short labels stay compact; long ones respect the controls.
            let fieldWidth = min(max(textWidth + fieldHeight * 1.7, fieldHeight * 3), availableWidth)
            let fieldCenterX = min(max(toolbarRect.midX, availableMinX + fieldWidth / 2),
                                   availableMaxX - fieldWidth / 2)
            let fieldRect = CGRect(
                x: fieldCenterX - fieldWidth / 2,
                y: toolbarRect.midY - fieldHeight / 2,
                width: fieldWidth,
                height: fieldHeight
            )
            layer = coloredLayer(
                color: CIColor(chrome.fieldColor),
                mask: roundedMask(rect: fieldRect, radius: fieldHeight / 2),
                canvasRect: layerExtent
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
                canvasRect: layerExtent
            ).composited(over: layer)
            if let textLayer = screenChromeTextLayer(
                text: address,
                color: chrome.glyphColor,
                fontSize: fontSize,
                weight: .regular,
                maximumWidth: max(fieldRect.width - fieldHeight * 1.35, 2),
                center: CGPoint(x: fieldRect.midX, y: fieldRect.midY),
                clipRect: fieldRect
            ) {
                layer = textLayer.composited(over: layer)
            }
        case .devicePhonePortrait, .devicePhoneLandscape,
             .deviceTabletPortrait, .deviceTabletLandscape:
            break
        }

        return layer.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: outerMask,
            ]
        )
    }

    private nonisolated static func screenChromeTextLayer(
        text: String,
        color: HexColor,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        maximumWidth: CGFloat,
        center: CGPoint,
        clipRect: CGRect,
        alignsLeading: Bool = false
    ) -> CIImage? {
        guard !text.isEmpty, fontSize > 0, maximumWidth > 2 else { return nil }
        guard let image = screenChromeTextImage(text: text, color: color, fontSize: fontSize, weight: weight)
        else { return nil }
        let scale = min(maximumWidth / image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetX = alignsLeading
            ? center.x - maximumWidth / 2
            : center.x - scaled.extent.width / 2
        return scaled
            .transformed(by: CGAffineTransform(
                translationX: targetX - scaled.extent.minX,
                y: center.y - scaled.extent.height / 2 - scaled.extent.minY
            ))
            .cropped(to: clipRect)
    }

    /// Immutable CPU-backed glyph raster: independent of the preview CIContext
    /// lifetime and reusable by both the browser measurement and export graph.
    private nonisolated static func screenChromeTextImage(
        text: String, color: HexColor, fontSize: CGFloat, weight: NSFont.Weight
    ) -> CIImage? {
        guard !text.isEmpty, fontSize > 0 else { return nil }
        let components = color.components
        let key = String(format: "%@|%.2f|%.3f|%.3f|%.3f|%.2f", text,
            Double(fontSize), components.red, components.green, components.blue,
            Double(weight.rawValue)) as NSString
        return screenChromeTextCache.image(for: key) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    red: components.red, green: components.green, blue: components.blue, alpha: 0.86)
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let bounds = glyphs.union(CGRect(x: 0, y: -descent, width: width, height: ascent + descent)).integral
            guard bounds.width > 0, bounds.height > 0, bounds.width < 32768,
                  let context = CGContext(data: nil, width: Int(bounds.width) + 2,
                    height: Int(bounds.height) + 2, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.textPosition = CGPoint(x: 1 - bounds.minX, y: 1 - bounds.minY)
            CTLineDraw(line, context)
            guard let image = context.makeImage() else { return nil }
            return CIImage(cgImage: image)
        }
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
        let transparent = CIImage(color: .clear).cropped(to: contentRect)
        let cameraMask = roundedMask(rect: contentRect, radius: scene.cornerRadius)
        let borderOuterRect = contentRect.insetBy(
            dx: -scene.borderWidth,
            dy: -scene.borderWidth
        )
        let borderOuterMask = scene.borderWidth > 0
            ? roundedMask(
                rect: borderOuterRect,
                radius: scene.cornerRadius + scene.borderWidth
            )
            : cameraMask
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
                    canvasRect: borderOuterRect
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
        ).cropped(to: contentRect)
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

    /// Builds screen pixels and authored chrome in the decoded screen's native
    /// coordinate density before a single perspective pass. This avoids both
    /// the seam caused by separately warped layers and the quality loss of
    /// first rasterizing a zoomed screen into the output-canvas resolution.
    private nonisolated static func unifiedDecoratedPerspectiveTransform(
        nativeSource: CIImage,
        finalRect: CGRect,
        projectionRect: CGRect,
        chromeScene decoration: FrameScreenDecoration,
        projectionCornerRadius: Double,
        borderWidth: Double,
        borderColor: HexColor,
        borderOpacity: Double,
        attachedCursor: SharedFrameCursorLayer?,
        mapping: UnitSquareHomography?,
        canvasRect: CGRect
    ) -> CIImage? {
        let sourceExtent = nativeSource.extent
        guard sourceExtent.width > 0,
              sourceExtent.height > 0,
              finalRect.width > 0,
              finalRect.height > 0,
              projectionRect.width > 0,
              projectionRect.height > 0,
              let mapping else { return nil }

        let scaleX = sourceExtent.width / finalRect.width
        let scaleY = sourceExtent.height / finalRect.height
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX > 0,
              scaleY > 0 else { return nil }

        // Core Image coordinates are bottom-left based here. Map the final
        // content rectangle exactly onto the decoded crop without an
        // intermediate resize; vector chrome follows the same change of basis.
        let canvasToNative = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: sourceExtent.minX - finalRect.minX * scaleX,
            ty: sourceExtent.minY - finalRect.minY * scaleY
        )
        let nativeProjectionRect = projectionRect
            .applying(canvasToNative)
            .standardized
        guard nativeProjectionRect.width > 0,
              nativeProjectionRect.height > 0 else { return nil }

        guard case let .chrome(chrome) = decoration else { return nil }
        // Generate the complete chrome directly in the decoded screen's native
        // coordinate space. Building it first in the zoomed canvas coordinate
        // space made a 4× target allocate a roughly 16× larger intermediate
        // during every position/tilt drag, only to shrink that layer back here.
        // Native card dimensions are independent of target scale; dragging now
        // changes only the final homography.
        let nativeChrome = screenChromeLayer(
            chrome,
            canvasRect: canvasRect,
            renderExtent: nativeProjectionRect,
            coordinateTransform: canvasToNative
        )
        let nativeScaleX = hypot(canvasToNative.a, canvasToNative.b)
        let nativeScaleY = hypot(canvasToNative.c, canvasToNative.d)
        let nativeRadiusScale = max(min(nativeScaleX, nativeScaleY), 0.000_1)
        let nativeMask = roundedMask(
            rect: nativeProjectionRect,
            radius: projectionCornerRadius * nativeRadiusScale
        )
        let nativeTransparent = CIImage(color: .clear)
            .cropped(to: nativeProjectionRect)
        var card = nativeSource
            .composited(over: nativeChrome)
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: nativeTransparent,
                    kCIInputMaskImageKey: nativeMask,
                ]
            )
            .cropped(to: nativeProjectionRect)
        var footprint = nativeProjectionRect

        let nativeBorderWidth = borderWidth * nativeRadiusScale
        if nativeBorderWidth > 0 {
            let nativeBorderRect = nativeProjectionRect.insetBy(
                dx: -nativeBorderWidth,
                dy: -nativeBorderWidth
            )
            let nativeBorderMask = roundedMask(
                rect: nativeBorderRect,
                radius: projectionCornerRadius * nativeRadiusScale
                    + nativeBorderWidth
            )
            let nativeBorder = coloredLayer(
                color: CIColor(borderColor, alpha: borderOpacity),
                mask: nativeBorderMask,
                canvasRect: nativeBorderRect
            )
            card = card.composited(over: nativeBorder)
            footprint = footprint.union(nativeBorderRect)
        }

        if let attachedCursor {
            let cursorRect = attachedCursor.footprint
            let nativeCursorRect = cursorRect
                .applying(canvasToNative)
                .standardized
            if nativeCursorRect.width > 0, nativeCursorRect.height > 0 {
                let nativeCursor = attachedCursor.image
                    .cropped(to: cursorRect)
                    .transformed(by: canvasToNative)
                    .cropped(to: nativeCursorRect)
                card = nativeCursor.composited(over: card)
                footprint = footprint.union(nativeCursorRect)
            }
        }

        guard footprint.width > 0, footprint.height > 0 else { return nil }
        return perspectiveTransform(
            card,
            sourceRect: nativeProjectionRect,
            contentExtent: footprint,
            mapping: mapping
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

    private nonisolated static func patternImage(
        preset: BackgroundPatternPreset,
        canvasRect: CGRect,
        scale patternScale: Double = 1.0,
        opacity patternOpacity: Double = 1.0
    ) -> CIImage {
        tiledPatternImage(
            preset: preset,
            canvasRect: canvasRect,
            scale: patternScale,
            opacity: patternOpacity,
            translation: .zero
        )
    }

    /// A pattern's authored size is relative to the canvas short edge. At 1x
    /// the pattern intentionally matches the former 0.5x density, leaving a
    /// useful smaller range below the default without changing preview/export
    /// density.
    private nonisolated static func patternTileSize(
        preset: BackgroundPatternPreset,
        canvasRect: CGRect,
        scale patternScale: Double
    ) -> CGFloat {
        let shortEdge = max(min(canvasRect.width, canvasRect.height), 2)
        let baseFraction: CGFloat = switch preset {
        case .obsidianGrid: 0.0425
        case .engineeringWhiteGrid: 0.040
        case .midnightDots: 0.032
        case .architecturalDots: 0.030
        case .isometricMesh: 0.050
        }
        return max(shortEdge * baseFraction * CGFloat(patternScale), 9)
    }

    private nonisolated static func tiledPatternImage(
        preset: BackgroundPatternPreset,
        canvasRect: CGRect,
        scale patternScale: Double,
        opacity patternOpacity: Double,
        translation: CGPoint
    ) -> CIImage {
        let palette = patternPalette(for: preset)
        let background = CIImage(
            color: CIColor(cgColor: palette.background.cgColor)
        ).cropped(to: canvasRect)
        let requestedSize = patternTileSize(
            preset: preset,
            canvasRect: canvasRect,
            scale: patternScale
        )
        let tileSize = (requestedSize * 2).rounded() / 2
        let opacity = (min(max(patternOpacity, 0), 1) * 100).rounded() / 100
        guard opacity > 0 else { return background }
        let key = "\(preset.rawValue)|\(tileSize)|\(opacity)" as NSString
        guard let tile = backgroundPatternTileCache.image(for: key, create: {
            makePatternTile(preset: preset, tileSize: tileSize, opacity: opacity)
        }) else {
            return background
        }
        // Only the transparent line/dot overlay is tiled. Tiling an opaque
        // white tile lets Core Image sample the tile boundary during scaling,
        // which creates false grid seams in dot-only presets and leaves those
        // seams visible even when pattern opacity is reduced.
        let overlay = tile.applyingFilter(
            "CIAffineTile",
            parameters: [
                kCIInputTransformKey: CGAffineTransform(
                    translationX: translation.x,
                    y: translation.y
                ),
            ]
        ).cropped(to: canvasRect)
        return overlay.composited(over: background)
    }

    private nonisolated static func patternPalette(
        for preset: BackgroundPatternPreset
    ) -> (background: NSColor, stroke: NSColor?, dot: NSColor?) {
        switch preset {
        case .obsidianGrid:
            return (
                NSColor(white: 0.060, alpha: 1),
                NSColor(white: 0.24, alpha: 1),
                nil
            )
        case .engineeringWhiteGrid:
            return (
                NSColor(white: 0.970, alpha: 1),
                NSColor(white: 0.79, alpha: 1),
                nil
            )
        case .midnightDots:
            return (
                NSColor(white: 0.065, alpha: 1),
                nil,
                NSColor(red: 0.76, green: 0.68, blue: 0.54, alpha: 0.90)
            )
        case .architecturalDots:
            return (
                NSColor(white: 0.975, alpha: 1),
                nil,
                NSColor(white: 0.58, alpha: 0.75)
            )
        case .isometricMesh:
            return (
                NSColor(white: 0.075, alpha: 1),
                NSColor(red: 0.31, green: 0.29, blue: 0.26, alpha: 1),
                nil
            )
        }
    }

    private nonisolated static func makePatternTile(
        preset: BackgroundPatternPreset,
        tileSize: CGFloat,
        opacity: Double
    ) -> CIImage? {
        let palette = patternPalette(for: preset)

        let renderScale: CGFloat = 2
        let pixelTileSize = max(Int(ceil(tileSize * renderScale)), 2)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelTileSize,
            height: pixelTileSize,
            bitsPerComponent: 8,
            bytesPerRow: pixelTileSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: renderScale, y: renderScale)
        context.clear(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))

        let lineWidth = max(tileSize * 0.008, 0.75)
        if let strokeColor = palette.stroke {
            context.setStrokeColor(
                strokeColor.withAlphaComponent(
                    strokeColor.alphaComponent * CGFloat(opacity)
                ).cgColor
            )
            context.setLineWidth(lineWidth)
            if preset == .isometricMesh {
                context.move(to: CGPoint(x: 0, y: 0))
                context.addLine(to: CGPoint(x: tileSize, y: tileSize))
                context.move(to: CGPoint(x: 0, y: tileSize))
                context.addLine(to: CGPoint(x: tileSize, y: 0))
                context.strokePath()
            } else {
                let inset = lineWidth / 2
                context.stroke(CGRect(
                    x: inset,
                    y: inset,
                    width: max(tileSize - lineWidth, 1),
                    height: max(tileSize - lineWidth, 1)
                ))
            }
        }

        if let dotColor = palette.dot {
            context.setFillColor(
                dotColor.withAlphaComponent(
                    dotColor.alphaComponent * CGFloat(opacity)
                ).cgColor
            )
            let fraction: CGFloat = preset == .midnightDots
                || preset == .architecturalDots ? 0.026 : 0.014
            let radius = max(tileSize * fraction, 0.8)
            context.fillEllipse(in: CGRect(
                x: tileSize / 2 - radius,
                y: tileSize / 2 - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage).transformed(
            by: CGAffineTransform(scaleX: 1 / renderScale, y: 1 / renderScale)
        )
    }

    private nonisolated static func dynamicFlowImage(
        preset: DynamicBackgroundPreset,
        canvasRect: CGRect,
        scale patternScale: Double = 1.0,
        opacity patternOpacity: Double = 1.0,
        time: Double
    ) -> CIImage {
        switch preset {
        case .cyberDriftGrid:
            let tileSize = patternTileSize(
                preset: .obsidianGrid,
                canvasRect: canvasRect,
                scale: patternScale
            )
            let movedGrid = tiledPatternImage(
                preset: .obsidianGrid,
                canvasRect: canvasRect,
                scale: patternScale,
                opacity: patternOpacity,
                translation: CGPoint(
                    x: (time * tileSize * 0.10).truncatingRemainder(dividingBy: tileSize),
                    y: (time * tileSize * 0.065).truncatingRemainder(dividingBy: tileSize)
                )
            )
            let glowAlpha = 0.85 * CGFloat(patternOpacity)
            let glow = CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": CIVector(
                        x: canvasRect.midX + sin(time * 0.4) * canvasRect.width * 0.08,
                        y: canvasRect.midY + cos(time * 0.4) * canvasRect.height * 0.08
                    ),
                    "inputRadius0": max(canvasRect.width, canvasRect.height) * 0.05,
                    "inputRadius1": max(canvasRect.width, canvasRect.height) * 0.70,
                    "inputColor0": CIColor(red: 0.31, green: 0.22, blue: 0.11, alpha: glowAlpha),
                    "inputColor1": CIColor(red: 0.045, green: 0.042, blue: 0.038, alpha: 1),
                ]
            )?.outputImage?.cropped(to: canvasRect)
            if let glow {
                return movedGrid.composited(over: glow)
            }
            return movedGrid
        case .starfieldDots:
            let tileSize = patternTileSize(
                preset: .midnightDots,
                canvasRect: canvasRect,
                scale: patternScale
            )
            return tiledPatternImage(
                preset: .midnightDots,
                canvasRect: canvasRect,
                scale: patternScale,
                opacity: patternOpacity,
                translation: CGPoint(
                    x: (time * tileSize * 0.07).truncatingRemainder(dividingBy: tileSize),
                    y: (time * tileSize * 0.04).truncatingRemainder(dividingBy: tileSize)
                )
            )
        case .auroraFluid:
            let alpha = CGFloat(min(max(patternOpacity, 0), 1))
            let shortEdge = min(canvasRect.width, canvasRect.height)
            let base = CIFilter(
                name: "CILinearGradient",
                parameters: [
                    "inputPoint0": CIVector(x: canvasRect.minX, y: canvasRect.minY),
                    "inputPoint1": CIVector(x: canvasRect.maxX, y: canvasRect.maxY),
                    "inputColor0": CIColor(red: 0.025, green: 0.085, blue: 0.20),
                    "inputColor1": CIColor(red: 0.015, green: 0.028, blue: 0.075),
                ]
            )?.outputImage?.cropped(to: canvasRect)
                ?? CIImage(color: CIColor(red: 0.015, green: 0.028, blue: 0.075))
                    .cropped(to: canvasRect)

            let phases: [(Double, Double, CGFloat, CIColor)] = [
                (0.19, 0.27, 0.56, CIColor(red: 0.08, green: 0.42, blue: 0.96, alpha: 0.82 * alpha)),
                (0.14, 0.22, 0.42, CIColor(red: 0.08, green: 0.83, blue: 0.96, alpha: 0.62 * alpha)),
                (0.11, 0.17, 0.32, CIColor(red: 0.90, green: 0.97, blue: 1.00, alpha: 0.70 * alpha)),
            ]
            return phases.enumerated().reduce(base) { image, entry in
                let (index, phase) = entry
                let offset = Double(index) * 2.18
                let center = CIVector(
                    x: canvasRect.midX
                        + cos(time * phase.0 + offset) * canvasRect.width * 0.36,
                    y: canvasRect.midY
                        + sin(time * phase.1 + offset * 0.73) * canvasRect.height * 0.34
                )
                let radius = shortEdge * phase.2 * CGFloat(patternScale)
                guard let blob = CIFilter(
                    name: "CIGaussianGradient",
                    parameters: [
                        "inputCenter": center,
                        "inputColor0": phase.3,
                        "inputColor1": CIColor.clear,
                        "inputRadius": radius,
                    ]
                )?.outputImage?.cropped(to: canvasRect) else { return image }
                return blob.composited(over: image)
            }
        }
    }

    nonisolated static func backgroundImage(
        scene: FrameBackgroundScene,
        canvasRect: CGRect,
        wallpaperSource: CIImage?,
        time: Double = 0
    ) -> CIImage {
        if scene.source.usesWallpaperMedia, let wallpaperSource {
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

        switch scene.source {
        case let .pattern(preset):
            return patternImage(preset: preset, canvasRect: canvasRect, scale: scene.patternScale, opacity: scene.patternOpacity)
        case let .dynamicFlow(preset):
            return dynamicFlowImage(preset: preset, canvasRect: canvasRect, scale: scene.patternScale, opacity: scene.patternOpacity, time: time)
        case .projectImage, .systemImage, .projectVideo, .systemVideo:
            let defaultColor = CIColor(.defaultBackground)
            return CIImage(color: defaultColor).cropped(to: canvasRect)
        }
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
        // A masked color is transparent outside the mask. Keeping the whole
        // canvas as its extent makes a small camera shadow, border, or chrome
        // control travel through subsequent filters as a full-resolution layer.
        // Restrict only that known-clear area; mask density and blur support
        // remain unchanged, and the caller still owns its original canvas clip.
        let extent = canvasRect.intersection(mask.extent)
        guard !extent.isEmpty, !extent.isNull else {
            return CIImage(color: .clear).cropped(to: .zero)
        }
        let foreground = CIImage(color: color).cropped(to: extent)
        let transparent = CIImage(color: .clear).cropped(to: extent)
        return foreground.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask,
            ]
        ).cropped(to: extent)
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
