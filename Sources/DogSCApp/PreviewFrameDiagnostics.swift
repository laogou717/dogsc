import CoreImage
import Foundation
import os
import QuartzCore

/// Explicit, bounded diagnostics. Release does nothing unless launched with
/// DOGSC_PREVIEW_DIAGNOSTICS=1; no per-second production logs or frame images.
/// All shared state is lock-protected, and CI waits run on a utility collector,
/// never the main actor or the serial composition/presentation queue.
final class PreviewFrameDiagnostics: @unchecked Sendable {
    struct Frame: Sendable {
        let owner: PreviewFrameDiagnostics
        let captureID: UInt64
        let index: Int
        var queuedAt: CFTimeInterval
        let collectsRenderInfo: Bool

        func enqueued() -> Frame {
            var copy = self
            copy.queuedAt = CACurrentMediaTime()
            return copy
        }
    }

    private struct Measurement {
        let outputTime: TimeInterval
        let target: CFTimeInterval
        let evaluationMS: Double
        var queueMS: Double?
        var graphMS: Double?
        var drawableWaitMS: Double?
        var encodeMS: Double?
        var presentedAt: CFTimeInterval?
        var compileMS: Double?
        var executionMS: Double?
        var passes: Int?
        var pixels: Int?
        var submitted = false
        var failed = false
        var coalesced = false
    }

    private struct Capture {
        let epoch: UInt64
        let startedAt: CFTimeInterval
        var measurements: [Measurement] = []
        var lastInfoSampleAt: CFTimeInterval = 0
    }

    private let lock = NSLock()
    private var captures: [UInt64: Capture] = [:]
    private var lastEpoch: UInt64?
    private var captureCount: UInt64 = 0
    private var pendingRenderInfo = 0
    private let collector = DispatchQueue(label: "cn.laogou.dogsc.preview-diagnostics", qos: .utility)
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "preview-diagnostics")

    static func configured() -> PreviewFrameDiagnostics? {
        ProcessInfo.processInfo.environment["DOGSC_PREVIEW_DIAGNOSTICS"] == "1"
            ? PreviewFrameDiagnostics() : nil
    }

    func beginFrame(epoch: UInt64, outputTime: TimeInterval, target: CFTimeInterval,
                    evaluationMS: Double) -> Frame? {
        let now = CACurrentMediaTime()
        return lock.withLock {
            if lastEpoch != epoch {
                guard captureCount < 3 else { return nil }
                captureCount += 1
                lastEpoch = epoch
                captures[captureCount] = Capture(epoch: epoch, startedAt: now)
                let id = captureCount
                collector.asyncAfter(deadline: .now() + 11) { [weak self] in self?.report(id) }
            }
            let id = captureCount
            guard let startedAt = captures[id]?.startedAt, now - startedAt < 10,
                  let count = captures[id]?.measurements.count, count < 900 else { return nil }
            // Mutate in place; copying Capture here would copy its entire
            // measurement array on every append and distort the CPU timings.
            let collectInfo = now - (captures[id]?.lastInfoSampleAt ?? now) >= 0.25
                && pendingRenderInfo < 4
            if collectInfo { captures[id]?.lastInfoSampleAt = now }
            let frame = Frame(owner: self, captureID: id, index: count,
                              queuedAt: now, collectsRenderInfo: collectInfo)
            captures[id]?.measurements.append(Measurement(outputTime: outputTime, target: target,
                                                         evaluationMS: evaluationMS))
            return frame
        }
    }

    private func update(_ frame: Frame, _ change: (inout Measurement) -> Void) {
        lock.withLock {
            guard captures[frame.captureID]?.measurements.indices.contains(frame.index) == true else { return }
            change(&captures[frame.captureID]!.measurements[frame.index])
        }
    }

    func encoded(_ frame: Frame, queueMS: Double, graphMS: Double,
                 drawableWaitMS: Double, encodeMS: Double) {
        update(frame) {
            $0.queueMS = queueMS; $0.graphMS = graphMS
            $0.drawableWaitMS = drawableWaitMS; $0.encodeMS = encodeMS; $0.submitted = true
        }
    }

    func coalesced(_ frame: Frame) { update(frame) { $0.coalesced = true } }
    func failed(_ frame: Frame) { update(frame) { $0.failed = true } }

    func presented(_ frame: Frame, at time: CFTimeInterval) {
        // Zero means not shown/skipped. Command-buffer completion is expressly
        // not accepted as evidence that the window server displayed a frame.
        guard time > 0 else { return }
        update(frame) { $0.presentedAt = time }
    }

    func collectRenderInfo(_ task: CIRenderTask, for frame: Frame) {
        guard frame.collectsRenderInfo else { return }
        let reserved = lock.withLock {
            guard pendingRenderInfo < 4, captures[frame.captureID] != nil else { return false }
            pendingRenderInfo += 1
            return true
        }
        guard reserved else { return }
        // CIRenderTask is an immutable handle to already-enqueued CI work.
        let handle = RenderTaskHandle(task)
        collector.async { [self] in
            defer { lock.withLock { pendingRenderInfo -= 1 } }
            guard let info = try? handle.task.waitUntilCompleted() else { return }
            update(frame) {
                $0.compileMS = info.kernelCompileTime * 1_000
                $0.executionMS = info.kernelExecutionTime * 1_000
                $0.passes = info.passCount
                $0.pixels = info.pixelsProcessed
            }
        }
    }

    private final class RenderTaskHandle: @unchecked Sendable {
        let task: CIRenderTask
        init(_ task: CIRenderTask) { self.task = task }
    }

    private func report(_ id: UInt64) {
        guard let capture = lock.withLock({ captures.removeValue(forKey: id) }) else { return }
        let samples = capture.measurements
        let shown = samples.compactMap(\.presentedAt).sorted()
        let intervals = zip(shown.dropFirst(), shown).map { ($0 - $1) * 1_000 }
        func stats(_ values: [Double]) -> [String: Double] {
            guard !values.isEmpty else { return [:] }
            let sorted = values.sorted()
            return ["count": Double(values.count), "mean": values.reduce(0, +) / Double(values.count),
                    "p95": sorted[min(Int(Double(sorted.count - 1) * 0.95), sorted.count - 1)],
                    "max": sorted.last!]
        }
        let span = (shown.last ?? 0) - (shown.first ?? 0)
        let report: [String: Any] = [
            "capture": id, "epoch": capture.epoch, "previewBudgetFPS": PreviewAnimationCadence.framesPerSecond,
            "outputStart": samples.first?.outputTime ?? 0, "outputEnd": samples.last?.outputTime ?? 0,
            "ticks": samples.count, "submitted": samples.filter(\.submitted).count,
            "actuallyPresented": shown.count, "failed": samples.filter(\.failed).count,
            "coalesced": samples.filter(\.coalesced).count,
            "presentedFPS": span > 0 ? Double(max(shown.count - 1, 0)) / span : 0,
            "displayIntervalMS": stats(intervals),
            "deadlineDelayMS": stats(samples.compactMap { s in s.presentedAt.map { max($0 - s.target, 0) * 1_000 } }),
            "sceneEvaluationMS": stats(samples.map(\.evaluationMS)),
            "renderQueueWaitMS": stats(samples.compactMap(\.queueMS)),
            "ciGraphCPU_MS": stats(samples.compactMap(\.graphMS)),
            "drawableWaitMS": stats(samples.compactMap(\.drawableWaitMS)),
            "ciEncodeCPU_MS": stats(samples.compactMap(\.encodeMS)),
            "ciKernelCompileMS": stats(samples.compactMap(\.compileMS)),
            "ciKernelExecutionMS": stats(samples.compactMap(\.executionMS)),
            "ciPasses": stats(samples.compactMap(\.passes).map(Double.init)),
            "ciPixelsProcessed": stats(samples.compactMap(\.pixels).map(Double.init)),
            "note": "Presented FPS counts changed base drawables, not stationary holds or the separate cursor layer. CI timings are sampled; presentation-buffer time is not total GPU render time."
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        Self.logger.notice("preview measurement: \(text, privacy: .public)")
    }
}
