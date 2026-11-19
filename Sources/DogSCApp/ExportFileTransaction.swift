import Darwin
import Foundation

/// File-system boundary shared by export request validation and final output
/// publication. Keeping this independent from AVFoundation makes stale-temp
/// and path-alias behavior deterministic and directly testable.
enum ExportFileTransaction {
    static func collides(outputURL: URL, inputURLs: [URL]) -> Bool {
        let outputPath = canonicalPath(outputURL)
        var output = stat()
        let exists = stat(outputPath, &output) == 0
        return inputURLs.contains { input in
            if canonicalPath(input) == outputPath { return true }
            var file = stat()
            return exists && stat(input.path, &file) == 0 && file.st_dev == output.st_dev && file.st_ino == output.st_ino
        }
    }

    static func makeTemporaryURL(for finalURL: URL) -> URL {
        let folder = finalURL.deletingLastPathComponent()
        let base = finalURL.deletingPathExtension().lastPathComponent
        let fileExtension = finalURL.pathExtension.isEmpty ? "mp4" : finalURL.pathExtension
        return folder.appendingPathComponent(
            ".\(base).dogsc-export-\(UUID().uuidString.lowercased()).tmp.\(fileExtension)"
        )
    }

    static func promote(temporaryURL: URL, to finalURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
