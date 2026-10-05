import AppKit
import Combine
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
/// this base class adds a transient shade within the existing button bounds.
class CaptureSelectionNativeButton: NSButton {
    private var interactionTrackingArea: NSTrackingArea?
    private let interactionShadeLayer = CAShapeLayer()
    private let keyboardFocusLayer = CAShapeLayer()
    private var keyboardFocusObservation: AnyCancellable?
    private var tracksKeyboardFocus = false
    private var hasNativeFocus = false
    private(set) var isPointerInside = false

    var captureKeyboardFocusColor = NSColor.black.withAlphaComponent(0.40) {
        didSet { updateCaptureKeyboardFocusAppearance() }
    }
    var captureKeyboardFocusLineWidth: CGFloat = 1.5 {
        didSet { updateCaptureInteractionShape() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCaptureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCaptureInteraction()
    }

    private func configureCaptureInteraction() {
        wantsLayer = true
        interactionShadeLayer.fillColor = NSColor.clear.cgColor
        interactionShadeLayer.zPosition = 1
        layer?.addSublayer(interactionShadeLayer)
        keyboardFocusLayer.fillColor = NSColor.clear.cgColor
        keyboardFocusLayer.zPosition = 2
        keyboardFocusLayer.opacity = 0
        layer?.addSublayer(keyboardFocusLayer)
        // @Published emits before its stored value changes; use the emitted
        // value so a pointer click clears the cue even if focus stays here.
        keyboardFocusObservation = AppKeyboardFocusVisibility.shared.$isVisible.sink { [weak self] visible in
            self?.updateCaptureKeyboardFocusAppearance(navigationIsVisible: visible)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(captureKeyboardWindowStateDidChange(_:)),
                name: name, object: nil
            )
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(captureAccessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    override var isEnabled: Bool {
        didSet {
            updateCaptureInteractionAppearance()
            updateCaptureKeyboardFocusTracking()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCaptureKeyboardFocusTracking()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            hasNativeFocus = true
            updateCaptureKeyboardFocusAppearance()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            hasNativeFocus = false
            updateCaptureKeyboardFocusAppearance()
        }
        return accepted
    }

    // Native selectors share the existing discrete input observer. Disabled
    // retirement controls release it before their window fades out.
    private func updateCaptureKeyboardFocusTracking() {
        let shouldTrack = window != nil && isEnabled
        if tracksKeyboardFocus != shouldTrack {
            tracksKeyboardFocus = shouldTrack
            if shouldTrack { AppKeyboardFocusVisibility.shared.acquire() }
            else { AppKeyboardFocusVisibility.shared.release() }
        }
        updateCaptureKeyboardFocusAppearance()
    }

    @objc private func captureKeyboardWindowStateDidChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
        updateCaptureKeyboardFocusAppearance()
    }

    private func updateCaptureKeyboardFocusAppearance(navigationIsVisible: Bool? = nil) {
        let visible = isEnabled && hasNativeFocus && window?.isKeyWindow == true
            && (navigationIsVisible ?? AppKeyboardFocusVisibility.shared.isVisible)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyboardFocusLayer.strokeColor = captureKeyboardFocusColor.cgColor
        keyboardFocusLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateCaptureInteractionShape()
    }

    private func updateCaptureInteractionShape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        interactionShadeLayer.frame = bounds
        interactionShadeLayer.path = CGPath(roundedRect: bounds,
            cornerWidth: layer?.cornerRadius ?? 0, cornerHeight: layer?.cornerRadius ?? 0,
            transform: nil)
        let inset = captureKeyboardFocusLineWidth / 2
        let radius = max(0, (layer?.cornerRadius ?? 0) - inset)
        keyboardFocusLayer.frame = bounds
        keyboardFocusLayer.lineWidth = captureKeyboardFocusLineWidth
        keyboardFocusLayer.path = bounds.width > inset * 2 && bounds.height > inset * 2
            ? CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                     cornerWidth: radius, cornerHeight: radius, transform: nil)
            : nil
        CATransaction.commit()
    }

    @objc private func captureAccessibilityDisplayOptionsDidChange(_ notification: Notification) {
        updateCaptureInteractionAppearance()
    }

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
        let pressed = isInteractive && isHighlighted
        let hovering = isInteractive && isPointerInside
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale: CGFloat = !isInteractive || reduceMotion
            ? 1
            : pressed ? 0.985
            : hovering ? 1.008 : 1
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)
        let targetShade = NSColor.black.withAlphaComponent(pressed ? 0.075 : hovering ? 0.025 : 0).cgColor
        let currentTransform = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        let currentShade = interactionShadeLayer.presentation()?.fillColor ?? interactionShadeLayer.fillColor
        let duration = pressed ? 0.09 : 0.15

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.transform = targetTransform
        interactionShadeLayer.fillColor = targetShade
        CATransaction.commit()
        updateCaptureInteractionShape()

        if reduceMotion {
            layer?.removeAnimation(forKey: "capture-button-press")
            interactionShadeLayer.removeAnimation(forKey: "capture-button-shade")
        } else {
            let motion = CABasicAnimation(keyPath: "transform")
            motion.fromValue = NSValue(caTransform3D: currentTransform)
            motion.toValue = NSValue(caTransform3D: targetTransform)
            motion.duration = duration
            motion.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(motion, forKey: "capture-button-press")
            let shade = CABasicAnimation(keyPath: "fillColor")
            shade.fromValue = currentShade
            shade.toValue = targetShade
            shade.duration = duration
            shade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            interactionShadeLayer.add(shade, forKey: "capture-button-shade")
        }
        captureInteractionDidChange(hovering: hovering, pressed: pressed)
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label.foregroundStyle(.white)
            .background(Color(white: pressed ? 0.16 : 0.24), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 0.75) }
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 12), color: .white.opacity(0.65))
            .shadow(color: .black.opacity(0.12), radius: pressed ? 2 : 5, y: 3)
            .modifier(RecorderPressFeedback(isPressed: pressed, cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct CaptureSelectionSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label.foregroundStyle(Color(white: 0.25))
            .background(Color(white: pressed ? 0.92 : 0.99), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.06), lineWidth: 0.75) }
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.08), radius: pressed ? 1 : 4, y: 2)
            .modifier(RecorderPressFeedback(isPressed: pressed, cornerRadius: 12))
    }
}

extension View {
    func captureSelectionCardSurface() -> some View {
        modifier(CaptureSelectionCardSurface())
    }
}
