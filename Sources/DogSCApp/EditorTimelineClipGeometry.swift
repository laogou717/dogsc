import CoreGraphics

/// The picture and compact waveform share one clip and one edit boundary.
enum EditorTimelineClipGeometry {
    static let contentInset: CGFloat = 3
    static let waveformBandFraction: CGFloat = 0.26

    /// Local coordinates of the part of a clip that can receive pointer input.
    /// A long clip can be tens of thousands of points wide when zoomed in;
    /// its visual frame must not also become one enormous gesture surface.
    static func interactionRange(
        segmentOriginX: CGFloat,
        segmentWidth: CGFloat,
        documentRange: ClosedRange<CGFloat>
    ) -> ClosedRange<CGFloat> {
        let width = max(segmentWidth, 0)
        let start = min(max(documentRange.lowerBound - segmentOriginX, 0), width)
        let end = min(max(documentRange.upperBound - segmentOriginX, start), width)
        return start...end
    }

    static func waveformBand(in rect: CGRect) -> CGRect {
        let content = rect.insetBy(dx: 0, dy: contentInset)
        let height = max(content.height, 0) * waveformBandFraction
        return CGRect(x: rect.minX, y: content.maxY - height, width: rect.width, height: height)
    }
}
