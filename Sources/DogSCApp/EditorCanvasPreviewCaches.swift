import Foundation
import RecorderCore

/// Keeps the three indexed playback tracks coherent with one exact project
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
}

@MainActor
final class EditorCanvasPlaybackTrackCache {
    private var zoomClips: [ZoomAnimationClip]
    private var screenClips: [ScreenMotionClip]
    private var cameraClips: [CameraMotionClip]
    private var zoomTrack: ZoomAnimationTrack
    private var screenMotionTrack: ScreenMotionTrack
    private var cameraMotionTrack: CameraMotionTrack

    init(project: RecorderProject) {
        zoomClips = project.zoomAnimations
        screenClips = project.timeline.screenMotionClips
        cameraClips = project.timeline.cameraMotionClips
        zoomTrack = ZoomAnimationTrack(zoomClips)
        screenMotionTrack = ScreenMotionTrack(screenClips)
        cameraMotionTrack = CameraMotionTrack(cameraClips)
    }

    func tracks(for project: RecorderProject) -> EditorCanvasPlaybackTracks {
        if zoomClips != project.zoomAnimations {
            zoomClips = project.zoomAnimations
            zoomTrack = ZoomAnimationTrack(zoomClips)
        }
        if screenClips != project.timeline.screenMotionClips {
            screenClips = project.timeline.screenMotionClips
            screenMotionTrack = ScreenMotionTrack(screenClips)
        }
        if cameraClips != project.timeline.cameraMotionClips {
            cameraClips = project.timeline.cameraMotionClips
            cameraMotionTrack = CameraMotionTrack(cameraClips)
        }
        return EditorCanvasPlaybackTracks(
            zoom: zoomTrack,
            screenMotion: screenMotionTrack,
            cameraMotion: cameraMotionTrack
        )
    }
}

/// One exact future 3D prewarm request. `CanvasPreview` may recompute its body
/// for hover, focus and selection chrome without changing any render input.
/// Keeping this cache non-observable avoids publishing another SwiftUI update,
/// while the complete playback context makes stale-plan reuse impossible.
@MainActor
final class EditorCanvasPerspectivePrewarmPlanCache {
    private struct Input: Equatable {
        let playbackEvaluation: CanvasPlaybackEvaluationContext
        let playbackTime: TimeInterval
    }

    private var input: Input?
    private var renderPlan: FrameRenderPlan?

    func plan(
        at playbackTime: TimeInterval,
        using playbackEvaluation: CanvasPlaybackEvaluationContext
    ) -> FrameRenderPlan {
        let nextInput = Input(
            playbackEvaluation: playbackEvaluation,
            playbackTime: playbackTime
        )
        if input == nextInput, let renderPlan {
            return renderPlan
        }
        let nextPlan = playbackEvaluation.frame(at: playbackTime).renderPlan
        input = nextInput
        renderPlan = nextPlan
        return nextPlan
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
