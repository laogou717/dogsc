import AVFoundation
import CoreImage
import Metal
import QuartzCore
import RecorderCore

/// 预览 drawable 合成提交与透视预热（PRE-007/PRE-022），从
/// `SharedRenderedPreviewSurface.swift` 拆出以满足架构行数预算。主声明里
/// 放宽到模块内访问的 queue* 渲染队列缓存只允许这里的代码使用。
extension SharedPreviewEngine {
    /// Compose and present directly into the Metal drawable. This removes the
    /// old per-frame `createCGImage` GPU readback and the subsequent CALayer
    /// upload, which was the main preview playback bottleneck.
    func renderDrawable(
        for job: PreviewRenderJob,
        renderCompletion: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
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
        if PreviewRenderValidity.shouldDiscardBeforeRendering(
            isPausedFrame: job.isPausedFrame,
            generation: job.generation,
            latestGeneration: renderGeneration
        ) {
            return true
        }
        // Continuous playback is paced by the display link. UI revisions
        // invalidate stationary jobs; only transport epochs retire live jobs.
        guard let device = job.metalLayer.device else {
            return false
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
                return false
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
            return false
        }
        guard let rendered = SharedPreviewFramePipeline.render(
                  plan: job.plan,
                  resources: job.resources
              ) else {
            return false
        }
        // Track visibility changes resize the monitor while a previous paused
        // frame can still be waiting on this queue. CAMetalLayer hands that old
        // job a drawable using the *new* live size; rendering the old bounds
        // into it fills only one side and leaves a persistent black strip.
        // Reject the mismatched surface; the engine retries on its own queue
        // with the newest scene/size contract.
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
        let drawable = job.drawable
        guard drawable.layer === job.metalLayer,
              drawable.texture.width == expectedTextureWidth,
              drawable.texture.height == expectedTextureHeight else {
            return false
        }
        if let observer = onDrawablePresented {
            drawable.addPresentedHandler { if $0.presentedTime > 0 { observer($0.presentedTime, job.plan.scene.time) } }
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
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        guard (!job.isPausedFrame || job.generation == renderGeneration),
              PreviewRenderValidity.shouldPresent(
            jobEpochID: job.presentationEpochID,
            latestEpochID: presentationEpochID
        ) else {
            // Work already encoded for a retired playback interval is allowed
            // to finish, but never receives a `present` call. CAMetalLayer
            // therefore keeps the last valid drawable visible until the first
            // frame from the new pause/seek/media epoch is ready.
            commandBuffer.commit()
            return true
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
        // A Metal display-link drawable already carries its deadline. The
        // platform forbids timed-present variants for these drawables.
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { completed in
            if completed.status != .completed, let timing { timing.owner.failed(timing) }
            // Used only to hand editing overlays back to composited content.
            // Actual display diagnostics come from addPresentedHandler above.
            renderCompletion(completed.status == .completed)
        }
        commandBuffer.commit()
        didSubmit = true

        scheduleEffectPreparation(for: job, context: context, device: device)
        return true
    }
}
