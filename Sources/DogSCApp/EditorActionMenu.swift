import SwiftUI

/// The editor uses its own readable action cards; AppKit still owns popover
/// placement, focus and outside-click dismissal.
struct EditorActionMenu<Label: View>: View {
    let title: String
    let items: [RecorderMenuItem]
    var showsHover = true
    var arrowEdge: Edge = .bottom
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { label() }
            .buttonStyle(EditorToolbarPressButtonStyle(showsHover: showsHover))
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .focusEffectDisabled()
            .help(appLocalized(title))
            .accessibilityLabel(appLocalized(title))
            .editorPopoverKeyboardEntry { isPresented = true }
            .editorPopover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            switch item.kind {
                            case .separator:
                                Rectangle().fill(EditorTheme.hairline)
                                    .frame(height: 1)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                            case .info:
                                Text(item.title).font(EditorTypography.helper)
                                    .foregroundStyle(EditorTheme.popoverSecondaryText)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                            case .action:
                                actionRow(item)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: menuContentHeight)
                .padding(4)
                .frame(width: menuWidth)
            }
    }

    private func actionRow(_ item: RecorderMenuItem) -> some View {
        Button {
            performAction(item)
        } label: {
            HStack(spacing: 8) {
                if let symbol = item.systemImage {
                    EditorSymbol(symbol, size: 14)
                        .foregroundStyle(EditorTheme.secondaryText)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                    if let detail = item.detail {
                        Text(detail)
                            .font(EditorTypography.helper)
                            .foregroundStyle(EditorTheme.popoverSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                EditorSymbol("checkmark", size: 13)
                    .foregroundStyle(EditorTheme.primaryText)
                    .opacity(item.isOn ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: item.detail == nil ? 28 : 40)
        }
        .buttonStyle(EditorActionRowStyle(selected: item.isOn))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control))
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
                return max(titleWidth, detailWidth) + 52 + (item.systemImage == nil ? 0 : 26)
            }
        }.max() ?? 0
        return min(320, max(180, ceil(contentWidth) + 2))
    }

    private var menuContentHeight: CGFloat {
        min(items.reduce(CGFloat(0)) { result, item in
            switch item.kind {
            case .separator: result + 9
            case .info: result + 28
            case .action: result + (item.detail == nil ? 28 : 40)
            }
        }, 400)
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
            let lit = isEnabled && hovered
            configuration.label
                .foregroundStyle(EditorTheme.chrome(isEnabled ? 0.92 : 0.32))
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(EditorTheme.chrome(isEnabled && configuration.isPressed ? EditorStateWash.pressed : lit ? EditorStateWash.hover : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control))
                .onHover { hovered = $0 }
                .animation(SpringMotion.micro, value: hovered)
        }
    }
}
