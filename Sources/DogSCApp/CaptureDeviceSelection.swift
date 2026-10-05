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
    private var recorderMoveObservers: [NSObjectProtocol] = []
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
        installRecorderMoveObservers()
        installKeyMonitor()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        animateRecorderOverlayIn(panel)
        DispatchQueue.main.async { [weak panel] in
            panel?.makeFirstResponder(nil)
        }
    }

    func stop() {
        removeKeyMonitor()
        removeRecorderMoveObservers()
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
        guard let panel else { return }
        let anchor = RecorderCaptureSourceAnchorResolver.recorderFrame
        if let anchor,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            panel.move(to: screen)
        }
        panel.update(
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            anchorFrame: anchor
        )
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
                MainActor.assumeIsolated { self?.updatePanel() }
            }
        }
    }

    private func removeRecorderMoveObservers() {
        recorderMoveObservers.forEach(NotificationCenter.default.removeObserver)
        recorderMoveObservers = []
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
    private var screenFrame: CGRect
    private var visibleFrame: CGRect

    init(screen: NSScreen) {
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
            rootView: makeRoot(
                devices: [],
                selectedDeviceID: nil,
                anchorFrame: nil
            )
        )
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func move(to screen: NSScreen) {
        guard screenFrame != screen.frame else { return }
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        setFrame(screen.frame, display: false)
    }

    func update(
        devices: [CaptureDeviceInfo],
        selectedDeviceID: String?,
        anchorFrame: CGRect?
    ) {
        hostingView.rootView = makeRoot(
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            anchorFrame: anchorFrame
        )
        DispatchQueue.main.async { [weak self] in
            self?.makeFirstResponder(nil)
        }
    }

    private func makeRoot(
        devices: [CaptureDeviceInfo],
        selectedDeviceID: String?,
        anchorFrame: CGRect?
    ) -> IOSDeviceSelectionOverlay {
        IOSDeviceSelectionOverlay(
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            anchorFrame: anchorFrame,
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
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let anchorFrame: CGRect?
    let onSelect: (String) -> Void
    let onStart: () -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let contentHeight = devices.isEmpty
            ? CGFloat(84)
            : CGFloat(devices.count * 62 + max(devices.count - 1, 0) * 9)
        let cardSize = CGSize(width: 520, height: 215 + contentHeight)
        let cardCenter = CaptureSelectionCardPlacement.localCenter(
            anchorFrame: anchorFrame,
            cardSize: cardSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        ZStack {
            Color.black.opacity(0.24)
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.065))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.black.opacity(0.1))
                            }
                        Image(systemName: "ipad.and.iphone")
                            .font(.appUI(size: 27, weight: .medium))
                            .foregroundStyle(EditorTheme.platinumAccent)
                            .symbolEffect(.bounce, value: selectedDeviceID)
                    }
                    .frame(width: 62, height: 62)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("外接设备")
                            .font(.appUI(size: 12, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.48))
                        Text("选择要录制的设备")
                            .font(.appUI(size: 20, weight: .medium))
                            .foregroundStyle(Color(white: 0.18))
                        Text("连接数据线，并在设备上完成解锁与信任")
                            .font(.appUI(.callout))
                            .foregroundStyle(Color.black.opacity(0.55))
                    }
                    Spacer()
                }

                if devices.isEmpty {
                    HStack(spacing: 16) {
                        Image(systemName: "cable.connector.slash")
                            .font(.appUI(size: 25, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.48))
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未发现可录制设备")
                                .font(.appUI(.body, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.86))
                            Text("连接后可直接重新扫描，无需退出当前界面")
                                .font(.appUI(.callout))
                                .foregroundStyle(Color.black.opacity(0.46))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 84)
                    .background(RecorderStyle.mintWash.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.black.opacity(0.075))
                    }
                } else {
                    VStack(spacing: 9) {
                        ForEach(devices) { device in
                            DeviceSelectionRow(
                                device: device,
                                selected: selectedDeviceID == device.id,
                                onSelect: { onSelect(device.id) }
                            )
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

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Label("取消", systemImage: "xmark")
                            .font(.appUI(size: 14, weight: .semibold))
                            .frame(width: 100, height: 44)
                    }
                    .buttonStyle(CaptureSelectionSecondaryButtonStyle())
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 12))
                    .focusEffectDisabled()
                    .help("按 Esc 取消")

                    Button(action: onRefresh) {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                            .font(.appUI(size: 14, weight: .semibold))
                            .frame(width: 124, height: 44)
                    }
                    .buttonStyle(CaptureSelectionSecondaryButtonStyle())
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 12))
                    .focusEffectDisabled()

                    Spacer()

                    Button(action: onStart) {
                        Label("开始录制", systemImage: "record.circle")
                            .font(.appUI(size: 15, weight: .semibold))
                            .frame(width: 156, height: 44)
                    }
                    .buttonStyle(CaptureSelectionPrimaryButtonStyle())
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 12), color: .white.opacity(0.65))
                    .focusEffectDisabled()
                    .disabled(selectedDeviceID == nil)
                }
            }
            .padding(24)
            .frame(width: 520)
            .captureSelectionCardSurface()
            .modifier(RecorderSelectionEntrance())
            .position(cardCenter)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .appControlFocusAppearance()
    }
}

private struct DeviceSelectionRow: View {
    let device: CaptureDeviceInfo
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 13) {
                Image(systemName: "ipad")
                    .font(.appUI(size: 19, weight: .medium))
                    .foregroundStyle(selected ? captureSelectionAccent : EditorTheme.platinumMuted)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.appUI(.body, weight: .semibold))
                        .foregroundStyle(Color(white: 0.18))
                        .lineLimit(1)
                    Text(appLocalized(selected ? "已选为录制来源" : "已连接"))
                        .font(.appUI(.caption))
                        .foregroundStyle(selected ? captureSelectionAccent : Color.black.opacity(0.42))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.appUI(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? captureSelectionAccent : Color.black.opacity(0.26))
            }
            .padding(.horizontal, 12)
            .frame(height: 62)
            .background(
                selected
                    ? captureSelectionAccent.opacity(0.13)
                    : Color.black.opacity(hovering ? 0.075 : 0.045),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(
                        selected
                            ? captureSelectionAccent.opacity(0.72)
                            : Color.black.opacity(hovering ? 0.14 : 0.075),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 15, cornerStyle: .circular, showsHover: false))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 15))
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .scaleEffect(hovering && !selected ? 1.006 : 1)
        .animation(SpringMotion.interactive, value: hovering)
        .animation(SpringMotion.interactive, value: selected)
    }
}
