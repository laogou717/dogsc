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
        // The selected preview quality is a real rendering contract, not a
        // paused-frame-only inspection hint. Flow mode uses a deliberate 1×
        // view raster so it materially reduces work even on Retina screens;
        // full mode keeps the source-native raster for both playback and
        // pause. Silently forcing playback back to low made this control
        // appear broken and made authored edges change at Play.
        let previewRasterCanvasSize = CanvasPreviewRasterPolicy.pixelSize(
            points: canvasSize,
            displayScale: displayScale,
            mode: previewResolutionMode,
            fullResolution: CGSize(
                width: sourceCanvasDimensions.width,
                height: sourceCanvasDimensions.height
            )
        )
        let evaluatedProject = overlayAuthoringProject(at: playbackTime)
        let mediaPlan = mediaSession.mediaPlan
        let pointerEvaluation = mediaPlan?.pointer.evaluation(
            at: playbackTime,
            motion: evaluatedProject.motion,
            style: evaluatedProject.cursorStyle
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
            reanchorAutomaticEntry: activeAutomaticClip.map {
                mediaPlan?.pointer.automaticEntryStartsAfterCut($0) ?? false
            } ?? false,
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
            outputDuration: mediaSession.outputDuration,
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
            cursorMetricsByAssetID: CursorAssetLibrary.metricsByAssetID,
            zoomTrack: tracks.zoom,
            screenMotionTrack: tracks.screenMotion,
            cameraMotionTrack: tracks.cameraMotion
        )
        let makeEvaluation: (CGSize) -> CanvasPlaybackEvaluationContext = { rasterSize in
            CanvasPlaybackEvaluationContext(
                project: evaluatedProject,
                outputDuration: mediaSession.outputDuration,
                frameRate: evaluatedProject.exportSettings.frameRate.rawValue,
                rasterCanvasSize: CompositionSize(
                    width: Double(rasterSize.width),
                    height: Double(rasterSize.height)
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
                cursorMetricsByAssetID: CursorAssetLibrary.metricsByAssetID,
                zoomTrack: tracks.zoom,
                screenMotionTrack: tracks.screenMotion,
                cameraMotionTrack: tracks.cameraMotion
            )
        }
        let previewEvaluation = makeEvaluation(previewRasterCanvasSize)
        let visibleFrame = previewEvaluation.frame(at: playbackTime)
        return CanvasPreviewLayout(
            sourceAspect: sourceAspect,
            scene: scene,
            frameScene: frameScene,
            rasterFrameScene: visibleFrame.semanticScene,
            renderPlan: visibleFrame.renderPlan,
            playbackEvaluation: previewEvaluation
        )
    }

    /// A newly inserted sticker normally begins at opacity zero because its
    /// persisted entrance animation starts on that exact frame. While paused
    /// and authoring that selected sticker, expose its final appearance so the
    /// user can immediately position and style it. Playback and export still
    /// evaluate the original 0.7-second animation from the persisted project.
    func overlayAuthoringProject(at playbackTime: TimeInterval) -> RecorderProject {
        guard !playbackController.isPlaying else { return project }
        let frameDuration = 1 / Double(max(project.exportSettings.frameRate.rawValue, 1))
        switch editorStore.selection {
        case let .sticker(id):
            guard let clip = project.timeline.stickerClips.first(where: {
                $0.id == id
            }) else { return project }
            guard clip.timing.contains(playbackTime),
                  playbackTime - clip.timing.startTime <= frameDuration + 0.000_1
            else { return project }
            var authored = project
            // Every sticker whose own first frame is under the paused playhead
            // must be composable, not only the most recently selected one.
            // Otherwise two images pasted together leave the earlier layer at
            // opacity zero until playback starts.
            for index in authored.timeline.stickerClips.indices {
                let candidate = authored.timeline.stickerClips[index]
                guard candidate.timing.contains(playbackTime),
                      playbackTime - candidate.timing.startTime
                        <= frameDuration + 0.000_1 else { continue }
                authored.timeline.stickerClips[index].enterDuration = 0
            }
            return authored
        case let .mosaic(id):
            guard let index = project.timeline.mosaicClips.firstIndex(where: {
                $0.id == id
            }) else { return project }
            let clip = project.timeline.mosaicClips[index]
            guard clip.timing.contains(playbackTime),
                  playbackTime - clip.timing.startTime <= frameDuration + 0.000_1
            else { return project }
            // The copy exists only for paused authoring. A newly inserted
            // transitioning effect must still be fully visible while it is
            // selected; playback/export retain the persisted entrance.
            var authored = project
            authored.timeline.mosaicClips[index].transitionInDuration = 0
            return authored
        default:
            return project
        }
    }
}
