import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Original image pixels shared by preview, snapshots and export. GIF timing
/// follows the source frame delays and the segment's source clock, including
/// trims and speed changes. Decoded frames have one bounded cache.
final class ImageMediaFrameCache: @unchecked Sendable {
    static let shared = ImageMediaFrameCache()

    struct Information: Sendable {
        let aspectRatio: Double
        let animationDuration: TimeInterval?
    }

    private final class Sequence: NSObject {
        /// Identifies the file's content, not this instance. Decoded frames
        /// outlive the sequence in their own cache: keying them on an instance
        /// UUID orphaned every frame of a file as soon as the sequence was
        /// evicted, while they went on holding the frame budget. It also makes
        /// a replaced file decode again instead of serving stale pixels.
        let fingerprint: String
        /// Re-stat at most twice a second; `frame(at:time:)` runs per display
        /// frame for every timed sticker on screen.
        var checkedAt: TimeInterval = .greatestFiniteMagnitude
        let source: CGImageSource
        let information: Information
        let ends: [TimeInterval]
        let orientation: Int32

        static func fingerprint(for url: URL) -> String {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(url.path)|\(modified)|\(values?.fileSize ?? 0)"
        }

        init?(url: URL) {
            fingerprint = Self.fingerprint(for: url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0 else { return nil }
            self.source = source
            orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            let aspect = width.doubleValue / height.doubleValue
            var ends: [TimeInterval] = []
            var duration: TimeInterval = 0
            if CGImageSourceGetType(source) as String? == UTType.gif.identifier,
               CGImageSourceGetCount(source) > 1 {
                for index in 0..<CGImageSourceGetCount(source) {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                        ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                    duration += delay.isFinite && delay > 0 ? max(delay, 0.01) : 0.1
                    ends.append(duration)
                }
            }
            self.ends = ends
            information = Information(aspectRatio: (5...8).contains(orientation) ? 1 / aspect : aspect,
                animationDuration: ends.isEmpty ? nil : duration)
        }

        func frameIndex(at time: TimeInterval) -> Int {
            guard let duration = information.animationDuration else { return 0 }
            let phase = (time.isFinite ? max(time, 0) : 0).truncatingRemainder(dividingBy: duration)
            var lower = 0, upper = ends.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if phase < ends[middle] { upper = middle } else { lower = middle + 1 }
            }
            return min(lower, ends.count - 1)
        }
    }

    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sequences: NSCache<NSURL, Sequence> = {
        let cache = NSCache<NSURL, Sequence>()
        cache.countLimit = 16
        return cache
    }()
    private let frames: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()

    private func sequence(for url: URL) -> Sequence? {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = sequences.object(forKey: url as NSURL) {
            guard now - cached.checkedAt > 0.5 else { return cached }
            if Sequence.fingerprint(for: url) == cached.fingerprint {
                cached.checkedAt = now
                return cached
            }
            sequences.removeObject(forKey: url as NSURL)
        }
        guard let sequence = Sequence(url: url) else { return nil }
        sequence.checkedAt = now
        sequences.setObject(sequence, forKey: url as NSURL)
        return sequence
    }

    /// Drops what was decoded from this file, for a caller that has just
    /// rewritten it and cannot wait for the next staleness check.
    func invalidate(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        sequences.removeObject(forKey: url as NSURL)
    }

    func information(at url: URL) -> Information? {
        lock.lock()
        defer { lock.unlock() }
        return sequence(for: url)?.information
    }

    func frame(at url: URL, time: TimeInterval) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let sequence = sequence(for: url) else { return nil }
        let index = sequence.frameIndex(at: time)
        let key = "\(sequence.fingerprint):\(index)" as NSString
        if let image = frames.object(forKey: key) { return image }
        guard let cg = CGImageSourceCreateImageAtIndex(sequence.source, index,
            [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cg).oriented(forExifOrientation: sequence.orientation)
        frames.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }

    func cgImage(at url: URL, time: TimeInterval) -> CGImage? {
        guard let image = frame(at: url, time: time) else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}
