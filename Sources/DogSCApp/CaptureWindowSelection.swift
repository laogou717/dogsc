import AppKit
import CoreText
import RecorderCore
import ScreenCaptureKit
import SwiftUI

struct CaptureWindowInfo: Identifiable, Equatable, Sendable {
    let id: UInt32
    let title: String
    let applicationName: String
    let applicationBundleIdentifier: String?
    let applicationProcessID: pid_t
    let frame: CGRect

    var pickerLabel: String {
        title.isEmpty ? applicationName : "\(applicationName) · \(title)"
    }

    @MainActor
    static func available(onScreenOnly: Bool = true) async throws -> [CaptureWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: onScreenOnly
        )
        let ignoredSystemApplications: Set<String> = [
            "com.apple.dock",
            "com.apple.WindowManager",
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
        ]
        return content.windows
            .filter { window in
                let bundleIdentifier = window.owningApplication?.bundleIdentifier
                guard window.windowID != 0,
                      window.frame.width >= 160,
                      window.frame.height >= 100,
                      window.owningApplication?.processID != getpid()
                        || CaptureEditorWindows.shared.includes(window.windowID),
                      !ignoredSystemApplications.contains(bundleIdentifier ?? "")
                else { return false }
                return window.owningApplication != nil
            }
            .map { window in
                CaptureWindowInfo(
                    id: window.windowID,
                    title: window.title ?? "",
                    applicationName: window.owningApplication?.applicationName ?? "应用窗口",
                    applicationBundleIdentifier: window.owningApplication?.bundleIdentifier,
                    applicationProcessID: window.owningApplication?.processID ?? 0,
                    frame: window.frame
                )
            }
            .sorted { left, right in
                left.pickerLabel.localizedStandardCompare(right.pickerLabel) == .orderedAscending
            }
    }
}

let windowSelectionOverlayIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.window-selection-overlay"
)

@MainActor
final class CaptureWindowSelector {
    private struct PendingSelectionClick {
        let token: CaptureSelectionToken
        let generation: UInt64
        let screenPoint: CGPoint
        let windowID: UInt32
    }

    var onSelect: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)?
    var onUnlock: ((CaptureSelectionToken) -> Void)?
    var onStart: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)?
    var onCancel: ((CaptureSelectionToken) -> Void)?

    private var overlayPanels: [WindowSelectionPanel] = []
    private var pollingTask: Task<Void, Never>?
    private var localKeyMonitor: Any?
    private var windows: [CaptureWindowInfo] = []
    // Hover is presentation only; selectedWindowID owns the confirmed identity.
    private var hoveredWindow: CaptureWindowInfo?
    private var selectedWindowID: UInt32?
    private var pendingSelectionClick: PendingSelectionClick?
    private var selectionClickGeneration: UInt64 = 0
    private var refreshCounter = 0
    private var isRecordingHighlight = false
    private var activeToken: CaptureSelectionToken?
    private var trackedGeometry: CaptureWindowGeometry?
    private let transition = CaptureSelectionTransition()
    private let geometryLookup: @MainActor (UInt32) -> CaptureWindowGeometry?

    init(
        geometryLookup: @escaping @MainActor (UInt32) -> CaptureWindowGeometry?
            = CaptureWindowGeometryLookup.live(windowID:)
    ) {
        self.geometryLookup = geometryLookup
    }

    func start(token: CaptureSelectionToken) {
        stop()
        activeToken = token
        isRecordingHighlight = false
        selectedWindowID = nil
        trackedGeometry = nil
        createOverlayPanels(token: token)
        installSelectionKeyMonitor(token: token)
        NSApplication.shared.activate(ignoringOtherApps: true)
        makePointerScreenOverlayKey()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshAndTrackSelection(token: token)
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
    }

    func stop(preservingRetiringPanels: Bool = false) {
        closeSelection(animated: false)
        if !preservingRetiringPanels { transition.finishImmediately() }
    }

    private func closeSelection(animated: Bool) {
        activeToken = nil
        invalidatePendingSelectionClick()
        pollingTask?.cancel()
        pollingTask = nil
        removeSelectionKeyMonitor()
        let retiringPanels = overlayPanels
        overlayPanels = []
        windows = []
        hoveredWindow = nil
        selectedWindowID = nil
        refreshCounter = 0
        isRecordingHighlight = false
        trackedGeometry = nil
        retiringPanels.forEach { $0.prepareForRetirement() }
        transition.retire(retiringPanels, animated: animated)
    }

    func lockSelectionForRecording(windowID: UInt32) {
        invalidatePendingSelectionClick()
        guard let geometry = validGeometry(for: windowID),
              let selected = windows.first(where: { $0.id == windowID })
                ?? hoveredWindow.flatMap({ $0.id == windowID ? $0 : nil })
                ?? recordingGuideWindow(windowID: windowID, geometry: geometry) else {
            stop()
            return
        }
        let createsGuidePanels = overlayPanels.isEmpty
        if createsGuidePanels {
            // A new take has no selector session. Rebuild only the guide for
            // the original window ID, without selection callbacks or focus.
            overlayPanels = NSScreen.screens.map { WindowSelectionPanel(screen: $0) }
            windows = [selected]
        }
        hoveredWindow = selected
        selectedWindowID = windowID
        activeToken = nil
        pollingTask?.cancel()
        pollingTask = nil
        removeSelectionKeyMonitor()
        isRecordingHighlight = true
        if !createsGuidePanels { transition.settlePresentation(overlayPanels) }
        overlayPanels.forEach {
            $0.ignoresMouseEvents = true
            $0.makeFirstResponder(nil)
            $0.resignKey()
            $0.resignMain()
        }
        trackedGeometry = geometry
        updateOverlays(
            for: selected,
            targetFrameOverride: geometry.frame,
            orderFront: !createsGuidePanels
        )
        if createsGuidePanels {
            // The first visible frame is already a noninteractive recording
            // guide; the initial selection hint and card never appear.
            overlayPanels.forEach { transition.present($0) }
        }
    }

    func updateRecordingGeometry(_ geometry: CaptureWindowGeometry?) {
        guard isRecordingHighlight, let selectedWindowID else { return }
        guard let geometry else {
            trackedGeometry = nil
            updateOverlays(for: nil)
            return
        }
        guard geometry.windowID == selectedWindowID,
              let selected = selectedWindow ?? hoveredWindow.flatMap({
                  $0.id == selectedWindowID ? $0 : nil
              }) else { return }
        trackedGeometry = geometry
        hoveredWindow = selected
        updateOverlays(for: selected, targetFrameOverride: geometry.frame)
    }

    private var selectedWindow: CaptureWindowInfo? {
        guard let selectedWindowID else { return nil }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    private func createOverlayPanels(token: CaptureSelectionToken) {
        overlayPanels.forEach { $0.orderOut(nil) }
        overlayPanels = NSScreen.screens.map { screen in
            let panel = WindowSelectionPanel(screen: screen)
            panel.onStart = { [weak self] in
                self?.startSelectedWindow(token: token)
            }
            panel.onCancel = { [weak self] in
                self?.cancelSelection(token: token)
            }
            panel.onCanvasClick = { [weak self] point in
                self?.handleSelectionClick(at: point, token: token)
            }
            transition.present(panel)
            return panel
        }
        updateOverlays(for: nil)
    }

    private func makePointerScreenOverlayKey() {
        guard let index = CaptureOverlayScreenPolicy.keyScreenIndex(
            pointer: NSEvent.mouseLocation,
            screenFrames: overlayPanels.map(\.frame)
        ) else { return }
        let keyPanel = overlayPanels[index]
        keyPanel.makeKeyAndOrderFront(nil)
        keyPanel.makeKey()
    }

    private func installSelectionKeyMonitor(token: CaptureSelectionToken) {
        removeSelectionKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {
                self?.cancelSelection(token: token)
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                self?.startSelectedWindow(token: token)
                return nil
            }
            return event
        }
    }

    private func removeSelectionKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func cancelSelection(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        closeSelection(animated: true)
        onCancel?(token)
    }

    private func refreshAndTrackSelection(token: CaptureSelectionToken) async {
        guard activeToken == token else { return }
        if let pendingSelectionClick,
           !isClickTargetStillValid(pendingSelectionClick) {
            invalidatePendingSelectionClick()
        }
        if windows.isEmpty || refreshCounter % 8 == 0 || pendingSelectionClick != nil {
            let pendingClickAtRefresh = pendingSelectionClick
            let refreshedWindows = try? await CaptureWindowInfo.available(
                onScreenOnly: !CommandLine.arguments.contains("--design-review")
            )
            guard activeToken == token, !Task.isCancelled else { return }
            // A successful empty catalog means the window disappeared. A
            // transient ScreenCaptureKit error must not impersonate that state.
            if let refreshedWindows {
                windows = refreshedWindows
                if let pendingClickAtRefresh {
                    completeSelectionClick(pendingClickAtRefresh)
                } else if let pendingSelectionClick,
                          windows.contains(where: { $0.id == pendingSelectionClick.windowID }) {
                    // A click made during the initial catalog fetch may use its
                    // exact identity as soon as that identity becomes available.
                    completeSelectionClick(pendingSelectionClick)
                }
            }
        }
        guard activeToken == token, !Task.isCancelled else { return }
        refreshCounter += 1

        if let selectedWindowID {
            let geometry = validGeometry(for: selectedWindowID)
            guard let selectedWindow = CaptureWindowSelectionPolicy.lockedWindow(
                id: selectedWindowID,
                catalog: windows,
                geometry: geometry
            ) else {
                unlockMissingSelection(token: token)
                return
            }
            guard hoveredWindow != selectedWindow || trackedGeometry != geometry else { return }
            hoveredWindow = selectedWindow
            trackedGeometry = geometry
            updateOverlays(for: selectedWindow, targetFrameOverride: geometry?.frame)
            return
        }
        refreshHoverHighlight(token: token)
    }

    private func refreshHoverHighlight(token: CaptureSelectionToken, forceUpdate: Bool = false) {
        guard activeToken == token, !isRecordingHighlight, selectedWindowID == nil else { return }
        let pointer = NSEvent.mouseLocation
        let candidate: CaptureWindowInfo?
        let geometry: CaptureWindowGeometry?
        if let windowID = frontmostWindowID(at: quartzPoint(for: pointer)),
           let window = windows.first(where: { $0.id == windowID }),
           let currentGeometry = validGeometry(for: windowID),
           currentGeometry.frame.contains(pointer) {
            candidate = window
            geometry = currentGeometry
        } else {
            candidate = nil
            geometry = nil
        }
        guard forceUpdate || hoveredWindow != candidate || trackedGeometry != geometry else { return }
        hoveredWindow = candidate
        trackedGeometry = geometry
        updateOverlays(for: candidate, targetFrameOverride: geometry?.frame)
    }

    private func frontmostWindowID(at quartzPoint: CGPoint) -> UInt32? {
        guard let windowDescriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for description in windowDescriptions {
            let ownerPID = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let windowID = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let layer = (description[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let alpha = (description[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            guard ownerPID != getpid() || CaptureEditorWindows.shared.includes(windowID),
                  layer == 0, alpha > 0.01,
                  let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.contains(quartzPoint)
            else { continue }

            // Snapshot the exact visible surface at the event point. Catalog
            // validation happens later and never falls through to a window
            // hidden behind an unavailable target.
            return windowID
        }
        return nil
    }

    private func startSelectedWindow(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        guard let selectedWindow else { return }
        hoveredWindow = selectedWindow
        lockSelectionForRecording(windowID: selectedWindow.id)
        onSelect?(selectedWindow, token)
        onStart?(selectedWindow, token)
    }

    private func handleSelectionClick(
        at screenPoint: CGPoint,
        token: CaptureSelectionToken
    ) {
        guard activeToken == token else { return }
        guard !isRecordingHighlight else { return }
        invalidatePendingSelectionClick()

        if let selectedWindowID {
            let geometry = validGeometry(for: selectedWindowID)
            guard let selectedWindow = CaptureWindowSelectionPolicy.lockedWindow(
                id: selectedWindowID,
                catalog: windows,
                geometry: geometry
            ), let geometry else {
                unlockMissingSelection(token: token)
                return
            }
            guard !geometry.frame.contains(screenPoint) else {
                hoveredWindow = selectedWindow
                trackedGeometry = geometry
                updateOverlays(for: selectedWindow, targetFrameOverride: geometry.frame)
                return
            }
            unlockMissingSelection(token: token)
            return
        }

        guard let windowID = frontmostWindowID(at: quartzPoint(for: screenPoint)) else { return }
        let click = PendingSelectionClick(
            token: token,
            generation: selectionClickGeneration,
            screenPoint: screenPoint,
            windowID: windowID
        )
        pendingSelectionClick = click
        if windows.contains(where: { $0.id == windowID }) {
            completeSelectionClick(click)
        }
    }

    private func completeSelectionClick(_ click: PendingSelectionClick) {
        guard activeToken == click.token, !isRecordingHighlight,
              selectedWindowID == nil,
              pendingSelectionClick?.generation == click.generation,
              selectionClickGeneration == click.generation else { return }
        pendingSelectionClick = nil
        guard let window = windows.first(where: { $0.id == click.windowID }),
              let geometry = validGeometry(for: click.windowID),
              geometry.frame.contains(click.screenPoint),
              frontmostWindowID(at: quartzPoint(for: click.screenPoint)) == click.windowID else { return }
        hoveredWindow = window
        selectedWindowID = window.id
        trackedGeometry = geometry
        onSelect?(window, click.token)
        guard activeToken == click.token,
              selectionClickGeneration == click.generation,
              selectedWindowID == window.id else { return }
        updateOverlays(for: window, targetFrameOverride: geometry.frame)
    }

    private func isClickTargetStillValid(_ click: PendingSelectionClick) -> Bool {
        activeToken == click.token && selectionClickGeneration == click.generation
            && validGeometry(for: click.windowID)?.frame.contains(click.screenPoint) == true
            && frontmostWindowID(at: quartzPoint(for: click.screenPoint)) == click.windowID
    }

    private func invalidatePendingSelectionClick() {
        selectionClickGeneration &+= 1
        pendingSelectionClick = nil
    }

    private func validGeometry(for windowID: UInt32) -> CaptureWindowGeometry? {
        guard let geometry = geometryLookup(windowID), geometry.windowID == windowID,
              geometry.frame.minX.isFinite, geometry.frame.minY.isFinite,
              geometry.frame.width.isFinite, geometry.frame.height.isFinite,
              geometry.frame.width > 0, geometry.frame.height > 0 else { return nil }
        return geometry
    }

    private func recordingGuideWindow(
        windowID: UInt32,
        geometry: CaptureWindowGeometry
    ) -> CaptureWindowInfo? {
        guard geometry.windowID == windowID,
              let descriptions = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow, .excludeDesktopElements],
                CGWindowID(windowID)
              ) as? [[String: Any]],
              let description = descriptions.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
              }),
              (description[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let ownerPID = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              ownerPID != getpid() || CaptureEditorWindows.shared.includes(windowID) else { return nil }
        let application = NSRunningApplication(processIdentifier: ownerPID)
        let frame = geometry.frame
        return CaptureWindowInfo(
            id: windowID,
            title: description[kCGWindowName as String] as? String ?? "",
            applicationName: application?.localizedName
                ?? description[kCGWindowOwnerName as String] as? String
                ?? "应用窗口",
            applicationBundleIdentifier: application?.bundleIdentifier,
            applicationProcessID: ownerPID,
            frame: CGRect(
                x: frame.minX,
                y: CGDisplayBounds(CGMainDisplayID()).height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        )
    }

    private func unlockMissingSelection(token: CaptureSelectionToken) {
        guard activeToken == token, selectedWindowID != nil else { return }
        invalidatePendingSelectionClick()
        selectedWindowID = nil
        hoveredWindow = nil
        trackedGeometry = nil
        onUnlock?(token)
        guard activeToken == token, selectedWindowID == nil else { return }
        refreshHoverHighlight(token: token, forceUpdate: true)
    }

    private func updateOverlays(
        for window: CaptureWindowInfo?,
        targetFrameOverride: CGRect? = nil,
        orderFront: Bool = true
    ) {
        let targetFrame = targetFrameOverride ?? window.map { appKitFrame(for: $0.frame) }
        let controlPanel = targetFrame.flatMap { target in
            CaptureOverlayScreenPolicy.largestIntersectionIndex(
                targetFrame: target,
                screenFrames: overlayPanels.map(\.frame)
            ).map { overlayPanels[$0] }
        }

        for panel in overlayPanels {
            let localCutout = targetFrame.map {
                $0.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
                    .intersection(panel.contentView?.bounds ?? .zero)
            }
            let showsControls = !isRecordingHighlight
                && selectedWindowID == window?.id
                && selectedWindowID != nil
                && window != nil
                && panel === controlPanel
            panel.update(
                cutoutFrame: localCutout,
                window: window,
                showsControls: showsControls,
                selectionLocked: selectedWindowID != nil,
                recordingHighlight: isRecordingHighlight
            )
            if orderFront { panel.orderFrontRegardless() }
        }
    }

    private func quartzPoint(for appKitPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: appKitPoint.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - appKitPoint.y
        )
    }

    private func appKitFrame(for quartzFrame: CGRect) -> CGRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: quartzFrame.minX,
            y: mainDisplayHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

private final class WindowSelectionPanel: NSPanel {
    var onStart: (() -> Void)? { didSet { selectionView.onStart = onStart } }
    var onCancel: (() -> Void)? { didSet { selectionView.onCancel = onCancel } }
    var onCanvasClick: ((CGPoint) -> Void)?

    private let selectionView = WindowSelectionOverlayView()
    private var retiring = false
    private var recordingGuide = false

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        identifier = windowSelectionOverlayIdentifier
        appearance = NSAppearance(named: .aqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .readOnly
        selectionView.frame = CGRect(origin: .zero, size: screen.frame.size)
        selectionView.autoresizingMask = [.width, .height]
        contentView = selectionView
        ignoresMouseEvents = false
        selectionView.onCanvasClick = { [weak self] localPoint in
            guard let self else { return }
            self.onCanvasClick?(CGPoint(
                x: self.frame.minX + localPoint.x,
                y: self.frame.minY + localPoint.y
            ))
        }
    }

    override var canBecomeKey: Bool { !retiring && !recordingGuide }
    override var canBecomeMain: Bool { !retiring && !recordingGuide }

    func prepareForRetirement() {
        retiring = true
        onStart = nil
        onCancel = nil
        onCanvasClick = nil
        selectionView.prepareForRetirement()
    }

    func update(
        cutoutFrame: CGRect?,
        window: CaptureWindowInfo?,
        showsControls: Bool,
        selectionLocked: Bool,
        recordingHighlight: Bool
    ) {
        recordingGuide = recordingHighlight
        level = CaptureWindowLevelPolicy.level(
            for: recordingHighlight ? .recordingGuideOverlay : .selectionOverlay
        )
        let icon = window.flatMap {
            NSRunningApplication(processIdentifier: $0.applicationProcessID)?.icon
        }
        selectionView.update(
            cutoutFrame: cutoutFrame,
            windowIdentity: window?.id,
            appName: window?.applicationName,
            windowTitle: window?.title,
            windowSize: window?.frame.size,
            appIcon: icon,
            showsControls: showsControls,
            selectionLocked: selectionLocked,
            recordingHighlight: recordingHighlight
        )
        sharingType = recordingHighlight ? .none : .readOnly
        ignoresMouseEvents = recordingHighlight
    }
}

private final class WindowSelectionOverlayView: NSView {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCanvasClick: ((CGPoint) -> Void)?
    private let dimmingLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let card = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let separator = NSView()
    private let cancelButton = CaptureSelectionNativeButton()
    private let startButton = CaptureSelectionNativeButton()
    private var cutoutFrame: CGRect?
    private var windowIdentity: UInt32?
    private var showsControls = false
    private var selectionLocked = false
    private var recordingHighlight = false
    private var thumbnailTask: Task<Void, Never>?
    private var acceptsSelectionInput = true
    private let cardTransition = CaptureSelectionCardTransition()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubviews()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configureSubviews() }

    private func configureSubviews() {
        wantsLayer = true
        dimmingLayer.fillRule = .evenOdd
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = captureSelectionAccentNSColor.withAlphaComponent(0.95).cgColor
        layer?.addSublayer(dimmingLayer)
        layer?.addSublayer(outlineLayer)
        card.wantsLayer = true
        card.layer?.backgroundColor = captureSelectionSurfaceNSColor.cgColor
        card.layer?.cornerRadius = 20
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        card.layer?.borderWidth = 1
        card.layer?.shadowColor = NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.27, alpha: 1).cgColor
        card.layer?.shadowOpacity = 0.12
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(card)
        card.isHidden = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 8
        iconView.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = captureSelectionInkNSColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = captureSelectionInkNSColor.withAlphaComponent(0.6)
        detailLabel.lineBreakMode = .byTruncatingTail
        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已选择")
        checkmark.contentTintColor = captureSelectionAccentNSColor
        separator.wantsLayer = true
        separator.layer?.backgroundColor = captureSelectionInkNSColor.withAlphaComponent(0.08).cgColor
        for view in [iconView, titleLabel, detailLabel, checkmark, separator, cancelButton, startButton] { card.addSubview(view) }
        for button in [cancelButton, startButton] {
            button.isBordered = false
            button.focusRingType = .none
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.wantsLayer = true
            button.layer?.cornerRadius = 11
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.065).cgColor
            button.layer?.borderWidth = 0.75
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = 0.07
            button.layer?.shadowRadius = 4
            button.layer?.shadowOffset = CGSize(width: 0, height: -2)
            button.target = self
        }
        cancelButton.title = "取消"
        cancelButton.contentTintColor = captureSelectionInkNSColor
        cancelButton.layer?.backgroundColor = NSColor.white.cgColor
        cancelButton.action = #selector(cancelSelection(_:))
        startButton.contentTintColor = .white
        startButton.captureKeyboardFocusColor = NSColor.white.withAlphaComponent(0.65)
        startButton.layer?.backgroundColor = captureSelectionPlatinumNSColor.cgColor
        startButton.action = #selector(startRecording(_:))
    }

    func update(cutoutFrame: CGRect?, windowIdentity: UInt32?, appName: String?, windowTitle: String?,
                windowSize: CGSize?, appIcon: NSImage?, showsControls: Bool, selectionLocked: Bool, recordingHighlight: Bool) {
        let targetChanged = self.windowIdentity != windowIdentity
        let firstLock = selectionLocked && !self.selectionLocked
        let highlightChanged = recordingHighlight != self.recordingHighlight
        let previousDimmingColor = dimmingLayer.presentation()?.fillColor ?? dimmingLayer.fillColor
        self.cutoutFrame = cutoutFrame
        self.windowIdentity = windowIdentity
        self.showsControls = appName != nil && showsControls && !recordingHighlight
        self.selectionLocked = selectionLocked
        self.recordingHighlight = recordingHighlight
        if self.showsControls {
            titleLabel.stringValue = appName ?? ""
            detailLabel.stringValue = windowTitle?.isEmpty == false ? windowTitle! : windowSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? ""
        }
        checkmark.isHidden = !selectionLocked
        cancelButton.isEnabled = self.showsControls
        startButton.isEnabled = selectionLocked && self.showsControls
        startButton.alphaValue = selectionLocked ? 1 : 0.5
        startButton.attributedTitle = NSAttributedString(string: selectionLocked ? "开始录制   ⌘R" : "单击窗口以锁定", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        if targetChanged {
            thumbnailTask?.cancel()
        }
        if (targetChanged || firstLock), self.showsControls { iconView.image = appIcon }
        if (targetChanged || firstLock), selectionLocked, let windowIdentity {
            thumbnailTask = Task { [weak self] in
                let image = await RecorderSourceThumbnail.image(windowID: windowIdentity)
                guard !Task.isCancelled, let self, self.windowIdentity == windowIdentity, let image else { return }
                self.iconView.image = image
            }
        }
        if recordingHighlight { thumbnailTask?.cancel() }
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
        if highlightChanged, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let tint = CABasicAnimation(keyPath: "fillColor")
            tint.fromValue = previousDimmingColor
            tint.toValue = dimmingLayer.fillColor
            tint.duration = 0.18
            tint.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimmingLayer.add(tint, forKey: "recording-highlight-tint")
        }
    }

    func prepareForRetirement() {
        acceptsSelectionInput = false
        onStart = nil
        onCancel = nil
        onCanvasClick = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        cardTransition.stop()
        cancelButton.isEnabled = false
        startButton.isEnabled = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsSelectionInput, !recordingHighlight else { return nil }
        guard showsControls else { return self }
        let visibleFrame = cardTransition.visibleFrame(of: card)
        guard visibleFrame.contains(point) else { return self }
        return card.hitTest(CGPoint(
            x: point.x - visibleFrame.minX + card.frame.minX,
            y: point.y - visibleFrame.minY + card.frame.minY
        )) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsSelectionInput, !recordingHighlight else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !showsControls || !cardTransition.visibleFrame(of: card).contains(point) else { return }
        onCanvasClick?(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateSelectionMask()
        guard let target = cutoutFrame, showsControls else {
            cardTransition.hide(card)
            return
        }
        cardTransition.show(card, at: confirmationCardFrame(for: target))
        iconView.frame = CGRect(x: 18, y: 101, width: 70, height: 50)
        titleLabel.frame = CGRect(x: 101, y: 126, width: 205, height: 20)
        detailLabel.frame = CGRect(x: 101, y: 106, width: 205, height: 16)
        checkmark.frame = CGRect(x: 312, y: 119, width: 18, height: 18)
        separator.frame = CGRect(x: 18, y: 75, width: card.bounds.width - 36, height: 1)
        cancelButton.frame = CGRect(x: 18, y: 22, width: 74, height: 36)
        startButton.frame = CGRect(x: card.bounds.width - 160, y: 22, width: 142, height: 36)
    }
    @objc private func startRecording(_ sender: Any?) {
        guard acceptsSelectionInput, showsControls, selectionLocked else { return }
        onStart?()
    }
    @objc private func cancelSelection(_ sender: Any?) {
        guard acceptsSelectionInput, showsControls else { return }
        onCancel?()
    }

    /// An independent, full-screen shape keeps the outside dimmed while the
    /// confirmation card and its preview update. The chosen window is a hole.
    private func updateSelectionMask() {
        let visibleTarget = cutoutFrame?.intersection(bounds)
        let hasTarget = visibleTarget.map {
            !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1
        } ?? false
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        var borderPath: CGPath?
        if hasTarget, let target = visibleTarget {
            maskPath.addRoundedRect(in: target.insetBy(dx: -1, dy: -1), cornerWidth: 9, cornerHeight: 9)
            borderPath = CGPath(roundedRect: target.insetBy(dx: 1.5, dy: 1.5),
                                cornerWidth: 9, cornerHeight: 9, transform: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimmingLayer.frame = bounds
        dimmingLayer.path = maskPath
        dimmingLayer.fillColor = NSColor.black.withAlphaComponent(recordingHighlight ? 0.58 : 0.42).cgColor
        outlineLayer.frame = bounds
        outlineLayer.path = borderPath
        outlineLayer.lineWidth = recordingHighlight ? 3 : (selectionLocked ? 3 : 2)
        CATransaction.commit()
    }

    private func confirmationCardFrame(for target: CGRect) -> CGRect {
        let size = CGSize(width: 350, height: 178)
        let centerX = min(max(target.midX, size.width / 2 + 20), bounds.maxX - size.width / 2 - 20)
        let above = target.maxY + 16
        let below = target.minY - size.height - 16
        let y: CGFloat
        if below >= bounds.minY + 20 { y = below }
        else if above + size.height <= bounds.maxY - 20 { y = above }
        else { y = min(max(target.maxY - size.height - 22, bounds.minY + 20), bounds.maxY - size.height - 20) }
        return CGRect(x: centerX - size.width / 2, y: y, width: size.width, height: size.height)
    }
}
