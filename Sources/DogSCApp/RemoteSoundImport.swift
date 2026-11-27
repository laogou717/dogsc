import Foundation
import RecorderCore

@MainActor
enum RemoteSoundImport {
    struct Result {
        let entry: AssetLibrary.Entry
        let reused: Bool
    }

    static func existing(url: String, library: AssetLibrary) -> AssetLibrary.Entry? {
        library.entries.first { $0.kind == .audio && $0.exists && $0.remoteSource?.url == url }
    }

    /// A content hash deduplicates the same sound reached by different URLs.
    static func save(_ download: RemoteSoundDownloader.Download, name: String?, library: AssetLibrary) throws -> Result {
        defer { try? FileManager.default.removeItem(at: download.file) }
        try Task.checkCancellation()
        library.reload()
        if let existing = library.entries.first(where: {
            $0.kind == .audio && $0.exists && $0.remoteSource?.sha256 == download.source.sha256
        }) { return Result(entry: existing, reused: true) }
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = String((raw.isEmpty ? "音效" : raw).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").prefix(100))
        let folder = library.folder(for: .audio)
        var target = folder.appendingPathComponent(base).appendingPathExtension(download.file.pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(download.file.pathExtension)
            suffix += 1
        }
        try FileManager.default.moveItem(at: download.file, to: target)
        let entry = AssetLibrary.Entry(path: target.path, kind: .audio, name: target.lastPathComponent,
            favorite: false, generated: true, remoteSource: download.source)
        do { try library.publish(entry) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        return Result(entry: entry, reused: false)
    }

    /// Bin registration is an ordinary undoable project edit. Undo leaves the
    /// downloaded project file available for redo.
    @discardableResult
    static func register(_ entry: AssetLibrary.Entry, store: EditorStore) throws -> UUID {
        var timeline = store.project.timeline
        if let asset = timeline.mediaAssets.first(where: {
            AssetLibrary.fileKey(ProjectFiles.resolve($0.path)) == AssetLibrary.fileKey(entry.path)
        }) { return asset.id }
        timeline.mediaAssets.append(MediaAsset(id: entry.id, path: ProjectFiles.portable(entry.path), kind: .audio, name: entry.name))
        try store.replaceTimeline(with: timeline, actionName: "下载音效")
        return entry.id
    }
}
