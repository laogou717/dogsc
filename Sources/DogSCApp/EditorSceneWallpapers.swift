import AppKit
import RecorderCore

struct EditorSceneWallpaper {
    var image: NSImage?
    var videoURL: URL?
}

extension CanvasPreview {
    @MainActor
    func loadSceneWallpapers() async {
        var result: [String: EditorSceneWallpaper] = [:]
        for source in project.sceneBackgroundSources where source != project.canvas.backgroundSource {
            guard let key = source.sceneResourceKey, let url = wallpaperURLResolver(source) else { continue }
            if let cached = resolvedSceneWallpapers[key] { result[key] = cached; continue }
            let image = source.isVideo
                ? await SystemWallpaperThumbnailLoader.image(at: url, isVideo: true)
                : await WallpaperFullImageLoader.image(at: url)
            guard !Task.isCancelled else { return }
            result[key] = EditorSceneWallpaper(image: image, videoURL: source.isVideo ? url : nil)
        }
        guard !Task.isCancelled else { return }
        resolvedSceneWallpapers = result
    }
}
