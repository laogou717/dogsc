import SwiftUI

/// The inspector's task switcher, docked at the top of the panel: six
/// evenly spaced icon tabs and a short ink indicator that glides beneath
/// the current one. The parent owns the existing routing binding.
struct EditorInspectorTabBar: View {
    static let height: CGFloat = 60
    @Binding var selection: InspectorTab
    let isCropping: Bool
    let cameraAvailable: Bool
    let audioAvailable: Bool
    let cursorAvailable: Bool
    @State private var hoveredTab: InspectorTab?
    @Namespace private var indicator

    // Same grammar as the Settings navigation island: 44 pt targets, only
    // the current task shows its name, one pill glides between them.
    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .animation(SpringMotion.hover, value: hoveredTab)
        .disabled(isCropping)
        .opacity(isCropping ? 0.45 : 1)
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let selected = selection == tab
        let hovered = hoveredTab == tab && !selected
        return AppChoiceButton(isSelected: selected) {
            guard selection != tab else { return }
            withAnimation(SpringMotion.settle) { selection = tab }
        } label: {
            HStack(spacing: 7) {
                AppLineIcon(kind: tab.lineIcon, size: 17)
                    .modifier(AppChoiceIconFeedback())
                if selected {
                    Text(tab.localizedLabel)
                        .font(.appUI(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.settingsLabel)
                }
            }
            .modifier(AppChoiceContentFeedback())
            .foregroundStyle(
                selected
                    ? EditorTheme.onAccent
                    : hovered ? EditorTheme.primaryText : EditorTheme.secondaryText
            )
            .padding(.leading, selected ? 14 : 0)
            .padding(.trailing, selected ? 16 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(EditorTheme.platinumAccent)
                        .matchedGeometryEffect(id: "inspector.tab.thumb", in: indicator)
                } else if hovered {
                    Circle().fill(SettingsTheme.hover)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .disabled(!isAvailable(tab))
        .opacity(isAvailable(tab) ? 1 : 0.35)
        .help(help(for: tab))
        .accessibilityLabel(tab.localizedLabel)
        .accessibilityIdentifier("editor.workspace.tool.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering in
            if hovering { hoveredTab = tab } else if hoveredTab == tab { hoveredTab = nil }
        }
    }

    private func isAvailable(_ tab: InspectorTab) -> Bool {
        switch tab {
        case .camera: return cameraAvailable
        case .audio: return audioAvailable
        case .cursor: return cursorAvailable
        case .frame, .opening, .zoom: return true
        }
    }

    private func help(for tab: InspectorTab) -> String {
        guard !isAvailable(tab) else { return tab.localizedLabel }
        switch tab {
        case .camera: return appLocalized("当前项目没有摄像头素材")
        case .audio: return appLocalized("当前项目没有系统声音或麦克风素材")
        case .cursor: return appLocalized("当前项目没有记录鼠标事件")
        case .frame, .opening, .zoom: return tab.localizedLabel
        }
    }
}
