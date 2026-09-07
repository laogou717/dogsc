import AppKit
import AVKit
import RecorderCore

struct CanvasPreviewLayout {
    let sourceAspect: CGFloat
    let scene: CompositionSceneEvaluation
    /// Point-space scene used only by SwiftUI hit targets and overlays.
    let frameScene: FrameScene
    /// Backing-pixel scene paired with `renderPlan`; visual project pixels are
    /// never composed at point resolution and enlarged on a Retina display.
    let rasterFrameScene: FrameScene
    let renderPlan: FrameRenderPlan
    /// Immutable inputs captured once by the SwiftUI update. The 60 Hz native
    /// playback loop evaluates only this context instead of rebuilding all
    /// point-space interaction geometry on every display refresh.
    let playbackEvaluation: CanvasPlaybackEvaluationContext
}

struct CanvasPlaybackEvaluationContext: Equatable, Sendable {
    let project: RecorderProject
    let outputDuration: TimeInterval
    let frameRate: Int
    let rasterCanvasSize: CompositionSize
    let sourceAspectRatio: Double
    let cameraSourceSize: CompositionSize?
    let primaryPlan: TimelineMediaPlan?
    let cameraPlan: TimelineMediaPlan?
    let pointerTrack: ProjectPointerTrack?
    let cursorMetrics: CursorAssetMetrics?
    let cursorMetricsByAssetID: [CursorAssetID: CursorAssetMetrics]
    let zoomTrack: ZoomAnimationTrack
    let screenMotionTrack: ScreenMotionTrack
    let cameraMotionTrack: CameraMotionTrack

    func frame(at presentationTime: TimeInterval) -> SharedPreviewPlaybackFrame {
        let primarySlice = primaryPlan?.slice(atOutputTime: presentationTime)
        let primaryRange = primarySlice.flatMap {
            MediaTimeRange(start: $0.outputStart, duration: $0.duration)
        }
        let plan = FrameSceneEvaluator.renderPlan(
            project: project,
            presentationTime: presentationTime,
            outputDuration: outputDuration,
            frameRate: frameRate,
            canvasSize: rasterCanvasSize,
            sourceAspectRatio: sourceAspectRatio,
            cameraSourceSize: cameraSourceSize,
            pointerTrack: pointerTrack,
            cursorMetrics: cursorMetrics,
            cursorMetricsByAssetID: cursorMetricsByAssetID,
            zoomTrack: zoomTrack,
            screenMotionTrack: screenMotionTrack,
            cameraMotionTrack: cameraMotionTrack,
            activePrimaryRange: primaryRange,
            cameraTimeline: cameraPlan
        )
        // Reuse the already-evaluated presentation scene instead of running
        // the complete pointer/zoom/projection evaluator a second time.
        let semanticScene = plan.scene
        return SharedPreviewPlaybackFrame(
            renderPlan: plan,
            semanticScene: semanticScene
        )
    }
}

enum EditorPreviewResolutionMode: String, CaseIterable, Identifiable {
    case low
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return appLocalized("低分辨率")
        case .full: return appLocalized("完整分辨率")
        }
    }
}

enum CanvasPreviewRasterPolicy {
    static func pixelSize(
        points: CGSize,
        displayScale _: CGFloat,
        mode: EditorPreviewResolutionMode = .low,
        fullResolution: CGSize? = nil
    ) -> CGSize {
        // “流畅”是用户主动选择的性能档，而不是窗口当前 backing
        // scale 的别名。在 Retina 屏幕上按 2× backing pixels 合成，
        // 仍会让一个大编辑窗口接近 4K 工作量，和完整源分辨率的负担
        // 差距太小。用 1× point raster 可把像素量稳定降为原来的
        // 四分之一；CAMetalLayer 负责显示缩放，几何和动画仍由同一
        // FrameRenderPlan 求值。完整档继续严格使用源分辨率。
        let lowResolution = CGSize(
            width: max(points.width.rounded(.up), 2),
            height: max(points.height.rounded(.up), 2)
        )
        guard mode == .full,
              let fullResolution,
              fullResolution.width.isFinite,
              fullResolution.height.isFinite,
              fullResolution.width > 0,
              fullResolution.height > 0 else {
            return lowResolution
        }
        return CGSize(
            width: max(fullResolution.width, 2),
            height: max(fullResolution.height, 2)
        )
    }

    /// PRE-007: the Metal drawable must match the selected raster canvas.
    /// Merely evaluating a 5K scene and immediately rendering it into the
    /// low-resolution window backing texture is still a low-resolution
    /// preview. `CAMetalLayer` scales this drawable into its view bounds.
    static func drawablePixelSize(
        rasterCanvasSize: CompositionSize,
        maximumTextureDimension: CGFloat = 16_384
    ) -> CGSize {
        let width = max(CGFloat(rasterCanvasSize.width), 2)
        let height = max(CGFloat(rasterCanvasSize.height), 2)
        let maximumEdge = max(width, height)
        let limit = max(maximumTextureDimension, 2)
        let scale = maximumEdge > limit ? limit / maximumEdge : 1
        return CGSize(
            width: max((width * scale).rounded(), 2),
            height: max((height * scale).rounded(), 2)
        )
    }
}

enum CanvasPreviewInteractionPolicy {
    /// PRE-004/PRE-006/MOT-001: playback shows only composited project pixels.
    /// SwiftUI editing handles are evaluated from the stationary editor tick,
    /// so leaving them visible during display-link playback makes a stale
    /// dashed outline detach from a moving or projected screen and masquerade
    /// as a disappearing authored border.
    static func showsEditingOverlays(isPlaying: Bool) -> Bool {
        !isPlaying
    }
}

/// The composition is immutable after construction. This explicit boundary
/// lets precise frame extraction run off the main actor without pretending an
/// actively-mutated AVFoundation object is generally Sendable.
final class ImmutablePreviewAsset: @unchecked Sendable {
    let asset: AVAsset
    let videoComposition: AVVideoComposition?

    init(_ asset: AVAsset, videoComposition: AVVideoComposition? = nil) {
        self.asset = asset
        self.videoComposition = videoComposition
    }
}

/// Single-use, cancellable decode request. Cancelling the Swift Task alone
/// does not stop AVAssetImageGenerator; rapid seek scrubbing would pile up
/// dozens of full decodes in the background. This owner exposes `cancel()`
/// that the playback controller calls whenever it abandons a paused-frame
/// request (same pattern as `EditorMediaThumbnailRequest`).
final class PausedPreviewFrameRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(_ asset: AVAsset, videoComposition: AVVideoComposition? = nil) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        // Multi-source instructions already orient every layer into the
        // canonical render size. Applying a track transform a second time can
        // rotate imported portrait clips only in paused/thumbnail frames.
        generator.appliesPreferredTrackTransform = videoComposition == nil
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    func image(at time: CMTime) async throws -> CGImage {
        try await generator.image(at: time).image
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
    }
}

enum PausedPreviewFrameLoader {
    nonisolated static func image(
        from source: ImmutablePreviewAsset,
        at time: CMTime
    ) async throws -> CGImage {
        let request = PausedPreviewFrameRequest(
            source.asset,
            videoComposition: source.videoComposition
        )
        return try await withTaskCancellationHandler {
            try await request.image(at: time)
        } onCancel: {
            request.cancel()
        }
    }
}
