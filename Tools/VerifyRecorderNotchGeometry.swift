import Foundation
import CoreGraphics

@main
struct VerifyNotchGeometry {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let left = CGRect(x: 0, y: 924, width: 645.5, height: 32)
        let right = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)
        let geometry = RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 32,
            auxiliaryLeft: left, auxiliaryRight: right)!
        check(geometry.notchRect == CGRect(x: 645.5, y: 924, width: 179, height: 32), "Use actual notch gap")
        check(geometry.collapsedSize == CGSize(width: 179, height: 38), "Expose six-point lip")
        check(geometry.activationRect == CGRect(x: 633.5, y: 912, width: 203, height: 44), "Reachable activation zone")
        check(geometry.expandedSize(for: CGSize(width: 374, height: 56)) == CGSize(width: 394, height: 98), "Reserve top inset and control padding")
        let frame = geometry.windowFrame(for: CGSize(width: 374, height: 56))
        check(frame == CGRect(x: 538, y: 858, width: 394, height: 98), "Top-anchor expanded canvas")
        check(frame.maxY == screen.maxY && frame.midX == geometry.notchRect.midX, "Stay aligned to notch")
        let interaction = geometry.expandedInteractionRect(for: CGSize(width: 374, height: 56))
        check(interaction == CGRect(x: 526, y: 846, width: 418, height: 110), "Bound generous hover region")
        check(interaction.contains(geometry.activationRect), "No gap between activation and expanded hover")
        check(screen.contains(interaction), "Do not claim offscreen hover")
        let offset = CGVector(dx: -1920, dy: 100)
        let negative = RecorderNotchGeometry(screenFrame: screen.offsetBy(dx: offset.dx, dy: offset.dy), safeAreaTop: 32,
            auxiliaryLeft: left.offsetBy(dx: offset.dx, dy: offset.dy),
            auxiliaryRight: right.offsetBy(dx: offset.dx, dy: offset.dy))!
        check(negative.notchRect == geometry.notchRect.offsetBy(dx: offset.dx, dy: offset.dy), "Support nonzero display origin")
        check(negative.windowFrame(for: CGSize(width: 374, height: 56)) == frame.offsetBy(dx: offset.dx, dy: offset.dy), "Translate expanded canvas exactly")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 0, auxiliaryLeft: left, auxiliaryRight: right) == nil, "No artificial notch on ordinary display")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 32, auxiliaryLeft: nil, auxiliaryRight: nil) == nil, "Require native auxiliary areas")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: nil) == nil, "Require both sides")
        let touching = CGRect(x: left.maxX, y: 924, width: screen.maxX - left.maxX, height: 32)
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: touching) == nil, "Require physical gap")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 32, auxiliaryLeft: left.offsetBy(dx: 10, dy: 0), auxiliaryRight: right) == nil, "Reject unrelated top rectangles")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 32, auxiliaryLeft: left.offsetBy(dx: 0, dy: -10), auxiliaryRight: right) == nil, "Reject inconsistent vertical band")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: 956, auxiliaryLeft: left, auxiliaryRight: right) == nil, "Reject impossible safe area")
        check(RecorderNotchGeometry(screenFrame: screen, safeAreaTop: .infinity, auxiliaryLeft: left, auxiliaryRight: right) == nil, "Reject nonfinite inset")
        check(RecorderNotchGeometry(screenFrame: .zero, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right) == nil, "Reject empty display")
        check(geometry.expandedSize(for: CGSize(width: CGFloat.nan, height: -10)) == CGSize(width: 179, height: 42), "Keep malformed measured size finite")
        let data = try JSONSerialization.data(withJSONObject: ["passed": checks, "status": "passed", "screen": "fixture: 1470x956; notch 179x32", "metrics": ["horizontalInset": 10, "contentTopInset": 4, "contentBottomInset": 6, "collapsedPeekHeight": 6], "expandedFrameFor374x56": ["x": 538, "y": 858, "width": 394, "height": 98]], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
