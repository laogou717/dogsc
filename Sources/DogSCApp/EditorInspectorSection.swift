import SwiftUI

/// Unified inspector section rhythm. Every inspector page used to hand-roll
/// its own `Text` headers and `Divider` separators with slightly different
/// fonts and spacing; one component now owns the title style and the gap
/// between a header and its controls. Sections opt into a quiet grouped
/// surface only when their contents have no surfaces of their own.
struct EditorInspectorSection<Content: View>: View {
    let title: String
    var icon: String? = nil
    let showsTitle: Bool
    let content: Content

    init(_ title: String, icon: String? = nil, showsTitle: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.showsTitle = showsTitle
        self.content = content()
    }

    @Environment(\.editorInsideTile) private var insideTile

    var body: some View {
        // A group is a small caption and its rows on the panel itself — no
        // card. Groups are separated by space and a hairline above.
        // EDT-079: a 12 pt grey title, rows 8 apart, a hairline under the
        // group (the next one starts after it).
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text(appLocalized(title))
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .frame(minHeight: 18, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.editorInsideTile, true)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized(title))
    }
}

/// A well (a segmented track, a bar's groove, a secondary button) inside a
/// tile is cut out of that tile in the panel's own tone, rather than adding
/// one more grey on top of its grey. Outside tiles the shared track grey stays.
enum EditorWell {
    /// Every segmented track is the same recessed well, inside a tile or not;
    /// the white thumb on it marks the choice.
    static func fill(insideTile: Bool) -> Color {
        EditorTheme.controlWell
    }
}

private struct EditorInsideTileKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a section tile: nested groups drop their own card fill
    /// so surfaces never stack two greys deep.
    var editorInsideTile: Bool {
        get { self[EditorInsideTileKey.self] }
        set { self[EditorInsideTileKey.self] = newValue }
    }
}

/// The one shape for explanatory notes inside a page: a flat card with a
/// small glyph, an optional title and quiet detail lines.
struct EditorInfoNote: View {
    var systemImage: String = "info.circle"
    var title: String? = nil
    let lines: [String]
    @Environment(\.editorInsideTile) private var insideTile

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            EditorSymbol(systemImage, size: 15.5)
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(EditorTheme.tertiaryText)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(appLocalized(title))
                        .font(.appUI(size: 12, weight: .semibold))
                        .foregroundStyle(EditorTheme.primaryText.opacity(0.86))
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.appUI(size: 12)).monospacedDigit()
                        .foregroundStyle(EditorTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, insideTile ? 0 : 12)
        .padding(.vertical, insideTile ? 2 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EditorTheme.cardFill.opacity(insideTile ? 0 : 1),
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.tile, style: .continuous))
    }
}

/// Compact product-owned empty state for a missing or stale inspector
/// context. System `ContentUnavailableView` is intentionally avoided here:
/// its document-style scale overwhelms a narrow inspector and cannot express
/// the direct action that releases an invalid selection.
struct EditorInspectorEmptyState: View {
    @Environment(\.consolePalette) private var palette
    let title: String
    let detail: String
    let systemImage: String
    var actionTitle: String? = nil
    var actionSystemImage = "arrow.uturn.backward"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            EditorSymbol(systemImage, size: 21)
                .font(.appUI(size: 15, weight: .semibold))
                .foregroundStyle((palette?.stroke ?? EditorTheme.platinumAccent).opacity(palette == nil ? 0.82 : 1))
                .frame(width: 38, height: 38)
                .background(
                    (palette?.fill ?? EditorTheme.platinumAccent).opacity(palette == nil ? 0.09 : 0.16),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke((palette?.stroke ?? EditorTheme.platinumAccent).opacity(palette == nil ? 0.14 : 0.35), lineWidth: 0.75)
                }

            VStack(spacing: 4) {
                Text(appLocalized(title))
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(EditorTheme.primaryText)
                Text(appLocalized(detail))
                    .font(EditorTypography.helper)
                    .foregroundStyle(EditorTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    EditorSymbolLabel(appLocalized(actionTitle), systemImage: actionSystemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                .fill(EditorTheme.groupSurface)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Capsule segmented switch used in place of system segmented pickers inside
/// the inspector.
struct EditorSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    var icon: (Option) -> String? = { _ in nil }
    var accessibilityTitle: ((Option) -> String)? = nil
    var optionHelp: ((Option) -> String)? = nil
    @Binding var selection: Option
    @Environment(\.recordingDesignControls) private var recordingColors
    @Namespace private var segmentNamespace
    @Environment(\.consolePalette) private var palette
    @Environment(\.editorInsideTile) private var insideTile
    @State private var hoveredOption: Option?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                let localizedTitle = appLocalized(title(option))
                AppChoiceButton(isSelected: isSelected) {
                    withAnimation(SpringMotion.panel) {
                        selection = option
                    }
                } label: {
                    ZStack {
                        if isSelected {
                            // The settings thumb: one raised slab travelling in a recessed track.
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill((recordingColors ? RecordingDesign.raised : EditorTheme.segmentThumb))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder((recordingColors ? RecordingDesign.line : EditorTheme.hairline), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "segmentActiveIndicator", in: segmentNamespace)
                        }
                        Group {
                            if let systemName = icon(option) {
                                HStack(spacing: 6) {
                                    Group {
                                        if let kind = EditorToolbarIconSurface.lineIcon(for: systemName) {
                                            AppLineIcon(kind: kind, size: 13)
                                        } else {
                                            EditorSymbol(systemName, size: 13)
                                        }
                                    }
                                    .modifier(AppChoiceIconFeedback())
                                    Text(localizedTitle)
                                }
                            } else {
                                Text(localizedTitle)
                                    .modifier(AppChoiceIconFeedback())
                            }
                        }
                        .modifier(AppChoiceContentFeedback())
                        .font(.appUI(size: 12.5, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? (recordingColors ? RecordingDesign.ink : EditorTheme.primaryText)
                                : hoveredOption == option ? (recordingColors ? RecordingDesign.ink : EditorTheme.primaryText) : (recordingColors ? RecordingDesign.secondary : EditorTheme.secondaryText)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    // The whole segment is the target. Without an explicit
                    // shape only the glyphs hit-test, and the pressed glyph
                    // shrinks, so a release could land "outside" the button.
                    .contentShape(Rectangle())
                }

                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { hoveredOption = option }
                    else if hoveredOption == option { hoveredOption = nil }
                }
                .help(appLocalized(optionHelp?(option) ?? title(option)))
                .accessibilityLabel(accessibilityTitle.map { appLocalized($0(option)) } ?? localizedTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background((recordingColors ? RecordingDesign.fill : EditorWell.fill(insideTile: insideTile)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(SpringMotion.micro, value: hoveredOption)
        // Per-option exits can be missed when a page swap moves the control
        // under a still pointer; the track as a whole always clears hover.
        .onHover { inside in
            if !inside { hoveredOption = nil }
        }
        .onChange(of: selection) { _, _ in hoveredOption = nil }
        .onDisappear { hoveredOption = nil }
    }
}

/// Compact visual selector for categories that are easier to recognize by
/// icon and label than by squeezing every option into one long segmented row.
struct EditorTileSelector<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    let icon: (Option) -> String
    @Binding var selection: Option
    var columnCount = 3
    @Namespace private var tileNamespace
    @Environment(\.editorInsideTile) private var insideTile

    var body: some View {
        // Keep these small option groups mounted so keyboard navigation can
        // reach every tile before it scrolls into the inspector's visible area.
        EditorTileSelectorLayout(maximumColumnCount: max(columnCount, 1)) {
            ForEach(options, id: \.self) { option in
                EditorTileSelectorButton(
                    title: title(option),
                    icon: icon(option),
                    isSelected: selection == option,
                    namespace: tileNamespace
                ) {
                    withAnimation(SpringMotion.standard) {
                        selection = option
                    }
                }
            }
        }
        .padding(4)
        .accessibilityElement(children: .contain)
    }
}

private struct EditorTileSelectorLayout: Layout {
    let maximumColumnCount: Int
    private let spacing: CGFloat = 6

    /// Four square tiles a row (fewer options keep the same size).
    private func metrics(_ width: CGFloat) -> (columns: Int, side: CGFloat) {
        let columns = 4
        return (columns, max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? 280
        let m = metrics(width)
        let rows = (subviews.count + m.columns - 1) / m.columns
        return CGSize(width: width, height: CGFloat(rows) * m.side + CGFloat(max(rows - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index % m.columns) * (m.side + spacing),
                            y: bounds.minY + CGFloat(index / m.columns) * (m.side + spacing)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: m.side, height: m.side)
            )
        }
    }
}

private struct EditorTileSelectorButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.consolePalette) private var palette
    @State private var isHovered = false

    var body: some View {
        // EDT-079: a square tile — the option drawn large in the middle, its
        // name small at the foot; the chosen one gets an accent ring.
        AppChoiceButton(isSelected: isSelected, action: action) {
            VStack(spacing: 3) {
                Spacer(minLength: 0)
                Group {
                    if let kind = EditorToolbarIconSurface.lineIcon(for: icon) {
                        AppLineIcon(kind: kind, size: 22)
                    } else {
                        EditorSymbol(icon, size: 22)
                    }
                }
                .modifier(AppChoiceIconFeedback())
                .foregroundStyle(EditorTheme.chrome(isSelected ? 0.9 : 0.7))
                Spacer(minLength: 0)
                Text(appLocalized(title))
                    .font(.appUI(size: 10.5))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.bottom, 4)
            }
            .modifier(AppChoiceContentFeedback())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(EditorTheme.chrome(isHovered && !isSelected ? 0.08 : 0.045))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                        .strokeBorder(EditorTheme.accent, lineWidth: 1.5)
                        .padding(-3.5)
                        .matchedGeometryEffect(id: "activeTileSelector", in: namespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
        .onHover { hovering in
            withAnimation(SpringMotion.hover) {
                isHovered = hovering
            }
        }
        .onChange(of: isSelected) { _, _ in isHovered = false }
        .help(appLocalized(title))
        .accessibilityLabel(appLocalized(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
