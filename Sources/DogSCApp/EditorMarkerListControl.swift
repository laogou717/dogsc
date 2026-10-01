import AppKit
import SwiftUI

/// The marker list uses a borderless child panel, not an NSMenu/NSPopover skin.
struct EditorMarkerListControl: View {
    let markers: [EditorRecordingMarker]
    let seek: (EditorRecordingMarker) -> Void
    let remove: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var presenter = EditorMarkerCardPresenter()

    var body: some View {
        Button { presenter.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark").font(.appUI(size: 12, weight: .medium))
                Text("标记").font(.appUI(size: 11, weight: .medium))
            }
            .foregroundStyle(EditorTheme.chrome(0.68))
            .padding(.horizontal, 8).frame(height: 30)
            .background(presenter.isPresented ? EditorTheme.selectionWash : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
        .background(EditorMarkerCardAnchor(presenter: presenter, colorScheme: colorScheme,
                                          content: { maxHeight in AnyView(card(maxHeight: maxHeight)) })
            .allowsHitTesting(false).accessibilityHidden(true))
        .help("录制标记：点击跳转；标尺上右键可删除")
        .accessibilityLabel("录制标记")
        .onDisappear { presenter.detach() }
    }

    private func card(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("录制标记").font(.appUI(size: 14, weight: .semibold))
                Text("\(markers.count)").font(.appUI(size: 11, design: .monospaced))
                    .foregroundStyle(EditorTheme.chrome(0.42))
                Spacer(minLength: 4)
                Button { presenter.dismiss(restoreFocus: true) } label: {
                    Image(systemName: "xmark").font(.appUI(size: 10, weight: .medium))
                        .frame(width: 22, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorTheme.chrome(0.45))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("关闭标记列表")
            }
            .padding(.horizontal, 16).padding(.top, 14)
            Text("快速找回重点与重录位置")
                .font(.appUI(size: 11)).foregroundStyle(EditorTheme.chrome(0.45))
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
            if markers.isEmpty {
                Text("标记所在素材已被剪掉，恢复剪辑后可重新定位")
                    .font(.appUI(size: 12)).foregroundStyle(EditorTheme.chrome(0.55))
                    .fixedSize(horizontal: false, vertical: true).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(markers) { item in
                            EditorMarkerListRow(item: item, select: {
                                presenter.dismiss(restoreFocus: true)
                                seek(item)
                            }, remove: { remove(item.id) })
                        }
                    }
                    .padding(.horizontal, 7)
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(markers.count) * 44 - 3, max(44, min(261, maxHeight - 120))))
            }
            Rectangle().fill(EditorTheme.chrome(0.065)).frame(height: 1)
                .padding(.horizontal, 16).padding(.top, 10)
            Text("点击定位 · 点删除图标移除")
                .font(.appUI(size: 10)).foregroundStyle(EditorTheme.chrome(0.42))
                .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .foregroundStyle(EditorTheme.chrome(0.86))
        .background(EditorTheme.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(EditorTheme.chrome(0.09), lineWidth: 1) }
    }
}

private struct EditorMarkerListRow: View {
    let item: EditorRecordingMarker
    let select: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: "bookmark").font(.appUI(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.65, green: 0.47, blue: 0.22))
                    Text(item.label).font(.appUI(size: 12, weight: .medium))
                    Spacer(minLength: 6)
                    Text(item.timestamp)
                        .font(.appUI(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(EditorTheme.chrome(0.035), in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "chevron.right").font(.appUI(size: 9, weight: .medium))
                        .foregroundStyle(EditorTheme.chrome(0.38))
                }
                .padding(.leading, 12).padding(.trailing, 8).frame(height: 41)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(item.label + " · " + item.timestamp)
            Button(action: remove) {
                Image(systemName: "trash").font(.appUI(size: 10))
                    .foregroundStyle(EditorTheme.chrome(hovered ? 0.55 : 0.28))
                    .frame(width: 24, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 4))
            .help("删除录制标记")
            .accessibilityLabel(appLocalized("删除录制标记") + " · " + item.label)
            .padding(.trailing, 5)
        }
        .background(EditorTheme.chrome(hovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
    }
}

private struct EditorMarkerCardAnchor: NSViewRepresentable {
    let presenter: EditorMarkerCardPresenter
    let colorScheme: ColorScheme
    let content: (CGFloat) -> AnyView
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        presenter.configure(anchor: view, colorScheme: colorScheme, content: content)
    }
}

@MainActor
private final class EditorMarkerCardPresenter: ObservableObject {
    @Published private(set) var isPresented = false
    private weak var anchor: NSView?
    private var content: ((CGFloat) -> AnyView)?
    private var colorScheme: ColorScheme = .light
    private var panel: EditorMarkerPanel?
    private var host: NSHostingController<AnyView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func configure(anchor: NSView, colorScheme: ColorScheme, content: @escaping (CGFloat) -> AnyView) {
        self.anchor = anchor; self.colorScheme = colorScheme; self.content = content
        if panel != nil { updatePlacement() }
    }

    func toggle() {
        if isPresented { dismiss(restoreFocus: true); return }
        guard let owner = anchor?.window else { return }
        let panel = EditorMarkerPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.identifier = NSUserInterfaceItemIdentifier("editor.recording-markers")
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        panel.contentViewController = host
        self.panel = panel; self.host = host
        updatePlacement()
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        isPresented = true
        animateRecorderOverlayIn(panel)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak panel] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss(restoreFocus: true); return nil }
            } else if event.window !== panel {
                if let anchor = self.anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                    self.dismiss(restoreFocus: true); return nil
                }
                self.dismiss()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func updatePlacement() {
        guard let anchor, let owner = anchor.window, let screen = owner.screen,
              let panel, let host, let content else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(304, visible.width)
        let anchorRect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        host.rootView = AnyView(content(visible.height).frame(width: width)
            .preferredColorScheme(colorScheme).appControlFocusAppearance())
        panel.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let height = min(max(host.view.fittingSize.height, 100), visible.height)
        let x = min(max(anchorRect.minX, visible.minX), visible.maxX - width)
        let below = anchorRect.minY - height - 8
        let y = below >= visible.minY ? below : min(anchorRect.maxY + 8, visible.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.invalidateShadow()
    }

    func dismiss(restoreFocus: Bool = false) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        let current = panel; let owner = current?.parent
        panel = nil; host = nil
        if let current { current.parent?.removeChildWindow(current) }
        current?.orderOut(nil); current?.contentViewController = nil; current?.close()
        if isPresented { isPresented = false }
        if restoreFocus, NSApp.isActive { owner?.makeKeyAndOrderFront(nil) }
    }

    func detach() {
        dismiss()
        content = nil
        anchor = nil
    }
}

private final class EditorMarkerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
