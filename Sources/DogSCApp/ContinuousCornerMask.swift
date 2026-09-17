import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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
        // Fractional edges and radii affect coverage even when the backing
        // dimensions match. Never reuse a neighbouring animation frame's mask.
        let cacheKey = "\(rect.width)x\(rect.height)@\(clampedRadius)" as NSString

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

            // Only the four corners contain changing coverage. A full 5K
            // coverage buffer on every zoom tick spends the CPU frame budget
            // painting an otherwise solid rectangle. Rasterize the SAME path
            // into a compact nine-part atlas, keeping pixel-aligned edge samples.
            // Circles/capsules and large overlapping corners keep the full path.
            let cap = Int(ceil(clampedRadius * 2 + 2))
            let usesAtlas = safeWidth > cap * 2 + 2 && safeHeight > cap * 2 + 2
            if let raster = surfaceBackedMask(
                width: safeWidth, height: safeHeight, path: path,
                cornerCap: usesAtlas ? cap : nil
            ) {
                cache.setObject(raster.image, forKey: cacheKey, cost: raster.cost)
                baseMask = raster.image
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
    /// an IOSurface-backed coverage buffer lets preview/export import it
    /// directly into Metal. One byte of coverage replaces four identical BGRA
    /// channels, without reducing resolution or changing the corner path.
    private nonisolated static func surfaceBackedMask(
        width: Int,
        height: Int,
        path: CGPath,
        cornerCap: Int? = nil
    ) -> (image: CIImage, cost: Int)? {
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ] as CFDictionary
        // Two straight pixels between the caps give the GPU a constant band
        // to stretch. Allocate ONLY this atlas, not a second full-size buffer.
        let drawingWidth = cornerCap.map { $0 * 2 + 2 } ?? width
        let drawingHeight = cornerCap.map { $0 * 2 + 2 } ?? height
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            drawingWidth,
            drawingHeight,
            kCVPixelFormatType_OneComponent8,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: baseAddress,
                  width: drawingWidth,
                  height: drawingHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: drawingWidth, height: drawingHeight))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(gray: 1, alpha: 1)
        if let cap = cornerCap {
            // Sample all nine regions from the original path. Each translation
            // is an integer, including the upper/right fractional coverage.
            // The central row/column sample the straight part of that path;
            // corners are never rescaled or rebuilt as a smaller rounded rect.
            let origins = [0, cap, cap + 2]
            let lengths = [cap, 2, cap]
            for x in 0..<3 {
                for y in 0..<3 {
                    context.saveGState()
                    context.clip(to: CGRect(x: origins[x], y: origins[y],
                                            width: lengths[x], height: lengths[y]))
                    context.translateBy(x: x == 2 ? CGFloat(drawingWidth - width) : 0,
                                        y: y == 2 ? CGFloat(drawingHeight - height) : 0)
                    context.addPath(path)
                    context.fillPath()
                    context.restoreGState()
                }
            }
        } else {
            context.addPath(path)
            context.fillPath()
        }
        // Coverage is linear data, not a gray photograph. Restore white RGB
        // plus coverage alpha so mask unions, source-out rings and shadows
        // have exactly the same semantics as the former premultiplied BGRA.
        let coverage = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()])
        let expanded: CIImage
        if let cap = cornerCap {
            // Apple's single nine-part filter retains both caps and only grows
            // the constant straight bands. A single sampling map also avoids
            // the seams introduced by compositing nine separately cropped images.
            let stretch = CIFilter.ninePartStretched()
            stretch.inputImage = coverage
            stretch.breakpoint0 = CGPoint(x: cap, y: cap)
            stretch.breakpoint1 = CGPoint(x: cap + 2, y: cap + 2)
            stretch.growAmount = CGPoint(x: width - drawingWidth, y: height - drawingHeight)
            guard let output = stretch.outputImage,
                  !output.extent.isInfinite, !output.extent.isNull,
                  abs(output.extent.width - CGFloat(width)) < 0.001,
                  abs(output.extent.height - CGFloat(height)) < 0.001 else {
                // Unexpected filter geometry keeps the original vector path,
                // rather than cropping a wrong mask or approximating its corners.
                return surfaceBackedMask(width: width, height: height, path: path)
            }
            expanded = output.transformed(by: CGAffineTransform(
                translationX: -output.extent.minX, y: -output.extent.minY
            )).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            expanded = coverage
        }
        return (expanded.applyingFilter("CIMaskToAlpha"), CVPixelBufferGetDataSize(pixelBuffer))
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
        // Charge only owned IOSurface bytes, including row alignment: compact
        // atlases for separated corners, full A8 buffers for circles/capsules.
        // CI owns transient GPU expansion; do not enable cross-frame intermediates.
        cache.countLimit = 48
        cache.totalCostLimit = 64 * 1_024 * 1_024
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
