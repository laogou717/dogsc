import CryptoKit
import Darwin
import Foundation

/// Versioned, bounded application cache. It contains derived audio only;
/// originals and project packages are never modified.
struct AudioSourceDiskCache: Sendable {
    let root: URL
    static let formatVersion = 1

    static var applicationDirectory: URL? {
        guard let id = Bundle.main.bundleIdentifier, ["cn.laogou.dogsc", "cn.laogou.dogsc.dev"].contains(id),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(id).appendingPathComponent("AudioSources-v\(formatVersion)")
    }

    func directory(for key: AudioSourceKey) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let hash = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash, isDirectory: true)
    }

    func restore(_ key: AudioSourceKey) -> PreparedAudioSource? {
        guard let directory = try? directory(for: key) else { return nil }
        return PreparedAudioSource.restore(key, at: directory)
    }

    func store(_ source: PreparedAudioSource, key: AudioSourceKey) throws -> PreparedAudioSource {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = restore(key) { return existing }
        let destination = try directory(for: key)
        if FileManager.default.fileExists(atPath: destination.path), !Self.removeIfUnleased(destination) {
            return source
        }
        do { return try source.publish(key, to: destination) }
        catch {
            // Another process may have published the same immutable source.
            if let existing = restore(key) { return existing }
            throw error
        }
    }

    /// A shared file lock follows every playing/exported lease, including
    /// artifacts evicted from the in-memory LRU and opened by another process.
    static func sharedLease(at directory: URL) throws -> Int32 {
        let fd = open(directory.appendingPathComponent("lease").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    @discardableResult private static func removeIfUnleased(_ directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("lease").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        do { try FileManager.default.removeItem(at: directory); return true } catch { return false }
    }

    func prune(byteLimit: Int64 = 8 * 1_024 * 1_024 * 1_024, entryLimit: Int = 96) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let rows = urls.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
             (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("source.caf").path)[.size] as? NSNumber)?.int64Value ?? 0)
        }.sorted { $0.1 < $1.1 }
        var bytes = rows.reduce(Int64(0)) { $0 + $1.2 }
        var count = rows.count
        for row in rows where bytes > byteLimit || count > entryLimit {
            if Self.removeIfUnleased(row.0) { bytes -= row.2; count -= 1 }
        }
    }
}
