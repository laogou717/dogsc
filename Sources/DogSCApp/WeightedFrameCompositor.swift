import CoreImage
import Foundation
import RecorderCore

/// One already-rendered temporal sample for a single output frame.
///
/// The scene evaluator owns sample times and weights; this type deliberately
/// contains no project or timeline state so preview and export can share the
/// same deterministic accumulation step.
struct WeightedFrameImage {
    var image: CIImage
    var weight: Double
}

struct WeightedFrameRenderPreparation: Equatable {
    var samples: [FrameSceneSample]
    /// A camera card that is identical in every temporal sample and is above
    /// every moving layer. It can be composed once after temporal accumulation
    /// instead of being redrawn 8/16/32 times.
    var staticTopCameraScene: FrameScene?
}

enum WeightedFrameCompositor {
    /// Lowers one immutable render plan with one media-resource snapshot.
    ///
    /// Preview and export deliberately share this overload. Temporal samples
    /// may move project geometry, but they must not independently resample the
    /// transport clock: every scene in the plan receives the same decoded
    /// screen/camera/wallpaper/cursor resources for this output frame.
    static func composite(
        _ plan: FrameRenderPlan,
        resources: SharedFrameRenderResources,
        extent: CGRect
    ) -> CIImage? {
        let preparation = renderPreparation(
            for: plan,
            rendersCursor: resources.cursor != nil
        )
        let renderSamples = preparation.samples
        var temporalResources = resources
        if preparation.staticTopCameraScene != nil {
            // A missing resource makes the existing camera role a no-op. This
            // avoids cloning every immutable scene merely to delete its camera
            // before temporal accumulation; the exact camera card is rendered
            // once with the original resources below.
            temporalResources.camera = nil
        }
        // The background (wallpaper blur / gradient) is time-invariant for the
        // output frame. Rendering it once and reusing it across every temporal
        // sample removes `sampleCount - 1` full-canvas Gaussian blurs per frame
        // — the dominant GPU cost of motion blur at 4K/120 FPS.
        guard let firstScene = renderSamples.first?.scene else { return nil }
        let background = resources.preparedBackground
            ?? SharedFrameRenderer.backgroundImage(
                scene: firstScene.background,
                canvasRect: extent,
                wallpaperSource: resources.wallpaper
            )
        let temporalResult: CIImage
        if renderSamples.count == 1, let sample = renderSamples.first {
            // Motion blur disabled, or PRE-010 collapsed a visually static
            // exposure window. One image is already its own normalized
            // weighted result, so do not allocate a WeightedFrameImage array
            // and enter the generic accumulation path on every output frame.
            temporalResult = SharedFrameRenderer.render(
                scene: sample.scene,
                resources: temporalResources,
                over: background
            ).cropped(to: extent)
        } else {
            guard let blended = composite(
                renderSamples.map { sample in
                    WeightedFrameImage(
                        image: SharedFrameRenderer.render(
                            scene: sample.scene,
                            resources: temporalResources,
                            over: background
                        ),
                        weight: sample.weight
                    )
                },
                extent: extent
            ) else { return nil }
            temporalResult = blended
        }
        guard let staticTopCameraScene = preparation.staticTopCameraScene else {
            return temporalResult
        }
        return SharedFrameRenderer.render(
            scene: staticTopCameraScene,
            resources: resources,
            over: temporalResult
        ).cropped(to: extent)
    }

    /// Separates an unchanged topmost camera card from a moving temporal plan.
    /// This is exact compositing, not an approximation: the media snapshot is
    /// shared by every sample and an unchanged top layer distributes over the
    /// normalized temporal blend. If the camera itself moves, appears/disappears
    /// inside the shutter, or is not the last rendered role, the original full
    /// sample path is retained.
    static func renderPreparation(
        for plan: FrameRenderPlan,
        rendersCursor: Bool = true
    ) -> WeightedFrameRenderPreparation {
        let samples = renderSamples(
            for: plan,
            rendersCursor: rendersCursor
        )
        guard samples.count > 1,
              let firstScene = samples.first?.scene,
              let camera = firstScene.camera,
              camera.opacity > 0,
              isTopmostCamera(in: firstScene),
              samples.dropFirst().allSatisfy({ sample in
                  sample.scene.camera == camera
                      && sample.scene.canvasSize == firstScene.canvasSize
                      && sample.scene.color == firstScene.color
                      && isTopmostCamera(in: sample.scene)
              }) else {
            return WeightedFrameRenderPreparation(
                samples: samples,
                staticTopCameraScene: nil
            )
        }

        var cameraOnlyScene = firstScene
        cameraOnlyScene.time = 0
        cameraOnlyScene.cursor = nil
        cameraOnlyScene.layerOrder = [.camera]
        return WeightedFrameRenderPreparation(
            samples: samples,
            staticTopCameraScene: cameraOnlyScene
        )
    }

    private static func isTopmostCamera(in scene: FrameScene) -> Bool {
        scene.layerOrder.last(where: { $0 != .background }) == .camera
    }

    /// Removes invalid weights before rendering and collapses a temporal plan
    /// when all authored visual values are identical. `FrameScene.time` is
    /// evaluation provenance only; every renderable value has already been
    /// lowered into geometry/style, so it deliberately does not participate.
    /// This turns a 32-sample enabled blur on a stationary 5K scene into one
    /// render without changing the result or disabling blur once anything
    /// actually moves.
    static func renderSamples(
        for plan: FrameRenderPlan,
        rendersCursor: Bool = true
    ) -> [FrameSceneSample] {
        let allSamplesAreUsable = plan.samples.allSatisfy {
            $0.weight.isFinite && $0.weight > 0
        }
        // Authored render plans always carry finite positive weights. Keep
        // their existing copy-on-write storage on the hot path; only malformed
        // external/recovery data needs a filtered allocation.
        let usable = allSamplesAreUsable
            ? plan.samples
            : plan.samples.filter {
                $0.weight.isFinite && $0.weight > 0
            }
        guard let first = usable.first else { return [] }
        guard usable.count > 1 else { return usable }
        guard usable.dropFirst().allSatisfy({ sample in
            scenesMatchVisually(
                sample.scene,
                first.scene,
                rendersCursor: rendersCursor
            )
        }) else { return usable }
        return [FrameSceneSample(
            scene: first.scene,
            weight: usable.reduce(0) { $0 + $1.weight }
        )]
    }

    /// FrameScene.time is provenance, not a render input. When the caller has
    /// no cursor resource (the editor's independent CALayer fast path), cursor
    /// data and its otherwise no-op layer role are not render inputs either.
    /// Compare in place so motion-blur plans do not need a second normalized
    /// scene array merely to discover that only the overlay cursor moved.
    private static func scenesMatchVisually(
        _ lhs: FrameScene,
        _ rhs: FrameScene,
        rendersCursor: Bool
    ) -> Bool {
        guard lhs.canvasSize == rhs.canvasSize,
              lhs.color == rhs.color,
              lhs.background == rhs.background,
              lhs.screen == rhs.screen,
              lhs.camera == rhs.camera else {
            return false
        }
        if rendersCursor, lhs.cursor != rhs.cursor {
            return false
        }
        return layerOrdersMatch(
            lhs.layerOrder,
            rhs.layerOrder,
            rendersCursor: rendersCursor
        )
    }

    private static func layerOrdersMatch(
        _ lhs: [FrameLayerRole],
        _ rhs: [FrameLayerRole],
        rendersCursor: Bool
    ) -> Bool {
        guard !rendersCursor else { return lhs == rhs }
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        while true {
            while lhsIndex < lhs.endIndex, lhs[lhsIndex] == .cursor {
                lhs.formIndex(after: &lhsIndex)
            }
            while rhsIndex < rhs.endIndex, rhs[rhsIndex] == .cursor {
                rhs.formIndex(after: &rhsIndex)
            }
            if lhsIndex == lhs.endIndex || rhsIndex == rhs.endIndex {
                return lhsIndex == lhs.endIndex && rhsIndex == rhs.endIndex
            }
            guard lhs[lhsIndex] == rhs[rhsIndex] else { return false }
            lhs.formIndex(after: &lhsIndex)
            rhs.formIndex(after: &rhsIndex)
        }
    }

    /// Accumulates opaque temporal samples in linear-light working space.
    /// Invalid and zero-weight entries are ignored, and the remaining weights
    /// are normalized so a clamped sample at a cut cannot change brightness.
    static func composite(
        _ samples: [WeightedFrameImage],
        extent: CGRect
    ) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }
        let allSamplesAreUsable = samples.allSatisfy { sample in
            sample.weight.isFinite && sample.weight > 0
        }
        // The frame-scene plan has already validated ordinary authored
        // weights. Reuse this image array instead of allocating a second array
        // on every preview/export frame; retain the defensive slow path for
        // malformed callers and recovery data.
        let usable = allSamplesAreUsable
            ? samples
            : samples.filter { sample in
                sample.weight.isFinite && sample.weight > 0
            }
        let total = usable.reduce(0) { $0 + $1.weight }
        guard total.isFinite, total > 0 else { return nil }

        var accumulated: CIImage?
        var accumulatedWeight = 0.0
        for sample in usable {
            let image = sample.image.cropped(to: extent)
            guard let previous = accumulated else {
                accumulated = image
                accumulatedWeight = sample.weight
                continue
            }

            let combinedWeight = accumulatedWeight + sample.weight
            let mix = sample.weight / combinedWeight
            // MOT-002/PRE-006: store the interpolation coefficient in alpha.
            // A grayscale RGB mask is color-managed from sRGB into the linear working space,
            // so a requested 0.5 becomes roughly 0.214 and changes authored
            // sample weights. Alpha is linear by definition.
            let mask = CIImage(
                color: CIColor(red: 0, green: 0, blue: 0, alpha: mix)
            ).cropped(to: extent)
            accumulated = image.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: previous,
                    kCIInputMaskImageKey: mask,
                ]
            ).cropped(to: extent)
            accumulatedWeight = combinedWeight
        }
        return accumulated
    }
}
