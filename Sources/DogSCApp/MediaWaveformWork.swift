import Foundation
import OSLog

/// Optional previews must never occupy Swift's cooperative executor with a
/// blocking framework read. A cancelled/timed-out caller stops waiting; the
/// decoder remains owned by its worker until that read actually returns.
final class MediaWaveformWork: @unchecked Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "cn.laogou.dogsc.media-waveform"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "media-waveform")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Double], any Error>?
    private var result: Result<[Double], any Error>?
    private var deadline: DispatchWorkItem?
    let cancellation = ExportCancellationLatch()

    func run(timeout: TimeInterval = 20,
             read: @escaping @Sendable (ExportCancellationLatch) throws -> [Double]) async throws -> [Double] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let prior = lock.withLock { () -> Result<[Double], any Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let prior { continuation.resume(with: prior); return }
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.cancellation.request()
                    if self.complete(.failure(MediaAnalysisError.readerFailed("音频波形读取超时"))) {
                        Self.logger.error("waveform read timed out after \(timeout, privacy: .public)s")
                    }
                }
                let pending = lock.withLock {
                    guard result == nil else { return false }
                    self.deadline = deadline
                    return true
                }
                guard pending else { return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                Self.queue.addOperation { [self] in
                    guard !cancellation.isRequested else { return }
                    complete(Result { try read(cancellation) })
                }
            }
        } onCancel: {
            self.cancellation.request()
            self.complete(.failure(CancellationError()))
        }
    }

    @discardableResult
    private func complete(_ value: Result<[Double], any Error>) -> Bool {
        let finished = lock.withLock { () -> (Bool, CheckedContinuation<[Double], any Error>?) in
            guard result == nil else { return (false, nil) }
            result = value
            deadline?.cancel()
            deadline = nil
            let waiting = continuation
            continuation = nil
            return (true, waiting)
        }
        finished.1?.resume(with: value)
        return finished.0
    }
}
