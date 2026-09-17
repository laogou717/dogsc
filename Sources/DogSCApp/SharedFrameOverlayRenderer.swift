import AppKit
import CoreImage
import Foundation
import RecorderCore

/// Lowers editor-authored overlay effects into Core Image layers. Keeping
/// these effects separate prevents the base screen/camera renderer from
/// becoming the owner of every future editor feature.
enum SharedFrameOverlayRenderer {

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
        // The card is still allowed to extend beyond the canvas before its
        // authored rotation. Only eliminate known-transparent padding so the
        // rotation and opacity filters do not process a canvas-sized card.
        let transparent = CIImage(color: .clear).cropped(to: target)
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
        ).cropped(to: target)
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
            let shadow = coloredLayer(
                color: color(.black, alpha: scene.shadowOpacity),
                mask: shadowMask,
                canvasRect: canvasRect
            )
            card = card.composited(over: shadow)
        }
        if abs(scene.rotationRadians) > 0.000_1 {
            // Sticker authoring uses the top-left-origin canvas convention:
            // positive angles rotate clockwise, matching SwiftUI and the
            // direct-manipulation handle. Core Image's coordinate system is
            // bottom-left-origin, so the same visible rotation needs the
            // opposite mathematical angle here.
            card = card
                .transformed(by: CGAffineTransform(
                    translationX: -center.x,
                    y: -center.y
                ))
                .transformed(by: CGAffineTransform(rotationAngle: -scene.rotationRadians))
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
        // Preserve the former canvas clipping (including before a sticker's
        // rotation), but do not turn its local border/shadow into a full-canvas
        // intermediate just by adding a transparent background.
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
        let extent = canvasRect.intersection(outer.extent)
        guard !extent.isEmpty, !extent.isNull else {
            return CIImage(color: .clear).cropped(to: .zero)
        }
        return outer.applyingFilter(
            "CISourceOutCompositing",
            parameters: [kCIInputBackgroundImageKey: inner]
        ).cropped(to: extent)
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
