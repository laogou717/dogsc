import AppKit
import Darwin
import os

/// One nonblocking presentation path for all file and directory panels.
@MainActor
enum AppFilePanel {
    private static var activePanel: NSSavePanel?
    private static var isPreparing = false
    private static var openPanel: NSOpenPanel?
    private static var savePanel: NSSavePanel?
    private static var buildWasReplaced = false
    private static var buildMonitor: (any DispatchSourceFileSystemObject)?
    private static let log = Logger(subsystem: "cn.laogou.dogsc", category: "file-panel")
    private static let recordsTiming = Bundle.main.bundleIdentifier == "cn.laogou.dogsc.dev"
        && ProcessInfo.processInfo.environment["DOGSC_FILE_PANEL_TIMING"] == "1"
    private static var requestCount = 0

    /// Construct the remote open panel once after launch, without showing it.
    /// AppKit permits reuse after completion; keep at most one panel of each kind.
    static func prepareOpenPanel() {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                guard !isPreparing, activePanel == nil, !buildWasReplaced else { return }
                _ = reusableOpenPanel()
            }
        }
    }

    private static func reusableOpenPanel() -> NSOpenPanel {
        if let openPanel { return openPanel }
        let panel = NSOpenPanel()
        openPanel = panel
        return panel
    }

    private static func reusableSavePanel() -> NSSavePanel {
        if let savePanel { return savePanel }
        let panel = NSSavePanel()
        savePanel = panel
        return panel
    }

    private static func reset(_ panel: NSSavePanel) {
        // Never carry a previous caller's filters, labels or directory-only mode.
        panel.title = ""
        panel.prompt = nil
        panel.message = ""
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = nil
        panel.nameFieldStringValue = ""
        panel.accessoryView = nil
        panel.delegate = nil
        panel.level = .normal
    }

    private static func presentationOwner(_ preferred: NSWindow?) -> NSWindow? {
        var owner = preferred ?? NSApp.keyWindow ?? NSApp.mainWindow
        // Transient child panels must not turn an editor picker into a
        // standalone window. Prefer their stable parent document window.
        while let parent = owner?.parent { owner = parent }
        if owner is NSSavePanel || owner?.isVisible != true { owner = NSApp.mainWindow }
        return owner
    }

    private struct ExecutableIdentity: Equatable, Sendable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    /// Development builds can be replaced while running. Watch their containing
    /// folder so picker clicks only consult a cached flag, never file metadata.
    static func monitorDevelopmentBuild() {
        guard Bundle.main.bundleIdentifier == "cn.laogou.dogsc.dev", buildMonitor == nil,
              let path = Bundle.main.executableURL?.path,
              let identity = executableIdentity(at: path) else { return }
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
        let descriptor = Darwin.open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let monitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke], queue: .global(qos: .utility))
        monitor.setEventHandler {
            guard executableIdentity(at: path) != identity else { return }
            Task { @MainActor in
                buildWasReplaced = true
                buildMonitor?.cancel()
                buildMonitor = nil
            }
        }
        monitor.setCancelHandler { Darwin.close(descriptor) }
        buildMonitor = monitor
        monitor.resume()
    }

    private nonisolated static func executableIdentity(at path: String) -> ExecutableIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return ExecutableIdentity(inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }

    static func open(configure: @escaping @MainActor (NSOpenPanel) -> Void,
                     completion: @escaping @MainActor ([URL]?) -> Void) {
        present(makePanel: { reusableOpenPanel() }, configure: { panel in
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = false
            configure(panel)
        }) { panel, response in
            completion(response == .OK ? panel?.urls : nil)
        }
    }

    static func open(configure: @escaping @MainActor (NSOpenPanel) -> Void) async -> [URL]? {
        await withCheckedContinuation { continuation in
            open(configure: configure) { continuation.resume(returning: $0) }
        }
    }

    static func save(configure: @escaping @MainActor (NSSavePanel) -> Void) async -> URL? {
        await withCheckedContinuation { continuation in
            present(makePanel: { reusableSavePanel() }, configure: configure) { panel, response in
                continuation.resume(returning: response == .OK ? panel?.url : nil)
            }
        }
    }

    private static func present<Panel: NSSavePanel>(
        makePanel: @escaping @MainActor () -> Panel,
        configure: @escaping @MainActor (Panel) -> Void,
        completion: @escaping @MainActor (Panel?, NSApplication.ModalResponse) -> Void
    ) {
        let timing = recordsTiming ? Timing() : nil
        // Reserve before constructing the remote panel, including pending requests.
        guard activePanel == nil, !isPreparing else {
            if activePanel?.isVisible == true { activePanel?.makeKeyAndOrderFront(nil) }
            timing?.mark("duplicate.ignored")
            completion(nil, .cancel)
            return
        }
        isPreparing = true
        let owner = presentationOwner(RecorderPopoverPresenter.shared.dismissForFilePanel())
        // The only scheduling boundary: leave the triggering menu/event loop.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                timing?.mark("scheduled")
                guard !buildWasReplaced else {
                    isPreparing = false
                    timing?.mark("build.replaced")
                    if !AppDialogPresenter.isPresenting {
                        AppDialogPresenter.present(AppDialog(
                            title: "请重新打开 DogSC",
                            message: "应用已更新，请先保存项目并重新打开，再选择文件或文件夹。",
                            actions: [.init(id: "ok", title: "知道了", role: .primary)]
                        ))
                    }
                    completion(nil, .cancel)
                    return
                }
                guard NSApp.modalWindow == nil, !AppDialogPresenter.isPresenting else {
                    isPreparing = false
                    timing?.mark("modal.busy")
                    completion(nil, .cancel)
                    return
                }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                timing?.mark("activation.ready")
                var owner = owner
                // Settings/export may already be a sheet; use the active sheet.
                while let sheet = owner?.attachedSheet { owner = sheet }
                let needsCreation = Panel.self == NSOpenPanel.self ? openPanel == nil : savePanel == nil
                timing?.mark(needsCreation ? "acquire.begin.cold" : "acquire.begin.reused")
                let panel = makePanel()
                timing?.mark("create.end")
                reset(panel)
                configure(panel)
                timing?.mark("configure.end")
                activePanel = panel
                isPreparing = false
                timing?.observeVisibility(of: panel)
                let finished: @MainActor (NSApplication.ModalResponse) -> Void = { response in
                    guard activePanel === panel else { return }
                    // AppKit may call completion before removing the panel.
                    panel.orderOut(nil)
                    activePanel = nil
                    timing?.finish(response)
                    if response == .abort {
                        if panel === openPanel { openPanel = nil }
                        if panel === savePanel { savePanel = nil }
                    }
                    completion(panel, response)
                    if response == .abort {
                        AppDialogPresenter.present(AppDialog(
                            title: "无法打开文件选择器",
                            message: "系统文件选择器连接失败，请保存项目并重新打开 DogSC 后再试。",
                            actions: [.init(id: "ok", title: "知道了", role: .primary)]
                        ))
                    }
                }
                timing?.mark("present.begin")
                if let owner, owner.isVisible, owner.level == .normal {
                    timing?.mark("present.sheet")
                    panel.animationBehavior = .default
                    panel.beginSheetModal(for: owner, completionHandler: finished)
                } else {
                    timing?.mark("present.window")
                    // Keep a standalone picker above the floating recorder strip.
                    panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue,
                        (owner?.level.rawValue ?? NSWindow.Level.normal.rawValue) + 1))
                    panel.animationBehavior = .utilityWindow
                    panel.begin(completionHandler: finished)
                }
                timing?.mark("present.returned")
                timing?.recordVisibility(of: panel)
            }
        }
    }

    /// Opt-in developer diagnostics in the system log; no paths or project data.
    /// Visibility is AppKit's isVisible state, not a measurement of first paint.
    @MainActor private final class Timing {
        private let id: Int
        private let started = DispatchTime.now().uptimeNanoseconds
        private var visibilityObserver: NSObjectProtocol?
        private var sawVisibility = false

        init() {
            requestCount += 1
            id = requestCount
            mark("request")
        }

        func mark(_ stage: String) {
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            log.info("Picker \(self.id) \(stage, privacy: .public) +\(milliseconds) ms")
        }

        func observeVisibility(of panel: NSSavePanel) {
            visibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: panel, queue: .main
            ) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    if let panel { self?.recordVisibility(of: panel) }
                }
            }
        }

        func recordVisibility(of panel: NSSavePanel) {
            guard !sawVisibility, panel.isVisible else { return }
            sawVisibility = true
            mark("visible.observed")
            stopObserving()
        }

        func finish(_ response: NSApplication.ModalResponse) {
            stopObserving()
            mark("completed.\(response.rawValue)")
        }

        private func stopObserving() {
            if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
            visibilityObserver = nil
        }
    }
}
