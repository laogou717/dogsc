import AppKit
import AVFoundation
import CoreImage
import Metal
import os
import QuartzCore
import RecorderCore
import SwiftUI

/// 后台预览渲染任务负载：全部为值类型或不可变引用（CIImage 不可变），
/// 可安全跨队列传递。
struct PreviewRenderJob: @unchecked Sendable {
    /// Configuration revision; live frames do not invalidate one another.
    let generation: UInt64
    let drawable: any CAMetalDrawable
    /// Stable across consecutive playback frames, but changes for pause,
    /// seek/scrub discontinuities and prepared-media replacement. The epoch
    /// decides whether a live job still belongs to the visible interval.
    let presentationEpochID: UInt64
    let diagnostics: PreviewFrameDiagnostics.Frame?
    let plan: FrameRenderPlan
    /// A bounded set of upcoming combined effect plans. Prepared only after
    /// paused idle, at the selected full raster size, without another decoder.
    let effectPrewarmPlans: [FrameRenderPlan]
    let resources: SharedFrameRenderResources
    let canvasSize: CompositionSize
    /// Actual on-screen drawable size. The editor may display a 4K project in
    /// a 900-point canvas; rendering the authored 4K size and then multiplying
    /// it by Retina scale accidentally created an 8K texture every frame.
    let destinationPixelSize: CGSize
    let colorProfile: CoreImageFrameColorProfile
    let colorContract: FrameColorContract?
    /// The view-owned target. PreviewDisplayDriver exclusively acquires its
    /// drawables; the serial render queue only encodes into supplied textures.
    let metalLayer: CAMetalLayer
    /// Whether this came from a stationary/inspector edit rather than the
    /// playback display link. Stale paused frames may be discarded safely;
    /// intermediate playback frames must retain cadence semantics.
    let isPausedFrame: Bool
    /// 该帧是否包含真实摄像头/屏幕内容（拖动抑制期间为 false）；
    /// 用于“内容已回到合成帧”的落地回调，覆盖层据此安全退出。
    let includesCamera: Bool
    let includesScreen: Bool
}

struct PreviewVisualSignature: Equatable {
    let plan: FrameRenderPlan
    let contentRevision: UInt64
    let backingScale: CGFloat
    let destinationPixelSize: CGSize
    let colorContract: FrameColorContract?
    /// Same decoded frame has a stable identity in ImageMediaFrameCache.
    /// Static images stay idle; GIF changes bypass the stand-in video's cadence.
    var insertedImageFrame: CIImage? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.contentRevision == rhs.contentRevision,
              lhs.insertedImageFrame === rhs.insertedImageFrame,
              lhs.backingScale == rhs.backingScale,
              lhs.destinationPixelSize == rhs.destinationPixelSize,
              lhs.colorContract == rhs.colorContract,
              lhs.plan.frameRate == rhs.plan.frameRate else {
            return false
        }

        if case .dynamicFlow = lhs.plan.scene.background.source,
           lhs.plan.scene.time != rhs.plan.scene.time {
            return false
        }
        // Presentation/output time and FrameScene.time are normally evaluation
        // provenance. Dynamic backgrounds are the exception because their
        // visible phase is evaluated by the renderer from scene.time.
        return scenesMatchVisually(
            lhs.plan.scene,
            rhs.plan.scene
        )
    }

    private static func scenesMatchVisually(
        _ lhs: FrameScene,
        _ rhs: FrameScene
    ) -> Bool {
        guard lhs.canvasSize == rhs.canvasSize,
              lhs.color == rhs.color,
              lhs.background == rhs.background,
              lhs.screen == rhs.screen,
              lhs.camera == rhs.camera,
              lhs.stickers == rhs.stickers,
              lhs.stickerBackdrop == rhs.stickerBackdrop,
              animationsMatch(lhs.animations, rhs.animations),
              lhs.subtitle == rhs.subtitle,
              lhs.videos == rhs.videos,
              insertedMotionsMatch(lhs.insertedMotion, rhs.insertedMotion) else {
            return false
        }
        return lhs.cursor == rhs.cursor && lhs.layerOrder == rhs.layerOrder
    }

    /// A main-track HTML motion changes picture on the native preview grid
    /// (60 Hz). Without this, playback redrew it only when the black stand-in
    /// video under it delivered a frame — 5 times a second.
    private static func insertedMotionsMatch(_ lhs: FrameInsertedMotionScene?, _ rhs: FrameInsertedMotionScene?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.sourcePath == rhs.sourcePath
            && lhs.properties == rhs.properties
            && lhs.elementEdits == rhs.elementEdits
            && motionFrame(lhs.localTime) == motionFrame(rhs.localTime)
    }

    private static func motionFrame(_ time: TimeInterval) -> Double {
        (time * HTMLMotionPreviewBuffer.frameRate + 1e-6).rounded(.down)
    }

    private static func animationsMatch(_ lhs: [FrameAnimationScene], _ rhs: [FrameAnimationScene]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            var left = left, right = right
            left.localTime = motionFrame(left.localTime)
            right.localTime = motionFrame(right.localTime)
            return left == right
        }
    }


}

/// Keeps the editor's time-invariant background as one stable Core Image
/// object. `insertingIntermediate(cache:)` only helps when that exact CIImage
/// instance survives between renders; rebuilding the same transform/blur
/// graph on every display tick still makes Core Image bind the source CGImage
/// and upload it to Metal again.
struct PreviewPreparedBackgroundCache {
    private struct Key: Equatable {
        let scene: FrameBackgroundScene
        let canvasSize: CompositionSize
        let wallpaperRevision: UInt64
    }

    private var key: Key?
    private var value: CIImage?

    mutating func image(
        scene: FrameBackgroundScene,
        canvasSize: CompositionSize,
        wallpaperSource: CIImage?,
        wallpaperRevision: UInt64
    ) -> CIImage? {
        if case .dynamicFlow = scene.source {
            key = nil
            value = nil
            return nil
        }
        // A decoded movie frame is already a one-frame resource. Wrapping
        // each unique 4K frame in `insertingIntermediate(cache: true)` creates
        // a fresh cached Metal intermediate every display tick and competes
        // with screen/camera composition. Only time-invariant backgrounds
        // benefit from this persistent cache.
        if scene.source.isVideo {
            key = nil
            value = nil
            return nil
        }
        let nextKey = Key(
            scene: scene,
            canvasSize: canvasSize,
            wallpaperRevision: wallpaperRevision
        )
        if key == nextKey, let value {
            return value
        }
        let canvasRect = CGRect(
            x: 0,
            y: 0,
            width: max(canvasSize.width, 2),
            height: max(canvasSize.height, 2)
        )
        let nextValue = SharedFrameRenderer.backgroundImage(
            scene: scene,
            canvasRect: canvasRect,
            wallpaperSource: wallpaperSource
        ).insertingIntermediate(cache: true)
        key = nextKey
        value = nextValue
        return nextValue
    }

    mutating func reset() {
        key = nil
        value = nil
    }
}

struct PreviewPresentationEpoch: Equatable, Sendable {
    let mediaGeneration: UInt64?
    let discontinuityID: UInt64?
    let isPlaying: Bool
}

/// Cached camera pixels have their own source/epoch ownership. An unavailable
/// auxiliary layer never holds the rest of a playing composition.
enum PreviewCameraFrameContinuityPolicy {
    /// A paused seek evaluates the destination scene immediately, while the
    /// camera's exact frame arrives asynchronously. The screen path already
    /// keeps its last decoded pixel across that hand-off; applying a stricter
    /// discontinuity check only to the camera made every timeline click expose
    /// one screen-only frame. A media-generation change is still a hard
    /// boundary, and playback never accepts a stale discontinuity.
    static func canUseCachedFrame(
        cachedMediaGeneration: UInt64?,
        cachedDiscontinuityID: UInt64?,
        currentMediaGeneration: UInt64,
        currentDiscontinuityID: UInt64,
        presentationIsPaused: Bool
    ) -> Bool {
        guard cachedMediaGeneration == currentMediaGeneration else { return false }
        return cachedDiscontinuityID == currentDiscontinuityID
            || presentationIsPaused
    }


}

enum PreviewPresentationVisibilityPolicy {
    static func shouldSuspend(
        hasWindow: Bool,
        isMiniaturized: Bool,
        isVisible: Bool,
        isApplicationActive: Bool = true
    ) -> Bool {
        !hasWindow || isMiniaturized || !isVisible || !isApplicationActive
    }
}

enum PreviewLayerRetirementPolicy {
    /// A tiny retirement drawable completes asynchronously. It may dismantle
    /// the backing layer only if the window has not resumed or started a newer
    /// retirement request while the GPU command was in flight.
    static func shouldFinalize(
        requestedGeneration: UInt64,
        latestGeneration: UInt64,
        isSuspended: Bool,
        ownsRequestedLayer: Bool
    ) -> Bool {
        requestedGeneration == latestGeneration
            && isSuspended
            && ownsRequestedLayer
    }
}

enum PreviewRenderValidity {
    static func shouldDiscardBeforeRendering(
        isPausedFrame: Bool,
        generation: UInt64,
        latestGeneration: UInt64
    ) -> Bool {
        isPausedFrame && generation != latestGeneration
    }

    /// Playback frames in one continuous interval must not be dropped merely
    /// because a newer tick has been queued; doing so previously reduced a
    /// nominal 60 Hz preview to roughly 45 fps. A pause, seek or media swap is
    /// different: its epoch changes, so an old queued playback drawable must
    /// never present over the new stationary interval.
    static func shouldPresent(
        jobEpochID: UInt64,
        latestEpochID: UInt64
    ) -> Bool {
        jobEpochID == latestEpochID
    }
}

/// One display-link evaluation produced without publishing SwiftUI state.
/// Keeping this value backend-neutral lets the NSView pull the same scene and
/// render plan as export while the rest of the editor tree remains untouched.
struct SharedPreviewPlaybackFrame: Sendable {
    let renderPlan: FrameRenderPlan
    let semanticScene: FrameScene
}

typealias SharedPreviewPlaybackFrameProvider = @Sendable (
    EditorPlaybackRenderTick
) -> SharedPreviewPlaybackFrame

/// The preview-only media boundary. Timeline and project interpretation stay
/// in `FrameSceneEvaluator`; this value only carries decoded media frames into
/// the same compositor used by export.
enum SharedPreviewFramePipeline {
    nonisolated static func rasterPlan(_ plan: FrameRenderPlan) -> FrameRenderPlan {
        var result = plan
        result.outputDuration = 0
        return result
    }

    nonisolated static func orientedFrame(
        _ image: CIImage,
        preferredTransform: CGAffineTransform
    ) -> CIImage {
        VideoExporter.orientVideoFrameForDisplay(
            image,
            preferredTransform: preferredTransform
        )
    }

    nonisolated static func render(
        plan: FrameRenderPlan,
        resources: SharedFrameRenderResources
    ) -> CIImage? {
        let scene = plan.scene
        let extent = CGRect(
            x: 0,
            y: 0,
            width: max(scene.canvasSize.width, 2),
            height: max(scene.canvasSize.height, 2)
        )
        let image = SharedFrameCompositor.composite(
            plan,
            resources: resources,
            extent: extent
        )
        PreviewSnapshot.store(image)
        return image
    }

}

/// EDT-054: the most recent composed preview frame, so the AI can look at
/// the picture it is editing (`canvas.snapshot`).
enum PreviewSnapshot {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var image: CIImage?
    }
    private static let box = Box()

    static func store(_ image: CIImage?) {
        guard let image else { return }
        box.lock.lock(); box.image = image; box.lock.unlock()
    }

    static var latest: CIImage? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.image
    }
}

/// A passive Core Image preview. SwiftUI remains responsible for hit targets,
/// selection outlines, crop handles and gestures, while every visible project
/// pixel below those overlays comes from `SharedFrameRenderer`.
