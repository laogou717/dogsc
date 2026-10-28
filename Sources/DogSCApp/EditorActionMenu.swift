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
            .appButtonKeyboardFocus(in: Capsule(style: .continuous))
            .focusEffectDisabled()
            .help(appLocalized(title))
            .accessibilityLabel(appLocalized(title))
            .editorPopoverKeyboardEntry { isPresented = true }
            .editorPopover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized(title))
                        .font(EditorTypography.eyebrow)
                        .tracking(0.5)
                        .foregroundStyle(EditorTheme.popoverSecondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    ScrollView {
                        VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        switch item.kind {
                        case .separator:
                            Color.clear.frame(height: 6)
                        case .info:
                            Text(item.title).font(.appUI(size: 12)).foregroundStyle(EditorTheme.popoverSecondaryText)
                                .padding(10)
                        case .action:
                            Button {
                                performAction(item)
                            } label: {
                                HStack(spacing: 12) {
                                    if let symbol = item.systemImage {
                                        EditorSymbol(symbol, size: 15)
                                            .frame(width: 30, height: 30)
                                            .background(EditorTheme.chrome(0.06), in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                                            .accessibilityHidden(true)
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
                                    EditorSymbol("checkmark", size: 15.5)
                                        .font(.appUI(size: 12, weight: .medium))
                                        .foregroundStyle(EditorTheme.selectionTint)
                                        .opacity(item.isOn ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 12).frame(minHeight: item.detail == nil ? 36 : 52)
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
            case .separator: return result + 15
            case .info: return result + 40
            case .action: return result + (item.detail == nil ? 40 : 56)
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
            let lit = isEnabled && hovered
            configuration.label
                .foregroundStyle(EditorTheme.chrome(isEnabled ? (lit ? 0.96 : 0.86) : 0.32))
                .offset(x: lit && !RecorderMotion.reduces ? 2 : 0)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(EditorTheme.chrome(isEnabled && configuration.isPressed ? EditorStateWash.pressed : lit ? EditorStateWash.hover : selected ? 0.045 : 0))
                        .overlay {
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                                .strokeBorder(EditorTheme.chrome(lit ? 0.06 : 0), lineWidth: 0.5)
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control))
                .scaleEffect(isEnabled && configuration.isPressed && !RecorderMotion.reduces ? 0.985 : 1)
                .onHover { hovered = $0 }
                .animation(SpringMotion.interactive, value: hovered)
                .animation(SpringMotion.snappy, value: configuration.isPressed)
        }
    }
}
