import AppKit
import CoreImage
import RecorderCore

/// View-owned HTML lookahead. Independent pages allow snapshot IPC/painting to
/// overlap without seeking a page while its previous frame is being captured.
/// Export renders its exact requested frames in its own session.
@MainActor
final class HTMLMotionPreviewBuffer {
    nonisolated static let frameRate = Double(PreviewAnimationCadence.framesPerSecond)

    private struct Content: Equatable {
        let path: String
        let properties: [String: AnimationPropertyValue]
        let edits: [String: MotionElementEdit]
        let size: CGSize
        let modified: Date
    }

    private let renderers = [HTMLMotionRenderer(), HTMLMotionRenderer()]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var inFlight = Set<Int>()
    private var content: Content?
    private var frames: [Int: CIImage] = [:]
    private var lastImage: CIImage?
    private var lastImageFrame: Int?
    private var wanted = 0
    private var frameLimit = 12
    private var failedFrames = Set<Int>()
    private var generation: UInt64 = 0
    private var didChange: (() -> Void)?
    private var revisionCheckedAt = -Double.infinity
    private var modified = Date.distantPast

    var onFramesChanged: (() -> Void)?
    var preparedFrames: [Int: CIImage] {
        var result = frames
        if let lastImageFrame, let lastImage { result[lastImageFrame] = lastImage }
        return result
    }
    var failedFrameIndices: Set<Int> { failedFrames }


    func reset() {
        guard content != nil || !tasks.isEmpty else { return }
        cancelRequests()
        renderers.forEach { $0.close() }
        content = nil
        frames.removeAll()
        lastImage = nil
        lastImageFrame = nil
        failedFrames.removeAll()
        didChange = nil
        revisionCheckedAt = -.infinity
    }


    private func cancelRequests() {
        generation &+= 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        inFlight.removeAll()
    }

    func image(path: String, properties: [String: AnimationPropertyValue],
               edits: [String: MotionElementEdit], time: Double, size: CGSize,
               memoryBudget: Int,
               didChange: @escaping () -> Void) -> CIImage? {
        let now = ProcessInfo.processInfo.systemUptime
        if content?.path != path || now - revisionCheckedAt > 0.5 {
            modified = (try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            revisionCheckedAt = now
        }
        let next = Content(path: path, properties: properties, edits: edits,
                           size: size, modified: modified)
        if content != next {
            let previous = content?.path == path ? lastImage : nil
            cancelRequests()
            frames.removeAll()
            failedFrames.removeAll()
            content = next
            lastImage = previous
            lastImageFrame = nil
        }
        self.didChange = didChange
        // Integer IDs avoid rounding misses between adjacent cached frames.
        wanted = Int((max(time, 0) * Self.frameRate + 1e-6).rounded(.down))
        let bytesPerFrame = max(size.width * size.height * 4, 1)
        frameLimit = max(1, min(12, Int(Double(memoryBudget) / bytesPerFrame)))
        let range = frameRange
        frames = frames.filter { range.contains($0.key) }
        failedFrames = failedFrames.filter { range.contains($0) }
        startRequests()
        // Future lookahead must not be shown early. A completed older frame
        // remains usable even after it leaves the small lookahead dictionary.
        if let frame = frames.keys.filter({ $0 <= wanted }).max(),
           let image = frames[frame], shouldPresent(frame) {
            lastImage = image
            lastImageFrame = frame
        }
        return lastImage
    }

    private var frameRange: ClosedRange<Int> {
        max(wanted - (frameLimit > 1 ? 1 : 0), 0)...(wanted + max(frameLimit - 2, 0))
    }

    private func shouldPresent(_ frame: Int) -> Bool {
        guard frame <= wanted else { return false }
        // Two workers can finish out of order. Never rewind the displayed
        // animation; a backwards seek may replace its now-future placeholder.
        guard let lastImageFrame else { return true }
        return frame >= lastImageFrame || lastImageFrame > wanted
    }

    private func startRequests() {
        guard let content else { return }
        let token = generation
        for worker in renderers.indices where tasks[worker] == nil {
            let candidates = wanted...frameRange.upperBound
            guard let frame = candidates.first(where: {
                frames[$0] == nil && !inFlight.contains($0) && !failedFrames.contains($0)
            }) else { break }
            inFlight.insert(frame)
            let renderer = renderers[worker]
            tasks[worker] = Task { @MainActor [weak self] in
                let image = await renderer.frame(path: content.path,
                    properties: content.properties, time: Double(frame) / Self.frameRate,
                    pixelSize: content.size, edits: content.edits)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.tasks[worker] = nil
                self.inFlight.remove(frame)
                var changed = false
                if let image {
                    if self.frameRange.contains(frame) { self.frames[frame] = image }
                    // Late is not invalid: discarding every frame that takes
                    // longer than one tick makes an overlay vanish in playback.
                    if self.shouldPresent(frame) {
                        self.lastImage = image
                        self.lastImageFrame = frame
                        changed = true
                    }
                } else {
                    self.failedFrames.insert(frame)
                    changed = frame == self.wanted
                }
                self.onFramesChanged?()
                if changed { self.didChange?() }
                self.startRequests()
            }
        }
    }
}
