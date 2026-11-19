import CoreImage
import Foundation
import os
import RecorderCore

/// WebKit stays on its required actor. The playback engine only reads ready
/// lookahead frames; it never waits for a page snapshot or a main-thread reply.
final class PreviewMotionFrames: @unchecked Sendable {
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
        var lastImage: CIImage?
        var failures = Set<Int>()
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
        let content = Content(path: path, properties: properties, edits: edits, size: size, budget: memoryBudget)
        let (image, schedule) = state.withLock { s in
            if s.content != content {
                let samePixels = s.content?.path == content.path && s.content?.properties == content.properties
                    && s.content?.edits == content.edits
                if !samePixels {
                    s.frames.removeAll()
                    s.lastImage = nil
                }
                s.failures.removeAll()
            }
            s.content = content
            s.time = time; s.wanted = Int((max(time, 0) * HTMLMotionPreviewBuffer.frameRate + 1e-6).rounded(.down))
            s.changed = didChange
            let image = s.frames.keys.filter { $0 <= s.wanted }.max().flatMap { s.frames[$0] }
            // Play and pause can both ask for a frame behind the display
            // deadline. Keep the last image used for this content until an
            // eligible sample arrives. A prefetched frame alone can't fill it.
            if let image { s.lastImage = image }
            let schedule = !s.scheduled; s.scheduled = true
            return (image ?? s.lastImage, schedule)
        }
        if schedule { EditorMainRunLoop.perform { [self] in process() } }
        return image
    }
    func reset() {
        let reset = state.withLock { s in
            guard s.content != nil || !s.frames.isEmpty else { return false }
            s.content = nil; s.frames.removeAll(); s.lastImage = nil; s.failures.removeAll(); s.changed = nil
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
        let frames = buffer.preparedFrames, failures = buffer.failedFrameIndices
        let changed = state.withLock { s -> (@Sendable () -> Void)? in
            guard s.content == content else { return nil }
            let changed = s.frames.count != frames.count || frames.contains { s.frames[$0.key] !== $0.value }
                || s.failures != failures
            s.frames = frames; s.failures = failures
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
