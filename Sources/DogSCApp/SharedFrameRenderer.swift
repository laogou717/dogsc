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
    var cameraBeauty: CameraBeautyFrame?
    var wallpaper: CIImage?
    var cursor: CIImage?
    var stickers: [String: CIImage]
    /// Rive frames already rendered for this exact output time, by clip id.
    var animations: [UUID: CIImage]
    /// Overlay video frames for this output time, by clip id.
    var videos: [UUID: CIImage] = [:]
    /// EDT-071: the live-drawn HTML motion of a main-track clip. It takes the
    /// place of the screen source (whose frame there is only a stand-in).
    var insertedMotion: CIImage?
    var insertedImage: CIImage?
    var timedStickers: [UUID: CIImage] = [:]
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
        animations: [UUID: CIImage] = [:],
        preparedBackground: CIImage? = nil
    ) {
        self.screen = screen
        self.camera = camera
        self.wallpaper = wallpaper
        self.cursor = cursor
        self.stickers = stickers
        self.animations = animations
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

/// The single Core Image lowering of a backend-neutral `FrameScene`.
///
/// A screen-attached cursor is composited into the decorated screen layer
/// before that layer is projected. Preview and export therefore share one
/// perspective implementation, while the camera remains an independent top
/// layer. An axis-aligned quad takes the original 2D path byte-for-byte.
enum SharedFrameRenderer {
    private static let backgroundPatternTileCache = BackgroundPatternTileCache()



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
        var drewOverlayLayers = false
        var resources = resources
        if scene.insertedImage != nil, let image = resources.insertedImage {
            resources.screen = image
        }
        if scene.insertedMotion != nil {
            // Over black, like the stand-in it replaces; until the first page
            // frame lands the span simply stays black.
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: resources.screen.extent)
            if let motion = resources.insertedMotion, motion.extent.width > 0, motion.extent.height > 0 {
                // Drawn at the output size; the screen layer fits it into the
                // frame (cover), so no second scale happens here.
                let placed = motion.transformed(by: CGAffineTransform(translationX: -motion.extent.minX, y: -motion.extent.minY))
                resources.screen = placed.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0))).cropped(to: placed.extent)
            } else {
                resources.screen = black
            }
        }
        // Insert an attached camera next to its owner in the mixed visual stack.
        // A higher title or video can still cover it, and a lower video cannot
        // fill the aperture between a template and its camera.
        let cameraOwner = scene.camera?.insetVideoID ?? scene.camera?.coveringVideoID ?? scene.animations.last(where: \.hostsCamera)?.id
        let cameraBeforeOwner = scene.cameraBeforeVisualOverlays
        func camera(over base: CIImage) -> CIImage {
            guard cameraVisibility > 0.001 else { return base }
            guard let cameraScene = scene.camera,
                  cameraScene.opacity > 0,
                  let cameraImage = resources.camera else { return base }
            var cameraLayer = renderCamera(
                source: cameraImage,
                scene: cameraScene,
                tracking: resources.cameraBeauty,
                over: transparent,
                canvasRect: canvasRect
            )
            // Only stickers that opt in contribute camera blur.
            let cameraBlur = scene.stickers.isEmpty ? 0 : scene.stickerBackdrop.cameraBlur
            if cameraBlur > 0.01 {
                cameraLayer = cameraLayer.clampedToExtent()
                    .applyingFilter(
                        "CIGaussianBlur",
                        parameters: [kCIInputRadiusKey: cameraBlur]
                    )
                    .cropped(to: canvasRect)
            }
            let visibleCamera = applyingOpacity(cameraLayer, cameraVisibility)
            return visibleCamera.composited(over: base).cropped(to: canvasRect)
        }
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
                if cameraOwner == nil { result = camera(over: result) }
            case .stickers, .videos, .animations:
                // EDT-054: pictures, motion graphics and videos share one layer
                // order (`layerIndex`, then video < sticker < animation), so a
                // later role must not draw them again.
                guard !drewOverlayLayers else { continue }
                drewOverlayLayers = true
                if !scene.stickers.isEmpty {
                    // "Hide screen" means the authored canvas background is the
                    // backdrop; ease any requested screen blur with its phase.
                    let baseBlur = scene.stickerBackdrop.screenBlur
                        * (1 - min(max(screenSuppression, 0), 1))
                    if baseBlur > 0.01 {
                        result = result.clampedToExtent()
                            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: baseBlur])
                            .cropped(to: canvasRect)
                    }
                }
                enum Item { case video(FrameVideoScene), sticker(FrameStickerScene), animation(FrameAnimationScene) }
                let items: [(layer: Int, rank: Int, id: UUID, item: Item)] =
                    scene.videos.map { ($0.layerIndex, 0, $0.id, .video($0)) }
                    + scene.stickers.map { ($0.layerIndex, 1, $0.id, .sticker($0)) }
                    + scene.animations.map { ($0.layerIndex, 2, $0.id, .animation($0)) }
                for entry in items.sorted(by: { $0.layer == $1.layer ? $0.rank < $1.rank : $0.layer < $1.layer }) {
                    let ownsCamera = entry.id == cameraOwner
                    if ownsCamera && cameraBeforeOwner { result = camera(over: result) }
                    defer {
                        if ownsCamera && !cameraBeforeOwner { result = camera(over: result) }
                    }
                    switch entry.item {
                    case let .sticker(sticker):
                        guard let source = resources.timedStickers[sticker.id] ?? resources.stickers[sticker.relativePath] else { continue }
                        result = SharedFrameOverlayRenderer.renderSticker(
                            source: source, scene: sticker, over: result, canvasRect: canvasRect)
                    case let .video(video):
                        guard let source = resources.videos[video.id],
                              source.extent.width > 0, source.extent.height > 0 else { continue }
                        let size = CGSize(width: canvasRect.width * CGFloat(video.width),
                                          height: canvasRect.width * CGFloat(video.width) * CGFloat(video.aspect))
                        let center = CGPoint(x: canvasRect.minX + canvasRect.width * CGFloat(video.position.x),
                                             y: canvasRect.maxY - canvasRect.height * CGFloat(video.position.y))
                        let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                           width: size.width, height: size.height)
                        guard let fill = CameraContentFill.layout(
                            sourceWidth: source.extent.width, sourceHeight: source.extent.height,
                            target: CompositionRect(x: 0, y: 0, width: frame.width, height: frame.height),
                            focus: video.contentPosition, contentScale: video.contentScale, overscan: 1
                        ), let crop = cameraSourceCropRect(sourceExtent: source.extent, layout: fill) else { continue }
                        var placed = source
                            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                            .transformed(by: CGAffineTransform(scaleX: frame.width / crop.width, y: frame.height / crop.height))
                            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
                            .cropped(to: frame)
                        if video.maskRadiusFraction > 0 {
                            let radius = min(frame.width, frame.height) * video.maskRadiusFraction
                            placed = placed.applyingFilter("CIBlendWithMask", parameters: [
                                kCIInputMaskImageKey: roundedMask(rect: frame, radius: radius),
                                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame)
                            ])
                        }
                        result = applyingOpacity(placed, video.opacity).composited(over: result).cropped(to: canvasRect)
                    case let .animation(animation):
                        guard let source = resources.animations[animation.id],
                              source.extent.width > 0, source.extent.height > 0 else { continue }
                        let targetWidth = canvasRect.width * CGFloat(animation.width)
                        let scale = targetWidth / source.extent.width
                        let size = CGSize(width: targetWidth, height: source.extent.height * scale)
                        let center = CGPoint(x: canvasRect.minX + canvasRect.width * CGFloat(animation.position.x),
                                             y: canvasRect.maxY - canvasRect.height * CGFloat(animation.position.y))
                        let placed = source
                            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                            .transformed(by: CGAffineTransform(translationX: center.x - size.width / 2, y: center.y - size.height / 2))
                        var graphic = applyingOpacity(placed, animation.opacity)
                        if let matte = animation.movingMatte, let camera = scene.camera, resources.camera != nil {
                            graphic = movingMatte(graphic, matte: matte, canvas: canvasRect,
                                                  cameraOpacity: camera.opacity * cameraVisibility)
                        }
                        result = graphic.composited(over: result).cropped(to: canvasRect)
                    }
                }
            case .subtitles:
                if let subtitle = scene.subtitle,
                   let image = SubtitleRasterizer.image(for: subtitle, canvasRect: canvasRect) {
                    result = image.composited(over: result).cropped(to: canvasRect)
                }
            }
        }
        return result.cropped(to: canvasRect)
    }

    /// Keep a flattened foreground (including its hole and lettering) registered
    /// to the moving aperture. Painting camera pixels back over a stationary
    /// hole leaves both silhouettes visible throughout the 240 ms handoff.
    private nonisolated static func movingMatte(
        _ graphic: CIImage, matte: FrameAnimationScene.MovingMatte, canvas: CGRect, cameraOpacity: Double
    ) -> CIImage {
        let source = coreImageRect(from: matte.aperture, canvasHeight: canvas.height)
        let target = coreImageRect(from: matte.presented, canvasHeight: canvas.height)
        guard !source.isEmpty, !target.isEmpty else { return graphic }
        let transform = CGAffineTransform(translationX: target.minX, y: target.minY)
            .scaledBy(x: target.width / source.width, y: target.height / source.height)
            .translatedBy(x: -source.minX, y: -source.minY)
        // Extend the authored outer pixels up to the original plate bounds
        // when the moving plate shrinks. Transparent edges stay transparent.
        let moved = graphic.clampedToExtent().transformed(by: transform).cropped(to: graphic.extent)
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = target
        mask.radius = Float(min(matte.cornerRadius, min(target.width, target.height) / 2))
        mask.color = CIColor(red: 1, green: 1, blue: 1, alpha: matte.reveal * cameraOpacity)
        guard let aperture = mask.outputImage else { return moved }
        return moved.applyingFilter("CISourceOutCompositing",
                                    parameters: [kCIInputBackgroundImageKey: aperture.cropped(to: target)])
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

        let widthScale = baseRect.width / cropRect.width
        let heightScale = baseRect.height / cropRect.height
        let fitScale = scene.fillsFrame ? max(widthScale, heightScale) : min(widthScale, heightScale)
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
        guard finalScale.isFinite, finalScale > 0 else { return nil }
        let sourceToCanvas = CGAffineTransform(
            a: finalScale, b: 0, c: 0, d: finalScale,
            tx: finalRect.midX - cropRect.width / 2 * finalScale,
            ty: finalRect.midY - cropRect.height / 2 * finalScale
        )
        // Sample opaque edge pixels before clipping in output space. Cropping a
        // fractional source row first otherwise magnifies its transparent fringe.
        let sampleRect = CGRect(x: ceil(cropRect.minX), y: ceil(cropRect.minY),
                                width: floor(cropRect.maxX) - ceil(cropRect.minX),
                                height: floor(cropRect.maxY) - ceil(cropRect.minY))
        let transform = sourceToCanvas.translatedBy(x: -cropRect.minX, y: -cropRect.minY)
        let transformed = normalizedSource.clamped(to: sampleRect.isEmpty ? cropRect : sampleRect)
            .transformed(by: transform)
            .cropped(to: cropRect.applying(transform))

        let projectionRect = coreImageRect(
            from: scene.projectionRect,
            canvasHeight: canvasRect.height
        )
        let contentCornerRadius: Double = switch scene.decoration {
        case .none: scene.cornerRadius
        case let .chrome(chrome): chrome.contentCornerRadius
        }
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
            let mask = roundedMask(rect: finalRect, radius: contentCornerRadius)
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

        func chromeForegroundLayer() -> CIImage? {
            guard case let .chrome(chrome) = scene.decoration else { return nil }
            return SharedFrameChromeRenderer.foreground(
                chrome, canvasRect: canvasRect, renderExtent: projectionRect
            )
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
                var card = layer.composited(over: chrome)
                if let foreground = chromeForegroundLayer() {
                    card = foreground.composited(over: card)
                }
                layer = card.applyingFilter(
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
            let canvasToNative = sourceToCanvas.inverted()
            let nativeMask = roundedMask(
                rect: finalRect.applying(canvasToNative),
                radius: contentCornerRadius / finalScale
            )
            let nativeClippedSource = croppedSource.applyingFilter(
                "CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: croppedSource.extent),
                    kCIInputMaskImageKey: nativeMask,
                ]
            ).cropped(to: croppedSource.extent)
            if case .chrome = scene.decoration,
               let unifiedCard = unifiedDecoratedPerspectiveTransform(
                   nativeSource: nativeClippedSource,
                   canvasToNative: canvasToNative,
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
                    if let foreground = chromeForegroundLayer(),
                       let projectedForeground = perspectiveTransform(
                           foreground,
                           sourceRect: projectionRect,
                           contentExtent: projectionRect,
                           mapping: projectionMapping
                       ) {
                        projected = projectedForeground.composited(over: projected)
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

    private nonisolated static func screenChromeLayer(
        _ chrome: FrameScreenChromeScene,
        canvasRect: CGRect,
        renderExtent: CGRect,
        coordinateTransform: CGAffineTransform = .identity
    ) -> CIImage {
        SharedFrameChromeRenderer.background(
            chrome,
            canvasRect: canvasRect,
            renderExtent: renderExtent,
            coordinateTransform: coordinateTransform
        )
    }

    private nonisolated static func renderCamera(
        source: CIImage,
        scene: FrameCameraScene,
        tracking: CameraBeautyFrame?,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        let contentRect = coreImageRect(
            from: scene.rect,
            canvasHeight: canvasRect.height
        )
        // The foreground owns the visible edge of a below-graphics aperture.
        // Extend just the masked pixels, keeping the crop and framing exact.
        // Interpolating bleed to zero exposed the wallpaper in fractional
        // edge pixels during the last few frames of a fullscreen handoff.
        let bleed = scene.usesCircularCorners ? 3 * max(1, min(canvasRect.width, canvasRect.height) / 1080) : 0
        let underlayRect = contentRect.insetBy(dx: -bleed, dy: -bleed)
        let underlayRadius = scene.cornerRadius + bleed
        let transparent = CIImage(color: .clear).cropped(to: underlayRect)
        func mask(_ rect: CGRect, radius: CGFloat) -> CIImage {
            // CSS border-radius uses circular arcs. A native continuous corner
            // with the same radius can still uncover the foreground aperture.
            if scene.usesCircularCorners && radius > 0 {
                let generator = CIFilter.roundedRectangleGenerator()
                generator.extent = rect
                generator.radius = Float(min(radius, min(rect.width, rect.height) / 2))
                generator.color = .white
                if let image = generator.outputImage { return image.cropped(to: rect) }
            }
            return roundedMask(rect: rect, radius: radius)
        }
        let cameraMask = mask(underlayRect, radius: underlayRadius)
        let borderOuterRect = underlayRect.insetBy(
            dx: -scene.borderWidth,
            dy: -scene.borderWidth
        )
        let borderOuterMask = scene.borderWidth > 0
            ? mask(
                borderOuterRect,
                radius: underlayRadius + scene.borderWidth
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

        let normalizedSource = normalized(CameraBeautyRenderer.apply(to: source, settings: scene.beauty, tracking: tracking))
        guard let fill = scene.contentFill ?? CameraContentFill.layout(
            sourceWidth: normalizedSource.extent.width,
            sourceHeight: normalizedSource.extent.height,
            target: scene.rect, focus: scene.sourceFocus, contentScale: scene.contentScale
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
        // Keep neighbouring source pixels for the resampling footprint. Cropping
        // a fractional aperture before scaling it would bake transparency into its edges.
        var placed = normalizedSource
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
        ).cropped(to: underlayRect)
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
        canvasToNative: CGAffineTransform,
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
        guard let mapping else { return nil }
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
        var nativeCard = nativeSource.composited(over: nativeChrome)
        if let nativeForeground = SharedFrameChromeRenderer.foreground(
            chrome,
            canvasRect: canvasRect,
            renderExtent: nativeProjectionRect,
            coordinateTransform: canvasToNative
        ) {
            nativeCard = nativeForeground.composited(over: nativeCard)
        }
        var card = nativeCard
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
