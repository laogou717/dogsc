import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

/// Generates smooth, Apple-standard continuous corner rounded masks (squircles)
/// with G2 curvature continuity matching macOS/iOS system UI.
enum ContinuousCornerMask {
    private static let cache = NSCache<NSString, CIImage>()

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
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let safeWidth = max(width, 1)
            let safeHeight = max(height, 1)
            if let context = CGContext(
                data: nil,
                width: safeWidth,
                height: safeHeight,
                bitsPerComponent: 8,
                bytesPerRow: safeWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.clear(CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight))
                context.setAllowsAntialiasing(true)
                context.setShouldAntialias(true)
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)

                let path: CGPath
                if clampedRadius >= min(rect.width, rect.height) / 2 && abs(rect.width - rect.height) < 0.5 {
                    path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
                } else {
                    path = RoundedRectangle(cornerRadius: clampedRadius, style: .continuous)
                        .path(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                        .cgPath
                }
                context.addPath(path)
                context.fillPath()

                if let cgImage = context.makeImage() {
                    let image = CIImage(cgImage: cgImage)
                    cache.setObject(image, forKey: cacheKey)
                    baseMask = image
                } else {
                    baseMask = fallbackMask(width: rect.width, height: rect.height, radius: clampedRadius)
                }
            } else {
                baseMask = fallbackMask(width: rect.width, height: rect.height, radius: clampedRadius)
            }
        }

        return baseMask.transformed(
            by: CGAffineTransform(translationX: rect.minX, y: rect.minY)
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
