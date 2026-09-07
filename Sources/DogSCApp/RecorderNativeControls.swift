import AppKit
import QuartzCore
import SwiftUI

struct RecorderMenuItem {
    enum Kind {
        case action
        case separator
        case info
    }

    var systemImage: String? = nil
    let kind: Kind
    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let handler: (() -> Void)?

    static func action(
        _ title: String,
        systemImage: String? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> Self {
        Self(
            systemImage: systemImage,
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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = hoverCornerRadius
        layer?.cornerCurve = .continuous
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateHoverShape()
    }

    private func updateHoverShape() {
        layer?.cornerRadius = hoverCornerRadius
        let isCircle = bounds.width > 0 && abs(bounds.width - bounds.height) < 0.5
            && hoverCornerRadius >= bounds.height / 2
        layer?.cornerCurve = isCircle ? .circular : .continuous
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
        window?.acceptsMouseMovedEvents = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshHoverState()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        setHoverAppearance(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverAppearance(false)
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
            ? NSColor.black.withAlphaComponent(hoverHighlightOpacity).cgColor
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
