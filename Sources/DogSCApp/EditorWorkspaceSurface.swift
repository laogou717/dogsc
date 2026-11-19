import SwiftUI
import RecorderCore

/// Shared material for the independent tools surrounding the video: the
/// recorder's island. One solid shape, a machined top edge that fades toward
/// the bottom, and a soft cast shadow. Parameter groups inside stay flat.
struct EditorFloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = EditorInterfaceRadius.floating

    func body(content: Content) -> some View {
        content
            .background(EditorTheme.panelSurface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                EditorIslandEdge(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .shadow(color: EditorTheme.softShadow.opacity(0.6), radius: 12, y: 4)
    }
}

/// The recorder's top-lit rim, shared by every island shape in the editor:
/// a hairline that defines the silhouette on any backdrop, with a lit bevel
/// just inside it that fades toward the bottom.
struct EditorIslandEdge<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape.strokeBorder(EditorTheme.islandOutline, lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// A capsule island for compact toolbars floating over the workspace.
struct EditorCapsuleIsland: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EditorTheme.panelSurface, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
            .overlay { EditorIslandEdge(shape: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)) }
            .shadow(color: EditorTheme.softShadow.opacity(0.6), radius: 12, y: 4)
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
    /// For a single in-place crossfade (no identity change).
    static var crossfade: Animation { .easeOut(duration: 0.16) }
    /// Expanding geometry follows the same lively settle as the approved
    /// incoming pages. Interpolation remains shared across native layers.
    static var layout: Animation? {
        SpringMotion.standard
    }
}

/// Picks the side a swap drifts from, given an ordered list of options.
func editorSwapEdge<T: Equatable>(from old: T, to new: T, in order: [T], vertical: Bool = false) -> Edge {
    let forward = (order.firstIndex(of: new) ?? 0) >= (order.firstIndex(of: old) ?? 0)
    return vertical ? (forward ? .bottom : .top) : (forward ? .trailing : .leading)
}


extension AnyTransition {
    /// The single content-swap transition of the editor. Every place a
    /// choice replaces content (rail tools, frame sub-pages, background
    /// sources, film/waveform, disclosure groups) uses this, drifting in
    /// from the edge of the option that was chosen.
    static func editorSwap(edge: Edge) -> AnyTransition {
        // Other in-place pages use the approved background-page handoff,
        // rather than replacing it with an unrelated crossfade.
        .editorSubpage(edge: edge)
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
    static let track = EditorTheme.controlWell
    static let thumb = EditorTheme.segmentThumb
    static let thumbShadow = Color.black.opacity(0.12)
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

/// What the stage's shape is derived from. A morph runs only between two
/// inputs that differ in the authored ratio alone; entering or leaving crop
/// mode and the first measurement of the source snap, because those have
/// their own transitions (or none).
struct EditorStageAspectInput: Equatable {
    let ratio: CGFloat
    let isCropping: Bool
    let sourceSize: CGSize

    func morphs(to next: EditorStageAspectInput) -> Bool {
        !SpringMotion.reducesMotion
            && !isCropping && !next.isCropping
            && sourceSize == next.sourceSize
    }
}

/// The single, preview-only source of truth for the canvas shape while the
/// aspect ratio changes. Both the stage frame and the rendered canvas read
/// `value(at:)` for the same frame, so the picture reflows continuously in
/// both directions. It never touches the project or the undo history.
struct EditorCanvasAspectMorph: Equatable {
    let id = UUID()
    let from: CGFloat
    let to: CGFloat
    let start: Date

    static var duration: TimeInterval { SpringMotion.canvasMorphDuration }

    func progress(at date: Date) -> Double {
        let linear = min(max(date.timeIntervalSince(start) / Self.duration, 0), 1)
        return SpringMotion.canvasMorphCurve.value(at: linear)
    }

    /// Interpolates in log space so 16:9 → 9:16 passes through 1:1 at the
    /// midpoint and widening and narrowing feel the same speed.
    func value(at date: Date) -> CGFloat {
        let t = CGFloat(progress(at: date))
        guard t < 1 else { return to }
        return exp(log(from) + (log(to) - log(from)) * t)
    }

    /// The stage's displayed ratio for one frame. Before `onChange` has
    /// registered a new target the previous shape is held for that one
    /// frame, so the canvas never jumps to the new aspect first.
    static func displayed(
        target: EditorStageAspectInput,
        settled: EditorStageAspectInput?,
        morph: EditorCanvasAspectMorph?,
        at date: Date
    ) -> CGFloat {
        if let morph, morph.to == target.ratio, !target.isCropping { return morph.value(at: date) }
        guard let settled, settled.morphs(to: target) else { return target.ratio }
        return morph?.value(at: date) ?? settled.ratio
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
