import AppKit
import Foundation
import ImageIO

/// Shared decoding for user-selected and macOS-managed wallpaper files.
/// This deliberately contains no bundled-wallpaper catalogue or product data.
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
        let image = NSImage(
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
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
                let result = NSImage(
                    size: NSSize(width: image.width, height: image.height)
                )
                result.addRepresentation(representation)
                return result
            }
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }
}
