import AppKit
import CoreImage
import Foundation
import RecorderCore

private final class ProgressTextImageCache: @unchecked Sendable {
    private let storage = NSCache<NSString, CIImage>()

    init() {
        storage.countLimit = 128
        storage.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(
        for key: NSString,
        create: () -> CIImage?
    ) -> CIImage? {
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

/// Lowers editor-authored overlay effects into Core Image layers. Keeping
/// these effects separate prevents the base screen/camera renderer from
/// becoming the owner of every future editor feature.
enum SharedFrameOverlayRenderer {
    private static let progressTextCache = ProgressTextImageCache()

    nonisolated static func applyingMosaics(
        _ mosaics: [FrameMosaicScene],
        to source: CIImage
    ) -> CIImage {
        guard !mosaics.isEmpty else { return source }
        let extent = source.extent
        var result = source
        for mosaic in mosaics where mosaic.style == .blur {
            let progress = mosaic.transitionProgress
            guard progress > 0.001 else { continue }
            let normalizedRect = mosaic.sourceRect.clamped()
            let rect = CGRect(
                x: extent.minX + extent.width * normalizedRect.x,
                y: extent.minY + extent.height
                    * (1 - normalizedRect.y - normalizedRect.height),
                width: extent.width * normalizedRect.width,
                height: extent.height * normalizedRect.height
            ).intersection(extent)
            guard rect.width > 1, rect.height > 1 else { continue }
            let radius = (4 + mosaic.intensity * 44) * progress
            // A local softening box does not need a full 4K/5K Gaussian pass
            // whenever the user moves it. Spotlight is intentionally absent:
            // it belongs to the already-composited base picture, not the raw
            // screen source.
            let sampleRect = rect.insetBy(dx: -radius * 3, dy: -radius * 3)
                .intersection(extent)
            let affected = result.cropped(to: sampleRect)
                .clampedToExtent()
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: radius]
                )
                .cropped(to: sampleRect)
            let cornerRadius = min(rect.width, rect.height) * mosaic.cornerRadius
            let mask = roundedMask(rect: rect, radius: cornerRadius)
            result = affected.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: mask,
                ]
            ).cropped(to: extent)
        }
        return result
    }

    nonisolated static func motionBlurred(
        _ image: CIImage,
        motion: FrameLayerMotion,
        canvasRect: CGRect
    ) -> CIImage {
        // Motion blur is a trail around a moving layer, not a replacement for
        // the layer itself. Clamping a full screen image before CIMotionBlur
        // extended its bright edge pixels across the canvas and turned fast
        // motion into an opaque white smear. Keep the authored layer sharp,
        // blur only its transparent-backed footprint, then place the sharp
        // layer back above that trail.
        let distance = max(motion.distance, 0)
        let radius = min(distance * 0.50, 16)
        let trailOpacity = 0.30 * min(max(distance / 5, 0), 1)
        guard radius >= 0.02, trailOpacity >= 0.001 else {
            return image.cropped(to: canvasRect)
        }
        let angle = atan2(-motion.deltaY, motion.deltaX)
        let blurredTrail = image
            .applyingFilter(
                "CIMotionBlur",
                parameters: [
                    kCIInputRadiusKey: radius,
                    kCIInputAngleKey: angle,
                ]
            )
            .cropped(to: canvasRect)
        // The sharp layer already owns its border, chrome and shadow. Remove
        // their current footprint from the trail so moving frames cannot make
        // those decorations temporarily darker/brighter and then pop on the
        // first static frame.
        let trail = blurredTrail
            .applyingFilter(
                "CISourceOutCompositing",
                parameters: [kCIInputBackgroundImageKey: image]
            )
            .cropped(to: canvasRect)
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: trailOpacity, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: trailOpacity, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: trailOpacity, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: trailOpacity),
                ]
            )
        return image.cropped(to: canvasRect)
            .composited(over: trail)
            .cropped(to: canvasRect)
    }

    nonisolated static func renderSticker(
        source: CIImage,
        scene: FrameStickerScene,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        guard scene.opacity > 0.001 else { return background }
        let normalizedSource = normalized(source)
        guard normalizedSource.extent.width > 0,
              normalizedSource.extent.height > 0 else { return background }
        let width = max(canvasRect.width * scene.width * scene.scale, 2)
        let height = width * normalizedSource.extent.height
            / normalizedSource.extent.width
        let center = CGPoint(
            x: canvasRect.width * (scene.position.x + scene.offset.x),
            y: canvasRect.height * (1 - scene.position.y - scene.offset.y)
        )
        let target = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        let scale = width / normalizedSource.extent.width
        var image = normalizedSource
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: target.minX,
                y: target.minY
            ))
            .cropped(to: target)
        let cornerRadius = min(
            max(scene.cornerRadius * width / 1_920, 0),
            min(width, height) / 2
        )
        let mask = roundedMask(rect: target, radius: cornerRadius)
        image = image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask,
            ]
        )
        if scene.borderWidth > 0 {
            let border = max(scene.borderWidth * canvasRect.width / 1_920, 0.5)
            let outerMask = roundedMask(
                rect: target.insetBy(dx: -border, dy: -border),
                radius: cornerRadius + border
            )
            let ring = ringMask(
                outer: outerMask,
                inner: mask,
                canvasRect: canvasRect
            )
            image = image.composited(over: coloredLayer(
                color: color(scene.borderColor),
                mask: ring,
                canvasRect: canvasRect
            ))
        }
        var card = image
        if scene.shadowOpacity > 0.001 {
            let shadowRadius = scene.shadowRadius * canvasRect.width / 1_920
            let shadowMask = mask
                .transformed(by: CGAffineTransform(
                    translationX: scene.shadowOffset.x * canvasRect.width / 1_920,
                    y: -scene.shadowOffset.y * canvasRect.width / 1_920
                ))
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: shadowRadius]
                )
                .cropped(to: canvasRect)
            let shadow = coloredLayer(
                color: color(.black, alpha: scene.shadowOpacity),
                mask: shadowMask,
                canvasRect: canvasRect
            )
            card = card.composited(over: shadow)
        }
        if abs(scene.rotationRadians) > 0.000_1 {
            card = card
                .transformed(by: CGAffineTransform(
                    translationX: -center.x,
                    y: -center.y
                ))
                .transformed(by: CGAffineTransform(rotationAngle: scene.rotationRadians))
                .transformed(by: CGAffineTransform(
                    translationX: center.x,
                    y: center.y
                ))
        }
        if scene.opacity < 0.999 {
            card = card.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: scene.opacity),
                ]
            )
        }
        return card.composited(over: background).cropped(to: canvasRect)
    }

    nonisolated static func renderProgress(
        _ scene: FrameProgressScene,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        let width = canvasRect.width * min(max(scene.width, 0.05), 1)
        let bandHeight = max(scene.bandHeight * canvasRect.width / 1_920, 24)
        let centerX = min(
            max(
                canvasRect.minX + canvasRect.width * scene.position.x,
                canvasRect.minX + width / 2
            ),
            canvasRect.maxX - width / 2
        )
        let bandY: CGFloat = switch scene.placement {
        case .top:
            canvasRect.maxY - bandHeight
        case .bottom:
            canvasRect.minY
        case .custom:
            min(max(
                canvasRect.height * (1 - scene.position.y) - bandHeight / 2,
                canvasRect.minY
            ), canvasRect.maxY - bandHeight)
        }
        let bandRect = CGRect(
            x: centerX - width / 2,
            y: bandY,
            width: width,
            height: bandHeight
        )
        let bandMask = roundedMask(rect: bandRect, radius: 0)
        var layer = coloredLayer(
            color: color(
                scene.backgroundColor,
                alpha: CGFloat(scene.backgroundOpacity)
            ),
            mask: bandMask,
            canvasRect: canvasRect
        )
        // The progress itself is the foreground area of the complete band.
        // A separate hairline read as an unrelated decoration and made the
        // component look like a title card with a second progress widget.
        let fillWidth = max(width * min(max(scene.fraction, 0), 1), 0)
        if fillWidth > 0.5 {
            let fillRect = CGRect(
                x: bandRect.minX,
                y: bandRect.minY,
                width: fillWidth,
                height: bandRect.height
            )
            layer = coloredLayer(
                color: color(scene.fillColor),
                mask: roundedMask(rect: fillRect, radius: 0),
                canvasRect: canvasRect
            ).composited(over: layer)
        }
        let chapters = scene.chapters.isEmpty
            ? [FrameProgressChapterScene(fraction: 0, title: "")]
            : scene.chapters
        for index in chapters.indices {
            let start = min(max(chapters[index].fraction, 0), 1)
            let end: Double = index + 1 < chapters.count
                ? min(max(chapters[index + 1].fraction, start), 1)
                : 1
            let segmentRect = CGRect(
                x: bandRect.minX + width * CGFloat(start),
                y: bandRect.minY,
                width: max(width * CGFloat(end - start), 0),
                height: bandRect.height
            )
            if index > 0 {
                let divider = CGRect(
                    x: segmentRect.minX,
                    y: bandRect.minY + bandRect.height * 0.2,
                    width: max(canvasRect.width / 1_920, 1),
                    height: bandRect.height * 0.6
                )
                layer = CIImage(color: color(scene.nodeColor, alpha: 0.32))
                    .cropped(to: divider)
                    .composited(over: layer)
            }
            let title = chapters[index].title.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
            let textBounds = segmentRect.insetBy(
                dx: min(bandHeight * 0.25, segmentRect.width * 0.18),
                dy: 0
            )
            guard !title.isEmpty, textBounds.width > 12 else { continue }
            let requestedFontSize = scene.textSize * canvasRect.width / 1_920
            let fontSize = min(max(requestedFontSize, 10), bandHeight * 0.72)
            let components = scene.textColor.components
            let cacheKey = String(
                format: "%@|%.2f|%.4f|%.4f|%.4f",
                title,
                Double(fontSize),
                components.red,
                components.green,
                components.blue
            ) as NSString
            if let text = progressTextCache.image(for: cacheKey, create: {
                let attributed = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.systemFont(
                            ofSize: fontSize,
                            weight: .semibold
                        ),
                        .foregroundColor: NSColor(
                            calibratedRed: components.red,
                            green: components.green,
                            blue: components.blue,
                            alpha: 1
                        ),
                    ]
                )
                return CIFilter(
                    name: "CIAttributedTextImageGenerator",
                    parameters: [
                        "inputText": attributed,
                        "inputScaleFactor": 1,
                    ]
                )?.outputImage
            }), text.extent.width > 0 {
                let availableWidth = max(textBounds.width, 2)
                let scale = min(max(availableWidth / text.extent.width, 0.55), 1)
                let scaled = text.transformed(by: CGAffineTransform(
                    scaleX: scale,
                    y: scale
                ))
                let placed = scaled.transformed(by: CGAffineTransform(
                    translationX: textBounds.midX
                        - scaled.extent.width / 2 - scaled.extent.minX,
                    y: bandRect.midY
                        - scaled.extent.height / 2 - scaled.extent.minY
                ))
                // A dense chapter layout may make the minimum readable scale
                // wider than its segment. Keep that title inside its own node
                // instead of letting it collide with adjacent chapter text.
                layer = placed.cropped(to: textBounds).composited(over: layer)
            }
        }
        return layer.composited(over: background).cropped(to: canvasRect)
    }

    private nonisolated static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
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
        ).cropped(to: canvasRect)
    }

    private nonisolated static func color(
        _ value: HexColor,
        alpha: CGFloat = 1
    ) -> CIColor {
        let components = value.components
        return CIColor(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: alpha
        )
    }
}
