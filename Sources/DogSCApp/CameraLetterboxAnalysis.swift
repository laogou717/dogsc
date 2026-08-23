import AVFoundation
import CoreImage
import Foundation
import RecorderCore

private struct CameraLetterboxMediaVersion: Hashable, Sendable {
    let path: String
    let fileSystemNumber: UInt64?
    let fileNumber: UInt64?
    let fileSize: UInt64?
    let modificationDate: Date?

    init(url: URL) {
        path = url.standardizedFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        fileSystemNumber = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        fileSize = (attributes?[.size] as? NSNumber)?.uint64Value
        modificationDate = attributes?[.modificationDate] as? Date
    }
}

/// Sync-point edits only change the camera clock; they do not change camera
/// pixels. Share the initial three-frame black-bar analysis across every media
/// composition generation, including callers that arrive while it is still in
/// flight. Keeping the completed Task also caches a legitimate nil result.
private actor CameraLetterboxAnalysisCache {
    private var tasks: [CameraLetterboxMediaVersion: Task<NormalizedCrop?, Never>] = [:]
    private var order: [CameraLetterboxMediaVersion] = []

    func value(for url: URL) async -> NormalizedCrop? {
        let version = CameraLetterboxMediaVersion(url: url)
        if let task = tasks[version] {
            return await task.value
        }

        let task = Task.detached(priority: .userInitiated) {
            await CameraLetterboxAnalysis.analyzeUncached(for: url)
        }
        tasks[version] = task
        order.append(version)
        if order.count > 8 {
            let expired = order.removeFirst()
            tasks.removeValue(forKey: expired)
        }
        return await task.value
    }
}

/// 摄像头素材的黑边检测与裁剪。竖屏模式的运动相机/手机会把横向感光画面
/// 装进带上下黑边的竖向画框（或反之），直接进 PIP 后近乎全黑。这里按内容
/// 亮度估计真实画面包围盒，预览与导出共用同一份检测结果把黑边裁掉。
enum CameraLetterboxAnalysis {
    private static let cache = CameraLetterboxAnalysisCache()

    /// 按时间轴均匀采样若干帧，从多帧中选择重复出现的稳定内容区。
    /// 不能取简单并集：一帧亮绿色错帧就会把全片裁切区扩张到损坏区。
    /// 没有可信黑边时返回 nil，调用方按原样使用素材。
    static func normalizedContentCrop(for url: URL) async -> NormalizedCrop? {
        await cache.value(for: url)
    }

    fileprivate static func analyzeUncached(for url: URL) async -> NormalizedCrop? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.2 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 黑边检测只在打开项目时做一次。原先把 1080x1920 母片
        // 压到 90x160，一个检测格就代表约 12 个源像素，边界插值
        // 足以在 PIP 底部留下整条黑缝。用 640 长边保留边界精度，
        // 仍远低于原片解码/预览成本。
        generator.maximumSize = CGSize(width: 640, height: 640)
        // This is spatial content detection, not frame-accurate editing. Exact
        // seeks force a long-GOP camera file to decode forward from a keyframe
        // for every one of the nine samples. A nearby frame carries the same
        // letterbox geometry while allowing AVFoundation to choose an already
        // accessible sample and substantially reducing first-open latency.
        let samplingTolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = samplingTolerance
        generator.requestedTimeToleranceAfter = samplingTolerance

        var candidates: [NormalizedCrop] = []
        for fraction in stride(from: 0.1, through: 0.9, by: 0.1) {
            guard !Task.isCancelled else {
                generator.cancelAllCGImageGeneration()
                return nil
            }
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time),
                  let bounds = contentBounds(in: image) else { continue }
            candidates.append(bounds)
        }
        return stableCrop(from: candidates)
    }

    /// 纯逻辑：从单张位图估计内容包围盒（归一化、左上角原点）。
    /// 行/列平均亮度超过阈值即视为内容；只有黑边至少占某一维 3%、且内容
    /// 保留至少 20% 时才认为存在黑边，避免误裁暗场素材。
    static func contentBounds(in image: CGImage) -> NormalizedCrop? {
        guard image.width > 0, image.height > 0 else { return nil }
        let gridWidth = min(image.width, 360)
        let gridHeight = max(
            Int((Double(image.height) / Double(image.width) * Double(gridWidth)).rounded()),
            1
        )
        guard let context = CGContext(
            data: nil,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: gridWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: gridWidth * gridHeight * 4)

        var rowLuma = [Double](repeating: 0, count: gridHeight)
        var colLuma = [Double](repeating: 0, count: gridWidth)
        var rowDetail = [Double](repeating: 0, count: gridHeight)
        for y in 0..<gridHeight {
            var previousLuma: Double?
            for x in 0..<gridWidth {
                let offset = (y * gridWidth + x) * 4
                let luma = 0.2126 * Double(pixels[offset])
                    + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])
                rowLuma[y] += luma
                colLuma[x] += luma
                if let previousLuma {
                    rowDetail[y] += abs(luma - previousLuma)
                }
                previousLuma = luma
            }
        }
        for y in 0..<gridHeight {
            rowLuma[y] /= Double(gridWidth)
            rowDetail[y] /= Double(max(gridWidth - 1, 1))
        }
        for x in 0..<gridWidth { colLuma[x] /= Double(gridHeight) }

        // A portrait container can carry a real landscape camera band plus
        // black/grey padding. Bright padding and green corruption are not
        // camera content. Prefer the textured band crossing the frame centre;
        // keep the older luminance detector as a fallback for synthetic/flat
        // content and pillarboxing.
        if gridHeight > gridWidth,
           let band = centralDetailedBand(rowDetail) {
            let bars = band.first + (gridHeight - 1 - band.last)
            let contentHeight = band.last - band.first + 1
            if contentHeight >= Int(ceil(Double(gridHeight) * 0.2)),
               contentHeight <= Int(floor(Double(gridHeight) * 0.8)),
               Double(bars) >= Double(gridHeight) * 0.03 {
                let vertical = conservativeBounds(band, count: gridHeight)
                return NormalizedCrop(
                    x: 0,
                    y: vertical.start,
                    width: 1,
                    height: vertical.end - vertical.start
                ).clamped()
            }
        }

        let threshold = 8.0
        func contentRange(_ luma: [Double]) -> (first: Int, last: Int)? {
            guard let first = luma.firstIndex(where: { $0 > threshold }),
                  let last = luma.lastIndex(where: { $0 > threshold }) else { return nil }
            return (first, last)
        }
        // 行/列均值会互相稀释：竖向黑边（内容带矮）把每一列的均值拉低，横向
        // 黑边（内容柱窄）把每一行的均值拉低。任一轴检出内容即可，未检出的
        // 轴视为满幅；两轴都失败才是真的没有内容。
        let rows = contentRange(rowLuma)
        let cols = contentRange(colLuma)
        guard rows != nil || cols != nil else { return nil }
        let rowRange = rows ?? (first: 0, last: gridHeight - 1)
        let colRange = cols ?? (first: 0, last: gridWidth - 1)
        let contentWidth = colRange.last - colRange.first + 1
        let contentHeight = rowRange.last - rowRange.first + 1
        let horizontalBars = colRange.first + (gridWidth - 1 - colRange.last)
        let verticalBars = rowRange.first + (gridHeight - 1 - rowRange.last)
        guard contentWidth >= Int(ceil(Double(gridWidth) * 0.2)),
              contentHeight >= Int(ceil(Double(gridHeight) * 0.2)),
              Double(horizontalBars) >= Double(gridWidth) * 0.03
                || Double(verticalBars) >= Double(gridHeight) * 0.03
        else { return nil }
        // 下采样后，检出的第一/最后一行仍可能是黑边与内容的
        // 插值混合行。对确认存在黑边的一侧内收一个高精度取样格；
        // 满幅边仍保留到 0/1。这里宁可少不到 3 个源像素，
        // 也不能让解码缩放把混合行拉成可见黑缝。
        func conservativeBounds(
            _ range: (first: Int, last: Int),
            count: Int
        ) -> (start: Double, end: Double) {
            let start = range.first == 0
                ? 0
                : (Double(range.first) + 1) / Double(count)
            let end = range.last == count - 1
                ? 1
                : Double(range.last) / Double(count)
            return (start, end)
        }
        let horizontal = conservativeBounds(colRange, count: gridWidth)
        let vertical = conservativeBounds(rowRange, count: gridHeight)
        return NormalizedCrop(
            x: horizontal.start,
            y: vertical.start,
            width: horizontal.end - horizontal.start,
            height: vertical.end - vertical.start
        ).clamped()
    }

    /// Finds a continuous textured horizontal band near the centre. Short
    /// low-detail gaps inside a face/background are bridged; large uniform
    /// black/grey padding remains outside. A fully corrupted textured frame
    /// produces a near-full band and is rejected by the caller.
    private static func centralDetailedBand(
        _ rowDetail: [Double]
    ) -> (first: Int, last: Int)? {
        guard rowDetail.count >= 8 else { return nil }
        let radius = 2
        let smoothed = rowDetail.indices.map { index in
            let lower = max(index - radius, 0)
            let upper = min(index + radius, rowDetail.count - 1)
            return rowDetail[lower...upper].reduce(0, +) / Double(upper - lower + 1)
        }
        let sorted = smoothed.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(2.2, median * 0.45)
        let active = smoothed.map { $0 >= threshold }
        let allowedGap = max(Int(Double(active.count) * 0.012), 2)

        var runs: [(first: Int, last: Int)] = []
        var start: Int?
        var lastActive: Int?
        for index in active.indices {
            guard active[index] else { continue }
            if let previous = lastActive,
               index - previous - 1 > allowedGap,
               let runStart = start {
                runs.append((runStart, previous))
                start = nil
            }
            if start == nil { start = index }
            lastActive = index
        }
        if let start, let lastActive { runs.append((start, lastActive)) }
        guard !runs.isEmpty else { return nil }

        let centre = Double(active.count - 1) / 2
        return runs
            .filter { $0.last - $0.first + 1 >= Int(Double(active.count) * 0.08) }
            .min { lhs, rhs in
                let lhsDistance = abs((Double(lhs.first + lhs.last) / 2) - centre)
                let rhsDistance = abs((Double(rhs.first + rhs.last) / 2) - centre)
                if abs(lhsDistance - rhsDistance) > 0.001 {
                    return lhsDistance < rhsDistance
                }
                return lhs.last - lhs.first > rhs.last - rhs.first
            }
    }

    /// Groups nearly identical crops and returns the median crop in the largest
    /// group. This keeps a single corrupt/dark frame from moving the whole
    /// project's camera framing.
    static func stableCrop(from candidates: [NormalizedCrop]) -> NormalizedCrop? {
        guard !candidates.isEmpty else { return nil }
        let tolerance = 0.065
        var best: [NormalizedCrop] = []
        for reference in candidates {
            let cluster = candidates.filter { candidate in
                abs(candidate.x - reference.x) <= tolerance
                    && abs(candidate.y - reference.y) <= tolerance
                    && abs(candidate.width - reference.width) <= tolerance
                    && abs(candidate.height - reference.height) <= tolerance
            }
            if cluster.count > best.count {
                best = cluster
            } else if cluster.count == best.count,
                      medianArea(cluster) < medianArea(best) {
                best = cluster
            }
        }
        guard !best.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return NormalizedCrop(
            x: median(best.map(\.x)),
            y: median(best.map(\.y)),
            width: median(best.map(\.width)),
            height: median(best.map(\.height))
        ).clamped()
    }

    private static func medianArea(_ crops: [NormalizedCrop]) -> Double {
        guard !crops.isEmpty else { return .infinity }
        let areas = crops.map { $0.width * $0.height }.sorted()
        return areas[areas.count / 2]
    }

    /// 预览与导出共用的像素级裁剪：按归一化内容区裁掉黑边并把原点归零，
    /// 保证下游用 extent 推导的几何（PIP 宽高比、aspect-fill）一致。
    static func cropped(_ image: CIImage, to crop: NormalizedCrop) -> CIImage {
        let rect = coreImageCropRect(sourceExtent: image.extent, crop: crop)
        return image
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// `NormalizedCrop` 约定左上角原点，Core Image 使用左下角原点。
    /// 非对称黑边若不翻转 y，会裁错一边，并在画中画顶部留缝。
    static func coreImageCropRect(
        sourceExtent: CGRect,
        crop: NormalizedCrop
    ) -> CGRect {
        CGRect(
            x: sourceExtent.minX + sourceExtent.width * crop.x,
            y: sourceExtent.minY + sourceExtent.height * (1 - crop.y - crop.height),
            width: sourceExtent.width * crop.width,
            height: sourceExtent.height * crop.height
        )
    }

    /// 检测后的显示尺寸：几何求值（PIP 宽高比）必须使用裁掉黑边后的尺寸。
    static func croppedDisplaySize(_ size: CGSize?, crop: NormalizedCrop?) -> CGSize? {
        guard let size, let crop else { return size }
        return CGSize(width: size.width * crop.width, height: size.height * crop.height)
    }
}
