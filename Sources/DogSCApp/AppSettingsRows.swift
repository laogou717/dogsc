import AppKit
import SwiftUI

// MARK: - Page structure

/// A page's title and its one-line lead, above the first group.
struct SettingsPageHeader: View {
    let title: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appLocalized(title))
                .font(.appUI(size: 22, weight: .semibold))
                .foregroundStyle(EditorTheme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(appLocalized(lead))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.tertiaryText)
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A run of rows with an optional quiet heading.
struct SettingsGroup<Content: View>: View {
    var header: String?
    @ViewBuilder let content: () -> Content

    init(_ header: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(appLocalized(header))
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
    }
}

/// One setting: its name (and a quiet second line) on the left, the control
/// on the right, a hairline beneath unless it closes its group.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var showsDivider = true
    @ViewBuilder let control: () -> Control

    init(_ title: String, detail: String? = nil, last: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.showsDivider = !last
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(appLocalized(title))
                    .font(.appUI(size: 14, weight: .medium))
                    .foregroundStyle(EditorTheme.primaryText)
                if let detail, !detail.isEmpty {
                    Text(appLocalized(detail))
                        .font(.appUI(size: 12.5))
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { control() }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(EditorTheme.chrome(0.075)).frame(height: 1) }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Controls

/// The flat buttons of Settings and the export sheet: a filled well, a
/// transparent ghost, or the window's one accent action.
struct AppSheetButtonStyle: ButtonStyle {
    enum Kind { case normal, ghost, primary }
    var kind: Kind = .normal
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, kind: kind, large: large)
    }

    private struct Surface: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let pressed = configuration.isPressed && isEnabled
            let hover = hovered && isEnabled
            configuration.label
                .font(.appUI(size: large ? 14 : 13.5, weight: .medium))
                .foregroundStyle(foreground(hover: hover))
                .padding(.horizontal, kind == .primary ? 16 : 12)
                .frame(height: large ? 36 : 32)
                .background(background(hover: hover, pressed: pressed), in: shape)
                .contentShape(shape)
                .appKeyboardFocus(in: shape)
                .opacity(isEnabled ? 1 : 0.42)
                .onHover { hovered = $0 }
                .animation(SpringMotion.micro, value: hovered)
                .animation(SpringMotion.micro, value: pressed)
        }

        private func foreground(hover: Bool) -> Color {
            switch kind {
            case .normal: EditorTheme.primaryText
            case .ghost: hover ? EditorTheme.primaryText : EditorTheme.secondaryText
            case .primary: EditorTheme.onAccentFill
            }
        }

        private func background(hover: Bool, pressed: Bool) -> AnyShapeStyle {
            switch kind {
            case .normal:
                AnyShapeStyle(EditorTheme.chrome(pressed ? 0.11 : hover ? 0.08 : 0.045))
            case .ghost:
                AnyShapeStyle(EditorTheme.chrome(pressed ? 0.08 : hover ? 0.045 : 0))
            case .primary:
                AnyShapeStyle(EditorTheme.accent.opacity(pressed ? 0.82 : hover ? 0.9 : 1))
            }
        }
    }
}

extension ButtonStyle where Self == AppSheetButtonStyle {
    static var appSheet: AppSheetButtonStyle { AppSheetButtonStyle() }
    static var appSheetGhost: AppSheetButtonStyle { AppSheetButtonStyle(kind: .ghost) }
    static var appSheetPrimary: AppSheetButtonStyle { AppSheetButtonStyle(kind: .primary) }
    static func appSheet(_ kind: AppSheetButtonStyle.Kind, large: Bool = false) -> AppSheetButtonStyle {
        AppSheetButtonStyle(kind: kind, large: large)
    }
}

/// A segmented choice: a 2-point track, a raised thumb, optional quiet
/// second words beside each title ("60 更流畅").
struct AppSegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var note: ((Option) -> String?)? = nil
    /// Settings rows give each option the same minimum width; the export
    /// sheet stretches the track across its column.
    var optionMinWidth: CGFloat? = 60
    var fillsWidth = false
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    withAnimation(SpringMotion.standard) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        Text(appLocalized(label(option)))
                            .font(.appUI(size: 13, weight: .medium))
                            .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                        if let small = note?(option) {
                            Text(appLocalized(small))
                                .font(.appUI(size: 11))
                                .foregroundStyle(EditorTheme.tertiaryText)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(minWidth: optionMinWidth.map { $0 - 4 }, maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: 28)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(EditorTheme.segmentThumb)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(EditorTheme.chrome(0.075), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appLocalized(label(option)))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Settings' segmented choice (kept for call sites outside the pages).
struct SettingsChoice<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    init(options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String) {
        self.options = options
        _selection = selection
        self.label = label
    }

    var body: some View {
        AppSegmentedChoice(options: options, selection: $selection, label: label)
    }
}

/// A pull-down showing the current value with a small chevron.
struct SettingsMenu<Items: View>: View {
    let title: String
    @ViewBuilder let items: () -> Items

    init(_ title: String, @ViewBuilder items: @escaping () -> Items) {
        self.title = title
        self.items = items
    }

    var body: some View {
        Menu {
            items()
        } label: {
            SettingsMenuLabel(title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct SettingsMenuLabel: View {
    let title: String
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            AppLineIcon(kind: .chevronDown, size: 10)
                .foregroundStyle(EditorTheme.secondaryText)
        }
        .font(.appUI(size: 13))
        .foregroundStyle(EditorTheme.primaryText)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(EditorTheme.chrome(hovered ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// A folder path in monospaced type beside its 更改 button.
struct SettingsPathControl: View {
    let url: URL
    let action: () -> Void

    var body: some View {
        Text((url.path as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(EditorTheme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 220, alignment: .trailing)
            .help(url.path)
        Button(appLocalized("更改"), action: action)
            .buttonStyle(.appSheet)
    }
}

struct SettingsStatusPill: View {
    enum Kind { case ok, missing, later }
    let text: String
    let kind: Kind

    init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    init(text: String, positive: Bool) {
        self.init(text: text, kind: positive ? .ok : .missing)
    }

    var body: some View {
        HStack(spacing: 5) {
            if kind == .ok { AppLineIcon(kind: .check, size: 12) }
            Text(appLocalized(text))
        }
        .font(.appUI(size: 12, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(fill, in: Capsule(style: .continuous))
    }

    private var tint: Color {
        switch kind {
        case .ok: EditorTheme.success
        case .missing: EditorTheme.destructiveText
        case .later: EditorTheme.secondaryText
        }
    }

    private var fill: Color {
        switch kind {
        case .ok: EditorTheme.success.opacity(0.13)
        case .missing: EditorTheme.destructiveText.opacity(0.12)
        case .later: EditorTheme.chrome(0.045)
        }
    }
}

/// One key cap: monospaced, a soft well, no outline.
struct SettingsKeyCap: View {
    let key: String

    var body: some View {
        Text(appLocalized(key))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(EditorTheme.secondaryText)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(EditorTheme.chrome(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct SettingsLanguageMenu: View {
    @ObservedObject private var languageSettings = AppLanguageSettings.shared

    var body: some View {
        SettingsMenu(languageSettings.selection.label) {
            Picker(appLocalized("界面语言"), selection: Binding(
                get: { languageSettings.selection },
                set: { languageSettings.select($0) }
            )) {
                ForEach(AppLanguagePreference.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel(appLocalized("界面语言"))
    }
}

// MARK: - Permissions

enum SettingsPermissionStatus: Equatable {
    case granted
    case askLater
    case missing
}

struct SettingsPermissionItem: Identifiable {
    let title: String
    let detail: String
    let icon: AppLineIcon.Kind
    let required: Bool
    let status: SettingsPermissionStatus
    let pane: String
    var id: String { pane }
}

/// A permission: icon tile, name with 必需 / 可选, what it is for, and
/// its state with the way to turn it on.
struct SettingsPermissionRow: View {
    let item: SettingsPermissionItem
    var last = false
    let enable: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppLineIcon(kind: item.icon, size: 16)
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: 36, height: 36)
                .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(appLocalized(item.title))
                        .font(.appUI(size: 14, weight: .medium))
                        .foregroundStyle(EditorTheme.primaryText)
                    Text(appLocalized(item.required ? "必需" : "可选"))
                        .font(.appUI(size: 11.5))
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                Text(appLocalized(item.detail))
                    .font(.appUI(size: 12.5))
                    .foregroundStyle(EditorTheme.tertiaryText)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                switch item.status {
                case .granted:
                    SettingsStatusPill(text: "已开启", kind: .ok)
                case .missing:
                    SettingsStatusPill(text: "未开启", kind: .missing)
                    Button(appLocalized("去开启"), action: enable).buttonStyle(.appSheetPrimary)
                case .askLater:
                    SettingsStatusPill(text: "以后再说", kind: .later)
                    Button(appLocalized("去开启"), action: enable).buttonStyle(.appSheet)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(EditorTheme.chrome(0.075)).frame(height: 1) }
        }
        .accessibilityElement(children: .contain)
    }
}
