import AVFoundation
import CoreImage
import Metal
import QuartzCore
import RecorderCore

/// 预览 drawable 合成提交与透视预热（PRE-007/PRE-022），从
/// `SharedRenderedPreviewSurface.swift` 拆出以满足架构行数预算。主声明里
/// 放宽到模块内访问的 queue* 渲染队列缓存只允许这里的代码使用。
extension SharedRenderedPreviewNSView {
    /// Compose and present directly into the Metal drawable. This removes the
    /// old per-frame `createCGImage` GPU readback and the subsequent CALayer
    /// upload, which was the main preview playback bottleneck.
    nonisolated func renderDrawable(
        for job: PreviewRenderJob,
        submissionCompletion: @escaping @Sendable (Bool) -> Void,
        presentationCompletion: @escaping @Sendable (Bool) -> Void
    ) {
        let timing = job.diagnostics
        let renderStarted = timing == nil ? 0 : CACurrentMediaTime()
        var didSubmit = false
        defer {
            if let timing, !didSubmit { timing.owner.failed(timing) }
        }
        // A queued paused slider frame has no temporal value once a newer edit
        // or playback frame exists. Playback frames deliberately do not use
        // this generation check: dropping intermediate playback submissions
        // was the former ~45 fps cadence bug.
        if PreviewRenderBackpressurePolicy.shouldDiscardBeforeRendering(
            isPausedFrame: job.isPausedFrame,
            generation: job.generation,
            latestGeneration: renderGeneration
        ) {
            submissionCompletion(true)
            presentationCompletion(false)
            return
        }
        // Multiple submitted jobs may legitimately be queued at once. Do not compare
        // each queued job with the latest generation here: completion of frame
        // N immediately submits N+2 while N+1 is still waiting on this serial
        // queue, so the old equality check discarded N+1 on every cycle and
        // capped a 60 Hz preview near 45 fps. Back-pressure already limits the
        // queue and coalesces newer input through `renderDirty`.
        guard let device = job.metalLayer.device else {
            submissionCompletion(false)
            return
        }
        if self.queueColorContract != job.colorContract {
            self.queueColorContract = job.colorContract
            // The screen projection, chrome, border and shadow graph changes
            // every animation frame. Context-wide intermediate caching retains
            // those one-frame Metal resources and lets a long preview grow far
            // beyond its live working set. Stable backgrounds already opt into
            // their own explicit `insertingIntermediate(cache: true)` boundary,
            // so keep that reuse while allowing all transient frame graphs to
            // be released as soon as their command buffer finishes.
            guard let commandQueue = device.makeCommandQueue() else {
                submissionCompletion(false)
                return
            }
            self.queueContext = job.colorProfile.makeMetalContext(
                commandQueue: commandQueue,
                cacheIntermediates: false
            )
            self.queueCommandQueue = commandQueue
            self.queuePreparedEffectSignatures.removeAll(keepingCapacity: false)
        }
        guard let context = self.queueContext,
              let commandQueue = self.queueCommandQueue else {
            submissionCompletion(false)
            return
        }
        guard let rendered = SharedPreviewFramePipeline.render(
                  plan: job.plan,
                  resources: job.resources
              ) else {
            submissionCompletion(false)
            return
        }
        // Track visibility changes resize the monitor while a previous paused
        // frame can still be waiting on this queue. CAMetalLayer hands that old
        // job a drawable using the *new* live size; rendering the old bounds
        // into it fills only one side and leaves a persistent black strip.
        // Reject the mismatched surface and let the main actor immediately
        // resubmit the newest scene/size contract.
        let expectedTextureWidth = max(
            Int(job.destinationPixelSize.width.rounded()),
            2
        )
        let expectedTextureHeight = max(
            Int(job.destinationPixelSize.height.rounded()),
            2
        )
        let displayBounds = CGRect(
            x: 0,
            y: 0,
            width: max(job.destinationPixelSize.width, 2),
            height: max(job.destinationPixelSize.height, 2)
        )
        let scaled = Self.previewDestinationImage(rendered, canvasSize: job.canvasSize,
                                                  bounds: displayBounds)
        let graphFinished = timing == nil ? 0 : CACurrentMediaTime()
        // Resolve and validate before encoding. The Swift texture-provider
        // callback cannot return nil, whereas a resized/retired CAMetalLayer
        // legitimately may. Do not force-unwrap or allocate a second full-size
        // fallback texture merely to use the lazy-provider convenience API.
        guard let drawable = job.metalLayer.nextDrawable(),
              drawable.texture.width == expectedTextureWidth,
              drawable.texture.height == expectedTextureHeight else {
            submissionCompletion(false)
            presentationCompletion(false)
            return
        }
        let drawableAcquired = timing == nil ? 0 : CACurrentMediaTime()
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: nil)
        destination.colorSpace = job.colorProfile.outputColorSpace
        // Core Image uses a lower-left origin, but a directly presented Metal
        // drawable stores the top row first. Keep this conversion at the
        // presentation boundary; false vertically inverts the entire preview.
        // Do not infer on-screen orientation from legacy offscreen byte order.
        destination.isFlipped = true
        // CI owns intermediate command buffers on our presentation queue.
        // Apple's CIRenderDestination contract warns that forcing every pass
        // into one client buffer increases latency and peak memory.
        // A queue-backed context returns after work is queued,
        // so the subsequent presentation buffer is ordered after all CI work.
        let renderTask: CIRenderTask
        do {
            renderTask = try context.startTask(toRender: scaled, from: displayBounds,
                                               to: destination, at: .zero)
        } catch {
            submissionCompletion(false)
            presentationCompletion(false)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            submissionCompletion(false)
            presentationCompletion(false)
            return
        }
        guard PreviewRenderBackpressurePolicy.shouldPresent(
            jobEpochID: job.presentationEpochID,
            latestEpochID: presentationEpochID
        ) else {
            // Work already encoded for a retired playback interval is allowed
            // to finish, but never receives a `present` call. CAMetalLayer
            // therefore keeps the last valid drawable visible until the first
            // frame from the new pause/seek/media epoch is ready.
            submissionCompletion(true)
            presentationCompletion(false)
            commandBuffer.commit()
            return
        }
        if let timing {
            let encodedAt = CACurrentMediaTime()
            timing.owner.encoded(timing,
                queueMS: (renderStarted - timing.queuedAt) * 1_000,
                graphMS: (graphFinished - renderStarted) * 1_000,
                drawableWaitMS: (drawableAcquired - graphFinished) * 1_000,
                encodeMS: (encodedAt - drawableAcquired) * 1_000)
            drawable.addPresentedHandler { drawable in
                timing.owner.presented(timing, at: drawable.presentedTime)
            }
            timing.owner.collectRenderInfo(renderTask, for: timing)
        }
        if let presentationHostTime = job.presentationHostTime {
            // Keep presentation on the Metal queue at the display-link's
            // deadline. Sending every drawable back through a main-thread CA
            // transaction makes playback wait behind unrelated UI updates.
            commandBuffer.present(drawable, atTime: presentationHostTime)
        } else {
            commandBuffer.present(drawable)
        }
        commandBuffer.addCompletedHandler { completed in
            if completed.status != .completed, let timing { timing.owner.failed(timing) }
            // Used only to hand editing overlays back to composited content.
            // Actual display diagnostics come from addPresentedHandler above.
            presentationCompletion(completed.status == .completed)
        }
        commandBuffer.commit()
        didSubmit = true
        submissionCompletion(true)

        scheduleEffectPreparation(for: job, context: context, device: device)
    }
}
