import SwiftUI

/// DogSC's one icon set (EDT-078, the 编辑器第二版 sheet): a 20-unit grid with
/// content inside the middle 15 units, 1.5 strokes with round caps and
/// joins, 2-unit corners on boxes, open line drawings. Only play, pause and
/// stop are solid. The line weight stays the same at every size.
struct AppLineIcon: View {
    enum Kind: Equatable {
        case settings, sliders, record, shield, info, appearance, sun, moon, globe
        case shapeCircle, shapeRounded, shapeWide
        case bell, speaker, box, download, sparkle, display, window, microphone
        case cursor, camera, folder, check, checkCircle, warning, refresh
        case code, feedback, cup, external, chevron, person, close, arrowLeft
        // Editor tools and toolbar actions.
        case scene, opening, zoom, cursorMotion, undo, redo, plus, trash, pencil
        case share, chevronDown, layers
        case play, pause, stop, previousFrame, nextFrame, scissors, minus
        case waveform, eye, eyeOff, fit, grid, crop, layout, film
        // Editor glyphs that used to fall back to system symbols.
        case magnet, clock, cube, link, photoAdd, paste, expand, aspect, target, move
        case pin, speed, drop, halfCircle, bookmark, swap, speakerOff, cameraOff
        case search, noSymbol, chevronLeft, chevronUp, noFrame, portrait, arrowRight
        case arrowUpLeft, arrowDownRight, deleteLeft, deleteRight, list, presets
        // EDT-078 additions.
        case ellipsis, sidebar, star, starFilled, export, wand, clear, text, image
        case shape, line, subtitle, select, spotlight, duplicate, radius, rotate, note, stack, eyedropper, keyboard, editorLayout, lens, overlayStack, regionBlur
    }

    let kind: Kind
    var size: CGFloat = 18

    /// 1.5 at 20 pt, never thinner than 1.25 nor heavier than 1.6; large
    /// display icons keep their proportion.
    static func strokeWidth(for size: CGFloat) -> CGFloat {
        size >= 28 ? size * 1.5 / 20 : min(max(size * 1.5 / 20, 1.25), 1.6)
    }

    private var isSolid: Bool { kind == .play || kind == .pause || kind == .stop || kind == .starFilled }

    /// EDT-080: two-tone. A soft face (16 % ink) gives each glyph a body,
    /// the outline draws it, and small solid accents (magnet poles, a pupil,
    /// a sun) give it a focal point.
    var body: some View {
        ZStack {
            if isSolid {
                Drawing(kind: kind, layer: .outline).fill()
            } else {
                Drawing(kind: kind, layer: .face).fill(.foreground.opacity(0.18))
                Drawing(kind: kind, layer: .accent).fill()
                Drawing(kind: kind, layer: .outline)
                    .stroke(style: StrokeStyle(lineWidth: Self.strokeWidth(for: size), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    enum Layer { case outline, face, accent }

    private struct Drawing: Shape {
        let kind: Kind
        var layer: Layer = .outline

        func path(in rect: CGRect) -> Path {
            var p = Path()
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            func line(_ points: [(CGFloat, CGFloat)]) {
                guard let first = points.first else { return }
                p.move(to: pt(first.0, first.1))
                for (x, y) in points.dropFirst() { p.addLine(to: pt(x, y)) }
            }
            func closed(_ points: [(CGFloat, CGFloat)]) { line(points); p.closeSubpath() }
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 2) {
                p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
            }
            func dot(_ x: CGFloat, _ y: CGFloat) { circle(x, y, 0.35) }
            func roundTop(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
                p.addPath(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                               cornerRadii: RectangleCornerRadii(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)))
            }

            if layer == .face || layer == .accent {
                Self.addDetail(kind: kind, layer: layer, to: &p)
                return p.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20)
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            }

            switch kind {
            // MARK: Transport (solid where weight matters)
            case .play:
                p.move(to: pt(6.5, 4.6)); p.addLine(to: pt(6.5, 15.4))
                p.addQuadCurve(to: pt(7.4, 15.9), control: pt(6.5, 16.4))
                p.addLine(to: pt(16, 10.5)); p.addQuadCurve(to: pt(16, 9.5), control: pt(16.8, 10))
                p.addLine(to: pt(7.4, 4.1)); p.addQuadCurve(to: pt(6.5, 4.6), control: pt(6.5, 3.6)); p.closeSubpath()
            case .pause:
                box(5.5, 4.5, 3, 11, 1); box(11.5, 4.5, 3, 11, 1)
            case .stop:
                box(5, 5, 10, 10, 2)
            case .previousFrame:
                closed([(14.5, 5.5), (14.5, 14.5), (8, 10)]); line([(5.5, 5), (5.5, 15)])
            case .nextFrame:
                closed([(5.5, 5.5), (5.5, 14.5), (12, 10)]); line([(14.5, 5), (14.5, 15)])
            case .record:
                circle(10, 10, 6.5); circle(10, 10, 2.8)

            // MARK: Basic actions
            case .plus:
                line([(10, 4), (10, 16)]); line([(4, 10), (16, 10)])
            case .minus:
                line([(4, 10), (16, 10)])
            case .close:
                line([(5.5, 5.5), (14.5, 14.5)]); line([(14.5, 5.5), (5.5, 14.5)])
            case .clear:
                circle(10, 10, 6.5); line([(7.7, 7.7), (12.3, 12.3)]); line([(12.3, 7.7), (7.7, 12.3)])
            case .check:
                line([(4.5, 10.5), (8, 14), (15.5, 6)])
            case .checkCircle:
                circle(10, 10, 6.5); line([(7, 10.2), (9.2, 12.4), (13.2, 8)])
            case .trash:
                line([(4, 6), (16, 6)]); line([(8, 6), (8, 4.5), (12, 4.5), (12, 6)])
                line([(5.5, 6), (6.2, 15.5), (13.8, 15.5), (14.5, 6)])
            case .duplicate:
                box(7, 7, 9.5, 9.5)
                p.move(to: pt(13, 7)); p.addLine(to: pt(13, 5)); p.addQuadCurve(to: pt(11.5, 3.5), control: pt(13, 3.5))
                p.addLine(to: pt(5.5, 3.5)); p.addQuadCurve(to: pt(4, 5), control: pt(4, 3.5))
                p.addLine(to: pt(4, 11)); p.addQuadCurve(to: pt(5.5, 12.5), control: pt(4, 12.5)); p.addLine(to: pt(7, 12.5))
            case .paste:
                box(5, 4.5, 10, 12); box(7.5, 3, 5, 3, 1); line([(7.5, 10), (12.5, 10)]); line([(7.5, 13), (11, 13)])
            case .undo:
                line([(7, 5), (3.5, 8.5), (7, 12)])
                p.move(to: pt(4, 8.5)); p.addLine(to: pt(11.5, 8.5)); p.addArc(center: pt(11.5, 12.5), radius: 4, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false); p.addLine(to: pt(9, 16.5))
            case .redo:
                line([(13, 5), (16.5, 8.5), (13, 12)])
                p.move(to: pt(16, 8.5)); p.addLine(to: pt(8.5, 8.5)); p.addArc(center: pt(8.5, 12.5), radius: 4, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true); p.addLine(to: pt(11, 16.5))
            case .refresh, .rotate:
                p.addArc(center: pt(10, 10), radius: 5.5, startAngle: .degrees(-40), endAngle: .degrees(-320), clockwise: true)
                line([(15.5, 3.5), (15.5, 6.6), (12.4, 6.6)])
            case .pencil:
                closed([(12.5, 4.5), (15.5, 7.5), (8, 15), (5, 15), (5, 12)]); line([(11, 6), (14, 9)])
            case .scissors:
                circle(6, 14.5, 2.5); circle(14, 14.5, 2.5); line([(7.6, 12.6), (14, 3.5)]); line([(12.4, 12.6), (6, 3.5)])
            case .link:
                p.move(to: pt(8.5, 11.5)); p.addLine(to: pt(11.5, 8.5))
                p.move(to: pt(9.5, 6)); p.addLine(to: pt(11, 4.5)); p.addArc(center: pt(13, 7), radius: 3.2, startAngle: .degrees(-130), endAngle: .degrees(40), clockwise: false); p.addLine(to: pt(14, 10.5))
                p.move(to: pt(10.5, 14)); p.addLine(to: pt(9, 15.5)); p.addArc(center: pt(7, 13), radius: 3.2, startAngle: .degrees(50), endAngle: .degrees(220), clockwise: false); p.addLine(to: pt(6, 9.5))
            case .magnet:
                // A horseshoe band: outer U, inner U, square pole ends.
                p.move(to: pt(3.5, 4.5)); p.addQuadCurve(to: pt(4.5, 3.5), control: pt(3.5, 3.5))
                p.addLine(to: pt(7.5, 3.5)); p.addQuadCurve(to: pt(8.5, 4.5), control: pt(8.5, 3.5))
                p.addLine(to: pt(8.5, 10.5)); p.addArc(center: pt(10, 10.5), radius: 1.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                p.addLine(to: pt(11.5, 4.5)); p.addQuadCurve(to: pt(12.5, 3.5), control: pt(11.5, 3.5))
                p.addLine(to: pt(15.5, 3.5)); p.addQuadCurve(to: pt(16.5, 4.5), control: pt(16.5, 3.5))
                p.addLine(to: pt(16.5, 10.5)); p.addArc(center: pt(10, 10.5), radius: 6.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                p.closeSubpath()
                line([(3.5, 7), (8.5, 7)]); line([(11.5, 7), (16.5, 7)])
            case .ellipsis:
                circle(5, 10, 0.9); circle(10, 10, 0.9); circle(15, 10, 0.9)
            case .search:
                circle(8.5, 8.5, 5); line([(12.3, 12.3), (16.5, 16.5)])
            case .noSymbol:
                circle(10, 10, 6.5); line([(5.5, 14.5), (14.5, 5.5)])
            case .share, .export:
                line([(10, 12.5), (10, 3.5)]); line([(6.5, 7), (10, 3.5), (13.5, 7)])
                p.move(to: pt(4, 11)); p.addLine(to: pt(4, 15.5)); p.addQuadCurve(to: pt(5, 16.5), control: pt(4, 16.5)); p.addLine(to: pt(15, 16.5)); p.addQuadCurve(to: pt(16, 15.5), control: pt(16, 16.5)); p.addLine(to: pt(16, 11))
            case .download:
                line([(10, 3.5), (10, 12.5)]); line([(6.5, 9), (10, 12.5), (13.5, 9)])
                p.move(to: pt(4, 11)); p.addLine(to: pt(4, 15.5)); p.addQuadCurve(to: pt(5, 16.5), control: pt(4, 16.5)); p.addLine(to: pt(15, 16.5)); p.addQuadCurve(to: pt(16, 15.5), control: pt(16, 16.5)); p.addLine(to: pt(16, 11))
            case .external:
                line([(8, 12), (15.5, 4.5)]); line([(10.5, 4.5), (15.5, 4.5), (15.5, 9.5)])
                p.move(to: pt(13, 12)); p.addLine(to: pt(13, 14.5)); p.addQuadCurve(to: pt(11.5, 16), control: pt(13, 16)); p.addLine(to: pt(5.5, 16)); p.addQuadCurve(to: pt(4, 14.5), control: pt(4, 16)); p.addLine(to: pt(4, 8.5)); p.addQuadCurve(to: pt(5.5, 7), control: pt(4, 7)); p.addLine(to: pt(8, 7))
            case .expand:
                line([(11.5, 4), (16, 4), (16, 8.5)]); line([(16, 4), (11, 9)]); line([(8.5, 16), (4, 16), (4, 11.5)]); line([(4, 16), (9, 11)])
            case .fit:
                line([(3.5, 5), (3.5, 15)]); line([(16.5, 5), (16.5, 15)])
                line([(6.5, 10), (13.5, 10)]); line([(8.5, 8), (6.5, 10), (8.5, 12)]); line([(11.5, 8), (13.5, 10), (11.5, 12)])
            case .swap:
                line([(3.5, 10), (16.5, 10)]); line([(6, 7.5), (3.5, 10), (6, 12.5)]); line([(14, 7.5), (16.5, 10), (14, 12.5)])
            case .move:
                line([(10, 3.5), (10, 16.5)]); line([(3.5, 10), (16.5, 10)])
                line([(8, 5.5), (10, 3.5), (12, 5.5)]); line([(8, 14.5), (10, 16.5), (12, 14.5)])
                line([(5.5, 8), (3.5, 10), (5.5, 12)]); line([(14.5, 8), (16.5, 10), (14.5, 12)])

            // MARK: Navigation
            case .chevron: line([(8, 5), (13, 10), (8, 15)])
            case .chevronLeft: line([(12, 5), (7, 10), (12, 15)])
            case .chevronDown: line([(5, 8), (10, 13), (15, 8)])
            case .chevronUp: line([(5, 12), (10, 7), (15, 12)])
            case .arrowLeft: line([(16, 10), (4, 10)]); line([(8.5, 5.5), (4, 10), (8.5, 14.5)])
            case .arrowRight: line([(4, 10), (16, 10)]); line([(11.5, 5.5), (16, 10), (11.5, 14.5)])
            case .arrowUpLeft: line([(15, 15), (5, 5)]); line([(5, 11), (5, 5), (11, 5)])
            case .arrowDownRight: line([(5, 5), (15, 15)]); line([(15, 9), (15, 15), (9, 15)])
            case .sidebar:
                box(3, 4, 14, 12); line([(8, 4), (8, 16)])
            case .deleteLeft, .deleteRight:
                var q = Path()
                q.move(to: pt(7, 4.5)); q.addLine(to: pt(15.5, 4.5)); q.addQuadCurve(to: pt(17, 6), control: pt(17, 4.5))
                q.addLine(to: pt(17, 14)); q.addQuadCurve(to: pt(15.5, 15.5), control: pt(17, 15.5)); q.addLine(to: pt(7, 15.5)); q.addLine(to: pt(2.5, 10)); q.closeSubpath()
                q.move(to: pt(9.5, 7.5)); q.addLine(to: pt(13.5, 12.5)); q.move(to: pt(13.5, 7.5)); q.addLine(to: pt(9.5, 12.5))
                p.addPath(kind == .deleteRight ? q.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 20, ty: 0)) : q)

            // MARK: App and settings
            case .settings, .sliders:
                line([(4, 6), (12, 6)]); line([(15, 6), (16, 6)]); circle(13.5, 6, 1.6)
                line([(4, 14), (5, 14)]); line([(8, 14), (16, 14)]); circle(6.5, 14, 1.6)
            case .shield:
                p.move(to: pt(10, 3)); p.addLine(to: pt(16, 5.5)); p.addLine(to: pt(16, 10))
                p.addCurve(to: pt(10, 17), control1: pt(16, 13.5), control2: pt(13.4, 16)); p.addCurve(to: pt(4, 10), control1: pt(6.6, 16), control2: pt(4, 13.5))
                p.addLine(to: pt(4, 5.5)); p.closeSubpath()
            case .info:
                circle(10, 10, 7); line([(10, 9), (10, 14)]); dot(10, 6.3)
            case .warning:
                p.move(to: pt(8.7, 4)); p.addQuadCurve(to: pt(11.3, 4), control: pt(10, 1.8))
                p.addLine(to: pt(16.7, 13.5)); p.addQuadCurve(to: pt(15.4, 15.8), control: pt(17.6, 15.8))
                p.addLine(to: pt(4.6, 15.8)); p.addQuadCurve(to: pt(3.3, 13.5), control: pt(2.4, 15.8)); p.closeSubpath()
                line([(10, 7.5), (10, 11)]); dot(10, 13.4)
            case .globe:
                circle(10, 10, 7); p.addEllipse(in: CGRect(x: 6.8, y: 3, width: 6.4, height: 14)); line([(3, 10), (17, 10)])
            case .appearance, .halfCircle:
                circle(10, 10, 6.5)
                p.move(to: pt(10, 3.5)); p.addArc(center: pt(10, 10), radius: 6.5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true); p.closeSubpath()
            case .sun:
                circle(10, 10, 3.2)
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    line([(10 + cos(a) * 5.6, 10 + sin(a) * 5.6), (10 + cos(a) * 7.2, 10 + sin(a) * 7.2)])
                }
            case .moon:
                // Crescent: an outer arc of a 6.5 circle, closed by an inner
                // arc that bulges the same way (a bite out of the top right).
                p.move(to: pt(12.4, 3.9))
                p.addCurve(to: pt(16.1, 12.4), control1: pt(9.4, 6.2), control2: pt(11.4, 12.6))
                p.addCurve(to: pt(3.5, 10), control1: pt(14.2, 17.6), control2: pt(4.6, 16.8))
                p.addCurve(to: pt(12.4, 3.9), control1: pt(3.2, 6.3), control2: pt(7.6, 3.2))
            case .bell:
                p.move(to: pt(4.5, 14)); p.addLine(to: pt(5.5, 12.5)); p.addLine(to: pt(5.5, 9))
                p.addArc(center: pt(10, 9), radius: 4.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: pt(14.5, 12.5)); p.addLine(to: pt(15.5, 14)); p.closeSubpath()
                p.move(to: pt(8.5, 16.5)); p.addQuadCurve(to: pt(11.5, 16.5), control: pt(10, 17.8))
            case .feedback:
                p.move(to: pt(5.5, 4)); p.addLine(to: pt(14.5, 4)); p.addQuadCurve(to: pt(16.5, 6), control: pt(16.5, 4))
                p.addLine(to: pt(16.5, 11.5)); p.addQuadCurve(to: pt(14.5, 13.5), control: pt(16.5, 13.5)); p.addLine(to: pt(9, 13.5))
                p.addLine(to: pt(5.5, 16.5)); p.addLine(to: pt(5.5, 13.5)); p.addQuadCurve(to: pt(3.5, 11.5), control: pt(3.5, 13.5))
                p.addLine(to: pt(3.5, 6)); p.addQuadCurve(to: pt(5.5, 4), control: pt(3.5, 4))
            case .cup:
                p.move(to: pt(4, 8)); p.addLine(to: pt(14, 8)); p.addLine(to: pt(14, 12))
                p.addArc(center: pt(10, 12), radius: 4, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false); p.closeSubpath()
                p.move(to: pt(14, 9)); p.addLine(to: pt(15, 9)); p.addArc(center: pt(15, 11), radius: 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false); p.addLine(to: pt(14, 13))
                line([(7, 3.5), (7, 5.5)]); line([(10, 3.5), (10, 5.5)])
            case .code:
                line([(6.5, 6), (3, 10), (6.5, 14)]); line([(13.5, 6), (17, 10), (13.5, 14)]); line([(11.5, 4.5), (8.5, 15.5)])
            case .person:
                circle(10, 7, 3)
                p.move(to: pt(4, 16.5)); p.addCurve(to: pt(16, 16.5), control1: pt(4.5, 11), control2: pt(15.5, 11))
            case .clock:
                circle(10, 10, 6.5); line([(10, 6.5), (10, 10), (12.5, 11.5)])
            case .speed:
                p.addArc(center: pt(10, 12), radius: 6.5, startAngle: .degrees(160), endAngle: .degrees(20), clockwise: false)
                line([(10, 12), (13, 8)]); circle(10, 12, 0.6)
            case .pin:
                p.move(to: pt(10, 17)); p.addCurve(to: pt(4.5, 8.5), control1: pt(6.5, 13.5), control2: pt(4.5, 11.5))
                p.addArc(center: pt(10, 8.5), radius: 5.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addCurve(to: pt(10, 17), control1: pt(15.5, 11.5), control2: pt(13.5, 13.5)); circle(10, 8.5, 2)
            case .bookmark:
                closed([(5.5, 3.5), (14.5, 3.5), (14.5, 16.5), (10, 13), (5.5, 16.5)])
            case .star, .starFilled:
                var points: [(CGFloat, CGFloat)] = []
                for i in 0..<10 {
                    let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                    let r: CGFloat = i % 2 == 0 ? 6.8 : 2.9
                    points.append((10 + cos(a) * r, 10.6 + sin(a) * r))
                }
                closed(points)
            case .overlayStack:
                // 两张叠放: the back sheet shows only its edge.
                p.move(to: pt(6.5, 4)); p.addLine(to: pt(14.5, 4)); p.addQuadCurve(to: pt(16.5, 6), control: pt(16.5, 4)); p.addLine(to: pt(16.5, 12.5))
                box(3.5, 7, 10.5, 9)
            case .regionBlur:
                // 半边虚化: a clear left half, the right half dissolving.
                p.move(to: pt(10, 3.5)); p.addArc(center: pt(10, 10), radius: 6.5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            case .keyboard:
                box(2.5, 5, 15, 10); for x in [CGFloat(6), 9, 12, 15] { dot(x, 8.5) }; line([(6.5, 11.5), (13.5, 11.5)])
            case .editorLayout:
                box(3, 4, 14, 12); line([(3, 12.5), (17, 12.5)]); line([(7, 4), (7, 12.5)])
            case .lens:
                circle(10, 10, 6.5); circle(10, 10, 2.5)
            case .eyedropper:
                line([(12.5, 3.5), (16.5, 7.5)]); closed([(11, 5), (15, 9), (8, 16), (4, 16), (4, 12)])
            case .note:
                box(4, 3.5, 12, 13); line([(7, 7.5), (13, 7.5)]); line([(7, 10.5), (13, 10.5)]); line([(7, 13.5), (10.5, 13.5)])
            case .list:
                for y in [CGFloat(6), 10, 14] { dot(4.5, y); line([(7.5, y), (16, y)]) }
            case .presets:
                box(3.5, 4, 5.5, 5.5, 1.5); box(11, 4, 5.5, 5.5, 1.5); box(3.5, 11.5, 13, 4.5, 1.5)

            case .folder:
                p.move(to: pt(3, 6.5)); p.addQuadCurve(to: pt(4.5, 5), control: pt(3, 5)); p.addLine(to: pt(7.7, 5))
                p.addLine(to: pt(9.3, 6.8)); p.addLine(to: pt(15.5, 6.8)); p.addQuadCurve(to: pt(17, 8.3), control: pt(17, 6.8))
                p.addLine(to: pt(17, 14.5)); p.addQuadCurve(to: pt(15.5, 16), control: pt(17, 16)); p.addLine(to: pt(4.5, 16))
                p.addQuadCurve(to: pt(3, 14.5), control: pt(3, 16)); p.closeSubpath()

            // MARK: Capture and devices
            case .display:
                box(2.5, 4, 15, 10); line([(10, 14), (10, 16.5)]); line([(7, 16.5), (13, 16.5)])
            case .window:
                box(3, 4, 14, 12); line([(3, 7.5), (17, 7.5)]); dot(5.5, 5.8); dot(7.5, 5.8)
            case .microphone:
                box(7.5, 3, 5, 9, 2.5)
                p.move(to: pt(5, 10)); p.addArc(center: pt(10, 10), radius: 5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                line([(10, 15), (10, 17)])
            case .camera:
                box(2.5, 5, 11, 10); closed([(13.5, 9), (17.5, 6.5), (17.5, 13.5), (13.5, 11)])
            case .cameraOff:
                box(2.5, 5, 11, 10); closed([(13.5, 9), (17.5, 6.5), (17.5, 13.5), (13.5, 11)]); line([(3, 3), (17, 17)])
            case .speaker:
                closed([(3.5, 8), (6.5, 8), (10.5, 5), (10.5, 15), (6.5, 12), (3.5, 12)])
                p.move(to: pt(13.5, 7.5)); p.addArc(center: pt(13.5, 10), radius: 2.5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            case .speakerOff:
                closed([(3.5, 8), (6.5, 8), (10.5, 5), (10.5, 15), (6.5, 12), (3.5, 12)])
                line([(13, 8), (17, 12)]); line([(17, 8), (13, 12)])
            case .cursor, .select:
                closed([(5, 3.5), (15.5, 9), (10.9, 10.2), (8.8, 15)])
            case .cursorMotion:
                closed([(7.5, 3.5), (16.5, 8.5), (12.6, 9.5), (10.8, 13.8)]); line([(3, 9), (5, 9)]); line([(3, 12.5), (6.5, 12.5)])
            case .portrait:
                box(6, 3, 8, 14)
            case .shapeCircle:
                circle(10, 10, 6.5)
            case .shapeRounded:
                box(3.5, 3.5, 13, 13, 4)
            case .shapeWide:
                box(2.5, 5.5, 15, 9)
            case .noFrame:
                box(3, 5, 14, 10); line([(4, 16.5), (16, 3.5)])
            case .aspect:
                box(3, 5.5, 14, 9)
            case .crop:
                line([(6, 2.5), (6, 14), (17.5, 14)]); line([(2.5, 6), (14, 6), (14, 17.5)])

            // MARK: Editor objects
            case .film:
                box(2.5, 5, 11, 10); closed([(13.5, 9), (17.5, 6.5), (17.5, 13.5), (13.5, 11)])
            case .scene, .image, .photoAdd:
                box(3, 4, 14, 12); circle(7.5, 8.5, 1.3); line([(3.5, 14.5), (7.5, 10.5), (10.5, 13.5), (12.5, 11.5), (16.5, 15.5)])
                if kind == .photoAdd { line([(15.5, 1.5), (15.5, 5.5)]); line([(13.5, 3.5), (17.5, 3.5)]) }
            case .opening:
                box(3, 4, 14, 12); closed([(8.5, 7.5), (12.5, 10), (8.5, 12.5)])
            case .text:
                line([(5, 5.5), (5, 4), (15, 4), (15, 5.5)]); line([(10, 4), (10, 16)]); line([(8, 16), (12, 16)])
            case .subtitle:
                box(2.5, 4.5, 15, 11); line([(6, 11.5), (10, 11.5)]); line([(12, 11.5), (14, 11.5)]); line([(6, 8.5), (14, 8.5)])
            case .shape:
                circle(7.5, 8, 4); box(9, 9.5, 7.5, 7, 1.5)
            case .line:
                line([(3.5, 10), (16.5, 10)])
            case .layers, .stack:
                closed([(10, 3.5), (17, 7.3), (10, 11.1), (3, 7.3)]); line([(3, 11.2), (10, 15), (17, 11.2)])
            case .layout, .box:
                box(3, 4, 14, 12); box(6, 7, 8, 6, 1)
            case .grid:
                box(3, 3, 14, 14); line([(7.7, 3), (7.7, 17)]); line([(12.3, 3), (12.3, 17)]); line([(3, 7.7), (17, 7.7)]); line([(3, 12.3), (17, 12.3)])
            case .zoom:
                circle(8.5, 8.5, 5); line([(12.3, 12.3), (16.5, 16.5)]); line([(8.5, 6.5), (8.5, 10.5)]); line([(6.5, 8.5), (10.5, 8.5)])
            case .cube:
                closed([(10, 3), (16.5, 6.5), (16.5, 13.5), (10, 17), (3.5, 13.5), (3.5, 6.5)]); line([(3.5, 6.5), (10, 10), (16.5, 6.5)]); line([(10, 10), (10, 17)])
            case .spotlight, .target:
                line([(3.5, 7), (3.5, 4.5), (4.5, 3.5), (7, 3.5)]); line([(13, 3.5), (15.5, 3.5), (16.5, 4.5), (16.5, 7)])
                line([(16.5, 13), (16.5, 15.5), (15.5, 16.5), (13, 16.5)]); line([(7, 16.5), (4.5, 16.5), (3.5, 15.5), (3.5, 13)])
                circle(10, 10, 2.5)
            case .drop:
                p.move(to: pt(10, 3.5)); p.addCurve(to: pt(14.5, 11.5), control1: pt(13, 7.1), control2: pt(14.5, 9.6))
                p.addArc(center: pt(10, 11.5), radius: 4.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                p.addCurve(to: pt(10, 3.5), control1: pt(5.5, 9.6), control2: pt(7, 7.1))
            case .waveform:
                line([(3, 8.5), (3, 11.5)]); line([(6, 6), (6, 14)]); line([(9, 3.5), (9, 16.5)]); line([(12, 7), (12, 13)]); line([(15, 5), (15, 15)]); line([(17.5, 8.5), (17.5, 11.5)])
            case .sparkle:
                p.move(to: pt(10, 3.5)); p.addCurve(to: pt(16.5, 10), control1: pt(10.6, 6.8), control2: pt(13.2, 9.4))
                p.addCurve(to: pt(10, 16.5), control1: pt(13.2, 10.6), control2: pt(10.6, 13.2))
                p.addCurve(to: pt(3.5, 10), control1: pt(9.4, 13.2), control2: pt(6.8, 10.6))
                p.addCurve(to: pt(10, 3.5), control1: pt(6.8, 9.4), control2: pt(9.4, 6.8))
            case .wand:
                line([(4, 16), (12.5, 7.5)]); line([(11, 6), (14, 9)])
                line([(14.5, 2.5), (14.5, 5)]); line([(13.25, 3.75), (15.75, 3.75)]); line([(16.5, 9), (16.5, 11)]); line([(15.5, 10), (17.5, 10)])
            case .eye:
                p.move(to: pt(2.5, 10)); p.addQuadCurve(to: pt(17.5, 10), control: pt(10, 2)); p.addQuadCurve(to: pt(2.5, 10), control: pt(10, 18)); circle(10, 10, 2.2)
            case .eyeOff:
                p.move(to: pt(2.5, 10)); p.addQuadCurve(to: pt(17.5, 10), control: pt(10, 2)); p.addQuadCurve(to: pt(2.5, 10), control: pt(10, 18)); line([(4, 16), (16, 4)])
            case .radius:
                p.move(to: pt(4, 16)); p.addLine(to: pt(4, 9)); p.addArc(center: pt(9, 9), radius: 5, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false); p.addLine(to: pt(16, 4))
            }
            return p.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }

        /// Faces (soft fills) and accents (solid marks) per glyph, on the
        /// same 20-unit grid as the outlines.
        static func addDetail(kind: Kind, layer: Layer, to p: inout Path) {
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            func poly(_ points: [(CGFloat, CGFloat)]) {
                guard let f = points.first else { return }
                p.move(to: pt(f.0, f.1)); for (x, y) in points.dropFirst() { p.addLine(to: pt(x, y)) }; p.closeSubpath()
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 2) {
                p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
            }
            let face = layer == .face
            switch kind {
            case .magnet:
                if face {
                    p.move(to: pt(3.5, 7)); p.addLine(to: pt(8.5, 7)); p.addLine(to: pt(8.5, 10.5))
                    p.addArc(center: pt(10, 10.5), radius: 1.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                    p.addLine(to: pt(11.5, 7)); p.addLine(to: pt(16.5, 7)); p.addLine(to: pt(16.5, 10.5))
                    p.addArc(center: pt(10, 10.5), radius: 6.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false); p.closeSubpath()
                } else {
                    box(3.5, 3.5, 5, 3.5, 1); box(11.5, 3.5, 5, 3.5, 1)
                }
            case .eye:
                if face { p.move(to: pt(2.5, 10)); p.addQuadCurve(to: pt(17.5, 10), control: pt(10, 2)); p.addQuadCurve(to: pt(2.5, 10), control: pt(10, 18)) }
                else { circle(10, 10, 2.2) }
            case .eyeOff:
                if face { p.move(to: pt(2.5, 10)); p.addQuadCurve(to: pt(17.5, 10), control: pt(10, 2)); p.addQuadCurve(to: pt(2.5, 10), control: pt(10, 18)) }
            case .scene, .image, .photoAdd:
                if face { poly([(3.5, 14.5), (7.5, 10.5), (10.5, 13.5), (12.5, 11.5), (16.5, 15.5), (16, 16), (4, 16)]) }
                else { circle(7.5, 8.5, 1.5) }
            case .fit:
                if face { box(5, 6.5, 10, 7, 1.5) }
            case .display:
                if face { box(2.5, 4, 15, 10) }
            case .window:
                if face { p.addPath(Path(roundedRect: CGRect(x: 3, y: 4, width: 14, height: 3.5), cornerRadii: RectangleCornerRadii(topLeading: 2, bottomLeading: 0, bottomTrailing: 0, topTrailing: 2))) }
                else { circle(5.5, 5.8, 0.8); circle(7.7, 5.8, 0.8) }
            case .camera, .film, .cameraOff:
                if face { box(2.5, 5, 11, 10) }
            case .opening:
                if face { box(3, 4, 14, 12) } else { poly([(8.5, 7.5), (12.5, 10), (8.5, 12.5)]) }
            case .microphone:
                if face { box(7.5, 3, 5, 9, 2.5) }
            case .folder:
                if face { box(3, 6.8, 14, 9.2, 1.5) }
            case .trash:
                if face { poly([(5.5, 6), (6.2, 15.5), (13.8, 15.5), (14.5, 6)]) }
            case .subtitle:
                if face { box(2.5, 4.5, 15, 11) }
            case .note, .paste:
                if face { box(kind == .note ? 4 : 5, kind == .note ? 3.5 : 4.5, kind == .note ? 12 : 10, kind == .note ? 13 : 12) }
            case .layers, .stack:
                if face { poly([(10, 3.5), (17, 7.3), (10, 11.1), (3, 7.3)]) }
            case .cube:
                if face { poly([(10, 3), (16.5, 6.5), (10, 10), (3.5, 6.5)]) }
            case .zoom, .search:
                if face { circle(8.5, 8.5, 5) }
            case .clock, .checkCircle, .clear, .info, .noSymbol, .shapeCircle:
                if face { circle(10, 10, kind == .info ? 7 : 6.5) }
                else if kind == .clock { circle(10, 10, 0.9) }
            case .globe:
                if face { circle(10, 10, 7) }
            case .speaker, .speakerOff:
                if face { poly([(3.5, 8), (6.5, 8), (10.5, 5), (10.5, 15), (6.5, 12), (3.5, 12)]) }
            case .bell:
                if face { p.move(to: pt(4.5, 14)); p.addLine(to: pt(5.5, 12.5)); p.addLine(to: pt(5.5, 9))
                    p.addArc(center: pt(10, 9), radius: 4.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: pt(14.5, 12.5)); p.addLine(to: pt(15.5, 14)); p.closeSubpath() }
            case .shield:
                if face { p.move(to: pt(10, 3)); p.addLine(to: pt(16, 5.5)); p.addLine(to: pt(16, 10))
                    p.addCurve(to: pt(10, 17), control1: pt(16, 13.5), control2: pt(13.4, 16)); p.addCurve(to: pt(4, 10), control1: pt(6.6, 16), control2: pt(4, 13.5))
                    p.addLine(to: pt(4, 5.5)); p.closeSubpath() }
            case .warning:
                if face { poly([(10, 3), (17, 15.8), (3, 15.8)]) }
            case .person:
                if face { circle(10, 7, 3) }
            case .pin:
                if face { circle(10, 8.5, 5.5) } else { circle(10, 8.5, 1.6) }
            case .bookmark:
                if face { poly([(5.5, 3.5), (14.5, 3.5), (14.5, 16.5), (10, 13), (5.5, 16.5)]) }
            case .record:
                if !face { circle(10, 10, 3.2) }
            case .target, .spotlight:
                if face { box(3.5, 3.5, 13, 13, 1.5) } else { circle(10, 10, 1.4) }
            case .cursor, .select:
                if face { poly([(5, 3.5), (15.5, 9), (10.9, 10.2), (8.8, 15)]) }
            case .cursorMotion:
                if face { poly([(7.5, 3.5), (16.5, 8.5), (12.6, 9.5), (10.8, 13.8)]) }
            case .layout, .box:
                if face { box(6, 7, 8, 6, 1) }
            case .presets:
                if face { box(3.5, 4, 5.5, 5.5, 1.5) }
            case .scissors:
                if face { circle(6, 14.5, 2.5); circle(14, 14.5, 2.5) }
            case .shape:
                if face { circle(7.5, 8, 4) }
            case .star:
                if face {
                    var points: [(CGFloat, CGFloat)] = []
                    for i in 0..<10 { let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5; let r: CGFloat = i % 2 == 0 ? 6.8 : 2.9; points.append((10 + cos(a) * r, 10.6 + sin(a) * r)) }
                    poly(points)
                }
            case .duplicate:
                if face { box(7, 7, 9.5, 9.5) }
            case .feedback:
                if face { box(3.5, 4, 13, 9.5) }
            case .cup:
                if face { p.move(to: pt(4, 8)); p.addLine(to: pt(14, 8)); p.addLine(to: pt(14, 12))
                    p.addArc(center: pt(10, 12), radius: 4, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false); p.closeSubpath() }
            case .appearance, .halfCircle:
                if !face { p.move(to: pt(10, 3.5)); p.addArc(center: pt(10, 10), radius: 6.5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true); p.closeSubpath() }
            case .sun:
                if face { circle(10, 10, 3.2) }
            case .moon:
                if face { p.move(to: pt(12.4, 3.9))
                    p.addCurve(to: pt(16.1, 12.4), control1: pt(9.4, 6.2), control2: pt(11.4, 12.6))
                    p.addCurve(to: pt(3.5, 10), control1: pt(14.2, 17.6), control2: pt(4.6, 16.8))
                    p.addCurve(to: pt(12.4, 3.9), control1: pt(3.2, 6.3), control2: pt(7.6, 3.2)) }
            case .sparkle:
                if face { p.move(to: pt(10, 3.5)); p.addCurve(to: pt(16.5, 10), control1: pt(10.6, 6.8), control2: pt(13.2, 9.4))
                    p.addCurve(to: pt(10, 16.5), control1: pt(13.2, 10.6), control2: pt(10.6, 13.2))
                    p.addCurve(to: pt(3.5, 10), control1: pt(9.4, 13.2), control2: pt(6.8, 10.6))
                    p.addCurve(to: pt(10, 3.5), control1: pt(6.8, 9.4), control2: pt(9.4, 6.8)) }
            case .wand:
                if !face { poly([(14.5, 1.8), (15.2, 3.05), (16.45, 3.75), (15.2, 4.45), (14.5, 5.7), (13.8, 4.45), (12.55, 3.75), (13.8, 3.05)]) }
            case .drop:
                if face { p.move(to: pt(10, 3.5)); p.addCurve(to: pt(14.5, 11.5), control1: pt(13, 7.1), control2: pt(14.5, 9.6))
                    p.addArc(center: pt(10, 11.5), radius: 4.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                    p.addCurve(to: pt(10, 3.5), control1: pt(5.5, 9.6), control2: pt(7, 7.1)) }
            case .overlayStack:
                if face { box(3.5, 7, 10.5, 9) } else { circle(7, 10.4, 1.1) }
            case .regionBlur:
                if face {
                    p.move(to: pt(10, 3.5)); p.addArc(center: pt(10, 10), radius: 6.5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false); p.closeSubpath()
                } else {
                    for (x, y, r) in [(12.4, 6.6, 0.8), (15.0, 9.2, 0.8), (12.6, 11.2, 0.8), (14.6, 13.6, 0.8), (11.6, 14.6, 0.7)] as [(CGFloat, CGFloat, CGFloat)] { circle(x, y, r) }
                }
            case .keyboard:
                if face { box(2.5, 5, 15, 10) }
            case .editorLayout:
                if face { box(3, 12.5, 14, 3.5, 1.5) }
            case .lens:
                if face { circle(10, 10, 6.5) } else { circle(10, 10, 1.2) }
            case .eyedropper:
                if face { poly([(11, 5), (15, 9), (8, 16), (4, 16), (4, 12)]) }
            case .pencil:
                if face { poly([(12.5, 4.5), (15.5, 7.5), (8, 15), (5, 15), (5, 12)]) }
            case .settings, .sliders:
                if !face { circle(13.5, 6, 1.6); circle(6.5, 14, 1.6) }
            case .portrait:
                if face { box(6, 3, 8, 14) }
            case .shapeRounded:
                if face { box(3.5, 3.5, 13, 13, 4) }
            case .shapeWide, .aspect:
                if face { box(kind == .aspect ? 3 : 2.5, 5.5, kind == .aspect ? 14 : 15, 9) }
            case .sidebar:
                if face { p.addPath(Path(roundedRect: CGRect(x: 3, y: 4, width: 5, height: 12), cornerRadii: RectangleCornerRadii(topLeading: 2, bottomLeading: 2, bottomTrailing: 0, topTrailing: 0))) }
            case .grid:
                if face { box(3, 3, 4.7, 4.7, 2) }
            case .external:
                if face { box(4, 7, 9, 9, 1.5) }
            case .code, .text, .line, .waveform, .list, .chevron, .chevronLeft, .chevronDown, .chevronUp:
                break
            default:
                break
            }
        }
    }
}
