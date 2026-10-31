import AppKit
import Combine

enum RecorderNotchPreference {
    static let enabledKey = "recorder.notch-hover.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

@MainActor
final class RecorderNotchState: ObservableObject {
    @Published var isDocked = false
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 179
    @Published var topInset: CGFloat = 32
    var reveal: () -> Void = {}
}

/// Only observes pointer motion; never captures, swallows or replays events.
/// The native window reserves the expanded canvas while SwiftUI animates the
/// visible surface, so a collapsing bar cannot move an open configuration panel.
@MainActor
final class RecorderNotchController {
    private weak var panel: RecorderPanel?
    private let state: RecorderNotchState
    private let configurationChanged: () -> Void
    private var geometry: RecorderNotchGeometry?
    private var interactionSize = RecorderPanelPolicy.setupSize
    private var isVisible = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingExpansion: Task<Void, Never>?
    private var pendingCollapse: Task<Void, Never>?
    private var menuTrackingDepth = 0

    init(panel: RecorderPanel, state: RecorderNotchState, configurationChanged: @escaping () -> Void) {
        self.panel = panel
        self.state = state
        self.configurationChanged = configurationChanged
        state.reveal = { [weak self] in self?.reveal() }
        for name in [UserDefaults.didChangeNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshConfiguration() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth += 1
                self.pendingCollapse?.cancel(); self.pendingCollapse = nil
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                self.updatePointer()
            }
        })
    }

    func refreshConfiguration() {
        let next = RecorderNotchPreference.isEnabled ? NSScreen.screens.compactMap { screen in
            RecorderNotchGeometry(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea)
        }.first : nil
        guard next != geometry else { return }
        geometry = next
        state.isDocked = next != nil
        if let next {
            state.notchWidth = next.collapsedSize.width
            state.topInset = next.notchRect.height
        }
        state.isExpanded = false
        pendingExpansion?.cancel(); pendingExpansion = nil
        pendingCollapse?.cancel(); pendingCollapse = nil
        updateMonitors()
        updatePointerRegion()
        configurationChanged()
    }

    func windowFrame(for canvasSize: CGSize, placementSize: CGSize) -> CGRect? {
        interactionSize = placementSize
        updatePointerRegion()
        return geometry?.windowFrame(for: canvasSize)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible {
            pendingExpansion?.cancel(); pendingExpansion = nil
            pendingCollapse?.cancel(); pendingCollapse = nil
            state.isExpanded = false
        }
        updateMonitors()
        updatePointerRegion()
        if visible { updatePointer() }
    }

    func reveal() {
        guard state.isDocked, isVisible else { return }
        pendingExpansion?.cancel(); pendingExpansion = nil
        pendingCollapse?.cancel(); pendingCollapse = nil
        state.isExpanded = true
        updatePointerRegion()
        // Also schedule a close when revealed from the Dock/status menu while
        // the pointer is elsewhere, rather than waiting for another mouse move.
        scheduleCollapseIfNeeded()
    }

    private var mustRemainExpanded: Bool {
        guard let panel else { return false }
        return NSEvent.pressedMouseButtons != 0 || menuTrackingDepth > 0
            || panel.childWindows?.contains(where: \.isVisible) == true
            || panel.attachedSheet != nil || NSApp.modalWindow != nil
            || AppDialogPresenter.isPresenting
    }

    private var pointerIsInside: Bool {
        guard let geometry else { return false }
        let point = NSEvent.mouseLocation
        return geometry.activationRect.contains(point)
            || (state.isExpanded && geometry.expandedInteractionRect(for: interactionSize).contains(point))
    }

    private func updatePointer() {
        guard isVisible, geometry != nil else { return }
        if pointerIsInside {
            pendingCollapse?.cancel(); pendingCollapse = nil
            if !state.isExpanded, pendingExpansion == nil {
                pendingExpansion = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, let self else { return }
                    pendingExpansion = nil
                    guard isVisible, pointerIsInside else { return }
                    state.isExpanded = true
                    updatePointerRegion()
                }
            }
        } else {
            pendingExpansion?.cancel(); pendingExpansion = nil
            scheduleCollapseIfNeeded()
        }
        panel?.refreshPointerInteraction()
    }

    private func scheduleCollapseIfNeeded() {
        guard state.isExpanded, !pointerIsInside, pendingCollapse == nil else { return }
        pendingCollapse = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            pendingCollapse = nil
            guard isVisible, !pointerIsInside else { return }
            if mustRemainExpanded {
                // A child panel may close without another mouse move.
                scheduleCollapseIfNeeded()
                return
            }
            state.isExpanded = false
            updatePointerRegion()
        }
    }

    private func updatePointerRegion() {
        guard let panel else { return }
        guard let geometry else {
            panel.notchPointerRegions = nil
            panel.refreshPointerInteraction()
            return
        }
        var regions = [CGRect(x: geometry.notchRect.minX,
            y: geometry.screenFrame.maxY - geometry.collapsedSize.height,
            width: geometry.collapsedSize.width, height: geometry.collapsedSize.height)]
        if state.isExpanded {
            let full = geometry.windowFrame(for: interactionSize)
            // Do not intercept menu-bar clicks in the transparent upper wings.
            regions.append(CGRect(x: full.minX, y: full.minY, width: full.width,
                height: max(0, full.height - geometry.notchRect.height)))
        }
        panel.notchPointerRegions = isVisible ? regions : []
        panel.refreshPointerInteraction()
    }

    private func updateMonitors() {
        if isVisible, geometry != nil, localMonitor == nil {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.updatePointer() }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointer() }
            }
        } else if !isVisible || geometry == nil {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil; globalMonitor = nil
        }
    }

    func shutdown() {
        setVisible(false)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        state.reveal = {}
    }
}
