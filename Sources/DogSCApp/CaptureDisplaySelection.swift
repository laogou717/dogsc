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
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = CommandLine.arguments.contains("--design-review") ? .readOnly : .none
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
    let display: CaptureDisplay
    let selected: Bool
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let anchorFrame: CGRect?
    let onSelect: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let cardSize = CGSize(width: 490, height: 199)
        let cardCenter = CaptureSelectionCardPlacement.localCenter(
            anchorFrame: anchorFrame,
            cardSize: cardSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        ZStack {
            Color.black.opacity(selected ? 0.46 : 0.64)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    selected ? captureSelectionAccent : Color.white.opacity(0.11),
                    lineWidth: selected ? 3 : 1
                )
                .padding(10)

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.065))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.1))
                            }
                        Image(systemName: selected ? "display.and.arrow.down" : "display")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(selected ? captureSelectionAccent : EditorTheme.platinumAccent)
                            .symbolEffect(.bounce, value: selected)
                    }
                    .frame(width: 62, height: 62)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("显示器")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.48))
                        Text(display.name)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(display.width) × \(display.height)  ·  \(display.refreshRate) Hz")
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(selected ? captureSelectionAccent : Color.white.opacity(0.34))
                            .frame(width: 6, height: 6)
                        Text(selected ? "已锁定" : "待选择")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(selected ? captureSelectionAccent : Color.white.opacity(0.52))
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.055), in: Capsule())
                }

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Label("取消", systemImage: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 104, height: 44)
                    }
                    .buttonStyle(CaptureSelectionSecondaryButtonStyle())
                    .focusEffectDisabled()
                    .help("按 Esc 取消")

                    Spacer()

                    Button(action: selected ? onStart : onSelect) {
                        Label(
                            selected ? "开始录制" : "选择此显示器",
                            systemImage: selected ? "record.circle" : "checkmark"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 190, height: 44)
                    }
                    .buttonStyle(CaptureSelectionPrimaryButtonStyle())
                    .focusEffectDisabled()
                }
            }
            .padding(24)
            .frame(width: 490)
            .captureSelectionCardSurface()
            .position(cardCenter)
            .scaleEffect(selected ? 1.01 : 1)
            .animation(SpringMotion.fluid, value: selected)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
