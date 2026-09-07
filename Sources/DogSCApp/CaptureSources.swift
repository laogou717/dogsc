import AppKit
import CoreText
import QuartzCore
import RecorderCore
import ScreenCaptureKit
import SwiftUI

let captureSelectionAccent = RecorderStyle.mint
let captureSelectionAccentNSColor = NSColor(
    calibratedRed: 0.22,
    green: 0.70,
    blue: 0.47,
    alpha: 1
)

// Capture controls use an opaque silver surface so arbitrary desktop content
// cannot reduce label contrast. Desktop dimming is a separate overlay.
let captureSelectionInkNSColor = NSColor(calibratedWhite: 0.20, alpha: 1)
let captureSelectionSurfaceNSColor = NSColor(calibratedWhite: 0.965, alpha: 1)
let captureSelectionRaisedNSColor = NSColor(calibratedWhite: 0.995, alpha: 1)
let captureSelectionPlatinumNSColor = NSColor(calibratedWhite: 0.24, alpha: 1)

/// AppKit-backed capture selectors cannot use SwiftUI ButtonStyle, but they
/// should still share the same short hover lift and pressed settle as the
/// display/device selectors. Subclasses keep ownership of their materials;
/// this base class changes only the physical response of the existing button.
class CaptureSelectionNativeButton: NSButton {
    private var interactionTrackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let interactionTrackingArea {
            removeTrackingArea(interactionTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        interactionTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerInside = true
        updateCaptureInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        updateCaptureInteractionAppearance()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateCaptureInteractionAppearance()
    }

    func captureInteractionDidChange(hovering: Bool, pressed: Bool) {}

    private func updateCaptureInteractionAppearance() {
        let isInteractive = isEnabled
        let scale: CGFloat = !isInteractive
            ? 1
            : isHighlighted ? 0.965
            : isPointerInside ? 1.012 : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
        )
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut)
        )
        layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        captureInteractionDidChange(
            hovering: isInteractive && isPointerInside,
            pressed: isInteractive && isHighlighted
        )
    }
}

struct CaptureSelectionCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white, RecorderStyle.silver],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.9), lineWidth: 1)
                            .mask {
                                LinearGradient(
                                    colors: [.white, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(RecorderStyle.line, lineWidth: 0.7)
            }
            .shadow(color: RecorderStyle.lift, radius: 18, y: 8)
    }
}

struct CaptureSelectionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(Color(white: configuration.isPressed ? 0.16 : 0.24), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.12), radius: configuration.isPressed ? 2 : 5, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct CaptureSelectionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color(white: 0.25))
            .background(Color(white: configuration.isPressed ? 0.92 : 0.99), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.06), lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.08), radius: configuration.isPressed ? 1 : 4, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension View {
    func captureSelectionCardSurface() -> some View {
        modifier(CaptureSelectionCardSurface())
    }
}
