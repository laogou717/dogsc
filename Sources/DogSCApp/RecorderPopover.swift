import AppKit
import SwiftUI

/// Custom floating surface, shared by inputs, destination and recording actions.
/// One panel owns outside-click / Escape dismissal; switching anchors replaces it.
@MainActor
final class RecorderPopoverPresenter {
    static let shared = RecorderPopoverPresenter()
    private var panel: RecorderConfigurationPanel?
    private var identifier: String?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func toggle(id: String, anchor: NSView, content: AnyView, width: CGFloat) {
        if identifier == id { dismiss(); return }
        dismiss()
        guard let owner = anchor.window, let screen = owner.screen else { return }
        let anchorRect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let maxHeight = visible.height - 16
        let host = NSHostingController(rootView: RecorderPopoverViewport(content: content, width: width, maxHeight: maxHeight) { [weak self] height in
            guard let self, self.identifier == id, let panel = self.panel else { return }
            let newHeight = min(height, maxHeight)
            guard abs(panel.frame.height - newHeight) > 1 else { return }
            let below = anchorRect.minY - newHeight - 10
            let y = below >= visible.minY ? below : min(anchorRect.maxY + 10, visible.maxY - newHeight)
            panel.setFrame(NSRect(x: panel.frame.minX, y: y, width: width, height: newHeight), display: true)
            panel.invalidateShadow()
        }.preferredColorScheme(.light).appControlFocusAppearance())
        let height = min(max(host.view.fittingSize.height, 80), maxHeight)
        let x = min(max(anchorRect.midX - width / 2, visible.minX), visible.maxX - width)
        let below = anchorRect.minY - height - 10
        let y = below >= visible.minY ? below : min(anchorRect.maxY + 10, visible.maxY - height)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        let panel = RecorderConfigurationPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        panel.identifier = NSUserInterfaceItemIdentifier("recorder.popover.\(id)")
        self.panel = panel
        identifier = id
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        animateRecorderOverlayIn(panel)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak panel] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.dismiss(); return nil }
            if event.type != .keyDown, event.window !== panel {
                // Clicking the same trigger should close, not close then reopen.
                if anchorRect.contains(NSEvent.mouseLocation) { self?.dismiss(); return nil }
                self?.dismiss()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }

    func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        let current = panel
        panel = nil; identifier = nil
        if let current { current.parent?.removeChildWindow(current) }
        current?.orderOut(nil)
        current?.contentViewController = nil
        current?.close()
    }

    /// Finish the triggering mouse-up and dispose of its hosting tree before
    /// handing focus to an open panel or changing the app's workspace phase.
    func dismissAndPerform(_ action: @escaping @MainActor () -> Void) {
        let owner = panel?.parent
        dismiss()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if owner?.isVisible == true { owner?.makeKeyAndOrderFront(nil) }
            action()
        }
    }
}

private struct RecorderPopoverViewport: View {
    let content: AnyView
    let width: CGFloat
    let maxHeight: CGFloat
    let onResize: (CGFloat) -> Void
    @State private var contentHeight: CGFloat = 300
    var body: some View {
        ScrollView(.vertical) {
            content.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { value in
                    guard value > 0 else { return }
                    contentHeight = value
                    onResize(min(value, maxHeight))
                }
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: min(contentHeight, maxHeight))
        .background(RecorderStyle.silver)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private final class RecorderConfigurationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct RecorderPopoverButton<Label: View, Panel: View>: View {
    let id: String
    let title: String
    let width: CGFloat
    let height: CGFloat
    var panelWidth: CGFloat = 290
    @ViewBuilder let label: () -> Label
    @ViewBuilder let panel: () -> Panel
    @State private var pressed = false
    private var cornerRadius: CGFloat { width == height ? height / 2 : EditorInterfaceRadius.group }
    var body: some View {
        ZStack {
            label()
                .frame(width: width, height: height)
                .modifier(RecorderPressFeedback(isPressed: pressed, cornerRadius: cornerRadius))
                .accessibilityHidden(true)
            RecorderPopoverTrigger(id: id, title: title, content: AnyView(panel()), panelWidth: panelWidth,
                                   cornerRadius: cornerRadius,
                                   onPressChange: { pressed = $0 })
        }
        .frame(width: width, height: height)
        .help(appLocalized(title))
    }
}

private struct RecorderPopoverTrigger: NSViewRepresentable {
    let id: String
    let title: String
    let content: AnyView
    let panelWidth: CGFloat
    let cornerRadius: CGFloat
    let onPressChange: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> RecorderMenuButtonNSView {
        let button = RecorderMenuButtonNSView()
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.sendAction(on: .leftMouseUp)
        button.target = context.coordinator
        button.action = #selector(Coordinator.show(_:))
        return button
    }
    func updateNSView(_ view: RecorderMenuButtonNSView, context: Context) {
        view.onPressChange = onPressChange
        view.hoverCornerRadius = cornerRadius
        context.coordinator.id = id
        context.coordinator.content = content
        context.coordinator.width = panelWidth
        view.setAccessibilityLabel(appLocalized(title))
        view.setAccessibilityIdentifier("recorder.config.\(id)")
    }
    @MainActor final class Coordinator: NSObject {
        var id = ""
        var content = AnyView(EmptyView())
        var width: CGFloat = 290
        @objc func show(_ sender: NSView) {
            RecorderPopoverPresenter.shared.toggle(id: id, anchor: sender, content: content, width: width)
        }
    }
}

struct RecorderPopoverSurface<Content: View>: View {
    var width: CGFloat = 290
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().padding(18).frame(width: width)
            .foregroundStyle(RecorderStyle.ink)
            .font(.appUI(size: 13))
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.floating, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: EditorInterfaceRadius.floating, style: .continuous).strokeBorder(RecorderStyle.line, lineWidth: 0.75).allowsHitTesting(false) }
    }
}

struct RecorderChoiceRow: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    var enabled = true
    var subtitle: String? = nil
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).font(.appUI(size: 17)).frame(width: 22) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(appLocalized(title)).lineLimit(2).multilineTextAlignment(.leading)
                    if let subtitle { Text(subtitle).font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted).lineLimit(2) }
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark").font(.appUI(size: 12, weight: .semibold)).foregroundStyle(RecorderStyle.mint).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 40)
            .background(selected ? RecorderStyle.mintWash.opacity(0.6) : hovered ? Color.black.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(RecorderPlainPressButtonStyle())
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 10))
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovered = value } }
        .accessibilityValue(selected ? appLocalized("已选择") : "")
    }
}

struct RecorderActionList: View {
    let title: String
    let items: [RecorderMenuItem]
    var body: some View {
        RecorderPopoverSurface {
            VStack(alignment: .leading, spacing: 5) {
                Text(appLocalized(title)).font(.appUI(size: 14, weight: .semibold)).padding(.bottom, 8)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item.kind {
                    case .separator: Divider().padding(.vertical, 4)
                    case .info: Text(item.title).font(.appUI(size: 12)).foregroundStyle(RecorderStyle.muted).fixedSize(horizontal: false, vertical: true).padding(6)
                    case .action:
                        RecorderChoiceRow(title: item.title, selected: item.isOn, enabled: item.isEnabled) {
                            RecorderPopoverPresenter.shared.dismissAndPerform { item.handler?() }
                        }
                    }
                }
            }
        }
    }
}
