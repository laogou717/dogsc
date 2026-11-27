import CoreImage
import Foundation
import os
import RecorderCore

/// WebKit stays on its required actor. The playback engine only reads ready
/// lookahead frames; it never waits for a page snapshot or a main-thread reply.
final class PreviewMotionFrames: @unchecked Sendable {
    struct Sample {
        let image: CIImage?
        let pending: Bool
    }
    private struct Content: Equatable, Sendable {
        let path: String
        let properties: [String: AnimationPropertyValue]
        let edits: [String: MotionElementEdit]
        let size: CGSize
        let budget: Int
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path == rhs.path && lhs.properties == rhs.properties && lhs.edits == rhs.edits && lhs.size == rhs.size
        }
    }
    private struct State: Sendable {
        var content: Content?
        var time: Double = 0
        var frames: [Int: CIImage] = [:]
        var lastFrame: (index: Int, image: CIImage)?
        var playbackEpoch: UInt64?
        var firstPlaybackFrame = 0
        var failures = Set<Int>()
        var sourceIsMissing = false
        var scheduled = false
        var changed: (@Sendable () -> Void)?
        var wanted = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let enqueue: @Sendable (@escaping @Sendable () -> Void) -> Void
    @MainActor private var buffer: HTMLMotionPreviewBuffer?
    init(enqueue: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) { self.enqueue = enqueue }

    func image(path: String, properties: [String: AnimationPropertyValue], edits: [String: MotionElementEdit],
               time: Double, size: CGSize, memoryBudget: Int,
               didChange: @escaping @Sendable () -> Void) -> CIImage? {
        sample(path: path, properties: properties, edits: edits, time: time, size: size,
               memoryBudget: memoryBudget, exact: false, didChange: didChange).image
    }

    func sample(path: String, properties: [String: AnimationPropertyValue], edits: [String: MotionElementEdit],
                time: Double, size: CGSize, memoryBudget: Int, exact: Bool, playbackEpoch: UInt64? = nil,
                didChange: @escaping @Sendable () -> Void) -> Sample {
        let content = Content(path: path, properties: properties, edits: edits, size: size, budget: memoryBudget)
        let (sample, schedule) = state.withLock { s in
            if s.content != content {
                if s.content?.path != path {
                    s.sourceIsMissing = !FileManager.default.fileExists(atPath: path)
                }
                let samePixels = s.content?.path == content.path && s.content?.properties == content.properties
                    && s.content?.edits == content.edits
                if !samePixels {
                    s.frames.removeAll()
                    s.lastFrame = nil
                    s.playbackEpoch = nil
                }
                s.failures.removeAll()
            }
            s.content = content
            s.time = time; s.wanted = Int((max(time, 0) * HTMLMotionPreviewBuffer.frameRate + 1e-6).rounded(.down))
            s.changed = didChange
            if s.playbackEpoch != playbackEpoch {
                s.playbackEpoch = playbackEpoch
                // Keep the anchor fixed as audio advances. A late first
                // paint can catch up, but a frame from before a seek cannot.
                s.firstPlaybackFrame = max(s.wanted - 1, 0)
            }
            let floor = playbackEpoch == nil ? 0 : s.firstPlaybackFrame
            if let index = s.frames.keys.filter({ $0 >= floor && $0 <= s.wanted }).max(),
               let image = s.frames[index] {
                s.lastFrame = (index, image)
            }
            // Play and pause can both ask for a frame behind the display
            // deadline. Keep the last image used for this content until an
            // eligible sample arrives. A prefetched frame alone can't fill it.
            let schedule = !s.scheduled; s.scheduled = true
            // Capture readiness and pixels together. A WebKit completion
            // between two separate reads could admit a job with a nil image.
            let fallback = s.lastFrame.flatMap { frame in
                frame.index >= floor && (playbackEpoch == nil || frame.index <= s.wanted + 1) ? frame.image : nil
            }
            let failed = s.sourceIsMissing || s.failures.contains(s.wanted)
            let pixels = exact && !failed ? s.frames[s.wanted] : fallback
            return (Sample(image: pixels, pending: pixels == nil && !failed), schedule)
        }
        if schedule { EditorMainRunLoop.perform { [self] in process() } }
        return sample
    }

    func reset() {
        let reset = state.withLock { s in
            guard s.content != nil || !s.frames.isEmpty else { return false }
            s.content = nil; s.frames.removeAll(); s.lastFrame = nil; s.failures.removeAll(); s.changed = nil
            return true
        }
        guard reset else { return }
        EditorMainRunLoop.perform { [self] in
            guard state.withLock({ $0.content == nil }) else { return }
            buffer?.reset(); buffer = nil
        }
    }
    @MainActor private func process() {
        let request = state.withLock { s in s.scheduled = false; return (s.content, s.time) }
        guard let content = request.0 else { return }
        if buffer == nil { buffer = HTMLMotionPreviewBuffer() }
        guard let buffer else { return }
        buffer.onFramesChanged = { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            self.publish(buffer, content: content)
        }
        _ = buffer.image(path: content.path, properties: content.properties, edits: content.edits,
            time: request.1, size: content.size, memoryBudget: content.budget, didChange: {})
        publish(buffer, content: content)
    }
    @MainActor private func publish(_ buffer: HTMLMotionPreviewBuffer, content: Content) {
        let frames = buffer.preparedFrames, failures = buffer.failedFrameIndices, missing = buffer.sourceIsMissing
        let changed = state.withLock { s -> (@Sendable () -> Void)? in
            guard s.content == content else { return nil }
            let changed = s.frames.count != frames.count || frames.contains { s.frames[$0.key] !== $0.value }
                || s.failures != failures || s.sourceIsMissing != missing
            s.frames = frames; s.failures = failures; s.sourceIsMissing = missing
            return changed ? s.changed : nil
        }
        if let changed { enqueue(changed) }
    }
}

extension SharedPreviewEngine {
    func makeMotionBuffer() -> PreviewMotionFrames {
        PreviewMotionFrames { [weak self] action in self?.renderQueue.async(execute: action) }
    }
}
