import RecorderCore
import SwiftUI

extension CanvasPreview {
    /// Reuse render placement so unequal margins do not change drag speed or
    /// introduce a jump when crossing the authored centre.
    func screenPlacementAxes(scene: FrameScreenScene, canvasSize: CGSize, scale: Double)
        -> (x: ScreenPlacementAxis, y: ScreenPlacementAxis) {
        let styleScale = Double(previewRenderScale(for: canvasSize))
        let canvas = project.canvas
        let decoration = ScreenFrameGeometry.decorationInsetsAtScaleOne(
            style: canvas.screenFrame, frameScale: canvas.screenFrameScale,
            toolbarScale: canvas.screenFrameToolbarScale,
            fittedWidth: scene.fittedRect.width, fittedHeight: scene.fittedRect.height,
            styleScale: styleScale
        )
        let viewport = ScreenAnchorViewport(
            canvasWidth: Double(canvasSize.width), canvasHeight: Double(canvasSize.height),
            fittedWidth: scene.fittedRect.width, fittedHeight: scene.fittedRect.height,
            borderWidthAtScaleOne: canvas.borderWidth * styleScale,
            decorationTopAtScaleOne: decoration.top,
            decorationRightAtScaleOne: decoration.right,
            decorationBottomAtScaleOne: decoration.bottom,
            decorationLeftAtScaleOne: decoration.left,
            fittedCenterX: scene.fittedRect.midX, fittedCenterY: scene.fittedRect.midY
        )
        return viewport.placementAxes(scale: scale)
    }
}
