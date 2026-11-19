import SwiftUI

/// The wallpapers as a row of slim slices. The one under the pointer opens
/// wide to show itself; with the pointer away, the chosen one stays open.
struct EditorWallpaperAccordion: View {
    let groups: [SystemWallpaperGroup]
    let selectedGroupID: String?
    let asset: (SystemWallpaperGroup) -> SystemWallpaperAsset?
    let title: (SystemWallpaperGroup) -> String
    let onSelect: (SystemWallpaperGroup) -> Void

    @State private var hoveredID: String?

    private let spacing: CGFloat = 4
    private let height: CGFloat = 124

    var body: some View {
        GeometryReader { proxy in
            let weights = groups.map(weight(for:))
            let totalWeight = max(weights.reduce(0, +), 1)
            let available = max(proxy.size.width - spacing * CGFloat(max(groups.count - 1, 0)), 1)
            HStack(spacing: spacing) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    slice(group, width: available * CGFloat(weights[index] / totalWeight))
                }
            }
            .animation(RecorderMotion.reduces ? nil : SpringMotion.standard, value: hoveredID)
            .animation(RecorderMotion.reduces ? nil : SpringMotion.standard, value: selectedGroupID)
            .onHover { inside in
                if !inside { hoveredID = nil }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    private func weight(for group: SystemWallpaperGroup) -> Double {
        if hoveredID == group.id { return 5 }
        if hoveredID == nil, selectedGroupID == group.id { return 3.4 }
        return 1
    }

    @ViewBuilder
    private func slice(_ group: SystemWallpaperGroup, width: CGFloat) -> some View {
        if let asset = asset(group) {
            let isSelected = selectedGroupID == group.id
            let isOpen = hoveredID == group.id || (hoveredID == nil && isSelected)
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            Button { onSelect(group) } label: {
                Color.clear
                    .overlay { SystemWallpaperThumbnail(asset: asset) }
                    .frame(width: width, height: height)
                    .clipShape(shape)
                    .overlay(alignment: .bottomLeading) {
                        Text(title(group))
                            .font(.appUI(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(.black.opacity(0.42), in: Capsule(style: .continuous))
                            .padding(7)
                            .opacity(isOpen && width > 72 ? 1 : 0)
                            .offset(y: isOpen ? 0 : 5)
                            .animation(SpringMotion.snappy, value: isOpen)
                    }
                    .overlay {
                        shape.strokeBorder(
                            isSelected ? EditorTheme.selectionTint : EditorTheme.chrome(0.08),
                            lineWidth: isSelected ? 2 : 0.75
                        )
                    }
                    .opacity(isOpen ? 1 : 0.82)
                    .contentShape(shape)
            }
            .buttonStyle(.editorThumbnail)
            .focusEffectDisabled()
            .onHover { inside in
                if inside { hoveredID = group.id }
                else if hoveredID == group.id { hoveredID = nil }
            }
            .help(title(group))
            .accessibilityLabel(title(group))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
