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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // APP-001 / UX-024 / APP-004: 应用图标为单一品牌资产（Info.plist
        // CFBundleIconFile -> AppIcon.icns），Dock、切换器与编辑器工具栏
        // 统一使用打包图标，不再在运行时更换。
        let model = AppModel()
        self.model = model
        WindowCoordinator.install(model: model)
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
        DispatchQueue.main.async { [weak self] in
            self?.installProjectMediaMenu()
            EditorMenuBridge.shared.installMainMenuItems()
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
        installProjectMediaMenu()
        EditorMenuBridge.shared.installMainMenuItems()
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

    /// Running-app Dock menu. ProjectStore also registers every opened package
    /// with NSDocumentController so macOS can retain Recent Documents for the
    /// Dock menu while the process is not running.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "最近项目")
        let summaries = ProjectStore.recentProjectSummaries(limit: 8)
        guard !summaries.isEmpty else {
            menu.addItem(NSMenuItem(title: "暂无最近项目", action: nil, keyEquivalent: ""))
            return menu
        }
        for summary in summaries {
            let item = NSMenuItem(
                title: summary.menuTitle,
                action: #selector(openRecentProject(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = summary.url.path
            item.toolTip = summary.url.path
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        // requestOpenProject 会处理当前阶段（编辑器时先安全保存、录制中提示）。
        model?.requestOpenProject(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // A full-colour Dock icon becomes a pale square at 18pt and is
            // illegible in the monochrome macOS status bar. Use the native
            // recording symbol here; the branded asset remains authoritative
            // for Dock, app switcher and the editor toolbar.
            let statusImage = NSImage(
                systemSymbolName: "record.circle",
                accessibilityDescription: "DogSC"
            ) ?? NSImage()
            statusImage.isTemplate = true
            button.image = statusImage
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = "DogSC"
            button.setAccessibilityLabel("DogSC菜单")
        }

        let menu = NSMenu(title: "DogSC")
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

        let showApp = NSMenuItem(
            title: "显示DogSC",
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
            title: "退出DogSC",
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
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: sender
        )
    }

    @objc private func quitFromStatusItem(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(sender)
    }

    private func installProjectMediaMenu() {
        guard let mainMenu = NSApplication.shared.mainMenu,
              !mainMenu.items.contains(where: {
                  $0.identifier == projectMediaMenuIdentifier
              }) else { return }
        let submenu = NSMenu(title: "项目素材")

        let exportSources = NSMenuItem(
            title: "导出项目源文件…",
            action: #selector(exportProjectSourceMedia(_:)),
            keyEquivalent: ""
        )
        exportSources.target = self
        submenu.addItem(exportSources)

        let importAligned = NSMenuItem(
            title: "替换当前项目摄像头…",
            action: #selector(importCameraReplacement(_:)),
            keyEquivalent: ""
        )
        importAligned.target = self
        submenu.addItem(importAligned)

        let root = NSMenuItem(title: "项目素材", action: nil, keyEquivalent: "")
        root.identifier = projectMediaMenuIdentifier
        root.submenu = submenu
        mainMenu.insertItem(root, at: max(mainMenu.numberOfItems - 2, 1))
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
            return !model.exporter.isExporting
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
    static let recordingSize = NSSize(width: recordingWindowWidth(), height: 46)

    static func contentSize(for phase: AppPhase) -> NSSize? {
        switch phase {
        case .setup:
            setupSize
        case .preparing, .finishing:
            progressSize
        case .recording:
            recordingSize
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
}

@MainActor
final class RecorderPanelController {
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
        let initialSize = RecorderPanelPolicy.contentSize(for: model.phase)
            ?? RecorderPanelPolicy.setupSize
        hostingController = NSHostingController(
            rootView: RecorderMainWindowRoot(model: model, phase: model.phase)
        )
        panel = RecorderPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: RecorderPanelPolicy.styleMask,
            backing: .buffered,
            defer: false
        )
        configurePanel(initialSize: initialSize)
    }

    var window: NSPanel { panel }

    func present(phase: AppPhase) {
        currentPhase = phase
        panel.presentedPhase = phase
        guard let contentSize = RecorderPanelPolicy.contentSize(for: phase) else {
            panel.orderOut(nil)
            return
        }

        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: phase,
            selectionActive: selectionIsActive
        ))
        panel.sharingType = isDesignReview || phase == .setup ? .readOnly : .none
        panel.contentMinSize = contentSize
        panel.contentMaxSize = contentSize

        if !hasPositionedPanel {
            panel.setContentSize(contentSize)
            panel.center()
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
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.tabbingMode = .disallowed
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: currentPhase,
            selectionActive: selectionIsActive
        ))
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.contentMinSize = initialSize
        panel.contentMaxSize = initialSize
    }
}

final class RecorderPanel: NSPanel {
    var presentedPhase: AppPhase = .setup

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
