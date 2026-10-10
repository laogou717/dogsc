import SwiftUI
import RecorderCore

/// Shared material for the independent tools surrounding the video: the
/// recorder's island. One solid shape, a machined top edge that fades toward
/// the bottom, and a soft cast shadow. Parameter groups inside stay flat.
struct EditorFloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = EditorInterfaceRadius.floating

    func body(content: Content) -> some View {
        content
            .background(EditorTheme.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                EditorIslandEdge(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .shadow(color: EditorTheme.softShadow, radius: 22, y: 10)
    }
}

/// The recorder's top-lit rim, shared by every island shape in the editor.
struct EditorIslandEdge<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape
            .strokeBorder(LinearGradient(colors: [EditorTheme.topHighlight, EditorTheme.islandEdgeLow],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// A capsule island for compact toolbars floating over the workspace.
struct EditorCapsuleIsland: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EditorTheme.cardElevated, in: Capsule(style: .continuous))
            .overlay { EditorIslandEdge(shape: Capsule(style: .continuous)) }
            .shadow(color: EditorTheme.softShadow.opacity(0.8), radius: 16, y: 6)
    }
}

extension View {
    func editorCapsuleIsland() -> some View { modifier(EditorCapsuleIsland()) }
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
                colorScheme == .light ? .black.opacity(0.13) : .white.opacity(0.09)
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
        // 8 pt inset + 18 pt selection radius keeps the corners concentric.
        .modifier(EditorFloatingSurface(cornerRadius: 26))
        .disabled(isCropping)
        .opacity(isCropping ? 0.45 : 1)
        
    }

    private func rail(buttonHeight: CGFloat, spacing: CGFloat) -> some View {
        let compact = buttonHeight < 44
        return VStack(spacing: spacing) {
            ForEach(InspectorTab.allCases) { tab in
                let selected = selection == tab
                AppChoiceButton(isSelected: selected) {
                    selectTab(tab)
                } label: {
                    VStack(spacing: compact ? 2 : 4) {
                        // The recorder's hand-drawn 18 pt family; selection
                        // brightens ink and lifts the neutral pill behind it.
                        AppLineIcon(kind: tab.lineIcon, size: compact ? 17 : 19)
                            .modifier(AppChoiceIconFeedback())
                        Text(tab.localizedLabel)
                            .font(.appUI(size: compact ? 10.5 : 11, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .modifier(AppChoiceContentFeedback())
                    .foregroundStyle(selected ? EditorTheme.primaryText
                                     : hoveredTab == tab ? EditorTheme.chrome(0.78) : EditorTheme.chrome(0.5))
                    .frame(width: 56, height: buttonHeight)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(EditorTheme.railSelectionWash)
                                .matchedGeometryEffect(id: "toolSelection", in: selectionNamespace)
                        } else if hoveredTab == tab {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(EditorTheme.chrome(0.05))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .appButtonKeyboardFocus(
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .disabled(!isAvailable(tab))
                .opacity(isAvailable(tab) ? 1 : 0.38)
                .help(help(for: tab))
                .accessibilityLabel(tab.localizedLabel)
                .accessibilityIdentifier("editor.workspace.tool.\(tab.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        if hovering { hoveredTab = tab } else if hoveredTab == tab { hoveredTab = nil }
                    }
                }
            }
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func selectTab(_ tab: InspectorTab) {
        // The pill travels on the recorder's settle spring.
        withAnimation(RecorderMotion.settle) { selection = tab }
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

extension InspectorTab {
    /// Hand-drawn counterpart of `icon`, sharing the recorder's stroke.
    var lineIcon: AppLineIcon.Kind {
        switch self {
        case .frame: .scene
        case .opening: .opening
        case .zoom: .zoom
        case .cursor: .cursorMotion
        case .camera: .camera
        case .audio: .speaker
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

/// A quiet transport capsule; playback alone carries the primary ink fill.
struct EditorSoftRaisedButtonStyle: ButtonStyle {
    var isPrimary = false
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isPrimary: isPrimary)
    }

    private struct Surface: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: ButtonStyleConfiguration
        let isPrimary: Bool

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .foregroundStyle(isPrimary ? EditorTheme.onAccent : EditorTheme.primaryText)
                .background(
                    isPrimary ? EditorTheme.platinumAccent.opacity(pressed ? 0.78 : isHovered ? 0.9 : 1)
                        : EditorTheme.chrome(pressed ? 0.14 : isHovered ? 0.10 : 0.055),
                    in: Capsule()
                )
                .contentShape(Capsule())
                .appKeyboardFocus(in: Capsule(), color: isPrimary ? EditorTheme.onAccent.opacity(0.65) : EditorTheme.chrome(0.40))
                .scaleEffect(pressed && !RecorderMotion.reduces ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.38)
                .onHover { isHovered = $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { isHovered = false } }
                .animation(RecorderMotion.fade, value: isHovered)
                .animation(RecorderMotion.quick, value: pressed)
        }
    }
}
