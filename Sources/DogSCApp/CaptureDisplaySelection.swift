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
    private var screenParametersObserver: NSObjectProtocol?
    private var activeToken: CaptureSelectionToken?
    private let transition = CaptureSelectionTransition()

    func start(displays: [CaptureDisplay], token: CaptureSelectionToken) {
        stop()
        activeToken = token
        self.displays = displays
        selectedDisplayID = nil

        reconcilePanels(screens: NSScreen.screens, token: token)
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshConnectedDisplays(token: token)
            }
        }
        installKeyMonitor()
        // With one display there is nothing to choose between: frame it at
        // once so the island already offers the take.
        if panels.count == 1, let only = panels.first?.display {
            DispatchQueue.main.async { [weak self] in self?.select(only, token: token) }
        }
        makePointerScreenKey()
    }

    private func reconcilePanels(screens: [NSScreen], token: CaptureSelectionToken) {
        var previousPanels = panels
        panels = screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
                  let display = displays.first(where: { $0.id == displayID.uint32Value })
            else { return nil }

            if let index = previousPanels.firstIndex(where: { $0.display == display }) {
                let panel = previousPanels.remove(at: index)
                panel.setFrame(screen.frame, display: true)
                return panel
            }
            let panel = DisplaySelectionPanel(screen: screen, display: display)
            panel.onSelect = { [weak self] in self?.select(display, token: token) }
            panel.onStart = { [weak self] in self?.startSelectedDisplay(token: token) }
            panel.onCancel = { [weak self] in self?.cancelSelection(token: token) }
            transition.present(panel)
            return panel
        }
        previousPanels.forEach { $0.prepareForRetirement() }
        transition.retire(previousPanels, animated: false)
        updateSelection()
    }

    private func refreshConnectedDisplays(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        let screens = NSScreen.screens
        displays = CaptureDisplay.available(screens: screens)
        // A removed target must never silently become the built-in display.
        if displays.isEmpty || selectedDisplayID.map({ selected in
            !displays.contains(where: { $0.id == selected })
        }) == true {
            cancelSelection(token: token)
            return
        }
        reconcilePanels(screens: screens, token: token)
        makePointerScreenKey()
    }

    private func makePointerScreenKey() {
        // A selector belongs over the currently visible desktop, including
        // another app's full-screen Space. Taking key input must not activate
        // DogSC and move the user back to the editor's Space.
        let pointer = NSEvent.mouseLocation
        (panels.first(where: { $0.frame.contains(pointer) }) ?? panels.first)?
            .makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.panels.forEach { $0.makeFirstResponder(nil) }
        }
    }

    func stop(preservingRetiringPanels: Bool = false) {
        closeSelection(animated: false)
        if !preservingRetiringPanels { transition.finishImmediately() }
    }

    private func closeSelection(animated: Bool) {
        activeToken = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        removeKeyMonitor()
        let retiringPanels = panels
        panels = []
        displays = []
        selectedDisplayID = nil
        retiringPanels.forEach { $0.prepareForRetirement() }
        transition.retire(retiringPanels, animated: animated)
    }

    private func select(_ display: CaptureDisplay, token: CaptureSelectionToken) {
        guard activeToken == token, displays.contains(display) else { return }
        selectedDisplayID = display.id
        updateSelection()
        onSelect?(display, token)
    }

    private func startSelectedDisplay(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        guard let selectedDisplayID,
              let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        closeSelection(animated: true)
        onStart?(display, token)
    }

    private func cancelSelection(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        closeSelection(animated: true)
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

    private func updateSelection() {
        panels.forEach { panel in
            panel.update(selected: panel.display.id == selectedDisplayID)
        }
    }
}

private final class DisplaySelectionPanel: NSPanel {
    let display: CaptureDisplay
    var onSelect: (() -> Void)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    private var hostingView: NSHostingView<DisplaySelectionOverlay>!
    private let presentation = DisplaySelectionPresentation()
    private var retiring = false

    init(screen: NSScreen, display: CaptureDisplay) {
        self.display = display
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        appearance = nil
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        sharingType = .readOnly
        hostingView = NSHostingView(
            rootView: makeRoot(selected: false)
        )
        contentView = hostingView
    }

    override var canBecomeKey: Bool { !retiring }
    override var canBecomeMain: Bool { false }

    func update(selected: Bool) {
        guard !retiring else { return }
        hostingView.rootView = makeRoot(selected: selected)
        DispatchQueue.main.async { [weak self] in
            self?.makeFirstResponder(nil)
        }
    }

    func prepareForRetirement() {
        retiring = true
        onSelect = nil
        onStart = nil
        onCancel = nil
        presentation.retiring = true
    }

    private func makeRoot(selected: Bool) -> DisplaySelectionOverlay {
        DisplaySelectionOverlay(
            presentation: presentation,
            display: display,
            selected: selected,
            onSelect: { [weak self] in self?.onSelect?() },
            onStart: { [weak self] in self?.onStart?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
    }
}

private final class DisplaySelectionPresentation: ObservableObject {
    @Published var retiring = false
}

/// Choosing a display is framing it: a viewfinder closes in from beyond the
/// screen's edges, and a small island at the foot names the display and starts
/// the take. Clicking anywhere on a display also chooses it.
private struct DisplaySelectionOverlay: View {
    @ObservedObject var presentation: DisplaySelectionPresentation
    @State private var arrived = false
    let display: CaptureDisplay
    let selected: Bool
    let onSelect: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // Entry belongs to this view. Retirement belongs to the panel's
        // single opacity transition: reversing this spring used to move the
        // capsule while the red button was still releasing its own press.
        let shown = arrived
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? (selected ? 0.08 : 0.26) : 0)
                .contentShape(Rectangle())
                .onTapGesture { if !selected { onSelect() } }
            CaptureViewfinder(inset: shown ? (selected ? 20 : 34) : -80, arm: selected ? 54 : 38)
                .stroke(.white.opacity(selected ? 1 : 0.62),
                        style: StrokeStyle(lineWidth: selected ? 3 : 2, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.4), radius: 8)
                .allowsHitTesting(false)
            island
                .compositingGroup()
                .opacity(shown ? 1 : 0)
                .offset(y: shown || RecorderMotion.reduces ? 0 : 36)
                .blur(radius: shown ? 0 : 8)
                .scaleEffect(shown || RecorderMotion.reduces ? 1 : 0.94)
                .padding(.bottom, 132)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(RecorderMotion.morph, value: shown)
        .animation(RecorderMotion.settle, value: selected)
        .appControlFocusAppearance()
        .allowsHitTesting(!presentation.retiring)
        .onAppear { arrived = true }
    }

    private var island: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(display.name).font(.appUI(size: 14, weight: .semibold)).lineLimit(1)
                Text(verbatim: "\(display.width) × \(display.height) · \(display.refreshRate) Hz")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(RecorderStyle.muted)
            }
            .padding(.leading, 24).padding(.trailing, 18)
            Button(action: onCancel) {
                HStack(spacing: 7) { Text("取消"); RecorderKeyHint(key: "esc") }
            }
            .buttonStyle(RecorderPillButtonStyle(kind: .quiet)).help("按 Esc 取消")
            Button(action: selected ? onStart : onSelect) {
                // Both labels participate in sizing, including localization.
                // Selection changes the action in place, never pushes the
                // outer island wider while the inner pill is releasing.
                ZStack {
                    Text(appLocalized("选择此显示器"))
                        .opacity(selected ? 0 : 1)
                    HStack(spacing: 8) {
                        Circle().fill(.white).frame(width: 8, height: 8)
                        Text(appLocalized("开始录制"))
                        RecorderKeyHint(key: "⌘R")
                    }
                    .opacity(selected ? 1 : 0)
                }
                .accessibilityHidden(true)
            }
            .buttonStyle(RecorderPillButtonStyle(kind: selected ? .record : .primary))
            .animation(RecorderMotion.fade, value: selected)
            .accessibilityLabel(appLocalized(selected ? "开始录制" : "选择此显示器"))
        }
        .padding(8)
        .foregroundStyle(RecorderStyle.ink)
        .focusEffectDisabled()
        .fixedSize()
        .recorderSurface(radius: 30, castsShadow: true)
    }
}
