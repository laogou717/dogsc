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
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = CommandLine.arguments.contains("--design-review") ? .readOnly : .none
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

    private let iconContainerView = NSView()
    private let iconView = NSImageView()
    private let contextLabel = NSTextField(labelWithString: "将录制此窗口")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "点击「开始录制」或按 ⌘R 开始")
    private let cancelButton = NSButton()
    private let startButton = NSButton()
    private let startButtonGradient = CAGradientLayer()
    private var cutoutFrame: CGRect?
    private var windowIdentity: UInt32?
    private var showsControls = false
    private var selectionLocked = false
    private var recordingHighlight = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        configureSubviews()
    }

    private func configureSubviews() {
        iconContainerView.wantsLayer = true
        iconContainerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        iconContainerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        iconContainerView.layer?.borderWidth = 1
        iconContainerView.layer?.shadowColor = NSColor.black.cgColor
        iconContainerView.layer?.shadowOpacity = 0.34
        iconContainerView.layer?.shadowRadius = 8
        iconContainerView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(iconContainerView)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconContainerView.addSubview(iconView)

        contextLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        contextLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        contextLabel.lineBreakMode = .byTruncatingTail
        addSubview(contextLabel)

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.57)
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        shortcutLabel.font = .systemFont(ofSize: 11, weight: .medium)
        shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.46)
        shortcutLabel.alignment = .right
        addSubview(shortcutLabel)

        cancelButton.title = "取消"
        cancelButton.font = .systemFont(ofSize: 14, weight: .medium)
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        cancelButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        cancelButton.layer?.borderWidth = 1
        cancelButton.layer?.cornerRadius = 11
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection(_:))
        addSubview(cancelButton)

        let startTitle = NSMutableAttributedString(
            string: "开始录制",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        startTitle.append(NSAttributedString(
            string: "   ⌘R",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.68),
            ]
        ))
        startButton.attributedTitle = startTitle
        startButton.contentTintColor = .white
        startButton.isBordered = false
        startButton.wantsLayer = true
        startButton.layer?.backgroundColor = NSColor.clear.cgColor
        startButtonGradient.colors = [
            NSColor(calibratedRed: 0.36, green: 0.25, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.49, green: 0.24, blue: 1, alpha: 1).cgColor,
        ]
        startButtonGradient.startPoint = CGPoint(x: 0, y: 0.5)
        startButtonGradient.endPoint = CGPoint(x: 1, y: 0.5)
        startButton.layer?.insertSublayer(startButtonGradient, at: 0)
        startButton.layer?.cornerRadius = 11
        startButton.layer?.shadowColor = NSColor.systemPurple.cgColor
        startButton.layer?.shadowOffset = .zero
        startButton.layer?.shadowOpacity = 0.38
        startButton.layer?.shadowRadius = 9
        startButton.target = self
        startButton.action = #selector(startRecording(_:))
        addSubview(startButton)

        let pulse = CABasicAnimation(keyPath: "shadowRadius")
        pulse.fromValue = 7
        pulse.toValue = 12
        pulse.duration = 1.15
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        startButton.layer?.add(pulse, forKey: "recording-pulse")
    }

    func update(
        cutoutFrame: CGRect?,
        windowIdentity: UInt32?,
        appName: String?,
        windowTitle: String?,
        windowSize: CGSize?,
        appIcon: NSImage?,
        showsControls: Bool,
        selectionLocked: Bool,
        recordingHighlight: Bool
    ) {
        let targetChanged = windowIdentity != nil && windowIdentity != self.windowIdentity
        let lockChanged = selectionLocked != self.selectionLocked
        self.cutoutFrame = cutoutFrame
        self.windowIdentity = windowIdentity
        self.showsControls = showsControls
        self.selectionLocked = selectionLocked
        self.recordingHighlight = recordingHighlight
        iconView.image = appIcon
        contextLabel.stringValue = selectionLocked ? "已锁定此窗口" : "单击窗口以锁定"
        shortcutLabel.stringValue = selectionLocked
            ? "点击「开始录制」或按 ⌘R 开始"
            : "锁定后可移动鼠标并开始录制"
        startButton.isEnabled = selectionLocked
        startButton.alphaValue = selectionLocked ? 1 : 0.48
        titleLabel.stringValue = appName ?? ""
        let dimensions = windowSize.map {
            "\(Int($0.width.rounded())) × \(Int($0.height.rounded()))"
        } ?? ""
        let cleanedWindowTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detailLabel.stringValue = cleanedWindowTitle.isEmpty
            ? dimensions
            : [cleanedWindowTitle, dimensions].filter { !$0.isEmpty }.joined(separator: "  ·  ")

        let controlsHidden = appName == nil || !showsControls || recordingHighlight
        [iconContainerView, contextLabel, titleLabel, detailLabel, shortcutLabel, cancelButton, startButton]
            .forEach { $0.isHidden = controlsHidden }
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
        if (targetChanged || lockChanged) && !controlsHidden {
            animateIconSelection()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !recordingHighlight else { return }
        onCanvasClick?(convert(event.locationInWindow, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func containsConfirmationControls(at point: CGPoint) -> Bool {
        guard showsControls, !recordingHighlight, windowIdentity != nil,
              let target = cutoutFrame else { return false }
        return confirmationCardFrame(for: target).contains(point)
    }

    override func layout() {
        super.layout()
        guard let target = cutoutFrame,
              windowIdentity != nil,
              showsControls,
              !recordingHighlight else { return }
        let card = confirmationCardFrame(for: target)
        let scale = card.width / 780
        cancelButton.layer?.cornerRadius = 11 * scale
        startButton.layer?.cornerRadius = 11 * scale

        let iconContainerSize: CGFloat = 72 * scale
        iconContainerView.layer?.cornerRadius = 15 * scale
        iconContainerView.frame = CGRect(
            x: card.minX + 22 * scale,
            y: card.midY - iconContainerSize / 2,
            width: iconContainerSize,
            height: iconContainerSize
        )
        let iconInset = 9 * scale
        iconView.frame = CGRect(
            x: iconInset,
            y: iconInset,
            width: iconContainerSize - iconInset * 2,
            height: iconContainerSize - iconInset * 2
        )

        let cancelWidth: CGFloat = 82 * scale
        let startWidth: CGFloat = 160 * scale
        let buttonHeight: CGFloat = 48 * scale
        let startX = card.maxX - 22 * scale - startWidth
        startButton.frame = CGRect(
            x: startX,
            y: card.minY + 42 * scale,
            width: startWidth,
            height: buttonHeight
        )
        startButtonGradient.frame = startButton.bounds
        startButtonGradient.cornerRadius = 11 * scale
        cancelButton.frame = CGRect(
            x: startButton.frame.minX - 10 * scale - cancelWidth,
            y: startButton.frame.minY,
            width: cancelWidth,
            height: buttonHeight
        )

        let textX = iconContainerView.frame.maxX + 18 * scale
        let textWidth = max(120 * scale, cancelButton.frame.minX - textX - 24 * scale)
        contextLabel.frame = CGRect(
            x: textX,
            y: card.maxY - 31 * scale,
            width: textWidth,
            height: 15 * scale
        )
        titleLabel.frame = CGRect(
            x: textX,
            y: card.minY + 50 * scale,
            width: textWidth,
            height: 28 * scale
        )
        detailLabel.frame = CGRect(
            x: textX,
            y: card.minY + 28 * scale,
            width: textWidth,
            height: 17 * scale
        )
        shortcutLabel.frame = CGRect(
            x: cancelButton.frame.minX,
            y: card.minY + 15 * scale,
            width: startButton.frame.maxX - cancelButton.frame.minX,
            height: 14 * scale
        )
    }

    @objc private func startRecording(_ sender: Any?) {
        onStart?()
    }

    @objc private func cancelSelection(_ sender: Any?) {
        onCancel?()
    }

    private func animateIconSelection() {
        guard let layer = iconContainerView.layer else { return }
        layer.removeAnimation(forKey: "hover-bounce")
        let vertical = CAKeyframeAnimation(keyPath: "transform.translation.y")
        vertical.values = [0, 7, -2, 1, 0]
        vertical.keyTimes = [0, 0.28, 0.55, 0.76, 1]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.075, 0.985, 1.015, 1]
        scale.keyTimes = vertical.keyTimes
        let group = CAAnimationGroup()
        group.animations = [vertical, scale]
        group.duration = 0.52
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "hover-bounce")
    }

    override func draw(_ dirtyRect: NSRect) {
        let selectionTint = NSColor(
            calibratedRed: 0.025,
            green: 0.045,
            blue: 0.18,
            alpha: recordingHighlight ? 0 : 0.3
        )
        selectionTint.setFill()
        bounds.fill()

        let mask = NSBezierPath(rect: bounds)
        if let cutoutFrame, cutoutFrame.width > 1, cutoutFrame.height > 1 {
            mask.appendRoundedRect(cutoutFrame.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
        }
        mask.windingRule = .evenOdd
        NSColor(
            calibratedRed: 0.025,
            green: 0.045,
            blue: 0.18,
            alpha: recordingHighlight ? 0.58 : 0.54
        ).setFill()
        mask.fill()

        guard let target = cutoutFrame, target.width > 1, target.height > 1 else { return }
        let outline = NSBezierPath(
            roundedRect: target.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 9,
            yRadius: 9
        )
        NSColor(calibratedRed: 0.39, green: 0.26, blue: 1, alpha: 0.95).setStroke()
        outline.lineWidth = recordingHighlight ? 3 : (selectionLocked ? 5 : 4)
        outline.stroke()

        guard windowIdentity != nil, showsControls, !recordingHighlight else { return }
        let card = confirmationCardFrame(for: target)
        let radius = 18 * (card.width / 780)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.58)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = CGSize(width: 0, height: -9)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(
            calibratedRed: 0.045,
            green: 0.047,
            blue: 0.065,
            alpha: 0.95
        ).setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()
    }

    private func confirmationCardFrame(for target: CGRect) -> CGRect {
        let availableWidth = max(320, bounds.width - 40)
        let cardWidth = min(780, availableWidth)
        let size = CGSize(width: cardWidth, height: cardWidth / 6.4)
        let centerX = min(
            max(target.midX, size.width / 2 + 20),
            bounds.maxX - size.width / 2 - 20
        )
        let preferredAboveY = target.maxY + 16
        let preferredBelowY = target.minY - 16 - size.height
        let cardY: CGFloat
        if preferredAboveY + size.height <= bounds.maxY - 20 {
            cardY = preferredAboveY
        } else if preferredBelowY >= bounds.minY + 20 {
            cardY = preferredBelowY
        } else {
            cardY = min(
                max(target.maxY - size.height - 22, bounds.minY + 20),
                bounds.maxY - size.height - 20
            )
        }
        return CGRect(
            x: centerX - size.width / 2,
            y: cardY,
            width: size.width,
            height: size.height
        )
    }
}
