import SwiftUI

/// Unified inspector section rhythm. Every inspector page used to hand-roll
/// its own `Text` headers and `Divider` separators with slightly different
/// fonts and spacing; one component now owns the title style and the gap
/// between a header and its controls. Sections opt into a quiet grouped
/// surface only when their contents have no surfaces of their own.
struct EditorInspectorSection<Content: View>: View {
    let title: String
    var icon: String? = nil
    let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.6))
                }
                Text(appLocalized(title))
                    .font(.appUI(size: 14, weight: .semibold))
                    .foregroundStyle(EditorTheme.chrome(0.88))
            }
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
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
                    .font(.appUI(size: 12.5, weight: .semibold))
                    .foregroundStyle(EditorTheme.chrome(0.90))
                Text(detail)
                    .font(.appUI(size: 10.5))
                    .foregroundStyle(EditorTheme.chrome(0.48))
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
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [EditorTheme.chrome(0.048), EditorTheme.chrome(0.022)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(EditorTheme.chrome(0.075), lineWidth: 0.75)
        }
        .shadow(color: EditorTheme.softShadow, radius: 5, y: 2)
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
    @Binding var selection: Option
    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(SpringMotion.fluid) {
                        selection = option
                    }
                } label: {
                    ZStack {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(EditorTheme.cardElevated)
                                .shadow(color: EditorTheme.softShadow, radius: 3, y: 1)
                                .matchedGeometryEffect(id: "segmentActiveIndicator", in: segmentNamespace)
                        }
                        Group {
                            if let systemName = icon(option) {
                                Label(title(option), systemImage: systemName)
                            } else {
                                Text(title(option))
                            }
                        }
                        .font(.appUI(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(
                            isSelected ? Color.primary : Color.secondary
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                }
                .buttonStyle(EditorSegmentedOptionButtonStyle(isSelected: isSelected))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
                .accessibilityLabel(accessibilityTitle?(option) ?? title(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            EditorTheme.chrome(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(EditorTheme.chrome(0.06), lineWidth: 0.5)
        )
    }
}

private struct EditorSegmentedOptionButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, isSelected: isSelected)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    !isSelected && isHovered && isEnabled
                        ? EditorTheme.chrome(0.055)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .scaleEffect(
                    configuration.isPressed && isEnabled ? 0.965
                        : isHovered && !isSelected && isEnabled ? 1.015 : 1
                )
                .opacity(isEnabled ? 1 : 0.42)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
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
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 6),
                count: max(columnCount, 1)
            ),
            spacing: 6
        ) {
            ForEach(options, id: \.self) { option in
                EditorTileSelectorButton(
                    title: title(option),
                    icon: icon(option),
                    isSelected: selection == option,
                    namespace: tileNamespace
                ) {
                    withAnimation(SpringMotion.fluid) {
                        selection = option
                    }
                }
            }
        }
        .padding(4)
        .background(
            EditorTheme.chrome(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(EditorTheme.chrome(0.06), lineWidth: 0.5)
        }
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
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.appUI(size: 12, weight: .semibold))
                Text(title)
                    .font(.appUI(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(
                EditorTheme.chrome(isSelected ? 0.88 : isHovered ? 0.82 : 0.62)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [EditorTheme.selectionWash, EditorTheme.selectionWash],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(EditorTheme.selectionTint.opacity(0.15), lineWidth: 0.75)
                        }
                        .matchedGeometryEffect(id: "activeTileSelector", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(EditorTheme.chrome(0.075))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
