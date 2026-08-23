import AppKit
import CoreImage
import Foundation
import RecorderCore

/// Vector artwork used when a style's system bitmap is too small for the
/// requested raster size. The HI services framework ships the exact cursor
/// artwork as a vector PDF plus a shadow spec — the same source the system
/// itself rasterizes for `NSCursor` — so redrawing it at any size reproduces
/// the native design crisply, while its footprint is mapped onto the system
/// bitmap's measured artwork box so the on-screen size never jumps.
struct CursorVectorSource {
    let pageImage: NSImage
    let pageWidthPoint: CGFloat
    let pageHeightPoint: CGFloat
    /// Normalized (0…1 of the reference raster) artwork alpha boxes.
    let pdfArtworkRect: CGRect
    let bitmapArtworkRect: CGRect
    let shadowColor: NSColor
    let shadowOffsetPoint: CGSize
    let shadowBlurPoint: CGFloat
    /// Largest pixel dimension of the system bitmap's best representation.
    let maxBitmapPixel: CGFloat

    var pageMaxPoint: CGFloat { max(pageWidthPoint, pageHeightPoint) }
}

struct ResolvedCursorAsset: Identifiable, @unchecked Sendable {
    let id: CursorAssetID
    let displayName: String
    let image: NSImage?
    let metrics: CursorAssetMetrics
    /// Present only for styles the system bitmap resolves at 1x/2x where the
    /// same design also ships as vector PDF (pointing hand, open/closed hand,
    /// crosshair).
    let vectorSource: CursorVectorSource?

    var isHidden: Bool { id == .hidden }

    /// 光标栅格渲染的默认超采样高度：覆盖至 8K 画布 × 6× 样式大小（约 1056px）
    /// 的导出与光栅预览，无需在合成器内放大。
    static let sourceRenderPixelHeight: CGFloat = 1_088

    /// Rasterize the cursor at an exact pixel size.
    ///
    /// - When the target fits the system bitmap's best representation the
    ///   bitmap is resampled directly (the exact native artwork, downscaled).
    /// - When the target exceeds it and a vector source exists, the PDF
    ///   artwork is drawn at the target size — crisp at any zoom.
    /// - Otherwise the bitmap is capped at its best representation so the
    ///   caller never receives a blurry upscale. Vector-backed images without
    ///   bitmap representations (SF symbol fallback) draw directly at any size.
    func rasterizedPixelImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, image != nil else { return nil }
        let targetMax = CGFloat(max(width, height))
        if let vectorSource, targetMax > vectorSource.maxBitmapPixel {
            return Self.rasterizedVector(
                vectorSource,
                width: width,
                height: height
            )
        }
        let nativeMax = image.flatMap(Self.maxBitmapPixel)
            ?? CGFloat.greatestFiniteMagnitude
        let capped = targetMax > nativeMax
            ? nativeMax / targetMax
            : 1
        let drawWidth = max(Int((CGFloat(width) * capped).rounded(.up)), 1)
        let drawHeight = max(Int((CGFloat(height) * capped).rounded(.up)), 1)
        return Self.rasterizedBitmap(image!, width: drawWidth, height: drawHeight)
    }

    func renderSource() -> CursorRenderSource? {
        guard image != nil else { return nil }
        let aspect = metrics.intrinsicSize.width
            / max(metrics.intrinsicSize.height, 1)
        let width = max(1, Self.sourceRenderPixelHeight * aspect)
        guard let cgImage = rasterizedPixelImage(
            width: Int(width.rounded(.up)),
            height: Int(Self.sourceRenderPixelHeight)
        ) else { return nil }
        return CursorRenderSource(image: CIImage(cgImage: cgImage), metrics: metrics)
    }

    private static func maxBitmapPixel(of image: NSImage) -> CGFloat? {
        var best: CGFloat?
        for rep in image.representations {
            guard let bitmap = rep as? NSBitmapImageRep else { continue }
            let pixels = CGFloat(max(bitmap.pixelsWide, bitmap.pixelsHigh))
            best = max(best ?? 0, pixels)
        }
        return best
    }

    private static func rasterizedBitmap(
        _ image: NSImage,
        width: Int,
        height: Int
    ) -> CGImage? {
        Self.renderBitmap(width: width, height: height) { _ in
            image.draw(
                in: NSRect(x: 0, y: 0, width: width, height: height),
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1
            )
        }?.cgImage
    }

    private static func rasterizedVector(
        _ source: CursorVectorSource,
        width: Int,
        height: Int
    ) -> CGImage? {
        let targetWidth = CGFloat(width)
        let targetHeight = CGFloat(height)
        let kx = targetWidth * source.bitmapArtworkRect.width
            / source.pdfArtworkRect.width
        let ky = targetHeight * source.bitmapArtworkRect.height
            / source.pdfArtworkRect.height
        let drawRect = CGRect(
            x: source.bitmapArtworkRect.minX * targetWidth
                - source.pdfArtworkRect.minX * kx,
            y: source.bitmapArtworkRect.minY * targetHeight
                - source.pdfArtworkRect.minY * ky,
            width: kx,
            height: ky
        )
        let artWidth = max(Int(ceil(drawRect.width)), 1)
        let artHeight = max(Int(ceil(drawRect.height)), 1)
        guard let artwork = Self.renderBitmap(
            width: artWidth,
            height: artHeight,
            { _ in
                source.pageImage.draw(
                    in: NSRect(
                        x: 0,
                        y: 0,
                        width: drawRect.width,
                        height: drawRect.height
                    ),
                    from: NSRect(origin: .zero, size: source.pageImage.size),
                    operation: .copy,
                    fraction: 1
                )
            }
        )?.cgImage else { return nil }
        let pxPerPoint = kx / max(source.pageMaxPoint, 1)
        return Self.renderBitmap(width: width, height: height) { cg in
            cg.setShadow(
                offset: CGSize(
                    width: source.shadowOffsetPoint.width * pxPerPoint,
                    height: -source.shadowOffsetPoint.height * pxPerPoint
                ),
                blur: source.shadowBlurPoint * pxPerPoint * 2,
                color: source.shadowColor.cgColor
            )
            cg.draw(artwork, in: drawRect)
        }?.cgImage
    }

    fileprivate static func renderBitmap(
        width: Int,
        height: Int,
        _ draw: (CGContext) -> Void
    ) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(width, 1),
            pixelsHigh: max(height, 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

struct CursorRenderSource: @unchecked Sendable {
    let image: CIImage
    let metrics: CursorAssetMetrics
}

/// 光标样式目录。自 2026-08-16 起，全部样式在运行时直接读取 macOS
/// 系统光标图像（NSCursor.image + hotSpot）：不打包任何图片，样式永远
/// 跟随用户当前系统的外观（包括系统大版本的光标 redesign）。旧项目里
/// 已删除的生成样式 ID 由 resolvedAsset(for:) 回落到系统箭头。
/// 2026-08-21：放大时的模糊根因是系统位图只有 1x/2x 表示；对系统仅提供
/// 低位图的手/十字准星样式，改用系统自身的矢量 PDF 渲染到目标像素尺寸。
enum CursorAssetLibrary {
    static var availableAssets: [ResolvedCursorAsset] {
        cachedAvailableAssets
    }

    static func resolvedAsset(for id: CursorAssetID) -> ResolvedCursorAsset? {
        let assets = availableAssets
        return assets.first(where: { $0.id == id })
            ?? assets.first(where: { $0.id == .systemArrow })
    }

    /// Playback can evaluate cursor overlays at 120 Hz. Resolve the immutable
    /// system images once instead of querying NSCursor on every frame.
    private static let cachedAvailableAssets: [ResolvedCursorAsset] = {
        [
            systemAsset(
                id: .systemArrow,
                displayName: "系统箭头",
                cursor: .arrow,
                fallbackSymbol: "cursorarrow",
                clickColor: HexColor(rgb24: 0x7C_5C_FC)
            ),
            systemAsset(
                id: .systemPointingHand,
                displayName: "指向手势",
                cursor: .pointingHand,
                fallbackSymbol: "hand.point.up.left.fill",
                clickColor: HexColor(rgb24: 0x7C_5C_FC),
                vectorDirectory: "pointinghand"
            ),
            systemAsset(
                id: .systemCrosshair,
                displayName: "十字准星",
                cursor: .crosshair,
                fallbackSymbol: "scope",
                clickColor: HexColor(rgb24: 0x54_B8_FF),
                vectorDirectory: "cross"
            ),
            systemAsset(
                id: .systemIBeam,
                displayName: "I 型光标",
                cursor: .iBeam,
                fallbackSymbol: "text.cursor",
                clickColor: HexColor(rgb24: 0x54_B8_FF)
            ),
            systemAsset(
                id: .systemOpenHand,
                displayName: "张开手",
                cursor: .openHand,
                fallbackSymbol: "hand.raised.fill",
                clickColor: HexColor(rgb24: 0x7C_5C_FC),
                vectorDirectory: "openhand"
            ),
            systemAsset(
                id: .systemClosedHand,
                displayName: "握拳手",
                cursor: .closedHand,
                fallbackSymbol: "hand.raised.fist",
                clickColor: HexColor(rgb24: 0x7C_5C_FC),
                vectorDirectory: "closedhand"
            ),
            systemAsset(
                id: .systemNotAllowed,
                displayName: "禁止",
                cursor: .operationNotAllowed,
                fallbackSymbol: "nosign",
                clickColor: HexColor(rgb24: 0xFF_64_64)
            ),
            ResolvedCursorAsset(
                id: .hidden,
                displayName: "隐藏",
                image: nil,
                metrics: CursorAssetMetrics(
                    hotspot: CursorAssetPoint(x: 0.5, y: 0.5),
                    intrinsicSize: CursorAssetSize(width: 1, height: 1),
                    clickColor: HexColor(rgb24: 0x7C_5C_FC)
                ),
                vectorSource: nil
            ),
        ]
    }()

    private static func systemAsset(
        id: CursorAssetID,
        displayName: String,
        cursor: NSCursor,
        fallbackSymbol: String,
        clickColor: HexColor,
        vectorDirectory: String? = nil
    ) -> ResolvedCursorAsset {
        let cursorImage = cursor.image
        let image = cursorImage.tiffRepresentation == nil
            ? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: displayName)
            : cursorImage
        let width = max(Double(image?.size.width ?? cursorImage.size.width), 1)
        let height = max(Double(image?.size.height ?? cursorImage.size.height), 1)
        return ResolvedCursorAsset(
            id: id,
            displayName: displayName,
            image: image,
            metrics: CursorAssetMetrics(
                hotspot: CursorAssetPoint(
                    x: min(max(Double(cursor.hotSpot.x) / width, 0), 1),
                    y: min(max(Double(cursor.hotSpot.y) / height, 0), 1)
                ),
                intrinsicSize: CursorAssetSize(width: width, height: height),
                clickColor: clickColor
            ),
            vectorSource: image.flatMap {
                vectorSource(
                    directory: vectorDirectory,
                    bitmap: $0,
                    pagePointSize: CursorAssetSize(width: width, height: height)
                )
            }
        )
    }

    /// HIServices 框架内随系统发布的光标矢量资源根目录（含各光标子目录的
    /// cursor.pdf + info.plist：热点与阴影规格）。存在性在进程内做一次探测。
    private static let systemCursorVectorBase: URL? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework"
            + "/Versions/A/Frameworks/HIServices.framework/Versions/A"
            + "/Resources/cursors"
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// Load and measure the vector artwork for a system bitmap-only style.
    /// Measurements (artwork alpha boxes, best bitmap representation) are the
    /// mapping used by `rasterizedPixelImage` to keep proportions and the
    /// hotspot grid identical to the system bitmap at every size.
    private static func vectorSource(
        directory: String?,
        bitmap: NSImage,
        pagePointSize: CursorAssetSize
    ) -> CursorVectorSource? {
        guard let directory,
              let base = systemCursorVectorBase,
              let pdfImage = NSImage(
                contentsOf: base
                    .appendingPathComponent(directory)
                    .appendingPathComponent("cursor.pdf")
              ),
              let bestBitmap = bestBitmapRepresentation(of: bitmap),
              let bitmapBox = alphaBoundingBox(of: bestBitmap),
              let shadowSpec = shadowSpec(
                at: base.appendingPathComponent(directory)
              )
        else { return nil }
        let referencePx = CGFloat(max(bestBitmap.pixelsWide, bestBitmap.pixelsHigh))
        guard referencePx > 0 else { return nil }
        let pageWidth = max(Double(pdfImage.size.width), 1)
        let pageHeight = max(Double(pdfImage.size.height), 1)
        let referenceSize = Int(referencePx.rounded())
        guard let pageRep = ResolvedCursorAsset.renderBitmap(
            width: referenceSize,
            height: referenceSize,
            { _ in
                pdfImage.draw(
                    in: NSRect(
                        x: 0,
                        y: 0,
                        width: referencePx,
                        height: referencePx
                    ),
                    from: NSRect(origin: .zero, size: pdfImage.size),
                    operation: .copy,
                    fraction: 1
                )
            }
        ), let pdfBox = alphaBoundingBox(of: pageRep) else { return nil }
        return CursorVectorSource(
            pageImage: pdfImage,
            pageWidthPoint: CGFloat(pageWidth),
            pageHeightPoint: CGFloat(pageHeight),
            pdfArtworkRect: CGRect(
                x: pdfBox.minX / referencePx,
                y: pdfBox.minY / referencePx,
                width: pdfBox.width / referencePx,
                height: pdfBox.height / referencePx
            ),
            bitmapArtworkRect: CGRect(
                x: bitmapBox.minX / referencePx,
                y: bitmapBox.minY / referencePx,
                width: bitmapBox.width / referencePx,
                height: bitmapBox.height / referencePx
            ),
            shadowColor: shadowSpec.color,
            shadowOffsetPoint: shadowSpec.offset,
            shadowBlurPoint: shadowSpec.blur,
            maxBitmapPixel: CGFloat(max(
                bestBitmap.pixelsWide,
                bestBitmap.pixelsHigh
            ))
        )
    }

    private struct ShadowSpec {
        let color: NSColor
        let offset: CGSize
        let blur: CGFloat
    }

    private static func shadowSpec(at directory: URL) -> ShadowSpec? {
        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent("info.plist")
        ),
        let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let channels = plist["shadowcolor"] as? [Double],
        channels.count == 4,
        let offsetX = plist["shadowoffsetx"] as? Double,
        let offsetY = plist["shadowoffsety"] as? Double,
        let blur = plist["blur"] as? Double
        else { return nil }
        return ShadowSpec(
            color: NSColor(
                red: channels[0],
                green: channels[1],
                blue: channels[2],
                alpha: channels[3]
            ),
            offset: CGSize(width: offsetX, height: offsetY),
            blur: CGFloat(blur)
        )
    }

    private static func bestBitmapRepresentation(
        of image: NSImage
    ) -> NSBitmapImageRep? {
        var best: NSBitmapImageRep?
        var bestPixels = 0
        for rep in image.representations {
            guard let bitmap = rep as? NSBitmapImageRep else { continue }
            let pixels = max(bitmap.pixelsWide, bitmap.pixelsHigh)
            if pixels > bestPixels {
                best = bitmap
                bestPixels = pixels
            }
        }
        return best
    }

    /// Alpha bounding box of a bitmap, used to align the vector artwork with
    /// the system bitmap's own footprint (both include the soft shadow).
    private static func alphaBoundingBox(
        of rep: NSBitmapImageRep,
        minimumAlpha: UInt8 = 8
    ) -> CGRect? {
        guard let data = rep.bitmapData, rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return nil }
        var minX = rep.pixelsWide
        var minY = rep.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<rep.pixelsHigh {
            var offset = y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                if data[offset + 3] > minimumAlpha {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                offset += 4
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: Double(minX),
            y: Double(minY),
            width: Double(maxX - minX + 1),
            height: Double(maxY - minY + 1)
        )
    }
}

/// Coordinate adapter shared by both renderers. The preview already uses a
/// top-left origin; export supplies a Core Image bottom-left pointer and is
/// converted before evaluating the exact same RecorderCore geometry.
enum CursorRenderContract {
    static func previewLayout(
        pointer: CompositionPoint,
        canvasSize: CursorAssetSize,
        style: CursorStyle,
        metrics: CursorAssetMetrics
    ) -> CursorRenderLayout? {
        CursorRenderGeometry.layout(
            pointer: pointer,
            canvasShortEdge: min(canvasSize.width, canvasSize.height),
            styleSize: style.size,
            metrics: metrics
        )
    }

    static func exportLayout(
        coreImagePointer: CompositionPoint,
        canvasSize: CursorAssetSize,
        style: CursorStyle,
        metrics: CursorAssetMetrics
    ) -> CursorRenderLayout? {
        previewLayout(
            pointer: CompositionPoint(
                x: coreImagePointer.x,
                y: canvasSize.height - coreImagePointer.y
            ),
            canvasSize: canvasSize,
            style: style,
            metrics: metrics
        )
    }
}
