import AppKit
import Foundation
import Observation

/// One immutable language snapshot is shared by SwiftUI and native labels.
/// Reads can also come from error-formatting workers: the lock protects only
/// that snapshot, while all changes and UI notifications belong to MainActor.
final class AppLocalization: Observable, @unchecked Sendable {
    static let shared = AppLocalization()

    private struct Language {
        let identifier: String
        let bundle: Bundle
        var locale: Locale { Locale(identifier: identifier) }
    }

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var current: Language

    private init() {
        current = Self.resolve(AppLanguagePreference(
            preferredLanguages: AppPreferences.applicationLanguageOverride
        ))
    }

    // Access is registered at the caller's body evaluation, including when a
    // computed label calls appLocalized through another type. No view .id or
    // hosting-root replacement is needed to invalidate those String labels.
    private var language: Language {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { current }
    }

    var locale: Locale { language.locale }

    func localizedString(_ key: String) -> String {
        language.bundle.localizedString(forKey: key, value: key, table: nil)
    }

    @MainActor
    @discardableResult
    func apply(_ preference: AppLanguagePreference) -> Bool {
        let next = Self.resolve(preference)
        guard lock.withLock({ current.identifier != next.identifier }) else { return false }
        registrar.withMutation(of: self, keyPath: \.language) {
            lock.withLock { current = next }
        }
        return true
    }

    private static func resolve(_ preference: AppLanguagePreference) -> Language {
        // The application-domain AppleLanguages override must not feed back
        // into System after the user removes it. Read the global domain first.
        let systemLanguages = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] ?? Locale.preferredLanguages
        let identifier = Bundle.preferredLocalizations(
            from: ["en", "zh-Hans"],
            forPreferences: preference.preferredLanguages ?? systemLanguages
        ).first ?? "en"
        let bundle = Bundle.main.url(forResource: identifier, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? .main
        return Language(identifier: identifier, bundle: bundle)
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("cn.laogou.dogsc.language.changed")
}

/// Native views retain their binding; its callback uses a weak owner. Selector
/// registration is automatically removed when this binding is deallocated.
@MainActor
final class AppLanguageBinding: NSObject {
    private let refresh: @MainActor () -> Void

    init(_ refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
            name: .appLanguageDidChange, object: nil)
    }

    @objc private func languageDidChange() { refresh() }
}

/// Track only titles explicitly supplied by the app. Weak window keys avoid
/// extending a panel's lifetime; user-created project names stay with their
/// existing owner rather than becoming translation keys.
@MainActor
private final class AppWindowLocalization: NSObject {
    static let shared = AppWindowLocalization()

    private final class Title: NSObject {
        let key: String
        let prefix: String?
        let arguments: [String]

        init(key: String, prefix: String?, arguments: [String]) {
            self.key = key
            self.prefix = prefix
            self.arguments = arguments
        }

        var text: String {
            let translated = arguments.isEmpty ? appLocalized(key)
                : String(format: appLocalized(key), arguments: arguments.map { $0 as CVarArg })
            return prefix.map { "\($0) \(translated)" } ?? translated
        }
    }

    private let titles = NSMapTable<NSWindow, Title>.weakToStrongObjects()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTitles),
            name: .appLanguageDidChange, object: nil)
    }

    func setTitle(of window: NSWindow, key: String, prefix: String?, arguments: [String]) {
        let title = Title(key: key, prefix: prefix, arguments: arguments)
        titles.setObject(title, forKey: window)
        window.title = title.text
    }

    @objc private func refreshTitles() {
        for window in titles.keyEnumerator().allObjects as? [NSWindow] ?? [] {
            window.title = titles.object(forKey: window)?.text ?? window.title
        }
    }
}

@MainActor
func appLocalizeWindowTitle(_ window: NSWindow, _ key: String,
                            prefix: String? = nil, arguments: [String] = []) {
    AppWindowLocalization.shared.setTitle(of: window, key: key, prefix: prefix, arguments: arguments)
}
