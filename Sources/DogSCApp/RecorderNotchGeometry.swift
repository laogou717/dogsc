import Foundation
import CoreGraphics

enum RecorderNotchMetrics {
    static let horizontalInset: CGFloat = 10
    static let contentTopInset: CGFloat = 4
    static let contentBottomInset: CGFloat = 6
    static let collapsedPeekHeight: CGFloat = 6

    static func expandedSize(contentSize: CGSize, notchWidth: CGFloat, topInset: CGFloat) -> CGSize {
        let width = contentSize.width.isFinite ? max(contentSize.width, 0) : 0
        let height = contentSize.height.isFinite ? max(contentSize.height, 0) : 0
        return CGSize(width: max(notchWidth, width + 2 * horizontalInset),
            height: topInset + contentTopInset + height + contentBottomInset)
    }
}

/// Screen-space geometry for a real camera cutout. Coordinates use AppKit's
/// bottom-left origin; the notch stays anchored to the full screen's top edge.
struct RecorderNotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchRect: CGRect

    init?(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?
    ) {
        guard Self.isFinitePositive(screenFrame),
              safeAreaTop.isFinite, safeAreaTop > 0,
              safeAreaTop < screenFrame.height,
              let left = auxiliaryLeft, let right = auxiliaryRight,
              Self.isFinitePositive(left), Self.isFinitePositive(right)
        else { return nil }

        // A menu bar alone is not a notch. Both system-provided auxiliary
        // areas must describe the same top safe-area band with a gap between.
        let tolerance: CGFloat = 1
        let bandBottom = screenFrame.maxY - safeAreaTop
        guard abs(left.minX - screenFrame.minX) <= tolerance,
              abs(right.maxX - screenFrame.maxX) <= tolerance,
              abs(left.maxY - screenFrame.maxY) <= tolerance,
              abs(right.maxY - screenFrame.maxY) <= tolerance,
              abs(left.minY - bandBottom) <= tolerance,
              abs(right.minY - bandBottom) <= tolerance,
              left.maxX > screenFrame.minX,
              right.minX < screenFrame.maxX,
              left.maxX < right.minX
        else { return nil }

        self.screenFrame = screenFrame
        notchRect = CGRect(
            x: left.maxX,
            y: bandBottom,
            width: right.minX - left.maxX,
            height: safeAreaTop
        )
    }

    /// Six points below the hardware cutout remain visible and reachable.
    var collapsedSize: CGSize {
        CGSize(width: notchRect.width, height: notchRect.height + RecorderNotchMetrics.collapsedPeekHeight)
    }

    /// The extra lower strip can be reached even when the camera area itself
    /// cannot display content. Do not claim unrelated menu-bar space.
    var activationRect: CGRect {
        CGRect(
            x: notchRect.minX - 12,
            y: notchRect.minY - 12,
            width: notchRect.width + 24,
            height: notchRect.height + 12
        ).intersection(screenFrame)
    }

    func expandedSize(for canvasSize: CGSize) -> CGSize {
        RecorderNotchMetrics.expandedSize(contentSize: canvasSize,
            notchWidth: notchRect.width, topInset: notchRect.height)
    }

    func windowFrame(for canvasSize: CGSize) -> CGRect {
        let size = expandedSize(for: canvasSize)
        return CGRect(
            x: notchRect.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The visible surface uses placementSize while a larger native canvas may
    /// briefly remain for a phase morph. A small margin bridges pointer motion
    /// across the rounded surface edge without leaving an invisible wide trap.
    func expandedInteractionRect(for placementSize: CGSize) -> CGRect {
        windowFrame(for: placementSize)
            .insetBy(dx: -12, dy: -12)
            .intersection(screenFrame)
    }

    private static func isFinitePositive(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.maxX.isFinite
            && rect.minY.isFinite && rect.maxY.isFinite
    }
}
