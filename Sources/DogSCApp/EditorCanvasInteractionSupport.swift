import AppKit
import AVKit
import Combine
import CoreImage
import QuartzCore
import RecorderCore
import SwiftUI

@MainActor
final class EditorCanvasDragPreviewRenderer {
    private lazy var context = CIContext(options: [
        .cacheIntermediates: false,
    ])

    static func rasterScale(
        sourceSize: CGSize,
        maximumPixelSize: CGSize
    ) -> CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return 1 }
        let maximumWidth = max(maximumPixelSize.width, 2)
        let maximumHeight = max(maximumPixelSize.height, 2)
        return min(
            max(min(maximumWidth / sourceSize.width, maximumHeight / sourceSize.height), 0.01),
            1
        )
    }

    func image(
        from source: CIImage,
        maximumPixelSize: CGSize
    ) -> NSImage? {
        guard !source.extent.isEmpty, !source.extent.isInfinite else { return nil }
        var normalized = source.transformed(by: CGAffineTransform(
            translationX: -source.extent.minX,
            y: -source.extent.minY
        ))
        let scale = Self.rasterScale(
            sourceSize: normalized.extent.size,
            maximumPixelSize: maximumPixelSize
        )
        if scale < 0.999_9 {
            normalized = normalized.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1,
                ]
            )
        }
        let bounds = normalized.extent.integral
        guard let output = context.createCGImage(normalized, from: bounds) else {
            return nil
        }
        return NSImage(
            cgImage: output,
            size: NSSize(width: output.width, height: output.height)
        )
    }
}

extension CanvasPreview {
/// 拖动摄像头用的即时预览图：取播放控制器的暂停摄像头帧，
    /// 按黑边检测裁剪，并按项目设置水平镜像——合成器在渲染时才做镜像，
    /// 暂停帧本身是未镜像的原始方向，漏掉这一步拖动时画面会左右翻转。
    func pausedCameraDragImage(canvasSize: CGSize) -> NSImage? {
        guard !playbackController.isPlaying,
              abs(project.camera.contentPosition.x - 0.5) < 0.000_1,
              abs(project.camera.contentPosition.y - 0.5) < 0.000_1,
              abs(project.camera.contentScale - 1) < 0.000_1,
              let paused = playbackController.pausedCameraImage else { return nil }
        var proposedRect = NSRect(origin: .zero, size: paused.size)
        guard let cgImage = paused.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return paused }
        var frame = CIImage(cgImage: cgImage)
        if let crop = mediaSession.cameraContentCrop {
            frame = CameraLetterboxAnalysis.cropped(frame, to: crop)
        }
        if project.camera.isMirrored {
            frame = frame.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            frame = frame.transformed(by: CGAffineTransform(
                translationX: -frame.extent.minX,
                y: -frame.extent.minY
            ))
        }
        return dragPreviewRenderer.image(
            from: frame,
            maximumPixelSize: CGSize(
                width: canvasSize.width * max(displayScale, 1),
                height: canvasSize.height * max(displayScale, 1)
            )
        ) ?? paused
    }

    /// 拖动屏幕素材用的即时预览图：暂停屏幕帧按画布裁切设置裁剪。
    /// 缩放视口或 3D 旋转生效时返回 nil（退回合成路径，避免内容不一致）。
    func pausedScreenDragImage(
        scope: EditorCanvasEditScope,
        scene: FrameScreenScene,
        canvasSize: CGSize
    ) -> NSImage? {
        guard !playbackController.isPlaying,
              let paused = playbackController.pausedScreenImage else { return nil }
        // 视口恒等（无缩放/平移）时 finalRect 与 baseRect 完全重合
        let base = scene.baseRect
        let final = scene.finalRect
        guard abs(final.x - base.x) < 0.5, abs(final.y - base.y) < 0.5,
              abs(final.width - base.width) < 0.5, abs(final.height - base.height) < 0.5
        else { return nil }
        if case let .screen(.motion(id)) = scope,
           let target = project.timeline.screenMotionClips.first(where: { $0.id == id })?.target {
            guard abs(target.rotationX) < 0.01,
                  abs(target.rotationY) < 0.01,
                  abs(target.rotationZ) < 0.01 else { return nil }
        }
        let crop = project.canvas.crop.clamped()
        var proposedRect = NSRect(origin: .zero, size: paused.size)
        guard let cgImage = paused.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return paused }
        var frame = CIImage(cgImage: cgImage)
        let width = frame.extent.width
        let height = frame.extent.height
        frame = frame.cropped(to: CGRect(
            x: width * crop.x,
            y: height * (1 - crop.y - crop.height),
            width: width * crop.width,
            height: height * crop.height
        ))
        return dragPreviewRenderer.image(
            from: frame,
            maximumPixelSize: CGSize(
                width: canvasSize.width * max(displayScale, 1),
                height: canvasSize.height * max(displayScale, 1)
            )
        ) ?? paused
    }

    /// 合成帧回报“已带着摄像头内容落地”后清覆盖图；超时兜底防异常状态残留。
    func scheduleCameraDragPreviewClear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !cameraCompositorSuppressed,
                  cameraDragOrigin == nil, cameraSizeOrigin == nil else { return }
            cameraDragPreviewImage = nil
        }
    }

    func scheduleScreenDragPreviewClear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !screenCompositorSuppressed,
                  screenDragOrigin == nil, screenScaleOrigin == nil else { return }
            screenDragPreviewImage = nil
        }
    }

    func commitCanvasInteraction(actionName: String) {
        do {
            _ = try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    var previewAspectRatio: CGFloat {
        switch project.canvas.aspectRatio {
        case .adaptive:
            let crop = project.canvas.crop.clamped()
            let sourceAspect = sourcePixelSize.width / max(sourcePixelSize.height, 1)
            return max(sourceAspect * CGFloat(crop.width / crop.height), 0.01)
        case .landscape: return 16 / 9
        case .standard: return 4 / 3
        case .portrait: return 9 / 16
        case .square: return 1
        }
    }

    func fittedCanvasSize(in available: CGSize) -> CGSize {
        let ratio = previewAspectRatio
        let widthFromHeight = available.height * ratio
        if widthFromHeight <= available.width {
            return CGSize(width: widthFromHeight, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / ratio)
    }

    func previewRenderScale(for canvasSize: CGSize) -> CGFloat {
        CGFloat(
            CompositionSceneEvaluator.canonicalStyleScale(
                canvasWidth: canvasSize.width,
                canvasHeight: canvasSize.height
            )
        )
    }

}

/// SwiftUI lowering of RecorderCore's canonical projected interaction quad.
/// The path deliberately uses canvas coordinates unchanged so visible pixels,
/// selection outlines and hit-testing all share the same geometry contract.
struct ProjectedScreenShape: Shape {
    let quad: ProjectedScreenQuad

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: quad.topLeft.x, y: quad.topLeft.y))
        path.addLine(to: CGPoint(x: quad.topRight.x, y: quad.topRight.y))
        path.addLine(to: CGPoint(x: quad.bottomRight.x, y: quad.bottomRight.y))
        path.addLine(to: CGPoint(x: quad.bottomLeft.x, y: quad.bottomLeft.y))
        path.closeSubpath()
        return path
    }
}

/// 画布拖动吸附：把归一化位置吸附到锚点（中心/边缘停靠位），
/// 返回吸附后的点与各轴命中的参考线位置。
enum CanvasSnapMath {
    static func snapped(
        _ point: NormalizedPoint,
        anchorsX: [Double],
        anchorsY: [Double],
        threshold: Double = 0.02
    ) -> (point: NormalizedPoint, guideX: Double?, guideY: Double?) {
        func snap(_ value: Double, _ anchors: [Double]) -> (Double, Double?) {
            for anchor in anchors where abs(value - anchor) <= threshold {
                return (anchor, anchor)
            }
            return (value, nil)
        }
        let x = snap(point.x, anchorsX)
        let y = snap(point.y, anchorsY)
        return (NormalizedPoint(x: x.0, y: y.0), x.1, y.1)
    }
}
