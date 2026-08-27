import AppKit
import QuartzCore
import SwiftUI

struct RecorderMenuItem {
    enum Kind {
        case action
        case separator
        case info
    }

    let kind: Kind
    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let handler: (() -> Void)?

    static func action(
        _ title: String,
        isOn: Bool = false,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> Self {
        Self(
            kind: .action,
            title: title,
            isOn: isOn,
            isEnabled: isEnabled,
            handler: handler
        )
    }

    static func info(_ title: String) -> Self {
        Self(kind: .info, title: title, isOn: false, isEnabled: false, handler: nil)
    }

    static var separator: Self {
        Self(kind: .separator, title: "", isOn: false, isEnabled: false, handler: nil)
    }
}

private final class RecorderMenuActionBox: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}

final class RecorderMenuButtonNSView: NSButton {
    var hoverCornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = hoverCornerRadius }
    }
    var hoverHighlightOpacity: CGFloat = 0.065
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = hoverCornerRadius
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = hoverCornerRadius
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        let targetColor = hovering
            ? NSColor.white.withAlphaComponent(hoverHighlightOpacity).cgColor
            : NSColor.clear.cgColor
        guard layer?.backgroundColor != targetColor else { return }

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        animation.toValue = targetColor
        animation.duration = 0.14
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
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.identifier = accessibilityIdentifier.map {
            NSUserInterfaceItemIdentifier($0)
        }
        return button
    }

    func updateNSView(_ nsView: RecorderMenuButtonNSView, context: Context) {
        context.coordinator.action = action
        nsView.hoverCornerRadius = cornerRadius
        nsView.hoverHighlightOpacity = highlightOpacity
        nsView.isEnabled = isEnabled
        nsView.setAccessibilityLabel(accessibilityLabel)
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

private struct RecorderMenuTrigger: NSViewRepresentable {
    let items: [RecorderMenuItem]
    let accessibilityLabel: String
    let accessibilityIdentifier: String?
    let cornerRadius: CGFloat
    let highlightOpacity: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    func makeNSView(context: Context) -> RecorderMenuButtonNSView {
        let button = RecorderMenuButtonNSView()
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.hoverCornerRadius = cornerRadius
        button.hoverHighlightOpacity = highlightOpacity
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.identifier = accessibilityIdentifier.map {
            NSUserInterfaceItemIdentifier($0)
        }
        return button
    }

    func updateNSView(_ nsView: RecorderMenuButtonNSView, context: Context) {
        context.coordinator.items = items
        nsView.hoverCornerRadius = cornerRadius
        nsView.hoverHighlightOpacity = highlightOpacity
        nsView.setAccessibilityLabel(accessibilityLabel)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.identifier = accessibilityIdentifier.map {
            NSUserInterfaceItemIdentifier($0)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var items: [RecorderMenuItem]

        init(items: [RecorderMenuItem]) {
            self.items = items
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            for entry in items {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .info:
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                case .action:
                    let item = NSMenuItem(
                        title: entry.title,
                        action: #selector(performMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.state = entry.isOn ? .on : .off
                    item.isEnabled = entry.isEnabled
                    if let handler = entry.handler {
                        item.representedObject = RecorderMenuActionBox(handler: handler)
                    }
                    menu.addItem(item)
                }
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                in: sender
            )

            (sender as? RecorderMenuButtonNSView)?.refreshHoverState()
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? RecorderMenuActionBox)?.handler()
        }
    }
}

struct RecorderPopupMenuButton<Content: View>: View {
    let width: CGFloat
    let items: [RecorderMenuItem]
    let accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    var height: CGFloat = 44
    var cornerRadius: CGFloat = 10
    var highlightOpacity: Double = 0.065
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
                // The AppKit trigger below owns the menu action and accessible
                // name. Its SwiftUI artwork is only a visual label; exposing
                // both creates separate icon/text stops before the real button.
                .accessibilityHidden(true)

            RecorderMenuTrigger(
                items: items,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                cornerRadius: cornerRadius,
                highlightOpacity: highlightOpacity
            )
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
    }
}
