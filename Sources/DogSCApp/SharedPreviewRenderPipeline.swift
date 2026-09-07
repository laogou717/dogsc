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
            self.queueDidPrewarmPerspective = false
            self.queuePrewarmedPerspectiveSignatures.removeAll(keepingCapacity: false)
        }
        guard let context = self.queueContext,
              let commandQueue = self.queueCommandQueue else {
            submissionCompletion(false)
            return
        }
        if !queueDidPrewarmPerspective {
            queueDidPrewarmPerspective = true
            Self.prewarmPerspectivePipeline(
                context: context,
                device: device,
                commandQueue: commandQueue,
                colorSpace: job.colorProfile.outputColorSpace
            )
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
        let scaleX = displayBounds.width / max(job.canvasSize.width, 2)
        let scaleY = displayBounds.height / max(job.canvasSize.height, 2)
        let scaled: CIImage
        if scaleX < 1, scaleY < 1 {
            // Preserve text and one-pixel UI edges when a 4K recording is
            // displayed in a much smaller editor canvas. Bilinear scaling was
            // fast but made the preview visibly softer than the export.
            scaled = rendered.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: scaleY,
                    kCIInputAspectRatioKey: scaleX / max(scaleY, 0.000_1),
                ]
            )
        } else {
            scaled = rendered.transformed(
                by: CGAffineTransform(scaleX: scaleX, y: scaleY)
            )
        }
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
        do {
            _ = try context.startTask(toRender: scaled, from: displayBounds,
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
        if let presentationHostTime = job.presentationHostTime {
            // The display link and AVPlayerItemVideoOutput evaluated this
            // exact host-time deadline. Scheduling the drawable for the same
            // deadline prevents a slow frame from being followed by two
            // immediate catch-up presentations.
            commandBuffer.present(drawable, atTime: presentationHostTime)
        } else {
            commandBuffer.present(drawable)
        }
        commandBuffer.addCompletedHandler { completed in
            presentationCompletion(completed.status == .completed)
        }
        commandBuffer.commit()
        submissionCompletion(true)

        // The 32×32 pass above only compiles kernels. A 5K project such as
        // project 01 still allocates several full-size perspective/border
        // intermediates on the first real 3D frame. Schedule the authored graph
        // only after a short paused-idle interval. The previous immediate
        // command raced an immediate Play press and made the first playback
        // frames wait behind the very warm-up intended to help them.
        if let prewarmPlan = job.perspectivePrewarmPlan,
           let signature = PreviewPerspectivePrewarmSignature(
               plan: prewarmPlan,
               destinationPixelSize: job.destinationPixelSize
           ),
           queuePrewarmedPerspectiveSignatures.insert(signature).inserted {
            renderQueue.asyncAfter(
                deadline: .now() + PreviewPerspectivePrewarmPolicy.idleDelay
            ) { [weak self] in
                guard let self else { return }
                guard PreviewPerspectivePrewarmPolicy.shouldRun(
                    jobGeneration: job.generation,
                    latestGeneration: self.renderGeneration,
                    jobEpochID: job.presentationEpochID,
                    latestEpochID: self.presentationEpochID,
                    colorContractMatches: self.queueColorContract == job.colorContract
                ) else {
                    self.queuePrewarmedPerspectiveSignatures.remove(signature)
                    return
                }
                guard let prewarmCommandBuffer = Self.actualPerspectivePrewarmCommandBuffer(
                    plan: prewarmPlan,
                    resources: job.resources,
                    destinationPixelSize: job.destinationPixelSize,
                    context: context,
                    device: device,
                    commandQueue: commandQueue,
                    colorSpace: job.colorProfile.outputColorSpace
                ) else {
                    self.queuePrewarmedPerspectiveSignatures.remove(signature)
                    return
                }
                prewarmCommandBuffer.addCompletedHandler { [weak self] completed in
                    guard completed.status != .completed else { return }
                    self?.renderQueue.async { [weak self] in
                        self?.queuePrewarmedPerspectiveSignatures.remove(signature)
                    }
                }
                prewarmCommandBuffer.commit()
            }
        }
    }

    nonisolated static func actualPerspectivePrewarmCommandBuffer(
        plan: FrameRenderPlan,
        resources: SharedFrameRenderResources,
        destinationPixelSize: CGSize,
        context: CIContext,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        colorSpace: CGColorSpace
    ) -> MTLCommandBuffer? {
        let scene = plan.scene
        guard !SharedFrameRenderer.isIdentityProjection(scene.screen),
           let rendered = SharedPreviewFramePipeline.render(
               plan: plan,
               resources: resources
           ) else { return nil }
        let width = max(Int(destinationPixelSize.width.rounded()), 2)
        let height = max(Int(destinationPixelSize.height.rounded()), 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        // Core Image may choose a compute kernel for this off-screen pass.
        // A private texture that only advertises renderTarget/shaderRead can
        // therefore fail to create a CIRenderDestination on some GPUs.
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let scaleX = bounds.width / max(scene.canvasSize.width, 2)
        let scaleY = bounds.height / max(scene.canvasSize.height, 2)
        let scaled = rendered.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )
        context.render(
            scaled,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
        return commandBuffer
    }

    /// Compile and enqueue the exact Core Image filter family used by 3D
    /// screen motion while the editor is already drawing its first paused
    /// frame. Previously the perspective and projected-mask kernels were first
    /// encountered on playback frame two (frame one is still identity), which
    /// caused the visible one-time hitch after adding a screen-motion clip.
    nonisolated static func prewarmPerspectivePipeline(
        context: CIContext,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        colorSpace: CGColorSpace
    ) {
        let size = 32
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let mask = CIFilter(
                  name: "CIRoundedRectangleGenerator",
                  parameters: [
                      "inputExtent": CIVector(cgRect: extent),
                      "inputRadius": 3,
                  ]
              )?.outputImage else { return }
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let source = CIImage(color: .white)
            .cropped(to: extent)
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: mask,
                ]
            )
        let projected = source.applyingFilter(
            "CIPerspectiveTransformWithExtent",
            parameters: [
                "inputExtent": CIVector(cgRect: extent),
                "inputTopLeft": CIVector(x: 2, y: 31),
                "inputTopRight": CIVector(x: 30, y: 28),
                "inputBottomRight": CIVector(x: 31, y: 2),
                "inputBottomLeft": CIVector(x: 1, y: 4),
            ]
        )
        context.render(
            projected,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: extent,
            colorSpace: colorSpace
        )
        commandBuffer.commit()
    }
}
