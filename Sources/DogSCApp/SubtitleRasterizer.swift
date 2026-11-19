import AppKit
import CoreImage
import CoreText
import RecorderCore

/// Core Text subtitle raster shared by preview and export (EDT-054). The
/// box is cached by content and size; the entrance/exit is applied as a
/// transform per frame, so animation costs no re-raster (except typing).
enum SubtitleRasterizer {
    private final class Cache: @unchecked Sendable {
        let storage: NSCache<NSString, CIImage> = {
            let cache = NSCache<NSString, CIImage>()
            cache.countLimit = 96
            return cache
        }()
    }
    private static let cache = Cache()
    static let entranceDuration: TimeInterval = 0.28

    private static func font(_ style: SubtitleStyle, size: CGFloat) -> NSFont {
        if let family = style.fontFamily,
           let named = NSFontManager.shared.font(withFamily: family, traits: style.bold ? .boldFontMask : [],
                                                 weight: style.bold ? 9 : 5, size: size) {
            return named
        }
        let weight: NSFont.Weight = style.bold ? .semibold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign = switch style.font {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// The unanimated box at its resting place (Core Image coordinates).
    /// Each language is exactly one line: a line too long for the frame is
    /// set smaller instead of wrapping into a tall block.
    private static func box(for subtitle: FrameSubtitleScene, visibleCharacters: Int?, canvasRect: CGRect) -> CIImage? {
        let style = subtitle.style
        let key = "\(subtitle.text)|\(subtitle.secondaryText ?? "")|\(style)|\(canvasRect.size)|\(visibleCharacters ?? -1)" as NSString
        if let cached = cache.storage.object(forKey: key) { return cached }
        let baseSize = max(canvasRect.height * CGFloat(style.fontScale), 8)
        let c = style.textColor.components
        let color = CGColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        let maxWidth = canvasRect.width * 0.9

        func line(_ text: String, size: CGFloat, hiddenFrom: Int?) -> CTLine {
            let string = NSMutableAttributedString(string: text, attributes: [
                .font: font(style, size: size),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            if let hiddenFrom, hiddenFrom < string.length {
                string.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: clear,
                                    range: NSRange(location: hiddenFrom, length: string.length - hiddenFrom))
            }
            return CTLineCreateWithAttributedString(string)
        }
        func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

        let hiddenFrom = visibleCharacters.map { String(Array(subtitle.text).prefix($0)).utf16.count }
        let secondaryText = subtitle.secondaryText.flatMap { $0.isEmpty ? nil : $0 }
        var primarySize = baseSize, secondarySize = baseSize * 0.72
        var primary = line(subtitle.text, size: primarySize, hiddenFrom: hiddenFrom)
        var secondary = secondaryText.map { line($0, size: secondarySize, hiddenFrom: nil) }
        if width(primary) > maxWidth {
            primarySize *= maxWidth / width(primary)
            primary = line(subtitle.text, size: primarySize, hiddenFrom: hiddenFrom)
        }
        if let current = secondary, width(current) > maxWidth, let secondaryText {
            secondarySize *= maxWidth / width(current)
            secondary = line(secondaryText, size: secondarySize, hiddenFrom: nil)
        }

        let padding = baseSize * 0.45
        let primaryHeight = primarySize * 1.25, secondaryHeight = secondary == nil ? 0 : secondarySize * 1.3
        let gap = secondary == nil ? 0 : baseSize * 0.12
        let contentWidth = max(width(primary), secondary.map(width) ?? 0)
        let boxSize = CGSize(width: ceil(contentWidth + padding * 2),
                             height: ceil(primaryHeight + gap + secondaryHeight + padding * 1.1))
        guard boxSize.width > 1, boxSize.height > 1,
              let context = CGContext(
                data: nil, width: Int(boxSize.width), height: Int(boxSize.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if style.backgroundOpacity > 0.001 {
            context.setFillColor(CGColor(gray: 0, alpha: CGFloat(style.backgroundOpacity)))
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: boxSize),
                                   cornerWidth: baseSize * 0.3, cornerHeight: baseSize * 0.3, transform: nil))
            context.fillPath()
        }
        // Core Graphics draws from the bottom: secondary line first.
        var baseline = padding * 0.55 + secondarySize * 0.32
        if let secondary {
            context.textPosition = CGPoint(x: (boxSize.width - width(secondary)) / 2, y: baseline)
            CTLineDraw(secondary, context)
            baseline += secondaryHeight + gap
        }
        context.textPosition = CGPoint(x: (boxSize.width - width(primary)) / 2,
                                       y: secondary == nil ? (boxSize.height - primarySize * 0.72) / 2 : baseline + primarySize * 0.08)
        CTLineDraw(primary, context)
        guard let cgImage = context.makeImage() else { return nil }
        let x = canvasRect.midX - boxSize.width / 2
        let y = canvasRect.minY + canvasRect.height * CGFloat(style.bottomMargin)
        let image = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: x, y: y))
        cache.storage.setObject(image, forKey: key)
        return image
    }

    static func image(for subtitle: FrameSubtitleScene, canvasRect: CGRect) -> CIImage? {
        let style = subtitle.style
        let duration = entranceDuration
        let enter = min(subtitle.elapsed / duration, 1)
        let exit = min(subtitle.remaining / duration, 1)
        let eased = 1 - pow(1 - min(enter, exit), 3)
        var visible: Int?
        if style.entrance == .typewriter {
            let count = subtitle.text.count
            let typing = min(subtitle.elapsed / max(min(Double(count) * 0.045, 1.2), 0.01), 1)
            visible = typing < 1 ? Int(Double(count) * typing) : nil
        }
        guard let base = box(for: subtitle, visibleCharacters: visible, canvasRect: canvasRect) else { return nil }
        guard style.entrance != .none, style.entrance != .typewriter || exit < 1 else { return base }
        let opacity = style.entrance == .typewriter ? exit : eased
        var image = base
        let center = CGPoint(x: base.extent.midX, y: base.extent.midY)
        switch style.entrance {
        case .rise:
            image = image.transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(1 - eased) * base.extent.height * 0.35))
        case .pop:
            let scale = 0.86 + 0.14 * CGFloat(eased)
            image = image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        default: break
        }
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
    }

    /// The resting box in top-left canvas points, for canvas hit-testing.
    static func boxRect(for subtitle: FrameSubtitleScene, canvasSize: CGSize) -> CGRect? {
        let rect = CGRect(origin: .zero, size: canvasSize)
        guard let image = box(for: subtitle, visibleCharacters: nil, canvasRect: rect) else { return nil }
        let e = image.extent
        return CGRect(x: e.minX, y: canvasSize.height - e.maxY, width: e.width, height: e.height)
    }
}
