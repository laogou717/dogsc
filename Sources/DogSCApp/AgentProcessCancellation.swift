import Darwin
import Foundation
import OSLog

enum AgentProcessCancellation {
    private struct Entry: Sendable {
        let pid: Int32
        let parent: Int32
        let started: String
    }
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "agent-cancellation")

    /// Process enumeration and shutdown never wait on the UI thread. Allow
    /// the CLI to flush its conversation before escalating a stuck shutdown.
    static func request(_ process: Process) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard process.isRunning else { return }
            let snapshot = snapshotEntries()
            let owned = family(of: process.processIdentifier, in: snapshot)
            guard process.isRunning else { return }
            for entry in owned.reversed() { kill(entry.pid, SIGTERM) }
            if owned.isEmpty { process.terminate() }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
                let current = snapshotEntries()
                var remaining = owned
                if process.isRunning {
                    remaining += family(of: process.processIdentifier, in: current)
                }
                if remaining.isEmpty, process.isRunning {
                    logger.warning("forcing stopped CLI to exit after process enumeration failed")
                    kill(process.processIdentifier, SIGKILL)
                }
                var signalled = Set<Int32>()
                for entry in remaining.reversed() {
                    // A former child may now be orphaned. Match its birth as
                    // well as PID so a reused PID cannot target another task.
                    guard current[entry.pid]?.started == entry.started,
                          signalled.insert(entry.pid).inserted else { continue }
                    logger.warning("forcing stopped CLI process to exit: pid=\(entry.pid, privacy: .public)")
                    kill(entry.pid, SIGKILL)
                }
            }
        }
    }

    private static func family(of pid: Int32, in entries: [Int32: Entry]) -> [Entry] {
        guard let root = entries[pid] else { return [] }
        var result = [root]
        var index = 0
        while index < result.count {
            let parent = result[index].pid
            result += entries.values.filter { $0.parent == parent }
            index += 1
        }
        return result
    }

    private static func snapshotEntries() -> [Int32: Entry] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,lstart="]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var result: [Int32: Entry] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            result[pid] = Entry(pid: pid, parent: parent,
                                started: fields[2].trimmingCharacters(in: .whitespaces))
        }
        return result
    }
}
