import Foundation
import RecorderCore

/// Source revisions are immutable files. Project commands switch references,
/// so undo, exports and other projects can keep using the exact old source.
@MainActor
enum HTMLMotionEditing {
    private static let revisionPrefix = ".motion-"

    @MainActor struct DisplayNames {
        private let projectNames: [URL: String]

        init(assets: [MediaAsset]) {
            projectNames = Dictionary(assets.compactMap { asset in
                guard asset.kind == .animation, let name = Self.visibleName(asset.name) else { return nil }
                return (ProjectFiles.url(asset.path).standardizedFileURL, name)
            }, uniquingKeysWith: { first, _ in first })
        }

        func name(for path: String, library: AssetLibrary = .shared) -> String {
            let url = ProjectFiles.url(path).standardizedFileURL
            if let name = projectNames[url] { return name }
            if let name = Self.visibleName(url.lastPathComponent) { return name }
            if let entry = library.motionEntry(for: url.path) {
                return projectNames[ProjectFiles.url(entry.path).standardizedFileURL]
                    ?? Self.visibleName(entry.name) ?? appLocalized("动效")
            }
            return appLocalized("动效")
        }

        private static func visibleName(_ rawName: String) -> String? {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = (name as NSString).pathExtension.lowercased() == "dmhtml"
                ? (name as NSString).deletingPathExtension : name
            guard !stem.isEmpty else { return nil }
            let prefix = HTMLMotionEditing.revisionPrefix
            if stem.hasPrefix(prefix), UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil { return nil }
            return stem
        }
    }

    struct File {
        let url: URL
        let entry: AssetLibrary.Entry
        let reused: Bool
    }

    struct Update {
        let path: String
        let assetID: UUID
        let unchanged: Bool
    }

    static func canonical(_ html: String) -> String {
        html.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validated(_ html: String) throws -> String {
        let content = canonical(html)
        guard content.contains("<") else { throw failure("html must contain a complete HTML motion page.") }
        return content
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DogSC.HTMLMotionEditing", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func create(name rawName: String, html: String, copy: Bool = false,
                       library: AssetLibrary) throws -> File {
        let content = try validated(html)
        let cleaned = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = cleaned.isEmpty ? "动效" : cleaned
        library.reload()
        if !copy, let existing = library.entries.first(where: {
            $0.kind == .animation && $0.name == name + ".dmhtml"
        }) {
            if let old = try? String(contentsOfFile: existing.path, encoding: .utf8), canonical(old) == content {
                return File(url: URL(fileURLWithPath: existing.path), entry: existing, reused: true)
            }
            throw failure("A different motion already has this name. Revise it with html_update using its current clip/asset id; use copy:true only for an independent asset. Existing path: \(existing.path)")
        }
        let folder = library.folder(for: .animation)
        var url = folder.appendingPathComponent(name).appendingPathExtension("dmhtml")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(suffix)").appendingPathExtension("dmhtml")
            suffix += 1
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let entry = AssetLibrary.Entry(path: url.path, kind: .animation, name: url.lastPathComponent,
            favorite: false, generated: true)
        do { try library.publish(entry) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return File(url: url, entry: entry, reused: false)
    }

    /// Keep one bin tile for all versions of this logical asset. Native IDs,
    /// names and import dates survive a revision or another placement.
    @discardableResult
    static func register(_ file: File, in timeline: inout ProjectTimeline) -> UUID {
        let matches = timeline.mediaAssets.indices.filter {
            file.entry.references(ProjectFiles.resolve(timeline.mediaAssets[$0].path))
        }
        if let first = matches.first {
            timeline.mediaAssets[first].path = ProjectFiles.portable(file.url.path)
            let id = timeline.mediaAssets[first].id
            for index in matches.dropFirst().reversed() { timeline.mediaAssets.remove(at: index) }
            return id
        }
        let asset = MediaAsset(id: file.entry.id, path: ProjectFiles.portable(file.url.path),
            kind: .animation, name: file.entry.name)
        timeline.mediaAssets.append(asset)
        return asset.id
    }

    static func update(id: UUID? = nil, path: String? = nil, html: String,
                       store: EditorStore, library: AssetLibrary) throws -> Update {
        try Task.checkCancellation()
        let content = try validated(html)
        guard (id == nil) != (path == nil) else { throw failure("Supply exactly one current clip/asset id or path.") }
        let before = store.project.timeline
        let segments: [RecordingSegment]
        if case let .edited(values) = before.sourceSequence { segments = values }
        else { segments = [] }
        let source = path ?? before.animationClips.first(where: { $0.id == id })?.sourcePath
            ?? segments.first(where: { $0.id == id })?.media?.motionPath
            ?? before.mediaAssets.first(where: { $0.id == id && $0.kind == .animation })?.path
        guard let source else { throw failure("The HTML motion target no longer exists.") }
        let url = ProjectFiles.url(source).standardizedFileURL
        let knownPaths = before.animationClips.map(\.sourcePath)
            + segments.compactMap { $0.media?.motionPath } + before.mediaAssets.map(\.path)
        guard HTMLMotion.isHTMLMotion(url.path), knownPaths.contains(where: {
            ProjectFiles.url($0).standardizedFileURL == url
        }), let entry = library.motionEntry(for: url.path),
              url.resolvingSymlinksInPath().path.hasPrefix(library.folder.resolvingSymlinksInPath().path + "/")
        else { throw failure("Target must be a library HTML motion used by the current project.") }
        let original = try String(contentsOf: url, encoding: .utf8)
        if canonical(original) == content {
            return Update(path: url.path, assetID: before.mediaAssets.first(where: {
                entry.references(ProjectFiles.resolve($0.path))
            })?.id ?? entry.id, unchanged: true)
        }
        let matching = (entry.revisionPaths ?? []).first {
            (try? String(contentsOfFile: $0, encoding: .utf8)).map { canonical($0) == content } == true
        }
        let revised = matching.map { URL(fileURLWithPath: $0) }
            ?? url.deletingLastPathComponent().appendingPathComponent("\(revisionPrefix)\(UUID()).dmhtml")
        var removeOnFailure = matching == nil
        defer { if removeOnFailure { try? FileManager.default.removeItem(at: revised) } }
        if matching == nil { try content.write(to: revised, atomically: true, encoding: .utf8) }
        var nextEntry = entry
        var versions = entry.revisionPaths ?? [entry.path]
        if !versions.contains(revised.path) { versions.append(revised.path) }
        nextEntry.revisionPaths = versions
        nextEntry.path = revised.path
        let file = File(url: revised, entry: nextEntry, reused: matching != nil)
        let portable = ProjectFiles.portable(revised.path)
        var next = before
        for index in next.animationClips.indices where ProjectFiles.url(next.animationClips[index].sourcePath).standardizedFileURL == url {
            next.animationClips[index].sourcePath = portable
        }
        if case var .edited(values) = next.sourceSequence {
            for index in values.indices where values[index].media?.motionPath.map({ ProjectFiles.url($0).standardizedFileURL == url }) == true {
                values[index].media?.motionPath = portable
            }
            next.sourceSequence = .edited(values)
        }
        let assetID = register(file, in: &next)
        try ProjectValidator.validate(next)
        try Task.checkCancellation()
        try library.publish(nextEntry)
        do { try store.replaceTimeline(with: next, actionName: "更新动效") }
        catch {
            do { try library.publish(entry) }
            catch { removeOnFailure = false } // Keep the published file valid if rollback I/O fails.
            throw error
        }
        removeOnFailure = false
        return Update(path: revised.path, assetID: assetID, unchanged: false)
    }
}
