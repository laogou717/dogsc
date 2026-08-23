import RecorderCore
import SwiftUI

/// 画布场景求值（低清/完整栅格策略、播放求值上下文），从
/// `EditorCanvasPreview.swift` 拆出以满足架构行数预算。
extension CanvasPreview {
    func previewLayout(
        canvasSize: CGSize,
        renderScale: CGFloat,
        playbackTime: TimeInterval,
        tracks: EditorCanvasPlaybackTracks
    ) -> CanvasPreviewLayout {
        let sourceAspect = sourceAspectRatio
        let sourceCanvasDimensions = project.canvas.pixelDimensions(
            resolution: .source,
            sourceAspectRatio: Double(sourceAspect),
            sourcePixelSize: CanvasDimensions(
                width: max(Int(sourcePixelSize.width.rounded()), 2),
                height: max(Int(sourcePixelSize.height.rounded()), 2)
            )
        )
        let rasterCanvasSize = CanvasPreviewRasterPolicy.pixelSize(
            points: canvasSize,
            displayScale: displayScale,
            mode: previewResolutionMode,
            fullResolution: CGSize(
                width: sourceCanvasDimensions.width,
                height: sourceCanvasDimensions.height
            )
        )
        let evaluatedProject = project
        let mediaPlan = mediaSession.mediaPlan
        let pointerEvaluation = mediaPlan?.pointer.evaluation(
            at: playbackTime,
            motion: project.motion,
            style: project.cursorStyle
        ) ?? PointerTrackEvaluation(position: nil, cursor: nil)
        let activeZoomClip = tracks.zoom.activeClip(at: playbackTime)
        let activeAutomaticClip = activeZoomClip.flatMap {
            $0.origin == .automatic ? $0 : nil
        }
        let automaticCameraPosition = activeAutomaticClip.map { clip in
            mediaPlan?.pointer.automaticCameraFocus(
                at: playbackTime,
                clip: clip,
                motion: evaluatedProject.motion
            ) ?? clip.focus
        }
        let inheritedAutomaticCameraPosition: NormalizedPoint? = activeZoomClip
            .flatMap { tracks.zoom.adjacentPreviousClip(to: $0) }
            .flatMap { previous in
                guard previous.origin == .automatic else { return nil }
                return mediaPlan?.pointer.automaticCameraFocus(
                    at: previous.endTime,
                    clip: previous,
                    motion: evaluatedProject.motion
                ) ?? previous.focus
            }
        // This evaluation is interaction-only: it supplies drag normalization
        // and selection-overlay transforms. Visible project pixels are lowered
        // exclusively from `frameScene` by `SharedRenderedPreviewView`.
        let scene = CompositionSceneEvaluator.evaluate(
            project: evaluatedProject,
            time: playbackTime,
            canvasWidth: Double(canvasSize.width),
            canvasHeight: Double(canvasSize.height),
            sourceAspectRatio: Double(sourceAspect),
            cameraAspectRatio: Double(cameraSourceAspectRatio),
            styleScale: Double(renderScale),
            automaticZoomFocus: automaticCameraPosition,
            inheritedAutomaticZoomFocus: inheritedAutomaticCameraPosition,
            zoomTrack: tracks.zoom,
            screenMotionTrack: tracks.screenMotion,
            cameraMotionTrack: tracks.cameraMotion
        )
        let cursorMetrics = CursorAssetLibrary.resolvedAsset(
            for: evaluatedProject.cursorStyle.assetID
        )?.metrics
        let frameScene = FrameSceneEvaluator.scene(
            project: evaluatedProject,
            time: playbackTime,
            canvasSize: CompositionSize(
                width: Double(canvasSize.width),
                height: Double(canvasSize.height)
            ),
            sourceAspectRatio: Double(sourceAspect),
            // contentFill 的缩放会作用在真实像素图像上：这里必须给真实像素
            // 尺寸，给归一化宽高比会把图像放大数百倍，PIP 只剩左边缘一列
            // 像素（表现为摄像头全黑）。
            cameraSourceSize: hasCameraTrack
                ? mediaSession.cameraDisplaySize.map {
                    CompositionSize(width: Double($0.width), height: Double($0.height))
                }
                : nil,
            pointerTrack: mediaPlan?.pointer,
            pointerEvaluation: pointerEvaluation,
            cursorMetrics: cursorMetrics,
            zoomTrack: tracks.zoom,
            screenMotionTrack: tracks.screenMotion,
            cameraMotionTrack: tracks.cameraMotion
        )
        let playbackEvaluation = CanvasPlaybackEvaluationContext(
            project: evaluatedProject,
            outputDuration: mediaSession.outputDuration,
            frameRate: evaluatedProject.exportSettings.frameRate.rawValue,
            rasterCanvasSize: CompositionSize(
                width: Double(rasterCanvasSize.width),
                height: Double(rasterCanvasSize.height)
            ),
            sourceAspectRatio: Double(sourceAspect),
            cameraSourceSize: hasCameraTrack
                ? mediaSession.cameraDisplaySize.map {
                    CompositionSize(width: Double($0.width), height: Double($0.height))
                }
                : nil,
            primaryPlan: mediaPlan?.primary,
            cameraPlan: mediaPlan?.camera,
            pointerTrack: mediaPlan?.pointer,
            cursorMetrics: cursorMetrics,
            zoomTrack: tracks.zoom,
            screenMotionTrack: tracks.screenMotion,
            cameraMotionTrack: tracks.cameraMotion
        )
        let playbackFrame = playbackEvaluation.frame(at: playbackTime)
        return CanvasPreviewLayout(
            sourceAspect: sourceAspect,
            scene: scene,
            frameScene: frameScene,
            rasterFrameScene: playbackFrame.semanticScene,
            renderPlan: playbackFrame.renderPlan,
            playbackEvaluation: playbackEvaluation
        )
    }
}
