import Foundation

/// The single geometry contract for placing camera pixels inside an authored
/// camera shape. The shape itself is applied later as a mask; this contract
/// deliberately describes the rectangular content aperture behind that mask.
public enum CameraContentFill {
    /// A small, intentional overscan removes one-pixel seams caused by clean
    /// aperture rounding and fractional display/export coordinates. Keeping
    /// this value here prevents preview and export from drifting apart.
    public static let edgeOverscanScale = 1.01

    public static func layout(
        sourceWidth: Double,
        sourceHeight: Double,
        target: CompositionRect,
        focus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        contentScale: Double = 1
    ) -> CameraContentFillLayout? {
        guard sourceWidth.isFinite,
              sourceHeight.isFinite,
              target.x.isFinite,
              target.y.isFinite,
              target.width.isFinite,
              target.height.isFinite,
              sourceWidth > 0,
              sourceHeight > 0,
              target.width > 0,
              target.height > 0
        else { return nil }

        let sourceZoom = min(max(contentScale.isFinite ? contentScale : 1, 1), 4)
        let scale = max(
            target.width / sourceWidth,
            target.height / sourceHeight
        ) * edgeOverscanScale * sourceZoom
        let destinationWidth = sourceWidth * scale
        let destinationHeight = sourceHeight * scale
        let visibleSourceWidth = target.width / scale
        let visibleSourceHeight = target.height / scale
        let focusX = min(max(focus.x.isFinite ? focus.x : 0.5, 0), 1)
        let focusY = min(max(focus.y.isFinite ? focus.y : 0.5, 0), 1)
        let visibleSource = CompositionRect(
            x: (sourceWidth - visibleSourceWidth) * focusX,
            y: (sourceHeight - visibleSourceHeight) * focusY,
            width: visibleSourceWidth,
            height: visibleSourceHeight
        )
        let destination = CompositionRect(
            x: target.x - visibleSource.x * scale,
            y: target.y - visibleSource.y * scale,
            width: destinationWidth,
            height: destinationHeight
        )

        return CameraContentFillLayout(
            source: CompositionRect(
                x: 0,
                y: 0,
                width: sourceWidth,
                height: sourceHeight
            ),
            target: target,
            destination: destination,
            visibleSource: visibleSource,
            scale: scale
        )
    }
}

public struct CameraContentFillLayout: Equatable, Sendable {
    public let source: CompositionRect
    public let target: CompositionRect
    /// The source-sized rectangle after authored aspect-fill and overscan.
    public let destination: CompositionRect
    /// The authored portion of the source that remains visible through target.
    public let visibleSource: CompositionRect
    public let scale: Double

    init(
        source: CompositionRect,
        target: CompositionRect,
        destination: CompositionRect,
        visibleSource: CompositionRect,
        scale: Double
    ) {
        self.source = source
        self.target = target
        self.destination = destination
        self.visibleSource = visibleSource
        self.scale = scale
    }

    /// Horizontal mirroring is evaluated after content fill, around the target
    /// aperture's centre. This keeps a mirrored subject in the same crop and
    /// avoids the translation jump caused by mirroring around the global origin.
    public var mirrorAxisX: Double { target.midX }

    public func destinationPoint(
        forSourcePoint point: CompositionPoint,
        mirroredHorizontally: Bool
    ) -> CompositionPoint {
        let sourceX = mirroredHorizontally
            ? source.x + source.width - (point.x - source.x)
            : point.x
        return CompositionPoint(
            x: destination.x + (sourceX - source.x) * scale,
            y: destination.y + (point.y - source.y) * scale
        )
    }
}
