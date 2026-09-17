import AppKit
import CoreImage
import Metal
import QuartzCore

/// CAMetalLayer is thread-safe for drawable acquisition but is not annotated
/// Sendable. Keep the cross-queue boundary explicit and weak so a retirement
/// request cannot extend the life of a dismantled editor surface.
final class PreviewLayerRetirementRequest: @unchecked Sendable {
    weak var layer: CAMetalLayer?
    let generation: UInt64

    init(layer: CAMetalLayer, generation: UInt64) {
        self.layer = layer
        self.generation = generation
    }
}

/// RES-001/RES-002 预览层后台退役与恢复重建，从
/// `SharedRenderedPreviewSurface.swift` 拆出以满足架构行数预算。主声明里
/// 放宽到模块内访问的退役代际/光标层/渲染队列成员只允许这里的代码使用。
extension SharedRenderedPreviewNSView {
    static func makePreviewMetalLayer() -> CAMetalLayer {
        let result = CAMetalLayer()
        configurePreviewMetalLayer(result)
        return result
    }

    /// Applies the complete Metal configuration to a preview layer. Besides
    /// the initial `makeBackingLayer()` creation, this repairs a backing layer
    /// that survived background retirement: AppKit re-attaches the same layer
    /// object when `wantsLayer` turns back on instead of calling
    /// `makeBackingLayer()` again, so the layer returns with the `nil` device
    /// and 2×2 retirement drawable left by
    /// `finalizePreviewBackingLayerRetirement`. Without this repair every
    /// render bails on the missing device and the restored window stays black.
    static func configurePreviewMetalLayer(_ layer: CAMetalLayer) {
        if layer.device == nil {
            layer.device = MTLCreateSystemDefaultDevice()
        }
        layer.pixelFormat = .bgra8Unorm
        // Core Image must be allowed to render into the texture.
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3
        // Playback is already paced by the window's CADisplayLink. Enabling a
        // second independent vblank gate inside CAMetalLayer holds all three
        // drawables until presentation completion; on a 120 Hz desktop with a
        // 60 Hz producer that measured only 43-46 completed frames/s. Let the
        // display link own pacing and keep drawable acquisition non-blocking.
        layer.displaySyncEnabled = false
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
    }

    /// A hidden CAMetalLayer still lets WindowServer retain its last presented
    /// IOSurfaces. On a 5K project that left two 53 MB drawables resident after
    /// minimising the editor, even after shrinking drawableSize and clearing
    /// the device. Ask AppKit to dismantle the backing layer it owns so the
    /// old queue can die after submitted buffers finish, without switching
    /// this view into runtime layer-hosting geometry.
    func suspendPreviewBackingLayer() {
        guard wantsLayer else { return }

        previewRetirementGeneration &+= 1
        let retirementGeneration = previewRetirementGeneration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorClickGradientLayer.removeFromSuperlayer()
        cursorClickSecondaryLayer.removeFromSuperlayer()
        cursorClickAccentLayer.removeFromSuperlayer()
        cursorClickLayer.removeFromSuperlayer()
        cursorImageLayer.removeFromSuperlayer()
        if let previewLayer = layer as? CAMetalLayer {
            previewLayer.isHidden = true
            let request = PreviewLayerRetirementRequest(
                layer: previewLayer,
                generation: retirementGeneration
            )
            // Queue the retirement behind all already-submitted preview work.
            // The same Metal command queue then guarantees the 2×2 drawable is
            // presented after every full-resolution frame, without blocking
            // AppKit's main thread while the GPU drains.
            renderQueue.async { [weak self, request] in
                self?.presentTinyRetirementDrawable(request)
            }
        } else {
            wantsLayer = false
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// WindowServer keeps the most recently presented drawable as the window's
    /// visual backing even after AppKit dismantles the layer. Replace that
    /// front buffer with a transparent 2×2 surface first, so the retained
    /// snapshot costs kilobytes instead of one 53 MB 5K IOSurface.
    nonisolated func presentTinyRetirementDrawable(
        _ request: PreviewLayerRetirementRequest
    ) {
        guard request.generation == previewRetirementGeneration,
              let previewLayer = request.layer else { return }
        guard let device = previewLayer.device else {
            finishTinyRetirementDrawable(request)
            return
        }
        previewLayer.drawableSize = CGSize(width: 2, height: 2)
        if queueCommandQueue == nil {
            queueCommandQueue = device.makeCommandQueue()
        }
        guard let drawable = previewLayer.nextDrawable(),
              let commandQueue = queueCommandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            finishTinyRetirementDrawable(request)
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            finishTinyRetirementDrawable(request)
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self, request] _ in
            self?.finishTinyRetirementDrawable(request)
        }
        commandBuffer.commit()
    }

    nonisolated func finishTinyRetirementDrawable(
        _ request: PreviewLayerRetirementRequest
    ) {
        DispatchQueue.main.async { [weak self, request] in
            guard let self, let previewLayer = request.layer else { return }
            self.finalizePreviewBackingLayerRetirement(
                previewLayer,
                generation: request.generation
            )
        }
    }

    func finalizePreviewBackingLayerRetirement(
        _ previewLayer: CAMetalLayer,
        generation: UInt64
    ) {
        guard PreviewLayerRetirementPolicy.shouldFinalize(
                  requestedGeneration: generation,
                  latestGeneration: previewRetirementGeneration,
                  isSuspended: presentationIsSuspended,
                  ownsRequestedLayer: layer === previewLayer
              ) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.device = nil
        wantsLayer = false
        CATransaction.commit()
    }

    /// Re-enable AppKit's layer-backed lifecycle when the window returns.
    /// `makeBackingLayer()` creates a fresh Metal queue while AppKit remains
    /// responsible for its geometry and WindowServer registration.
    func installPreviewBackingLayerIfNeeded() {
        // Cancel an in-flight retirement before it can dismantle the layer the
        // returning foreground window is about to reuse.
        previewRetirementGeneration &+= 1
        if !wantsLayer {
            wantsLayer = true
        }
        guard let previewLayer = layer as? CAMetalLayer else { return }

        // A restored window can hand back the very layer that background
        // retirement stripped (`device = nil`, 2×2 drawable, hidden) instead
        // of a fresh `makeBackingLayer()` instance. Re-apply the full Metal
        // configuration so the first resumed render can acquire a real
        // drawable; `renderCurrentFrame()` restores the full drawable size.
        Self.configurePreviewMetalLayer(previewLayer)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.masksToBounds = true
        previewLayer.addSublayer(cursorClickGradientLayer)
        previewLayer.addSublayer(cursorClickSecondaryLayer)
        previewLayer.addSublayer(cursorClickAccentLayer)
        previewLayer.addSublayer(cursorClickLayer)
        previewLayer.addSublayer(cursorImageLayer)
        CATransaction.commit()
    }
}
