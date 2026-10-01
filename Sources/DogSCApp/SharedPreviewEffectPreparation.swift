import CoreImage
import Metal
import QuartzCore
import RecorderCore

/// Branches, output size and resource availability identify the graph. Do not
/// key on every animated coordinate: that would warm every slider tick again.
struct PreviewEffectPrewarmSignature: Hashable {
    let width: Int
    let height: Int
    let branches: [Bool]
    let mosaicStyles: [String]
    let stickerBranches: [[Bool]]

    init(plan: FrameRenderPlan, resources: SharedFrameRenderResources, size: CGSize) {
        let scene = plan.scene
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
        let chrome: Bool
        if case .chrome = scene.screen.decoration { chrome = true } else { chrome = false }
        branches = [
            !SharedFrameRenderer.isIdentityProjection(scene.screen), chrome,
            scene.screen.cornerRadius > 0, scene.screen.borderWidth > 0,
            (scene.screen.shadow?.opacity ?? 0) > 0,
            scene.screen.opacity > 0 && scene.screen.opacity < 1,
            scene.screen.focusEffect != nil,
            scene.cursor != nil && resources.cursor != nil,
            (scene.camera?.opacity ?? 0) > 0 && resources.camera != nil,
            (scene.camera?.borderWidth ?? 0) > 0,
            (scene.camera?.shadow?.opacity ?? 0) > 0,
            (scene.camera?.opacity ?? 1) < 1,
            scene.background.blurRadius > 0,
            scene.stickerBackdrop.screenBlur > 0,
            scene.stickerBackdrop.cameraBlur > 0,
            scene.stickerBackdrop.screenSuppression > 0,
            scene.stickerBackdrop.cameraSuppression > 0,
        ]
        mosaicStyles = scene.screen.mosaics.map { $0.style.rawValue }
        stickerBranches = scene.stickers.map {
            [$0.cornerRadius > 0, $0.borderWidth > 0, $0.shadowOpacity > 0,
             $0.backdropBlur > 0, $0.opacity < 1, abs($0.rotationRadians) > 0.001,
             resources.stickers[$0.relativePath] != nil, $0.opacity > 0 && $0.scale > 0]
        }
    }
}

extension SharedRenderedPreviewNSView {
    /// This is preparation, not another offscreen video render. Apple's API
    /// compiles kernels and reserves volatile intermediates in the same context
    /// the next visible frames use. Only one graph runs per idle turn; there is
    /// no GPU wait and no retained collection of high-resolution output frames.
    nonisolated func scheduleEffectPreparation(
        for job: PreviewRenderJob,
        context: CIContext,
        device: MTLDevice,
        index: Int = 0
    ) {
        guard job.isPausedFrame, index < job.effectPrewarmPlans.count else { return }
        renderQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  job.generation == self.renderGeneration,
                  job.presentationEpochID == self.presentationEpochID,
                  self.queueColorContract == job.colorContract else { return }
            let plan = job.effectPrewarmPlans[index]
            let signature = PreviewEffectPrewarmSignature(
                plan: plan, resources: job.resources, size: job.destinationPixelSize)
            if !self.queuePreparedEffectSignatures.contains(signature) {
                // Bound metadata too. Changing many effects must not grow a
                // lifetime history of graph signatures in the preview view.
                if self.queuePreparedEffectSignatures.count >= 16 {
                    self.queuePreparedEffectSignatures.removeAll(keepingCapacity: true)
                }
                if Self.prepareEffect(plan: plan, job: job, context: context, device: device,
                                      isCurrent: {
                    job.generation == self.renderGeneration
                        && job.presentationEpochID == self.presentationEpochID
                }) {
                    self.queuePreparedEffectSignatures.insert(signature)
                }
            }
            self.scheduleEffectPreparation(for: job, context: context, device: device, index: index + 1)
        }
    }

    nonisolated private static func prepareEffect(
        plan: FrameRenderPlan,
        job: PreviewRenderJob,
        context: CIContext,
        device: MTLDevice,
        isCurrent: () -> Bool
    ) -> Bool {
        guard let rendered = SharedPreviewFramePipeline.render(plan: plan, resources: job.resources),
              isCurrent() else { return false }
        let width = max(Int(job.destinationPixelSize.width.rounded()), 2)
        let height = max(Int(job.destinationPixelSize.height.rounded()), 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor), isCurrent() else { return false }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let image = previewDestinationImage(rendered, canvasSize: plan.scene.canvasSize, bounds: bounds)
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = job.colorProfile.outputColorSpace
        destination.isFlipped = true
        do {
            try context.prepareRender(image, from: bounds, to: destination, at: .zero)
            return true
        } catch {
            return false // Visible rendering remains the fallback and retries.
        }
    }

    nonisolated static func previewDestinationImage(
        _ image: CIImage, canvasSize: CompositionSize, bounds: CGRect
    ) -> CIImage {
        let scaleX = bounds.width / max(canvasSize.width, 2)
        let scaleY = bounds.height / max(canvasSize.height, 2)
        if scaleX < 1, scaleY < 1 {
            return image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / max(scaleY, 0.000_1),
            ])
        }
        return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}
