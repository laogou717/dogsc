import SwiftUI

// MARK: - Page arrival

private struct ConsoleRevealKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for a moment after a page is switched to: its modules rise into
    /// place and its knobs sweep up to their values. Selecting something else
    /// inside the same page never replays it.
    var consoleReveal: Bool {
        get { self[ConsoleRevealKey.self] }
        set { self[ConsoleRevealKey.self] = newValue }
    }
}

extension Animation {
    /// A little life on arrival, settled well within half a second.
    static var consoleReveal: Animation { .spring(response: 0.62, dampingFraction: 0.82) }
}

/// Modules assemble when a page arrives: each rises from below, later ones
/// a beat after earlier ones (ordered by where they sit in the page).
private struct ConsoleRevealModifier: ViewModifier {
    @Environment(\.consoleReveal) private var reveals
    @State private var shown = false
    @State private var minY: CGFloat = 0

    func body(content: Content) -> some View {
        let hidden = reveals && !shown && !RecorderMotion.reduces
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 40 : 0)
            .scaleEffect(hidden ? 0.96 : 1, anchor: .top)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(EditorConsole.scrollSpace)).minY
            } action: { minY = $0 }
            .onAppear {
                guard reveals, !RecorderMotion.reduces else { shown = true; return }
                DispatchQueue.main.async {
                    // Start once the outgoing page has left (see consolePage),
                    // so the two pages never show through each other.
                    let delay = EditorPageTiming.outgoing + Double(min(max(minY, 0), 900)) / 900 * 0.3
                    withAnimation(Animation.consoleReveal.delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    func consoleReveal() -> some View { modifier(ConsoleRevealModifier()) }
}

/// One clock for a page change: the outgoing page is fully gone before the
/// incoming one starts to appear. Overlapping two half-transparent pages
/// read as a rendering fault, not as motion.
enum EditorPageTiming {
    static let outgoing: Double = 0.14
}

/// The outgoing page drops away: a short accelerating fall and fade.
private struct ConsoleDropModifier: ViewModifier {
    let dropped: Bool

    func body(content: Content) -> some View {
        content
            .opacity(dropped ? 0 : 1)
            .offset(y: dropped ? 26 : 0)
            .scaleEffect(dropped ? 0.985 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var consolePage: AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        return .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: ConsoleDropModifier(dropped: true),
                identity: ConsoleDropModifier(dropped: false)
            )
            .animation(.timingCurve(0.5, 0, 0.9, 0.5, duration: EditorPageTiming.outgoing))
        )
    }
}

/// A sub-page inside a section (wallpaper / grid / motion / custom): the
/// outgoing one slides out toward the side it came from and is gone before
/// the incoming one slides in from the chosen side and settles with a little
/// spring — the same "leave first, then arrive" clock as a page change.
private struct EditorSubpagePhase: ViewModifier {
    let offset: CGSize
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).offset(offset).scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static func editorSubpage(edge: Edge) -> AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        let incoming: CGSize
        switch edge {
        case .leading: incoming = CGSize(width: -26, height: 0)
        case .trailing: incoming = CGSize(width: 26, height: 0)
        case .top: incoming = CGSize(width: 0, height: -14)
        case .bottom: incoming = CGSize(width: 0, height: 14)
        }
        let outgoing = CGSize(width: -incoming.width * 18 / 26,
                              height: -incoming.height * 18 / 26)
        return .asymmetric(
            insertion: .modifier(
                active: EditorSubpagePhase(offset: incoming, opacity: 0, scale: 0.985),
                identity: EditorSubpagePhase(offset: .zero, opacity: 1, scale: 1)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.84).delay(EditorPageTiming.outgoing - 0.02)),
            removal: .modifier(
                active: EditorSubpagePhase(offset: outgoing, opacity: 0, scale: 0.985),
                identity: EditorSubpagePhase(offset: .zero, opacity: 1, scale: 1)
            )
            .animation(.timingCurve(0.5, 0, 0.9, 0.5, duration: EditorPageTiming.outgoing))
        )
    }
}

/// The incoming page as a whole waits for the outgoing one, then rises in.
/// Loose items (notes, buttons) arrive with it; sections additionally
/// assemble one after another when the task itself changed.
private struct ConsolePageArrival: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        let hidden = !shown && !RecorderMotion.reduces
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 14 : 0)
            .onAppear {
                guard !RecorderMotion.reduces else { shown = true; return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86).delay(EditorPageTiming.outgoing - 0.02)) {
                    shown = true
                }
            }
    }
}

extension View {
    func consolePageArrival() -> some View { modifier(ConsolePageArrival()) }
}

// MARK: - Rolling title

/// A page name whose characters roll up and out, then the new ones roll in,
/// one after another.
struct EditorRollingTitle: View {
    let text: String
    var size: CGFloat = 38

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                RollingGlyph(character: String(character), index: index, size: size)
            }
        }
        .frame(height: size * 1.22, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct RollingGlyph: View {
    let character: String
    let index: Int
    let size: CGFloat
    @State private var shown: String
    @State private var previous: String?
    @State private var progress: CGFloat = 1
    @State private var revision = 0

    init(character: String, index: Int, size: CGFloat) {
        self.character = character
        self.index = index
        self.size = size
        _shown = State(initialValue: character)
    }

    var body: some View {
        let travel = size * 1.1
        // Only the current glyph determines its advance. A transparent old
        // glyph must not keep a wider Chinese character's layout in English.
        glyph(shown).opacity(0)
            .overlay {
                ZStack {
                    if let previous {
                        glyph(previous)
                            .offset(y: -travel * progress)
                            .opacity(Double(max(0, 1.0 - progress * 3.0)))
                            .blur(radius: 6.0 * progress)
                    }
                    glyph(shown)
                        .offset(y: travel * (1.0 - progress))
                        .opacity(Double(min(1.0, progress * 2.4)))
                        .blur(radius: 8.0 * (1.0 - min(progress, 1.0)))
                }
            }
        .onChange(of: character) { old, new in
            guard old != new else { return }
            revision += 1
            let currentRevision = revision
            if RecorderMotion.reduces {
                shown = new
                previous = nil
                progress = 1
                return
            }
            previous = old
            shown = new
            progress = 0
            withAnimation(.spring(response: 0.66, dampingFraction: 0.74).delay(0.04 + Double(index) * 0.07), completionCriteria: .logicallyComplete) {
                progress = 1
            } completion: {
                guard revision == currentRevision else { return }
                previous = nil
            }
        }
    }

    private func glyph(_ value: String) -> some View {
        Text(value)
            .font(.appUI(size: size, weight: .semibold))
            .tracking(-size * 0.03)
            .foregroundStyle(EditorTheme.primaryText)
            .fixedSize()
    }
}

// MARK: - Live readout on the canvas

/// While a knob, slider or curve node is being moved, the canvas itself says
/// what is changing: the frame corners draw in and a small readout appears.
/// The inspector controls post here; the stage draws it.
@MainActor
final class EditorConsoleHUD: ObservableObject {
    static let shared = EditorConsoleHUD()

    @Published private(set) var label = ""
    @Published private(set) var value = ""
    @Published private(set) var isActive = false
    private var hideTask: Task<Void, Never>?

    func show(title: String, text: String) { show(label: title, value: text) }

    func show(label: String, value: String) {
        self.label = label
        self.value = value
        isActive = true
        scheduleHide(after: 1.6)
    }

    /// The gesture ended: keep the readout a moment so the final value can
    /// be read, then let it go.
    func release() { scheduleHide(after: 0.9) }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }
}

struct EditorConsoleHUDOverlay: View {
    @ObservedObject private var hud = EditorConsoleHUD.shared
    var color: Color = .white

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = hud.isActive ? 20 : 8
            ZStack(alignment: .bottomLeading) {
                ForEach(0..<4, id: \.self) { corner in
                    Bracket(corner: corner)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .position(
                            x: corner % 2 == 0 ? inset + 9 : proxy.size.width - inset - 9,
                            y: corner < 2 ? inset + 9 : proxy.size.height - inset - 9
                        )
                }
                HStack(spacing: 7) {
                    Text(appLocalized(hud.label))
                        .font(.appUI(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.78))
                    Text(hud.value)
                        .font(.appUI(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.black.opacity(0.58), in: Capsule(style: .continuous))
                .padding(.leading, inset + 4)
                .padding(.bottom, inset + 2)
                .opacity(hud.isActive ? 1 : 0)
                .offset(y: hud.isActive ? 0 : 6)
            }
            .opacity(hud.isActive ? 1 : 0)
            .animation(RecorderMotion.reduces ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: hud.isActive)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Bracket: Shape {
        let corner: Int
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let r: CGFloat = 5
            switch corner {
            case 0:
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
                path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            case 1:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
                path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            case 2:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
                path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            default:
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
                path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            return path
        }
    }
}
