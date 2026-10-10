import AppKit
import OSLog
import QuartzCore
import RecorderCore
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
    private let settingsWindowController = AppSettingsWindowController.shared
    private var settingsShortcutMonitor: Any?
    private var recordingMarkerHotKey: RecordingMarkerHotKey?
    private var keyWindowObservation: NSObjectProtocol?
    private var isWaitingForRecordingCompletionDecision = false

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
        AppPreferences.applyAppearancePreferenceToOpenWindows()
        NSApplication.shared.setActivationPolicy(.regular)
        // APP-001 / UX-024 / APP-004: 应用图标为单一品牌资产（Info.plist
        // CFBundleIconFile -> AppIcon.icns），Dock、切换器与编辑器工具栏
        // 统一使用打包图标，不再在运行时更换。
        let model = AppModel()
        self.model = model
        recordingMarkerHotKey = RecordingMarkerHotKey(model: model)
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
        AppUpdateController.shared.startIfEligible()
        DispatchQueue.main.async { [weak self] in
            self?.refreshMainMenuBindings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        WindowCoordinator.prepareExternalProjectPresentation()
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
        model?.resumeRequiredPermissionOnboardingAfterActivation()
        refreshMainMenuBindings()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // WindowCoordinator creates the recorder or permission surface. There
        // is no untitled document; the remaining SwiftUI scene is settings.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        WindowCoordinator.bringCurrentWindowFront()
        // Reopening has already been handled by the current app phase. Do not
        // let the framework additionally open its default settings scene.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model,
              model.phase == .recordingComplete || WindowCoordinator.hasRecordingProjectEditor
        else { return .terminateNow }
        guard !isWaitingForRecordingCompletionDecision,
              !model.isResolvingCompletedRecording,
              !AppDialogPresenter.isPresenting else { return .terminateCancel }
        isWaitingForRecordingCompletionDecision = true
        let owner = sender.keyWindow
        Task { @MainActor [weak self] in
            var shouldTerminate = await WindowCoordinator.flushRecordingProjectEditorForTermination()
            if shouldTerminate, model.phase == .recordingComplete {
                let decisionOwner = owner?.isVisible == true ? owner : sender.keyWindow
                shouldTerminate = await model.confirmCompletedRecordingForTermination(relativeTo: decisionOwner)
            }
            self?.isWaitingForRecordingCompletionDecision = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        recordingMarkerHotKey?.invalidate()
        recordingMarkerHotKey = nil
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
        let menu = NSMenu(title: AppIdentity.displayName)
        menu.addItem(dockActionItem(
            title: String(
                format: appLocalized("显示%@"),
                AppIdentity.displayName
            ),
            symbol: "macwindow",
            action: #selector(showCurrentWindowFromStatusItem(_:))
        ))
        menu.addItem(dockActionItem(
            title: appLocalized("打开项目…"),
            symbol: "folder",
            action: #selector(openProjectFromDock(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(dockActionItem(
            title: appLocalized("设置…"),
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
        // URL routing keeps a live take separate and safely saves editor switches.
        WindowCoordinator.prepareExternalProjectPresentation()
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
            button.setAccessibilityLabel(
                String(format: appLocalized("%@菜单"), applicationName)
            )
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
            title: String(format: appLocalized("显示%@"), applicationName),
            action: #selector(showCurrentWindowFromStatusItem(_:)),
            keyEquivalent: ""
        )
        showApp.target = self
        menu.addItem(showApp)

        let recentRoot = NSMenuItem(
            title: appLocalized("最近项目"),
            action: nil,
            keyEquivalent: ""
        )
        let recentMenu = NSMenu(title: appLocalized("最近项目"))
        let summaries = ProjectStore.recentProjectSummaries(limit: 8)
        if summaries.isEmpty {
            recentMenu.addItem(
                NSMenuItem(
                    title: appLocalized("暂无最近项目"),
                    action: nil,
                    keyEquivalent: ""
                )
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
            title: appLocalized("导出完成提示音"),
            action: #selector(toggleExportCompletionSound(_:)),
            keyEquivalent: ""
        )
        sound.target = self
        sound.state = AppPreferences.isExportCompletionSoundEnabled ? .on : .off
        menu.addItem(sound)

        menu.addItem(.separator())

        let systemAudio = NSMenuItem(
            title: appLocalized("下次录制系统声音"),
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
            title: microphoneName.map {
                String(format: appLocalized("下次录制麦克风（%@）"), $0)
            } ?? appLocalized("下次录制麦克风"),
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
            title: appLocalized("设置…"),
            action: #selector(openSettingsFromStatusItem(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let guide = NSMenuItem(
            title: appLocalized("首次使用引导…"),
            action: #selector(openFirstLaunchGuide(_:)),
            keyEquivalent: ""
        )
        guide.target = self
        guide.isEnabled = FirstLaunchGuideAccess.shared.isAvailable
        menu.addItem(guide)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(format: appLocalized("退出%@"), applicationName),
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

    @objc private func openFirstLaunchGuide(_ sender: NSMenuItem) {
        WindowCoordinator.showFirstLaunchGuide()
    }

    private func installSettingsShortcutMonitor() {
        guard settingsShortcutMonitor == nil else { return }
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard NSApp.modalWindow == nil else { return event }
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
        settingsWindowController.show(section: .about)
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
        setMainMenuEditorMode(WindowCoordinator.activeEditorModel != nil)
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
            title: appLocalized("导出项目源文件…"),
            action: #selector(exportProjectSourceMedia(_:)),
            keyEquivalent: ""
        )
        exportSources.target = self
        exportSources.identifier = exportProjectMediaItemIdentifier
        fileMenu.addItem(exportSources)

        let importAligned = NSMenuItem(
            title: appLocalized("替换当前项目摄像头…"),
            action: #selector(importCameraReplacement(_:)),
            keyEquivalent: ""
        )
        importAligned.target = self
        importAligned.identifier = replaceCameraMediaItemIdentifier
        fileMenu.addItem(importAligned)
    }

    @objc private func exportProjectSourceMedia(_ sender: NSMenuItem) {
        WindowCoordinator.activeEditorModel?.exportCurrentProjectSourceMedia()
    }

    @objc private func importCameraReplacement(_ sender: NSMenuItem) {
        WindowCoordinator.activeEditorModel?.importCameraReplacement()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openFirstLaunchGuide(_:)) {
            return FirstLaunchGuideAccess.shared.isAvailable
        }
        guard menuItem.action == #selector(exportProjectSourceMedia(_:))
                || menuItem.action == #selector(importCameraReplacement(_:))
        else { return true }
        guard let model = WindowCoordinator.activeEditorModel,
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
    /// The panel is a fixed transparent canvas with room for the island's
    /// shadow; the island inside it changes shape, the window never resizes.
    /// A 56 pt island needs more than the old 46 pt vertical margin: its
    /// 22 pt shadow blur is offset downward by 10 pt. Keep 92 pt on each side
    /// so the shadow reaches transparency before the window clips it.
    static let canvasSize = NSSize(width: 720, height: 240)
    static let setupSize = canvasSize
    static let progressSize = canvasSize
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
            canvasSize
        case .editor, .recordingComplete:
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
    private var selectionSource: CaptureSource?
    private let transition = RecorderPanelTransition()
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

    private var hidesSetupForSelection: Bool {
        currentPhase == .setup && selectionIsActive && selectionSource != .device
    }

    private func resizeRecordingContent(to width: CGFloat) {
        // The island resizes inside a fixed canvas, so this is never reached
        // by the current views; the canvas width keeps it inert if it is.
        guard currentPhase == .recording, width.isFinite,
              width >= 200, width <= 640,
              abs(panel.frame.width - width) >= 1,
              width > RecorderPanelPolicy.canvasSize.width else { return }
        let size = NSSize(width: width, height: 52)
        panel.contentMinSize = size
        panel.contentMaxSize = size
        // Keep the existing host and warning monitor alive during resizing.
        panel.setFrame(
            RecorderPanelPolicy.frame(
                centeredOn: panel.frame,
                contentSize: size,
                visibleFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ),
            display: true,
            animate: false
        )
    }

    func present(phase: AppPhase) {
        let phaseChanged = currentPhase != phase
        // Saving a corner result should return the recorder quietly while
        // the user's other application keeps its typing focus.
        let returnsFromCompletion = currentPhase == .recordingComplete && phase == .setup
        let shouldActivateSetup = (phaseChanged || !panel.isVisible) && !returnsFromCompletion
        if phaseChanged { RecorderPopoverPresenter.shared.dismiss() }
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
            transition.hide(panel, animated: false)
            return
        }

        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: phase,
            selectionActive: selectionIsActive
        ))
        // CaptureSurfaceFilter excludes this process's helper windows. Keep
        // the panel readable by other recorders throughout every phase.
        panel.sharingType = .readOnly
        if phaseChanged || phase != .recording {
            panel.contentMinSize = contentSize
            panel.contentMaxSize = contentSize
        }

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

        // Readiness updates are observed by the existing root. Replacing it
        // inside a zero-duration transaction interrupted press/selection state.
        if phaseChanged || (phase != .recording && panel.frame.size != destination.size) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.setFrame(destination, display: false, animate: false)
                if phaseChanged {
                    hostingController.rootView = RecorderMainWindowRoot(
                        model: model,
                        phase: phase,
                        onRecordingWidthChange: { [weak self] width in
                            self?.resizeRecordingContent(to: width)
                        }
                    )
                }
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.contentView?.needsDisplay = true
                panel.invalidateShadow()
            }
            CATransaction.commit()
        }

        logger.info(
            "phase=\(String(describing: phase), privacy: .public) frame=\(destination.width, privacy: .public)x\(destination.height, privacy: .public)"
        )
        guard !hidesSetupForSelection else {
            transition.hide(panel, animated: true)
            return
        }
        if phaseChanged || !panel.isVisible || panel.alphaValue < 1 {
            transition.show(panel, animated: true)
        }
        if phase == .setup, shouldActivateSetup {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func setCaptureSelectionActive(
        _ active: Bool,
        source: CaptureSource? = nil,
        restoringSetup: Bool = true
    ) {
        if selectionIsActive != active {
            if active { FirstUseTourController.controller(for: .recorder).suspend() }
            else { FirstUseTourController.controller(for: .recorder).resume() }
        }
        selectionIsActive = active
        selectionSource = active ? source : nil
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: currentPhase,
            selectionActive: active
        ))
        if hidesSetupForSelection {
            RecorderPopoverPresenter.shared.dismiss()
            panel.makeFirstResponder(nil)
            transition.hide(panel, animated: true)
        } else if !active, restoringSetup, currentPhase == .setup {
            present(phase: .setup)
        } else if active, currentPhase == .setup {
            present(phase: .setup)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        FirstUseTourController.controller(for: .recorder).suspend()
        transition.hide(panel, animated: false)
    }

    func bringToFront() {
        guard currentPhase != .editor, !hidesSetupForSelection else { return }
        transition.show(panel, animated: !panel.isVisible)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func shutdown() {
        RecorderPopoverPresenter.shared.dismiss()
        transition.hide(panel, animated: false)
        panel.setIslandInteractionView(nil)
        panel.contentViewController = nil
        panel.close()
    }

    private func configurePanel(initialSize: NSSize) {
        panel.identifier = recorderMainWindowIdentifier
        panel.presentedPhase = currentPhase
        panel.contentViewController = hostingController
        panel.appearance = nil
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The island draws its own shadow so it can follow the morph.
        panel.hasShadow = false
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
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
        panel.refreshPointerInteraction()
        UserDefaults.standard.set(
            NSStringFromRect(panel.frame),
            forKey: RecorderPanelPolicy.savedFrameKey
        )
    }
}

final class RecorderPanel: NSPanel {
    var presentedPhase: AppPhase = .setup
    private lazy var pointerRegion = RecorderPanelPointerRegion(window: self)

    func setPointerInteractionEnabled(_ enabled: Bool) {
        pointerRegion.setEnabled(enabled)
    }

    func setIslandInteractionView(_ view: NSView?) {
        pointerRegion.setIslandView(view)
    }

    func refreshPointerInteraction() {
        pointerRegion.refresh()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
