import SwiftUI
import RecorderCore

/// Shared material for the three independent tools surrounding the video.
/// A single outer surface supplies depth; individual parameter groups stay flat.
struct EditorFloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = EditorInterfaceRadius.floating

    func body(content: Content) -> some View {
        content
            .background(EditorTheme.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        EditorTheme.hairline,
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: EditorTheme.softShadow.opacity(0.65), radius: 14, y: 5)
    }
}

/// A static workspace grid, outside the rendered video. Never enters export
/// or a per-frame timeline: only size/appearance changes redraw the grid.
struct EditorWorkspaceGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: CGFloat(12), to: size.width, by: 22) {
                for y in stride(from: CGFloat(12), to: size.height, by: 22) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.35, height: 1.35))
                }
            }
            context.fill(dots, with: .color(
                colorScheme == .light ? .black.opacity(0.19) : .white.opacity(0.16)
            ))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Navigation lives to the left of the canvas, while the selected tool's
/// controls remain on the right. The parent owns the existing routing binding.
struct EditorWorkspaceToolRail: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: InspectorTab
    let isCropping: Bool
    let cameraAvailable: Bool
    let audioAvailable: Bool
    let cursorAvailable: Bool
    @State private var hoveredTab: InspectorTab?
    @Namespace private var selectionNamespace

    var body: some View {
        ViewThatFits(in: .vertical) {
            rail(buttonHeight: 52, spacing: 5)
            rail(buttonHeight: 38, spacing: 2)
            AppKeyboardFocusScrollView {
                rail(buttonHeight: 38, spacing: 2)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 72)
        // Keep the surface on the viewport while the buttons scroll inside it.
        .modifier(EditorFloatingSurface())
        .disabled(isCropping)
        .opacity(isCropping ? 0.45 : 1)
        
    }

    private func rail(buttonHeight: CGFloat, spacing: CGFloat) -> some View {
        let compact = buttonHeight < 44
        return VStack(spacing: spacing) {
            ForEach(InspectorTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    selectTab(tab)
                } label: {
                    VStack(spacing: compact ? 2 : 4) {
                        Image(systemName: tab.icon)
                            .font(.appUI(size: compact ? 17 : 19, weight: .regular))
                        Text(tab.localizedLabel)
                            .font(.appUI(size: compact ? 11 : 12, weight: selected ? .medium : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .frame(width: 56, height: buttonHeight)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                                .fill(EditorTheme.railSelectionWash)
                                .matchedGeometryEffect(id: "toolSelection", in: selectionNamespace)
                        } else if hoveredTab == tab {
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                                .fill(EditorTheme.chrome(0.045))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.group, showsHover: false))
                .appButtonKeyboardFocus(
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                )
                .disabled(!isAvailable(tab))
                .opacity(isAvailable(tab) ? 1 : 0.38)
                .help(help(for: tab))
                .accessibilityLabel(tab.localizedLabel)
                .accessibilityIdentifier("editor.workspace.tool.\(tab.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard isEnabled, !isCropping, isAvailable(tab),
                          press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                        return .ignored
                    }
                    selectTab(tab)
                    return .handled
                }
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        hoveredTab = hovering ? tab : nil
                    }
                }
            }
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func selectTab(_ tab: InspectorTab) {
        withAnimation(SpringMotion.fluid) { selection = tab }
    }

    private func isAvailable(_ tab: InspectorTab) -> Bool {
        switch tab {
        case .camera: cameraAvailable
        case .audio: audioAvailable
        case .cursor: cursorAvailable
        case .frame, .opening, .zoom: true
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

/// Chrome and preview use the same ratio, so unused letterboxing never
/// separates the tools from the visible canvas on a wide display.
enum EditorWorkspaceGeometry {
    static func aspectRatio(canvas: CanvasStyle, sourceSize: CGSize) -> CGFloat {
        let sourceSize = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize : CGSize(width: 16, height: 9)
        let crop = canvas.crop.clamped()
        let croppedAspect = Double(sourceSize.width / max(sourceSize.height, 1))
            * crop.width / crop.height
        return CGFloat(canvas.resolvedAspectRatio(sourceAspectRatio: croppedAspect))
    }
}

struct EditorSoftRaisedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration) }

    private struct Surface: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .foregroundStyle(EditorTheme.chrome(isEnabled ? 0.88 : 0.28))
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(configuration.isPressed && isEnabled
                            ? EditorTheme.panelRaised : EditorTheme.cardElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                                .fill(EditorTheme.chrome(isHovered && isEnabled ? 0.045 : 0))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                                .strokeBorder(EditorTheme.chrome(isHovered && isEnabled ? 0.14 : 0.085), lineWidth: 0.75)
                        }
                        .allowsHitTesting(false)
                }
                .shadow(color: EditorTheme.softShadow.opacity(isHovered && isEnabled ? 0.35 : 0.2), radius: 2, y: 1)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
                .onHover { isHovered = $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { isHovered = false } }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}
