import SwiftUI

/// All track headers share the same three columns, including empty action
/// slots. Different title lengths never move icons, actions or row boundaries.
struct EditorTimelineLaneLabel: View {
    let title: String
    let symbol: String
    var onHide: (() -> Void)?
    var horizontalInset: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.appUI(size: 13, weight: .regular))
                .foregroundStyle(EditorTheme.chrome(0.48))
                .frame(width: 20)
            Text(appLocalized(title))
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.66))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
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
                    .help(String(format: appLocalized("隐藏“%@”轨道；效果仍然生效"), appLocalized(title)))
                    .accessibilityLabel(String(format: appLocalized("隐藏“%@”轨道"), appLocalized(title)))
                } else {
                    Color.clear.frame(width: 24, height: 28)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxHeight: .infinity)
    }
}

extension EditorTimelineView {
    var timelineRowGrid: some View {
        let rowHeights = [timelineRulerHeight, primaryVideoHeight + 12]
            + (showsCameraSyncTimeline ? [cameraSyncTimelineHeight] : [])
            + (showsZoomTimeline ? [zoomTimelineHeight] : [])
            + (showsScreenMotionTimeline ? [motionTimelineHeight] : [])
            + (showsCameraMotionTimeline ? [motionTimelineHeight] : [])
            + (showsOverlayTimeline ? [overlayTimelineHeight] : [])
        return Canvas { context, size in
            var trackDividers = Path()
            var y: CGFloat = 0
            // Only separate adjacent rows; the final lane flows into the
            // overview gutter instead of enclosing it as another empty row.
            for (index, height) in rowHeights.dropLast().enumerated() {
                y += height
                var divider = Path()
                divider.move(to: CGPoint(x: 0, y: y - 0.5))
                divider.addLine(to: CGPoint(x: size.width, y: y - 0.5))
                if index == 0 {
                    context.stroke(divider, with: .color(EditorTheme.chrome(0.085)), lineWidth: 0.5)
                } else {
                    trackDividers.addPath(divider)
                }
            }
            context.stroke(trackDividers, with: .color(EditorTheme.chrome(0.055)), lineWidth: 0.5)
            var labelDivider = Path()
            labelDivider.move(to: CGPoint(x: timelineLabelWidth - 0.5, y: 0))
            labelDivider.addLine(to: CGPoint(x: timelineLabelWidth - 0.5, y: size.height))
            context.stroke(labelDivider, with: .color(EditorTheme.chrome(0.07)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
