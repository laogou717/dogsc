import AVFoundation

/// One-shot bridge for AVPlayerItemVideoOutput's pull notification.
///
/// `requestNotificationOfMediaDataChange` has no effect unless the output has
/// a pull delegate. Keeping the bridge on MainActor gives cancellation,
/// timeout and delegate cleanup one serial owner without waking the editor on
/// an 8 ms polling timer while AVFoundation prepares the first frame.
@MainActor
final class InitialFrameMediaDataWaiter: NSObject,
    AVPlayerItemOutputPullDelegate,
    @unchecked Sendable
{
    private let output: AVPlayerItemVideoOutput
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolvedValue: Bool?

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
        super.init()
    }

    func wait(
        timeout: Duration,
        advanceInterval: TimeInterval = 0.005
    ) async -> Bool {
        if let resolvedValue { return resolvedValue }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let resolvedValue {
                    continuation.resume(returning: resolvedValue)
                    return
                }
                self.continuation = continuation
                output.setDelegate(self, queue: .main)
                output.requestNotificationOfMediaDataChange(
                    withAdvanceInterval: max(advanceInterval, 0)
                )
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(false)
            }
        }
    }

    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        Task { @MainActor [weak self] in
            self?.finish(true)
        }
    }

    private func finish(_ value: Bool) {
        guard resolvedValue == nil else { return }
        resolvedValue = value
        timeoutTask?.cancel()
        timeoutTask = nil
        output.setDelegate(nil, queue: nil)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}
