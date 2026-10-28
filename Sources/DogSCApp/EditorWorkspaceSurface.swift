import SwiftUI
import RecorderCore

/// Shared material for the independent tools surrounding the video: the
/// recorder's island. One solid shape, a machined top edge that fades toward
/// the bottom, and a soft cast shadow. Parameter groups inside stay flat.
struct EditorFloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = EditorInterfaceRadius.floating

    func body(content: Content) -> some View {
        content
            .background(EditorTheme.cardGradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                EditorIslandEdge(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .shadow(color: EditorTheme.contactShadow, radius: 1.5, y: 1)
            .shadow(color: EditorTheme.softShadow, radius: 18, y: 9)
            .shadow(color: EditorTheme.ambientShadow, radius: 44, y: 22)
    }
}

/// The recorder's top-lit rim, shared by every island shape in the editor:
/// a hairline that defines the silhouette on any backdrop, with a lit bevel
/// just inside it that fades toward the bottom.
struct EditorIslandEdge<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        ZStack {
            shape.strokeBorder(EditorTheme.islandOutline, lineWidth: 0.5)
            shape.inset(by: 0.5)
                .strokeBorder(LinearGradient(colors: [EditorTheme.topHighlight, EditorTheme.topHighlight.opacity(0)],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A capsule island for compact toolbars floating over the workspace.
struct EditorCapsuleIsland: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EditorTheme.cardGradient, in: Capsule(style: .continuous))
            .overlay { EditorIslandEdge(shape: Capsule(style: .continuous)) }
            .shadow(color: EditorTheme.contactShadow, radius: 1.5, y: 1)
            .shadow(color: EditorTheme.softShadow.opacity(0.75), radius: 14, y: 6)
            .shadow(color: EditorTheme.ambientShadow.opacity(0.8), radius: 30, y: 14)
    }
}

extension View {
    func editorCapsuleIsland() -> some View { modifier(EditorCapsuleIsland()) }
}

// MARK: - Page handoff

/// Timing shared by every content swap, including in-place mode changes
/// that fade one layer out and another in without changing identity.
enum EditorSwapTiming {
    // Crossfade, not a relay: the new content starts arriving at the same
    // moment the old one starts leaving, so there is never an empty frame.
    static var insertion: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34) }
    static var removal: Animation { .timingCurve(0.4, 0, 1, 1, duration: 0.18) }
    /// For a single in-place crossfade (no identity change).
    static var crossfade: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: 0.3) }
    /// Expanding geometry follows the same lively settle as the approved
    /// incoming pages. Interpolation remains shared across native layers.
    static var layout: Animation? {
        RecorderMotion.reduces ? nil : .spring(response: 0.4, dampingFraction: 0.84)
    }
}

/// Picks the side a swap drifts from, given an ordered list of options.
func editorSwapEdge<T: Equatable>(from old: T, to new: T, in order: [T], vertical: Bool = false) -> Edge {
    let forward = (order.firstIndex(of: new) ?? 0) >= (order.firstIndex(of: old) ?? 0)
    return vertical ? (forward ? .bottom : .top) : (forward ? .trailing : .leading)
}

/// The recorder's phase handoff, shared with Settings: the old page leaves
/// soft and quick; the next one drifts in from the side it was chosen on,
/// sharpening a beat after the island has started to change shape.
struct EditorPagePhase: ViewModifier {
    let hidden: Bool
    var drift: CGSize = .zero
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .offset(hidden ? drift : .zero)
    }
}

private struct EditorLabelPhase: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.9 : 1, anchor: .leading)
            .blur(radius: hidden ? 4 : 0)
    }
}

extension AnyTransition {
    static func editorPage(drift: CGSize) -> AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity.animation(.easeOut(duration: 0.16)) }
        return .asymmetric(
            insertion: .modifier(active: EditorPagePhase(hidden: true, drift: drift),
                                 identity: EditorPagePhase(hidden: false))
                .animation(EditorSwapTiming.insertion),
            removal: .modifier(active: EditorPagePhase(hidden: true), identity: EditorPagePhase(hidden: false))
                .animation(EditorSwapTiming.removal)
        )
    }

    /// The single content-swap transition of the editor. Every place a
    /// choice replaces content (rail tools, frame sub-pages, background
    /// sources, film/waveform, disclosure groups) uses this, drifting in
    /// from the edge of the option that was chosen.
    static func editorSwap(edge: Edge) -> AnyTransition {
        // Other in-place pages use the approved background-page handoff,
        // rather than replacing it with an unrelated crossfade.
        .editorSubpage(edge: edge)
    }

    static var editorLabel: AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: EditorLabelPhase(hidden: true), identity: EditorLabelPhase(hidden: false))
                .animation(.easeOut(duration: 0.24).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.08))
        )
    }
}

/// Content scrolling inside an island dissolves into its edges instead of
/// being cut by a rule.
struct EditorScrollEdgeFade: ViewModifier {
    var top: CGFloat = 10
    var bottom: CGFloat = 14
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
        }
    }
}

/// The settings track: a recessed channel holding one raised thumb.
enum EditorChoiceStyle {
    static let track = SettingsTheme.track
    static let thumb = SettingsTheme.thumb
    static let thumbShadow = SettingsTheme.thumbShadow
    static let hover = RecorderStyle.chrome.opacity(EditorStateWash.hover)
}

/// A static workspace stage, outside the rendered video. Never enters export
/// or a per-frame timeline: only size/appearance changes redraw it. A soft
/// pool of light sits behind the monitor, a fine dot grid dissolves toward
/// the edges, and the corners fall gently into shade.
struct EditorWorkspaceGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let reach = max(size.width, size.height)
            ZStack {
                RadialGradient(
                    colors: [EditorTheme.stageLight, EditorTheme.stageLight.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: reach * 0.62
                )
                Canvas { context, size in
                    var dots = Path()
                    for x in stride(from: CGFloat(12), to: size.width, by: 24) {
                        for y in stride(from: CGFloat(12), to: size.height, by: 24) {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                        }
                    }
                    context.fill(dots, with: .color(
                        colorScheme == .light ? .black.opacity(0.11) : .white.opacity(0.075)
                    ))
                }
                .mask {
                    RadialGradient(
                        colors: [.black, .black.opacity(0.35), .clear],
                        center: UnitPoint(x: 0.5, y: 0.45),
                        startRadius: reach * 0.08,
                        endRadius: reach * 0.6
                    )
                }
                RadialGradient(
                    colors: [EditorTheme.stageVignette.opacity(0), EditorTheme.stageVignette],
                    center: UnitPoint(x: 0.5, y: 0.45),
                    startRadius: reach * 0.36,
                    endRadius: reach * 0.85
                )
            }
            .drawingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension InspectorTab {
    /// Hand-drawn counterpart of `icon`, sharing the recorder's stroke.
    var lineIcon: AppLineIcon.Kind {
        switch self {
        case .frame: return .scene
        case .opening: return .opening
        case .zoom: return .zoom
        case .cursor: return .cursorMotion
        case .camera: return .camera
        case .audio: return .speaker
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
            let hovered = isHovered && isEnabled
            configuration.label
                .foregroundStyle(isPrimary ? EditorTheme.onAccent : EditorTheme.primaryText)
                .background {
                    if isPrimary {
                        Capsule()
                            .fill(EditorTheme.platinumGradient)
                            .overlay {
                                Capsule().inset(by: 0.5).strokeBorder(
                                    LinearGradient(colors: [EditorTheme.onAccent.opacity(0.28), .clear],
                                                   startPoint: .top, endPoint: .center),
                                    lineWidth: 1
                                )
                            }
                            .overlay { Capsule().fill(EditorTheme.onAccent.opacity(pressed ? 0.16 : hovered ? 0.06 : 0)) }
                            .shadow(color: EditorTheme.accentGlow.opacity(hovered ? 1 : 0.55), radius: hovered ? 12 : 7, y: 3)
                    } else {
                        Capsule()
                            .fill(EditorTheme.chrome(pressed ? EditorStateWash.pressed + 0.05 : hovered ? EditorStateWash.hover + 0.05 : 0.05))
                            .overlay { Capsule().strokeBorder(EditorTheme.chrome(hovered ? 0.08 : 0.045), lineWidth: 0.5) }
                    }
                }
                .contentShape(Capsule())
                .appKeyboardFocus(in: Capsule(), color: isPrimary ? EditorTheme.onAccent.opacity(0.65) : EditorTheme.chrome(0.40))
                .scaleEffect(pressed && !RecorderMotion.reduces ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.38)
                .onHover { isHovered = $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { isHovered = false } }
                .animation(SpringMotion.hover, value: isHovered)
                .animation(SpringMotion.snappy, value: pressed)
        }
    }
}

/// The workspace behind the canvas: an even field of small dots, no light
/// pools, vignette or gradient. Drawn once per size/appearance change.
struct EditorStageDots: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            let spacing: CGFloat = 18
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                }
            }
            context.fill(dots, with: .color(
                colorScheme == .light ? .black.opacity(0.13) : .white.opacity(0.09)
            ))
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
