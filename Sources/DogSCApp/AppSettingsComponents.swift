import AppKit
import SwiftUI

// MARK: - Settings palette
// Settings is built from the recorder's own parts: one solid island, quiet
// glyphs, a recessed track with a raised thumb, and the same springs.

enum SettingsTheme {
    static let canvasBackground = Color(nsColor: RecorderStyle.canvasNSColor)
    static let textPrimary = RecorderStyle.ink
    static let textSecondary = RecorderStyle.muted
    static let textFaint = RecorderStyle.faint
    /// A recessed channel for choices and menus.
    static let track = RecorderStyle.chrome.opacity(0.06)
    /// The raised thumb inside a track: paper on Aqua, a lit slab on Dark Aqua.
    static let thumb = Color(nsColor: RecorderStyle.adaptive(.white, .white.withAlphaComponent(0.13)))
    static let thumbShadow = Color(nsColor: RecorderStyle.adaptive(
        .black.withAlphaComponent(0.12), .black.withAlphaComponent(0.32)))
    static let hover = RecorderStyle.chrome.opacity(0.045)
    static let mint = RecorderStyle.mint
    static let recording = RecorderStyle.destructiveInk
    static let amber = RecorderStyle.amberInk
}

enum SettingsMotion {
    static var reduces: Bool { RecorderMotion.reduces }
    static var springMorph: Animation? { RecorderMotion.settle }
    static var springSnappy: Animation? { RecorderMotion.quick }
    static var quick: Animation { .easeOut(duration: 0.16) }
}

enum SettingsLayout {
    static let islandRadius: CGFloat = 26
    static let islandInset: CGFloat = 8
    /// Tiles sit 14 pt inside the island, so 18 pt keeps them concentric.
    static let tileRadius: CGFloat = 18
}

// MARK: - Page parts

/// A small caption above a cluster of tiles.
struct SettingsCaption: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(appLocalized(key))
            .font(.appUI(size: 11.5, weight: .medium))
            .foregroundStyle(SettingsTheme.textFaint)
            .padding(.leading, 8)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .consoleReveal()
    }
}

/// The slab every page is composed of: a faint fill on the island, no
/// outline, no shadow. Tinted when it carries a state worth noticing.
struct SettingsTile: ViewModifier {
    var tint: Color? = nil
    var hovered = false
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous)
                .fill(tint.map { $0.opacity(hovered ? 0.15 : 0.11) }
                      ?? RecorderStyle.chrome.opacity(hovered ? 0.075 : 0.045))
        }
        .consoleReveal()
    }
}

extension View {
    func settingsTile(tint: Color? = nil, hovered: Bool = false) -> some View {
        modifier(SettingsTile(tint: tint, hovered: hovered))
    }
}

// MARK: - Island

/// The island keeps its existing height morph; page content shares the
/// editor's short drop, delayed rise and staggered module arrival.
struct SettingsIsland<Content: View>: View {
    let pageID: AppSettingsSection
    let maxHeight: CGFloat
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    private static var topAnchor: String { "settings.island.top" }

    var body: some View {
        let height = min(contentHeight, maxHeight)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    ZStack(alignment: .top) {
                        content()
                            .padding(SettingsLayout.islandInset)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { measured in
                                guard measured > 0 else { return }
                                if contentHeight == 0 {
                                    // The first page establishes the island
                                    // without growing from an invented size.
                                    var initial = Transaction(animation: nil)
                                    initial.disablesAnimations = true
                                    withTransaction(initial) { contentHeight = measured }
                                } else {
                                    contentHeight = measured
                                }
                            }
                            .coordinateSpace(name: EditorConsole.scrollSpace)
                            .environment(\.consoleReveal, true)
                            .consolePageArrival()
                            .id(pageID)
                            .transition(.consolePage)
                    }
                }
            }
            .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
            .frame(height: max(height, 1))
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.islandRadius, style: .continuous))
            .background { RecorderSurfaceShape(radius: SettingsLayout.islandRadius, castsShadow: true) }
            .opacity(contentHeight == 0 ? 0 : 1)
            .animation(RecorderMotion.morph, value: height)
            .onChange(of: pageID) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
            .onChange(of: height, initial: true) { _, value in
                if value > 0 { onHeightChange(value) }
            }
        }
    }
}

/// The navigation label arrives with the selection and steps aside quickly.
private struct SettingsLabelPhase: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.86 : 1, anchor: .leading)
            .blur(radius: hidden ? 4 : 0)
    }
}

extension AnyTransition {
    static var settingsLabel: AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: SettingsLabelPhase(hidden: true), identity: SettingsLabelPhase(hidden: false))
                .animation(.easeOut(duration: 0.24).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.08))
        )
    }
}

// MARK: - Ringing bell

/// The notification bell swings when the sample plays and dims when the
/// sound is off, matching the input glyphs' on/off language.
struct SettingsRingingBell: View {
    let ringing: Bool
    let enabled: Bool
    var size: CGFloat = 18

    var body: some View {
        AppLineIcon(kind: .bell, size: size)
            .foregroundStyle(enabled ? SettingsTheme.textSecondary : SettingsTheme.textFaint)
            .rotationEffect(.degrees(ringing && !RecorderMotion.reduces ? 15 : 0), anchor: .top)
            .animation(ringing ? .easeInOut(duration: 0.12).repeatCount(4, autoreverses: true) : .default, value: ringing)
            .animation(RecorderMotion.fade, value: enabled)
            .accessibilityHidden(true)
    }
}

// MARK: - Sound preview

/// A round play action. While the sample sounds, a ring opens outward the
/// way the microphone ring opens with live input.
struct SettingsSoundPreviewButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppLineIcon(kind: .speaker, size: 14)
                .foregroundStyle(isPlaying ? RecorderStyle.positiveInk : SettingsTheme.textPrimary)
                .modifier(SettingsActivationFeedback(trigger: isPlaying ? 1 : 0))
        }
        .buttonStyle(SettingsCircleButtonStyle())
        .overlay {
            SettingsRipple(active: isPlaying)
                .allowsHitTesting(false)
        }
        .help(appLocalized("试听"))
        .accessibilityLabel(appLocalized("试听导出完成提示音"))
    }
}

private struct SettingsRipple: View {
    let active: Bool
    var body: some View {
        Circle()
            .strokeBorder(RecorderStyle.positiveInk, lineWidth: 1.5)
            .frame(width: 30, height: 30)
            .scaleEffect(active && !RecorderMotion.reduces ? 1.6 : 1)
            .opacity(active ? 0.8 : 0)
            .animation(.easeOut(duration: 0.7), value: active)
            .accessibilityHidden(true)
    }
}

// MARK: - Permission summary

/// How many of the four capture permissions are granted, as a ring that
/// fills on arrival. Amber until screen recording and accessibility are on.
struct SettingsPermissionSummary: View {
    let granted: Int
    let total: Int
    let requiredReady: Bool
    @State private var arrived = false

    var body: some View {
        let tint = requiredReady ? RecorderStyle.positiveInk : SettingsTheme.amber
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(RecorderStyle.chrome.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: arrived ? CGFloat(granted) / CGFloat(max(total, 1)) : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(granted)/\(total)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            .frame(width: 46, height: 46)

            Text(appLocalized(requiredReady ? "录制所需权限已就绪" : "屏幕录制或辅助功能尚未就绪，录制可能缺少画面或光标。"))
                .font(.appUI(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(requiredReady ? 0.08 : 0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(RecorderMotion.morph, value: granted)
        .animation(RecorderMotion.fade, value: requiredReady)
        .onAppear {
            withAnimation((RecorderMotion.morph ?? .easeOut(duration: 0.2)).delay(0.18)) { arrived = true }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toggle

/// A green-when-live switch. While held, the knob stretches toward the side
/// it is about to travel to, then settles on the recorder spring.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    var accessibilityLabel: String = ""
    var accessibilityHint: String = ""

    var body: some View {
        Button {
            withAnimation(RecorderMotion.settle) { isOn.toggle() }
        } label: {
            Color.clear.frame(width: 42, height: 24)
        }
        .buttonStyle(SwitchStyle(isOn: isOn))
        .appButtonKeyboardFocus(in: Capsule(style: .continuous))
        .accessibilityLabel(appLocalized(accessibilityLabel))
        .accessibilityValue(appLocalized(isOn ? "开关状态 · 开启" : "开关状态 · 关闭"))
        .accessibilityHint(appLocalized(accessibilityHint))
    }

    private struct SwitchStyle: ButtonStyle {
        let isOn: Bool
        func makeBody(configuration: Configuration) -> some View {
            SettingsSwitchTrack(isOn: isOn, pressed: configuration.isPressed)
        }
    }
}

/// The switch artwork, shared by the standalone toggle and input tiles.
struct SettingsSwitchTrack: View {
    let isOn: Bool
    let pressed: Bool
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let held = pressed && isEnabled && !RecorderMotion.reduces
        let knob: CGFloat = compact ? 16 : 20
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? RecorderStyle.positiveInk : RecorderStyle.chrome.opacity(hovered && isEnabled ? 0.17 : 0.12))
            Capsule(style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.22), radius: 2.5, y: 1)
                .frame(width: held ? knob + knob / 4 : knob, height: knob)
                .padding(2)
        }
        .frame(width: compact ? 34 : 42, height: knob + 4)
        .contentShape(Capsule(style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .animation(RecorderMotion.settle, value: isOn)
        .animation(held ? .easeOut(duration: 0.1) : RecorderMotion.quick, value: held)
        .animation(RecorderMotion.fade, value: hovered)
    }
}

// MARK: - Pill Button Style

struct SettingsPillButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> Pill {
        Pill(configuration: configuration, prominent: prominent, compact: compact)
    }

    struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .font(.appUI(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(prominent ? RecorderStyle.onPrimary : SettingsTheme.textPrimary)
                .padding(.horizontal, compact ? 11 : 14)
                .frame(height: compact ? 26 : 30)
                .background(background(pressed: pressed), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
                .appKeyboardFocus(in: Capsule(style: .continuous))
                .scaleEffect(pressed && !SettingsMotion.reduces ? 0.95 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(SettingsMotion.springSnappy, value: pressed)
                .animation(SettingsMotion.quick, value: hovered)
        }

        private func background(pressed: Bool) -> Color {
            if prominent {
                return RecorderStyle.primaryFill.opacity(pressed ? 0.8 : hovered ? 0.92 : 0.98)
            }
            return RecorderStyle.chrome.opacity(pressed ? 0.15 : hovered && isEnabled ? 0.11 : 0.07)
        }
    }
}

/// A round glyph action that sits beside pill buttons, e.g. reveal in Finder.
struct SettingsCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .foregroundStyle(hovered ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(RecorderStyle.chrome.opacity(pressed ? 0.15 : hovered ? 0.11 : 0.07), in: Circle())
                .contentShape(Circle())
                .appKeyboardFocus(in: Circle())
                .scaleEffect(pressed && !SettingsMotion.reduces ? 0.9 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(SettingsMotion.springSnappy, value: pressed)
                .animation(SettingsMotion.quick, value: hovered)
        }
    }
}

struct SettingsPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, scale: scale)
    }

    struct Body: View {
        let configuration: Configuration
        let scale: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && isEnabled && !SettingsMotion.reduces ? scale : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(SettingsMotion.springSnappy, value: configuration.isPressed)
        }
    }
}

// MARK: - Selection and press motion

/// Playback-state feedback for the sound preview action. Choice controls use
/// the native press tracking below instead of this activation-only response.
struct SettingsActivationFeedback: ViewModifier {
    let trigger: Int
    func body(content: Content) -> some View {
        content
            .scaleEffect(trigger > 0 && !RecorderMotion.reduces ? 0.95 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.5), value: trigger)
    }
}

/// One persistent thumb moves between stable hit targets. AppStorage
/// updates get an explicit animation rather than depending on the transaction
/// that happened to deliver the preference notification.
private struct SettingsSelectionTrack: View {
    let index: Int
    let count: Int
    var spacing: CGFloat = 2
    var radius: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, (geometry.size.width - CGFloat(count - 1) * spacing) / CGFloat(max(1, count)))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(SettingsTheme.thumb)
                .shadow(color: SettingsTheme.thumbShadow, radius: 3, y: 1)
                .frame(width: width)
                .offset(x: CGFloat(index) * (width + spacing))
                .animation(RecorderMotion.settle, value: index)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SettingsSegmented<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var help: (Value) -> String = { _ in "" }
    var icon: (Value) -> AppLineIcon.Kind? = { _ in nil }
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                AppChoiceButton(isSelected: isSelected) {
                    selection = option
                } label: {
                    HStack(spacing: 6) {
                        if let glyph = icon(option) {
                            AppLineIcon(kind: glyph, size: 15)
                                .modifier(AppChoiceIconFeedback())
                        }
                        Text(label(option))
                            .font(.appUI(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .modifier(AppChoiceContentFeedback())
                    .foregroundStyle(isSelected ? SettingsTheme.textPrimary
                                     : hovered == option ? SettingsTheme.textPrimary.opacity(0.8) : SettingsTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .contentShape(Capsule())
                }
                .onHover { inside in
                    if inside { hovered = option }
                    else if hovered == option { hovered = nil }
                }
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(help(option))
            }
        }
        .background {
            SettingsSelectionTrack(index: options.firstIndex(of: selection) ?? 0, count: options.count, radius: 16)
        }
        .padding(3)
        .background(SettingsTheme.track, in: Capsule())
        .animation(RecorderMotion.fade, value: hovered)
        .animation(RecorderMotion.fade, value: selection)
    }
}
