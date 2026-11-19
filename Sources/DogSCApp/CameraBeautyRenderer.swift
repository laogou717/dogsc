import CoreImage
import CoreGraphics
import ImageIO
import RecorderCore
import Vision

/// The same image operation is used by live preview, the editor and export.
/// Each playback/capture stream owns its tracking state; still images use frame-local detection.
enum CameraBeautyRenderer {
    struct FaceRegion {
        var bounds: CGRect
        var protectedRegions: [CGRect] = []
        var opacity: Double = 1
    }

    private final class FaceMasks: @unchecked Sendable {
        final class Entry {
            let image: CIImage?
            init(_ image: CIImage?) { self.image = image }
        }
        let cache = NSCache<CIImage, Entry>()
        let context = CIContext(options: [.cacheIntermediates: false])

        init() { cache.countLimit = 3 }

        func mask(for source: CIImage) -> CIImage? {
            if let entry = cache.object(forKey: source) { return entry.image }
            let extent = source.extent
            let regions = detectFaces(in: analysisImage(source), context: context)
            let mask = faceMask(extent: extent, regions: regions)
            cache.setObject(Entry(mask), forKey: source)
            return mask
        }
    }

    static func analysisImage(_ source: CIImage) -> CIImage {
        let extent = source.extent
        let size = analysisSize(for: extent)
        return source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
    }

    static func detectFaces(in thumbnail: CIImage, context: CIContext) -> [FaceRegion] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: thumbnail, orientation: .up, options: [.ciContext: context])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).map { face in
            let features = [face.landmarks?.leftEye, face.landmarks?.rightEye,
                            face.landmarks?.leftEyebrow, face.landmarks?.rightEyebrow,
                            face.landmarks?.outerLips]
            return FaceRegion(bounds: face.boundingBox, protectedRegions: features.map { region in
                guard let points = region?.normalizedPoints, !points.isEmpty else { return .null }
                let xs = points.map(\.x), ys = points.map(\.y)
                let box = face.boundingBox
                return CGRect(x: box.minX + (xs.min() ?? 0) * box.width,
                              y: box.minY + (ys.min() ?? 0) * box.height,
                              width: ((xs.max() ?? 0) - (xs.min() ?? 0)) * box.width,
                              height: ((ys.max() ?? 0) - (ys.min() ?? 0)) * box.height)
                    .insetBy(dx: -box.width * 0.035, dy: -box.height * 0.025)
            })
        }
    }

    private static let masks = FaceMasks()

    static func apply(to source: CIImage, settings: CameraBeautySettings, tracking: CameraBeautyFrame? = nil) -> CIImage {
        if let tracking {
            guard settings.isEnabled, valid(source.extent) else { return source }
            return apply(to: source, settings: settings, regions: tracking.tracker.regions(for: source, frame: tracking))
        }
        guard settings.isEnabled, valid(source.extent), let mask = masks.mask(for: source) else { return source }
        return apply(to: source, settings: settings, faceMask: mask)
    }

    /// Explicit regions also let regression tests exercise skin/feature masking
    /// independently of the OS face model's recognition of a test picture.
    static func apply(to source: CIImage, settings: CameraBeautySettings, regions: [FaceRegion]) -> CIImage {
        guard settings.isEnabled, valid(source.extent),
              let mask = faceMask(extent: source.extent, regions: regions) else { return source }
        return apply(to: source, settings: settings, faceMask: mask)
    }

    private static func apply(to source: CIImage, settings: CameraBeautySettings, faceMask: CIImage) -> CIImage {
        let extent = source.extent
        // The face boundary excludes the room; this soft colour mask further
        // protects hair, clothing and highlights within that boundary.
        let skin = source.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 32, "inputCubeData": skinCube
        ])
        let mask = faceMask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: skin
        ]).cropped(to: extent)
        var adjusted = source
        if settings.smoothing > 0 {
            let smooth = source.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.025 + settings.smoothing * 0.075,
                "inputSharpness": 0.3
            ]).cropped(to: extent)
            adjusted = source.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: smooth, kCIInputTimeKey: settings.smoothing * 0.85
            ])
        }
        if settings.whitening > 0 {
            let w = settings.whitening
            adjusted = adjusted.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + 0.075 * w),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.10 * w),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.055 * w),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
    }

    private static func valid(_ extent: CGRect) -> Bool {
        !extent.isNull && !extent.isInfinite && extent.width > 1 && extent.height > 1
    }

    private static func analysisSize(for extent: CGRect) -> CGSize {
        let scale = min(1, 320 / max(extent.width, extent.height))
        return CGSize(width: max(2, (extent.width * scale).rounded()),
                      height: max(2, (extent.height * scale).rounded()))
    }

    private static func faceMask(extent: CGRect, regions: [FaceRegion]) -> CIImage? {
        guard !regions.isEmpty else { return nil }
        let size = analysisSize(for: extent)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                   width: rect.width * size.width, height: rect.height * size.height)
        }
        for region in regions {
            context.setFillColor(gray: min(max(region.opacity, 0), 1), alpha: 1)
            let face = pixels(region.bounds)
            context.fillEllipse(in: face.insetBy(dx: face.width * 0.04, dy: 0))
            context.setFillColor(gray: 0, alpha: 1)
            for feature in region.protectedRegions where !feature.isNull { context.fillEllipse(in: pixels(feature)) }
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(size.width, size.height) * 0.006])
            .cropped(to: CGRect(origin: .zero, size: size))
            .transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private static let skinCube: Data = {
        let dimension = 32
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        func display(_ linear: Double) -> Double {
            linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        }
        func ramp(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
            let t = min(max((x - lo) / (hi - lo), 0), 1)
            return t * t * (3 - 2 * t)
        }
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let red = display(Double(r) / 31), green = display(Double(g) / 31), blue = display(Double(b) / 31)
            let cb = 0.5 - 0.168736 * red - 0.331264 * green + 0.5 * blue
            let cr = 0.5 + 0.5 * red - 0.418688 * green - 0.081312 * blue
            let weight = Float(ramp(0.25, 0.32, cb) * (1 - ramp(0.53, 0.60, cb))
                * ramp(0.50, 0.55, cr) * (1 - ramp(0.78, 0.86, cr)))
            values.append(contentsOf: [weight, weight, weight, 1])
        } } }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}
