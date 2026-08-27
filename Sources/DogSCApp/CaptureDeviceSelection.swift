import AppKit
import CoreText
import RecorderCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class IOSDeviceCaptureSelector {
    var onSelect: ((CaptureDeviceInfo, CaptureSelectionToken) -> Void)?
    var onStart: ((CaptureDeviceInfo, CaptureSelectionToken) -> Void)?
    var onCancel: ((CaptureSelectionToken) -> Void)?
    var onRefresh: (() -> Void)?

    private var panel: IOSDeviceSelectionPanel?
    private var devices: [CaptureDeviceInfo] = []
    private var selectedDeviceID: String?
    private var localKeyMonitor: Any?
    private var activeToken: CaptureSelectionToken?

    func start(
        devices: [CaptureDeviceInfo],
        on displayID: UInt32? = nil,
        token: CaptureSelectionToken
    ) {
        stop()
        activeToken = token
        self.devices = devices
        selectedDeviceID = nil
        guard let screen = screen(for: displayID) else {
            activeToken = nil
            onCancel?(token)
            return
        }
        let panel = IOSDeviceSelectionPanel(screen: screen)
        panel.onSelect = { [weak self] id in self?.select(id: id, token: token) }
        panel.onStart = { [weak self] in self?.startSelectedDevice(token: token) }
        panel.onRefresh = { [weak self] in self?.refreshDevices(token: token) }
        panel.onCancel = { [weak self] in self?.cancelSelection(token: token) }
        self.panel = panel
        updatePanel()
        installKeyMonitor()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func stop() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
        devices = []
        selectedDeviceID = nil
        activeToken = nil
    }

    func updateDevices(_ devices: [CaptureDeviceInfo]) {
        guard panel != nil else { return }
        self.devices = devices
        if let selectedDeviceID,
           !devices.contains(where: { $0.id == selectedDeviceID }) {
            self.selectedDeviceID = nil
        }
        updatePanel()
    }

    private func select(id: String, token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        selectedDeviceID = id
        updatePanel()
        if let device = devices.first(where: { $0.id == id }) {
            onSelect?(device, token)
        }
    }

    private func refreshDevices(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        onRefresh?()
    }

    private func updatePanel() {
        panel?.update(devices: devices, selectedDeviceID: selectedDeviceID)
    }

    private func startSelectedDevice(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        guard let selectedDeviceID,
              let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
        stop()
        onStart?(device, token)
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
                self?.startSelectedDevice(token: token)
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

    private func screen(for displayID: UInt32?) -> NSScreen? {
        if let displayID,
           let selected = NSScreen.screens.first(where: { screen in
               guard let number = screen.deviceDescription[
                   NSDeviceDescriptionKey("NSScreenNumber")
               ] as? NSNumber else { return false }
               return number.uint32Value == displayID
           }) {
            return selected
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

private final class IOSDeviceSelectionPanel: NSPanel {
    var onSelect: ((String) -> Void)?
    var onStart: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onCancel: (() -> Void)?

    private var hostingView: NSHostingView<IOSDeviceSelectionOverlay>!

    init(screen: NSScreen) {
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
        hostingView = NSHostingView(rootView: makeRoot(devices: [], selectedDeviceID: nil))
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func update(devices: [CaptureDeviceInfo], selectedDeviceID: String?) {
        hostingView.rootView = makeRoot(devices: devices, selectedDeviceID: selectedDeviceID)
    }

    private func makeRoot(
        devices: [CaptureDeviceInfo],
        selectedDeviceID: String?
    ) -> IOSDeviceSelectionOverlay {
        IOSDeviceSelectionOverlay(
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            onSelect: { [weak self] id in self?.onSelect?(id) },
            onStart: { [weak self] in self?.onStart?() },
            onRefresh: { [weak self] in self?.onRefresh?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
    }
}

private struct IOSDeviceSelectionOverlay: View {
    let devices: [CaptureDeviceInfo]
    let selectedDeviceID: String?
    let onSelect: (String) -> Void
    let onStart: () -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.68)
            VStack(spacing: 18) {
                Image(systemName: "ipad.and.iphone")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(captureSelectionAccent)
                    .symbolEffect(.bounce, value: selectedDeviceID)
                    .accessibilityHidden(true)
                Text("选择要录制的设备")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                Text("使用数据线连接、解锁并信任这台 Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if devices.isEmpty {
                    ContentUnavailableView(
                        "没有找到设备",
                        systemImage: "cable.connector.slash",
                        description: Text("连接后点击重新扫描")
                    )
                    .frame(height: 140)
                } else {
                    VStack(spacing: 9) {
                        ForEach(devices) { device in
                            Button { onSelect(device.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "ipad")
                                        .font(.system(size: 20, weight: .medium))
                                    Text(device.name)
                                        .font(.body.weight(.semibold))
                                    Spacer()
                                    Image(systemName: selectedDeviceID == device.id
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedDeviceID == device.id
                                            ? captureSelectionAccent : Color.secondary)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 54)
                                .background(
                                    selectedDeviceID == device.id
                                        ? captureSelectionAccent.opacity(0.16)
                                        : Color.white.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(
                                            selectedDeviceID == device.id
                                                ? captureSelectionAccent.opacity(0.9)
                                                : Color.white.opacity(0.09),
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(device.name)
                            .accessibilityValue(
                                selectedDeviceID == device.id ? "已选择" : "未选择"
                            )
                            .accessibilityAddTraits(
                                selectedDeviceID == device.id ? .isSelected : []
                            )
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("重新扫描", action: onRefresh)
                        .buttonStyle(.bordered)
                    Button(action: onStart) {
                        Label("开始录制", systemImage: "record.circle")
                            .font(.body.weight(.semibold))
                            .frame(width: 150, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(captureSelectionAccent)
                    .disabled(selectedDeviceID == nil)
                }
                Button("取消 · Esc", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 470)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
