import SwiftUI

/// One action at the workspace edge; the three-way System preference stays
/// in Settings. Resolve System through the effective scheme on first click.
struct EditorAppearanceToggleButton: View {
    @AppStorage(AppPreferences.appearancePreferenceKey)
    private var preference = AppAppearancePreference.system
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private var isDark: Bool { colorScheme == .dark }
    private var actionTitle: String {
        appLocalized(isDark ? "切换为浅色外观" : "切换为深色外观")
    }

    var body: some View {
        Button {
            preference = isDark ? .light : .dark
            AppPreferences.applyAppearancePreferenceToOpenWindows()
        } label: {
            EditorToolbarIconSurface(systemName: isDark ? "moon.stars.fill" : "sun.max.fill")
                .contentTransition(reducesMotion ? .opacity : .symbolEffect(.replace))
                .animation(reducesMotion ? nil : .easeInOut(duration: 0.22), value: isDark)
        }
        .buttonStyle(.editorToolbarPress)
        .help(actionTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("界面外观")
        .accessibilityValue(appLocalized(isDark ? "深色" : "浅色"))
        .accessibilityHint(actionTitle)
        .accessibilityIdentifier("editor.appearance")
    }
}
