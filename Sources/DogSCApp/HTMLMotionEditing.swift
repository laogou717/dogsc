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
            let filename = Self.visibleName(url.lastPathComponent)
            if let filename, !filename.contains(" · v") { return filename }
            let local = ProjectFiles.package.flatMap { AssetLibrary.projectAssets(in: $0).motionEntry(for: url.path) }
            if let entry = local ?? library.motionEntry(for: url.path) {
                return projectNames[ProjectFiles.url(entry.path).standardizedFileURL]
                    ?? Self.visibleName(entry.name) ?? appLocalized("动效")
            }
            return filename ?? appLocalized("动效")
        }

        private static func visibleName(_ rawName: String) -> String? {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = HTMLMotion.isHTMLMotion(name)
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

    private static func validated(_ html: String) throws -> String {
        let content = try MotionTemplateLibrary.embedReferencedSamples(in: HTMLMotionPage.authoredPage(html))
        guard content.contains("<") else { throw failure("html must contain a complete HTML motion page.") }
        _ = try MotionSoundScore.read(in: content)
        return content
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DogSC.HTMLMotionEditing", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func currentMotionPaths(in timeline: ProjectTimeline) -> [String] {
        var paths = timeline.animationClips.map(\.sourcePath)
        if case let .edited(segments) = timeline.sourceSequence {
            paths += segments.compactMap { $0.media?.motionPath }
        }
        paths += timeline.mediaAssets.filter { $0.kind == .animation }.map(\.path)
        return paths.map(ProjectFiles.resolve)
    }

    static func create(name rawName: String, html: String, copy: Bool = false,
                       template: URL? = nil, timeline: ProjectTimeline? = nil, library: AssetLibrary) throws -> File {
        let content = try validated(html)
        let cleaned = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = HTMLMotion.isHTMLMotion(cleaned) ? (cleaned as NSString).deletingPathExtension : cleaned
        var name = AssetLibrary.sanitized(stem.isEmpty ? template?.deletingPathExtension().lastPathComponent ?? "动效" : stem)
        library.reload()
        if !copy {
            let active = timeline.map(currentMotionPaths(in:)) ?? library.entries.map(\.path)
            for entry in library.entries where entry.kind == .animation && (entry.name as NSString).deletingPathExtension == name {
                guard let path = active.first(where: entry.references) else { continue }
                if let old = try? String(contentsOfFile: path, encoding: .utf8), HTMLMotionPage.authoredPage(old) == content {
                    return File(url: URL(fileURLWithPath: path), entry: entry, reused: true)
                }
                throw failure("A current motion already has this name. Revise it with html_update using its clip/asset id, or use copy:true for an independent asset.")
            }
        }
        if copy {
            let base = name
            let names = Set(library.entries.filter { $0.kind == .animation }.map { ($0.name as NSString).deletingPathExtension })
            var suffix = 2
            while names.contains(name) { name = "\(base) \(suffix)"; suffix += 1 }
        }
        let page = HTMLMotionPage.standalonePage(content)
        if let template {
            let copied = try library.copyIntoLibrary(path: template.path, kind: .animation, name: name + ".html", entryExtension: "html")
            let entry = AssetLibrary.Entry(path: copied.file.path, kind: .animation, name: name + ".html",
                favorite: false, generated: true, origin: template.path, copiedRoot: copied.owned.path)
            do {
                try page.write(to: copied.file, atomically: true, encoding: .utf8)
                try library.publish(entry)
            }
            catch { try? FileManager.default.removeItem(at: copied.owned); throw error }
            return File(url: copied.file, entry: entry, reused: false)
        }
        let folder = library.folder(for: .animation)
        var url = folder.appendingPathComponent(name).appendingPathExtension("html")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(suffix)").appendingPathExtension("html")
            suffix += 1
        }
        try page.write(to: url, atomically: true, encoding: .utf8)
        let entry = AssetLibrary.Entry(path: url.path, kind: .animation, name: name + ".html",
            favorite: false, generated: true)
        do { try library.publish(entry) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return File(url: url, entry: entry, reused: false)
    }

    /// Keep one bin tile for all versions of this logical asset. Native IDs,
    /// names and import dates survive a revision or another placement.
    @discardableResult
    static func register(_ file: File, in timeline: inout ProjectTimeline, replacing original: URL? = nil) -> UUID {
        let matches = timeline.mediaAssets.indices.filter {
            let path = ProjectFiles.resolve(timeline.mediaAssets[$0].path)
            return file.entry.references(path) || original?.path == path
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
        guard HTMLMotion.isHTMLMotion(url.path), currentMotionPaths(in: before).contains(where: {
            ProjectFiles.url($0).standardizedFileURL == url
        }) else { throw failure("Target must be an HTML motion used by the current project.") }
        let binAsset = before.mediaAssets.first { ProjectFiles.url($0.path).standardizedFileURL == url }
        let entry: AssetLibrary.Entry
        let localURL: URL
        if let local = library.motionEntry(for: url.path) {
            entry = local
            localURL = url
        } else {
            // Editing an older external source must leave other projects and the favorite untouched.
            entry = try library.keepCopy(of: url, kind: .animation, name: binAsset?.name ?? url.lastPathComponent)
            localURL = URL(fileURLWithPath: entry.revisionPaths?.first ?? entry.path)
        }
        guard localURL.resolvingSymlinksInPath().path.hasPrefix(library.folder.resolvingSymlinksInPath().path + "/") else {
            throw failure("Motion revisions must be saved inside the project media folder.")
        }
        let original = try String(contentsOf: url, encoding: .utf8)
        if HTMLMotionPage.authoredPage(original) == content && url == localURL {
            return Update(path: url.path, assetID: before.mediaAssets.first(where: {
                entry.references(ProjectFiles.resolve($0.path))
            })?.id ?? entry.id, unchanged: true)
        }
        let matching = (entry.revisionPaths ?? []).first {
            (try? String(contentsOfFile: $0, encoding: .utf8)).map { HTMLMotionPage.authoredPage($0) == content } == true
        }
        let revised: URL
        if let matching {
            revised = URL(fileURLWithPath: matching)
        } else {
            let stem = AssetLibrary.sanitized(HTMLMotion.isHTMLMotion(entry.name)
                ? (entry.name as NSString).deletingPathExtension : entry.name)
            let folder = localURL.deletingLastPathComponent()
            var version = (entry.revisionPaths?.count ?? 1) + 1
            var candidate: URL
            repeat {
                candidate = folder.appendingPathComponent("\(stem) · v\(version).html")
                version += 1
            } while FileManager.default.fileExists(atPath: candidate.path)
            revised = candidate
        }
        var removeOnFailure = matching == nil
        defer { if removeOnFailure { try? FileManager.default.removeItem(at: revised) } }
        if matching == nil { try HTMLMotionPage.standalonePage(content).write(to: revised, atomically: true, encoding: .utf8) }
        var nextEntry = entry
        var versions = entry.revisionPaths ?? [entry.path]
        if !versions.contains(revised.path) { versions.append(revised.path) }
        nextEntry.revisionPaths = versions
        nextEntry.path = revised.path
        let file = File(url: revised, entry: nextEntry, reused: matching != nil)
        let portable = ProjectFiles.portable(revised.path)
        var next = before
        let oldSlot = HTMLMotion.cameraSlot(in: original)
        let slot = HTMLMotion.cameraSlot(in: content)
        let oldScore = try MotionSoundScore.read(in: original)
        let newScore = try MotionSoundScore.read(in: content)
        var oldSoundPath: String?
        var newSoundPath: String?
        if oldScore != newScore {
            guard let package = ProjectFiles.package else { throw CocoaError(.fileNoSuchFile) }
            oldSoundPath = try oldScore.map { try ProjectFiles.portable($0.file(in: package).path) }
            newSoundPath = try newScore.map { try ProjectFiles.portable($0.file(in: package).path) }
        }
        func followsScore(_ path: String?) -> Bool {
            oldScore != newScore && path.map { ProjectFiles.url($0).standardizedFileURL } == oldSoundPath.map { ProjectFiles.url($0).standardizedFileURL }
        }
        for index in next.animationClips.indices where ProjectFiles.url(next.animationClips[index].sourcePath).standardizedFileURL == url {
            if next.animationClips[index].cameraSlot == oldSlot { next.animationClips[index].cameraSlot = slot }
            if followsScore(next.animationClips[index].soundtrack?.path) {
                var sound = next.animationClips[index].soundtrack
                next.animationClips[index].soundtrack = newSoundPath.map { path in
                    sound?.path = path
                    return sound ?? VisualClipSound(path: path, volume: MotionSoundScore.defaultVolume)
                }
            }
            next.animationClips[index].sourcePath = portable
        }
        if case var .edited(values) = next.sourceSequence {
            for index in values.indices where values[index].media?.motionPath.map({ ProjectFiles.url($0).standardizedFileURL == url }) == true {
                if values[index].media?.cameraSlot == oldSlot { values[index].media?.cameraSlot = slot }
                if followsScore(values[index].media?.transferSound?.path ?? values[index].media?.soundPath) {
                    values[index].media?.soundPath = newSoundPath
                    if let newSoundPath {
                        var sound = values[index].media?.transferSound ?? VisualClipSound(path: newSoundPath, volume: MotionSoundScore.defaultVolume)
                        sound.path = newSoundPath
                        values[index].media?.transferSound = sound
                    }
                    else { values[index].media?.transferSound = nil }
                }
                values[index].media?.motionPath = portable
            }
            next.sourceSequence = .edited(values)
        }
        let assetID = register(file, in: &next, replacing: url)
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
