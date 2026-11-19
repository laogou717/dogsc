import AppKit
import Darwin
import Foundation
import RecorderCore

/// EDT-058: the cross-project library. AI-generated reusable media is saved
/// in its folder (one subfolder per kind) so deleting a project never takes
/// it along. Favouriting a file from elsewhere copies it in as well: a motion
/// generated inside a project package would otherwise die with that project.
/// The index lives inside the folder, so it travels with it (e.g. to an
/// external drive).
@MainActor
final class AssetLibrary: ObservableObject {
    static let shared = AssetLibrary()
    static let folderKey = "cn.laogou.dogsc.asset-library-folder"

    struct RemoteSource: Codable, Equatable, Sendable {
        var url: String
        var pageURL: String
        var licenseURL: String
        var sha256: String
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// Absolute path (library files and user files alike).
        var path: String
        var kind: MediaAssetKind
        var name: String
        var favorite: Bool
        /// Created or downloaded by the AI into the library folder.
        var generated: Bool
        /// Where this favourite was taken from, when favouriting copied the
        /// file in. Lets the original tile still read as favourited.
        var origin: String?
        /// The file or folder the library owns because favouriting copied it
        /// in, and may therefore take away again. Optional so an index
        /// written before this existed still decodes.
        var copiedRoot: String?
        /// Immutable source versions of one logical motion, oldest first.
        /// Hidden revision files are not separate library entries.
        var revisionPaths: [String]?
        var remoteSource: RemoteSource?
        var addedAt = Date()

        func references(_ path: String) -> Bool {
            let wanted = AssetLibrary.fileKey(path)
            return ([self.path] + (revisionPaths ?? [])).contains { AssetLibrary.fileKey($0) == wanted }
        }

        var exists: Bool { FileManager.default.fileExists(atPath: path) }
        /// Files owned by this entry, including its immutable source versions.
        var ownedFiles: [URL] {
            let versions = revisionPaths ?? []
            var files = copiedRoot.map { [URL(fileURLWithPath: $0)] } ?? []
            if files.isEmpty, generated { files.append(URL(fileURLWithPath: versions.first ?? path)) }
            files += versions.dropFirst().map { URL(fileURLWithPath: $0) }
            return files.filter { file in
                !files.contains { $0 != file && file.path.hasPrefix($0.path + "/") }
            }
        }
    }

    /// Everything one removal has to put back, including files it trashed.
    struct Removal: Equatable {
        var entries: [Entry]
        /// Where each trashed item now sits, by the path it came from.
        var trashed: [String: URL]
    }

    enum LibraryError: LocalizedError {
        case copyFailed(name: String, reason: String)
        var errorDescription: String? {
            switch self {
            case let .copyFailed(name, reason):
                String(format: appLocalized("无法把「%@」复制进素材库：%@"), name, reason)
            }
        }
    }

    @Published private(set) var entries: [Entry] = [] {
        didSet { favoriteKeys = nil; favoriteQueries.removeAll(keepingCapacity: true) }
    }
    private var favoriteKeys: Set<String>?
    private var favoriteQueries: [String: Bool] = [:]
    /// The last removal, while it can still be undone from a notice.
    @Published private(set) var lastRemoval: Removal?

    private let folderOverride: URL?
    init(folder: URL? = nil) { folderOverride = folder; reload() }

    var folder: URL {
        if let folderOverride { return folderOverride }
        if let path = UserDefaults.standard.string(forKey: Self.folderKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return movies.appendingPathComponent("DogSC", isDirectory: true)
            .appendingPathComponent("素材库", isDirectory: true)
    }

    func setFolder(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.folderKey)
        reload()
    }

    static func subfolderName(for kind: MediaAssetKind) -> String {
        switch kind {
        case .animation: "动效"
        case .image: "图片"
        case .audio: "音频"
        case .video: "视频"
        }
    }

    /// Where the AI saves a new file of this kind.
    func folder(for kind: MediaAssetKind) -> URL {
        let url = folder.appendingPathComponent(Self.subfolderName(for: kind), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var indexURL: URL { folder.appendingPathComponent(".dogsc-library.json") }

    nonisolated static func fileKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Reads the index and picks up media the AI saved straight into the
    /// library folder.
    func reload() {
        favoriteKeys = nil
        favoriteQueries.removeAll(keepingCapacity: true)
        var loaded = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: indexURL))) ?? []
        let known = Set(loaded.flatMap { [$0.path] + ($0.revisionPaths ?? []) }.map(Self.fileKey))
        for kind in [MediaAssetKind.animation, .image, .audio, .video] {
            let directory = folder.appendingPathComponent(Self.subfolderName(for: kind), isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in files where !file.lastPathComponent.hasPrefix(".")
                && !known.contains(Self.fileKey(file.path)) && MediaAssetKind.kind(forExtension: file.pathExtension) != nil {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                loaded.append(Entry(path: file.path, kind: MediaAssetKind.kind(forExtension: file.pathExtension) ?? kind,
                                    name: file.lastPathComponent, favorite: false, generated: true, addedAt: created))
            }
        }
        // AI files that were deleted in Finder leave the library; favourites
        // stay visible as missing so they can be relinked or removed.
        loaded.removeAll { $0.generated && !$0.favorite && !$0.exists }
        if loaded != entries { entries = loaded }
        save()
    }

    private func save() {
        try? writeIndex(entries)
    }

    private func writeIndex(_ values: [Entry]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: indexURL, options: .atomic)
    }

    func motionEntry(for path: String) -> Entry? {
        entries.first { $0.kind == .animation && $0.references(path) }
    }

    /// Publish metadata only after its file is ready, without dangling entries
    /// when writing the index fails.
    func publish(_ entry: Entry) throws {
        var next = entries
        if let index = next.firstIndex(where: { $0.id == entry.id }) { next[index] = entry }
        else { next.append(entry) }
        try writeIndex(next)
        entries = next
    }

    /// A file that was copied in still answers for the path it came from, so
    /// its tile in a project keeps showing a filled star.
    func isFavorite(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if let hit = favoriteQueries[path] { return hit }
        if favoriteKeys == nil {
            favoriteKeys = Set(entries.filter(\.favorite).flatMap {
                ([$0.path] + ($0.revisionPaths ?? []) + [$0.origin].compactMap { $0 }).map(Self.fileKey)
            })
        }
        let result = favoriteKeys?.contains(Self.fileKey(path)) == true
        favoriteQueries[path] = result
        return result
    }

    /// Favouriting takes a copy unless the file already lives in the library,
    /// so the motion survives the project that produced it. Unfavouriting a
    /// copy takes it away again.
    func toggleFavorite(path: String, kind: MediaAssetKind, name: String) throws {
        if let index = entries.firstIndex(where: { $0.references(path) || $0.origin == path }) {
            if entries[index].favorite, !entries[index].generated { remove([entries[index].id]); return }
            entries[index].favorite.toggle()
            save()
            return
        }
        let root = folder.standardizedFileURL.path
        if URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root + "/") {
            entries.append(Entry(path: path, kind: kind, name: name, favorite: true, generated: false))
        } else {
            let copy = try copyIntoLibrary(path: path, kind: kind, name: name)
            entries.append(Entry(path: copy.file.path, kind: kind, name: name, favorite: true, generated: false,
                                 origin: path, copiedRoot: copy.owned.path))
        }
        save()
    }

    /// Clones the file into the library — free on one APFS volume. An HTML
    /// motion resolves its neighbours against its own folder, so the page and
    /// everything it references are mirrored under the smallest directory
    /// that contains them all; every relative URL then still resolves and the
    /// page itself is never rewritten.
    private func copyIntoLibrary(path: String, kind: MediaAssetKind,
                                 name: String) throws -> (file: URL, owned: URL) {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let destination = folder(for: kind)
        let base = Self.sanitized(((name as NSString).deletingPathExtension))
        let dependencies = kind == .animation ? Self.htmlDependencies(of: source) : []
        do {
            guard !dependencies.isEmpty else {
                let target = Self.unused(in: destination, base: base, extension: source.pathExtension)
                try Self.clone(source, to: target)
                return (target, target)
            }
            let files = [source] + dependencies
            let root = Self.commonDirectory(of: files)
            let bundle = Self.unused(in: destination, base: base, extension: "")
            for file in files {
                let target = bundle.appendingPathComponent(Self.relative(file, to: root))
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Self.clone(file, to: target)
            }
            return (bundle.appendingPathComponent(Self.relative(source, to: root)), bundle)
        } catch {
            throw LibraryError.copyFailed(name: source.lastPathComponent, reason: appErrorDescription(error))
        }
    }

    private static func clone(_ source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, 0) != 0 {
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    /// A name that is safe as one path component, and never empty.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? appLocalized("素材") : cleaned
    }

    /// Never overwrites a file that is already there: " 2", " 3" and so on.
    private static func unused(in folder: URL, base: String, extension suffix: String) -> URL {
        func url(_ name: String) -> URL {
            let url = folder.appendingPathComponent(name)
            return suffix.isEmpty ? url : url.appendingPathExtension(suffix)
        }
        var candidate = url(base)
        var copy = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base) \(copy)")
            copy += 1
        }
        return candidate
    }

    private static func relative(_ file: URL, to root: URL) -> String {
        file.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    private static func commonDirectory(of files: [URL]) -> URL {
        var components = files[0].deletingLastPathComponent().pathComponents
        for file in files.dropFirst() {
            let other = file.deletingLastPathComponent().pathComponents
            var shared = 0
            while shared < min(components.count, other.count), components[shared] == other[shared] { shared += 1 }
            components = Array(components.prefix(shared))
        }
        return URL(fileURLWithPath: "/" + components.dropFirst().joined(separator: "/"), isDirectory: true)
    }

    /// Local files an HTML motion references, followed through nested pages,
    /// stylesheets and scripts — the same shapes the project importer moves.
    private static func htmlDependencies(of url: URL, visited: Set<String> = [], found: Set<String> = []) -> [URL] {
        guard found.count < 200,
              ["dmhtml", "html", "htm", "css", "js", "mjs"].contains(url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"[\"']([^\"'\n]+)[\"']|url\(\s*([^\s\)]+)\s*\)"#)
        else { return [] }
        var visited = visited; visited.insert(url.path)
        var found = found
        var result: [URL] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let swiftRange = Range(range, in: text) else { continue }
            let value = String(text[swiftRange])
            guard !value.hasPrefix("#"),
                  let dependency = URL(string: value, relativeTo: url.deletingLastPathComponent())?.absoluteURL,
                  dependency.isFileURL else { continue }
            let file = URL(fileURLWithPath: dependency.path).standardizedFileURL
            guard !visited.contains(file.path), !found.contains(file.path),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            found.insert(file.path)
            result.append(file)
            let nested = htmlDependencies(of: file, visited: visited, found: found)
            for item in nested { found.insert(item.path) }
            result += nested
        }
        return result
    }

    func addGenerated(_ url: URL) {
        guard let kind = MediaAssetKind.kind(forExtension: url.pathExtension) else { return }
        if let index = entries.firstIndex(where: { $0.references(url.path) }) {
            entries[index].generated = true
        } else {
            entries.append(Entry(path: url.path, kind: kind, name: url.lastPathComponent, favorite: false, generated: true))
        }
        save()
    }

    func remove(_ id: UUID) { remove([id]) }

    /// Takes entries out of the library. A file the library owns — AI-made,
    /// or copied in when it was favourited — goes to the Trash so the folder
    /// does not fill up with orphans; a file of the user's own elsewhere is
    /// never touched. One call is one removal, and one removal can be undone.
    func remove(_ ids: Set<UUID>) {
        let removed = entries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        var trashed: [String: URL] = [:]
        for entry in removed {
            for owned in entry.ownedFiles {
                var restored: NSURL?
                try? FileManager.default.trashItem(at: owned, resultingItemURL: &restored)
                if let url = restored as URL? { trashed[owned.path] = url }
            }
        }
        entries.removeAll { ids.contains($0.id) }
        lastRemoval = Removal(entries: removed, trashed: trashed)
        save()
    }

    /// Puts the last removal back, files included, so a mistaken Delete costs
    /// one click rather than a trip to the Trash.
    func undoLastRemoval() {
        guard let removal = lastRemoval else { return }
        lastRemoval = nil
        for (original, trashed) in removal.trashed {
            let target = URL(fileURLWithPath: original)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: trashed, to: target)
        }
        entries.append(contentsOf: removal.entries.filter { entry in !entries.contains { $0.id == entry.id } })
        save()
    }

    func forgetLastRemoval() { lastRemoval = nil }
}
