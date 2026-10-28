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
        // Settings grammar: a quiet caption, then one rounded tile holding
        // the controls. Tiles are separated by space, never by rules.
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                HStack(spacing: 5) {
                    if let icon {
                        Group {
                            if let kind = EditorToolbarIconSurface.lineIcon(for: icon) {
                                AppLineIcon(kind: kind, size: 12)
                            } else {
                                EditorSymbol(icon, size: 13.5).font(.appUI(size: 11, weight: .regular))
                            }
                        }
                    }
                    Text(appLocalized(title))
                        .font(.appUI(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(EditorTheme.tertiaryText)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            }

            if insideTile {
                VStack(alignment: .leading, spacing: EditorInterfaceSpacing.controlGap) {
                    content
                }
            } else {
                VStack(alignment: .leading, spacing: EditorInterfaceSpacing.controlGap) {
                    content
                }
                .padding(.horizontal, EditorInterfaceSpacing.tileInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EditorTheme.cardFill,
                            in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.tile, style: .continuous))
                .environment(\.editorInsideTile, true)
            }
        }
        .modifier(EditorSectionReveal(isNested: insideTile))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized(title))
    }
}

/// Top-level sections arrive with their page; nested ones just sit inside.
private struct EditorSectionReveal: ViewModifier {
    let isNested: Bool

    func body(content: Content) -> some View {
        if isNested { content } else { content.consoleReveal() }
    }
}

/// A well (a segmented track, a bar's groove, a secondary button) inside a
/// tile is cut out of that tile in the panel's own tone, rather than adding
/// one more grey on top of its grey. Outside tiles the shared track grey stays.
enum EditorWell {
    static func fill(insideTile: Bool) -> Color {
        insideTile ? EditorTheme.panelSurface : EditorChoiceStyle.track
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
                .font(.appUI(size: 16, weight: .semibold))
                .foregroundStyle((palette?.stroke ?? EditorTheme.platinumAccent).opacity(palette == nil ? 0.82 : 1))
                .frame(width: 38, height: 38)
                .background(
                    (palette?.fill ?? EditorTheme.platinumAccent).opacity(palette == nil ? 0.09 : 0.16),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
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
    @Namespace private var segmentNamespace
    @Environment(\.consolePalette) private var palette
    @Environment(\.editorInsideTile) private var insideTile
    @State private var hoveredOption: Option?

    @ViewBuilder
    private func optionButton(_ option: Option) -> some View {
        let isSelected = selection == option
        let localizedTitle = appLocalized(title(option))
        AppChoiceButton(isSelected: isSelected) {
            withAnimation(SpringMotion.settle) {
                selection = option
            }
        } label: {
            ZStack {
                if isSelected {
                    // The settings thumb: one raised slab travelling in a recessed track.
                    EditorRaisedThumb(shape: Capsule(style: .continuous))
                        .matchedGeometryEffect(id: "segmentActiveIndicator", in: segmentNamespace)
                }
                Group {
                    if let systemName = icon(option) {
                        HStack(spacing: 6) {
                            Group {
                                if let kind = EditorToolbarIconSurface.lineIcon(for: systemName) {
                                    AppLineIcon(kind: kind, size: 15)
                                } else {
                                    EditorSymbol(systemName, size: 14)
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
                .font(.appUI(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected
                        ? (palette?.ink ?? EditorTheme.primaryText)
                        : hoveredOption == option ? EditorTheme.primaryText : EditorTheme.secondaryText
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: EditorInterfaceHeight.selection)
            // The whole segment is the target. Without an explicit
            // shape only the glyphs hit-test, and the pressed glyph
            // shrinks, so a release could land "outside" the button.
            .contentShape(Capsule(style: .continuous))
        }
        .appButtonKeyboardFocus(in: Capsule(style: .continuous))
        .frame(maxWidth: .infinity)
        .frame(height: EditorInterfaceHeight.selection)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(SpringMotion.hover) {
                if hovering { hoveredOption = option }
                else if hoveredOption == option { hoveredOption = nil }
            }
        }
        .help(appLocalized(optionHelp?(option) ?? title(option)))
        .accessibilityLabel(accessibilityTitle.map { appLocalized($0(option)) } ?? localizedTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
        .padding(2)
        .background(EditorWell.fill(insideTile: insideTile), in: Capsule(style: .continuous))
        // Per-option exits can be missed when a page swap moves the control
        // under a still pointer; the track as a whole always clears hover.
        .onHover { inside in
            if !inside { withAnimation(SpringMotion.hover) { hoveredOption = nil } }
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
                    withAnimation(SpringMotion.settle) {
                        selection = option
                    }
                }
            }
        }
        .padding(2)
        .background(EditorWell.fill(insideTile: insideTile),
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct EditorTileSelectorLayout: Layout {
    let maximumColumnCount: Int
    private let spacing: CGFloat = 2

    func makeCache(subviews: Subviews) -> CGFloat {
        let naturalWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        // Leave modest room for the tile's existing text scaling, then wrap
        // whole options instead of truncating translated direction names.
        return max(ceil(naturalWidth * 0.9), 1)
    }

    func updateCache(_ cache: inout CGFloat, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) -> CGSize {
        let naturalWidth = cache * CGFloat(maximumColumnCount) + spacing * CGFloat(maximumColumnCount - 1)
        // SwiftUI also probes with infinity; return this grid's natural maximum
        // instead of converting an unbounded column capacity to an integer.
        let width = proposal.width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? naturalWidth
        let columns = columnCount(for: width, minimumTileWidth: cache)
        let rows = (subviews.count + columns - 1) / columns
        let height = CGFloat(rows) * EditorInterfaceHeight.selection
            + CGFloat(max(rows - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) {
        let columns = columnCount(for: bounds.width, minimumTileWidth: cache)
        let tileWidth = max((bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
        let tileHeight = EditorInterfaceHeight.selection
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index % columns) * (tileWidth + spacing),
                    y: bounds.minY + CGFloat(index / columns) * (tileHeight + spacing)
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: tileWidth, height: tileHeight)
            )
        }
    }

    private func columnCount(for width: CGFloat, minimumTileWidth: CGFloat) -> Int {
        guard width.isFinite else { return maximumColumnCount }
        let capacity = (width + spacing) / (minimumTileWidth + spacing)
        return Int(max(1, min(CGFloat(maximumColumnCount), capacity)))
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
        AppChoiceButton(isSelected: isSelected, action: action) {
            HStack(spacing: 6) {
                Group {
                    if let kind = EditorToolbarIconSurface.lineIcon(for: icon) {
                        AppLineIcon(kind: kind, size: 15)
                    } else {
                        EditorSymbol(icon, size: 15.5).font(.appUI(size: 12, weight: .regular))
                    }
                }
                .modifier(AppChoiceIconFeedback())
                Text(appLocalized(title))
                    .modifier(AppChoiceContentFeedback())
                        .font(.appUI(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .modifier(AppChoiceContentFeedback())
            .foregroundStyle(
                isSelected && palette != nil
                    ? AnyShapeStyle(palette!.ink)
                    : AnyShapeStyle(EditorTheme.chrome(isSelected ? 0.88 : isHovered ? 0.82 : 0.62))
            )
            .frame(maxWidth: .infinity)
            .frame(height: EditorInterfaceHeight.selection)
            .background {
                if isSelected {
                    EditorRaisedThumb(shape: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control - 2, style: .continuous))
                        .matchedGeometryEffect(id: "activeTileSelector", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control - 2, style: .continuous)
                        .fill(EditorChoiceStyle.hover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
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
