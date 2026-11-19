import Foundation

/// Matches system language preferences to the localizations DogSC ships.
///
/// The app ships Simplified Chinese only. When asked for Traditional Chinese
/// (`zh-Hant`, `zh-TW`, `zh-HK`, `zh-MO`), Foundation cannot match `zh-Hans`
/// and falls back to the development language, which leaves a Hong Kong or
/// Taiwan system showing English. Treat every Chinese preference as
/// Simplified Chinese instead, while keeping the order of other languages.
/// If a Traditional Chinese localization is ever added, match it here first.
enum AppLanguageResolution {
    static let localizations = ["en", "zh-Hans"]

    static func identifier(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(
            from: localizations,
            forPreferences: preferences.map(simplifiedChinesePreference)
        ).first ?? "en"
    }

    private static func simplifiedChinesePreference(_ preference: String) -> String {
        let normalized = preference.replacingOccurrences(of: "_", with: "-")
        guard normalized.split(separator: "-").first?.lowercased() == "zh" else {
            return preference
        }
        return "zh-Hans"
    }
}
