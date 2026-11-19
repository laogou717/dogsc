import SwiftUI

/// All track headers share the same three columns, including empty action
/// slots. Different title lengths never move icons, actions or row boundaries.
struct EditorTimelineLaneLabel: View {
    let title: String
    let symbol: String
    var tint: Color = EditorTheme.chrome(0.48)
    var onHide: (() -> Void)?
    var horizontalInset: CGFloat = EditorTimelineLabelMetrics.inset
    /// Icon-only column: the name moves into the tooltip.
    var collapsed = false
    /// Clips on the lane, shown quietly at the end (mockup `.ct`).
    var count: Int? = nil
    /// The main track reads as the primary row.
    var emphasized = false
    @State private var isHovered = false

    var body: some View {
        // Mockup `.th`: a plain tertiary glyph, the name, and the count. The
        // lane hue lives on the clips, not the header.
        HStack(spacing: EditorTimelineLabelMetrics.spacing) {
            EditorSymbol(symbol, size: EditorTimelineLabelMetrics.icon)
                .foregroundStyle(emphasized ? EditorTheme.secondaryText : EditorTheme.tertiaryText)
                .frame(width: EditorTimelineLabelMetrics.icon, height: EditorTimelineLabelMetrics.icon)
                .accessibilityHidden(true)
            if !collapsed {
                Text(appLocalized(title))
                    .font(.appUI(size: 12.5, weight: emphasized ? .medium : .regular))
                    .foregroundStyle(emphasized || isHovered ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .offset(x: -6)))
                if let count, count > 0 {
                    EditorTimelineLabelCount(count: count)
                        .opacity(isHovered && onHide != nil ? 0 : 1)
                }
            }
        }
        .padding(.leading, collapsed ? EditorTimelineLabelMetrics.collapsedInset : horizontalInset)
        .padding(.trailing, collapsed ? 0 : horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        // The hide action takes the count's place only under the pointer,
        // so it never takes width from the name.
        .overlay(alignment: .trailing) {
            if let onHide, !collapsed {
                Button(action: onHide) {
                    AppLineIcon(kind: .eyeOff, size: 13)
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.control))
                .opacity(isHovered ? 1 : 0)
                .padding(.trailing, horizontalInset - 5)
                .help(String(format: appLocalized("隐藏“%@”轨道；效果仍然生效"), appLocalized(title)))
                .accessibilityLabel(String(format: appLocalized("隐藏“%@”轨道"), appLocalized(title)))
            }
        }
        .help(collapsed ? appLocalized(title) : "")
        .onHover { isHovered = $0 }
    }
}

/// One geometry for every row in the label column, so icons, chevrons,
/// names and counts sit on the same verticals whatever the row kind.
enum EditorTimelineLabelMetrics {
    static let inset: CGFloat = 12
    static let icon: CGFloat = 15
    static let spacing: CGFloat = 8
    /// Where names start: sub-rows (layer numbers) indent to this column.
    static var nameColumn: CGFloat { inset + icon + spacing }
    /// Centres a 15 pt glyph in the 52 pt icon-only column.
    static let collapsedInset: CGFloat = 18.5
}

/// The quiet count at the end of a label row.
struct EditorTimelineLabelCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.appUI(size: 11, design: .monospaced))
            .foregroundStyle(EditorTheme.tertiaryText)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
    }
}

extension EditorTimelineView {
    func timelineRowGrid(labelWidth: CGFloat) -> some View {
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
    nonisolated var labelWidth: CGFloat
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
            insertion: .opacity.animation(.easeOut(duration: 0.16)),
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
