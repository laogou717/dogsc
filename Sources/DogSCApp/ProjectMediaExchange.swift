import AVFoundation
import Foundation
import RecorderCore

struct ProjectSourceMediaFiles: Sendable {
    let screen: URL
    let camera: URL?
    let microphone: URL?
}

struct ImportedCameraMedia: Sendable {
    let folderURL: URL
    let cameraRelativePath: String
    let cameraURL: URL
}

enum ProjectMediaExchangeError: LocalizedError {
    case missingProjectMedia(String)
    case invalidMedia(String)

    var errorDescription: String? {
        switch self {
        case let .missingProjectMedia(name):
            return "项目没有可导出的\(name)源文件。"
        case let .invalidMedia(reason):
            return reason
        }
    }
}

enum ProjectMediaExchange {
    static func exportSources(
        _ sources: ProjectSourceMediaFiles,
        projectTitle: String,
        into parentFolder: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let folder = uniqueExportFolder(
            parent: parentFolder,
            baseName: sanitizedFilename(projectTitle) + "-源文件"
        )
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        do {
            try copy(
                sources.screen,
                to: folder,
                baseName: "屏幕"
            )
            if let camera = sources.camera {
                try copy(camera, to: folder, baseName: "摄像头")
            }
            if let microphone = sources.microphone {
                try copy(microphone, to: folder, baseName: "麦克风")
            }
            return folder
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    static func inspectCameraReplacement(_ camera: URL) async throws {
        // SRC-003: an externally conformed camera file is an independent
        // auxiliary source. It neither needs an audio track nor the same
        // physical duration as the screen/microphone files. A shorter camera
        // simply becomes unavailable at its own end, matching normal project
        // behavior for an interrupted or deliberately trimmed camera track.
        _ = try await inspect(url: camera, requiredMediaType: .video)
    }

    static func importCameraReplacement(
        camera: URL,
        session: RecordingSession
    ) throws -> ImportedCameraMedia {
        let fileManager = FileManager.default
        let folderName = "camera-replacement-\(UUID().uuidString.lowercased())"
        let folder = session.packageURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        do {
            let cameraURL = try copy(camera, to: folder, baseName: "camera")
            return ImportedCameraMedia(
                folderURL: folder,
                cameraRelativePath: "media/\(folderName)/\(cameraURL.lastPathComponent)",
                cameraURL: cameraURL
            )
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private static func inspect(
        url: URL,
        requiredMediaType: AVMediaType
    ) async throws -> TimeInterval {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectMediaExchangeError.invalidMedia(
                "选择的文件不存在：\(url.path)"
            )
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: requiredMediaType)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty,
              duration.isFinite,
              duration > 0.01 else {
            let kind = requiredMediaType == .audio ? "音频" : "视频"
            throw ProjectMediaExchangeError.invalidMedia(
                "\(url.lastPathComponent) 没有可用的\(kind)轨。"
            )
        }
        return duration
    }

    @discardableResult
    private static func copy(
        _ source: URL,
        to folder: URL,
        baseName: String
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fallback = baseName == "麦克风" || baseName == "microphone"
            ? "m4a" : "mov"
        let fileExtension = source.pathExtension.isEmpty
            ? fallback : source.pathExtension.lowercased()
        let destination = folder
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private static func uniqueExportFolder(parent: URL, baseName: String) -> URL {
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(baseName)-\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let parts = value.components(separatedBy: CharacterSet(charactersIn: "/:"))
        let result = parts
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "未命名录制" : result
    }
}
