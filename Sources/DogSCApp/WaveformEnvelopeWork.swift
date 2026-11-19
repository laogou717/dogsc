import Combine
import Foundation
import os

struct WaveformEnvelopeResult: Sendable {
    let request: WaveformEnvelopeRequest
    let samples: [Double]
}

/// One running sample and one replaceable request. Old zoom/scroll requests
/// cancel between small chunks instead of building a queue behind the pointer.
final class WaveformEnvelopeWork: @unchecked Sendable {
    private struct State: Sendable {
        var pending: WaveformEnvelopeRequest?
        var generation: UInt64 = 0
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "cn.laogou.dogsc.waveform-envelope", qos: .userInitiated)
    private let receive: @Sendable (WaveformEnvelopeResult) -> Void

    init(receive: @escaping @Sendable (WaveformEnvelopeResult) -> Void) { self.receive = receive }

    func submit(_ request: WaveformEnvelopeRequest) {
        let schedule = state.withLock { s in
            s.pending = request; s.generation &+= 1
            if s.scheduled { return false }
            s.scheduled = true; return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    func cancel() { state.withLock { $0.pending = nil; $0.generation &+= 1 } }

    private func drain() {
        while let (request, generation) = state.withLock({ s -> (WaveformEnvelopeRequest, UInt64)? in
            guard let pending = s.pending else { s.scheduled = false; return nil }
            s.pending = nil
            return (pending, s.generation)
        }) {
            guard let samples = request.sample(isCancelled: { self.state.withLock { $0.generation != generation } }),
                  state.withLock({ $0.generation == generation }) else { continue }
            receive(WaveformEnvelopeResult(request: request, samples: samples))
        }
    }
}

@MainActor
final class WaveformEnvelopeModel: ObservableObject {
    @Published private(set) var displayed: WaveformEnvelopeResult?
    private var requested: WaveformEnvelopeRequest?
    private var recent: [WaveformEnvelopeResult] = []
    private var worker: WaveformEnvelopeWork?

    init() {
        let delivery = EditorMainDelivery<WaveformEnvelopeResult> { [weak self] result in
            guard let self, self.requested == result.request else { return }
            self.recent.removeAll { $0.request == result.request }
            self.recent.insert(result, at: 0)
            if self.recent.count > 6 { self.recent.removeLast() }
            self.displayed = result
        }
        worker = WaveformEnvelopeWork { delivery.send($0) }
    }

    deinit { worker?.cancel() }

    func update(_ request: WaveformEnvelopeRequest) {
        guard requested != request else { return }
        requested = request
        if let hit = recent.first(where: { $0.request == request }) {
            worker?.cancel()
            displayed = hit
        } else {
            if displayed?.request.channels != request.channels { displayed = nil }
            worker?.submit(request)
        }
    }
}
