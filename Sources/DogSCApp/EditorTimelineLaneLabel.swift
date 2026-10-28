import SwiftUI

/// All track headers share the same three columns, including empty action
/// slots. Different title lengths never move icons, actions or row boundaries.
struct EditorTimelineLaneLabel: View {
    let title: String
    let symbol: String
    var tint: Color = EditorTheme.chrome(0.48)
    var onHide: (() -> Void)?
    var horizontalInset: CGFloat = 12
    /// Icon-only column: the name moves into the tooltip.
    var collapsed = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            // The lane's glyph on a wash of its colour, the same tile the
            // track panel uses.
            EditorSymbol(symbol, size: 12)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .accessibilityHidden(true)
            if !collapsed {
                Text(appLocalized(title))
                    .font(.appUI(size: 12))
                    .foregroundStyle(isHovered ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .offset(x: -6)))
            }
        }
        .padding(.horizontal, collapsed ? 15 : horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        // The hide action floats over the name's end only under the pointer,
        // so it never takes width from the name.
        .overlay(alignment: .trailing) {
            if let onHide, !collapsed {
                Button(action: onHide) {
                    EditorSymbol("eye.slash", size: 13.5)
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(EditorTheme.chromeBar.opacity(0.92), in: Circle())
                }
                .buttonStyle(.editorToolbarPress)
                .opacity(isHovered ? 1 : 0)
                .padding(.trailing, 6)
                .help(String(format: appLocalized("隐藏“%@”轨道；效果仍然生效"), appLocalized(title)))
                .accessibilityLabel(String(format: appLocalized("隐藏“%@”轨道"), appLocalized(title)))
            }
        }
        .help(collapsed ? appLocalized(title) : "")
        .onHover { hovering in withAnimation(SpringMotion.hover) { isHovered = hovering } }
    }
}

extension EditorTimelineView {
    func timelineRowGrid(labelWidth: CGFloat) -> some View {
        let rowHeights = [timelineRulerHeight, primaryVideoHeight + 12]
            + (showsCameraSyncTimeline ? [cameraSyncTimelineHeight] : [])
            + (showsZoomTimeline ? [zoomTimelineHeight] : [])
            + (showsScreenMotionTimeline ? [motionTimelineHeight] : [])
            + (showsCameraMotionTimeline ? [motionTimelineHeight] : [])
            + (showsOverlayTimeline ? [overlayTimelineHeight] : [])
        _ = rowHeights
        // Row lines are drawn by the rows themselves (timelineRowDivider), so
        // they move with a lane that is being shown or hidden instead of
        // jumping to their final place while the lanes are still animating.
        return Canvas { context, size in
            context.fill(
                Path(CGRect(x: 0, y: 0, width: labelWidth, height: size.height)),
                with: .color(EditorTheme.chromeBar)
            )
            var labelDivider = Path()
            labelDivider.move(to: CGPoint(x: labelWidth - 0.5, y: 0))
            labelDivider.addLine(to: CGPoint(x: labelWidth - 0.5, y: size.height))
            context.stroke(labelDivider, with: .color(EditorTheme.chrome(0.07)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// SwiftUI frames, Canvas and native playhead layers must all see the same
/// interpolated width. Animating only a frame leaves the latter two at the
/// final position immediately, because time-bound geometry rejects implicit
/// animation. Keep that protection and interpolate its input instead.
struct EditorTimelineColumnLayout<Content: View>: View, Animatable {
    var labelWidth: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    nonisolated var animatableData: CGFloat {
        get { labelWidth }
        set { labelWidth = newValue }
    }

    var body: some View { content(labelWidth) }
}

/// One clock for timeline swaps: the outgoing layer leaves first, the
/// incoming one follows, and lanes open or close without showing through
/// the rows that move beneath them.
enum EditorTimelineSwap {
    static let inDelay: Double = 0.1
}

extension AnyTransition {
    static var timelineLane: AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6))
                .animation(.easeOut(duration: 0.22).delay(0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }
}

extension View {
    /// The hairline under a timeline row (a lane or its header).
    func timelineRowDivider(strong: Bool = false) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorTheme.chrome(strong ? 0.085 : 0.055))
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
    }
}
