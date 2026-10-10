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

    var body: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.headingGap) {
            if showsTitle {
                HStack(spacing: 6) {
                    if let icon {
                        Group {
                            if let kind = EditorToolbarIconSurface.lineIcon(for: icon) {
                                AppLineIcon(kind: kind, size: 15)
                            } else {
                                Image(systemName: icon).font(.appUI(size: 13, weight: .regular))
                            }
                        }
                            .foregroundStyle(EditorTheme.secondaryText)
                    }
                    Text(appLocalized(title))
                        .font(EditorTypography.sectionTitle)
                        .foregroundStyle(EditorTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: EditorInterfaceSpacing.controlGap) {
                content
            }
        }
        .padding(.vertical, showsTitle ? 4 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized(title))
    }
}

/// Compact product-owned empty state for a missing or stale inspector
/// context. System `ContentUnavailableView` is intentionally avoided here:
/// its document-style scale overwhelms a narrow inspector and cannot express
/// the direct action that releases an invalid selection.
struct EditorInspectorEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String
    var actionTitle: String? = nil
    var actionSystemImage = "arrow.uturn.backward"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.appUI(size: 16, weight: .semibold))
                .foregroundStyle(EditorTheme.platinumAccent.opacity(0.82))
                .frame(width: 38, height: 38)
                .background(
                    EditorTheme.platinumAccent.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(EditorTheme.platinumAccent.opacity(0.14), lineWidth: 0.75)
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
                    Label(appLocalized(actionTitle), systemImage: actionSystemImage)
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
    @State private var hoveredOption: Option?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                let localizedTitle = appLocalized(title(option))
                AppChoiceButton(isSelected: isSelected) {
                    withAnimation(RecorderMotion.settle) {
                        selection = option
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                            .fill(hoveredOption == option && !isSelected ? EditorTheme.chrome(0.055) : .clear)
                        if isSelected {
                            // The recorder's flat neutral lift: no outline, no shadow.
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                                .fill(EditorTheme.selectionWash)
                                .matchedGeometryEffect(id: "segmentActiveIndicator", in: segmentNamespace)
                        }
                        Group {
                            if let systemName = icon(option) {
                                HStack(spacing: 6) {
                                    Group {
                                        if let kind = EditorToolbarIconSurface.lineIcon(for: systemName) {
                                            AppLineIcon(kind: kind, size: 15)
                                        } else {
                                            Image(systemName: systemName)
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
                        .font(.appUI(size: 12, weight: .medium))
                        .foregroundStyle(
                            isSelected ? EditorTheme.primaryText : EditorTheme.secondaryText
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: EditorInterfaceHeight.selection)
                }

                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .frame(maxWidth: .infinity)
                .frame(height: EditorInterfaceHeight.selection)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        if hovering { hoveredOption = option }
                        else if hoveredOption == option { hoveredOption = nil }
                    }
                }
                .help(appLocalized(optionHelp?(option) ?? title(option)))
                .accessibilityLabel(accessibilityTitle.map { appLocalized($0(option)) } ?? localizedTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            EditorTheme.groupSurface,
            in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
        )
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
                    withAnimation(RecorderMotion.settle) {
                        selection = option
                    }
                }
            }
        }
        .padding(4)
        .background(
            EditorTheme.groupSurface,
            in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct EditorTileSelectorLayout: Layout {
    let maximumColumnCount: Int
    private let spacing: CGFloat = 6

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
    @State private var isHovered = false

    var body: some View {
        AppChoiceButton(isSelected: isSelected, action: action) {
            HStack(spacing: 6) {
                Group {
                    if let kind = EditorToolbarIconSurface.lineIcon(for: icon) {
                        AppLineIcon(kind: kind, size: 15)
                    } else {
                        Image(systemName: icon).font(.appUI(size: 12, weight: .regular))
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
                EditorTheme.chrome(isSelected ? 0.88 : isHovered ? 0.82 : 0.62)
            )
            .frame(maxWidth: .infinity)
            .frame(height: EditorInterfaceHeight.selection)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                        .fill(EditorTheme.selectionWash)
                        .matchedGeometryEffect(id: "activeTileSelector", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(EditorTheme.chrome(0.075))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(RecorderMotion.fade) {
                isHovered = hovering
            }
        }
        .onChange(of: isSelected) { _, _ in isHovered = false }
        .help(appLocalized(title))
        .accessibilityLabel(appLocalized(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
