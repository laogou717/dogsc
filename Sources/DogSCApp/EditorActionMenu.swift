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
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .focusEffectDisabled()
            .help(appLocalized(title))
            .accessibilityLabel(appLocalized(title))
            .editorPopoverKeyboardEntry { isPresented = true }
            .editorPopover(isPresented: $isPresented, arrowEdge: .bottom) {
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
                            Text(item.title).font(.appUI(size: 12)).foregroundStyle(EditorTheme.popoverSecondaryText)
                                .padding(10)
                        case .action:
                            Button {
                                performAction(item)
                            } label: {
                                HStack(spacing: 12) {
                                    if let symbol = item.systemImage {
                                        Image(systemName: symbol).font(.system(size: 16))
                                            .frame(width: 22).accessibilityHidden(true)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                                        if let detail = item.detail {
                                            Text(detail)
                                                .font(.appUI(size: 12))
                                                .foregroundStyle(EditorTheme.popoverSecondaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 12)
                                    Image(systemName: "checkmark")
                                        .font(.appUI(size: 12, weight: .medium))
                                        .foregroundStyle(EditorTheme.selectionTint)
                                        .opacity(item.isOn ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 12).frame(minHeight: item.detail == nil ? 36 : 52)
                            }
                            .buttonStyle(EditorActionRowStyle(selected: item.isOn))
                            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
                            .disabled(!item.isEnabled)
                            .accessibilityLabel(appLocalized(item.title))
                            .accessibilityAddTraits(item.isOn ? .isSelected : [])
                            .help(appLocalized(item.detail ?? item.title))
                            .onKeyPress(keys: [.return], phases: .down) { press in
                                guard item.isEnabled,
                                      press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                                    return .ignored
                                }
                                performAction(item)
                                return .handled
                            }
                        }
                    }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: menuContentHeight)
                }
                .padding(8).frame(width: menuWidth)
            }
    }
    private func performAction(_ item: RecorderMenuItem) {
        isPresented = false
        item.handler?()
    }

    private var menuWidth: CGFloat {
        let contentWidth = items.map { item -> CGFloat in
            switch item.kind {
            case .separator:
                return 0
            case .info:
                return AppTypography.regularTextWidth(item.title, size: 12) + 36
            case .action:
                let titleWidth = AppTypography.regularTextWidth(item.title, size: 13)
                let detailWidth = item.detail.map {
                    AppTypography.regularTextWidth($0, size: 12)
                } ?? 0
                // Padding, the trailing checkmark and gaps stay aligned;
                // rows with an icon also reserve its 22-point column.
                return max(titleWidth, detailWidth) + 88 + (item.systemImage == nil ? 0 : 34)
            }
        }.max() ?? 0
        return min(360, max(270, ceil(contentWidth) + 2))
    }

    private var menuContentHeight: CGFloat {
        min(items.reduce(CGFloat(0)) { result, item in
            switch item.kind {
            case .separator: result + 15
            case .info: result + 40
            case .action: result + (item.detail == nil ? 40 : 56)
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
