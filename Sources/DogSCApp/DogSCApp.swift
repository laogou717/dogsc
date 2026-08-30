import AppKit
import Combine
import SwiftUI

let recorderMainWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.main-window"
)
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

@main
struct DogSCApp: App {
    @NSApplicationDelegateAdaptor(DogSCApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        // The normal app owns no SwiftUI-created main window. A dedicated
        // RecorderPanelController presents the compact recorder surface, while
        // EditorWindowController continues to own the full editor window.
        Settings {
            AppSettingsView()
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("快捷键速查") {
                    EditorMenuBridge.shared.shortcutCheatsheetRequest.send()
                }
            }
        }
    }
}

/// Phase-pinned content hosted by `RecorderPanelController`. The controller
/// swaps this root in the same non-animated transaction that changes panel size,
/// so SwiftUI never negotiates an intermediate recorder width.
struct RecorderMainWindowRoot: View {
    @ObservedObject var model: AppModel
    let phase: AppPhase

    var body: some View {
        Group {
            switch phase {
            case .setup:
                SetupView(model: model)
            case .preparing:
                RecorderPhaseProgressView(
                    title: model.recorderTransitionStage.title,
                    phase: .preparing,
                    accessibilityIdentifier: RecorderAccessibilityID.phasePreparing
                )
            case .recording:
                RecordingBar(model: model)
            case .finishing:
                RecorderPhaseProgressView(
                    title: model.recorderTransitionStage.title,
                    phase: .finishing,
                    accessibilityIdentifier: RecorderAccessibilityID.phaseFinishing
                )
            case .editor:
                // The panel is already ordered out for this phase; a compact root
                // remains available only to keep the generic host type stable.
                RecorderPhaseProgressView(
                    title: "正在打开编辑器…",
                    phase: .editor,
                    accessibilityIdentifier: "recorder.phase.editor-transition"
                )
            }
        }
        .modifier(RecorderSystemWindowDragModifier())
    }
}

/// SwiftUI fills the complete borderless recorder window, so the official
/// window gesture is its one drag owner on current macOS. It delegates the
/// drag to the system and contains no coordinate, screen or frame logic.
private struct RecorderSystemWindowDragModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

struct RecorderPhaseProgressView: View {
    let title: String
    let phase: AppPhase
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).font(.callout.weight(.medium))
        }
        .frame(width: 320, height: 46)
        .background(
            Capsule().fill(Color(red: 0.055, green: 0.058, blue: 0.067))
        )
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Holds one immutable editor generation. Opening another project recreates
/// the editor window and therefore constructs a fresh context atomically.
private struct EditorSessionHost: View {
    @StateObject private var contextProvider: EditorSessionContextProvider

    init(model: AppModel) {
        _contextProvider = StateObject(
            wrappedValue: EditorSessionContextProvider(model: model)
        )
    }

    var body: some View {
        EditorView(context: contextProvider.context)
            .id(contextProvider.context.id)
            .preferredColorScheme(.dark)
    }
}

@MainActor
enum WindowCoordinator {
    private static let editorWindowController = EditorWindowController()
    private static var recorderPanelController: RecorderPanelController?
    private static var permissionWindowController: RequiredPermissionWindowController?
    private static var presentationObservation: AnyCancellable?
    private static weak var model: AppModel?

    static func install(model: AppModel) {
        self.model = model
        recorderPanelController = RecorderPanelController(model: model)
        permissionWindowController = RequiredPermissionWindowController(model: model)
        let presentationTriggers: [AnyPublisher<Void, Never>] = [
            model.$phase.map { _ in () }.eraseToAnyPublisher(),
            model.$hasVerifiedScreenRecordingPermission
                .map { _ in () }.eraseToAnyPublisher(),
            model.$hasAccessibilityPermission
                .map { _ in () }.eraseToAnyPublisher(),
            model.$hasCompletedRequiredPermissionOnboarding
                .map { _ in () }.eraseToAnyPublisher(),
            model.captureSetup.$readiness
                .map { _ in () }.eraseToAnyPublisher(),
        ]
        presentationObservation = Publishers.MergeMany(presentationTriggers)
            // `@Published` emits from willSet. Reading the model directly in
            // that synchronous callback leaves every window one state behind:
            // the permission button waits for the next poll and a cold-opened
            // project remains on the finishing surface. Deliver on the next
            // main-queue turn so all related properties hold their new values.
            .receive(on: DispatchQueue.main)
            .sink { [weak model] in
                guard let model else { return }
                apply(phase: model.phase, model: model)
            }
    }

    private static func apply(phase: AppPhase, model: AppModel) {
        guard let recorderPanelController,
              let permissionWindowController else { return }
        permissionWindowController.refreshDragAssistantState()
        if phase != .setup {
            recorderPanelController.setCaptureSelectionActive(false)
        }
        if model.showsRequiredPermissionGate {
            editorWindowController.closeForPhaseChange()
            recorderPanelController.hide()
            permissionWindowController.present()
            return
        }

        permissionWindowController.hide()
        switch phase {
        case .editor:
            recorderPanelController.present(phase: phase)
            // The active recording/open-project flow is owned by AppModel. Its
            // editor keeps using that same document and workspace so close,
            // project replacement and save all cross one persistence barrier.
            editorWindowController.show(model: model)
        case .setup, .preparing, .recording, .finishing:
            editorWindowController.closeForPhaseChange()
            recorderPanelController.present(phase: phase)
        }
    }

    static func beginCaptureSourceSelection() {
        recorderPanelController?.setCaptureSelectionActive(true)
    }

    static func endCaptureSourceSelection() {
        recorderPanelController?.setCaptureSelectionActive(false)
    }

    static func recorderDisplayID() -> UInt32? {
        guard let window = recorderPanelController?.window else { return nil }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? window.screen
        return (screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
    }

    static func bringCurrentWindowFront() {
        if model?.phase == .editor {
            editorWindowController.bringToFront()
        } else if model?.showsRequiredPermissionGate == true {
            permissionWindowController?.bringToFront()
        } else {
            recorderPanelController?.bringToFront()
        }
    }

    static func showPermissionDragAssistant(
        for permission: RequiredRecordingPermissionKind
    ) {
        permissionWindowController?.showDragAssistant(for: permission)
    }

    static func dismissPermissionDragAssistant() {
        permissionWindowController?.refreshDragAssistantState()
    }

    /// Menu-bar "打开项目…" entry. A recorder/editor has one authoritative
    /// current project; replacing it first crosses AppModel's save barrier.
    static func openProjectFromMenu() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        model?.openProjectPicker()
    }

    static func setDefaultSystemAudioRecordingEnabled(_ enabled: Bool) {
        if let model {
            model.setDefaultSystemAudioRecordingEnabled(enabled)
        } else {
            UserDefaults.standard.set(
                enabled,
                forKey: CaptureDevicePreferenceKey.systemAudioEnabled
            )
        }
    }

    static func setDefaultMicrophoneRecordingEnabled(_ enabled: Bool) {
        if let model {
            model.setDefaultMicrophoneRecordingEnabled(enabled)
        } else {
            UserDefaults.standard.set(
                enabled,
                forKey: CaptureDevicePreferenceKey.microphoneEnabled
            )
        }
    }

    static func shutdown() {
        presentationObservation = nil
        editorWindowController.closeForPhaseChange()
        permissionWindowController?.shutdown()
        permissionWindowController = nil
        recorderPanelController?.shutdown()
        recorderPanelController = nil
        model = nil
    }
}

/// Owns one editor session at a time. Closing its traffic-light button asks the
/// model to close the project; the model's phase transition then tears down this
/// window and restores the recorder bar. Returning `false` from the delegate is
/// important because the close request may be cancelled by the save alert.
@MainActor
private final class EditorWindowController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var windowController: NSWindowController?
    /// Keep the type-erased hosting view so phase teardown can replace its
    /// root before AppKit detaches the window. Merely setting
    /// `contentViewController = nil` does not synchronously dismantle a
    /// SwiftUI graph; its local event monitors can otherwise keep the entire
    /// editor generation (players and Core Image surfaces included) alive in
    /// the recorder phase.
    private var hostingView: EditorFirstMouseHostingView<AnyView>?
    private var firstMouseActivationMonitor: Any?
    private var isClosingForPhaseChange = false
    private var isRequestingProjectClose = false

    func show(model: AppModel) {
        self.model = model

        if let window = windowController?.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let hostingController = NSViewController()
        let hostingView = EditorFirstMouseHostingView(
            rootView: AnyView(EditorSessionHost(model: model))
        )
        self.hostingView = hostingView
        hostingController.view = hostingView
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
        window.title = "\(AppIdentity.displayName) 编辑器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // 编辑器同样是固定深色表面（appBackground 为常量 RGB）；强制
        // darkAqua 保证亮色系统下 Color.primary/.secondary 仍解析为亮色。
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
        let restoredFrame = window.setFrameUsingName(
            AppPreferences.editorWindowFrameAutosaveName
        )
        _ = window.setFrameAutosaveName(
            AppPreferences.editorWindowFrameAutosaveName
        )
        if !restoredFrame {
            window.center()
        }

        let controller = NSWindowController(window: window)
        windowController = controller
        installFirstMouseActivationMonitor(for: window)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // 不把键盘焦点交给第一个可聚焦控件（导出按钮等），避免无边框
        // 窗口出现"键盘控制"焦点环；与录制条面板同一先例。
        window.makeFirstResponder(nil)
        if UserDefaults.standard.bool(
            forKey: AppPreferences.editorWindowFullScreenKey
        ) {
            DispatchQueue.main.async { [weak window] in
                guard let window,
                      !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }

    func closeForPhaseChange() {
        guard let controller = windowController else { return }
        removeFirstMouseActivationMonitor()
        isClosingForPhaseChange = true
        // Force SwiftUI's disappearance hooks while the host still has a live
        // window. They own the editor's keyboard/mouse monitors and explicit
        // player/preview invalidation; relying on AppKit's later controller
        // release left those hooks deferred indefinitely.
        hostingView?.rootView = AnyView(EmptyView())
        hostingView?.layoutSubtreeIfNeeded()
        if let window = controller.window {
            window.delegate = nil
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        hostingView = nil
        windowController = nil
        model = nil
        isRequestingProjectClose = false
        isClosingForPhaseChange = false
    }

    func bringToFront() {
        guard let window = windowController?.window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// SwiftUI controls normally consume the first click only to reactivate an
    /// inactive AppKit window. A notification can therefore leave the timeline
    /// looking active while its first click does nothing. Make this editor key
    /// in the local-event preflight and return the same event so the intended
    /// timeline button/drag also executes on that click.
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

            // `.fullSizeContentView` leaves a thin native title-bar band above
            // the custom SwiftUI toolbar on some MacBook layouts. The toolbar's
            // backmost interaction view cannot cover that separate AppKit
            // region, so handle its blank area at the owning window boundary.
            // Standard traffic-light buttons are explicitly excluded.
            if event.type == .leftMouseDown,
               event.clickCount == 2,
               self?.isBlankNativeTitlebarHit(
                   event.locationInWindow,
                   in: editorWindow
               ) == true {
                EditorWindowTitlebarDoubleClickAction.perform(on: editorWindow)
                return nil
            }
            return event
        }
    }

    private func isBlankNativeTitlebarHit(
        _ location: NSPoint,
        in window: NSWindow
    ) -> Bool {
        // contentLayoutRect excludes AppKit's native title-bar safe area even
        // when the content view itself extends beneath that area.
        guard location.y >= window.contentLayoutRect.maxY else { return false }

        let trafficLights: [NSWindow.ButtonType] = [
            .closeButton,
            .miniaturizeButton,
            .zoomButton,
        ]
        for buttonType in trafficLights {
            guard let button = window.standardWindowButton(buttonType),
                  let container = button.superview else { continue }
            let buttonFrameInWindow = container.convert(button.frame, to: nil)
            if buttonFrameInWindow.insetBy(dx: -4, dy: -4).contains(location) {
                return false
            }
        }
        return true
    }

    private func removeFirstMouseActivationMonitor() {
        guard let firstMouseActivationMonitor else { return }
        NSEvent.removeMonitor(firstMouseActivationMonitor)
        self.firstMouseActivationMonitor = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingForPhaseChange else { return true }
        guard !isRequestingProjectClose else { return false }
        isRequestingProjectClose = true
        // Run after AppKit finishes the current close dispatch. A successful
        // request changes the phase and closes this window through the method
        // above; cancelling the alert leaves the editor exactly as it was.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.model?.requestCloseProject()
            if self.model?.phase == .editor {
                self.isRequestingProjectClose = false
            }
        }
        return false
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(
            true,
            forKey: AppPreferences.editorWindowFullScreenKey
        )
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.editorWindowFullScreenKey
        )
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
