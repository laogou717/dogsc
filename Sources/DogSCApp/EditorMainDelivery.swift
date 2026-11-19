import Foundation
import os

/// Coalesces UI notifications without making their producer wait for AppKit.
/// A blocked main thread retains a single latest value, not a queue of ticks.
final class EditorMainDelivery<Value: Sendable>: @unchecked Sendable {
    private struct State: Sendable { var value: Value?; var scheduled = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let receive: @MainActor @Sendable (Value) -> Void
    init(_ receive: @escaping @MainActor @Sendable (Value) -> Void) { self.receive = receive }
    func send(_ value: Value) {
        let schedule = state.withLock { s in
            s.value = value
            if s.scheduled { return false }
            s.scheduled = true; return true
        }
        guard schedule else { return }
        EditorMainRunLoop.perform { [weak self] in
            guard let self else { return }
            let value = self.state.withLock { s in
                defer { s.value = nil; s.scheduled = false }
                return s.value
            }
            if let value { self.receive(value) }
        }
    }
}

/// UI-owned work such as following a streaming reply. Replaces an outstanding
/// action rather than appending scroll/layout operations for every update.
@MainActor
final class EditorMainAction {
    private var pending: (@MainActor () -> Void)?
    private var scheduled = false

    func submit(_ action: @escaping @MainActor () -> Void) {
        pending = action
        guard !scheduled else { return }
        scheduled = true
        EditorMainRunLoop.perform { [weak self] in
            guard let self else { return }
            let action = self.pending
            self.pending = nil; self.scheduled = false
            action?()
        }
    }

    func cancel() { pending = nil }
}
