import Foundation
import RecorderCore

/// Keeps the indexed playback tracks coherent with one exact project
/// snapshot without publishing another SwiftUI state change. The previous
/// `onChange` chain rendered once with the new project plus stale tracks, then
/// rebuilt each changed track and rendered a second time. Timeline gestures
/// therefore paid two layout/render passes and could briefly evaluate a mixed
/// frame. This cache updates synchronously inside the existing body pass and
/// reuses the indexes for unrelated overlay/hover changes.
struct EditorCanvasPlaybackTracks {
    let zoom: ZoomAnimationTrack
    let screenMotion: ScreenMotionTrack
    let cameraMotion: CameraMotionTrack
    let stickers: StickerTransitionTrack
}

@MainActor
final class EditorCanvasPlaybackTrackCache {
    private var zoomClips: [ZoomAnimationClip]
    private var screenClips: [ScreenMotionClip]
    private var cameraClips: [CameraMotionClip]
    private var stickerClips: [StickerClip]
    private var zoomTrack: ZoomAnimationTrack
    private var outputDuration: TimeInterval?
    private var screenMotionTrack: ScreenMotionTrack
    private var cameraMotionTrack: CameraMotionTrack
    private var stickerTrack: StickerTransitionTrack

    init(project: RecorderProject) {
        zoomClips = project.zoomAnimations
        screenClips = project.timeline.screenMotionClips
        cameraClips = project.timeline.cameraMotionClips
        stickerClips = project.timeline.stickerClips
        zoomTrack = ZoomAnimationTrack(zoomClips)
        screenMotionTrack = ScreenMotionTrack(screenClips)
        cameraMotionTrack = CameraMotionTrack(cameraClips)
        stickerTrack = StickerTransitionTrack(stickerClips)
    }

    func tracks(for project: RecorderProject, outputDuration: TimeInterval) -> EditorCanvasPlaybackTracks {
        if zoomClips != project.zoomAnimations || self.outputDuration != outputDuration {
            self.outputDuration = outputDuration
            zoomClips = project.zoomAnimations
            zoomTrack = ZoomAnimationTrack(zoomClips, outputDuration: outputDuration)
        }
        if screenClips != project.timeline.screenMotionClips {
            screenClips = project.timeline.screenMotionClips
            screenMotionTrack = ScreenMotionTrack(screenClips)
        }
        if cameraClips != project.timeline.cameraMotionClips {
            cameraClips = project.timeline.cameraMotionClips
            cameraMotionTrack = CameraMotionTrack(cameraClips)
        }
        if stickerClips != project.timeline.stickerClips {
            stickerClips = project.timeline.stickerClips
            stickerTrack = StickerTransitionTrack(stickerClips)
        }
        return EditorCanvasPlaybackTracks(
            zoom: zoomTrack,
            screenMotion: screenMotionTrack,
            cameraMotion: cameraMotionTrack,
            stickers: stickerTrack
        )
    }
}

/// Cache only a few semantic plans, never decoded frames or full-size pixels.
/// Hover/focus updates reuse these inputs; editing an effect invalidates them.
@MainActor
final class EditorCanvasEffectPrewarmPlanCache {
    private struct Input: Equatable {
        let evaluation: CanvasPlaybackEvaluationContext
        let times: [TimeInterval]
    }
    private var input: Input?
    private var renderPlans: [FrameRenderPlan] = []

    func plans(
        around time: TimeInterval,
        using evaluation: CanvasPlaybackEvaluationContext
    ) -> [FrameRenderPlan] {
        let next = Input(evaluation: evaluation,
                         times: PreviewAnimationPreparation.prewarmTimes(around: time, using: evaluation))
        if input == next { return renderPlans }
        renderPlans = next.times.map { evaluation.frame(at: $0).renderPlan }
        input = next
        return renderPlans
    }
}

/// Crop handles mutate only the draft rectangle, not the flat source image
/// displayed underneath them. Cache that one normalized source frame across
/// draft changes so a drag updates SwiftUI geometry without reevaluating the
/// RecorderCore scene graph.
@MainActor
final class EditorCanvasCropSourceFrameCache {
    private struct Input: Equatable {
        let normalizedProject: RecorderProject
        let size: CGSize
        let sourceAspect: CGFloat
    }

    private var input: Input?
    private var frame: SharedPreviewPlaybackFrame?

    func frame(
        normalizedProject: RecorderProject,
        size: CGSize,
        sourceAspect: CGFloat,
        build: () -> SharedPreviewPlaybackFrame
    ) -> SharedPreviewPlaybackFrame {
        let nextInput = Input(
            normalizedProject: normalizedProject,
            size: size,
            sourceAspect: sourceAspect
        )
        if input == nextInput, let frame {
            return frame
        }
        let nextFrame = build()
        input = nextInput
        frame = nextFrame
        return nextFrame
    }
}

/// A bounded, cancellable cache for the exact scene plans needed by the next
/// authored animation interval. It deliberately caches no decoded media and no
/// full-canvas pixel buffers: a handful of 5K BGRA frames would consume
/// hundreds of megabytes, while a second AVAssetImageGenerator over the long
/// audio-bearing composition has already proven capable of stalling project
/// preparation. Playback still decodes through AVPlayer and renders through
/// the same SharedFrameCompositor as export; this cache removes the burst of
/// project/track/motion evaluation from the display-link budget.
@MainActor
final class EditorCanvasPlaybackPlanCache {
    struct Handle: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let frameRate: Int
    }

    private struct Input: Equatable {
        let evaluation: CanvasPlaybackEvaluationContext
        let frameRange: ClosedRange<Int>
    }

    private struct IndexedFrame: Sendable {
        let index: Int
        let frame: SharedPreviewPlaybackFrame
    }

    private var input: Input?
    private var frames: [Int: SharedPreviewPlaybackFrame] = [:]
    private var preparationTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Prepare only while the editor is stationary. Starting playback keeps
    /// already completed entries but immediately stops background work, so the
    /// cache can never compete with a frame that has to be shown now.
    func prepare(
        around outputTime: TimeInterval,
        using evaluation: CanvasPlaybackEvaluationContext,
        isPlaying: Bool,
        isInteracting: Bool
    ) -> Handle? {
        let nextRange = Self.animationFrameRange(
            around: outputTime,
            evaluation: evaluation
        )
        let contextChanged = input?.evaluation != evaluation

        if contextChanged {
            invalidate()
        }

        if isPlaying || isInteracting {
            preparationTask?.cancel()
            preparationTask = nil
        }
        guard let nextRange else { return nil }
        let nextInput = Input(evaluation: evaluation, frameRange: nextRange)

        if isPlaying || isInteracting {
            // Advancing the playhead changes the prospective cache range,
            // not the validity of already-prepared entries. Keep the handle
            // while its evaluation context matches; out-of-range reads miss.
            guard input?.evaluation == evaluation, !frames.isEmpty else { return nil }
            return Handle(
                generation: generation,
                frameRate: PreviewAnimationCadence.framesPerSecond
            )
        }

        if input != nextInput || (preparationTask == nil && frames.count < nextInput.frameRange.count) {
            startPreparation(for: nextInput)
        }
        return Handle(
            generation: generation,
            frameRate: PreviewAnimationCadence.framesPerSecond
        )
    }

    func frame(
        at outputTime: TimeInterval,
        handle: Handle
    ) -> SharedPreviewPlaybackFrame? {
        guard handle.generation == generation,
              outputTime.isFinite else { return nil }
        let index = Int(
            (max(outputTime, 0) * Double(max(handle.frameRate, 1))).rounded()
        )
        return frames[index]
    }

    func invalidate() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        input = nil
        frames.removeAll(keepingCapacity: false)
    }

    private func startPreparation(for nextInput: Input) {
        generation &+= 1
        let requestedGeneration = generation
        preparationTask?.cancel()
        if input != nextInput { frames.removeAll(keepingCapacity: true) }
        input = nextInput
        let completedIndices = Set(frames.keys)

        preparationTask = Task.detached(priority: .utility) { [weak self] in
            do {
                // Do not react to every tiny inspector tick. A short idle gate
                // lets the user finish a gesture or press Play immediately;
                // either action cancels this task before it consumes CPU.
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }

            let frameRate = PreviewAnimationCadence.framesPerSecond
            var batch: [IndexedFrame] = []
            batch.reserveCapacity(8)

            for index in nextInput.frameRange {
                guard !Task.isCancelled else { return }
                guard !completedIndices.contains(index) else { continue }
                let time = Double(index) / Double(frameRate)
                batch.append(IndexedFrame(
                    index: index,
                    frame: nextInput.evaluation.frame(at: time)
                ))

                if batch.count == 8 {
                    await self?.install(
                        batch,
                        requestedGeneration: requestedGeneration,
                        expectedInput: nextInput
                    )
                    batch.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
            }

            if !batch.isEmpty, !Task.isCancelled {
                await self?.install(
                    batch,
                    requestedGeneration: requestedGeneration,
                    expectedInput: nextInput
                )
            }
            await self?.finishPreparation(
                requestedGeneration: requestedGeneration,
                expectedInput: nextInput
            )
        }
    }

    private func install(
        _ batch: [IndexedFrame],
        requestedGeneration: UInt64,
        expectedInput: Input
    ) {
        guard generation == requestedGeneration,
              input == expectedInput else { return }
        for entry in batch {
            frames[entry.index] = entry.frame
        }
    }

    private func finishPreparation(
        requestedGeneration: UInt64,
        expectedInput: Input
    ) {
        guard generation == requestedGeneration,
              input == expectedInput else { return }
        preparationTask = nil
    }

    private static func animationFrameRange(
        around requestedTime: TimeInterval,
        evaluation: CanvasPlaybackEvaluationContext
    ) -> ClosedRange<Int>? {
        let duration = max(evaluation.outputDuration, 0)
        guard duration > 0 else { return nil }
        let now = min(max(requestedTime.isFinite ? requestedTime : 0, 0), duration)
        let horizonEnd = min(now + 8, duration)

        let intervals = PreviewAnimationPreparation.intervals(using: evaluation)

        guard let interval = intervals.lazy
            .filter({ $0.end > now && $0.start <= horizonEnd })
            .min(by: { lhs, rhs in
                if lhs.start == rhs.start { return lhs.end < rhs.end }
                return lhs.start < rhs.start
            })
        else { return nil }

        let frameRate = PreviewAnimationCadence.framesPerSecond
        let frameDuration = 1 / Double(frameRate)
        let start = max(now, interval.start - 0.20)
        // Most authored enters/returns complete within a second. A 2.5-second
        // hard cap covers the expensive transition and nearby overlap without
        // turning this lightweight plan cache into an unbounded timeline copy.
        let end = min(
            duration,
            min(max(interval.end + 0.20, start + 0.50), start + 2.50)
        )
        let firstFrame = max(Int(floor(start / frameDuration)), 0)
        let lastFrame = max(Int(ceil(end / frameDuration)), firstFrame)
        return firstFrame...lastFrame
    }
}
