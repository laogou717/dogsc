import AppKit
import Foundation
import ImageIO

struct BundledWallpaperPreset: Identifiable, Hashable {
    let collection: String
    let fileName: String
    let url: URL

    var relativePath: String { "\(collection)/\(fileName)" }
    var id: String { relativePath }
    var name: String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

struct BundledWallpaperCollection: Identifiable, Hashable {
    let name: String
    let wallpapers: [BundledWallpaperPreset]

    var id: String { name }

    /// `name` is the on-disk directory key; the picker shows a Chinese
    /// display name so the capsules match the rest of the editor UI.
    var displayName: String {
        switch name {
        case "Photography": return "摄影"
        case "Horizon": return "地平线"
        case "Nocturne": return "夜曲"
        default: return name
        }
    }
}

enum BundledWallpaperLibrary {
    static let collectionOrder = [
        "Photography", "Horizon", "Nocturne",
    ]

    static let collections: [BundledWallpaperCollection] = {
        guard let root = rootURL else { return [] }
        let fileManager = FileManager.default
        return collectionOrder.compactMap { collection in
            let directory = root.appendingPathComponent(collection, isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            let images = urls
                .filter { ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map {
                    BundledWallpaperPreset(
                        collection: collection,
                        fileName: $0.lastPathComponent,
                        url: $0
                    )
                }
            guard !images.isEmpty else { return nil }
            return BundledWallpaperCollection(name: collection, wallpapers: images)
        }
    }()

    static func resolve(relativePath: String?) -> URL? {
        guard let relativePath, let rootURL else { return nil }
        let candidate = rootURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static var rootURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Wallpapers", isDirectory: true)
    }
}

/// The wallpaper grid is only about 80×50 points per tile. Decoding the source
/// JPEG directly made the two photographic presets allocate their full 5K
/// backing stores merely to draw a thumbnail. ImageIO downsamples during decode
/// so browsing collections does not compete with preview and timeline memory.
enum WallpaperThumbnailDecoder {
    static let defaultMaximumPixelSize = 320

    static func image(
        at url: URL,
        maximumPixelSize: Int = defaultMaximumPixelSize,
        aspectRatio: CGFloat? = nil
    ) -> NSImage? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        // 按目标纵横比中心裁剪。竖幅壁纸若不裁剪，scaledToFill 的图片
        // 元素会以原始纵横比（如 92×161）上报命中框，向上盖住壁纸分类
        // 胶囊行（UX-024 反复回归）。裁剪后图片与格子同形，无溢出。
        if let aspectRatio, aspectRatio > 0 {
            let width = CGFloat(thumbnail.width)
            let height = CGFloat(thumbnail.height)
            let cropWidth = min(width, height * aspectRatio)
            let cropHeight = min(height, width / aspectRatio)
            let rect = CGRect(
                x: (width - cropWidth) / 2,
                y: (height - cropHeight) / 2,
                width: cropWidth,
                height: cropHeight
            )
            thumbnail = thumbnail.cropping(to: rect) ?? thumbnail
        }
        let representation = NSBitmapImageRep(cgImage: thumbnail)
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(representation)
        return image
    }

    static func decodedByteCost(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 0 }
        return max(representation.pixelsWide, 0)
            * max(representation.pixelsHigh, 0)
            * 4
    }
}

enum WallpaperThumbnailLoader {
    /// 缩略图格子的目标纵横比：宽 ≈ (检查器内容宽 280–400 − 边距)/3，
    /// 高固定 50。解码时即按此裁剪，见 `WallpaperThumbnailDecoder.image`。
    static let gridCellAspectRatio: CGFloat = 92.0 / 50.0

    static func image(
        at url: URL,
        maximumPixelSize: Int = WallpaperThumbnailDecoder.defaultMaximumPixelSize,
        aspectRatio: CGFloat? = WallpaperThumbnailLoader.gridCellAspectRatio
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let decodeTask = Task<NSImage?, Never>.detached(priority: .utility) {
            autoreleasepool {
                guard !Task.isCancelled else { return nil }
                return WallpaperThumbnailDecoder.image(
                    at: url,
                    maximumPixelSize: maximumPixelSize,
                    aspectRatio: aspectRatio
                )
            }
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    /// 打开"背景"分区时后台预热全部缩略图：首次切换集合的网格立即
    /// 呈现，不会逐格等待解码（此前大图的首次解码让切换看起来"没反应"）。
    @MainActor
    static func prewarmAll(
        into cache: NSCache<NSString, NSImage>
    ) async {
        for collection in BundledWallpaperLibrary.collections {
            for preset in collection.wallpapers {
                let key = preset.relativePath as NSString
                if cache.object(forKey: key) != nil { continue }
                guard let decoded = await image(at: preset.url) else { continue }
                cache.setObject(
                    decoded,
                    forKey: key,
                    cost: WallpaperThumbnailDecoder.decodedByteCost(of: decoded)
                )
            }
        }
    }
}

enum WallpaperFullImageLoader {
    static func image(at url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let decodeTask = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            autoreleasepool {
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(
                          source,
                          0,
                          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                      ),
                      !Task.isCancelled else {
                    return nil
                }
                let representation = NSBitmapImageRep(cgImage: image)
                let result = NSImage(size: NSSize(width: image.width, height: image.height))
                result.addRepresentation(representation)
                return result
            }
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            // A SwiftUI `.task(id:)` is cancelled when the user picks another
            // wallpaper or closes the editor. Detached work does not inherit
            // that cancellation automatically, so forward it explicitly;
            // otherwise several full-resolution decodes can keep competing
            // with playback after their result is already obsolete.
            decodeTask.cancel()
        }
    }
}
