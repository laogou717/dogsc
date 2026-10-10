import AppKit
import RecorderCore
import Combine
import CoreGraphics
import SwiftUI

let recorderMainWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.main-window"
)

/// FOC-001: an inactive SwiftUI hosting view normally consumes the activation
/// click before its timeline/control receives it. The editor explicitly
/// accepts that first mouse so the same click both restores key status and
/// performs the intended edit after a notification or another app took focus.
private final class EditorFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@main
enum DogSCApplication {
    @MainActor
    static func main() {
        // SceneBuilder cannot conditionally apply newer scene modifiers.
        // Choose the host before creating the one application delegate.
        if #available(macOS 15.0, *) {
            DogSCModernApp.main()
        } else {
            DogSCApp.main()
        }
    }
}

private struct DogSCApp: App {
    @NSApplicationDelegateAdaptor(DogSCApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene { DogSCSettingsScene() }
}

@available(macOS 15.0, *)
private struct DogSCModernApp: App {
    @NSApplicationDelegateAdaptor(DogSCApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        DogSCSettingsScene()
            // AppKit owns launch and Dock reopening. Settings is never a
            // default or restored main window, even with old saved state.
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

private struct DogSCSettingsScene: Scene {
    @ObservedObject private var guideAccess = FirstLaunchGuideAccess.shared

    var body: some Scene {
        // The normal app owns no SwiftUI-created main window. A dedicated
        // RecorderPanelController presents the compact recorder surface, while
        // EditorWindowController continues to own the full editor window.
        Settings { AppSettingsView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    AppSettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // Declare this with the scene so SwiftUI retains it when rebuilding
            // the application menu for a different AppKit key window.
            CommandGroup(after: .appSettings) {
                Button("首次使用引导…") {
                    WindowCoordinator.showFirstLaunchGuide()
                }
                .disabled(!guideAccess.isAvailable)
            }
            CommandGroup(after: .toolbar) {
                Button("快捷键速查") {
                    EditorMenuBridge.shared.shortcutCheatsheetRequest.send()
                }
            }
        }
    }

}

/// The menu and settings entry share the same recording-phase gate.
@MainActor
final class FirstLaunchGuideAccess: ObservableObject {
    static let shared = FirstLaunchGuideAccess()
    @Published var isAvailable = false
}

/// Phase-pinned content hosted by `RecorderPanelController`. The controller
/// swaps this root in the same non-animated transaction that changes panel size,
/// so SwiftUI never negotiates an intermediate recorder width.
/// One island for the whole take. The window is a fixed transparent canvas;
/// a single solid shape inside it stretches to fit whatever the phase needs,
/// and each phase's content dissolves in once the shape is underway.
struct RecorderMainWindowRoot: View {
    @ObservedObject var model: AppModel
    let phase: AppPhase
    var onRecordingWidthChange: (CGFloat) -> Void = { _ in }
    @State private var islandSize = CGSize.zero

    var body: some View {
        ZStack {
            RecorderSurfaceShape(radius: islandSize.height / 2, castsShadow: true)
                .frame(width: islandSize.width, height: islandSize.height)
                .allowsHitTesting(false)
            Group {
                switch phase {
                case .setup:
                    island { SetupView(model: model) }
                case .preparing:
                    island {
                        RecorderPhaseProgressView(
                            title: model.recorderTransitionStage.title,
                            phase: .preparing,
                            accessibilityIdentifier: RecorderAccessibilityID.phasePreparing
                        )
                    }
                case .recording:
                    island { RecordingBar(model: model) }
                case .finishing:
                    island {
                        RecorderPhaseProgressView(
                            title: model.recorderTransitionStage.title,
                            phase: .finishing,
                            accessibilityIdentifier: RecorderAccessibilityID.phaseFinishing
                        )
                    }
                case .editor, .recordingComplete:
                    // The panel is already ordered out for this phase; a compact
                    // root remains only to keep the generic host type stable.
                    island {
                        RecorderPhaseProgressView(
                            title: appLocalized("正在打开编辑器…"),
                            phase: .editor,
                            accessibilityIdentifier: "recorder.phase.editor-transition"
                        )
                    }
                }
            }
        }
        .background {
            RecorderIslandInteractionRegion()
                .frame(width: islandSize.width, height: islandSize.height)
                .allowsHitTesting(false)
        }
        .contentShape(Capsule())
        .modifier(RecorderSystemWindowDragModifier())
        .frame(width: RecorderPanelPolicy.canvasSize.width, height: RecorderPanelPolicy.canvasSize.height)
        .animation(RecorderMotion.morph, value: islandSize)
        .animation(RecorderMotion.morph, value: phase)
        .font(.appUI(.body))
        .appControlFocusAppearance()
    }

    private func island<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width > 0, size.height > 0 else { return }
                if islandSize == .zero {
                    // Establish the first complete island before the window
                    // fades in. Animating an invented initial size also starts
                    // descendant insertion transitions during launch layout.
                    var initialLayout = Transaction(animation: nil)
                    initialLayout.disablesAnimations = true
                    withTransaction(initialLayout) { islandSize = size }
                } else {
                    islandSize = size
                }
            }
            .transition(.recorderContent)
    }
}

/// Content leaves quickly and soft, and arrives a beat after the surface has
/// started to move, pulling into focus as it settles.
private struct RecorderContentPhase: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.94 : 1)
            .blur(radius: hidden ? 6 : 0)
    }
}

extension AnyTransition {
    static var recorderContent: AnyTransition {
        guard !RecorderMotion.reduces else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: RecorderContentPhase(hidden: true), identity: RecorderContentPhase(hidden: false))
                .animation(.easeOut(duration: 0.3).delay(0.14)),
            removal: .modifier(active: RecorderContentPhase(hidden: true), identity: RecorderContentPhase(hidden: false))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

/// Only the island owns the official window gesture. Its transparent shadow
/// canvas is drawing space, never a drag target.
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
            Text(title).font(.appUI(size: 13, weight: .medium))
                .contentTransition(.opacity)
        }
        .foregroundStyle(RecorderStyle.ink)
        .padding(.horizontal, 20)
        .frame(height: 44)
        .animation(RecorderMotion.fade, value: title)
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
            .appControlFocusAppearance()
        // NSWindow owns appearance so native and SwiftUI chrome change in
        // the same transition, before either tree redraws in the new theme.
    }
}

@MainActor
enum WindowCoordinator {
    static func showFirstLaunchGuide() {
        guard FirstLaunchGuideAccess.shared.isAvailable,
              let permissionWindowController else { return }
        // Settings is floating; otherwise it would cover the normal-level
        // permission window as soon as the full-screen introduction disappears.
        AppSettingsWindowController.shared.hideForFirstLaunchGuide()
        RecorderPopoverPresenter.shared.dismiss()
        RecorderMemoController.shared.hide()
        recorderPanelController?.hide()
        permissionWindowController.presentManually()
    }

    static func resumeWorkspaceAfterPermissionGuide(replay: Bool) {
        guard let model else { return }
        if replay {
            FirstUseTourController.controller(for: .recorder).prepareReplay()
            FirstUseTourController.controller(for: .editor).prepareReplay()
        }
        apply(phase: model.phase, model: model)
        bringCurrentWindowFront()
        let kind: FirstUseTourKind = model.phase == .editor ? .editor : .recorder
        FirstUseTourController.controller(for: kind).resume()
    }

    private static let editorWindowController = EditorWindowController()
    private static let recordingProjectEditor = RecordingProjectEditor()
    private static let completionWindowController = RecordingCompletionWindowController()
    private static var recorderPanelController: RecorderPanelController?
    private static var permissionWindowController: RequiredPermissionWindowController?
    private static var presentationObservation: AnyCancellable?
    private static weak var model: AppModel?
    /// A project opened by Finder or the Dock recent-items menu should appear
    /// on the system main display. AppKit's global frame autosave otherwise
    /// restores the last editor display for every project, which makes a cold
    /// right-click open look permanently pinned to a secondary monitor.
    private static var pendingExternalProjectVisibleFrame: NSRect?

    static func install(model: AppModel) {
        self.model = model
        recordingProjectEditor.onPresentationChange = { [weak model] in
            guard let model else { return }
            apply(phase: model.phase, model: model)
        }
        recordingProjectEditor.onFailure = { [weak model] message in
            model?.errorMessage = message
        }
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
        if model.showsRequiredPermissionGate || (phase != .setup && phase != .preparing && phase != .recording) {
            RecorderMemoController.shared.hide()
        }
        let guideAvailable = phase == .setup || phase == .editor
        if FirstLaunchGuideAccess.shared.isAvailable != guideAvailable {
            FirstLaunchGuideAccess.shared.isAvailable = guideAvailable
        }
        guard let recorderPanelController,
              let permissionWindowController else { return }
        permissionWindowController.refreshDragAssistantState()
        // Readiness changes during a manual review must not bring the existing
        // floating recorder/editor back above the unfinished permission page.
        if permissionWindowController.isManualGuideActive,
           phase == .setup || phase == .editor { return }
        if phase != .setup {
            recorderPanelController.setCaptureSelectionActive(false, restoringSetup: false)
        }
        if phase != .recordingComplete {
            completionWindowController.close()
        }
        if model.showsRequiredPermissionGate {
            completionWindowController.close()
            editorWindowController.closeForPhaseChange()
            recorderPanelController.hide()
            permissionWindowController.present()
            return
        }

        permissionWindowController.hide()
        if let editor = recordingProjectEditor.presentedModel {
            // Recorder notifications must not steal focus from a recording
            // or force a still-valid editor to recreate its playback graph.
            if !editorWindowController.isShowing(model: editor) {
                showEditor(model: editor)
            }
        } else if phase == .editor {
            // Permission/readiness refreshes also arrive after app activation.
            // Updating an already-present editor must not reorder it above an
            // explicitly requested Settings window. Dock/Finder requests keep
            // their separate bringToFront / preferred-display paths.
            if !editorWindowController.isShowing(model: model) || pendingExternalProjectVisibleFrame != nil {
                showEditor(model: model)
            }
        } else {
            editorWindowController.closeForPhaseChange()
        }
        switch phase {
        case .recordingComplete:
            let capturedScreen = NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.uint32Value == model.project.capture.displayID
            }
            let preferredScreen = capturedScreen ?? recorderPanelController.window.screen
            recorderPanelController.present(phase: phase)
            completionWindowController.show(model: model, preferredScreen: preferredScreen)
        case .editor:
            recorderPanelController.present(phase: phase)
        case .setup, .preparing, .recording, .finishing:
            recorderPanelController.present(phase: phase)
        }
    }

    private static func showEditor(model: AppModel) {
        let preferredVisibleFrame = pendingExternalProjectVisibleFrame
        pendingExternalProjectVisibleFrame = nil
        editorWindowController.show(model: model, preferredVisibleFrame: preferredVisibleFrame)
    }

    static var activeEditorModel: AppModel? {
        recordingProjectEditor.presentedModel ?? (model?.phase == .editor ? model : nil)
    }

    static var hasRecordingProjectEditor: Bool { recordingProjectEditor.model != nil }

    /// All URL entrances share this routing, including Dock, Finder and the
    /// editor's own picker. A live take is never replaced by an editing file.
    static func routeProjectOpen(at url: URL, from requester: AppModel) -> Bool {
        guard let recorder = model else { return false }
        let packageURL = url.lastPathComponent == "project.json" ? url.deletingLastPathComponent() : url
        let recorderOwnsPendingTake = recorder.phase == .preparing || recorder.phase == .recording
            || recorder.phase == .recordingComplete
            || (recorder.phase == .finishing && recorder.recordingRuns.active != nil)
        // This guard also covers the independent editor's own picker. A
        // shared URL must never activate a second persistence epoch for a take
        // whose writer or completion decision is still owned by the recorder.
        if recorderOwnsPendingTake, let currentURL = recorder.currentSession?.packageURL,
           currentURL.standardizedFileURL.resolvingSymlinksInPath()
            == packageURL.standardizedFileURL.resolvingSymlinksInPath() {
            requester.errorMessage = "这次录制尚未进入编辑器，请先完成录制后的处理。"
            return true
        }
        guard requester === recorder else { return false }
        let separateEditorIsRequired = hasRecordingProjectEditor
            || recorderOwnsPendingTake
        guard separateEditorIsRequired else { return false }
        recordingProjectEditor.openProject(at: packageURL)
        return true
    }

    static func closeRecordingProjectEditorForReplacement() async -> Bool {
        await recordingProjectEditor.closeForReplacement()
    }

    static func flushRecordingProjectEditorForTermination() async -> Bool {
        await recordingProjectEditor.flushForTermination()
    }

    static func beginCaptureSourceSelection(source: CaptureSource) {
        RecorderMemoController.shared.suspendForSelection()
        recorderPanelController?.setCaptureSelectionActive(true, source: source)
    }

    static func endCaptureSourceSelection(restoringRecorder: Bool = true) {
        // Selection cleanup also runs during permission onboarding. Never
        // restore the recorder or memo before the permission page hands off.
        let shouldRestoreRecorder = restoringRecorder
            && model?.phase == .setup
            && model?.showsRequiredPermissionGate == false
            && permissionWindowController?.isManualGuideActive != true
        recorderPanelController?.setCaptureSelectionActive(
            false,
            restoringSetup: shouldRestoreRecorder
        )
        guard shouldRestoreRecorder else { return }
        if let owner = recorderPanelController?.window {
            RecorderMemoController.shared.resumeAfterSelection(relativeTo: owner)
        }
    }

    static func restoreCaptureSourceSelectionFocus() {
        guard let model, model.phase == .setup,
              !model.showsRequiredPermissionGate,
              permissionWindowController?.isManualGuideActive != true else { return }
        endCaptureSourceSelection()
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let window = recorderPanelController?.window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    static func toggleRecorderMemo() {
        guard let model, model.phase == .setup || model.phase == .recording,
              let owner = recorderPanelController?.window else { return }
        RecorderMemoController.shared.toggle(relativeTo: owner)
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
        if permissionWindowController?.isManualGuideActive == true {
            permissionWindowController?.bringToFront()
        } else if model?.phase == .recordingComplete {
            completionWindowController.bringToFront()
        } else if activeEditorModel != nil {
            editorWindowController.bringToFront()
        } else if model?.showsRequiredPermissionGate == true {
            permissionWindowController?.bringToFront()
        } else {
            recorderPanelController?.bringToFront()
        }
    }

    static func prepareExternalProjectPresentation() {
        guard let visibleFrame = systemMainScreen()?.visibleFrame else { return }
        if editorWindowController.moveVisibleWindow(to: visibleFrame) {
            pendingExternalProjectVisibleFrame = nil
        } else {
            pendingExternalProjectVisibleFrame = visibleFrame
        }
    }

    private static func systemMainScreen() -> NSScreen? {
        let displayID = UInt32(CGMainDisplayID())
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.screens.first
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
        RecorderMemoController.shared.shutdown()
        presentationObservation = nil
        completionWindowController.close()
        editorWindowController.closeForPhaseChange()
        recordingProjectEditor.shutdown()
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

    /// Finder/Dock project opens are explicit navigation requests. If an editor
    /// already exists, move that same authoritative window to the system main
    /// display instead of leaving it on the autosaved secondary display.
    func moveVisibleWindow(to visibleFrame: NSRect) -> Bool {
        guard let window = windowController?.window else { return false }
        window.setFrame(
            centeredFrame(preserving: window.frame, inside: visibleFrame),
            display: true
        )
        return true
    }

    func show(model: AppModel, preferredVisibleFrame: NSRect? = nil) {
        if self.model !== model { closeForPhaseChange() }
        self.model = model

        if let window = windowController?.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let preferredVisibleFrame {
                window.setFrame(
                    centeredFrame(
                        preserving: window.frame,
                        inside: preferredVisibleFrame
                    ),
                    display: true
                )
            }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            CaptureEditorWindows.shared.register(window)
            return
        }

        let hostingController = NSViewController()
        let hostingView = EditorFirstMouseHostingView(
            rootView: AnyView(EditorSessionHost(model: model))
        )
        // The window owns its frame and minimum size. Content fitting must
        // not replace the display-sized initial frame during attachment.
        hostingView.sizingOptions = []
        self.hostingView = hostingView
        hostingController.view = hostingView
        let initialFrame = preferredVisibleFrame ?? systemMainScreen()?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1728, height: 900)
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        let window = NSWindow(
            contentRect: NSWindow.contentRect(
                forFrameRect: initialFrame,
                styleMask: styleMask
            ),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.identifier = recorderEditorWindowIdentifier
        window.title = "\(AppIdentity.displayName) \(appLocalized("编辑器"))"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = AppPreferences.appearancePreference.appKitAppearance
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.tabbingMode = .disallowed
        window.sharingType = .readOnly
        window.collectionBehavior = [.managed]
        window.contentMinSize = editorMinimumSize()
        window.contentViewController = hostingController
        window.delegate = self
        let restoredFrame = window.setFrameUsingName(
            AppPreferences.editorWindowFrameAutosaveName
        )
        if !restoredFrame {
            // Apply the whole-window frame after installing its content.
            // Centering the host's current frame can preserve a small fitting
            // size on a fresh install instead of the intended work area.
            window.setFrame(initialFrame, display: false)
        } else if let preferredVisibleFrame {
            window.setFrame(
                centeredFrame(
                    preserving: window.frame,
                    inside: preferredVisibleFrame
                ),
                display: false
            )
        }
        _ = window.setFrameAutosaveName(
            AppPreferences.editorWindowFrameAutosaveName
        )
        let controller = NSWindowController(window: window)
        windowController = controller
        installFirstMouseActivationMonitor(for: window)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        CaptureEditorWindows.shared.register(window)
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
            CaptureEditorWindows.shared.unregister(window)
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

    func isShowing(model: AppModel) -> Bool {
        windowController != nil && self.model === model
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
        if let window = windowController?.window { CaptureEditorWindows.shared.register(window) }
        UserDefaults.standard.set(
            true,
            forKey: AppPreferences.editorWindowFullScreenKey
        )
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window = windowController?.window { CaptureEditorWindows.shared.register(window) }
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.editorWindowFullScreenKey
        )
    }

    private func editorMinimumSize() -> NSSize {
        // Match SwiftUI's content minimum on every display. A window created
        // on a large monitor must still fit when moved to a small one.
        EditorWorkspaceLayout.minimumWindowSize
    }

    private func centeredFrame(
        preserving frame: NSRect,
        inside visibleFrame: NSRect
    ) -> NSRect {
        let size = NSSize(
            width: min(frame.width, visibleFrame.width),
            height: min(frame.height, visibleFrame.height)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    private func systemMainScreen() -> NSScreen? {
        let displayID = UInt32(CGMainDisplayID())
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.screens.first
    }
}
