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
    let generation: UInt64
    /// Stable across consecutive playback frames, but changes for pause,
    /// seek/scrub discontinuities and prepared-media replacement. Generation
    /// orders every submitted frame; epoch decides whether an older playback
    /// job still belongs to the currently visible transport interval.
    let presentationEpochID: UInt64
    /// The display-link deadline this playback frame was evaluated for.
    /// Stationary frames have no deadline and present immediately.
    let presentationHostTime: CFTimeInterval?
    let plan: FrameRenderPlan
    /// An actual project 3D frame evaluated at the same raster size. It is
    /// rendered offscreen after the visible paused frame so playback never
    /// discovers the full-size perspective allocation on its first 3D tick.
    let perspectivePrewarmPlan: FrameRenderPlan?
    let resources: SharedFrameRenderResources
    let canvasSize: CompositionSize
    /// Actual on-screen drawable size. The editor may display a 4K project in
    /// a 900-point canvas; rendering the authored 4K size and then multiplying
    /// it by Retina scale accidentally created an 8K texture every frame.
    let destinationPixelSize: CGSize
    let colorProfile: CoreImageFrameColorProfile
    let colorContract: FrameColorContract?
    /// The view-owned drawable target. CAMetalLayer is internally thread-safe
    /// for `nextDrawable()`; this unchecked boundary is confined to the one
    /// serial preview render queue.
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
    let separatesCursor: Bool
    let contentRevision: UInt64
    let backingScale: CGFloat
    let destinationPixelSize: CGSize
    let colorContract: FrameColorContract?

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.separatesCursor == rhs.separatesCursor,
              lhs.contentRevision == rhs.contentRevision,
              lhs.backingScale == rhs.backingScale,
              lhs.destinationPixelSize == rhs.destinationPixelSize,
              lhs.colorContract == rhs.colorContract,
              lhs.plan.frameRate == rhs.plan.frameRate else {
            return false
        }

        // Presentation/output time and FrameScene.time are evaluation
        // provenance. Every renderable value has already been lowered into the
        // scene. Comparing those clocks made a visually identical frame dirty.
        return scenesMatchVisually(
            lhs.plan.scene,
            rhs.plan.scene,
            ignoringCursor: lhs.separatesCursor
        )
    }

    private static func scenesMatchVisually(
        _ lhs: FrameScene,
        _ rhs: FrameScene,
        ignoringCursor: Bool
    ) -> Bool {
        guard lhs.canvasSize == rhs.canvasSize,
              lhs.color == rhs.color,
              lhs.background == rhs.background,
              lhs.screen == rhs.screen,
              lhs.camera == rhs.camera,
              lhs.stickers == rhs.stickers,
              lhs.progress == rhs.progress else {
            return false
        }
        if !ignoringCursor, lhs.cursor != rhs.cursor {
            return false
        }
        return layerOrdersMatch(
            lhs.layerOrder,
            rhs.layerOrder,
            ignoringCursor: ignoringCursor
        )
    }

    private static func layerOrdersMatch(
        _ lhs: [FrameLayerRole],
        _ rhs: [FrameLayerRole],
        ignoringCursor: Bool
    ) -> Bool {
        guard ignoringCursor else { return lhs == rhs }
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
}

/// The cursor's Core Animation appearance changes far less often than its
/// position. Keeping that distinction explicit prevents the 60 Hz playback
/// path from rebuilding the same image, color and vector path for every mouse
/// movement while still allowing geometry/projection to update every frame.
struct PreviewCursorOverlayAppearance: Equatable {
    let assetID: CursorAssetID
    let shadow: FrameShadow?
    let clickColor: HexColor
    let clickStyle: CursorClickEffectStyle
    let clickOpacity: Double
    let clickScale: Double
    let clickDiameter: Double
    let clickLineWidth: Double

    init(cursor: FrameCursorScene) {
        assetID = cursor.assetID
        shadow = cursor.shadow
        clickColor = cursor.effectiveClickColor
        clickStyle = cursor.clickStyle
        clickOpacity = cursor.clickOpacity
        clickScale = cursor.clickScale
        clickDiameter = cursor.layout.clickDiameter * cursor.clickScale
        clickLineWidth = cursor.layout.clickLineWidth
    }
}

/// Rasterized cursor contents cache key: the on-screen pixel size changes only
/// on zoom/resize, while the pointer position updates every display tick.
struct PreviewCursorContentsSignature: Equatable {
    let assetID: CursorAssetID
    let width: Int
    let height: Int
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
    ) -> CIImage {
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

enum PreviewPresentationVisibilityPolicy {
    static func shouldSuspend(
        hasWindow: Bool,
        isMiniaturized: Bool,
        isVisible: Bool
    ) -> Bool {
        !hasWindow || isMiniaturized || !isVisible
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

/// Structural identity of the expensive full-size 3D Core Image graph.
/// Animation time, position, scale and quad coordinates deliberately do not
/// participate: those values change parameters of an already-compiled graph,
/// not the filter/texture families it must allocate. Editing only a transition
/// duration therefore cannot launch another 5K prewarm beside Play.
struct PreviewPerspectivePrewarmSignature: Equatable, Hashable, Sendable {
    let destinationWidth: Int
    let destinationHeight: Int
    let hasProjectedBorder: Bool
    let hasProjectedShadow: Bool
    let hasScreenChrome: Bool
    let hasRasterCursor: Bool
    let hasCamera: Bool
    let hasCameraBorder: Bool
    let hasCameraShadow: Bool
    let hasBackgroundBlur: Bool

    init?(plan: FrameRenderPlan, destinationPixelSize: CGSize) {
        let scene = plan.scene
        guard !SharedFrameRenderer.isIdentityProjection(scene.screen) else {
            return nil
        }
        destinationWidth = max(Int(destinationPixelSize.width.rounded()), 2)
        destinationHeight = max(Int(destinationPixelSize.height.rounded()), 2)
        hasProjectedBorder = scene.screen.borderWidth > 0
        hasProjectedShadow = (scene.screen.shadow?.opacity ?? 0) > 0
        if case .chrome = scene.screen.decoration {
            hasScreenChrome = true
        } else {
            hasScreenChrome = false
        }
        hasRasterCursor = scene.cursor != nil && scene.layerOrder.contains(.cursor)
        hasCamera = (scene.camera?.opacity ?? 0) > 0
        hasCameraBorder = (scene.camera?.borderWidth ?? 0) > 0
        hasCameraShadow = (scene.camera?.shadow?.opacity ?? 0) > 0
        hasBackgroundBlur = scene.background.blurRadius > 0
    }
}

enum PreviewPerspectivePrewarmPolicy {
    /// Give a just-edited paused frame a short quiet interval. If the user
    /// presses Play immediately, the epoch changes and the retired full-size
    /// warm-up is skipped instead of competing with the first playback frame.
    static let idleDelay: TimeInterval = 0.12

    static func shouldRun(
        jobGeneration: UInt64,
        latestGeneration: UInt64,
        jobEpochID: UInt64,
        latestEpochID: UInt64,
        colorContractMatches: Bool
    ) -> Bool {
        jobGeneration == latestGeneration
            && jobEpochID == latestEpochID
            && colorContractMatches
    }
}

enum PreviewRenderBackpressurePolicy {
    static func maximumInFlight(
        isPausedFrame: Bool,
        playbackLimit: Int
    ) -> Int {
        isPausedFrame ? 1 : max(playbackLimit, 1)
    }

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
struct SharedPreviewPlaybackFrame {
    let renderPlan: FrameRenderPlan
    let semanticScene: FrameScene
}

typealias SharedPreviewPlaybackFrameProvider = @MainActor (
    EditorPlaybackRenderTick
) -> SharedPreviewPlaybackFrame

/// The preview-only media boundary. Timeline and project interpretation stay
/// in `FrameSceneEvaluator`; this value only carries decoded media frames into
/// the same compositor used by export.
enum SharedPreviewFramePipeline {
    nonisolated static func canSeparateCursor(in plan: FrameRenderPlan) -> Bool {
        let scene = plan.scene
        // A separated CALayer cursor would sit above the raster spotlight and
        // stay sharp outside its focus. Keep it in the base composite whenever
        // spotlight is active so "everything below" has one visual result.
        if scene.layerOrder.contains(.spotlight) { return false }
        // CUR-002/PRE-002: a 3D screen still keeps its pointer in a tiny
        // independent layer. A later camera layer remains the only reason to
        // retain raster composition under perspective.
        return !SharedFrameRenderer.isIdentityProjection(scene.screen)
            ? scene.camera == nil
            : !cursorIntersectsLaterCamera(in: scene)
    }

    /// The authored camera is above the cursor. A separate SwiftUI cursor is
    /// above the raster surface, so it is only equivalent while its complete
    /// visual footprint does not overlap that later camera layer. This keeps
    /// the fast path for almost all pointer motion without changing z-order
    /// when the pointer travels behind the camera bubble.
    private nonisolated static func cursorIntersectsLaterCamera(
        in scene: FrameScene
    ) -> Bool {
        guard let cursor = scene.cursor,
              let camera = scene.camera,
              camera.opacity > 0,
              let cursorIndex = scene.layerOrder.firstIndex(of: .cursor),
              let cameraIndex = scene.layerOrder.firstIndex(of: .camera),
              cursorIndex < cameraIndex else { return false }

        var cursorRect = CGRect(
            x: cursor.layout.origin.x,
            y: cursor.layout.origin.y,
            width: cursor.layout.size.width,
            height: cursor.layout.size.height
        )
        if cursor.isClicking {
            let footprint = max(cursor.layout.clickDiameter, cursor.layout.size.height * 2.5) * cursor.clickScale
            let radius = footprint / 2
            cursorRect = cursorRect.union(CGRect(
                x: cursor.layout.pointer.x - radius,
                y: cursor.layout.pointer.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        if let shadow = cursor.shadow, shadow.opacity > 0 {
            cursorRect = cursorRect.union(
                cursorRect
                    .offsetBy(dx: shadow.offset.x, dy: shadow.offset.y)
                    .insetBy(dx: -shadow.radius, dy: -shadow.radius)
            )
        }

        var cameraRect = CGRect(
            x: camera.rect.x,
            y: camera.rect.y,
            width: camera.rect.width,
            height: camera.rect.height
        ).insetBy(dx: -camera.borderWidth, dy: -camera.borderWidth)
        if let shadow = camera.shadow, shadow.opacity > 0 {
            cameraRect = cameraRect.union(
                cameraRect
                    .offsetBy(dx: shadow.offset.x, dy: shadow.offset.y)
                    .insetBy(dx: -shadow.radius, dy: -shadow.radius)
            )
        }
        return cursorRect.intersects(cameraRect)
    }

    /// The synthetic cursor gets its own cheap Core Animation layer in the
    /// editor. Removing it from the full-canvas Core Image pass lets a 120 Hz
    /// cursor move independently while the base video only recomposites when a
    /// decoded frame or authored screen/camera geometry actually changes.
    nonisolated static func rasterPlan(_ plan: FrameRenderPlan) -> FrameRenderPlan {
        rasterPlan(plan, separatesCursor: canSeparateCursor(in: plan))
    }

    /// The visible preview surface already needs this decision for its CALayer
    /// cursor, so pass the same per-frame result into raster preparation.
    nonisolated static func rasterPlan(
        _ plan: FrameRenderPlan,
        separatesCursor: Bool
    ) -> FrameRenderPlan {
        var result = plan
        result.presentationTime = 0
        result.outputDuration = 0
        var scene = plan.scene
        // `time` has already been lowered into concrete geometry/style and is
        // not read by SharedFrameRenderer. Ignore it for visual identity.
        scene.time = 0
        if separatesCursor {
            scene.cursor = nil
            scene.layerOrder.removeAll { $0 == .cursor }
        }
        result.scene = scene
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
        return SharedFrameCompositor.composite(
            plan,
            resources: resources,
            extent: extent
        )
    }

    /// Compatibility entry for static surfaces such as the crop tool.
    /// It still travels through the render-plan compositor, so a sharp preview
    /// cannot acquire a separate pixel path from export.
    nonisolated static func render(
        scene: FrameScene,
        screen: CIImage,
        camera: CIImage?,
        wallpaper: CIImage?,
        cursor: CIImage?
    ) -> CIImage {
        let plan = FrameRenderPlan(
            presentationTime: scene.time,
            outputDuration: max(scene.time, 0),
            frameRate: 1,
            scene: scene
        )
        let resources = SharedFrameRenderResources(
            screen: screen,
            camera: camera,
            wallpaper: wallpaper,
            cursor: cursor
        )
        return render(plan: plan, resources: resources) ?? SharedFrameRenderer.render(
            scene: scene,
            resources: SharedFrameRenderResources(
                screen: screen,
                camera: camera,
                wallpaper: wallpaper,
                cursor: cursor
            )
        )
    }
}

/// A passive Core Image preview. SwiftUI remains responsible for hit targets,
/// selection outlines, crop handles and gestures, while every visible project
/// pixel below those overlays comes from `SharedFrameRenderer`.
