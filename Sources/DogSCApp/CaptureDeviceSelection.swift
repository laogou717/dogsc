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
        appearance = nil
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
            ? CGFloat(44)
            : CGFloat(devices.count * 52 + max(devices.count - 1, 0) * 2)
        let cardSize = CGSize(width: 380, height: 142 + contentHeight)
        let cardCenter = CaptureSelectionCardPlacement.localCenter(
            anchorFrame: anchorFrame,
            cardSize: cardSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        ZStack {
            Color.black.opacity(0.26)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("选择要录制的设备").font(.appUI(size: 15, weight: .semibold))
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RecorderStyle.muted).frame(width: 30, height: 30)
                    }
                    .buttonStyle(RecorderCirclePressStyle())
                    .help("重新扫描").accessibilityLabel("重新扫描")
                }
                .padding(.leading, 12).padding(.trailing, 4).frame(height: 34)

                if devices.isEmpty {
                    Text("未发现可录制设备")
                        .font(.appUI(size: 13))
                        .foregroundStyle(RecorderStyle.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                } else {
                    VStack(spacing: 2) {
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
                    .padding(.top, 4)
                }

                HStack(spacing: 4) {
                    Button(action: onCancel) {
                        HStack(spacing: 7) { Text("取消"); RecorderKeyHint(key: "esc") }
                    }
                    .buttonStyle(RecorderPillButtonStyle(kind: .quiet))
                    .focusEffectDisabled()
                    .help("按 Esc 取消")

                    Spacer()

                    Button(action: onStart) {
                        HStack(spacing: 8) {
                            Circle().fill(.white).frame(width: 8, height: 8)
                            Text("开始录制")
                        }
                    }
                    .buttonStyle(RecorderPillButtonStyle(kind: .record))
                    .focusEffectDisabled()
                    .disabled(selectedDeviceID == nil)
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 8)
            .frame(width: 380)
            .foregroundStyle(RecorderStyle.ink)
            .recorderSurface(radius: 30, castsShadow: true)
            .modifier(RecorderSelectionEntrance())
            .position(cardCenter)
        }
        .ignoresSafeArea()
        .appControlFocusAppearance()
        .animation(RecorderMotion.settle, value: selectedDeviceID)
        .animation(RecorderMotion.settle, value: devices.count)
    }
}

/// A device is a line of text. The chosen one is lit and ticked; the pointer
/// leaves a soft trace on the others.
private struct DeviceSelectionRow: View {
    let device: CaptureDeviceInfo
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "ipad.landscape" : "ipad")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? RecorderStyle.ink : RecorderStyle.muted)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.appUI(size: 13, weight: .medium))
                        .foregroundStyle(selected ? RecorderStyle.ink : RecorderStyle.ink.opacity(0.72))
                        .lineLimit(1)
                    Text(appLocalized(selected ? "已选为录制来源" : "已连接"))
                        .font(.appUI(size: 11))
                        .foregroundStyle(RecorderStyle.muted)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(RecorderStyle.ink)
                    .opacity(selected ? 1 : 0).scaleEffect(selected ? 1 : 0.4)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(selected ? RecorderStyle.selection : hovering ? RecorderStyle.well : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 14, cornerStyle: .circular, showsHover: false))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 14))
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(RecorderMotion.fade, value: hovering)
        .animation(RecorderMotion.quick, value: selected)
    }
}
