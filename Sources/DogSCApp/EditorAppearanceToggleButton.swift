import SwiftUI

/// One action at the workspace edge; the three-way System preference stays
/// in Settings. Resolve System through the effective scheme on first click.
struct EditorAppearanceToggleButton: View {
    @AppStorage(AppPreferences.appearancePreferenceKey)
    private var preference = AppAppearancePreference.dark
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
                .id(isDark)
                .transition(reducesMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 0.6).combined(with: .opacity),
                    removal: .scale(scale: 1.3).combined(with: .opacity)))
                .animation(RecorderMotion.settle ?? .easeOut(duration: 0.18), value: isDark)
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 16))
        .help(actionTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("界面外观")
        .accessibilityValue(appLocalized(isDark ? "深色" : "浅色"))
        .accessibilityHint(actionTitle)
        .accessibilityIdentifier("editor.appearance")
    }
}
