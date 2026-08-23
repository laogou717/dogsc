import CryptoKit
import Foundation
import RecorderCore

/// Small, source-versioned waveform cache shared by editor generations.
///
/// A waveform contains at most 6,000 Doubles, so keeping the derived result is
/// dramatically cheaper than decoding several minutes of PCM every time the
/// user closes and reopens a project. It lives in Library/Caches rather than in
/// the project package: cache failure can never damage or dirty authored data.
actor EditorTimelineWaveformCache {
    static let shared = EditorTimelineWaveformCache()

    private struct Envelope: Codable {
        let schemaVersion: Int
        let samples: [Double]
    }

    private let directory: URL
    private let entryLimit: Int
    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        entryLimit: Int = 24,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.entryLimit = max(entryLimit, 1)
        self.directory = directory ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("cn.laogou.dogsc", isDirectory: true)
            .appendingPathComponent("Waveforms", isDirectory: true)
    }

    func samples(
        for input: EditorMediaInput,
        sourceRange: MediaTimeRange,
        sampleCount: Int
    ) -> [Double]? {
        let url = cacheURL(
            for: input,
            sourceRange: sourceRange,
            sampleCount: sampleCount
        )
        guard let data = try? Data(contentsOf: url),
              let envelope = try? PropertyListDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 2,
              envelope.samples.count == sampleCount,
              envelope.samples.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return envelope.samples
    }

    func store(
        _ samples: [Double],
        for input: EditorMediaInput,
        sourceRange: MediaTimeRange,
        sampleCount: Int
    ) {
        guard samples.count == sampleCount,
              samples.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else { return }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(Envelope(schemaVersion: 2, samples: samples))
            try data.write(
                to: cacheURL(
                    for: input,
                    sourceRange: sourceRange,
                    sampleCount: sampleCount
                ),
                options: .atomic
            )
            removeOverflowEntries()
        } catch {
            // This is a disposable acceleration cache. Read-only volumes,
            // storage pressure or cleanup races must never block the editor.
        }
    }

    private func cacheURL(
        for input: EditorMediaInput,
        sourceRange: MediaTimeRange,
        sampleCount: Int
    ) -> URL {
        let version = input.version
        let fileSystemNumber = version.fileSystemNumber.map { String($0) } ?? "-"
        let fileNumber = version.fileNumber.map { String($0) } ?? "-"
        let fileSize = version.fileSize.map { String($0) } ?? "-"
        let modificationBits = version.modificationDate.map {
            String($0.timeIntervalSinceReferenceDate.bitPattern)
        } ?? "-"
        let rangeStartBits = String(sourceRange.start.bitPattern)
        let rangeDurationBits = String(sourceRange.duration.bitPattern)
        let identityFields: [String] = [
            "waveform-v1",
            version.standardizedPath,
            fileSystemNumber,
            fileNumber,
            fileSize,
            modificationBits,
            rangeStartBits,
            rangeDurationBits,
            String(sampleCount),
        ]
        let identity = identityFields.joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).plist", isDirectory: false)
    }

    private func removeOverflowEntries() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "plist",
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        guard entries.count > entryLimit else { return }
        for entry in entries
            .sorted(by: { $0.1 < $1.1 })
            .prefix(entries.count - entryLimit) {
            try? fileManager.removeItem(at: entry.0)
        }
    }
}
