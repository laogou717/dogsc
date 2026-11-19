import AppKit
import Foundation
import os

/// A serial writer coalesces snapshots per conversation, including deletion.
/// Encoding and filesystem work never run in a streaming UI update.
final class AgentConversationPersistence: @unchecked Sendable {
    private struct State: Sendable {
        var pending: [URL: [AgentChatModel.Message]?] = [:]
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "cn.laogou.dogsc.chat-persistence", qos: .utility)
    private let historyQueue = DispatchQueue(label: "cn.laogou.dogsc.chat-history", qos: .utility)
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
    }

    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }

    func save(_ messages: [AgentChatModel.Message], to url: URL) {
        enqueue(messages, at: url)
    }

    func remove(_ url: URL) {
        enqueue(nil, at: url)
        queue.async { [self] in drain() }
    }

    private func enqueue(_ messages: [AgentChatModel.Message]?, at url: URL) {
        let schedule = state.withLock { s in
            // updateValue stores a tombstone; dictionary subscript assignment
            // with nil would remove the pending deletion instead.
            s.pending.updateValue(messages, forKey: url)
            if s.scheduled { return false }
            s.scheduled = true; return true
        }
        if schedule { queue.asyncAfter(deadline: .now() + 0.25) { [self] in drain() } }
    }

    /// Used at explicit thread switches and application termination, never per token.
    func flush() { queue.sync { drain() } }

    func summaries(in workspace: URL, receive: @escaping @Sendable ([AgentChatModel.ThreadSummary]) -> Void) {
        queue.async { [self] in
            drain()
            historyQueue.async { [self] in receive(readSummaries(in: workspace)) }
        }
    }

    static func newThreadURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".json")
    }

    private func historyFiles(in workspace: URL) -> [(url: URL, date: Date)] {
        let folder = workspace.appendingPathComponent("conversations", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        // Directory enumeration may return a different spelling of the same
        // path (e.g. /private/var). All writes and deletions use workspace URLs.
        var urls = contents.map { folder.appendingPathComponent($0.lastPathComponent) }
        urls.append(workspace.appendingPathComponent("conversation.json"))
        return urls.compactMap { url -> (url: URL, date: Date)? in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date > $1.date }
    }

    func messages(at url: URL) -> [AgentChatModel.Message]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([AgentChatModel.Message].self, from: data)
    }

    /// Resolve the first conversation before a new request can be sent. Only
    /// the chosen transcript normally needs decoding on the opening path.
    func latest(in workspace: URL) -> (url: URL, messages: [AgentChatModel.Message]) {
        flush()
        for (url, _) in historyFiles(in: workspace) {
            if let list = messages(at: url), list.contains(where: { $0.role == .user }) {
                return (url, list)
            }
        }
        return (Self.newThreadURL(in: workspace), [])
    }

    private func readSummaries(in workspace: URL) -> [AgentChatModel.ThreadSummary] {
        historyFiles(in: workspace).compactMap { url, date in
            guard let first = messages(at: url)?.first(where: { $0.role == .user }) else { return nil }
            return .init(id: url.deletingPathExtension().lastPathComponent, title: first.text, date: date)
        }
    }

    private func drain() {
        while let batch = state.withLock({ s -> [URL: [AgentChatModel.Message]?]? in
            guard !s.pending.isEmpty else { s.scheduled = false; return nil }
            defer { s.pending.removeAll(keepingCapacity: true) }
            return s.pending
        }) {
            for (url, messages) in batch {
                guard let messages else { try? FileManager.default.removeItem(at: url); continue }
                let kept = Array(messages.filter { $0.role != .error }.suffix(200))
                guard let data = try? JSONEncoder().encode(kept) else { continue }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
