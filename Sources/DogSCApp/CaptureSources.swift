import AppKit
import CoreText
import QuartzCore
import RecorderCore
import ScreenCaptureKit
import SwiftUI

let captureSelectionAccent = Color(red: 0.86, green: 0.62, blue: 0.28)
let captureSelectionAccentNSColor = NSColor(
    calibratedRed: 0.86,
    green: 0.62,
    blue: 0.28,
    alpha: 1
)

let captureSelectionSurfaceNSColor = NSColor(
    calibratedRed: 0.052,
    green: 0.054,
    blue: 0.059,
    alpha: 0.97
)
let captureSelectionRaisedNSColor = NSColor(
    calibratedRed: 0.105,
    green: 0.108,
    blue: 0.114,
    alpha: 0.96
)
let captureSelectionPlatinumNSColor = NSColor(
    calibratedRed: 0.949,
    green: 0.941,
    blue: 0.918,
    alpha: 1
)

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
                            colors: [EditorTheme.cardElevated, EditorTheme.recorderSurface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(EditorTheme.topHighlight, lineWidth: 1)
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
                    .stroke(EditorTheme.hairline, lineWidth: 1)
            }
            .shadow(color: EditorTheme.softShadow, radius: 28, y: 14)
    }
}

struct CaptureSelectionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Color.black.opacity(0.9) : Color.white.opacity(0.3))
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isEnabled ? EditorTheme.platinumAccent : Color.white.opacity(0.055))
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    isEnabled ? Color.white.opacity(0.58) : Color.white.opacity(0.06),
                                    lineWidth: 1
                                )
                        }
                }
                .brightness(isHovered && isEnabled ? 0.035 : 0)
                .shadow(
                    color: isEnabled ? EditorTheme.platinumAccent.opacity(isHovered ? 0.24 : 0.15) : .clear,
                    radius: configuration.isPressed ? 3 : isHovered ? 13 : 10,
                    y: configuration.isPressed ? 1 : isHovered ? 6 : 5
                )
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.975
                        : isHovered ? 1.012 : 1
                )
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
        }
    }
}

struct CaptureSelectionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(
                    Color.white.opacity(
                        !isEnabled ? 0.32
                            : configuration.isPressed ? 0.62 : 0.82
                    )
                )
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            Color.white.opacity(
                                configuration.isPressed ? 0.11
                                    : isHovered && isEnabled ? 0.09 : 0.065
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    Color.white.opacity(
                                        configuration.isPressed ? 0.16
                                            : isHovered && isEnabled ? 0.14 : 0.09
                                    )
                                )
                        }
                }
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.975
                        : isHovered ? 1.012 : 1
                )
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
        }
    }
}

extension View {
    func captureSelectionCardSurface() -> some View {
        modifier(CaptureSelectionCardSurface())
    }
}
