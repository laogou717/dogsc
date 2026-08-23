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
        installKeyMonitor()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        (panels.first(where: { $0.frame.contains(pointer) }) ?? panels.first)?
            .makeKeyAndOrderFront(nil)
    }

    func stop() {
        removeKeyMonitor()
        panels.forEach { $0.orderOut(nil) }
        panels = []
        displays = []
        selectedDisplayID = nil
        activeToken = nil
    }

    private func select(_ display: CaptureDisplay, token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        selectedDisplayID = display.id
        panels.forEach { $0.update(selected: $0.display.id == display.id) }
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
}

private final class DisplaySelectionPanel: NSPanel {
    let display: CaptureDisplay
    var onSelect: (() -> Void)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    private var hostingView: NSHostingView<DisplaySelectionOverlay>!

    init(screen: NSScreen, display: CaptureDisplay) {
        self.display = display
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
        sharingType = .none
        hostingView = NSHostingView(rootView: makeRoot(selected: false))
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func update(selected: Bool) {
        hostingView.rootView = makeRoot(selected: selected)
    }

    private func makeRoot(selected: Bool) -> DisplaySelectionOverlay {
        DisplaySelectionOverlay(
            display: display,
            selected: selected,
            onSelect: { [weak self] in self?.onSelect?() },
            onStart: { [weak self] in self?.onStart?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
    }
}

private struct DisplaySelectionOverlay: View {
    let display: CaptureDisplay
    let selected: Bool
    let onSelect: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(selected ? 0.48 : 0.68)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    selected ? captureSelectionAccent : Color.white.opacity(0.13),
                    lineWidth: selected ? 4 : 1
                )
                .padding(10)

            VStack(spacing: 16) {
                Image(systemName: selected ? "display.and.arrow.down" : "display")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(
                        selected ? captureSelectionAccent : Color.white.opacity(0.82)
                    )
                    .symbolEffect(.bounce, value: selected)
                Text(selected ? "已选择此显示器" : "选择此显示器")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(display.width) × \(display.height)  ·  \(display.refreshRate) Hz")
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)

                Button(action: selected ? onStart : onSelect) {
                    Label(
                        selected ? "开始录制" : "选择此显示器",
                        systemImage: selected ? "record.circle" : "checkmark.circle"
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 210, height: 46)
                    .background(
                        captureSelectionAccent,
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button("取消 · Esc", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(width: 430)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
