import AppKit
import Combine
import RecorderCore
import SwiftUI

private let recorderEditorWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.editor-window"
)

/// FOC-001: an inactive SwiftUI hosting view normally consumes the activation
/// click before its timeline/control receives it. The editor explicitly
/// accepts that first mouse so the same click both restores key status and
/// performs the intended edit after a notification or another app took focus.
private final class EditorFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns one editor window for a specific project package. Multiple windows can
/// run simultaneously side-by-side with fully isolated documents, stores, and transports.
@MainActor
final class EditorProjectWindowController: NSObject, NSWindowDelegate {
    private(set) var packageURL: URL
    private(set) var sessionContext: EditorSessionContext?
    private var windowController: NSWindowController?
    private var firstMouseActivationMonitor: Any?
    private var isClosingProgrammatically = false
    private var isRequestingClose = false
    private var subscriptions = Set<AnyCancellable>()

    var onClose: ((URL) -> Void)?

    var window: NSWindow? {
        windowController?.window
    }

    init(packageURL: URL) {
        self.packageURL = packageURL.standardizedFileURL
        super.init()
    }

    func show(
        project: RecorderProject,
        session: RecordingSession,
        cascadeFrom: NSPoint? = nil
    ) {
        let canonicalURL = session.packageURL.standardizedFileURL
        self.packageURL = canonicalURL

        let document = ProjectDocument(project: project)
        let persistence = ProjectSessionPersistenceController()
        let workspace = ProjectWorkspace(document: document, persistence: persistence)
        workspace.activate(session: session, isSaved: true)

        let sessionId = EditorSessionID(rawValue: UUID())
        let sourceURL = ProjectStore.resolve(
            relativePath: project.media?.screen.relativePath ?? "media/screen-0001.mp4",
            session: session
        )
        let cameraURL = ProjectStore.resolve(
            relativePath: project.media?.camera?.relativePath ?? "media/camera-0001.mov",
            session: session
        )
        let microphoneURL = ProjectStore.resolve(
            relativePath: project.media?.microphone?.relativePath ?? "media/microphone.m4a",
            session: session
        )
        let pointerEvents = (try? ProjectStore.loadPointerEvents(project: project, session: session))
            ?? (try? ProjectStore.loadPointerEvents(session: session))
            ?? []

        let hostActions = EditorHostActions(
            persistenceStatus: workspace.status,
            errorMessage: nil,
            persistenceStatusUpdates: workspace.objectWillChange
                .compactMap { [weak workspace] in workspace?.status }
                .eraseToAnyPublisher(),
            errorMessageUpdates: Empty().eraseToAnyPublisher(),
            openProject: {
                EditorWindowManager.shared.openProjectPicker()
            },
            deleteProject: { [weak self] in
                self?.deleteAndClose()
            },
            chooseWallpaper: { nil },
            setError: { _ in },
            saveProject: { [weak workspace, weak document] in
                guard let workspace, let document else { return }
                Task { @MainActor in
                    try? await workspace.flush(document.project)
                }
            },
            revealProject: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.packageURL])
            },
            exportSourceMedia: { [weak self] in
                guard let self else { return }
                self.exportSourceMedia(project: document.project, session: session)
            },
            importCamera: { },
            importDesktopWallpaper: { nil },
            renameProject: { [weak self] newTitle in
                guard let self else { return nil }
                return self.rename(to: newTitle, document: document, workspace: workspace)
            }
        )

        let wallpaperResolver = EditorWallpaperResolver(projectSession: session)
        let context = EditorSessionContext(
            id: sessionId,
            document: document,
            projectIdentity: EditorProjectIdentity(packageURL: canonicalURL),
            media: EditorSessionMediaInputs(
                sourceURL: sourceURL,
                cameraURL: cameraURL,
                microphoneURL: microphoneURL,
                pointerEvents: pointerEvents
            ),
            exporter: VideoExporter(),
            hostActions: hostActions,
            mediaPreparation: { request in
                try await TimelinePreviewCompositionLoader.prepare(request: request)
            },
            wallpaperURLResolver: wallpaperResolver.resolve
        )
        self.sessionContext = context

        let hostingController = NSViewController()
        hostingController.view = EditorFirstMouseHostingView(
            rootView: EditorView(context: context)
                .id(context.id)
                .preferredColorScheme(.dark)
        )

        let window = NSWindow(
            contentRect: editorInitialFrame(),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.identifier = recorderEditorWindowIdentifier
        window.title = "DogSC - \(context.projectIdentity.displayTitle(for: project.title))"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.hasShadow = true
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.tabbingMode = .disallowed
        window.sharingType = .readOnly
        window.collectionBehavior = [.managed]
        window.minSize = editorMinimumSize()
        window.contentViewController = hostingController
        window.delegate = self

        if let cascadeFrom {
            _ = window.cascadeTopLeft(from: cascadeFrom)
        } else {
            let restored = window.setFrameUsingName(AppPreferences.editorWindowFrameAutosaveName)
            if !restored {
                window.center()
            }
        }
        _ = window.setFrameAutosaveName(AppPreferences.editorWindowFrameAutosaveName)

        let controller = NSWindowController(window: window)
        windowController = controller
        installFirstMouseActivationMonitor(for: window)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        ProjectStore.registerRecentProject(canonicalURL)
    }

    func bringToFront() {
        guard let window = windowController?.window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        isClosingProgrammatically = true
        removeFirstMouseActivationMonitor()
        if let window = windowController?.window {
            window.delegate = nil
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        windowController = nil
        onClose?(packageURL)
    }

    private func rename(
        to newTitle: String,
        document: ProjectDocument,
        workspace: ProjectWorkspace
    ) -> URL? {
        do {
            let newURL = try ProjectStore.renamePackage(at: packageURL, toTitle: newTitle)
            guard newURL.standardizedFileURL != packageURL.standardizedFileURL else {
                return packageURL
            }
            let oldURL = packageURL
            self.packageURL = newURL
            let newSession = RecordingSession(packageURL: newURL)
            workspace.activate(session: newSession, isSaved: workspace.isSaved)
            windowController?.window?.title = "DogSC - \(newTitle)"
            EditorWindowManager.shared.handleProjectRenamed(from: oldURL, to: newURL)
            return newURL
        } catch {
            return nil
        }
    }

    private func deleteAndClose() {
        let alert = NSAlert()
        alert.messageText = "删除当前项目？"
        alert.informativeText = "该项目及其录制素材将被移入废纸篓。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? FileManager.default.trashItem(at: packageURL, resultingItemURL: nil)
        close()
    }

    private func exportSourceMedia(project: RecorderProject, session: RecordingSession) {
        let panel = NSSavePanel()
        panel.title = "导出项目源文件"
        panel.prompt = "导出"
        panel.nameFieldStringValue = packageURL.deletingPathExtension().lastPathComponent + "-源文件"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let mediaFolder = session.packageURL.appendingPathComponent("media", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: mediaFolder, includingPropertiesForKeys: nil) {
            for item in items {
                try? FileManager.default.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(item.lastPathComponent)
                )
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingProgrammatically else { return true }
        close()
        return false
    }

    private func installFirstMouseActivationMonitor(for editorWindow: NSWindow) {
        removeFirstMouseActivationMonitor()
        firstMouseActivationMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak editorWindow] event in
            guard self != nil,
                  let editorWindow,
                  event.window === editorWindow else { return event }
            if !NSApplication.shared.isActive || !editorWindow.isKeyWindow {
                NSApplication.shared.activate(ignoringOtherApps: true)
                editorWindow.makeKey()
            }
            return event
        }
    }

    private func removeFirstMouseActivationMonitor() {
        guard let firstMouseActivationMonitor else { return }
        NSEvent.removeMonitor(firstMouseActivationMonitor)
        self.firstMouseActivationMonitor = nil
    }

    private func editorInitialFrame() -> NSRect {
        let desired = NSSize(width: 1728, height: 900)
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSRect(origin: .zero, size: desired)
        }
        return NSRect(
            origin: .zero,
            size: NSSize(
                width: min(desired.width, max(visibleFrame.width - 24, 840)),
                height: min(desired.height, max(visibleFrame.height - 24, 640))
            )
        )
    }

    private func editorMinimumSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSSize(width: 1120, height: 680)
        }
        return NSSize(
            width: min(1120, max(visibleFrame.width - 24, 840)),
            height: min(680, max(visibleFrame.height - 24, 640))
        )
    }
}

/// Central manager for multiple concurrently opened editor project windows.
@MainActor
final class EditorWindowManager: ObservableObject {
    static let shared = EditorWindowManager()

    private var projectControllers: [String: EditorProjectWindowController] = [:]
    private var lastCascadePoint: NSPoint?

    var openProjectURLs: [URL] {
        projectControllers.values.map(\.packageURL)
    }

    var hasOpenProjects: Bool {
        !projectControllers.isEmpty
    }

    func isProjectOpen(at url: URL) -> Bool {
        projectControllers[url.standardizedFileURL.path] != nil
    }

    @discardableResult
    func openProject(at packageURL: URL) -> Bool {
        let canonicalURL = packageURL.standardizedFileURL
        let key = canonicalURL.path

        if let existing = projectControllers[key] {
            existing.bringToFront()
            return true
        }

        do {
            let loaded = try ProjectStore.loadProject(at: canonicalURL)
            let controller = EditorProjectWindowController(packageURL: canonicalURL)

            let cascadePoint: NSPoint?
            if let lastPoint = lastCascadePoint {
                cascadePoint = lastPoint
            } else if let frontmost = projectControllers.values.first?.window {
                cascadePoint = NSPoint(
                    x: frontmost.frame.origin.x,
                    y: frontmost.frame.origin.y + frontmost.frame.height
                )
            } else {
                cascadePoint = nil
            }

            controller.onClose = { [weak self] closedURL in
                self?.handleWindowClosed(at: closedURL)
            }

            controller.show(
                project: loaded.project,
                session: loaded.session,
                cascadeFrom: cascadePoint
            )

            if let newWindow = controller.window {
                lastCascadePoint = NSPoint(
                    x: newWindow.frame.origin.x,
                    y: newWindow.frame.origin.y + newWindow.frame.height
                )
            }

            projectControllers[key] = controller
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开项目"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
    }

    func openProjectPicker() {
        let panel = NSOpenPanel()
        panel.title = "打开 DogSC 项目"
        panel.prompt = "打开"
        panel.message = "选择 .dogscproject 项目文件夹，或项目内的 project.json"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let packageURL = url.pathExtension == "dogscproject"
                ? url
                : (url.lastPathComponent == "project.json" ? url.deletingLastPathComponent() : url)
            openProject(at: packageURL)
        }
    }

    func handleProjectRenamed(from oldURL: URL, to newURL: URL) {
        let oldKey = oldURL.standardizedFileURL.path
        let newKey = newURL.standardizedFileURL.path
        guard let controller = projectControllers.removeValue(forKey: oldKey) else { return }
        projectControllers[newKey] = controller
    }

    private func handleWindowClosed(at url: URL) {
        let key = url.standardizedFileURL.path
        projectControllers.removeValue(forKey: key)
        if projectControllers.isEmpty {
            lastCascadePoint = nil
        }
    }

    func bringAnyWindowToFront() -> Bool {
        guard let controller = projectControllers.values.first else { return false }
        controller.bringToFront()
        return true
    }

    func closeAllWindows() {
        let controllers = Array(projectControllers.values)
        for controller in controllers {
            controller.close()
        }
        projectControllers.removeAll()
        lastCascadePoint = nil
    }
}
