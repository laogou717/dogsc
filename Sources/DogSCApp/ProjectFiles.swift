import Foundation

/// EDT-054: files inside the project package (the AI workspace) are stored as
/// package-relative paths so renaming or moving a project never breaks them;
/// files elsewhere stay absolute (media is referenced, not copied).
enum ProjectFiles {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var package: URL?
    }
    private static let state = State()

    static func setPackage(_ url: URL?) {
        state.lock.lock(); state.package = url?.standardizedFileURL; state.lock.unlock()
    }

    static var package: URL? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.package
    }

    /// Absolute path for reading.
    static func resolve(_ path: String) -> String {
        guard !path.hasPrefix("/"), let package else { return path }
        return package.appendingPathComponent(path).path
    }

    static func url(_ path: String) -> URL { URL(fileURLWithPath: resolve(path)) }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: resolve(path)) }

    /// Path to store in the project: relative when inside the package.
    static func portable(_ path: String) -> String {
        guard let package else { return path }
        let root = package.path.hasSuffix("/") ? package.path : package.path + "/"
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(root) ? String(standardized.dropFirst(root.count)) : path
    }
}
