import SwiftUI

/// The editor uses its own readable action cards; AppKit still owns popover
/// placement, focus and outside-click dismissal.
struct EditorActionMenu<Label: View>: View {
    let title: String
    let items: [RecorderMenuItem]
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { label() }
            .buttonStyle(.editorToolbarPress)
            .focusEffectDisabled()
            .help(title)
            .accessibilityLabel(title)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized(title))
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    ScrollView {
                        VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        switch item.kind {
                        case .separator:
                            Divider().padding(.horizontal, 10).padding(.vertical, 5)
                        case .info:
                            Text(item.title).font(.appUI(size: 12)).foregroundStyle(.secondary)
                                .padding(10)
                        case .action:
                            Button {
                                isPresented = false
                                item.handler?()
                            } label: {
                                HStack(spacing: 12) {
                                    if let symbol = item.systemImage {
                                        Image(systemName: symbol).font(.system(size: 16))
                                            .frame(width: 22).accessibilityHidden(true)
                                    }
                                    Text(item.title).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 12)
                                    Image(systemName: "checkmark")
                                        .font(.appUI(size: 12, weight: .medium))
                                        .foregroundStyle(EditorTheme.selectionTint)
                                        .opacity(item.isOn ? 1 : 0)
                                }
                                .padding(.horizontal, 12).frame(minHeight: 36)
                            }
                            .buttonStyle(EditorActionRowStyle(selected: item.isOn))
                            .disabled(!item.isEnabled)
                            .help(item.title)
                        }
                    }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: menuContentHeight)
                }
                .padding(8).frame(width: 270)
                .background(EditorTheme.panelSurface)
                .appControlFocusAppearance()
            }
    }
    private var menuContentHeight: CGFloat {
        min(items.reduce(CGFloat(0)) { result, item in
            switch item.kind {
            case .separator: result + 15
            case .info: result + 40
            case .action: result + 40
            }
        }, 360)
    }

}

struct EditorActionRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        Row(selected: selected, configuration: configuration)
    }
    private struct Row: View {
        let selected: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(EditorTheme.chrome(isEnabled ? 0.88 : 0.32))
                .frame(maxWidth: .infinity)
                .background(EditorTheme.chrome(isEnabled && configuration.isPressed ? 0.13 : isEnabled && hovered ? 0.085 : selected ? 0.045 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
                .animation(SpringMotion.interactive, value: hovered)
                .animation(SpringMotion.snappy, value: configuration.isPressed)
        }
    }
}
