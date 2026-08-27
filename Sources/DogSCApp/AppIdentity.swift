import Foundation

/// Runtime identity of the installed bundle. Local development and a formal
/// release intentionally use different display names and bundle identifiers;
/// user-facing chrome must therefore read the bundle instead of hard-coding
/// the release name.
enum AppIdentity {
    static var displayName: String {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "DogSC"
    }
}
