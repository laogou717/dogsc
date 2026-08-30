import CoreImage
import Foundation
import RecorderCore

/// Composes one fully evaluated output scene. Motion treatment already lives
/// on individual moving layers; the compositor never re-renders frame history.
enum SharedFrameCompositor {
    static func composite(
        _ plan: FrameRenderPlan,
        resources: SharedFrameRenderResources,
        extent: CGRect
    ) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scene = plan.scene
        let background = resources.preparedBackground
            ?? SharedFrameRenderer.backgroundImage(
                scene: scene.background,
                canvasRect: extent,
                wallpaperSource: resources.wallpaper,
                time: scene.time
            )
        return SharedFrameRenderer.render(
            scene: scene,
            resources: resources,
            over: background
        ).cropped(to: extent)
    }
}
