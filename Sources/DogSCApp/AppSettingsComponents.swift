import AppKit
import SwiftUI

// MARK: - Settings palette
// All settings surfaces inherit the same appearance as the recorder.

enum SettingsTheme {
    static let canvasBackground = Color(nsColor: RecorderStyle.canvasNSColor)
    static let cardBackground = RecorderStyle.base
    static let cardBorder = LinearGradient(
        colors: [RecorderStyle.chrome.opacity(0.09), RecorderStyle.chrome.opacity(0.025)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let divider = RecorderStyle.chrome.opacity(0.06)
    static let well = RecorderStyle.chrome.opacity(0.06)
    static let wellHover = RecorderStyle.chrome.opacity(0.10)
    static let textPrimary = RecorderStyle.ink
    static let textSecondary = RecorderStyle.muted
    static let textFaint = RecorderStyle.faint

    static let mint = Color(red: 0.30, green: 0.86, blue: 0.55)
    static let mintWash = Color(red: 0.30, green: 0.86, blue: 0.55).opacity(0.18)
    static let recording = RecorderStyle.destructiveInk
    static let recordingWash = Color(red: 1.0, green: 0.28, blue: 0.24).opacity(0.18)
    static let amber = RecorderStyle.amberInk
    static let amberWash = Color(red: 0.95, green: 0.68, blue: 0.28).opacity(0.18)
}

enum SettingsMotion {
    static var reduces: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var springMorph: Animation? { RecorderMotion.settle }
    static var springSnappy: Animation? { RecorderMotion.quick }
    static var springGentle: Animation? { RecorderMotion.morph }
    static var quick: Animation { .easeOut(duration: 0.16) }
}

// MARK: - Card Container

struct SettingsCard<Content: View>: View {
    let title: String?
    let footer: String?
    var footerColor: Color = SettingsTheme.textSecondary
    let content: Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        footerColor: Color = SettingsTheme.textSecondary,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.footerColor = footerColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(appLocalized(title))
                    .font(.appUI(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .padding(.leading, 18)
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The recorder surface: opaque fill, fine top edge and cast shadow.
            // Rows clip to the shape first; the surface and its shadow sit outside the clip.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background { RecorderSurfaceShape(radius: 20, castsShadow: true) }

            if let footer {
                Text(appLocalized(footer))
                    .font(EditorTypography.helper)
                    .foregroundStyle(footerColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Divider

struct SettingsDivider: View {
    var leadingInset: CGFloat = 54
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.divider)
            .frame(height: 1)
            .padding(.leading, leadingInset)
            .padding(.trailing, 18)
            .accessibilityHidden(true)
    }
}

// MARK: - Row

struct SettingsRow<Trailing: View>: View {
    let icon: AppLineIcon.Kind?
    let title: String
    let detail: String?
    var detailColor: Color = SettingsTheme.textSecondary
    var singleLineDetail: Bool = false
    var stacksControl: Bool = false
    let trailing: Trailing

    init(
        icon: AppLineIcon.Kind? = nil,
        title: String,
        detail: String? = nil,
        detailColor: Color = SettingsTheme.textSecondary,
        singleLineDetail: Bool = false,
        stacksControl: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.detailColor = detailColor
        self.singleLineDetail = singleLineDetail
        self.stacksControl = stacksControl
        self.trailing = trailing()
    }

    var body: some View {
        Group {
            if stacksControl {
                VStack(alignment: .leading, spacing: 14) {
                    heading
                    trailing
                        .padding(.leading, icon == nil ? 0 : 36)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        heading
                        Spacer(minLength: 0)
                        trailing.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        heading
                        trailing
                            .padding(.leading, icon == nil ? 0 : 36)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, stacksControl || detail != nil ? 16 : 14)
        .frame(minHeight: 58)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                AppLineIcon(kind: icon, size: 18)
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)

                if let detail {
                    if singleLineDetail {
                        Text(detail)
                            .font(EditorTypography.helper)
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(appLocalized(detail))
                            .font(EditorTypography.helper)
                            .foregroundStyle(detailColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        }
    }
}

// MARK: - Interactive Link Row

struct SettingsLinkRow: View {
    let icon: AppLineIcon.Kind
    let title: String
    var detail: String? = nil
    var trailingIcon: AppLineIcon.Kind = .external
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppLineIcon(kind: icon, size: 18)
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(appLocalized(title))
                        .font(.appUI(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.textPrimary)

                    if let detail {
                        Text(appLocalized(detail))
                            .font(EditorTypography.helper)
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                }

                Spacer(minLength: 12)

                AppLineIcon(kind: trailingIcon, size: 14)
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .offset(x: hovered && !SettingsMotion.reduces ? 2 : 0,
                            y: hovered && !SettingsMotion.reduces && trailingIcon == .external ? -2 : 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 56)
            .background(RecorderStyle.chrome.opacity(hovered ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle(scale: 0.99))
        .onHover { hovering in
            withAnimation(SettingsMotion.springSnappy) { hovered = hovering }
        }
        .modifier(OptionalAccessibilityIdentifier(id: accessibilityIdentifier))
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

// MARK: - Toggle

struct SettingsToggle: View {
    @Binding var isOn: Bool
    var accessibilityLabel: String = ""
    var accessibilityHint: String = ""

    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(SettingsMotion.springMorph) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(isOn ? RecorderStyle.positiveInk : RecorderStyle.chrome.opacity(0.12))
                    .animation(RecorderMotion.fade, value: isOn)
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.24), radius: 3, y: 1)
                    .frame(width: 18, height: 18)
                    .offset(x: isOn ? 10 : -10)
                    .animation(RecorderMotion.settle, value: isOn)
            }
            .frame(width: 44, height: 24)
            .scaleEffect(hovered && !SettingsMotion.reduces ? 1.04 : 1.0)
            .animation(SettingsMotion.springSnappy, value: hovered)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SettingsPressStyle(scale: 0.94))
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(appLocalized(isOn ? "开关状态 · 开启" : "开关状态 · 关闭"))
        .accessibilityHint(accessibilityHint)
    }
}

// MARK: - Pill Button Style

struct SettingsPillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> Pill {
        Pill(configuration: configuration, prominent: prominent)
    }

    struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .font(.appUI(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(foreground(pressed: pressed))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(background(pressed: pressed), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
                .scaleEffect(pressed && !SettingsMotion.reduces ? 0.95 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(SettingsMotion.springSnappy, value: pressed)
                .animation(SettingsMotion.quick, value: hovered)
        }

        private func foreground(pressed: Bool) -> Color {
            if prominent {
                return RecorderStyle.onPrimary
            }
            return SettingsTheme.textPrimary
        }

        private func background(pressed: Bool) -> Color {
            if prominent {
                return RecorderStyle.primaryFill.opacity(pressed ? 0.8 : hovered ? 0.94 : 0.98)
            }
            return RecorderStyle.chrome.opacity(pressed ? 0.16 : hovered ? 0.11 : 0.07)
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
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, scale in
            view.scaleEffect(RecorderMotion.reduces ? 1 : scale)
        } keyframes: { _ in
            CubicKeyframe(0.90, duration: 0.08)
            SpringKeyframe(1, duration: 0.32, spring: Spring(duration: 0.32, bounce: 0.18))
        }
    }
}

/// One persistent highlight moves between stable hit targets. AppStorage
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
                .fill(RecorderStyle.selection)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(RecorderStyle.chrome.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
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
                    .foregroundStyle(isSelected ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(RecorderStyle.chrome.opacity(hovered == option && !isSelected ? 0.045 : 0), in: Capsule())
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
            SettingsSelectionTrack(index: options.firstIndex(of: selection) ?? 0, count: options.count)
        }
        .padding(3)
        .background(RecorderStyle.well, in: Capsule())
        .animation(RecorderMotion.fade, value: hovered)
        .animation(RecorderMotion.fade, value: selection)
    }
}

// MARK: - Camera Shape Choices

struct SettingsCameraShapePicker: View {
    @Binding var selection: RecordingCameraPreviewShape
    @State private var hovered: RecordingCameraPreviewShape?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RecordingCameraPreviewShape.allCases) { shape in
                AppChoiceButton(isSelected: selection == shape) {
                    selection = shape
                } label: {
                    VStack(spacing: 12) {
                        silhouette(for: shape)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                            .modifier(AppChoiceIconFeedback())
                        Text(shape.label)
                            .font(.appUI(size: 12, weight: .semibold))
                            .foregroundStyle(selection == shape ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .modifier(AppChoiceContentFeedback())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(RecorderStyle.chrome.opacity(hovered == shape && selection != shape ? 0.04 : 0))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .onHover { inside in
                    if inside { hovered = shape }
                    else if hovered == shape { hovered = nil }
                }
                .accessibilityLabel(shape.label)
                .accessibilityAddTraits(selection == shape ? .isSelected : [])
                .accessibilityIdentifier("settings.camera-shape.\(shape.rawValue)")
            }
        }
        .background {
            SettingsSelectionTrack(index: RecordingCameraPreviewShape.allCases.firstIndex(of: selection) ?? 0,
                                   count: RecordingCameraPreviewShape.allCases.count, spacing: 8, radius: 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(RecorderMotion.fade, value: selection)
        .animation(RecorderMotion.fade, value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("悬浮窗形状")
    }

    private func silhouette(for shape: RecordingCameraPreviewShape) -> some View {
        let width: CGFloat = shape == .sourceAspect ? 76 : 56
        let height: CGFloat = shape == .sourceAspect ? 46 : 56
        let radius: CGFloat = shape == .circle ? 28 : shape == .roundedSquare ? 13 : 9
        let outline = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return outline
            .fill(RecorderStyle.chrome.opacity(0.045))
            .overlay {
                AppLineIcon(kind: .person, size: 34)
                    .foregroundStyle(RecorderStyle.chrome.opacity(selection == shape ? 0.88 : 0.38))
            }
            .overlay {
                outline.strokeBorder(RecorderStyle.chrome.opacity(selection == shape ? 0.78 : 0.26), lineWidth: 1.5)
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

struct SettingsAppearancePicker: View {
    @Binding var selection: AppAppearancePreference

    var body: some View {
        SettingsSegmented(
            options: AppAppearancePreference.allCases,
            selection: $selection,
            label: { $0.label },
            icon: { preference in
                switch preference {
                case .system: .appearance
                case .light: .sun
                case .dark: .moon
                }
            }
        )
    }
}
