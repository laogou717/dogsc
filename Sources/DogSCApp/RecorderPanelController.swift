import AppKit
import OSLog
import QuartzCore
import SwiftUI

@MainActor
final class DogSCApplicationDelegate: NSObject,
    NSApplicationDelegate,
    NSMenuDelegate,
    NSMenuItemValidation {
    private var model: AppModel?
    /// Finder may deliver an `open urls` event before
    /// `applicationDidFinishLaunching`. Dropping it leaves the recorder bar
    /// open even though the user explicitly double-clicked a project.
    private var pendingProjectURL: URL?
    private var didFinishLaunching = false
    private let settingsWindowController = AppSettingsWindowController()
    private var settingsShortcutMonitor: Any?
    private var keyWindowObservation: NSObjectProtocol?

    /// Pure launch-order policy kept separate from AppKit callbacks so a cold
    /// open always consumes the pending project exactly once.
    static func projectURLToOpen(
        modelIsReady: Bool,
        pendingURL: URL?,
        incomingURL: URL?
    ) -> (pending: URL?, immediate: URL?) {
        guard modelIsReady else {
            return (incomingURL ?? pendingURL, nil)
        }
        // Readiness consumes the queued request exactly once. A newly delivered
        // URL wins; otherwise the launch-time pending URL is drained.
        return (nil, incomingURL ?? pendingURL)
    }
    private var statusItem: NSStatusItem?
    private let projectMediaMenuIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.project-media-menu"
    )
    private let projectMediaSeparatorIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu.project-media-separator"
    )
    private let exportProjectMediaItemIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu.export-project-media"
    )
    private let replaceCameraMediaItemIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu.replace-camera-media"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // APP-001 / UX-024 / APP-004: 应用图标为单一品牌资产（Info.plist
        // CFBundleIconFile -> AppIcon.icns），Dock、切换器与编辑器工具栏
        // 统一使用打包图标，不再在运行时更换。
        let model = AppModel()
        self.model = model
        WindowCoordinator.install(model: model)
        ProjectStore.synchronizeSystemRecentProjects()
        didFinishLaunching = true
        let launchOpen = Self.projectURLToOpen(
            modelIsReady: true,
            pendingURL: pendingProjectURL,
            incomingURL: nil
        )
        pendingProjectURL = launchOpen.pending
        if let url = launchOpen.immediate {
            model.requestOpenProject(at: url)
        }
        installStatusItem()
        installSettingsShortcutMonitor()
        installKeyWindowMenuRefresh()
        DispatchQueue.main.async { [weak self] in
            self?.refreshMainMenuBindings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let resolution = Self.projectURLToOpen(
            modelIsReady: didFinishLaunching && model != nil,
            pendingURL: pendingProjectURL,
            incomingURL: url
        )
        pendingProjectURL = resolution.pending
        if let immediate = resolution.immediate, let model {
            model.requestOpenProject(at: immediate)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Files can be renamed or removed in Finder while DogSC is inactive.
        // Keep the system-owned Dock recents honest when the app returns.
        ProjectStore.synchronizeSystemRecentProjects()
        model?.resumeRequiredPermissionOnboardingAfterActivation()
        refreshMainMenuBindings()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        WindowCoordinator.bringCurrentWindowFront()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsShortcutMonitor {
            NSEvent.removeMonitor(settingsShortcutMonitor)
            self.settingsShortcutMonitor = nil
        }
        if let keyWindowObservation {
            NotificationCenter.default.removeObserver(keyWindowObservation)
            self.keyWindowObservation = nil
        }
        // Tear down UI first so editor display links/players receive
        // onDisappear, then synchronously release idle capture device graphs.
        WindowCoordinator.shutdown()
        model?.shutdownForApplicationTermination()
        model = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// macOS already places NSDocumentController's recent files above this
    /// custom section and current windows below it. Keep this menu limited to
    /// app actions; repeating the project list here produced two competing
    /// recent-project sections in the same Dock menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        ProjectStore.synchronizeSystemRecentProjects()
        let menu = NSMenu(title: AppIdentity.displayName)
        menu.addItem(dockActionItem(
            title: "显示\(AppIdentity.displayName)",
            symbol: "macwindow",
            action: #selector(showCurrentWindowFromStatusItem(_:))
        ))
        menu.addItem(dockActionItem(
            title: "打开项目…",
            symbol: "folder",
            action: #selector(openProjectFromDock(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(dockActionItem(
            title: "设置…",
            symbol: "gearshape",
            action: #selector(openSettingsFromStatusItem(_:))
        ))
        return menu
    }

    private func dockActionItem(
        title: String,
        symbol: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )
        return item
    }

    @objc private func openProjectFromDock(_ sender: NSMenuItem) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        model?.openProjectPicker()
    }

    @objc private func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        // requestOpenProject 会处理当前阶段（编辑器时先安全保存、录制中提示）。
        model?.requestOpenProject(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let applicationName = AppIdentity.displayName
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // A full-colour Dock icon becomes a pale square at 18pt and is
            // illegible in the monochrome macOS status bar. Use the native
            // recording symbol here; the branded asset remains authoritative
            // for Dock, app switcher and the editor toolbar.
            let statusImage = NSImage(
                systemSymbolName: "record.circle",
                accessibilityDescription: applicationName
            ) ?? NSImage()
            statusImage.isTemplate = true
            button.image = statusImage
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = applicationName
            button.setAccessibilityLabel("\(applicationName)菜单")
        }

        let menu = NSMenu(title: applicationName)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildStatusMenu(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let applicationName = AppIdentity.displayName

        let showApp = NSMenuItem(
            title: "显示\(applicationName)",
            action: #selector(showCurrentWindowFromStatusItem(_:)),
            keyEquivalent: ""
        )
        showApp.target = self
        menu.addItem(showApp)

        let recentRoot = NSMenuItem(title: "最近项目", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "最近项目")
        let summaries = ProjectStore.recentProjectSummaries(limit: 8)
        if summaries.isEmpty {
            recentMenu.addItem(
                NSMenuItem(title: "暂无最近项目", action: nil, keyEquivalent: "")
            )
        } else {
            for summary in summaries {
                let recentItem = NSMenuItem(
                    title: summary.menuTitle,
                    action: #selector(openRecentProject(_:)),
                    keyEquivalent: ""
                )
                recentItem.target = self
                recentItem.representedObject = summary.url.path
                recentItem.toolTip = summary.url.path
                recentMenu.addItem(recentItem)
            }
        }
        recentRoot.submenu = recentMenu
        menu.addItem(recentRoot)
        menu.addItem(.separator())

        let sound = NSMenuItem(
            title: "导出完成提示音",
            action: #selector(toggleExportCompletionSound(_:)),
            keyEquivalent: ""
        )
        sound.target = self
        sound.state = AppPreferences.isExportCompletionSoundEnabled ? .on : .off
        menu.addItem(sound)

        menu.addItem(.separator())

        let systemAudio = NSMenuItem(
            title: "下次录制系统声音",
            action: #selector(toggleDefaultSystemAudio(_:)),
            keyEquivalent: ""
        )
        systemAudio.target = self
        systemAudio.state = AppPreferences.isDefaultSystemAudioRecordingEnabled
            ? .on : .off
        systemAudio.isEnabled = canChangeRecordingAudioDefaults
        menu.addItem(systemAudio)

        let microphoneName = UserDefaults.standard.string(
            forKey: CaptureDevicePreferenceKey.microphoneName
        )
        let microphone = NSMenuItem(
            title: microphoneName.map { "下次录制麦克风（\($0)）" }
                ?? "下次录制麦克风",
            action: #selector(toggleDefaultMicrophone(_:)),
            keyEquivalent: ""
        )
        microphone.target = self
        microphone.state = AppPreferences.isDefaultMicrophoneRecordingEnabled
            ? .on : .off
        microphone.isEnabled = canChangeRecordingAudioDefaults
        menu.addItem(microphone)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(openSettingsFromStatusItem(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出\(applicationName)",
            action: #selector(quitFromStatusItem(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func showCurrentWindowFromStatusItem(_ sender: NSMenuItem) {
        WindowCoordinator.bringCurrentWindowFront()
    }

    @objc private func toggleExportCompletionSound(_ sender: NSMenuItem) {
        let enabled = !AppPreferences.isExportCompletionSoundEnabled
        UserDefaults.standard.set(
            enabled,
            forKey: AppPreferences.exportCompletionSoundEnabledKey
        )
        sender.state = enabled ? .on : .off
    }

    private var canChangeRecordingAudioDefaults: Bool {
        guard let phase = model?.phase else { return false }
        return phase == .setup || phase == .editor
    }

    @objc private func toggleDefaultSystemAudio(_ sender: NSMenuItem) {
        guard canChangeRecordingAudioDefaults else { return }
        let enabled = !AppPreferences.isDefaultSystemAudioRecordingEnabled
        model?.setDefaultSystemAudioRecordingEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func toggleDefaultMicrophone(_ sender: NSMenuItem) {
        guard canChangeRecordingAudioDefaults else { return }
        let enabled = !AppPreferences.isDefaultMicrophoneRecordingEnabled
        model?.setDefaultMicrophoneRecordingEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func openSettingsFromStatusItem(_ sender: NSMenuItem) {
        settingsWindowController.show()
    }

    private func installSettingsShortcutMonitor() {
        guard settingsShortcutMonitor == nil else { return }
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let modifiers = event.modifierFlags.intersection([
                .command, .shift, .option, .control,
            ])
            guard modifiers == [.command],
                  event.charactersIgnoringModifiers == "," else { return event }
            self?.settingsWindowController.show()
            return nil
        }
    }

    @objc private func openAboutFromApplicationMenu(_ sender: NSMenuItem) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(sender)
    }

    /// SwiftUI contributes the standard application submenu, but this app's
    /// key windows are AppKit-owned. Retarget the two app-level actions so they
    /// remain available from the recorder, editor, and menu-bar extra alike.
    private func installApplicationMenuActions() {
        guard let applicationMenu = NSApplication.shared.mainMenu?.items.first?.submenu
        else { return }

        if let about = applicationMenu.items.first(where: {
            $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
                || $0.title.hasPrefix("关于")
        }) {
            about.target = self
            about.action = #selector(openAboutFromApplicationMenu(_:))
            about.isEnabled = true
        }

        if let settings = applicationMenu.items.first(where: {
            $0.keyEquivalent == "," || $0.title.hasPrefix("设置")
        }) {
            settings.target = self
            settings.action = #selector(openSettingsFromStatusItem(_:))
            settings.keyEquivalent = ","
            settings.keyEquivalentModifierMask = [.command]
            settings.isEnabled = true
        }

        if let quit = applicationMenu.items.first(where: {
            $0.action == #selector(NSApplication.terminate(_:))
                || $0.title.hasPrefix("退出")
        }) {
            quit.target = self
            quit.action = #selector(quitFromStatusItem(_:))
            quit.keyEquivalent = "q"
            quit.keyEquivalentModifierMask = [.command]
            quit.isEnabled = true
        }
    }

    /// SwiftUI can replace scene-contributed menu items when a sheet becomes
    /// key or hands focus back to its parent window. Reapply the small AppKit
    /// menu contract after that transition settles so File does not disappear
    /// and the unavailable generated Help menu cannot return.
    private func installKeyWindowMenuRefresh() {
        guard keyWindowObservation == nil else { return }
        keyWindowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshMainMenuBindings()
            }
        }
    }

    func refreshMainMenuBindings() {
        installApplicationMenuActions()
        EditorMenuBridge.shared.installMainMenuItems()
        installProjectMediaMenu()
        setMainMenuEditorMode(model?.phase == .editor)
    }

    func setMainMenuEditorMode(_ isEditor: Bool) {
        EditorMenuBridge.shared.setEditorMenuItemsVisible(isEditor)
    }

    @objc private func quitFromStatusItem(_ sender: NSMenuItem) {
        if EditorMenuBridge.shared.isEditorActive {
            EditorMenuBridge.shared.quitRequest.send()
        } else {
            NSApplication.shared.terminate(sender)
        }
    }

    private func installProjectMediaMenu() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }

        // Remove the former two-item top-level menu if this method is invoked
        // again in a process that installed the legacy layout.
        if let legacyRoot = mainMenu.items.first(where: {
            $0.identifier == projectMediaMenuIdentifier
        }) {
            mainMenu.removeItem(legacyRoot)
        }

        let fileMenuIdentifier = NSUserInterfaceItemIdentifier(
            "cn.laogou.dogsc.file-menu"
        )
        guard let fileMenu = mainMenu.items.first(where: {
            $0.identifier == fileMenuIdentifier
        })?.submenu else { return }
        guard !fileMenu.items.contains(where: {
            $0.action == #selector(exportProjectSourceMedia(_:))
                || $0.action == #selector(importCameraReplacement(_:))
        }) else { return }

        if !fileMenu.items.isEmpty {
            let separator = NSMenuItem.separator()
            separator.identifier = projectMediaSeparatorIdentifier
            fileMenu.addItem(separator)
        }

        let exportSources = NSMenuItem(
            title: "导出项目源文件…",
            action: #selector(exportProjectSourceMedia(_:)),
            keyEquivalent: ""
        )
        exportSources.target = self
        exportSources.identifier = exportProjectMediaItemIdentifier
        fileMenu.addItem(exportSources)

        let importAligned = NSMenuItem(
            title: "替换当前项目摄像头…",
            action: #selector(importCameraReplacement(_:)),
            keyEquivalent: ""
        )
        importAligned.target = self
        importAligned.identifier = replaceCameraMediaItemIdentifier
        fileMenu.addItem(importAligned)
    }

    @objc private func exportProjectSourceMedia(_ sender: NSMenuItem) {
        model?.exportCurrentProjectSourceMedia()
    }

    @objc private func importCameraReplacement(_ sender: NSMenuItem) {
        model?.importCameraReplacement()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(exportProjectSourceMedia(_:))
                || menuItem.action == #selector(importCameraReplacement(_:))
        else { return true }
        guard let model,
              model.phase == .editor,
              !model.isMediaExchangeRunning else { return false }
        if menuItem.action == #selector(importCameraReplacement(_:)) {
            return model.project.media?.camera != nil
                && !model.exporter.isExporting
        }
        return model.recordingURL != nil
    }
}

/// Pure geometry/style policy for the native recorder panel. Keeping the
/// canonical sizes outside AppKit keeps phase transitions deterministic and
/// prevents title-bar chrome from appearing between phases.
enum RecorderPanelPolicy {
    static let styleMask: NSWindow.StyleMask = [.borderless]
    static let setupSize = NSSize(width: setupWindowWidth(), height: 64)
    static let progressSize = NSSize(width: 320, height: 46)
    static let savedFrameKey = "recorder.panel.last-frame"

    static func contentSize(
        for phase: AppPhase,
        recordsMicrophone: Bool
    ) -> NSSize? {
        switch phase {
        case .setup:
            setupSize
        case .preparing, .finishing:
            progressSize
        case .recording:
            NSSize(
                width: recordingWindowWidth(recordsMicrophone: recordsMicrophone),
                height: 52
            )
        case .editor:
            nil
        }
    }

    /// Resize around the current visual center and clamp the result into the
    /// selected screen. This avoids the old left-edge anchored collapse and
    /// preserves the destination screen after a cross-display drag.
    static func frame(
        centeredOn currentFrame: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect?
    ) -> NSRect {
        var frame = NSRect(
            x: currentFrame.midX - contentSize.width / 2,
            y: currentFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        guard let visibleFrame else { return frame.integral }

        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            max(visibleFrame.maxX - frame.width, visibleFrame.minX)
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            max(visibleFrame.maxY - frame.height, visibleFrame.minY)
        )
        return frame.integral
    }

    static func initialFrame(
        contentSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: visibleFrame.midX - contentSize.width / 2,
            y: visibleFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        ).integral
    }
}

@MainActor
final class RecorderPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: RecorderPanel
    private let hostingController: NSHostingController<RecorderMainWindowRoot>
    private var hasPositionedPanel = false
    private var currentPhase: AppPhase
    private var selectionIsActive = false
    private let isDesignReview = CommandLine.arguments.contains("--design-review")
    private let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "recorder-panel"
    )

    init(model: AppModel) {
        self.model = model
        currentPhase = model.phase
        let initialSize = RecorderPanelPolicy.contentSize(
            for: model.phase,
            recordsMicrophone: model.configuration.recordsMicrophone
        )
            ?? RecorderPanelPolicy.setupSize
        hostingController = NSHostingController(
            rootView: RecorderMainWindowRoot(model: model, phase: model.phase)
        )
        panel = RecorderPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [RecorderPanelPolicy.styleMask, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel(initialSize: initialSize)
    }

    var window: NSPanel { panel }

    func present(phase: AppPhase) {
        currentPhase = phase
        panel.presentedPhase = phase
        // SwiftUI may rebuild its scene-contributed menu when the editor
        // window closes. Reinstall our AppKit-owned File/Edit commands after
        // the phase transition settles, otherwise returning to the recorder
        // can lose the entire File menu and ⌘O stops working.
        DispatchQueue.main.async {
            (NSApplication.shared.delegate as? DogSCApplicationDelegate)?
                .refreshMainMenuBindings()
        }
        guard let contentSize = RecorderPanelPolicy.contentSize(
            for: phase,
            recordsMicrophone: model.configuration.recordsMicrophone
        ) else {
            panel.orderOut(nil)
            return
        }

        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: phase,
            selectionActive: selectionIsActive
        ))
        // Recorder controls are UI, not source material. A shareable setup
        // panel unnecessarily asks WindowServer to keep this transparent HUD
        // eligible as a capture surface. Design review opts in explicitly;
        // real capture keeps one private window surface.
        panel.sharingType = isDesignReview ? .readOnly : .none
        panel.contentMinSize = contentSize
        panel.contentMaxSize = contentSize

        if !hasPositionedPanel {
            panel.setContentSize(contentSize)
            let savedFrame = UserDefaults.standard.string(
                forKey: RecorderPanelPolicy.savedFrameKey
            ).map(NSRectFromString)
            let pointer = NSEvent.mouseLocation
            let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) }
                ?? NSScreen.main
            let savedScreen = savedFrame.flatMap { saved in
                NSScreen.screens.first { !$0.frame.intersection(saved).isEmpty }
            }
            let destinationScreen = savedScreen ?? pointerScreen
            if let savedFrame, let destinationScreen {
                panel.setFrame(
                    RecorderPanelPolicy.frame(
                        centeredOn: savedFrame,
                        contentSize: contentSize,
                        visibleFrame: destinationScreen.visibleFrame
                    ),
                    display: false
                )
            } else if let destinationScreen {
                panel.setFrame(
                    RecorderPanelPolicy.initialFrame(
                        contentSize: contentSize,
                        visibleFrame: destinationScreen.visibleFrame
                    ),
                    display: false
                )
            } else {
                panel.center()
            }
            hasPositionedPanel = true
        }

        let destination = RecorderPanelPolicy.frame(
            centeredOn: panel.frame,
            contentSize: contentSize,
            visibleFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.setFrame(destination, display: false, animate: false)
            hostingController.rootView = RecorderMainWindowRoot(
                model: model,
                phase: phase
            )
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.needsDisplay = true
        }
        CATransaction.commit()

        logger.info(
            "phase=\(String(describing: phase), privacy: .public) frame=\(destination.width, privacy: .public)x\(destination.height, privacy: .public)"
        )
        if phase == .setup {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func setCaptureSelectionActive(_ active: Bool) {
        selectionIsActive = active
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: currentPhase,
            selectionActive: active
        ))
        if panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func bringToFront() {
        guard currentPhase != .editor else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func shutdown() {
        panel.orderOut(nil)
        panel.contentViewController = nil
        panel.close()
    }

    private func configurePanel(initialSize: NSSize) {
        panel.identifier = recorderMainWindowIdentifier
        panel.presentedPhase = currentPhase
        panel.contentViewController = hostingController
        // 悬浮条使用固定深色 HUD 表面；强制 darkAqua 让 SwiftUI 系统色
        // （Color.primary/.secondary 等）在系统亮色模式下仍解析为亮色文字，
        // 否则黑底黑字不可见。与 CameraPreviewWindow/区域选择器同一先例。
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Keep the context current after a real move changes ColorSync profile.
        // No display-link, frame correction or drag-session patch participates.
        panel.displaysWhenScreenProfileChanges = true
        // macOS 15+ uses exactly one official SwiftUI WindowDragGesture. Older
        // systems retain AppKit's background movement as the compatibility
        // path; the two owners are never active together.
        if #available(macOS 15.0, *) {
            panel.isMovableByWindowBackground = false
        } else {
            panel.isMovableByWindowBackground = true
        }
        panel.acceptsMouseMovedEvents = true
        panel.tabbingMode = .disallowed
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: currentPhase,
            selectionActive: selectionIsActive
        ))
        // A recorder HUD must keep one stable overlay identity while moving
        // between displays with separate Spaces. This mirrors the camera HUD:
        // the behavior is fixed at construction and never toggled while held.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.contentMinSize = initialSize
        panel.contentMaxSize = initialSize
        panel.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard hasPositionedPanel, notification.object as? NSWindow === panel else { return }
        UserDefaults.standard.set(
            NSStringFromRect(panel.frame),
            forKey: RecorderPanelPolicy.savedFrameKey
        )
    }
}

final class RecorderPanel: NSPanel {
    var presentedPhase: AppPhase = .setup

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
