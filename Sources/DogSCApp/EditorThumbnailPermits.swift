import Foundation

/// Suspends excess thumbnail work without timers. Cancellation removes queued
/// work immediately so toggling display mode never waits for a batch to drain.
actor EditorThumbnailPermits {
    private let limit: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                order.append(id)
                waiting[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiting.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        active = max(active - 1, 0)
    }

    private func cancel(_ id: UUID) {
        order.removeAll { $0 == id }
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
