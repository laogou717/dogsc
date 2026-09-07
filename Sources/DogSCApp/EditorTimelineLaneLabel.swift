import SwiftUI

/// All track headers share the same three columns, including empty action
/// slots. Different title lengths never move icons, actions or row boundaries.
struct EditorTimelineLaneLabel: View {
    let title: String
    let symbol: String
    var onHide: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.appUI(size: 13, weight: .regular))
                .foregroundStyle(EditorTheme.chrome(0.48))
                .frame(width: 20)
            Text(title)
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.66))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let onHide {
                    Button(action: onHide) {
                        Image(systemName: "eye.slash")
                            .font(.appUI(size: 11, weight: .regular))
                            .foregroundStyle(EditorTheme.chrome(0.40))
                            .frame(width: 24, height: 28)
                    }
                    .buttonStyle(.editorToolbarPress)
                    .help("隐藏“\(title)”轨道；效果仍然生效")
                    .accessibilityLabel("隐藏“\(title)”轨道")
                } else {
                    Color.clear.frame(width: 24, height: 28)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}

extension EditorTimelineView {
    var timelineRowGrid: some View {
        let rowHeights = [timelineRulerHeight, primaryVideoHeight + 12]
            + (showsCameraSyncTimeline ? [cameraSyncTimelineHeight] : [])
            + (showsZoomTimeline ? [CGFloat(56)] : [])
            + (showsScreenMotionTimeline ? [motionTimelineHeight] : [])
            + (showsCameraMotionTimeline ? [motionTimelineHeight] : [])
            + (showsOverlayTimeline ? [overlayTimelineHeight] : [])
        return Canvas { context, size in
            var lines = Path()
            var y: CGFloat = 0
            for height in rowHeights {
                y += height
                lines.move(to: CGPoint(x: 0, y: y - 0.5))
                lines.addLine(to: CGPoint(x: size.width, y: y - 0.5))
            }
            lines.move(to: CGPoint(x: timelineLabelWidth - 0.5, y: 0))
            lines.addLine(to: CGPoint(x: timelineLabelWidth - 0.5, y: size.height))
            context.stroke(lines, with: .color(EditorTheme.chrome(0.085)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
