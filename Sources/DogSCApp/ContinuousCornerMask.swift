import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SwiftUI

/// Generates smooth, Apple-standard continuous corner rounded masks (squircles)
/// with G2 curvature continuity matching macOS/iOS system UI.
enum ContinuousCornerMask {
    private static let cache = ContinuousCornerMaskCache()

    nonisolated static func resetCache() {
        cache.removeAllObjects()
    }

    nonisolated static func mask(
        rect: CGRect,
        radius: CGFloat
    ) -> CIImage {
        guard rect.width > 0, rect.height > 0 else {
            return CIImage(color: .clear).cropped(to: rect)
        }
        guard radius > 0 else {
            return CIImage(color: .white).cropped(to: rect)
        }
        let clampedRadius = min(radius, min(rect.width, rect.height) / 2)
        let width = Int(ceil(rect.width))
        let height = Int(ceil(rect.height))
        let cacheKey = "\(width)x\(height)@\(Int(round(clampedRadius * 2)))" as NSString

        let baseMask: CIImage
        if let cached = cache.object(forKey: cacheKey) {
            baseMask = cached
        } else {
            let safeWidth = max(width, 1)
            let safeHeight = max(height, 1)
            let path: CGPath
            if clampedRadius >= min(rect.width, rect.height) / 2 && abs(rect.width - rect.height) < 0.5 {
                path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
            } else {
                path = RoundedRectangle(cornerRadius: clampedRadius, style: .continuous)
                    .path(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                    .cgPath
            }

            if let image = surfaceBackedMask(
                width: safeWidth,
                height: safeHeight,
                path: path
            ) {
                cache.setObject(
                    image,
                    forKey: cacheKey,
                    cost: safeWidth * safeHeight * 4
                )
                baseMask = image
            } else {
                baseMask = fallbackMask(width: rect.width, height: rect.height, radius: clampedRadius)
            }
        }

        return baseMask.transformed(
            by: CGAffineTransform(translationX: rect.minX, y: rect.minY)
        )
    }

    /// A cached `CIImage(cgImage:)` is still uploaded with `replaceRegion` on
    /// every separate Core Image render. Drawing the same vector mask once into
    /// an IOSurface-backed pixel buffer lets preview/export import it directly
    /// into Metal while preserving the continuous-corner geometry.
    private nonisolated static func surfaceBackedMask(
        width: Int,
        height: Int,
        path: CGPath
    ) -> CIImage? {
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.addPath(path)
        context.fillPath()
        return CIImage(
            cvPixelBuffer: pixelBuffer,
            options: [.colorSpace: colorSpace]
        )
    }

    private nonisolated static func fallbackMask(
        width: CGFloat,
        height: CGFloat,
        radius: CGFloat
    ) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        return CIFilter(
            name: "CIRoundedRectangleGenerator",
            parameters: [
                "inputExtent": CIVector(cgRect: extent),
                "inputRadius": radius,
            ]
        )?.outputImage ?? CIImage(color: .white).cropped(to: extent)
    }

}

/// `NSCache` explicitly serializes its own storage operations. This wrapper is
/// the narrow concurrency boundary used by preview and export render queues;
/// cached `CIImage` values are immutable render recipes.
private final class ContinuousCornerMaskCache: @unchecked Sendable {
    private let storage: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        // Two large stable screen masks plus smaller border/control masks fit;
        // a zoom transition that produces many nearby dimensions cannot retain
        // an unbounded sequence of full-canvas IOSurfaces.
        cache.countLimit = 48
        cache.totalCostLimit = 192 * 1_024 * 1_024
        return cache
    }()

    func object(forKey key: NSString) -> CIImage? {
        storage.object(forKey: key)
    }

    func setObject(_ image: CIImage, forKey key: NSString, cost: Int) {
        storage.setObject(image, forKey: key, cost: max(cost, 1))
    }

    func removeAllObjects() {
        storage.removeAllObjects()
    }
}
