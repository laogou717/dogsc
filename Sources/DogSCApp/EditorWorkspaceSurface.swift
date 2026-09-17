import SwiftUI
import RecorderCore

/// Shared material for the three independent tools surrounding the video.
/// A single outer surface supplies depth; individual parameter groups stay flat.
struct EditorFloatingSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(LinearGradient(colors: [EditorTheme.cardElevated, EditorTheme.panelSurface], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .light ? 0.85 : 0.09),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .light ? 0.055 : 0.20), radius: 16, y: 7)
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
            ScrollView(.vertical, showsIndicators: false) {
                rail(buttonHeight: 38, spacing: 2)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 72)
        .disabled(isCropping)
        .opacity(isCropping ? 0.45 : 1)
        
    }

    private func rail(buttonHeight: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(InspectorTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(SpringMotion.fluid) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.appUI(size: 19, weight: .regular))
                        Text(tab.localizedLabel)
                            .font(.appUI(size: 11, weight: selected ? .medium : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(width: 56, height: buttonHeight)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(EditorTheme.railSelectionWash)
                                .shadow(color: EditorTheme.softShadow, radius: 4, y: 2)
                                .matchedGeometryEffect(id: "toolSelection", in: selectionNamespace)
                        } else if hoveredTab == tab {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(EditorTheme.chrome(0.045))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 14, showsHover: false))
                .disabled(!isAvailable(tab))
                .opacity(isAvailable(tab) ? 1 : 0.38)
                .help(help(for: tab))
                .accessibilityLabel(tab.localizedLabel)
                .accessibilityIdentifier("editor.workspace.tool.\(tab.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        hoveredTab = hovering ? tab : nil
                    }
                }
            }
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(EditorFloatingSurface(cornerRadius: 24))
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
        if let fixed = canvas.resolvedFixedAspectRatio { return CGFloat(fixed) }
        let crop = canvas.crop.clamped()
        return max(sourceSize.width / max(sourceSize.height, 1)
            * CGFloat(crop.width / crop.height), 0.01)
    }
}

/// Native NSPanel owns the only outer shadow. SwiftUI supplies the opaque
/// rounded content silhouette, leaving the window corners transparent.
struct RecorderPanelSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(EditorTheme.panelSurface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(EditorTheme.chrome(0.06), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
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
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(configuration.isPressed && isEnabled
                            ? EditorTheme.panelRaised : EditorTheme.cardElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(EditorTheme.chrome(isHovered && isEnabled ? 0.045 : 0))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(EditorTheme.chrome(isHovered && isEnabled ? 0.10 : 0.065), lineWidth: 0.75)
                        }
                        .allowsHitTesting(false)
                }
                .shadow(color: EditorTheme.softShadow.opacity(isHovered && isEnabled ? 0.8 : 0.5), radius: 4, y: 2)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
                .onHover { isHovered = $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { isHovered = false } }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}
