import Darwin
import Foundation

/// Official continuous headless protocol: one user event in, one result out.
/// Keep stdout NDJSON separate from stderr and keep the native conversation warm.
@MainActor
final class AntigravitySession {
    let key: String
    let process = Process()
    private let input = Pipe()
    private let reader = Reader()
    private let writes = DispatchQueue(label: "cn.laogou.dogsc.antigravity-input")
    private var updateHandler: ((AntigravityCLI.StreamUpdate) -> Void)?
    private var completionHandler: ((String?, String) -> Void)?
    private(set) var isStopping = false
    var canSend: Bool { process.isRunning && !isStopping && completionHandler == nil }

    init(key: String, executable: String, arguments: [String], workspace: URL) throws {
        self.key = key
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AgentCLI.searchPath
        process.environment = environment
        process.standardInput = input
        let reader = self.reader
        try AgentCLICommand.start(process, consume: { [weak self] bytes in
            let updates = reader.decode(bytes)
            if !updates.isEmpty { DispatchQueue.main.async { self?.receive(updates) } }
        }, consumeError: { bytes in
            reader.appendDetail(String(decoding: bytes, as: UTF8.self))
        }, finished: { [weak self] task in
            let updates = reader.decode(Data(), atEnd: true)
            let status = task.terminationStatus
            let detail = reader.detail
            DispatchQueue.main.async {
                self?.receive(updates)
                self?.ended(status: status, detail: detail)
            }
        })
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func send(_ prompt: String, update: @escaping (AntigravityCLI.StreamUpdate) -> Void,
              completion: @escaping (String?, String) -> Void) throws {
        guard canSend else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": prompt]])
        data.append(0x0A)
        let payload = data
        reader.resetDetail()
        updateHandler = update
        completionHandler = completion
        let input = input.fileHandleForWriting
        writes.async { [weak self] in
            do { try input.write(contentsOf: payload) }
            catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.writeFailed(message) }
            }
        }
    }

    func cancel() {
        guard !isStopping else { return }
        isStopping = true
        AgentProcessCancellation.request(process)
    }

    private func writeFailed(_ message: String) {
        reader.appendDetail(message)
        cancel()
    }

    private func receive(_ updates: [AntigravityCLI.StreamUpdate]) {
        for update in updates {
            updateHandler?(update)
            if update.status != nil, !isStopping {
                let completion = completionHandler
                completionHandler = nil
                updateHandler = nil
                if update.status != "SUCCESS" {
                    isStopping = true
                    AgentProcessCancellation.request(process)
                }
                completion?(update.error, reader.detail)
            }
        }
    }

    private func ended(status: Int32, detail: String) {
        let completion = completionHandler
        completionHandler = nil
        updateHandler = nil
        try? input.fileHandleForWriting.close()
        // A result, rather than process teardown, normally finishes the turn.
        completion?("Antigravity CLI exited before its result (\(status)).", detail)
    }

    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var diagnostics = ""
        var detail: String { lock.withLock { diagnostics } }
        func resetDetail() { lock.withLock { diagnostics = "" } }
        func appendDetail(_ text: String) {
            lock.withLock { diagnostics = String((diagnostics + text + "\n").suffix(16_000)) }
        }

        // Only the command's serial output queue owns pending bytes and parser.
        private var pending = Data()
        private var decoder = AntigravityCLI.StreamDecoder()

        func decode(_ bytes: Data, atEnd: Bool = false) -> [AntigravityCLI.StreamUpdate] {
            pending.append(bytes)
            if atEnd && !pending.isEmpty { pending.append(0x0A) }
            var updates: [AntigravityCLI.StreamUpdate] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard !line.isEmpty else { continue }
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    updates.append(decoder.consume(event))
                } else {
                    appendDetail(String(decoding: line, as: UTF8.self))
                }
            }
            return updates
        }
    }
}

struct AntigravityCheckpoint: Codable {
    var conversationID: String
    var messageID: UUID?
    var briefingDigest: String

    static func load(thread: String, workspace: URL) -> Self? { all(in: workspace)[thread] }

    static func save(_ checkpoint: Self?, thread: String, workspace: URL) {
        var entries = all(in: workspace)
        entries[thread] = checkpoint
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file(in: workspace), options: .atomic) }
    }

    private static func file(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".agents/dogsc-sessions.json")
    }

    private static func all(in workspace: URL) -> [String: Self] {
        guard let data = try? Data(contentsOf: file(in: workspace)) else { return [:] }
        return (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
    }
}
