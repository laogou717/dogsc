import SwiftUI

/// The recorder's 18-point drawing grid, rounded joins and open silhouettes.
/// Settings and its small actions share one stroke instead of mixing symbol weights.
struct AppLineIcon: View {
    enum Kind: Equatable {
        case settings, sliders, record, shield, info, appearance, sun, moon
        case bell, speaker, box, download, sparkle, display, window, microphone
        case cursor, camera, folder, check, checkCircle, warning, refresh
        case code, feedback, cup, external, chevron, person, close, arrowLeft
        // Editor tools and toolbar actions.
        case scene, opening, zoom, cursorMotion, undo, redo, plus, trash, pencil
        case share, chevronDown, layers
        case play, pause, stop, previousFrame, nextFrame, scissors, minus
        case waveform, eye, eyeOff, fit, grid, crop, layout, film
    }

    let kind: Kind
    var size: CGFloat = 18

    var body: some View {
        Drawing(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct Drawing: Shape {
        let kind: Kind

        func path(in rect: CGRect) -> Path {
            var p = Path()
            func line(_ points: [(CGFloat, CGFloat)]) {
                guard let first = points.first else { return }
                p.move(to: CGPoint(x: first.0, y: first.1))
                for (x, y) in points.dropFirst() { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                p.addEllipse(in: CGRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2))
            }
            func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
                p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
            }
            switch kind {
            case .settings:
                for i in 0..<48 {
                    let angle = CGFloat(i) * .pi / 24 - .pi / 2
                    let radius: CGFloat = [0, 1, 4, 5].contains(i % 6) ? 6 : 7.5
                    let point = CGPoint(x: 9 + cos(angle)*radius, y: 9 + sin(angle)*radius)
                    if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
                p.closeSubpath(); circle(9, 9, 2.5)
            case .sliders:
                line([(2, 4), (5, 4)]); circle(7, 4, 1.8); line([(9, 4), (16, 4)])
                line([(2, 9), (10, 9)]); circle(12, 9, 1.8); line([(14, 9), (16, 9)])
                line([(2, 14), (4, 14)]); circle(6, 14, 1.8); line([(8, 14), (16, 14)])
            case .record:
                circle(9, 9, 7); circle(9, 9, 2.6)
            case .shield:
                p.move(to: CGPoint(x: 9, y: 1.5))
                for point in [CGPoint(x: 15, y: 4), CGPoint(x: 15, y: 9)] { p.addLine(to: point) }
                p.addQuadCurve(to: CGPoint(x: 9, y: 16.5), control: CGPoint(x: 15, y: 14))
                p.addQuadCurve(to: CGPoint(x: 3, y: 9), control: CGPoint(x: 3, y: 14))
                p.addLine(to: CGPoint(x: 3, y: 4)); p.closeSubpath()
                rounded(6.8, 8, 4.4, 4, 0.8)
                p.move(to: CGPoint(x: 7.5, y: 8)); p.addCurve(to: CGPoint(x: 10.5, y: 8), control1: CGPoint(x: 7.5, y: 4.5), control2: CGPoint(x: 10.5, y: 4.5))
            case .info:
                circle(9, 9, 7); circle(9, 5, 0.35); line([(8, 8), (9, 8), (9, 13)]); line([(7.7, 13), (10.3, 13)])
            case .appearance:
                circle(9, 9, 6.7); line([(9, 2.3), (9, 15.7)])
                line([(5, 4), (5, 14)]); line([(7, 3), (7, 15)])
            case .sun:
                circle(9, 9, 3.2)
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    line([(9+cos(a)*5.5, 9+sin(a)*5.5), (9+cos(a)*7.4, 9+sin(a)*7.4)])
                }
            case .moon:
                p.move(to: CGPoint(x: 11, y: 2))
                p.addCurve(to: CGPoint(x: 16, y: 11), control1: CGPoint(x: 6, y: 7), control2: CGPoint(x: 11, y: 13))
                p.addCurve(to: CGPoint(x: 11, y: 2), control1: CGPoint(x: 10, y: 22), control2: CGPoint(x: -5, y: 7))
            case .bell:
                p.move(to: CGPoint(x: 3, y: 12.5)); p.addQuadCurve(to: CGPoint(x: 4.5, y: 8), control: CGPoint(x: 4.5, y: 11))
                p.addCurve(to: CGPoint(x: 13.5, y: 8), control1: CGPoint(x: 4.5, y: 0.5), control2: CGPoint(x: 13.5, y: 0.5))
                p.addQuadCurve(to: CGPoint(x: 15, y: 12.5), control: CGPoint(x: 13.5, y: 11))
                p.closeSubpath(); line([(9, 1.5), (9, 2.5)])
                p.move(to: CGPoint(x: 7, y: 15)); p.addQuadCurve(to: CGPoint(x: 11, y: 15), control: CGPoint(x: 9, y: 17))
            case .speaker:
                line([(2, 6), (5, 6), (9, 2.7), (9, 15.3), (5, 12), (2, 12), (2, 6)])
                p.move(to: CGPoint(x: 12, y: 6)); p.addQuadCurve(to: CGPoint(x: 12, y: 12), control: CGPoint(x: 14.5, y: 9))
                p.move(to: CGPoint(x: 14.5, y: 3.5)); p.addQuadCurve(to: CGPoint(x: 14.5, y: 14.5), control: CGPoint(x: 18.5, y: 9))
            case .box:
                line([(2.5, 5.3), (9, 2), (15.5, 5.3), (15.5, 12.7), (9, 16), (2.5, 12.7), (2.5, 5.3), (9, 9), (15.5, 5.3)])
                line([(9, 9), (9, 16)]); line([(5.8, 3.7), (12, 7.2)])
            case .download:
                line([(9, 1.8), (9, 11)]); line([(5.5, 7.5), (9, 11), (12.5, 7.5)])
                p.move(to: CGPoint(x: 3, y: 9)); p.addLine(to: CGPoint(x: 3, y: 13.5)); p.addQuadCurve(to: CGPoint(x: 5, y: 15.5), control: CGPoint(x: 3, y: 15.5)); p.addLine(to: CGPoint(x: 13, y: 15.5)); p.addQuadCurve(to: CGPoint(x: 15, y: 13.5), control: CGPoint(x: 15, y: 15.5)); p.addLine(to: CGPoint(x: 15, y: 9))
            case .sparkle:
                line([(10.5, 4), (12, 8.5), (16, 10), (12, 11.5), (10.5, 16), (9, 11.5), (5, 10), (9, 8.5), (10.5, 4)])
                line([(4, 1.8), (4, 6.2)]); line([(1.8, 4), (6.2, 4)])
            case .display:
                rounded(2, 2.5, 14, 10, 2); line([(9, 12.5), (9, 15.5)]); line([(5.5, 15.5), (12.5, 15.5)])
            case .window:
                rounded(2, 3, 14, 12, 2); line([(2, 6.5), (16, 6.5)]); circle(4.5, 4.8, 0.2); circle(6.5, 4.8, 0.2)
            case .microphone:
                rounded(6.5, 1.5, 5, 10, 2.5)
                p.move(to: CGPoint(x: 4, y: 8)); p.addCurve(to: CGPoint(x: 14, y: 8), control1: CGPoint(x: 4, y: 16), control2: CGPoint(x: 14, y: 16))
                line([(9, 14), (9, 16.5)]); line([(6, 16.5), (12, 16.5)])
            case .cursor:
                line([(3, 1.5), (14, 9), (9.5, 9.5), (12, 15), (9, 16.5), (6.5, 11), (3, 14), (3, 1.5)])
            case .camera:
                rounded(1.5, 4.5, 10.5, 9, 2); line([(12, 7), (16.5, 4.5), (16.5, 13.5), (12, 11)])
            case .folder:
                p.move(to: CGPoint(x: 2, y: 6)); p.addLine(to: CGPoint(x: 2, y: 4)); p.addQuadCurve(to: CGPoint(x: 4, y: 2.5), control: CGPoint(x: 2, y: 2.5)); for point in [CGPoint(x: 7, y: 2.5), CGPoint(x: 9, y: 4.5), CGPoint(x: 14, y: 4.5)] { p.addLine(to: point) }; p.addQuadCurve(to: CGPoint(x: 16, y: 6.5), control: CGPoint(x: 16, y: 4.5)); p.addLine(to: CGPoint(x: 16, y: 13.5)); p.addQuadCurve(to: CGPoint(x: 14, y: 15.5), control: CGPoint(x: 16, y: 15.5)); p.addLine(to: CGPoint(x: 4, y: 15.5)); p.addQuadCurve(to: CGPoint(x: 2, y: 13.5), control: CGPoint(x: 2, y: 15.5)); p.addLine(to: CGPoint(x: 2, y: 6)); p.addLine(to: CGPoint(x: 12, y: 6))
            case .check, .checkCircle:
                if kind == .checkCircle { circle(9, 9, 7) }
                line([(5, 9), (8, 12), (13, 6)])
            case .warning:
                line([(9, 2), (16.5, 15), (1.5, 15), (9, 2)]); line([(9, 6), (9, 10)]); circle(9, 12.5, 0.3)
            case .refresh:
                p.move(to: CGPoint(x: 3, y: 7)); p.addCurve(to: CGPoint(x: 14.5, y: 4.5), control1: CGPoint(x: 5, y: -0.5), control2: CGPoint(x: 13, y: 1)); line([(14.5, 1.5), (14.5, 5), (11, 5)])
                p.move(to: CGPoint(x: 15, y: 11)); p.addCurve(to: CGPoint(x: 3.5, y: 13.5), control1: CGPoint(x: 13, y: 18.5), control2: CGPoint(x: 5, y: 17)); line([(3.5, 16.5), (3.5, 13), (7, 13)])
            case .code:
                line([(5, 4.5), (1.5, 9), (5, 13.5)]); line([(13, 4.5), (16.5, 9), (13, 13.5)]); line([(10.5, 3), (7.5, 15)])
            case .feedback:
                p.move(to: CGPoint(x: 5, y: 2.5)); p.addLine(to: CGPoint(x: 13, y: 2.5)); p.addQuadCurve(to: CGPoint(x: 16, y: 5.5), control: CGPoint(x: 16, y: 2.5)); p.addLine(to: CGPoint(x: 16, y: 10)); p.addQuadCurve(to: CGPoint(x: 13, y: 13), control: CGPoint(x: 16, y: 13)); for point in [CGPoint(x: 8, y: 13), CGPoint(x: 4, y: 16), CGPoint(x: 4, y: 12.8)] { p.addLine(to: point) }; p.addQuadCurve(to: CGPoint(x: 2, y: 10), control: CGPoint(x: 2, y: 12.5)); p.addLine(to: CGPoint(x: 2, y: 5.5)); p.addQuadCurve(to: CGPoint(x: 5, y: 2.5), control: CGPoint(x: 2, y: 2.5)); line([(5.5, 6.5), (12.5, 6.5)]); line([(5.5, 9.5), (10, 9.5)])
            case .cup:
                p.move(to: CGPoint(x: 3, y: 5)); for point in [CGPoint(x: 12, y: 5), CGPoint(x: 12, y: 10)] { p.addLine(to: point) }; p.addCurve(to: CGPoint(x: 3, y: 10), control1: CGPoint(x: 12, y: 16), control2: CGPoint(x: 3, y: 16)); p.closeSubpath()
                p.move(to: CGPoint(x: 12, y: 6)); p.addCurve(to: CGPoint(x: 12, y: 11), control1: CGPoint(x: 18, y: 4), control2: CGPoint(x: 18, y: 12)); line([(2, 16), (14, 16)]); line([(5, 1.5), (5, 2.5)]); line([(9, 1.5), (9, 2.5)])
            case .external:
                line([(4, 14), (14, 4)]); line([(6, 4), (14, 4), (14, 12)])
            case .chevron:
                line([(6, 3.5), (11.5, 9), (6, 14.5)])
            case .person:
                circle(9, 6, 3)
                p.move(to: CGPoint(x: 2.5, y: 16)); p.addCurve(to: CGPoint(x: 15.5, y: 16), control1: CGPoint(x: 3, y: 10), control2: CGPoint(x: 15, y: 10))
            case .close:
                line([(4.5, 4.5), (13.5, 13.5)]); line([(13.5, 4.5), (4.5, 13.5)])
            case .arrowLeft:
                line([(14.5, 9), (3.5, 9)]); line([(8.5, 4), (3.5, 9), (8.5, 14)])
            case .scene:
                rounded(2, 3.5, 14, 11, 2.5)
                line([(4.8, 12), (8, 8.6), (10.4, 11), (11.8, 9.6), (13.6, 11.6)])
                circle(12.2, 6.6, 1.1)
            case .opening:
                rounded(2, 3, 14, 12, 2.5)
                line([(7.6, 6.6), (11.8, 9), (7.6, 11.4), (7.6, 6.6)])
            case .zoom:
                for (cx, cy, dx, dy) in [(2.5, 2.5, 1.0, 1.0), (15.5, 2.5, -1.0, 1.0),
                                         (15.5, 15.5, -1.0, -1.0), (2.5, 15.5, 1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                    p.move(to: CGPoint(x: cx, y: cy + 3.6 * dy))
                    p.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx + 3.6 * dx, y: cy), radius: 1.6)
                    p.addLine(to: CGPoint(x: cx + 3.6 * dx, y: cy))
                }
                circle(9, 9, 2.4)
            case .cursorMotion:
                line([(7, 2.5), (15.5, 8.2), (11.9, 8.7), (13.8, 13), (11.6, 14), (9.8, 9.8), (7, 12.4), (7, 2.5)])
                line([(1.8, 6.5), (4, 6.5)]); line([(2.6, 10), (4.4, 10)]); line([(1.8, 13.5), (5, 13.5)])
            case .undo, .redo:
                var q = Path()
                q.move(to: CGPoint(x: 7, y: 3.8)); q.addLine(to: CGPoint(x: 3.8, y: 7)); q.addLine(to: CGPoint(x: 7, y: 10.2))
                q.move(to: CGPoint(x: 3.8, y: 7)); q.addLine(to: CGPoint(x: 11, y: 7))
                q.addCurve(to: CGPoint(x: 11, y: 14.2), control1: CGPoint(x: 15.8, y: 7), control2: CGPoint(x: 15.8, y: 14.2))
                q.addLine(to: CGPoint(x: 6.5, y: 14.2))
                p.addPath(kind == .redo ? q.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 18, ty: 0)) : q)
            case .plus:
                line([(9, 3.5), (9, 14.5)]); line([(3.5, 9), (14.5, 9)])
            case .trash:
                line([(2.5, 4.5), (15.5, 4.5)]); line([(6.8, 4.5), (7.4, 2.2), (10.6, 2.2), (11.2, 4.5)])
                line([(4, 4.5), (4.9, 14.4), (6.4, 15.8), (11.6, 15.8), (13.1, 14.4), (14, 4.5)])
                line([(7.4, 7.6), (7.6, 12.6)]); line([(10.6, 7.6), (10.4, 12.6)])
            case .pencil:
                line([(3, 15), (3.6, 11.6), (12, 3.2), (14.8, 6), (6.4, 14.4), (3, 15)]); line([(10.4, 4.8), (13.2, 7.6)])
            case .share:
                line([(9, 11), (9, 2)]); line([(5.5, 5.5), (9, 2), (12.5, 5.5)])
                p.move(to: CGPoint(x: 5.5, y: 8.5)); p.addLine(to: CGPoint(x: 4.5, y: 8.5)); p.addQuadCurve(to: CGPoint(x: 3, y: 10), control: CGPoint(x: 3, y: 8.5)); p.addLine(to: CGPoint(x: 3, y: 14)); p.addQuadCurve(to: CGPoint(x: 4.5, y: 15.5), control: CGPoint(x: 3, y: 15.5)); p.addLine(to: CGPoint(x: 13.5, y: 15.5)); p.addQuadCurve(to: CGPoint(x: 15, y: 14), control: CGPoint(x: 15, y: 15.5)); p.addLine(to: CGPoint(x: 15, y: 10)); p.addQuadCurve(to: CGPoint(x: 13.5, y: 8.5), control: CGPoint(x: 15, y: 8.5)); p.addLine(to: CGPoint(x: 12.5, y: 8.5))
            case .chevronDown:
                line([(4, 6.5), (9, 11.5), (14, 6.5)])
            case .layers:
                line([(9, 2.5), (16, 6.5), (9, 10.5), (2, 6.5), (9, 2.5)]); line([(2, 10.5), (9, 14.5), (16, 10.5)])
            case .play:
                line([(5.5, 3.5), (14, 9), (5.5, 14.5), (5.5, 3.5)])
            case .pause:
                line([(6, 3.5), (6, 14.5)]); line([(12, 3.5), (12, 14.5)])
            case .stop:
                rounded(4, 4, 10, 10, 2)
            case .previousFrame, .nextFrame:
                var q = Path()
                q.move(to: CGPoint(x: 3.5, y: 3.5)); q.addLine(to: CGPoint(x: 3.5, y: 14.5))
                q.move(to: CGPoint(x: 14, y: 3.5)); q.addLine(to: CGPoint(x: 6, y: 9))
                q.addLine(to: CGPoint(x: 14, y: 14.5)); q.closeSubpath()
                p.addPath(kind == .nextFrame ? q.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 18, ty: 0)) : q)
            case .scissors:
                circle(4.5, 4.5, 2.3); circle(4.5, 13.5, 2.3)
                line([(6.3, 6), (15, 14.5)]); line([(6.3, 12), (15, 3.5)])
            case .minus:
                line([(3.5, 9), (14.5, 9)])
            case .waveform:
                for (x, height) in [(2, 3), (5.5, 8), (9, 13), (12.5, 7), (16, 3)] as [(CGFloat, CGFloat)] {
                    line([(x, 9 - height / 2), (x, 9 + height / 2)])
                }
            case .eye, .eyeOff:
                p.move(to: CGPoint(x: 1.5, y: 9))
                p.addCurve(to: CGPoint(x: 16.5, y: 9), control1: CGPoint(x: 5, y: 2), control2: CGPoint(x: 13, y: 2))
                p.addCurve(to: CGPoint(x: 1.5, y: 9), control1: CGPoint(x: 13, y: 16), control2: CGPoint(x: 5, y: 16))
                circle(9, 9, 2.3)
                if kind == .eyeOff { line([(3, 2.5), (15, 15.5)]) }
            case .fit:
                line([(2.5, 3), (2.5, 15)]); line([(15.5, 3), (15.5, 15)])
                line([(5.5, 6), (8.5, 9), (5.5, 12)])
                line([(12.5, 6), (9.5, 9), (12.5, 12)])
            case .grid:
                rounded(2.5, 2.5, 13, 13, 2)
                line([(7, 2.5), (7, 15.5)]); line([(11, 2.5), (11, 15.5)])
                line([(2.5, 7), (15.5, 7)]); line([(2.5, 11), (15.5, 11)])
            case .crop:
                line([(5, 2), (5, 13), (16, 13)])
                line([(2, 5), (13, 5), (13, 16)])
            case .layout:
                rounded(2, 3, 14, 12, 2)
                rounded(5, 6, 8, 6, 1)
            case .film:
                rounded(2, 3, 14, 12, 2)
                line([(5.5, 3), (5.5, 15)]); line([(12.5, 3), (12.5, 15)])
                for y in [CGFloat(7), 11] {
                    line([(2, y), (5.5, y)]); line([(12.5, y), (16, y)])
                }
            }
            return p.applying(CGAffineTransform(scaleX: rect.width / 18, y: rect.height / 18)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
    }
}
