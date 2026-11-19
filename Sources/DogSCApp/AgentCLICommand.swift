import Darwin
import Foundation
import os

/// One serial reader owns the pipe, including its final drain. A child's exit
/// can arrive before the last readability notification, or before a descendant
/// closes its copy of stdout. Neither event should lose or delay the reply.
enum AgentCLICommand {
    private final class Reader: @unchecked Sendable {
        let pipe = Pipe()
        let source: DispatchSourceRead
        private let consume: @Sendable (Data) -> Void

        init(queue: DispatchQueue, consume: @escaping @Sendable (Data) -> Void) throws {
            self.consume = consume
            let handle = pipe.fileHandleForReading
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { try? handle.close() }
            source.activate()
        }

        // Only the serial output queue reads or closes this descriptor.
        func drain() {
            guard !source.isCancelled else { return }
            let fd = pipe.fileHandleForReading.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 { consume(Data(bytes.prefix(count))); continue }
                if count < 0, errno == EINTR { continue }
                if count == 0 || errno != EAGAIN { source.cancel() }
                return
            }
        }

        deinit { source.cancel() }
    }

    static func start(_ process: Process, mergesStandardError: Bool = false,
                      consume: @escaping @Sendable (Data) -> Void,
                      consumeError: (@Sendable (Data) -> Void)? = nil,
                      finished: @escaping @Sendable (Process) -> Void) throws {
        let queue = DispatchQueue(label: "cn.laogou.dogsc.cli-output", qos: .userInitiated)
        let output = try Reader(queue: queue, consume: consume)
        let errors = try consumeError.map { try Reader(queue: queue, consume: $0) }
        process.standardOutput = output.pipe
        if let errors { process.standardError = errors.pipe }
        else { process.standardError = mergesStandardError ? output.pipe : FileHandle.nullDevice }
        process.terminationHandler = { task in
            queue.async {
                output.drain()
                errors?.drain()
                output.source.cancel()
                errors?.source.cancel()
                task.terminationHandler = nil
                finished(task)
            }
        }
        do { try process.run() }
        catch {
            process.terminationHandler = nil
            throw error
        }
    }

    /// For model discovery, account checks and integration setup on a worker.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?,
                    mergesStandardError: Bool = false) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AgentCLI.searchPath
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        let output = OSAllocatedUnfairLock(initialState: Data())
        let done = DispatchSemaphore(value: 0)
        do {
            try start(task, mergesStandardError: mergesStandardError, consume: { bytes in
                output.withLock { $0.append(bytes) }
            }, finished: { _ in done.signal() })
            guard done.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .success else {
                AgentProcessCancellation.request(task)
                return (-1, appLocalized("命令超时。"))
            }
            return (task.terminationStatus, String(decoding: output.withLock { $0 }, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// All callbacks run on the same reader queue, in stream order. The final
    /// event is also delivered when stdout ends without a trailing newline.
    static func startLines(_ process: Process, consume: @escaping @Sendable ([Data], Data) -> Void,
                           finished: @escaping @Sendable (Process) -> Void) throws {
        final class Lines: @unchecked Sendable { var pending = Data() }
        let lines = Lines()
        try start(process, mergesStandardError: true, consume: { chunk in
            lines.pending.append(chunk)
            var complete: [Data] = []
            while let newline = lines.pending.firstIndex(of: 0x0A) {
                complete.append(lines.pending[..<newline])
                lines.pending.removeSubrange(lines.pending.startIndex...newline)
            }
            consume(complete, lines.pending)
        }, finished: { task in
            if !lines.pending.isEmpty { consume([lines.pending], Data()) }
            finished(task)
        })
    }
}
