import CoreImage
import Foundation
import RecorderCore

/// A cursor render result carries both pixels and its projected footprint so a
/// screen-attached cursor can travel through the same homography as the screen.
struct SharedFrameCursorLayer {
    var image: CIImage
    var footprint: CGRect
}

/// Owns cursor sprite placement, velocity rotation, and click-effect lowering.
enum SharedFrameCursorRenderer {
    nonisolated static func render(
        source: CIImage,
        scene: FrameCursorScene,
        over background: CIImage,
        canvasRect: CGRect
    ) -> CIImage {
        guard let layer = layer(
            source: source,
            scene: scene,
            canvasRect: canvasRect
        ) else { return background }
        return layer.image.composited(over: background).cropped(to: canvasRect)
    }

    nonisolated static func layer(
        source: CIImage,
        scene: FrameCursorScene,
        canvasRect: CGRect
    ) -> SharedFrameCursorLayer? {
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
        let pointer = CGPoint(
            x: layout.pointer.x,
            y: Double(canvasRect.maxY) - layout.pointer.y
        )
        let visualCursor: CIImage
        if abs(scene.rotationRadians) > 0.000_1 {
            let rotation = CGAffineTransform(
                translationX: pointer.x,
                y: pointer.y
            )
            .rotated(by: scene.rotationRadians)
            .translatedBy(x: -pointer.x, y: -pointer.y)
            visualCursor = placed.transformed(by: rotation)
        } else {
            visualCursor = placed
        }

        var layer = visualCursor
        var footprint = visualCursor.extent
        if scene.isClicking {
            let progress = scene.clickPhase?.progress ?? 0.25
            let effectiveColor = scene.effectiveClickColor
            if let clickGeom = CursorRenderGeometry.clickGeometry(
                style: scene.clickStyle,
                progress: progress,
                baseHeight: layout.clickEffectHeight,
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
                    layer = visualCursor.composited(over: clickLayerAccum)
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
                layer = visualCursor.composited(over: ring)
                footprint = footprint.union(outerRect)
            }
        }
        return SharedFrameCursorLayer(
            image: layer.cropped(to: footprint),
            footprint: footprint
        )
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
