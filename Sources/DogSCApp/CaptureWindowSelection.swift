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
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
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
                      bundleIdentifier != ownBundleIdentifier,
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
    var onSelect: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)?
    var onUnlock: ((CaptureSelectionToken) -> Void)?
    var onStart: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)?
    var onCancel: ((CaptureSelectionToken) -> Void)?
    var onAutomaticallyCreatesZoomsChange: ((Bool) -> Void)?

    private var overlayPanels: [WindowSelectionPanel] = []
    private var pollingTask: Task<Void, Never>?
    private var localKeyMonitor: Any?
    private var windows: [CaptureWindowInfo] = []
    private var hoveredWindow: CaptureWindowInfo?
    private var selectedWindowID: UInt32?
    private var refreshCounter = 0
    private var isRecordingHighlight = false
    private var activeToken: CaptureSelectionToken?
    private var presentedAutomaticallyCreatesZooms = true
    private var trackedGeometry: CaptureWindowGeometry?
    private let geometryLookup: @MainActor (UInt32) -> CaptureWindowGeometry?

    var isActive: Bool { pollingTask != nil || !overlayPanels.isEmpty }

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
                await self.refreshAndTrackPointer(token: token)
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        removeSelectionKeyMonitor()
        overlayPanels.forEach { $0.orderOut(nil) }
        overlayPanels = []
        hoveredWindow = nil
        selectedWindowID = nil
        refreshCounter = 0
        isRecordingHighlight = false
        activeToken = nil
        trackedGeometry = nil
    }

    func lockSelectionForRecording(windowID: UInt32) {
        guard let selected = windows.first(where: { $0.id == windowID })
                ?? hoveredWindow.flatMap({ $0.id == windowID ? $0 : nil }),
              let geometry = geometryLookup(windowID),
              geometry.windowID == windowID else {
            stop()
            return
        }
        hoveredWindow = selected
        selectedWindowID = windowID
        pollingTask?.cancel()
        pollingTask = nil
        removeSelectionKeyMonitor()
        isRecordingHighlight = true
        overlayPanels.forEach { $0.ignoresMouseEvents = true }
        trackedGeometry = geometry
        updateOverlays(for: selected, targetFrameOverride: geometry.frame)
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

    func setAutomaticallyCreatesZooms(_ enabled: Bool) {
        guard presentedAutomaticallyCreatesZooms != enabled else { return }
        presentedAutomaticallyCreatesZooms = enabled
        overlayPanels.forEach { $0.automaticallyCreatesZooms = enabled }
        updateOverlays(
            for: hoveredWindow,
            targetFrameOverride: isRecordingHighlight ? trackedGeometry?.frame : nil
        )
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
            panel.onAutoZoomChanged = { [weak self] enabled in
                self?.onAutomaticallyCreatesZoomsChange?(enabled)
            }
            panel.automaticallyCreatesZooms = presentedAutomaticallyCreatesZooms
            panel.orderFrontRegardless()
            animateRecorderOverlayIn(panel)
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
        stop()
        onCancel?(token)
    }

    private func refreshAndTrackPointer(token: CaptureSelectionToken) async {
        guard activeToken == token else { return }
        if windows.isEmpty || refreshCounter % 8 == 0 {
            let refreshedWindows = try? await CaptureWindowInfo.available(
                onScreenOnly: !CommandLine.arguments.contains("--design-review")
            )
            guard activeToken == token, !Task.isCancelled else { return }
            // A successful empty catalog means the window disappeared. A
            // transient ScreenCaptureKit error must not impersonate that state.
            if let refreshedWindows {
                windows = refreshedWindows
            }
        }
        guard activeToken == token, !Task.isCancelled else { return }
        refreshCounter += 1

        if let selectedWindowID {
            let geometry = geometryLookup(selectedWindowID)
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

        let appKitPointer = NSEvent.mouseLocation
        if overlayPanels.contains(where: { $0.containsConfirmationControls(at: appKitPointer) }) {
            return
        }
        let pointerIsInsideRecorderWindow = isPointerInsideRecorderWindow(appKitPointer)
        let frontmostCandidate: CaptureWindowInfo?
        if pointerIsInsideRecorderWindow {
            frontmostCandidate = nil
        } else {
            let quartzPointer = CGEvent(source: nil)?.location
            frontmostCandidate = quartzPointer.flatMap(frontmostWindow(at:))
        }
        var candidate = CaptureWindowSelectionPolicy.hover(
            previous: hoveredWindow,
            pointerIsInsideRecorderWindow: pointerIsInsideRecorderWindow,
            frontmostCandidate: frontmostCandidate
        )
        if candidate == nil, CommandLine.arguments.contains("--design-review") {
            candidate = windows.max {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }
        }
        guard candidate != hoveredWindow else { return }
        hoveredWindow = candidate
        updateOverlays(for: candidate)
    }

    private func frontmostWindow(at quartzPoint: CGPoint) -> CaptureWindowInfo? {
        guard let windowDescriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let candidatesByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        for description in windowDescriptions {
            let ownerPID = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (description[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let alpha = (description[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            guard ownerPID != getpid(), layer == 0, alpha > 0.01,
                  let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.contains(quartzPoint)
            else { continue }

            let windowID = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            if let exactMatch = candidatesByID[windowID] {
                return exactMatch
            }

            // The first non-recorder layer-0 window is the visible surface at the
            // pointer. If ScreenCaptureKit cannot capture that exact surface, do
            // not fall through to a different window hidden behind it.
            return nil
        }
        return nil
    }

    private func startSelectedWindow(token: CaptureSelectionToken) {
        guard activeToken == token else { return }
        guard let selectedWindow else { return }
        hoveredWindow = selectedWindow
        onSelect?(selectedWindow, token)
        onStart?(selectedWindow, token)
    }

    private func handleSelectionClick(
        at screenPoint: CGPoint,
        token: CaptureSelectionToken
    ) {
        guard activeToken == token else { return }
        guard !isRecordingHighlight else { return }

        if let selectedWindow {
            guard !appKitFrame(for: selectedWindow.frame).contains(screenPoint) else { return }
            selectedWindowID = nil
            hoveredWindow = nil
            trackedGeometry = nil
            onUnlock?(token)
            updateOverlays(for: nil)
            return
        }

        guard let hoveredWindow,
              appKitFrame(for: hoveredWindow.frame).contains(screenPoint) else { return }
        selectedWindowID = hoveredWindow.id
        trackedGeometry = geometryLookup(hoveredWindow.id)
        onSelect?(hoveredWindow, token)
        updateOverlays(for: hoveredWindow, targetFrameOverride: trackedGeometry?.frame)
    }

    private func unlockMissingSelection(token: CaptureSelectionToken) {
        guard activeToken == token, selectedWindowID != nil else { return }
        selectedWindowID = nil
        hoveredWindow = nil
        trackedGeometry = nil
        onUnlock?(token)
        updateOverlays(for: nil)
    }

    private func updateOverlays(
        for window: CaptureWindowInfo?,
        targetFrameOverride: CGRect? = nil
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
                && window != nil
                && panel === controlPanel
            panel.automaticallyCreatesZooms = presentedAutomaticallyCreatesZooms
            panel.update(
                cutoutFrame: localCutout,
                window: window,
                showsControls: showsControls,
                selectionLocked: selectedWindowID != nil,
                recordingHighlight: isRecordingHighlight
            )
            panel.orderFrontRegardless()
        }
    }

    private func isPointerInsideRecorderWindow(_ pointer: CGPoint) -> Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible
                && window.identifier != windowSelectionOverlayIdentifier
                && window.frame.contains(pointer)
        }
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
    var onAutoZoomChanged: ((Bool) -> Void)?
    var automaticallyCreatesZooms = true

    private let selectionView = WindowSelectionOverlayView()

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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func update(
        cutoutFrame: CGRect?,
        window: CaptureWindowInfo?,
        showsControls: Bool,
        selectionLocked: Bool,
        recordingHighlight: Bool
    ) {
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

    func containsConfirmationControls(at screenPoint: CGPoint) -> Bool {
        guard frame.contains(screenPoint) else { return false }
        let localPoint = CGPoint(
            x: screenPoint.x - frame.minX,
            y: screenPoint.y - frame.minY
        )
        return selectionView.containsConfirmationControls(at: localPoint)
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
        startButton.layer?.backgroundColor = captureSelectionPlatinumNSColor.cgColor
        startButton.action = #selector(startRecording(_:))
    }

    func update(cutoutFrame: CGRect?, windowIdentity: UInt32?, appName: String?, windowTitle: String?,
                windowSize: CGSize?, appIcon: NSImage?, showsControls: Bool, selectionLocked: Bool, recordingHighlight: Bool) {
        let targetChanged = self.windowIdentity != windowIdentity
        let firstLock = selectionLocked && !self.selectionLocked
        let wasHidden = card.isHidden
        self.cutoutFrame = cutoutFrame
        self.windowIdentity = windowIdentity
        self.showsControls = showsControls
        self.selectionLocked = selectionLocked
        self.recordingHighlight = recordingHighlight
        card.isHidden = appName == nil || !showsControls || recordingHighlight
        titleLabel.stringValue = appName ?? ""
        detailLabel.stringValue = windowTitle?.isEmpty == false ? windowTitle! : windowSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? ""
        checkmark.isHidden = !selectionLocked
        startButton.isEnabled = selectionLocked
        startButton.alphaValue = selectionLocked ? 1 : 0.5
        startButton.attributedTitle = NSAttributedString(string: selectionLocked ? "开始录制   ⌘R" : "单击窗口以锁定", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        if targetChanged {
            thumbnailTask?.cancel()
            iconView.image = appIcon
        }
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
        if (wasHidden || targetChanged), !card.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0
            opacity.toValue = 1
            opacity.duration = 0.18
            card.layer?.add(opacity, forKey: "entrance-opacity")
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -5
            move.toValue = 0
            move.duration = 0.18
            card.layer?.add(move, forKey: "entrance-position")
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !recordingHighlight else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard card.isHidden || !card.frame.contains(point) else { return }
        onCanvasClick?(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func containsConfirmationControls(at point: CGPoint) -> Bool { !card.isHidden && card.frame.contains(point) }

    override func layout() {
        super.layout()
        updateSelectionMask()
        guard let target = cutoutFrame, !card.isHidden else { return }
        card.frame = confirmationCardFrame(for: target)
        iconView.frame = CGRect(x: 18, y: 101, width: 70, height: 50)
        titleLabel.frame = CGRect(x: 101, y: 126, width: 205, height: 20)
        detailLabel.frame = CGRect(x: 101, y: 106, width: 205, height: 16)
        checkmark.frame = CGRect(x: 312, y: 119, width: 18, height: 18)
        separator.frame = CGRect(x: 18, y: 75, width: card.bounds.width - 36, height: 1)
        cancelButton.frame = CGRect(x: 18, y: 22, width: 74, height: 36)
        startButton.frame = CGRect(x: card.bounds.width - 160, y: 22, width: 142, height: 36)
    }
    @objc private func startRecording(_ sender: Any?) { guard selectionLocked else { return }; onStart?() }
    @objc private func cancelSelection(_ sender: Any?) { onCancel?() }

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
