import Foundation

/// Detect a stalled media pipeline independently of its potentially blocked
/// reader queues. Reads as well as writes count: decoding a long accelerated
/// source interval must not be mistaken for a stuck output frame.
final class ExportActivityWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let timeout: TimeInterval
    private let onStall: @Sendable () -> Void
    private var lastProgress = DispatchTime.now().uptimeNanoseconds
    private var stopped = false

    init(
        timeout: TimeInterval = 120,
        onStall: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.onStall = onStall
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "cn.laogou.dogsc.export.watchdog", qos: .utility)
        )
        timer.schedule(deadline: .now() + timeout, repeating: min(timeout / 2, 2))
        timer.setEventHandler { [weak self] in self?.checkProgress() }
        timer.resume()
    }

    func recordProgress() {
        lock.lock()
        lastProgress = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
        timer.cancel()
    }

    private func checkProgress() {
        lock.lock()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastProgress) / 1_000_000_000
        let shouldStop = !stopped && elapsed >= timeout
        if shouldStop { stopped = true }
        lock.unlock()
        if shouldStop {
            timer.cancel()
            onStall()
        }
    }

    deinit { timer.cancel() }
}
