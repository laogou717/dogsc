import AVFoundation
import Darwin
import Foundation
import RecorderCore

struct RecordingImportPreview: Identifiable, Sendable {
    let id = UUID()
    let packageURL: URL
    var project: RecorderProject
    let sourceDurations: [UUID: TimeInterval]
    let sourceSizes: [UUID: CGSize]
    let frameRate: Int
    let cameraCrops: [UUID: NormalizedCrop]
    let fileVersions: [String: EditorMediaFileVersion]
    let outputDuration: TimeInterval
    var name: String { EditorProjectIdentity(packageURL: packageURL).displayTitle(for: project.title) }
    var hasCamera: Bool { project.sources.contains { $0.media.camera != nil } }
    var hasMicrophone: Bool { project.sources.contains { $0.media.microphone != nil } }
}

struct RecordingImportBatch: Identifiable, Sendable {
    let id = UUID()
    let previews: [RecordingImportPreview]
}

enum RecordingImportError: LocalizedError {
    case missingFile(String), changed, sameProject, missingRecording
    var errorDescription: String? {
        switch self {
        case let .missingFile(path): String(format: appLocalized("导入失败，找不到素材：%@"), path)
        case .changed: appLocalized("项目或素材已发生变化，请重新导入。")
        case .sameProject: appLocalized("请选择当前项目之外的录屏项目。")
        case .missingRecording: appLocalized("这个项目没有可导入的录制。")
        }
    }
}

struct PreparedRecordingImport: Sendable {
    let project: RecorderProject
    let createdDirectory: URL?
    let rootSourceID: UUID
    let sourceDurations: [UUID: TimeInterval]
    func discard() { if let createdDirectory { try? FileManager.default.removeItem(at: createdDirectory) } }
}

struct PreparedRecordingImportBatch: Sendable {
    let project: RecorderProject
    let createdDirectories: [URL]
    let firstSourceID: UUID?
    func discard() {
        for directory in createdDirectories { try? FileManager.default.removeItem(at: directory) }
    }
}

/// What copying a recording into the project will actually cost. On one APFS
/// volume a copy clones blocks and costs almost nothing, so only a
/// cross-volume import is worth warning about.
struct RecordingImportCopyCost: Equatable, Sendable {
    var crossesVolumes = false
    var bytes: Int64 = 0
}

enum RecordingProjectImporter {
    /// Prepare the complete batch before committing a single undoable edit.
    /// A failed or cancelled member removes every new directory in the batch.
    static func prepareBatch(_ previews: [RecordingImportPreview], into current: RecorderProject,
                             packageURL: URL, sourceDurations: [UUID: TimeInterval],
                             options: RecordingProjectImportOptions) async throws -> PreparedRecordingImportBatch {
        guard !previews.isEmpty else { throw RecordingImportError.missingRecording }
        var project = current
        var durations = sourceDurations
        var directories: [URL] = []
        var firstSourceID: UUID?
        do {
            for preview in previews {
                try Task.checkCancellation()
                let prepared = try await prepare(preview, into: project, packageURL: packageURL,
                    sourceDurations: durations, options: options)
                if let directory = prepared.createdDirectory { directories.append(directory) }
                project = prepared.project
                durations = prepared.sourceDurations
                if firstSourceID == nil { firstSourceID = prepared.rootSourceID }
            }
            try Task.checkCancellation()
            for preview in previews { try verify(preview.fileVersions) }
            return PreparedRecordingImportBatch(project: project, createdDirectories: directories,
                firstSourceID: firstSourceID)
        } catch {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    /// Copying is no longer a question the panel asks, but a cross-volume
    /// import really does write the bytes again, so the panel can say so.
    static func copyCost(of previews: [RecordingImportPreview], into destination: URL?) -> RecordingImportCopyCost {
        // The device a path sits on is exactly what decides whether
        // clonefile can share blocks instead of writing them again.
        func volume(_ url: URL) -> dev_t? {
            var url = url.standardizedFileURL
            var info = stat()
            while stat(url.path, &info) != 0 {
                guard url.pathComponents.count > 1 else { return nil }
                url = url.deletingLastPathComponent()
            }
            return info.st_dev
        }
        guard let destination, let target = volume(destination) else { return RecordingImportCopyCost() }
        var cost = RecordingImportCopyCost()
        for preview in previews where volume(preview.packageURL) != target {
            cost.crossesVolumes = true
            let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
            guard let items = FileManager.default.enumerator(at: preview.packageURL,
                includingPropertiesForKeys: keys) else { continue }
            for case let file as URL in items {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                cost.bytes += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return cost
    }

    /// Read-only: neither source migrations, locks nor recent-project history
    /// are written. Future schema rejection follows the normal opening path.
    static func inspect(_ url: URL) async throws -> RecordingImportPreview {
        let package = url.standardizedFileURL.resolvingSymlinksInPath()
        var versions: [String: EditorMediaFileVersion] = [:]
        for name in ["project.json", "project.previous.json"] {
            let file = package.appendingPathComponent(name)
            versions[file.path] = EditorMediaFileVersion(url: file)
        }
        let loaded = try ProjectStore.loadProject(at: package, readOnly: true)
        guard loaded.project.media != nil else { throw RecordingImportError.missingRecording }
        var durations: [UUID: TimeInterval] = [:]
        var sizes: [UUID: CGSize] = [:]
        var crops: [UUID: NormalizedCrop] = [:]
        var frameRate = 0
        for source in loaded.project.sources {
            try Task.checkCancellation()
            func file(_ reference: ProjectMediaReference?) throws -> URL? {
                guard let reference else { return nil }
                guard let url = ProjectStore.resolveMediaPath(reference.relativePath, session: loaded.session) else {
                    throw RecordingImportError.missingFile(reference.relativePath)
                }
                versions[url.path] = EditorMediaFileVersion(url: url)
                return url
            }
            let pointer = try file(source.media.pointerEvents)
            let events = try pointer.map { try ProjectStore.decodePointerEvents(at: $0) } ?? []
            let tracks = try await TimelinePreviewCompositionLoader.loadRecording(
                screenURL: file(source.media.screen), cameraURL: file(source.media.camera),
                microphoneURL: file(source.media.microphone), manifest: source.media,
                pointerEvents: events, cameraContentCrop: source.cameraContentCrop)
            durations[source.id] = tracks.screen.timeRange.duration.seconds
            sizes[source.id] = tracks.screen.displaySize
            if source.id == RecordingSource.primaryID {
                frameRate = Int(((try? await tracks.screen.track.load(.nominalFrameRate)) ?? 0).rounded())
            }
            crops[source.id] = tracks.cameraContentCrop
        }
        let map = try TimelineMap(sourceSequence: loaded.project.timeline.sourceSequence, sourceDurations: durations)
        guard map.outputDuration > 0 else { throw RecordingImportError.missingRecording }
        try verify(versions)
        return RecordingImportPreview(packageURL: package, project: loaded.project,
            sourceDurations: durations, sourceSizes: sizes, frameRate: frameRate, cameraCrops: crops,
            fileVersions: versions, outputDuration: map.outputDuration)
    }

    static func verify(_ versions: [String: EditorMediaFileVersion]) throws {
        guard versions.allSatisfy({ EditorMediaFileVersion(url: URL(fileURLWithPath: $0.key)) == $0.value }) else {
            throw RecordingImportError.changed
        }
    }

    /// Only the recordings themselves and the bin travel: the imported
    /// programme's own edit is not reproduced here, so none of its timed
    /// clips or their files are relocated.
    static func prepare(_ preview: RecordingImportPreview, into current: RecorderProject,
                        packageURL: URL, sourceDurations: [UUID: TimeInterval],
                        options: RecordingProjectImportOptions) async throws -> PreparedRecordingImport {
        let destination = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        let source = preview.packageURL
        guard destination != source, !destination.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(destination.path + "/") else { throw RecordingImportError.sameProject }
        try verify(preview.fileVersions)
        let ids = Dictionary(uniqueKeysWithValues: preview.project.sources.map { ($0.id, UUID()) })
        guard let rootID = ids[RecordingSource.primaryID] else { throw RecordingImportError.missingRecording }
        let files = RecordingImportFiles(source: source, destination: destination,
            directory: "Sources/" + rootID.uuidString, copying: options.copiesMedia)
        do {
            var imported = preview.project
            imported.title = preview.name
            func manifest(_ original: ProjectMediaManifest) throws -> ProjectMediaManifest {
                func reference(_ original: ProjectMediaReference) throws -> ProjectMediaReference {
                    var r = original
                    r.relativePath = try files.relocate(r.relativePath)
                    r.syncAnchors = r.syncAnchors.map { MediaSyncAnchor(sourceTime: $0.sourceTime, offset: $0.offset) }
                    return r
                }
                return try ProjectMediaManifest(screen: reference(original.screen),
                    camera: original.camera.map(reference), microphone: original.microphone.map(reference),
                    pointerEvents: original.pointerEvents.map(reference))
            }
            imported.media = try imported.media.map(manifest)
            for i in imported.additionalSources.indices {
                imported.additionalSources[i].media = try manifest(imported.additionalSources[i].media)
                imported.additionalSources[i].cameraContentCrop = preview.cameraCrops[imported.additionalSources[i].id]
            }
            // A bin entry is a convenience, not part of the recording: one
            // whose file has gone is dropped rather than failing the import.
            imported.timeline.mediaAssets = imported.timeline.mediaAssets.compactMap { asset in
                var asset = asset
                guard let path = try? files.relocate(asset.path, html: asset.kind == .animation) else { return nil }
                asset.path = path
                return asset
            }
            try Task.checkCancellation()
            var result = try RecordingProjectImport.adding(imported, into: current,
                currentDurations: sourceDurations, importedDurations: preview.sourceDurations, sourceIDs: ids)
            if let index = result.additionalSources.firstIndex(where: { $0.id == rootID }) {
                result.additionalSources[index].cameraContentCrop = preview.cameraCrops[RecordingSource.primaryID]
            }
            try verify(preview.fileVersions)
            try files.publish()
            let durations = sourceDurations.merging(Dictionary(uniqueKeysWithValues: preview.sourceDurations.compactMap {
                    old, duration in ids[old].map { ($0, duration) }
                })) { _, new in new }
            return PreparedRecordingImport(project: result, createdDirectory: files.publishedURL,
                rootSourceID: rootID, sourceDurations: durations)
        } catch {
            files.discard()
            throw error
        }
    }
}

/// Clones each file on APFS, falling back to a real copy across volumes.
/// A private staging directory is published only after every required file
/// and the resulting project validate; undo keeps files available for redo.
private final class RecordingImportFiles {
    let source: URL
    let destination: URL
    let directory: String
    let copying: Bool
    private let staging: URL
    private var versions: [String: EditorMediaFileVersion] = [:]
    private var copied = Set<String>()
    private var mirroredPackage = false
    private(set) var publishedURL: URL?
    init(source: URL, destination: URL, directory: String, copying: Bool) {
        self.source = source; self.destination = destination; self.directory = directory; self.copying = copying
        staging = destination.appendingPathComponent("Sources/.import-" + UUID().uuidString)
    }
    private func relative(_ url: URL) -> String {
        if url.path.hasPrefix(source.path + "/") { return "Project/" + url.path.dropFirst(source.path.count + 1) }
        // Preserve the directory hierarchy for relative HTML dependencies,
        // including ../ references, without copying unrelated external files.
        return "External/" + url.path.dropFirst()
    }
    func relocate(_ path: String, html: Bool = false) throws -> String {
        guard let url = ProjectStore.resolveMediaPath(path, session: RecordingSession(packageURL: source)) else {
            throw RecordingImportError.missingFile(path)
        }
        versions[url.path] = EditorMediaFileVersion(url: url)
        guard copying else { return url.path }
        try copyFile(url)
        if html {
            if url.path.hasPrefix(source.path + "/"), !mirroredPackage {
                mirroredPackage = true
                // HTML is executable authoring data and can construct relative
                // paths dynamically. Mirror its project resources, preserving
                // their layout, instead of flattening the page to a movie.
                if let items = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let file as URL in items {
                        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { try copyFile(file) }
                    }
                }
            }
            try copyHTMLDependencies(url, visited: [])
        }
        return directory + "/" + relative(url)
    }
    private func copyFile(_ url: URL) throws {
        try Task.checkCancellation()
        guard copied.insert(url.path).inserted else { return }
        guard FileManager.default.isReadableFile(atPath: url.path),
              (try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true else {
            throw RecordingImportError.missingFile(url.lastPathComponent)
        }
        versions[url.path] = EditorMediaFileVersion(url: url)
        let target = staging.appendingPathComponent(relative(url))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(url.path, target.path, 0) != 0 { try FileManager.default.copyItem(at: url, to: target) }
    }
    private func copyHTMLDependencies(_ url: URL, visited: Set<String>) throws {
        guard !visited.contains(url.path), ["dmhtml", "html", "htm", "css", "js", "mjs"].contains(url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var visited = visited; visited.insert(url.path)
        let expression = try NSRegularExpression(pattern: #"[\"']([^\"'\n]+)[\"']|url\(\s*([^\s\)]+)\s*\)"#)
        var replacements: [(NSRange, String)] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let swiftRange = Range(range, in: text) else { continue }
            let value = String(text[swiftRange])
            guard !value.hasPrefix("#"),
                  let dependency = URL(string: value, relativeTo: url.deletingLastPathComponent())?.absoluteURL,
                  dependency.isFileURL else { continue }
            let file = URL(fileURLWithPath: dependency.path).standardizedFileURL
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            try copyFile(file)
            try copyHTMLDependencies(file, visited: visited)
            let base = staging.appendingPathComponent(relative(url)).deletingLastPathComponent().pathComponents
            let target = staging.appendingPathComponent(relative(file)).pathComponents
            var common = 0
            while common < min(base.count, target.count), base[common] == target[common] { common += 1 }
            let rewritten = (Array(repeating: "..", count: base.count - common) + target.dropFirst(common)).joined(separator: "/")
            var components = URLComponents(url: dependency, resolvingAgainstBaseURL: true)
            components?.scheme = nil; components?.host = nil; components?.path = rewritten
            replacements.append((range, components?.string ?? rewritten))
        }
        if !replacements.isEmpty {
            let rewritten = NSMutableString(string: text)
            for (range, value) in replacements.reversed() { rewritten.replaceCharacters(in: range, with: value) }
            try (rewritten as String).write(to: staging.appendingPathComponent(relative(url)), atomically: true, encoding: .utf8)
        }
    }

    func publish() throws {
        try RecordingProjectImporter.verify(versions)
        guard copying else { return }
        let target = destination.appendingPathComponent(directory)
        try FileManager.default.moveItem(at: staging, to: target)
        publishedURL = target
    }
    func discard() {
        try? FileManager.default.removeItem(at: staging)
        if let publishedURL { try? FileManager.default.removeItem(at: publishedURL) }
    }
}

extension EditorStore {
    @discardableResult
    func importRecordingProject(_ preview: RecordingImportPreview, into packageURL: URL,
                                sourceDurations: [UUID: TimeInterval],
                                options: RecordingProjectImportOptions) async throws -> UUID? {
        try await importRecordingProjects([preview], into: packageURL,
            sourceDurations: sourceDurations, options: options)
    }

    /// The editor view still hands the import panel a position. It is
    /// ignored — an import only joins the bin — and this overload goes away
    /// with that call site.
    @discardableResult
    func importRecordingProjects(_ previews: [RecordingImportPreview], into packageURL: URL,
                                 at _: TimeInterval, sourceDurations: [UUID: TimeInterval],
                                 options: RecordingProjectImportOptions) async throws -> UUID? {
        try await importRecordingProjects(previews, into: packageURL,
            sourceDurations: sourceDurations, options: options)
    }

    /// One undoable step that leaves the imported recordings in the bin and
    /// reveals the first of them; placing them is the user's own next move.
    @discardableResult
    func importRecordingProjects(_ previews: [RecordingImportPreview], into packageURL: URL,
                                 sourceDurations: [UUID: TimeInterval],
                                 options: RecordingProjectImportOptions) async throws -> UUID? {
        let before = project
        let generation = recordingImportGeneration
        let prepared = try await RecordingProjectImporter.prepareBatch(previews, into: before, packageURL: packageURL,
            sourceDurations: sourceDurations, options: options)
        do {
            try Task.checkCancellation()
            guard project == before, recordingImportGeneration == generation else { throw RecordingImportError.changed }
            try replaceProject(with: prepared.project, actionName: "导入录屏项目")
            if let id = prepared.firstSourceID { revealRecording(id) }
            return prepared.firstSourceID
        } catch { prepared.discard(); throw error }
    }
}
