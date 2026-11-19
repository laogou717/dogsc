import AppKit
import CoreImage
import CoreText
import RecorderCore

private final class ScreenChromeRasterCache: @unchecked Sendable {
    private let storage: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    func image(for key: NSString, create: () -> CIImage?) -> CIImage? {
        if let cached = storage.object(forKey: key) { return cached }
        guard let created = create() else { return nil }
        storage.setObject(
            created,
            forKey: key,
            cost: max(Int(created.extent.width * created.extent.height * 4), 1)
        )
        return created
    }
}

/// Original vector mockup chrome drawn with Core Image and Core Graphics only.
/// `background` sits under the recorded pixels; `foreground` (the phone's
/// island and the desktop window's hairline edge) sits above them. Both are
/// clipped to the outer card and travel through the screen's projection.
enum SharedFrameChromeRenderer {
    private static let rasterCache = ScreenChromeRasterCache()

    private struct Geometry {
        let extent: CGRect
        let outer: CGRect
        let toolbar: CGRect
        let content: CGRect
        let outerRadius: CGFloat
        let contentRadius: CGFloat
    }

    private enum Glyph: String {
        case chevronLeft, chevronRight, sidebar, lock, plus, tabs
    }

    nonisolated static func background(
        _ chrome: FrameScreenChromeScene,
        canvasRect: CGRect,
        renderExtent: CGRect,
        coordinateTransform: CGAffineTransform = .identity
    ) -> CIImage {
        let geometry = geometry(chrome, canvasRect: canvasRect, renderExtent: renderExtent,
                                transform: coordinateTransform)
        let layer = chrome.kind.isDevice
            ? deviceBody(chrome, geometry)
            : desktopWindow(chrome, geometry)
        return masked(layer, roundedMask(geometry.outer, geometry.outerRadius), extent: geometry.extent)
    }

    nonisolated static func foreground(
        _ chrome: FrameScreenChromeScene,
        canvasRect: CGRect,
        renderExtent: CGRect,
        coordinateTransform: CGAffineTransform = .identity
    ) -> CIImage? {
        let geometry = geometry(chrome, canvasRect: canvasRect, renderExtent: renderExtent,
                                transform: coordinateTransform)
        let layer: CIImage?
        if chrome.kind.isPhone {
            layer = dynamicIsland(geometry, landscape: chrome.kind == .devicePhoneLandscape)
        } else if !chrome.kind.isDevice {
            layer = windowEdge(chrome, geometry)
        } else {
            layer = nil
        }
        guard let layer else { return nil }
        return masked(layer, roundedMask(geometry.outer, geometry.outerRadius), extent: geometry.extent)
    }

    // MARK: - Geometry

    private nonisolated static func geometry(
        _ chrome: FrameScreenChromeScene,
        canvasRect: CGRect,
        renderExtent: CGRect,
        transform: CGAffineTransform
    ) -> Geometry {
        let radiusScale = max(min(hypot(transform.a, transform.b), hypot(transform.c, transform.d)), 0.000_1)
        func rect(_ value: CompositionRect) -> CGRect {
            SharedFrameRenderer.coreImageRect(from: value, canvasHeight: canvasRect.height)
                .applying(transform)
                .standardized
        }
        return Geometry(
            extent: renderExtent.standardized,
            outer: rect(chrome.outerRect),
            toolbar: rect(chrome.toolbarRect),
            content: rect(chrome.contentRect),
            outerRadius: chrome.outerCornerRadius * radiusScale,
            contentRadius: chrome.contentCornerRadius * radiusScale
        )
    }

    // MARK: - Apple devices

    private nonisolated static func deviceBody(
        _ chrome: FrameScreenChromeScene,
        _ geometry: Geometry
    ) -> CIImage {
        let outer = geometry.outer
        let content = geometry.content
        let extent = geometry.extent
        let bezel = max(min(content.minX - outer.minX, outer.maxX - content.maxX,
                            content.minY - outer.minY, outer.maxY - content.maxY), 0.5)
        let rim = max(bezel * 0.30, 0.8)

        var body = linearGradient(
            from: CGPoint(x: outer.midX, y: outer.maxY),
            to: CGPoint(x: outer.midX, y: outer.minY),
            CIColor(red: 0.60, green: 0.61, blue: 0.63),
            CIColor(red: 0.23, green: 0.235, blue: 0.25),
            extent: extent
        )
        body = linearGradient(
            from: CGPoint(x: outer.minX, y: outer.maxY),
            to: CGPoint(x: outer.midX, y: outer.midY),
            CIColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            extent: extent
        ).composited(over: body)

        let bezelRect = outer.insetBy(dx: rim, dy: rim)
        let bezelRadius = max(geometry.outerRadius - rim, 0)
        body = colored(CIColor(red: 0.018, green: 0.018, blue: 0.022),
                       mask: roundedMask(bezelRect, bezelRadius), extent: extent)
            .composited(over: body)

        let innerShade = max(rim * 0.45, 0.5)
        body = colored(CIColor(red: 0, green: 0, blue: 0, alpha: 0.55),
                       mask: ringMask(roundedMask(bezelRect, bezelRadius),
                                      roundedMask(bezelRect.insetBy(dx: innerShade, dy: innerShade),
                                                  max(bezelRadius - innerShade, 0)),
                                      extent: extent),
                       extent: extent).composited(over: body)

        let glassEdge = max(bezel * 0.07, 0.5)
        body = colored(CIColor(red: 0.11, green: 0.11, blue: 0.12),
                       mask: ringMask(roundedMask(content.insetBy(dx: -glassEdge, dy: -glassEdge),
                                                  geometry.contentRadius + glassEdge),
                                      roundedMask(content, geometry.contentRadius),
                                      extent: extent),
                       extent: extent).composited(over: body)

        let edge = max(rim * 0.30, 0.6)
        let edgeRing = ringMask(roundedMask(outer, geometry.outerRadius),
                                roundedMask(outer.insetBy(dx: edge, dy: edge),
                                            max(geometry.outerRadius - edge, 0)),
                                extent: extent)
        body = masked(linearGradient(
            from: CGPoint(x: outer.midX, y: outer.maxY),
            to: CGPoint(x: outer.midX, y: outer.midY),
            CIColor(red: 1, green: 1, blue: 1, alpha: 0.6),
            CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            extent: extent
        ), edgeRing, extent: extent).composited(over: body)
        body = masked(linearGradient(
            from: CGPoint(x: outer.midX, y: outer.minY),
            to: CGPoint(x: outer.midX, y: outer.midY),
            CIColor(red: 0, green: 0, blue: 0, alpha: 0.5),
            CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            extent: extent
        ), edgeRing, extent: extent).composited(over: body)

        if !chrome.kind.isPhone {
            let diameter = max(bezel * 0.26, 1)
            let center = CGPoint(x: outer.midX, y: (outer.maxY + content.maxY) / 2)
            let lens = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                              width: diameter, height: diameter)
            body = colored(CIColor(red: 0.14, green: 0.15, blue: 0.17),
                           mask: roundedMask(lens.insetBy(dx: -diameter * 0.18, dy: -diameter * 0.18),
                                             diameter * 0.68),
                           extent: extent).composited(over: body)
            body = colored(CIColor(red: 0.04, green: 0.05, blue: 0.08),
                           mask: roundedMask(lens, diameter / 2), extent: extent).composited(over: body)
            let glint = diameter * 0.28
            body = colored(CIColor(red: 1, green: 1, blue: 1, alpha: 0.28),
                           mask: roundedMask(CGRect(x: center.x - diameter * 0.22, y: center.y + diameter * 0.02,
                                                    width: glint, height: glint), glint / 2),
                           extent: extent).composited(over: body)
        }
        return body
    }

    private nonisolated static func sideButtons(
        outer: CGRect,
        rim: CGFloat,
        landscape: Bool,
        extent: CGRect
    ) -> CIImage {
        let leftButtons: [(CGFloat, CGFloat)] = [(0.175, 0.212), (0.255, 0.322), (0.345, 0.412)]
        let rightButtons: [(CGFloat, CGFloat)] = [(0.270, 0.385)]
        var layer = CIImage(color: .clear).cropped(to: extent)
        func segment(_ range: (CGFloat, CGFloat), onLeading: Bool) -> CGRect {
            if landscape {
                let x0 = outer.minX + range.0 * outer.width
                let width = (range.1 - range.0) * outer.width
                return CGRect(x: x0, y: onLeading ? outer.minY : outer.maxY - rim,
                              width: width, height: rim)
            }
            let y1 = outer.maxY - range.0 * outer.height
            let height = (range.1 - range.0) * outer.height
            return CGRect(x: onLeading ? outer.minX : outer.maxX - rim, y: y1 - height,
                          width: rim, height: height)
        }
        let buttons = leftButtons.map { segment($0, onLeading: true) }
            + rightButtons.map { segment($0, onLeading: false) }
        for button in buttons {
            let gap = max(rim * 0.22, 0.4)
            let outline = landscape
                ? button.insetBy(dx: -gap, dy: 0)
                : button.insetBy(dx: 0, dy: -gap)
            layer = colored(CIColor(red: 0, green: 0, blue: 0, alpha: 0.45),
                            mask: roundedMask(outline, rim * 0.5), extent: extent).composited(over: layer)
            layer = colored(CIColor(red: 1, green: 1, blue: 1, alpha: 0.24),
                            mask: roundedMask(button, rim * 0.5), extent: extent).composited(over: layer)
        }
        return layer
    }

    private nonisolated static func dynamicIsland(_ geometry: Geometry, landscape: Bool) -> CIImage? {
        let content = geometry.content
        let shortEdge = min(content.width, content.height)
        let longEdge = max(content.width, content.height)
        guard shortEdge > 4, longEdge / shortEdge >= 1.75 else { return nil }
        let length = shortEdge * 0.32
        let thickness = shortEdge * 0.095
        let gap = shortEdge * 0.028
        let island = landscape
            ? CGRect(x: content.minX + gap, y: content.midY - length / 2, width: thickness, height: length)
            : CGRect(x: content.midX - length / 2, y: content.maxY - gap - thickness,
                     width: length, height: thickness)
        var layer = colored(CIColor(red: 0, green: 0, blue: 0), mask: roundedMask(island, thickness / 2),
                            extent: geometry.extent)
        let lensDiameter = thickness * 0.40
        let lensCenter = landscape
            ? CGPoint(x: island.midX, y: island.maxY - thickness * 0.5)
            : CGPoint(x: island.maxX - thickness * 0.5, y: island.midY)
        let lens = CGRect(x: lensCenter.x - lensDiameter / 2, y: lensCenter.y - lensDiameter / 2,
                          width: lensDiameter, height: lensDiameter)
        layer = colored(CIColor(red: 0.07, green: 0.08, blue: 0.12),
                        mask: roundedMask(lens, lensDiameter / 2), extent: geometry.extent)
            .composited(over: layer)
        let glint = lensDiameter * 0.32
        layer = colored(CIColor(red: 0.55, green: 0.62, blue: 0.85, alpha: 0.35),
                        mask: roundedMask(CGRect(x: lensCenter.x - lensDiameter * 0.24,
                                                 y: lensCenter.y + lensDiameter * 0.02,
                                                 width: glint, height: glint), glint / 2),
                        extent: geometry.extent).composited(over: layer)
        return layer
    }

    // MARK: - Desktop window and browser

    private nonisolated static func isDark(_ chrome: FrameScreenChromeScene) -> Bool {
        let value = chrome.toolbarColor.components
        return value.red * 0.299 + value.green * 0.587 + value.blue * 0.114 < 0.5
    }

    private nonisolated static func windowEdge(
        _ chrome: FrameScreenChromeScene,
        _ geometry: Geometry
    ) -> CIImage {
        let extent = geometry.extent
        let outer = geometry.outer
        let toolbar = geometry.toolbar
        let dark = isDark(chrome)
        let hairline = max(toolbar.height * 0.022, 0.6)
        var layer = CIImage(color: .clear).cropped(to: extent)

        if chrome.kind == .window {
            let shadowDepth = toolbar.height * 0.42
            let shadowRect = CGRect(x: toolbar.minX, y: toolbar.minY - shadowDepth,
                                    width: toolbar.width, height: shadowDepth)
            layer = linearGradient(
                from: CGPoint(x: toolbar.midX, y: toolbar.minY),
                to: CGPoint(x: toolbar.midX, y: shadowRect.minY),
                CIColor(red: 0, green: 0, blue: 0, alpha: dark ? 0.34 : 0.10),
                CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                extent: shadowRect.intersection(extent)
            ).composited(over: layer)
        }

        let ring = ringMask(roundedMask(outer, geometry.outerRadius),
                            roundedMask(outer.insetBy(dx: hairline, dy: hairline),
                                        max(geometry.outerRadius - hairline, 0)),
                            extent: extent)
        layer = colored(dark
                            ? CIColor(red: 1, green: 1, blue: 1, alpha: 0.10)
                            : CIColor(red: 0, green: 0, blue: 0, alpha: 0.18),
                        mask: ring, extent: extent).composited(over: layer)
        let innerOuter = outer.insetBy(dx: hairline, dy: hairline)
        let innerRing = ringMask(roundedMask(innerOuter, max(geometry.outerRadius - hairline, 0)),
                                 roundedMask(innerOuter.insetBy(dx: hairline, dy: hairline),
                                             max(geometry.outerRadius - hairline * 2, 0)),
                                 extent: extent)
        layer = masked(linearGradient(
            from: CGPoint(x: outer.midX, y: outer.maxY),
            to: CGPoint(x: outer.midX, y: toolbar.minY),
            CIColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.22 : 0.9),
            CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            extent: extent
        ), innerRing, extent: extent).composited(over: layer)
        return layer
    }

    private nonisolated static func trafficLights(
        toolbar: CGRect,
        dark: Bool,
        extent: CGRect
    ) -> (layer: CIImage, margin: CGFloat, end: CGFloat) {
        let diameter = min(max(toolbar.height * 0.245, 1.5), toolbar.height * 0.32)
        let margin = max(toolbar.height * 0.42, diameter)
        let spacing = diameter * 1.68
        let colors: [(top: CIColor, bottom: CIColor)] = [
            (CIColor(red: 1.00, green: 0.47, blue: 0.43), CIColor(red: 0.93, green: 0.29, blue: 0.27)),
            (CIColor(red: 1.00, green: 0.80, blue: 0.33), CIColor(red: 0.96, green: 0.65, blue: 0.10)),
            (CIColor(red: 0.36, green: 0.86, blue: 0.40), CIColor(red: 0.13, green: 0.68, blue: 0.24)),
        ]
        var layer = CIImage(color: .clear).cropped(to: extent)
        for (index, color) in colors.enumerated() {
            let rect = CGRect(x: toolbar.minX + margin + CGFloat(index) * spacing,
                              y: toolbar.midY - diameter / 2, width: diameter, height: diameter)
            let mask = roundedMask(rect, diameter / 2)
            layer = masked(linearGradient(
                from: CGPoint(x: rect.midX, y: rect.maxY),
                to: CGPoint(x: rect.midX, y: rect.minY),
                color.top, color.bottom, extent: extent
            ), mask, extent: extent).composited(over: layer)
            let stroke = max(diameter * 0.075, 0.4)
            layer = colored(CIColor(red: 0, green: 0, blue: 0, alpha: dark ? 0.30 : 0.14),
                            mask: ringMask(mask,
                                           roundedMask(rect.insetBy(dx: stroke, dy: stroke),
                                                       diameter / 2 - stroke),
                                           extent: extent),
                            extent: extent).composited(over: layer)
            let gloss = CGRect(x: rect.minX + diameter * 0.26, y: rect.midY + diameter * 0.06,
                               width: diameter * 0.48, height: diameter * 0.30)
            layer = colored(CIColor(red: 1, green: 1, blue: 1, alpha: 0.32),
                            mask: roundedMask(gloss, gloss.height / 2), extent: extent)
                .composited(over: layer)
        }
        return (layer, margin, toolbar.minX + margin + spacing * 2 + diameter)
    }

    private nonisolated static func desktopWindow(
        _ chrome: FrameScreenChromeScene,
        _ geometry: Geometry
    ) -> CIImage {
        let extent = geometry.extent
        let toolbar = geometry.toolbar
        let dark = isDark(chrome)
        var layer = colored(ciColor(chrome.surfaceColor),
                            mask: roundedMask(geometry.outer, geometry.outerRadius), extent: extent)
        let hairline = max(toolbar.height * 0.022, 0.6)
        if chrome.kind == .window {
            let top = dark
                ? CIColor(red: 0.255, green: 0.255, blue: 0.28)
                : CIColor(red: 1, green: 1, blue: 1)
            let bottom = dark
                ? CIColor(red: 0.165, green: 0.165, blue: 0.185)
                : CIColor(red: 0.925, green: 0.928, blue: 0.945)
            layer = masked(linearGradient(
                from: CGPoint(x: toolbar.midX, y: toolbar.maxY),
                to: CGPoint(x: toolbar.midX, y: toolbar.minY),
                top, bottom, extent: extent
            ), CIImage(color: .white).cropped(to: toolbar), extent: extent).composited(over: layer)
            layer = CIImage(color: ciColor(chrome.separatorColor, alpha: dark ? 0.9 : 0.55))
                .cropped(to: CGRect(x: toolbar.minX, y: toolbar.minY, width: toolbar.width, height: hairline))
                .composited(over: layer)
        } else {
            layer = colored(ciColor(chrome.toolbarColor),
                            mask: CIImage(color: .white).cropped(to: toolbar), extent: extent)
                .composited(over: layer)
            layer = CIImage(color: ciColor(chrome.separatorColor))
                .cropped(to: CGRect(x: toolbar.minX, y: toolbar.minY, width: toolbar.width, height: hairline))
                .composited(over: layer)
        }

        let lights = trafficLights(toolbar: toolbar, dark: dark, extent: extent)
        layer = lights.layer.composited(over: layer)
        let margin = lights.margin
        let controlsEnd = lights.end

        switch chrome.kind {
        case .window:
            let title = chrome.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text = textLayer(title, color: chrome.glyphColor,
                                    fontSize: max(toolbar.height * 0.31, 5), weight: .semibold,
                                    maximumWidth: max(toolbar.width * 0.46, 2),
                                    center: CGPoint(x: toolbar.midX, y: toolbar.midY), clip: toolbar) {
                layer = text.composited(over: layer)
            }
        case .browser:
            layer = browserToolbar(chrome, toolbar: toolbar, controlsEnd: controlsEnd,
                                   margin: margin, extent: extent).composited(over: layer)
        case .devicePhonePortrait, .devicePhoneLandscape,
             .deviceTabletPortrait, .deviceTabletLandscape:
            break
        }
        return layer
    }

    private nonisolated static func browserToolbar(
        _ chrome: FrameScreenChromeScene,
        toolbar: CGRect,
        controlsEnd: CGFloat,
        margin: CGFloat,
        extent: CGRect
    ) -> CIImage {
        var layer = CIImage(color: .clear).cropped(to: extent)
        let glyph = toolbar.height * 0.34
        let glyphY = toolbar.midY - glyph / 2
        func place(_ kind: Glyph, x: CGFloat, alpha: CGFloat = 0.82) {
            if let image = glyphImage(kind, size: glyph, color: chrome.glyphColor, alpha: alpha) {
                layer = image.transformed(by: CGAffineTransform(translationX: x, y: glyphY))
                    .composited(over: layer)
            }
        }
        var x = controlsEnd + toolbar.height * 0.55
        place(.sidebar, x: x)
        x += glyph * 1.7
        place(.chevronLeft, x: x)
        x += glyph * 1.15
        place(.chevronRight, x: x, alpha: 0.42)
        let leadingEnd = x + glyph + toolbar.height * 0.45

        let plusX = toolbar.maxX - margin - glyph
        place(.plus, x: plusX)
        let tabsX = plusX - glyph * 1.7
        place(.tabs, x: tabsX)
        let trailingStart = tabsX - toolbar.height * 0.45

        let available = trailingStart - leadingEnd
        guard available > toolbar.height else { return layer }
        let fieldHeight = toolbar.height * 0.52
        let address = chrome.browserAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize = max(fieldHeight * 0.40, 5)
        let textWidth = textImage(address, color: chrome.glyphColor, fontSize: fontSize,
                                  weight: .medium)?.extent.width ?? 0
        let lockSize = fieldHeight * 0.40
        let lockGap = fieldHeight * 0.24
        let groupWidth = address.isEmpty ? 0 : lockSize + lockGap + textWidth
        let fieldWidth = min(max(groupWidth + fieldHeight * 1.6, toolbar.width * 0.38), available)
        let fieldCenter = min(max(toolbar.midX, leadingEnd + fieldWidth / 2), trailingStart - fieldWidth / 2)
        let field = CGRect(x: fieldCenter - fieldWidth / 2, y: toolbar.midY - fieldHeight / 2,
                           width: fieldWidth, height: fieldHeight)
        layer = colored(ciColor(chrome.fieldColor), mask: roundedMask(field, fieldHeight * 0.32),
                        extent: extent).composited(over: layer)
        guard !address.isEmpty else { return layer }

        let inset = fieldHeight * 0.45
        let groupStart = max(field.midX - groupWidth / 2, field.minX + inset)
        if let lock = glyphImage(.lock, size: lockSize, color: chrome.glyphColor, alpha: 0.78) {
            layer = lock.transformed(by: CGAffineTransform(translationX: groupStart,
                                                           y: field.midY - lockSize / 2))
                .composited(over: layer)
        }
        let textStart = groupStart + lockSize + lockGap
        let maximumWidth = max(field.maxX - inset - textStart, 2)
        let shownWidth = min(textWidth, maximumWidth)
        if let text = textLayer(address, color: chrome.glyphColor, fontSize: fontSize, weight: .medium,
                                maximumWidth: maximumWidth,
                                center: CGPoint(x: textStart + shownWidth / 2, y: field.midY),
                                clip: field) {
            layer = text.composited(over: layer)
        }
        return layer
    }

    // MARK: - Glyphs and text

    private nonisolated static func glyphImage(
        _ glyph: Glyph,
        size: CGFloat,
        color: HexColor,
        alpha: CGFloat
    ) -> CIImage? {
        guard size.isFinite, size > 0.5 else { return nil }
        let pixels = max((size * 2).rounded() / 2, 1)
        let components = color.components
        let key = String(format: "glyph|%@|%.1f|%.3f|%.3f|%.3f|%.2f", glyph.rawValue, Double(pixels),
                         components.red, components.green, components.blue, Double(alpha)) as NSString
        guard let image = rasterCache.image(for: key, create: {
            let side = Int(ceil(pixels)) + 2
            guard side < 4_096,
                  let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let ink = CGColor(red: components.red, green: components.green, blue: components.blue, alpha: alpha)
            context.translateBy(x: 1, y: 1)
            context.setStrokeColor(ink)
            context.setFillColor(ink)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let s = pixels
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            switch glyph {
            case .chevronLeft, .chevronRight:
                let flip = glyph == .chevronRight
                context.setLineWidth(s * 0.12)
                context.move(to: point(flip ? 0.40 : 0.60, 0.16))
                context.addLine(to: point(flip ? 0.66 : 0.34, 0.50))
                context.addLine(to: point(flip ? 0.40 : 0.60, 0.84))
                context.strokePath()
            case .sidebar:
                context.setLineWidth(s * 0.085)
                context.addPath(CGPath(roundedRect: CGRect(x: 0.08 * s, y: 0.20 * s, width: 0.84 * s, height: 0.60 * s),
                                       cornerWidth: 0.13 * s, cornerHeight: 0.13 * s, transform: nil))
                context.strokePath()
                context.move(to: point(0.38, 0.22))
                context.addLine(to: point(0.38, 0.78))
                context.strokePath()
            case .lock:
                context.addPath(CGPath(roundedRect: CGRect(x: 0.20 * s, y: 0.06 * s, width: 0.60 * s, height: 0.48 * s),
                                       cornerWidth: 0.10 * s, cornerHeight: 0.10 * s, transform: nil))
                context.fillPath()
                context.setLineWidth(s * 0.11)
                context.move(to: point(0.34, 0.54))
                context.addLine(to: point(0.34, 0.68))
                context.addArc(center: point(0.50, 0.68), radius: 0.16 * s,
                               startAngle: .pi, endAngle: 0, clockwise: true)
                context.addLine(to: point(0.66, 0.54))
                context.strokePath()
            case .plus:
                context.setLineWidth(s * 0.10)
                context.move(to: point(0.50, 0.18))
                context.addLine(to: point(0.50, 0.82))
                context.move(to: point(0.18, 0.50))
                context.addLine(to: point(0.82, 0.50))
                context.strokePath()
            case .tabs:
                context.setLineWidth(s * 0.085)
                context.addPath(CGPath(roundedRect: CGRect(x: 0.10 * s, y: 0.12 * s, width: 0.58 * s, height: 0.58 * s),
                                       cornerWidth: 0.12 * s, cornerHeight: 0.12 * s, transform: nil))
                context.strokePath()
                context.move(to: point(0.32, 0.88))
                context.addLine(to: point(0.78, 0.88))
                context.addQuadCurve(to: point(0.90, 0.76), control: point(0.90, 0.88))
                context.addLine(to: point(0.90, 0.32))
                context.strokePath()
            }
            guard let cgImage = context.makeImage() else { return nil }
            return CIImage(cgImage: cgImage)
                .transformed(by: CGAffineTransform(translationX: -1, y: -1))
        }) else { return nil }
        let scale = size / pixels
        return abs(scale - 1) < 0.001
            ? image
            : image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private nonisolated static func textLayer(
        _ text: String,
        color: HexColor,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        maximumWidth: CGFloat,
        center: CGPoint,
        clip: CGRect
    ) -> CIImage? {
        guard !text.isEmpty, fontSize > 0, maximumWidth > 2,
              let image = textImage(text, color: color, fontSize: fontSize, weight: weight)
        else { return nil }
        let scale = min(maximumWidth / image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled
            .transformed(by: CGAffineTransform(
                translationX: center.x - scaled.extent.width / 2 - scaled.extent.minX,
                y: center.y - scaled.extent.height / 2 - scaled.extent.minY
            ))
            .cropped(to: clip)
    }

    private nonisolated static func textImage(
        _ text: String,
        color: HexColor,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> CIImage? {
        guard !text.isEmpty, fontSize > 0 else { return nil }
        let components = color.components
        let key = String(format: "text|%@|%.2f|%.3f|%.3f|%.3f|%.2f", text,
                         Double(fontSize), components.red, components.green, components.blue,
                         Double(weight.rawValue)) as NSString
        return rasterCache.image(for: key) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    red: components.red, green: components.green, blue: components.blue, alpha: 0.9)
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let bounds = glyphs.union(CGRect(x: 0, y: -descent, width: width, height: ascent + descent)).integral
            guard bounds.width > 0, bounds.height > 0, bounds.width < 32_768,
                  let context = CGContext(data: nil, width: Int(bounds.width) + 2,
                                          height: Int(bounds.height) + 2, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.textPosition = CGPoint(x: 1 - bounds.minX, y: 1 - bounds.minY)
            CTLineDraw(line, context)
            guard let image = context.makeImage() else { return nil }
            return CIImage(cgImage: image)
        }
    }

    // MARK: - Core Image helpers

    private nonisolated static func ciColor(_ color: HexColor, alpha: CGFloat = 1) -> CIColor {
        let components = color.components
        return CIColor(red: CGFloat(components.red), green: CGFloat(components.green),
                       blue: CGFloat(components.blue), alpha: alpha)
    }

    private nonisolated static func roundedMask(_ rect: CGRect, _ radius: CGFloat) -> CIImage {
        ContinuousCornerMask.mask(rect: rect, radius: radius)
    }

    private nonisolated static func linearGradient(
        from start: CGPoint,
        to end: CGPoint,
        _ startColor: CIColor,
        _ endColor: CIColor,
        extent: CGRect
    ) -> CIImage {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: start),
            "inputPoint1": CIVector(cgPoint: end),
            "inputColor0": startColor,
            "inputColor1": endColor,
        ])?.outputImage ?? CIImage(color: endColor)
        return gradient.cropped(to: extent)
    }

    private nonisolated static func masked(_ image: CIImage, _ mask: CIImage, extent: CGRect) -> CIImage {
        let bounds = extent.intersection(mask.extent)
        guard !bounds.isEmpty, !bounds.isNull else { return CIImage(color: .clear).cropped(to: .zero) }
        return image.cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: bounds)
    }

    private nonisolated static func colored(_ color: CIColor, mask: CIImage, extent: CGRect) -> CIImage {
        masked(CIImage(color: color), mask, extent: extent)
    }

    private nonisolated static func ringMask(_ outer: CIImage, _ inner: CIImage, extent: CGRect) -> CIImage {
        outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            .cropped(to: extent)
    }
}
