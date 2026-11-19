import Foundation
import OSLog

let recordingFinalizationLogger = Logger(subsystem: "cn.laogou.dogsc", category: "recording-finalization")

/// A missing framework callback must not strand the recording document. A
/// late callback is ignored after the deadline has released its one waiter.
@MainActor
enum ScreenCaptureOperation {
    static func wait(_ name: String, timeout: TimeInterval = 10, timeoutMessage: String,
                     start: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        recordingFinalizationLogger.notice("SCK operation started: \(name, privacy: .public)")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let completion = Completion(continuation)
                let deadline = DispatchWorkItem {
                    completion.resolve(.failure(ScreenRecorderError.recordingFailed(timeoutMessage)))
                }
                completion.install(deadline)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                start { error in
                    completion.resolve(error.map { .failure($0) } ?? .success(()))
                }
            }
            recordingFinalizationLogger.notice("SCK operation finished: \(name, privacy: .public), seconds=\(ProcessInfo.processInfo.systemUptime - started, privacy: .public)")
        } catch {
            recordingFinalizationLogger.error("SCK operation failed: \(name, privacy: .public), seconds=\(ProcessInfo.processInfo.systemUptime - started, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var deadline: DispatchWorkItem?

        init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

        func install(_ deadline: DispatchWorkItem) { lock.withLock { self.deadline = deadline } }

        func resolve(_ result: Result<Void, any Error>) {
            let waiting = lock.withLock {
                let waiting = continuation
                continuation = nil
                deadline?.cancel()
                deadline = nil
                return waiting
            }
            waiting?.resume(with: result)
        }
    }
}
