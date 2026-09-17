import Foundation

public struct CursorAssetPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CursorAssetSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Rendering metadata shared by the editor preview and export compositor.
/// Hotspots use normalized image coordinates with a top-left origin.
public struct CursorAssetMetrics: Equatable, Sendable {
    public var hotspot: CursorAssetPoint
    public var intrinsicSize: CursorAssetSize
    public var clickColor: HexColor
    /// Image-space height that maps to the user's canonical cursor size.
    /// System shapes share the arrow's reference, preserving native proportions.
    public var scaleReferenceHeight: Double

    public init(
        hotspot: CursorAssetPoint,
        intrinsicSize: CursorAssetSize,
        clickColor: HexColor,
        scaleReferenceHeight: Double? = nil
    ) {
        self.hotspot = hotspot
        self.intrinsicSize = intrinsicSize
        self.clickColor = clickColor
        self.scaleReferenceHeight = scaleReferenceHeight ?? intrinsicSize.height
    }
}

public struct CursorClickGeometryFrame: Equatable, Sendable {
    public var style: CursorClickEffectStyle
    public var progress: Double

    // Primary outer ring / main shape
    public var primaryDiameter: Double
    public var primaryLineWidth: Double
    public var primaryOpacity: Double
    public var primaryIsFilled: Bool
    public var primaryGlowRadius: Double

    // Secondary inner element (spark dot, inner ring, or glow core)
    public var secondaryDiameter: Double
    public var secondaryLineWidth: Double
    public var secondaryOpacity: Double
    public var secondaryIsFilled: Bool
    public var secondaryGlowRadius: Double

    // Accent rays / burst
    public var accentOffset: Double
    public var accentSize: Double
    public var accentOpacity: Double

    // Maximum footprint diameter
    public var maxFootprintDiameter: Double

    public init(
        style: CursorClickEffectStyle,
        progress: Double,
        primaryDiameter: Double,
        primaryLineWidth: Double,
        primaryOpacity: Double,
        primaryIsFilled: Bool,
        primaryGlowRadius: Double = 0,
        secondaryDiameter: Double = 0,
        secondaryLineWidth: Double = 0,
        secondaryOpacity: Double = 0,
        secondaryIsFilled: Bool = false,
        secondaryGlowRadius: Double = 0,
        accentOffset: Double = 0,
        accentSize: Double = 0,
        accentOpacity: Double = 0,
        maxFootprintDiameter: Double = 0
    ) {
        self.style = style
        self.progress = progress
        self.primaryDiameter = primaryDiameter
        self.primaryLineWidth = primaryLineWidth
        self.primaryOpacity = primaryOpacity
        self.primaryIsFilled = primaryIsFilled
        self.primaryGlowRadius = primaryGlowRadius
        self.secondaryDiameter = secondaryDiameter
        self.secondaryLineWidth = secondaryLineWidth
        self.secondaryOpacity = secondaryOpacity
        self.secondaryIsFilled = secondaryIsFilled
        self.secondaryGlowRadius = secondaryGlowRadius
        self.accentOffset = accentOffset
        self.accentSize = accentSize
        self.accentOpacity = accentOpacity
        self.maxFootprintDiameter = maxFootprintDiameter > 0
            ? maxFootprintDiameter
            : max(primaryDiameter + primaryGlowRadius * 2, secondaryDiameter + secondaryGlowRadius * 2, (accentOffset + accentSize) * 2)
    }
}

public struct CursorRenderLayout: Equatable, Sendable {
    /// Top-left image origin in the same coordinate space as the pointer.
    public var origin: CompositionPoint
    public var size: CursorAssetSize
    public var pointer: CompositionPoint
    public var clickDiameter: Double
    public var clickLineWidth: Double
    /// Click feedback keeps the user's chosen size when the cursor shape changes.
    public var clickEffectHeight: Double

    public init(
        origin: CompositionPoint,
        size: CursorAssetSize,
        pointer: CompositionPoint,
        clickDiameter: Double,
        clickLineWidth: Double,
        clickEffectHeight: Double? = nil
    ) {
        self.origin = origin
        self.size = size
        self.pointer = pointer
        self.clickDiameter = clickDiameter
        self.clickLineWidth = clickLineWidth
        self.clickEffectHeight = clickEffectHeight ?? size.height
    }
}

/// Canonical cursor sizing and hotspot placement. Both preview and export feed
/// this evaluator top-left-origin coordinates, then only the export renderer
/// performs Core Image's final Y-axis conversion.
public enum CursorRenderGeometry {
    public static let canonicalHeight: Double = 44
    public static let canonicalShortEdge: Double = 1_080

    public static func layout(
        pointer: CompositionPoint,
        canvasShortEdge: Double,
        styleSize: Double,
        metrics: CursorAssetMetrics
    ) -> CursorRenderLayout? {
        guard pointer.x.isFinite, pointer.y.isFinite,
              canvasShortEdge.isFinite, canvasShortEdge > 0,
              metrics.hotspot.x.isFinite, metrics.hotspot.y.isFinite,
              metrics.intrinsicSize.width.isFinite,
              metrics.intrinsicSize.height.isFinite,
              metrics.intrinsicSize.width > 0,
              metrics.intrinsicSize.height > 0,
              metrics.scaleReferenceHeight.isFinite,
              metrics.scaleReferenceHeight > 0 else {
            return nil
        }

        let multiplier = min(max(styleSize, 0.25), 6)
        let referenceHeight = max(
            canvasShortEdge * canonicalHeight / canonicalShortEdge * multiplier,
            1
        )
        let imageScale = referenceHeight / metrics.scaleReferenceHeight
        let height = metrics.intrinsicSize.height * imageScale
        let width = metrics.intrinsicSize.width * imageScale
        let hotspotX = min(max(metrics.hotspot.x, 0), 1)
        let hotspotY = min(max(metrics.hotspot.y, 0), 1)
        let lineWidth = max(referenceHeight * 0.08, canvasShortEdge * 2 / canonicalShortEdge)
        return CursorRenderLayout(
            origin: CompositionPoint(
                x: pointer.x - width * hotspotX,
                y: pointer.y - height * hotspotY
            ),
            size: CursorAssetSize(width: width, height: height),
            pointer: pointer,
            clickDiameter: referenceHeight * 1.45,
            clickLineWidth: lineWidth,
            clickEffectHeight: referenceHeight
        )
    }

    public static func clickGeometry(
        style: CursorClickEffectStyle,
        progress: Double,
        baseHeight: Double,
        opacityMultiplier: Double = 1.0,
        scaleMultiplier: Double = 1.0
    ) -> CursorClickGeometryFrame? {
        guard style != .none, progress >= 0, progress <= 1, baseHeight > 0 else {
            return nil
        }

        let userScale = min(max(scaleMultiplier, 0.4), 3.0)
        let userOpacity = min(max(opacityMultiplier, 0.05), 1.0)
        let scaledHeight = baseHeight * userScale

        switch style {
        case .ripple:
            let e = 1.0 - pow(1.0 - progress, 3.0)
            let primaryDiameter = scaledHeight * (0.45 + 1.45 * e)
            let primaryLineWidth = max(scaledHeight * (0.075 - 0.04 * progress), 1.2)
            let primaryOpacity = max(userOpacity * 0.95 * (1.0 - pow(progress, 1.3)), 0)
            let primaryGlow = scaledHeight * 0.10 * (1.0 - progress)

            let secondaryDiameter: Double
            let secondaryOpacity: Double
            let secondaryIsFilled: Bool
            let secondaryGlow: Double
            if progress < 0.35 {
                let dotP = progress / 0.35
                secondaryDiameter = scaledHeight * 0.28 * (1.0 - dotP)
                secondaryOpacity = max(userOpacity * 0.85 * (1.0 - dotP), 0)
                secondaryIsFilled = true
                secondaryGlow = scaledHeight * 0.08 * (1.0 - dotP)
            } else {
                secondaryDiameter = 0
                secondaryOpacity = 0
                secondaryIsFilled = false
                secondaryGlow = 0
            }

            return CursorClickGeometryFrame(
                style: .ripple,
                progress: progress,
                primaryDiameter: primaryDiameter,
                primaryLineWidth: primaryLineWidth,
                primaryOpacity: primaryOpacity,
                primaryIsFilled: false,
                primaryGlowRadius: primaryGlow,
                secondaryDiameter: secondaryDiameter,
                secondaryLineWidth: 0,
                secondaryOpacity: secondaryOpacity,
                secondaryIsFilled: secondaryIsFilled,
                secondaryGlowRadius: secondaryGlow,
                maxFootprintDiameter: scaledHeight * 2.2
            )

        case .glow:
            let primaryDiameter: Double
            let primaryOpacity: Double
            if progress < 0.18 {
                let pBloom = progress / 0.18
                primaryDiameter = scaledHeight * (0.75 + 0.50 * (1.0 - pow(1.0 - pBloom, 2.0)))
                primaryOpacity = max(userOpacity * 0.78 * pBloom, 0)
            } else {
                let pFade = (progress - 0.18) / 0.82
                primaryDiameter = scaledHeight * (1.25 + 0.55 * pFade)
                primaryOpacity = max(userOpacity * 0.78 * (1.0 - pow(pFade, 1.4)), 0)
            }
            let primaryGlow = scaledHeight * 0.30
            let secondaryDiameter = primaryDiameter * 0.50
            let secondaryOpacity = primaryOpacity * 0.75
            let secondaryGlow = scaledHeight * 0.18

            return CursorClickGeometryFrame(
                style: .glow,
                progress: progress,
                primaryDiameter: primaryDiameter,
                primaryLineWidth: 0,
                primaryOpacity: primaryOpacity,
                primaryIsFilled: true,
                primaryGlowRadius: primaryGlow,
                secondaryDiameter: secondaryDiameter,
                secondaryLineWidth: 0,
                secondaryOpacity: secondaryOpacity,
                secondaryIsFilled: true,
                secondaryGlowRadius: secondaryGlow,
                maxFootprintDiameter: scaledHeight * 2.2
            )

        case .pulse:
            let e = 1.0 - pow(1.0 - progress, 2.5)
            let primaryDiameter = scaledHeight * (0.50 + 1.25 * e)
            let primaryLineWidth = max(scaledHeight * 0.065, 1.2)
            let primaryOpacity = max(userOpacity * 0.90 * (1.0 - progress), 0)
            let primaryGlow = scaledHeight * 0.10 * (1.0 - progress)

            let secondaryDiameter: Double
            let secondaryLineWidth: Double
            let secondaryOpacity: Double
            let secondaryIsFilled: Bool
            let secondaryGlow: Double
            if progress <= 0.55 {
                let innerP = progress / 0.55
                let innerE = sin(innerP * .pi)
                secondaryDiameter = scaledHeight * (0.25 + 0.45 * innerE)
                secondaryLineWidth = 0
                secondaryOpacity = max(userOpacity * 0.55 * (1.0 - innerP), 0)
                secondaryIsFilled = true
                secondaryGlow = scaledHeight * 0.12 * (1.0 - innerP)
            } else {
                secondaryDiameter = 0
                secondaryLineWidth = 0
                secondaryOpacity = 0
                secondaryIsFilled = false
                secondaryGlow = 0
            }

            return CursorClickGeometryFrame(
                style: .pulse,
                progress: progress,
                primaryDiameter: primaryDiameter,
                primaryLineWidth: primaryLineWidth,
                primaryOpacity: primaryOpacity,
                primaryIsFilled: false,
                primaryGlowRadius: primaryGlow,
                secondaryDiameter: secondaryDiameter,
                secondaryLineWidth: secondaryLineWidth,
                secondaryOpacity: secondaryOpacity,
                secondaryIsFilled: secondaryIsFilled,
                secondaryGlowRadius: secondaryGlow,
                maxFootprintDiameter: scaledHeight * 2.0
            )

        case .burst:
            let primaryDiameter = max(scaledHeight * (0.35 - 0.18 * progress), 1.0)
            let primaryOpacity = max(userOpacity * 0.95 * (1.0 - pow(progress, 2.0)), 0)
            let primaryGlow = scaledHeight * 0.14 * (1.0 - progress)

            let secondaryDiameter = scaledHeight * (0.45 + 0.55 * progress)
            let secondaryLineWidth = max(scaledHeight * 0.035, 1.0)
            let secondaryOpacity = max(userOpacity * 0.55 * (1.0 - progress), 0)
            let secondaryGlow = scaledHeight * 0.08 * (1.0 - progress)

            let burstE = 1.0 - pow(1.0 - progress, 2.0)
            let accentOffset = scaledHeight * (0.28 + 0.38 * burstE)
            let accentSize = max(scaledHeight * 0.075 * (1.0 - progress), 1.2)
            let accentOpacity = max(userOpacity * 0.85 * (1.0 - progress), 0)

            return CursorClickGeometryFrame(
                style: .burst,
                progress: progress,
                primaryDiameter: primaryDiameter,
                primaryLineWidth: 0,
                primaryOpacity: primaryOpacity,
                primaryIsFilled: true,
                primaryGlowRadius: primaryGlow,
                secondaryDiameter: secondaryDiameter,
                secondaryLineWidth: secondaryLineWidth,
                secondaryOpacity: secondaryOpacity,
                secondaryIsFilled: false,
                secondaryGlowRadius: secondaryGlow,
                accentOffset: accentOffset,
                accentSize: accentSize,
                accentOpacity: accentOpacity,
                maxFootprintDiameter: scaledHeight * 1.8
            )

        case .none:
            return nil
        }
    }
}
