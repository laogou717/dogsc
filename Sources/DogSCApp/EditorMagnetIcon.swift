import SwiftUI

/// A real vector glyph: "magnet" is unavailable in some supported SF Symbols versions.
struct EditorMagnetIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.22, y: h * 0.14))
            path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.54))
            path.addCurve(to: CGPoint(x: w * 0.78, y: h * 0.54),
                control1: CGPoint(x: w * 0.22, y: h * 0.98),
                control2: CGPoint(x: w * 0.78, y: h * 0.98))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.14))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: max(w * 0.18, 1.5), lineCap: .round))
            var ends = Path()
            for x in [0.22, 0.78] {
                ends.move(to: CGPoint(x: w * (x - 0.09), y: h * 0.34))
                ends.addLine(to: CGPoint(x: w * (x + 0.09), y: h * 0.34))
            }
            context.blendMode = .destinationOut
            context.stroke(ends, with: .color(.white), lineWidth: max(w * 0.055, 0.7))
        }
        .accessibilityHidden(true)
    }
}
