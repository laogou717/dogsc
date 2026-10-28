import AppKit
import RecorderCore
import SwiftUI

// Inspector pages open with a picture of what they control, painted from the
// project's own paused frame on the user's desktop, like the settings pages.
// Artwork is decorative: it never takes hits or enters the accessibility tree.

/// A small studio backdrop the page stages its picture on. It is neutral on
/// purpose: the user's own desktop photo often *is* the recording, and a
/// window of the video floating on the same image read as a cropped slice.
/// A soft lit gradient with a fine dot grid matches the workspace stage.
struct EditorInspectorStage<Content: View>: View {
    var height: CGFloat = 148
    var showsMenuBar = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous)
        ZStack {
            LinearGradient(colors: [EditorStageBackdrop.top, EditorStageBackdrop.bottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [EditorStageBackdrop.glow, EditorStageBackdrop.glow.opacity(0)],
                           center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 220)
            Canvas { context, size in
                var dots = Path()
                for x in stride(from: CGFloat(8), to: size.width, by: 14) {
                    for y in stride(from: CGFloat(8), to: size.height, by: 14) {
                        dots.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
                context.fill(dots, with: .color(EditorStageBackdrop.dot))
            }
            content()
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(EditorTheme.chrome(0.05), lineWidth: 0.5) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum EditorStageBackdrop {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: RecorderStyle.adaptive(light, dark))
    }
    static let top = adaptive(NSColor(calibratedRed: 0.945, green: 0.949, blue: 0.960, alpha: 1),
                              NSColor(calibratedRed: 0.135, green: 0.140, blue: 0.156, alpha: 1))
    static let bottom = adaptive(NSColor(calibratedRed: 0.886, green: 0.893, blue: 0.910, alpha: 1),
                                 NSColor(calibratedRed: 0.090, green: 0.093, blue: 0.104, alpha: 1))
    static let glow = adaptive(NSColor(calibratedWhite: 1, alpha: 0.8),
                               NSColor(calibratedWhite: 1, alpha: 0.06))
    static let dot = adaptive(NSColor(calibratedWhite: 0, alpha: 0.08),
                              NSColor(calibratedWhite: 1, alpha: 0.06))
}

/// The paused screen frame as a floating window, or a calm sheet before a
/// frame is available.
struct EditorStageScreen: View {
    let image: NSImage?
    var radius: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            Color(white: 0.96)
            if let image {
                Color.clear.overlay {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([0.7, 0.9, 0.5], id: \.self) { width in
                        GeometryReader { proxy in
                            Capsule().fill(Color.black.opacity(0.1))
                                .frame(width: proxy.size.width * width, height: 4)
                        }
                        .frame(height: 4)
                    }
                }
                .padding(12)
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
    }
}

/// The screen keeps the video's own proportions and fits inside a box of
/// the stage's fractions on both axes, so any frame — wide or tall — shows
/// as a floating window on the desktop instead of a cropped slice.
func editorStageScreenSize(in stage: CGSize, image: NSImage?, widthFraction: CGFloat, heightLimit: CGFloat = 0.8) -> CGSize {
    let box = CGSize(width: stage.width * widthFraction, height: stage.height * heightLimit)
    guard let size = image?.size, size.width > 1, size.height > 1 else {
        let width = min(box.width, box.height * 16.0 / 9.0)
        return CGSize(width: width, height: width * 9.0 / 16.0)
    }
    let scale = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
}

// MARK: - Opening

/// The opening choreography, replayed on the stage with the project's own
/// order, stagger, duration and curve. Disabled openings stand still.
struct EditorOpeningStage: View {
    let sequence: OpeningSequence
    let screenImage: NSImage?
    let elements: [OpeningSequenceElement]
    var isPaused = false
    var height: CGFloat = 158
    @Environment(\.editorIsActive) private var isEditorActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    private var animates: Bool {
        sequence.isEnabled && isEditorActive && !reduceMotion && !isPaused
    }

    /// Long openings are compressed so the loop stays readable.
    private var playScale: Double { min(1, 2.4 / max(sequence.duration, 0.01)) }
    private var cycle: Double { 0.5 + sequence.duration * playScale + 1.3 }

    var body: some View {
        EditorInspectorStage(height: height) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
                let elapsed = animates
                    ? timeline.date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle) - 0.5
                    : .infinity
                scene(time: elapsed / playScale)
            }
        }
        .saturation(sequence.isEnabled ? 1 : 0.35)
        .overlay(alignment: .bottomLeading) {
            if !sequence.isEnabled {
                Text(appLocalized("未启用"))
                    .font(.appUI(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                    .accessibilityHidden(true)
            }
        }
        .animation(SpringMotion.hover, value: sequence.isEnabled)
        .onChange(of: sequence) { _, _ in startDate = Date() }
    }

    private func scene(time: Double) -> some View {
        let included = elements.filter { sequence.includedElements.contains($0) }
        let stagger = min(sequence.stagger, sequence.maximumStagger(for: included.count))
        let elementDuration = max(
            sequence.duration - stagger * Double(max(included.count - 1, 0)),
            OpeningSequence.minimumElementDuration
        )
        func progress(_ element: OpeningSequenceElement) -> Double {
            guard sequence.isEnabled, let slot = included.firstIndex(of: element) else { return 1 }
            let start = Double(slot) * stagger
            return ElementMotionPreview.progress((time - start) / elementDuration, curve: sequence.motionCurve)
        }
        return GeometryReader { proxy in
            let size = proxy.size
            let screenSize = editorStageScreenSize(in: size, image: screenImage, widthFraction: 0.66, heightLimit: 0.64)
            ZStack {
                EditorStageScreen(image: screenImage)
                    .frame(width: screenSize.width, height: screenSize.height)
                    .modifier(OpeningEntrance(progress: progress(.screen), preset: sequence.preset, side: -1))
                    .position(x: size.width / 2, y: size.height * 0.54)

                if elements.contains(.stickers) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.4), Color(red: 0.98, green: 0.5, blue: 0.45)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay { AppLineIcon(kind: .sparkle, size: 14).foregroundStyle(.white) }
                        .frame(width: 38, height: 30)
                        .rotationEffect(.degrees(-6))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .modifier(OpeningEntrance(progress: progress(.stickers), preset: sequence.preset, side: -1))
                        .position(x: size.width * 0.2 + 4, y: size.height * 0.24)
                }

                if elements.contains(.camera) {
                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                        .overlay { AppLineIcon(kind: .person, size: 18).foregroundStyle(.white.opacity(0.9)) }
                        .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                        .frame(width: 42, height: 42)
                        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                        .modifier(OpeningEntrance(progress: progress(.camera), preset: sequence.preset, side: 1))
                        .position(x: size.width * 0.8, y: size.height * 0.72)
                }
            }
        }
    }
}

/// Mirrors the renderer's curve language for the preview only.
enum ElementMotionPreview {
    static func progress(_ linear: Double, curve: ElementMotionCurve) -> Double {
        let x = min(max(linear.isFinite ? linear : 1, 0), 1)
        switch curve {
        case .smooth: return x * x * x * (x * (x * 6 - 15) + 10)
        case .swift: return 1 - pow(1 - x, 4)
        case .gentle: return 1 - pow(1 - x, 3)
        }
    }
}

private struct OpeningEntrance: ViewModifier {
    let progress: Double
    let preset: OpeningSequencePreset
    let side: CGFloat

    func body(content: Content) -> some View {
        let remaining = 1 - progress
        switch preset {
        case .converge:
            content
                .scaleEffect(0.78 + 0.22 * progress)
                .opacity(progress)
        case .sideSlide:
            content
                .offset(x: side * 70 * remaining)
                .opacity(progress)
        case .light3D:
            content
                .rotation3DEffect(.degrees(32 * remaining), axis: (x: 1, y: side * 0.4, z: 0), perspective: 0.6)
                .scaleEffect(0.9 + 0.1 * progress)
                .opacity(progress)
        }
    }
}

// MARK: - Zoom

/// The zoom track explained by doing it: a focus point glides across the
/// frame, the viewfinder arms close around it, and the picture settles into
/// a closer view — then drifts on to the next subject. The same grammar the
/// export renderer speaks.
struct EditorZoomStage: View {
    let screenImage: NSImage?
    var height: CGFloat = 136
    @Environment(\.editorIsActive) private var isEditorActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    private var animates: Bool { isEditorActive && !reduceMotion }
    private static let cycle: Double = 3.6
    /// Focus points in the screen window's own unit space.
    private static let focusA = UnitPoint(x: 0.63, y: 0.38)
    private static let focusB = UnitPoint(x: 0.36, y: 0.62)

    /// Smoothstep between two times.
    private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(max((t - a) / (b - a), 0), 1)
        return x * x * (3 - 2 * x)
    }

    var body: some View {
        EditorInspectorStage(height: height) {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
                    let elapsed = animates ? timeline.date.timeIntervalSince(startDate) : 0
                    let cycleIndex = Int(floor(elapsed / Self.cycle))
                    let t = elapsed.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
                    scene(t: t, cycle: cycleIndex, in: proxy.size)
                }
            }
        }
    }

    @ViewBuilder
    private func scene(t: Double, cycle: Int, in stage: CGSize) -> some View {
        // Each cycle zooms one focus in, releases, travels, then zooms the next.
        let from = cycle.isMultiple(of: 2) ? Self.focusA : Self.focusB
        let to = cycle.isMultiple(of: 2) ? Self.focusB : Self.focusA
        let zoom = min(max(1 - ramp(t, 0.14, 0.34) + ramp(t, 0.58, 0.84), 0), 1)
        let travel = ramp(t, 0.32, 0.62)
        let focus = UnitPoint(
            x: from.x + (to.x - from.x) * travel,
            y: from.y + (to.y - from.y) * travel
        )
        let screen = editorStageScreenSize(in: stage, image: screenImage, widthFraction: 0.6, heightLimit: 0.7)
        let focusPoint = CGPoint(
            x: (stage.width - screen.width) / 2 + focus.x * screen.width,
            y: (stage.height - screen.height) / 2 + focus.y * screen.height
        )
        ZStack {
            EditorStageScreen(image: screenImage)
                .frame(width: screen.width, height: screen.height)
                .overlay {
                    CaptureViewfinder(inset: 16 - 10 * zoom, arm: 10 + 6 * zoom, radius: 6)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .shadow(color: .black.opacity(0.35), radius: 2)
                }
                .scaleEffect(1 + 0.2 * zoom, anchor: focus)
                .position(x: stage.width / 2, y: stage.height / 2)

            // The focus dot: visible while the camera travels, resting inside
            // the arms once the zoom has settled.
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
                .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 3) }
                .shadow(color: .black.opacity(0.35), radius: 2)
                .opacity(min(travel, 1 - zoom) > 0 ? 1 : 0.55)
                .position(focusPoint)
        }
    }
}

// MARK: - Screen 3D

/// What the 屏幕 3D track does, shown once: the screen window swings through
/// a slow pendulum of perspective tilt and drift, like a card being looked
/// at from slightly different seats.
struct EditorScreenMotionStage: View {
    let screenImage: NSImage?
    var height: CGFloat = 170
    @Environment(\.editorIsActive) private var isEditorActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    private var animates: Bool { isEditorActive && !reduceMotion }
    private static let cycle: Double = 4.8

    var body: some View {
        EditorInspectorStage(height: height) {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
                    let elapsed = animates ? timeline.date.timeIntervalSince(startDate) : 0
                    scene(phase: (elapsed / Self.cycle).truncatingRemainder(dividingBy: 1), in: proxy.size)
                }
            }
        }
    }

    @ViewBuilder
    private func scene(phase: Double, in stage: CGSize) -> some View {
        let wobble = sin(phase * 2 * .pi)
        let settle = cos(phase * 2 * .pi)
        let screen = editorStageScreenSize(
            in: stage, image: screenImage, widthFraction: 0.6, heightLimit: 0.68
        )
        EditorStageScreen(image: screenImage)
            .frame(width: screen.width, height: screen.height)
            .rotation3DEffect(
                .degrees(wobble * 5),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center,
                perspective: 0.55
            )
            .rotation3DEffect(
                .degrees(wobble * 10),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.55
            )
            .offset(x: wobble * 16)
            .shadow(color: .black.opacity(0.30), radius: 12, x: -wobble * 10, y: 8)
            .scaleEffect(1 + 0.04 * settle)
            .position(x: stage.width / 2, y: stage.height / 2)
    }
}

// MARK: - Segment map

/// One thin film strip: every primary segment in output order, the edited
/// one raised and lit. Reading "which clip is this" takes a glance instead
/// of a number.
struct EditorSegmentMap: View {
    @Environment(\.consolePalette) private var palette
    let segments: [ResolvedRecordingSegment]
    let selectedIndex: Int
    let totalDuration: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let total = max(totalDuration, 0.001)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(EditorTheme.chrome(0.06))
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let x = proxy.size.width * CGFloat(segment.outputStart / total)
                    let width = max(
                        proxy.size.width * CGFloat(segment.outputDuration / total) - 2,
                        3
                    )
                    Capsule()
                        .fill(
                            index == selectedIndex
                                ? (palette?.fill ?? EditorTheme.platinumAccent)
                                : EditorTheme.chrome(0.17)
                        )
                        .frame(
                            width: width,
                            height: index == selectedIndex ? 12 : 7
                        )
                        .shadow(
                            color: index == selectedIndex
                                ? (palette?.fill ?? EditorTheme.platinumAccent).opacity(0.35)
                                : .clear,
                            radius: 3
                        )
                        .position(
                            x: x + width / 2 + 1,
                            y: proxy.size.height / 2
                        )
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Canvas layout

/// The canvas settings drawn, not listed: the project's frame sits inside
/// the stage at the live margin, corner radius, border and shadow, so a
/// slider drag repaints the picture instead of a number.
struct EditorCanvasLayoutStage: View {
    let image: NSImage?
    let padding: Double
    let cornerRadius: Double
    let borderWidth: Double
    let shadowStrength: Double
    var height: CGFloat = 150

    var body: some View {
        EditorInspectorStage(height: height) {
            GeometryReader { proxy in
                let padNorm: CGFloat = CGFloat(min(max(padding, 0), 360) / 360)
                let margin: CGFloat = min(
                    16 + padNorm * (proxy.size.height * 0.26),
                    min(proxy.size.width, proxy.size.height) * 0.42
                )
                let screen = editorStageScreenSize(
                    in: CGSize(width: proxy.size.width - margin * 2, height: proxy.size.height - margin * 2),
                    image: image, widthFraction: 1, heightLimit: 1
                )
                let radNorm: CGFloat = CGFloat(min(max(cornerRadius, 0), 160) / 160)
                let screenRadius: CGFloat = 4 + radNorm * 8
                let strokeW: CGFloat = CGFloat(min(max(borderWidth, 0), 40)) * 0.35
                let shadowOpacity: Double = 0.2 + 0.35 * min(max(shadowStrength, 0), 1)
                EditorStageScreen(
                    image: image,
                    radius: screenRadius
                )
                .overlay {
                    RoundedRectangle(cornerRadius: screenRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: strokeW)
                }
                .shadow(color: .black.opacity(shadowOpacity), radius: 10, y: 5)
                .frame(width: screen.width, height: screen.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2 + 3)
            }
            .padding(.top, 6)
        }
        .animation(SpringMotion.settle, value: padding)
        .animation(SpringMotion.settle, value: cornerRadius)
        .animation(SpringMotion.settle, value: borderWidth)
        .animation(SpringMotion.settle, value: shadowStrength)
    }
}
