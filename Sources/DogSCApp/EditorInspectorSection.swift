import SwiftUI

/// Unified inspector section rhythm. Every inspector page used to hand-roll
/// its own `Text` headers and `Divider` separators with slightly different
/// fonts and spacing; one component now owns the title style and the gap
/// between a header and its controls. Sections opt into a quiet grouped
/// surface only when their contents have no surfaces of their own.
struct EditorInspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Capsule segmented switch used in place of system segmented pickers inside
/// the inspector. System segmented rendering cannot be trusted with a light
/// accent (the selected segment would paint white-on-white); this control
/// deliberately matches the 背景 tab strip in the 画面 page so every
/// segmented choice in the editor shares one visual language.
struct EditorSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    var icon: (Option) -> String? = { _ in nil }
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected ? Color.white.opacity(0.14) : Color(white: 0.10)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .overlay {
                            Group {
                                if let systemName = icon(option) {
                                    Label(title(option), systemImage: systemName)
                                } else {
                                    Text(title(option))
                                }
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(
                                isSelected ? Color.primary : Color.secondary
                            )
                        }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Color.black.opacity(0.2),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}
