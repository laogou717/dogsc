import AppKit
import CoreText
import RecorderCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CaptureDisplaySelector {
    var onSelect: ((CaptureDisplay, CaptureSelectionToken) -> Void)?
    var onStart: ((CaptureDisplay, CaptureSelectionToken) -> Void)?
    var onCancel: ((CaptureSelectionToken) -> Void)?

    private var panels: [DisplaySelectionPanel] = []
    private var displays: [CaptureDisplay] = []
    private var selectedDisplayID: UInt32?
    private var localKeyMonitor: Any?
    private var recorderMoveObservers: [NSObjectProtocol] = []
    private var activeToken: CaptureSelectionToken?

    func start(displays: [CaptureDisplay], token: CaptureSelectionToken) {
        stop()
        activeToken = token
        self.displays = displays
        selectedDisplayID = nil

        panels = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
                  let display = displays.first(where: { $0.id == displayID.uint32Value })
            else { return nil }

            let panel = DisplaySelectionPanel(screen: screen, display: display)
            panel.onSelect = { [weak self] in self?.select(display, token: token) }
            panel.onStart = { [weak self] in self?.startSelectedDisplay(token: token) }
            panel.onCancel = { [weak self] in self?.cancelSelection(token: token) }
            panel.orderFrontRegardless()
            animateRecorderOverlayIn(panel)
            return panel
        }
        installRecorderMoveObservers()
        updateAttachment()
        installKeyMonitor()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        (panels.first(where: { $0.frame.contains(pointer) }) ?? panels.first)?
            .makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.panels.forEach { $0.makeFirstResponder(nil) }
        }
    }

    func stop() {
        removeKeyMonitor()
        removeRecorderMoveObservers()
        panels.forEach { $0.orderOut(nil) }
        panels = []
        displays = []
        selectedDisplayID = nil
        activeToken = nil
    }

    private func select(_ display: CaptureDisplay, token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        selectedDisplayID = display.id
        updateAttachment()
        onSelect?(display, token)
    }

    private func startSelectedDisplay(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        guard let selectedDisplayID,
              let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        stop()
        onStart?(display, token)
    }

    private func cancelSelection(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        stop()
        onCancel?(token)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {
                guard let token = self?.activeToken else { return nil }
                self?.cancelSelection(token: token)
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                guard let token = self?.activeToken else { return nil }
                self?.startSelectedDisplay(token: token)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func installRecorderMoveObservers() {
        removeRecorderMoveObservers()
        guard let recorderWindow = RecorderCaptureSourceAnchorResolver.recorderWindow else {
            return
        }
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
        ]
        recorderMoveObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: recorderWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAttachment() }
            }
        }
    }

    private func removeRecorderMoveObservers() {
        recorderMoveObservers.forEach(NotificationCenter.default.removeObserver)
        recorderMoveObservers = []
    }

    private func updateAttachment() {
        let anchor = RecorderCaptureSourceAnchorResolver.recorderFrame
        panels.forEach { panel in
            let panelAnchor = anchor.flatMap {
                panel.frame.intersects($0) ? $0 : nil
            }
            panel.update(
                selected: panel.display.id == selectedDisplayID,
                anchorFrame: panelAnchor
            )
        }
    }
}

private final class DisplaySelectionPanel: NSPanel {
    let display: CaptureDisplay
    var onSelect: (() -> Void)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    private var hostingView: NSHostingView<DisplaySelectionOverlay>!
    private let screenFrame: CGRect
    private let visibleFrame: CGRect

    init(screen: NSScreen, display: CaptureDisplay) {
        self.display = display
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .readOnly
        hostingView = NSHostingView(
            rootView: makeRoot(selected: false, anchorFrame: nil)
        )
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func update(selected: Bool, anchorFrame: CGRect?) {
        hostingView.rootView = makeRoot(
            selected: selected,
            anchorFrame: anchorFrame
        )
        DispatchQueue.main.async { [weak self] in
            self?.makeFirstResponder(nil)
        }
    }

    private func makeRoot(
        selected: Bool,
        anchorFrame: CGRect?
    ) -> DisplaySelectionOverlay {
        DisplaySelectionOverlay(
            display: display,
            selected: selected,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            anchorFrame: anchorFrame,
            onSelect: { [weak self] in self?.onSelect?() },
            onStart: { [weak self] in self?.onStart?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
    }
}

private struct DisplaySelectionOverlay: View {
    @State private var thumbnail: NSImage?
    let display: CaptureDisplay
    let selected: Bool
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let anchorFrame: CGRect?
    let onSelect: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let cardSize = CGSize(width: 350, height: 178)
        let cardCenter = CaptureSelectionCardPlacement.localCenter(
            anchorFrame: anchorFrame,
            cardSize: cardSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        ZStack {
            Color.black.opacity(selected ? 0.16 : 0.24)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    selected ? captureSelectionAccent : Color.black.opacity(0.11),
                    lineWidth: selected ? 3 : 1
                )
                .padding(10)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    ZStack {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                                .padding(4).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "display").font(.appUI(size: 26, weight: .regular))
                        }
                    }.frame(width: 70, height: 50)
                        .modifier(RecorderRaisedSurface(radius: 10, selected: selected))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(display.name).font(.appUI(size: 15, weight: .medium)).lineLimit(1)
                        Text("\(display.width) × \(display.height) · \(display.refreshRate) Hz")
                            .font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(RecorderStyle.mint) }
                }
                Divider()
                HStack(spacing: 10) {
                    Button(action: onCancel) { Text("取消").frame(width: 74, height: 36) }
                        .buttonStyle(RecorderButtonStyle()).help("按 Esc 取消")
                    Spacer(minLength: 0)
                    Button(action: selected ? onStart : onSelect) {
                        Text(selected ? "开始录制" : "选择此显示器").frame(width: 142, height: 36)
                    }.buttonStyle(RecorderButtonStyle(primary: true))
                }.font(.appUI(size: 12, weight: .medium)).focusEffectDisabled()
            }
            .foregroundStyle(RecorderStyle.ink)
            .padding(18)
            .frame(width: 350, height: 178)
            .captureSelectionCardSurface()
            .modifier(RecorderSelectionEntrance())
            .position(cardCenter)

            .animation(SpringMotion.fluid, value: selected)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .appControlFocusAppearance()
        .task(id: display.id) { thumbnail = await RecorderSourceThumbnail.image(displayID: display.id) }
    }
}
