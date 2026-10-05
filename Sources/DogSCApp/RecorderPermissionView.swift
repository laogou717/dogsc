import AppKit
import SwiftUI

let permissionOnboardingWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.permission-onboarding"
)

enum RequiredRecordingPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: appLocalized("屏幕录制")
        case .accessibility: appLocalized("辅助功能")
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: appLocalized("录制屏幕、窗口或区域")
        case .accessibility: appLocalized("记录鼠标移动与点击")
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: "display"
        case .accessibility: "accessibility"
        }
    }

    var settingsSection: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
    }

    var settingsListName: String {
        switch self {
        case .screenRecording: appLocalized("屏幕与系统音频录制")
        case .accessibility: appLocalized("辅助功能")
        }
    }

    @MainActor
    func isGranted(in model: AppModel) -> Bool {
        switch self {
        case .screenRecording: model.hasScreenRecordingPermissionForOnboarding
        case .accessibility: model.hasAccessibilityPermission
        }
    }
}

struct DraggableApplicationIcon: NSViewRepresentable {
    let applicationURL: URL
    let onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> ApplicationBundleDragView {
        ApplicationBundleDragView(
            applicationURL: applicationURL,
            onDragEnded: onDragEnded
        )
    }

    func updateNSView(_ nsView: ApplicationBundleDragView, context: Context) {
        nsView.applicationURL = applicationURL
        nsView.onDragEnded = onDragEnded
    }
}

@MainActor
final class ApplicationBundleDragView: NSView, NSDraggingSource {
    var applicationURL: URL {
        didSet {
            guard oldValue != applicationURL else { return }
            icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            needsDisplay = true
        }
    }
    var onDragEnded: (Bool) -> Void
    private var icon: NSImage
    private var isDraggingApplication = false

    init(
        applicationURL: URL,
        onDragEnded: @escaping (Bool) -> Void
    ) {
        self.applicationURL = applicationURL
        self.onDragEnded = onDragEnded
        icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel("可拖动的 \(AppIdentity.displayName) 应用图标")
        setAccessibilityHelp("拖到系统设置的应用列表")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon.draw(
            in: bounds.insetBy(dx: 9, dy: 9),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingApplication else { return }
        isDraggingApplication = true
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDraggingApplication = false
        onDragEnded(operation != [])
    }
}

@MainActor
final class RequiredPermissionWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let presentation: PermissionOnboardingPresentation
    private let hostingController: NSHostingController<RequiredRecordingPermissionView>
    private let windowController: NSWindowController
    private lazy var introduction = FirstLaunchIntroduction(presentation: presentation)
    private lazy var dragAssistant = PermissionDragAssistantWindowController(
        onAcceptedApplicationDrop: { [weak self] in
            self?.yieldToSystemSettingsAuthorization()
        }
    )
    private var hasPositionedWindow = false
    private var isManualPresentation = false

    init(model: AppModel) {
        self.model = model
        let presentation = PermissionOnboardingPresentation()
        self.presentation = presentation
        hostingController = NSHostingController(
            rootView: RequiredRecordingPermissionView(model: model, presentation: presentation)
        )
        let window = EscapeDismissibleWindow(
            contentRect: NSRect(origin: .zero, size: PermissionOnboardingStyle.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        windowController = NSWindowController(window: window)
        super.init()
        window.identifier = permissionOnboardingWindowIdentifier
        window.title = String(format: appLocalized("开始使用 %@"), AppIdentity.displayName)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = PermissionOnboardingStyle.background
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.setFrame(NSRect(origin: .zero, size: PermissionOnboardingStyle.size), display: false)
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isHidden = true
        configurePage()
    }

    var isVisible: Bool { introduction.isPresenting || windowController.window?.isVisible == true }
    var isManualGuideActive: Bool { isManualPresentation }

    func present() {
        guard let window = windowController.window else { return }
        guard !isVisible else { return }
        if !hasPositionedWindow {
            positionAtVisualCenter(window)
            hasPositionedWindow = true
        }
        let shouldPlay = !UserDefaults.standard.bool(forKey: FirstLaunchIntroduction.seenKey)
            && !model.hasCompletedRequiredPermissionOnboarding
        show(window, playIntroduction: shouldPlay)
    }

    func hide() {
        // Readiness publications must not close a manually opened guide.
        // Preparation/recording phases still always dismiss it.
        if isManualPresentation, model.phase == .setup || model.phase == .editor { return }
        if isManualPresentation {
            isManualPresentation = false
            configurePage()
        }
        FirstUseTourController.controller(for: .permissions).suspend()
        introduction.cancel()
        presentation.isTourReady = false
        dragAssistant.hide()
        windowController.window?.orderOut(nil)
        FirstUseTourController.setPermissionPagePresented(false)
    }

    func bringToFront() {
        guard !introduction.isPresenting else { return }
        guard let window = windowController.window else { return }
        if !hasPositionedWindow {
            positionAtVisualCenter(window)
            hasPositionedWindow = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        clearAutomaticControlFocus(in: window)
    }

    func showDragAssistant(for permission: RequiredRecordingPermissionKind) {
        FirstUseTourController.controller(for: .permissions).suspend()
        introduction.cancel()
        dragAssistant.show(
            permission: permission,
            applicationURL: Bundle.main.bundleURL
        )
    }

    /// A real guide preview, without resetting TCC or replacing the project.
    func presentManually() {
        guard model.phase == .setup || model.phase == .editor,
              let window = windowController.window, !introduction.isPresenting else { return }
        isManualPresentation = true
        FirstUseTourController.setPermissionPagePresented(true)
        FirstUseTourController.controller(for: .recorder).suspend()
        FirstUseTourController.controller(for: .editor).suspend()
        FirstUseTourController.controller(for: .permissions).replay()
        configurePage()
        positionAtVisualCenter(window)
        hasPositionedWindow = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        show(window, playIntroduction: true)
    }

    private func show(_ window: NSWindow, playIntroduction: Bool) {
        FirstUseTourController.setPermissionPagePresented(true)
        NSApp.activate(ignoringOtherApps: true)
        presentation.isTourReady = false
        if playIntroduction {
            introduction.play(over: window) { [weak self, weak window] in
                guard let self, let window, window.isVisible else { return }
                self.clearAutomaticControlFocus(in: window)
                self.presentation.isTourReady = true
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            clearAutomaticControlFocus(in: window)
            presentation.isTourReady = true
        }
    }

    private func configurePage() {
        FirstUseTourController.controller(for: .permissions).configurePermissions(
            access: model.permissionTourAccess, isReview: isManualPresentation,
            openSettings: { [weak self] step in
                guard let self else { return }
                self.openSettings(step == .screen ? .screenRecording : .accessibility)
            },
            onContinue: { [weak self] in self?.completePage() },
            refresh: { [weak model] in
                guard let model else { return .init(screen: false, accessibility: false) }
                if model.phase == .setup {
                    await model.verifyRequiredRecordingPermissions()
                    // Coalesce with the page/activation check already in flight
                    // instead of briefly restoring a stale spotlight on return.
                    while model.isCheckingRequiredPermissions, !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(50)) }
                        catch { break }
                    }
                } else {
                    model.refreshRequiredRecordingPermissions()
                }
                return model.permissionTourAccess
            }
        )
        hostingController.rootView = RequiredRecordingPermissionView(
            model: model, presentation: presentation, isReview: isManualPresentation,
            onContinue: { [weak self] in self?.completePage() },
            onOpenSettings: { [weak self] permission in self?.openSettings(permission) }
        )
    }

    private func completePage() {
        guard model.hasRequiredRecordingPermissions else { return }
        let wasReview = isManualPresentation
        FirstUseTourController.controller(for: .permissions).completePermissions()
        isManualPresentation = false
        if model.showsRequiredPermissionGate { model.finishRequiredPermissionOnboarding() }
        hide()
        configurePage()
        WindowCoordinator.resumeWorkspaceAfterPermissionGuide(replay: wasReview)
    }

    private func openSettings(_ permission: RequiredRecordingPermissionKind) {
        FirstUseTourController.controller(for: .permissions).beginPermissionSettings(
            permission == .screenRecording ? .screen : .accessibility
        )
        introduction.cancel()
        if model.phase == .setup {
            model.openRequiredPermissionSettings(permission)
        } else if isManualPresentation,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsSection)") {
            NSWorkspace.shared.open(url)
            showDragAssistant(for: permission)
        }
    }

    /// Once System Settings accepts the dragged app, it may immediately show
    /// an administrator-password sheet. Leaving DogSC's onboarding window at
    /// the front makes that secure field reject typing with the system alert
    /// sound. Put the onboarding window behind the active settings window and
    /// explicitly hand activation back to System Settings. The permission
    /// poll keeps running, but only updates readiness. Returning to DogSC
    /// restores the next required step; Continue owns the workspace handoff.
    private func yieldToSystemSettingsAuthorization() {
        windowController.window?.orderBack(nil)
        PermissionDragAssistantWindowController.activateSystemSettings()
    }

    private func positionAtVisualCenter(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? window.screen
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        var frame = window.frame
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrame(frame.integral, display: false)
    }

    private func clearAutomaticControlFocus(in window: NSWindow) {
        window.makeFirstResponder(nil)
        // SwiftUI may propose its first button once more after the hosting view
        // completes the first layout pass. Clear that automatic proposal only;
        // a later Tab press can still focus controls normally.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isKeyWindow else { return }
            window.makeFirstResponder(nil)
        }
    }

    func refreshDragAssistantState() {
        guard let permission = dragAssistant.permission,
              permission.isGranted(in: model) else { return }
        dragAssistant.hide()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The user has returned to the permission page. Retain tour progress,
        // but remove the helper belonging to the System Settings visit.
        dragAssistant.hide()
    }

    func shutdown() {
        FirstUseTourController.controller(for: .permissions).suspend()
        introduction.cancel()
        presentation.isTourReady = false
        dragAssistant.shutdown()
        windowController.window?.orderOut(nil)
        windowController.window?.contentViewController = nil
        windowController.close()
    }

    func windowWillClose(_ notification: Notification) {
        let wasReview = isManualPresentation
        FirstUseTourController.controller(for: .permissions).suspend()
        introduction.cancel()
        presentation.isTourReady = false
        dragAssistant.hide()
        isManualPresentation = false
        configurePage()
        FirstUseTourController.setPermissionPagePresented(false)
        if wasReview { WindowCoordinator.resumeWorkspaceAfterPermissionGuide(replay: false) }
    }
}

@MainActor
private final class PermissionDragAssistantWindowController {
    private static let panelSize = NSSize(width: 640, height: 116)
    private static let attachmentGap: CGFloat = 10
    private static let screenInset: CGFloat = 12

    private var panel: NSPanel?
    private var hostingController: NSHostingController<PermissionDragAssistantView>?
    private var settingsFollowTask: Task<Void, Never>?
    private var hasSeenSystemSettingsWindow = false
    private var missingSystemSettingsSamples = 0
    private(set) var permission: RequiredRecordingPermissionKind?
    private let onAcceptedApplicationDrop: () -> Void

    init(onAcceptedApplicationDrop: @escaping () -> Void) {
        self.onAcceptedApplicationDrop = onAcceptedApplicationDrop
    }

    func show(
        permission: RequiredRecordingPermissionKind,
        applicationURL: URL
    ) {
        self.permission = permission
        let root = PermissionDragAssistantView(
            permission: permission,
            applicationURL: applicationURL,
            onApplicationDragEnded: { [weak self] accepted in
                self?.applicationDragEnded(accepted: accepted)
            }
        )
        let host: NSHostingController<PermissionDragAssistantView>
        if let hostingController {
            hostingController.rootView = root
            host = hostingController
        } else {
            host = NSHostingController(rootView: root)
            hostingController = host
        }
        host.sizingOptions = []

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // The helper must remain visible beside the active System
            // Settings window while the user is still dragging. It stops
            // floating and orders out as soon as that drag is accepted, before
            // the secure authorization sheet appears.
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.tabbingMode = .disallowed
            panel.appearance = NSAppearance(named: .aqua)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentMinSize = NSSize(width: 320, height: Self.panelSize.height)
            panel.contentMaxSize = NSSize(width: 10000, height: Self.panelSize.height)
            self.panel = panel
        }
        panel.contentViewController = host

        // The first visible frame already aligns with System Settings. Do not
        // flash a fallback-width helper while that application is launching.
        panel.orderOut(nil)
        beginFollowingSystemSettings()
    }

    private func applicationDragEnded(accepted: Bool) {
        guard accepted else { return }
        // The helper has completed its only job. Remove it before System
        // Settings asks for a password, then let the parent onboarding window
        // yield its ordering and activation as well.
        hide()
        onAcceptedApplicationDrop()
    }

    func hide() {
        settingsFollowTask?.cancel()
        settingsFollowTask = nil
        hasSeenSystemSettingsWindow = false
        missingSystemSettingsSamples = 0
        permission = nil
        panel?.orderOut(nil)
    }

    func shutdown() {
        settingsFollowTask?.cancel()
        settingsFollowTask = nil
        permission = nil
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel?.close()
        panel = nil
        hostingController = nil
    }

    private func beginFollowingSystemSettings() {
        settingsFollowTask?.cancel()
        hasSeenSystemSettingsWindow = false
        missingSystemSettingsSamples = 0
        settingsFollowTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.followSystemSettingsWindow()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func followSystemSettingsWindow() {
        guard let panel, permission != nil else { return }

        if hasSeenSystemSettingsWindow,
           let frontmostIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontmostIdentifier != "com.apple.systempreferences",
           frontmostIdentifier != Bundle.main.bundleIdentifier {
            hide()
            return
        }

        guard let settingsFrame = Self.systemSettingsWindowFrame(),
              let screen = Self.screen(containingMostOf: settingsFrame) else {
            missingSystemSettingsSamples += 1
            // Allow System Settings several seconds to launch on a cold Mac.
            // Once its window has existed, closing it removes the helper in
            // under half a second instead of leaving a permanent overlay.
            let limit = hasSeenSystemSettingsWindow ? 4 : 40
            if missingSystemSettingsSamples >= limit {
                hide()
            }
            return
        }
        hasSeenSystemSettingsWindow = true
        missingSystemSettingsSamples = 0
        let target = attachedFrame(
            to: settingsFrame,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func attachedFrame(
        to referenceFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        let width = min(referenceFrame.width, max(320, visibleFrame.width - Self.screenInset * 2))
        let minimumX = visibleFrame.minX + Self.screenInset
        let maximumX = max(
            visibleFrame.maxX - width - Self.screenInset,
            minimumX
        )
        let x = min(max(referenceFrame.minX, minimumX), maximumX)
        let belowY = referenceFrame.minY - panelSize.height - Self.attachmentGap
        let aboveY = referenceFrame.maxY + Self.attachmentGap
        let y: CGFloat
        if belowY >= visibleFrame.minY + Self.screenInset {
            y = belowY
        } else {
            y = min(
                aboveY,
                visibleFrame.maxY - panelSize.height - Self.screenInset
            )
        }
        return NSRect(x: x, y: y, width: width, height: Self.panelSize.height).integral
    }

    static func activateSystemSettings() {
        guard let application = systemSettingsApplication() else { return }
        application.activate(options: [.activateAllWindows])
    }

    private static func systemSettingsApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systempreferences"
        })
    }

    private static func systemSettingsWindowFrame() -> NSRect? {
        guard let application = systemSettingsApplication(),
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let candidate = windowInfo.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == application.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 480,
                  frame.height >= 320 else { return nil }
            return frame
        }
        .max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
        guard let candidate else { return nil }

        // CGWindow bounds use a top-left global origin; AppKit windows use a
        // bottom-left origin. The primary display's top edge is their bridge.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(
            x: candidate.minX,
            y: primaryTop - candidate.maxY,
            width: candidate.width,
            height: candidate.height
        ).integral
    }

    private static func screen(containingMostOf frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
        }
    }
}
