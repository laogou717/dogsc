import AppKit
import Combine
import QuartzCore
import SwiftUI

struct RecorderMenuItem {
    enum Kind {
        case action
        case separator
        case info
    }

    var systemImage: String? = nil
    var detail: String? = nil
    let kind: Kind
    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let handler: (() -> Void)?

    static func action(
        _ title: String,
        systemImage: String? = nil,
        detail: String? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> Self {
        Self(
            systemImage: systemImage,
            detail: detail.map { appLocalized($0) },
            kind: .action,
            title: appLocalized(title),
            isOn: isOn,
            isEnabled: isEnabled,
            handler: handler
        )
    }

    static func info(_ title: String) -> Self {
        Self(kind: .info, title: appLocalized(title), isOn: false, isEnabled: false, handler: nil)
    }

    static var separator: Self {
        Self(kind: .separator, title: "", isOn: false, isEnabled: false, handler: nil)
    }
}

final class RecorderMenuButtonNSView: NSButton {
    var onPressChange: ((Bool) -> Void)?
    private let keyboardFocusLayer = CAShapeLayer()
    private var keyboardFocusObservation: AnyCancellable?
    private var tracksKeyboardFocus = false
    private var hasNativeFocus = false
    // Artwork belongs to SwiftUI; AppKit owns first-click and mouse tracking only.
    override func draw(_ dirtyRect: NSRect) {}
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onPressChange?(true)
        defer { onPressChange?(false) }
        super.mouseDown(with: event)
    }

    var hoverCornerRadius: CGFloat = 10 {
        didSet { updateHoverShape() }
    }
    var hoverHighlightOpacity: CGFloat = 0.065
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = hoverCornerRadius
        layer?.cornerCurve = .continuous
        configureKeyboardFocusCue()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = hoverCornerRadius
        layer?.cornerCurve = .continuous
        configureKeyboardFocusCue()
    }

    private func configureKeyboardFocusCue() {
        keyboardFocusLayer.fillColor = NSColor.clear.cgColor
        keyboardFocusLayer.strokeColor = RecorderStyle.chromeNSColor.withAlphaComponent(0.62).cgColor
        keyboardFocusLayer.lineWidth = 1.5
        keyboardFocusLayer.opacity = 0
        layer?.addSublayer(keyboardFocusLayer)
        keyboardFocusObservation = AppKeyboardFocusVisibility.shared.$isVisible.sink { [weak self] visible in
            self?.updateKeyboardFocusCue(navigationIsVisible: visible)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self,
                selector: #selector(keyboardFocusWindowDidChange(_:)), name: name, object: nil)
        }
    }

    override var isEnabled: Bool {
        didSet { updateKeyboardFocusTracking() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasNativeFocus = true; updateKeyboardFocusCue() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { hasNativeFocus = false; updateKeyboardFocusCue() }
        return accepted
    }

    private func updateKeyboardFocusTracking() {
        let shouldTrack = window != nil && isEnabled
        if tracksKeyboardFocus != shouldTrack {
            tracksKeyboardFocus = shouldTrack
            if shouldTrack { AppKeyboardFocusVisibility.shared.acquire() }
            else { AppKeyboardFocusVisibility.shared.release() }
        }
        updateKeyboardFocusCue()
    }

    @objc private func keyboardFocusWindowDidChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
        updateKeyboardFocusCue()
    }

    private func updateKeyboardFocusCue(navigationIsVisible: Bool? = nil) {
        let visible = isEnabled && hasNativeFocus && window?.isKeyWindow == true
            && (navigationIsVisible ?? AppKeyboardFocusVisibility.shared.isVisible)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyboardFocusLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            keyboardFocusLayer.strokeColor = RecorderStyle.chromeNSColor.withAlphaComponent(0.62).cgColor
            refreshHoverState()
        }
    }

    override func layout() {
        super.layout()
        updateHoverShape()
    }

    private func updateHoverShape() {
        layer?.cornerRadius = hoverCornerRadius
        let isCircle = bounds.width > 0 && abs(bounds.width - bounds.height) < 0.5
            && hoverCornerRadius >= bounds.height / 2
        layer?.cornerCurve = isCircle ? .circular : .continuous
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyboardFocusLayer.frame = bounds
        let inset: CGFloat = 0.75
        let radius = max(0, hoverCornerRadius - inset)
        keyboardFocusLayer.path = bounds.width > inset * 2 && bounds.height > inset * 2
            ? CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                     cornerWidth: radius, cornerHeight: radius, transform: nil)
            : nil
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateKeyboardFocusTracking()
        window?.acceptsMouseMovedEvents = true
        if window == nil, let hoverObservation {
            NotificationCenter.default.removeObserver(hoverObservation)
            self.hoverObservation = nil
        } else if window != nil {
            observeSharedHover()
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshHoverState()
        }
    }

    /// A missed exit event must not leave a control lit. Whenever the pointer
    /// crosses any of these controls, all of them re-read where it really is.
    private static let hoverDidChange = Notification.Name("cn.laogou.dogsc.recorder-hover-changed")
    private var hoverObservation: NSObjectProtocol?

    override func mouseEntered(with event: NSEvent) {
        observeSharedHover()
        setHoverAppearance(true)
        NotificationCenter.default.post(name: Self.hoverDidChange, object: self)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverAppearance(false)
        NotificationCenter.default.post(name: Self.hoverDidChange, object: self)
    }

    private func observeSharedHover() {
        guard hoverObservation == nil else { return }
        hoverObservation = NotificationCenter.default.addObserver(
            forName: Self.hoverDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            // Re-reading the pointer is idempotent, so the sender may join in.
            MainActor.assumeIsolated { self?.refreshHoverState() }
        }
    }

    func refreshHoverState() {
        guard let window else {
            setHoverAppearance(false)
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        let hovering = bounds.contains(localPoint)
        setHoverAppearance(hovering)
    }

    private func setHoverAppearance(_ hovering: Bool) {
        let targetColor = hovering && isEnabled
            // The hover wash is light on the dark glass, and a little stronger
            // than it was on white so it reads at the same strength.
            ? RecorderStyle.chromeNSColor.withAlphaComponent(hoverHighlightOpacity * 1.6).cgColor
            : NSColor.clear.cgColor
        guard layer?.backgroundColor != targetColor else { return }

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        animation.toValue = targetColor
        animation.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "recorderMenuHover")
        layer?.backgroundColor = targetColor
    }
}

struct RecorderActionTrigger: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let action: () -> Void
    let accessibilityLabel: String
    var isEnabled = true
    var accessibilityIdentifier: String? = nil
    var cornerRadius: CGFloat = 10
    var highlightOpacity: Double = 0.075
    var onPressChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> RecorderMenuButtonNSView {
        let button = RecorderMenuButtonNSView()
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction(_:))
        // A selector overlay may become key immediately after this action. Send
        // only on mouse-up so the opening click cannot be stolen mid gesture.
        button.sendAction(on: .leftMouseUp)
        button.hoverCornerRadius = cornerRadius
        button.hoverHighlightOpacity = highlightOpacity
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(appLocalized(accessibilityLabel))
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.identifier = accessibilityIdentifier.map {
            NSUserInterfaceItemIdentifier($0)
        }
        return button
    }

    func updateNSView(_ nsView: RecorderMenuButtonNSView, context: Context) {
        _ = locale
        context.coordinator.action = action
        nsView.onPressChange = onPressChange
        nsView.hoverCornerRadius = cornerRadius
        nsView.hoverHighlightOpacity = highlightOpacity
        nsView.isEnabled = isEnabled
        nsView.setAccessibilityLabel(appLocalized(accessibilityLabel))
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.identifier = accessibilityIdentifier.map {
            NSUserInterfaceItemIdentifier($0)
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            action()
        }
    }
}
