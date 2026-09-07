import Foundation
import RecorderCore

/// Immutable preset-owned media. Copies happen off MainActor. Keeping these
/// separate from project packages lets a scene survive moving its source project.
struct ScenePresetBackgroundAsset: Codable, Equatable, Sendable {
    let filename: String
    let isVideo: Bool

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogSC/ScenePresets/Assets", isDirectory: true)
    }

    var url: URL? {
        guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename != ".", filename != ".." else { return nil }
        return Self.directory.appendingPathComponent(filename)
    }

    var isAvailable: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var availableSource: BackgroundSource? {
        guard isAvailable, let url else { return nil }
        return isVideo ? .systemVideo(absolutePath: url.path) : .systemImage(absolutePath: url.path)
    }

    static func retain(from url: URL, isVideo: Bool) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.isEmpty ? (isVideo ? "mov" : "png") : url.pathExtension
            let asset = Self(filename: "scene-\(UUID().uuidString).\(ext)", isVideo: isVideo)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let destination = asset.url else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.copyItem(at: url, to: destination)
            return asset
        }.value
    }

    /// Only discard a newly copied asset whose preset never committed. Assets
    /// of committed presets can still belong to a new recording or undo history.
    func discardUncommittedCopy() async {
        guard let url else { return }
        _ = await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
