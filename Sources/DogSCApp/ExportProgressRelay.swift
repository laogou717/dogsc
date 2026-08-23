import Foundation
import os

/// Pure state machine for coalescing worker progress without losing the newest
/// value. Keeping scheduling outside this value makes its cancellation and
/// latest-value semantics deterministic.
struct ExportProgressCoalescer {
    private(set) var latestValue: Double?
    private(set) var deliveryIsScheduled = false
    private(set) var isActive = true

    mutating func submit(_ value: Double) -> Bool {
        guard isActive else { return false }
        latestValue = Self.clamped(value)
        guard !deliveryIsScheduled else { return false }
        deliveryIsScheduled = true
        return true
    }

    mutating func takePendingForDelivery() -> Double? {
        guard isActive, deliveryIsScheduled else {
            deliveryIsScheduled = false
            latestValue = nil
            return nil
        }
        deliveryIsScheduled = false
        defer { latestValue = nil }
        return latestValue
    }

    mutating func invalidate() {
        isActive = false
        latestValue = nil
        deliveryIsScheduled = false
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Bridges per-frame export progress to the editor UI at a bounded cadence.
/// The renderer may complete frames faster than real time; queuing one
/// MainActor task per frame would make progress reporting compete with the
/// encoder and repeatedly rebuild the complete export sheet.
final class ExportProgressRelay: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: ExportProgressCoalescer()
    )
    private let deliveryDelay: DispatchTimeInterval
    private let delivery: @MainActor @Sendable (Double) -> Void

    init(
        maximumUpdatesPerSecond: Double = 15,
        delivery: @escaping @MainActor @Sendable (Double) -> Void
    ) {
        let updatesPerSecond = max(
            maximumUpdatesPerSecond.isFinite ? maximumUpdatesPerSecond : 15,
            1
        )
        deliveryDelay = .nanoseconds(Int((1_000_000_000 / updatesPerSecond).rounded()))
        self.delivery = delivery
    }

    func submit(_ value: Double) {
        let shouldSchedule = state.withLock { $0.submit(value) }
        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + deliveryDelay) { [weak self] in
            self?.deliverPending()
        }
    }

    func invalidate() {
        state.withLock { $0.invalidate() }
    }

    @MainActor
    private func deliverPending() {
        guard let value = state.withLock({ $0.takePendingForDelivery() }) else {
            return
        }
        delivery(value)
    }
}
