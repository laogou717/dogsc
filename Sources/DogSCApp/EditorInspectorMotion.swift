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
    static var consoleReveal: Animation { .easeOut(duration: 0.16) }
}

/// Retired per-module stagger: modules arrive with their page as one piece.
extension View {
    func consoleReveal() -> some View { self }
}

enum EditorPageTiming {
    static let outgoing: Double = 0
}

private struct EditorSubpagePhase: ViewModifier {
    let offset: CGSize
    let opacity: Double

    func body(content: Content) -> some View {
        content.opacity(opacity).offset(offset)
    }
}

extension AnyTransition {
    /// A page replaces the previous one in place: the old page is gone in the
    /// same frame, the new one fades in with a 4 pt rise. Never two pages.
    static var consolePage: AnyTransition {
        guard !RecorderMotion.reduces else { return .identity }
        return .asymmetric(
            insertion: .modifier(
                active: EditorSubpagePhase(offset: CGSize(width: 0, height: 4), opacity: 0),
                identity: EditorSubpagePhase(offset: .zero, opacity: 1)
            )
            .animation(.easeOut(duration: 0.16)),
            // An identity removal still keeps the old page on screen until
            // the whole animation ends (the overlap); a zero-length removal
            // animation takes it out in the same frame.
            removal: .opacity.animation(.linear(duration: 0))
        )
    }

    /// Every page swap in the editor — the inspector stack, sub-tabs such as
    /// 壁纸/网格 — is one gesture: the old page is gone at once, the new one
    /// slides 12 pt in from the side it came from on the 240 ms panel curve.
    /// Two pages are never visible together.
    static func editorSubpage(edge: Edge) -> AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        let drift: CGSize = switch edge {
        case .leading: CGSize(width: -12, height: 0)
        case .trailing: CGSize(width: 12, height: 0)
        case .top: CGSize(width: 0, height: -12)
        case .bottom: CGSize(width: 0, height: 12)
        }
        return .asymmetric(
            insertion: .modifier(
                active: EditorSubpagePhase(offset: drift, opacity: 0),
                identity: EditorSubpagePhase(offset: .zero, opacity: 1)
            )
            .animation(SpringMotion.panel ?? .linear(duration: 0)),
            // An identity removal still keeps the old page on screen until
            // the whole animation ends (the overlap); a zero-length removal
            // animation takes it out in the same frame.
            removal: .opacity.animation(.linear(duration: 0))
        )
    }
}

extension View {
    /// Retired: the page transition alone carries arrival.
    func consolePageArrival() -> some View { self }
}

// MARK: - Page title

/// A static page title. The name changes in place; the tab bar already shows
/// where the user moved, so the title needs no motion of its own.
struct EditorRollingTitle: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        Text(text)
            .font(EditorTypography.pageTitle)
            .foregroundStyle(EditorTheme.primaryText)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
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
        EditorCanvasPill {
            Text(appLocalized(hud.label))
                .foregroundStyle(Color.white.opacity(0.7))
            Text(hud.value)
                .font(.appUI(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .opacity(hud.isActive ? 1 : 0)
        .animation(SpringMotion.fade, value: hud.isActive)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The one notice shape on the canvas: a small opaque dark plate, top
/// centre. Readouts, undo notes and the crop hint all use it.
struct EditorCanvasPill<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .font(.appUI(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(white: 0.1).opacity(0.86),
                        in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .fixedSize()
    }
}
