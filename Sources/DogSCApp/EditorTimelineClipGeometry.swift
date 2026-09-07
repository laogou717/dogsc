import CoreGraphics

/// The picture and compact waveform share one clip and one edit boundary.
enum EditorTimelineClipGeometry {
    static let contentInset: CGFloat = 3
    static let waveformBandFraction: CGFloat = 0.26

    static func waveformBand(in rect: CGRect) -> CGRect {
        let content = rect.insetBy(dx: 0, dy: contentInset)
        let height = max(content.height, 0) * waveformBandFraction
        return CGRect(x: rect.minX, y: content.maxY - height, width: rect.width, height: height)
    }
}
