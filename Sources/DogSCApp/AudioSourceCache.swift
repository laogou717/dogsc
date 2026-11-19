import AVFoundation
import Darwin
import Foundation
import RecorderCore

/// Process-owned scratch files. Normal exit removes them; the next process
/// also reclaims workspaces left by a crash without touching a running app.
private enum AudioSourceProcessDirectory {
    static func make() -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-audio-sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-program-audio", isDirectory: true)
        for workspace in [base, legacy] {
            for url in (try? FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? [] {
                if let pid = url.lastPathComponent.split(separator: "-").first.flatMap({ Int32($0) }),
                   kill(pid, 0) != 0, errno == ESRCH { try? FileManager.default.removeItem(at: url) }
            }
        }
        let directory = base.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID())", isDirectory: true)
        atexit { try? FileManager.default.removeItem(at: AudioWorkspace.root) }
        return directory
    }
}

enum AudioWorkspace {
    static let root = AudioSourceProcessDirectory.make()
}

/// A source identity never includes cuts, faders, timeline placement or duration.
struct AudioSourceKey: Codable, Hashable, Sendable {
    let file: EditorMediaFileVersion
    let trackID: CMPersistentTrackID
    let boostsLoudness: Bool

    func validate() throws {
        guard file == EditorMediaFileVersion(url: URL(fileURLWithPath: file.standardizedPath)) else {
            throw VideoExporterError.exportFailed("声音素材已变化，请重新打开项目后重试。")
        }
    }
}

/// Caches source PCM shared by every edit and export. Cancellation
/// retires a job only when its last consumer leaves; an export can safely join
/// source preparation. Eviction releases only the cache lease, never a playing file.
actor AudioSourceCache {
    static let shared = AudioSourceCache(persistentDirectory: AudioSourceDiskCache.applicationDirectory)
    private struct Job {
        let id: UUID
        let task: Task<PreparedAudioSource?, any Error>
        var consumers: Set<UUID>
    }
    private struct Entry {
        let key: AudioSourceKey
        let audio: PreparedAudioSource?
        let bytes: Int64
    }
    private var jobs: [(key: AudioSourceKey, job: Job)] = []
    private var entries: [Entry] = []
    private let capacity: Int
    private let byteLimit: Int64
    private let renderer: @Sendable (AudioSourceKey) async throws -> PreparedAudioSource?
    private let diskCache: AudioSourceDiskCache?
    private(set) var renderCount = 0

    init(capacity: Int = 32, byteLimit: Int64 = 1_024 * 1_024 * 1_024,
         persistentDirectory: URL? = nil,
         renderer: @escaping @Sendable (AudioSourceKey) async throws -> PreparedAudioSource? = PreparedAudioSource.render) {
        self.capacity = max(capacity, 0)
        self.byteLimit = max(byteLimit, 0)
        self.renderer = renderer
        diskCache = persistentDirectory.map { AudioSourceDiskCache(root: $0) }
    }

    var pendingConsumerCount: Int { jobs.reduce(0) { $0 + $1.job.consumers.count } }

    func source(for request: AudioSourceKey) async throws -> PreparedAudioSource? {
        try Task.checkCancellation()
        try request.validate()
        if let index = entries.firstIndex(where: { $0.key == request }) {
            let entry = entries.remove(at: index)
            if entry.audio.map({ FileManager.default.fileExists(atPath: $0.url.path) }) ?? true {
                entries.append(entry)
                return entry.audio
            }
        }
        let consumer = UUID()
        let job: Job
        if let index = jobs.firstIndex(where: { $0.key == request }) {
            jobs[index].job.consumers.insert(consumer)
            job = jobs[index].job
        } else {
            let renderer = self.renderer
            let diskCache = self.diskCache
            job = Job(id: UUID(), task: Task.detached(priority: .userInitiated) {
                if let restored = diskCache?.restore(request) { return restored }
                await self.noteRender()
                guard let rendered = try await renderer(request) else { return nil }
                let result = (try? diskCache?.store(rendered, key: request)) ?? rendered
                if let diskCache { Task.detached(priority: .utility) { diskCache.prune() } }
                return result
            }, consumers: [consumer])
            jobs.append((request, job))
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await job.task.value
                try Task.checkCancellation()
                try request.validate()
                if let index = jobs.firstIndex(where: { $0.job.id == job.id }) {
                    jobs.remove(at: index)
                    let bytes = result.flatMap {
                        (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as? NSNumber)?.int64Value
                    } ?? 0
                    entries.append(Entry(key: request, audio: result, bytes: bytes))
                    // Keep one oversized source reusable instead of duplicating
                    // a file still leased by an active editor or export.
                    while entries.count > capacity || (entries.count > 1 && entries.reduce(Int64(0), { $0 + $1.bytes }) > byteLimit) {
                        entries.removeFirst()
                    }
                }
                return result
            } catch {
                release(job: job.id, consumer: consumer)
                throw error
            }
        } onCancel: {
            Task { await self.release(job: job.id, consumer: consumer) }
        }
    }

    private func noteRender() { renderCount += 1 }

    private func release(job id: UUID, consumer: UUID) {
        guard let index = jobs.firstIndex(where: { $0.job.id == id }) else { return }
        jobs[index].job.consumers.remove(consumer)
        if jobs[index].job.consumers.isEmpty {
            jobs.remove(at: index).job.task.cancel()
        }
    }

    func removeAll() {
        entries.removeAll()
    }
}
