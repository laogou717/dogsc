import SwiftUI

/// Uses the same SwiftUI shape path as the source surface. Permission rows
/// share one grouped card, so only its outer two corners are rounded.
struct FirstUseTourHighlight: Equatable {
    enum Corners: Equatable { case all, top, bottom }
    var radius: CGFloat
    var corners: Corners = .all
    var continuous = true
    var segments = 1
    var spacing: CGFloat = 0
    var inset: CGFloat = 0

    static func rounded(_ radius: CGFloat, corners: Corners = .all) -> Self {
        Self(radius: radius, corners: corners)
    }

    static let recorderSources = Self(radius: 14, segments: 4, spacing: 2, inset: 3)
    static let recorderInputs = Self(radius: 21, continuous: false, segments: 3, spacing: 10)

    func path(in bounds: CGRect) -> CGPath {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let width = (rect.width - CGFloat(segments - 1) * spacing) / CGFloat(segments)
        var path = Path()
        for index in 0..<segments {
            let segment = CGRect(x: rect.minX + CGFloat(index) * (width + spacing), y: rect.minY,
                                 width: width, height: rect.height)
            let radii = RectangleCornerRadii(
                topLeading: corners == .bottom ? 0 : radius,
                bottomLeading: corners == .top ? 0 : radius,
                bottomTrailing: corners == .top ? 0 : radius,
                topTrailing: corners == .bottom ? 0 : radius
            )
            path.addPath(UnevenRoundedRectangle(cornerRadii: radii, style: continuous ? .continuous : .circular).path(in: segment))
        }
        // SwiftUI paths use a top-left origin; the dimmer's AppKit coordinates
        // use a bottom-left origin. This matters for top/bottom-only corners.
        var transform = CGAffineTransform(translationX: 0, y: bounds.minY + bounds.maxY).scaledBy(x: 1, y: -1)
        return path.cgPath.copy(using: &transform) ?? path.cgPath
    }
}
