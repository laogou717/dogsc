import AppKit
import AVKit
import Combine
import QuartzCore
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Sent synchronously before the editor handles a user-initiated Space
    /// transport command. Timeline tools use it to release transient editing
    /// state so a selected control cannot keep ownership of playback.
    static let editorWillTogglePlaybackFromSpace = Notification.Name(
        "cn.laogou.dogsc.editor-will-toggle-playback-from-space"
    )
}

enum EditorInspectorRouting {
    static func tab(for selection: EditorSelection?) -> InspectorTab {
        switch selection {
        case .canvas, .screen, .crop,
             .mosaic, .sticker, nil: return .frame
        case .primarySegment: return .audio
        case .zoomTrack, .zoom, .screenMotionTrack, .screenMotion: return .zoom
        case .cursor: return .cursor
        case .camera, .cameraMotion: return .camera
        case .audio: return .audio
        }
    }

    /// A primary clip is often selected only to move the editing cursor to the
    /// next piece of content. Keep the inspector task the user explicitly chose
    /// (audio, cursor, camera, motion or opening) instead of treating
    /// every primary-clip click as a request to open the frame inspector.
    static func explicitTabAfterSelectionChange(
        _ selection: EditorSelection?,
        current: InspectorTab?
    ) -> InspectorTab? {
        if case .primarySegment = selection {
            return .audio
        }
        guard let current else { return nil }
        if selection == .canvas,
           current == .opening {
            return current
        }
        return tab(for: selection) == current ? current : nil
    }
}

private struct EditorPlaybackInstallIdentity: Equatable {
    let lifecycle: EditorMediaSessionLifecycle
    let cameraTimingRevision: UInt64
}

/// The inspector is a workspace pane, not fixed chrome. Mirroring the
/// timeline lane sizing (PRE-033): the drag writes only memory, mouse-up
/// persists, double-click restores the default.
enum EditorInspectorSizing {
    static let defaultContentWidth: CGFloat = 384
    static let minimumContentWidth: CGFloat = 340
    static let maximumContentWidth: CGFloat = 480

    static func clampedContentWidth(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed.isFinite ? proposed : defaultContentWidth,
                minimumContentWidth),
            maximumContentWidth)
    }
}

struct EditorToolbarIconSurface: View {
    let systemName: String
    var isActive = false
    var body: some View {
        Group {
            // Toolbar actions share the recorder's hand-drawn stroke family;
            // anything without a drawn counterpart keeps its system symbol.
            if let kind = Self.lineIcon(for: systemName) {
                AppLineIcon(kind: kind, size: 16)
            } else {
                EditorSymbol(systemName, size: 18).font(.appUI(size: 14, weight: .regular))
            }
        }
        .foregroundStyle(EditorTheme.secondaryText)
        .frame(width: 30, height: 30)
        .background(isActive ? EditorTheme.selectionWash : .clear,
                    in: Circle())
        .contentShape(Circle())
    }

    static func lineIcon(for systemName: String) -> AppLineIcon.Kind? {
        EditorSymbolCatalog.kind(for: systemName)
    }
}

/// The one solid action on the editor's top edge: an ink capsule with an
/// inverted label. Hover only lifts its tone; press settles it slightly.
struct EditorPrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pill(configuration: configuration) }

    private struct Pill: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .font(.appUI(size: 13, weight: .semibold))
                .foregroundStyle(EditorTheme.onAccent)
                .padding(.horizontal, 14)
                .frame(height: 30)
                // The one primary action is the editor's black ink slab;
                // hover lifts it slightly, press settles it.
                .background(EditorTheme.platinumAccent.opacity(pressed ? 0.82 : 1),
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).fill(EditorTheme.onAccent.opacity(hovered && isEnabled && !pressed ? 0.12 : 0)))
                .shadow(color: hovered && isEnabled ? EditorTheme.accentGlow : .clear, radius: 6, y: 2)
                .contentShape(Capsule(style: .continuous))
                .appKeyboardFocus(in: Capsule(style: .continuous))
                .scaleEffect(pressed && !RecorderMotion.reduces ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(SpringMotion.snappy, value: pressed)
                .animation(SpringMotion.hover, value: hovered)
        }
    }
}

struct EditorToolbarControlSurface<Content: View>: View {
    let accessibilityTitle: String
    var isActive = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .font(.appUI(size: 12, weight: .medium))
            .foregroundStyle(EditorTheme.secondaryText)
            .padding(.horizontal, 10).frame(height: 30)
            .background(isActive ? EditorTheme.selectionWash : .clear,
                        in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLocalized(accessibilityTitle))
    }
}

enum EditorChromeMetrics {
    static let titleBarHeight: CGFloat = 46
}

/// A short vertical rule between toolbar groups.
struct EditorToolbarDivider: View {
    var body: some View {
        Rectangle().fill(EditorTheme.hairline).frame(width: 1, height: 16).padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

struct EditorView: View {
    let context: EditorSessionContext
    @ObservedObject var hostActions: EditorHostActions
    @ObservedObject private var exporter: VideoExporter
    @StateObject var editorStore: EditorStore
    @StateObject private var mediaSession: EditorMediaSession
    @StateObject var playbackController: EditorPlaybackController
    @Environment(\.undoManager) private var undoManager
    @State private var showsExportSheet = false
    @State private var exportScope: EditorExportScope = .fullProject
    @State private var showsShortcutCheatsheet = false
    /// A short "Undo: Adjust Zoom" chip, so ⌘Z is never a silent jump.
    @State private var undoToast: EditorUndoToast?
    @State var showsScenePresetPopover = false
    @State var savedStylePresets: [EditorStylePreset] = []
    @State var isNamingStylePreset = false
    @State var stylePresetName = ""
    @State var activeStylePresetID: UUID?
    @State var activeStyleSnapshot: EditorStylePreset?
    @State var activeStylePresetBackgroundSources: [BackgroundSource] = []
    @State var updatingStylePresetID: UUID?
    @State var defaultStylePresetID: UUID?
    @State var stylePresetTask: Task<Void, Never>?
    @State var isSavingStylePreset = false
    @State var stylePresetError: String?
    @State var stylePresetNotice: String?
    @State var pendingStylePreset: EditorStylePreset?
    @State private var spaceKeyMonitor: Any?
    @State private var titleEditingMouseMonitor: Any?
    @State private var titleInputRegion = EditorTextInputRegion()
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// Sync repair is an exceptional workflow, not a permanent editor lane.
    /// The camera inspector owns its disclosure while the timeline mirrors it.
    @State private var isCameraSyncEditing = false
    @State private var explicitInspectorTab: InspectorTab?
    @State private var inspectorMovesDown = true
    @State private var timelineTrackVisibility: EditorTimelineTrackVisibility
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.defaultValue
    @State private var preferredTimelineHeight: CGFloat?
    @State private var isEditorActive = true
    @State private var workspaceScreenSize = NSScreen.main?.visibleFrame.size
    @State private var isWorkspaceReflowing = false
    @State private var workspaceReflowTask: Task<Void, Never>?
    @FocusState private var titleFieldFocused: Bool
    @FocusState private var previewCanvasFocused: Bool
    /// A notification or another panel can take key status while this process
    /// remains active. Timeline-local gestures need that window boundary too;
    /// an application-level resign notification alone is insufficient.
    @State private var windowDeactivationRevision: UInt64 = 0
    /// The last-focused primary clip remains `EditorStore.selection`; this set
    /// adds transient multi-selection for ranged export without changing the
    /// persisted project or the inspector's single-target editing semantics.
    @State var selectedPrimarySegmentIDs: Set<UUID> = []

    init(context: EditorSessionContext) {
        self.context = context
        _hostActions = ObservedObject(wrappedValue: context.hostActions)
        _exporter = ObservedObject(wrappedValue: context.exporter)
        _editorStore = StateObject(
            wrappedValue: EditorStore(
                sessionID: context.id,
                document: context.document
            )
        )
        _mediaSession = StateObject(wrappedValue: context.makeMediaSession())
        _playbackController = StateObject(wrappedValue: EditorPlaybackController())
        _timelineTrackVisibility = State(
            initialValue: AppPreferences.timelineTrackVisibility(
                for: context.document.project
            )
        )

    }

    var body: some View {
        GeometryReader { window in
            let layout = EditorWorkspaceLayout(size: window.size, screenSize: workspaceScreenSize)
            // Docked studio layout: a slim title bar, the stage with its
            // transport HUD, the inspector docked to the right edge, and the
            // timeline spanning the full width below. Panels meet at hairlines.
            VStack(spacing: 0) {
                editorToolbar(layout: layout)
                Rectangle().fill(EditorTheme.hairline).frame(height: 1)
                GeometryReader { geometry in
                    let timelineHeight = layout.timelineHeight(
                        preferred: preferredTimelineHeight,
                        availableHeight: geometry.size.height
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            GeometryReader { stage in
                                editorStage(size: stage.size, layout: layout)
                            }
                            .background(EditorTheme.stage)
                            Rectangle().fill(EditorTheme.hairline).frame(width: 1)
                            editorInspectorColumn(layout: layout)
                        }
                        Rectangle().fill(EditorTheme.hairline).frame(height: 1)
                        timeline(panelHeight: timelineHeight, layout: layout)
                            .background(EditorTheme.panelSurface)
                            .firstUseTourTarget("editor.timeline", in: .editor, highlight: .rounded(0))
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        // The title bar starts at the window's top edge; the native traffic
        // lights are re-centred on its midline by the lifecycle bridge.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: EditorWorkspaceLayout.minimumWindowSize.width,
               minHeight: EditorWorkspaceLayout.minimumWindowSize.height)
        .background(EditorTheme.backgroundDeep)
        // 界面交互使用铂金强调；橙/红/绿只表达内容身份与录制状态。
        .tint(editorAccent)
        .font(.appUI(size: 13))
        .focusEffectDisabled()
        .firstUseTour(.editor, enabled: !showsExportSheet && !isCropping && !isNamingStylePreset && !showsShortcutCheatsheet)
        .environment(\.editorIsActive, isEditorActive)
        .onDisappear { workspaceReflowTask?.cancel() }
        .onChange(of: editorStore.selection) { _, selection in
            synchronizePrimarySegmentSelection(with: selection)
            explicitInspectorTab = EditorInspectorRouting
                .explicitTabAfterSelectionChange(
                    selection,
                    current: explicitInspectorTab
                )
        }
        .background {
            EditorWindowLifecycleBridge(
                projectTitle: projectDisplayTitle,
                onResignKey: {
                    resolveExternalAction(.windowDeactivation)
                    windowDeactivationRevision &+= 1
                },
                onActivityChanged: { active in
                    isEditorActive = active
                    playbackController.setPreviewActive(active)
                },
                onScreenSizeChanged: { workspaceScreenSize = $0 }
            )
            .frame(width: 0, height: 0)
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if let message = hostActions.errorMessage {
                    let revision = hostActions.errorRevision
                    EditorTransientNotice(message: message) {
                        guard hostActions.errorRevision == revision else { return }
                        hostActions.clearError()
                    }
                    .id(revision)
                    .transition(RecorderMotion.reduces ? .opacity : .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: -10))
                            .combined(with: .scale(scale: 0.96, anchor: .topTrailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing))
                    ))
                }
            }
            .padding(.top, EditorChromeMetrics.titleBarHeight + 12)
            .padding(.trailing, 12)
            .animation(SpringMotion.fluid ?? .easeOut(duration: 0.18), value: hostActions.errorRevision)
            .animation(SpringMotion.fluid ?? .easeOut(duration: 0.18), value: hostActions.errorMessage)
            .zIndex(20)
        }
        .sheet(isPresented: $showsExportSheet) {
            ExportSheet(
                wallpaperURLResolver: context.wallpaperURL,
                projectAssetURLResolver: context.projectAssetURL,
                projectDisplayName: projectDisplayTitle,
                exportScope: exportScope,
                exporter: exporter,
                editorStore: editorStore,
                mediaSession: mediaSession,
                playbackController: playbackController
            )
        }
        .sheet(isPresented: $showsShortcutCheatsheet) {
            EditorShortcutCheatsheet()
        }
        .sheet(isPresented: $isNamingStylePreset) {
            EditorScenePresetSheet(
                name: $stylePresetName,
                project: editorStore.project,
                sourceSize: mediaSession.sourceDisplaySize,
                isUpdating: updatingStylePresetID != nil,
                isSaving: isSavingStylePreset,
                error: stylePresetError,
                nameConflict: stylePresetNameConflict,
                onCancel: { isNamingStylePreset = false },
                onSave: saveCurrentStylePreset
            )
        }
        .sheet(item: $pendingStylePreset) { preset in
            EditorScenePresetPreview(
                preset: preset,
                mediaSession: mediaSession,
                outputTime: playbackController.outputTime,
                sourceSize: mediaSession.sourceDisplaySize,
                onCancel: { pendingStylePreset = nil },
                onApply: {
                    pendingStylePreset = nil
                    applyStylePreset(preset)
                }
            )
        }
        .appDialog(isPresented: Binding(
            get: { stylePresetNotice != nil },
            set: { if !$0 { stylePresetNotice = nil } }
        )) {
            AppDialog(title: "场景预设", message: stylePresetNotice ?? "", symbol: "rectangle.3.group",
                      actions: [.init(id: "acknowledge", title: "知道了", role: .primary)])
        }
        .onReceive(EditorMenuBridge.shared.exportRequest) { _ in
            // 菜单栏 ⌘E 与工具栏导出按钮同一条路径。
            presentExport(scope: .fullProject)
        }
        .onReceive(EditorMenuBridge.shared.shortcutCheatsheetRequest) { _ in
            guard !isCropping, !showsShortcutCheatsheet else { return }
            showsShortcutCheatsheet = true
        }
        .onReceive(EditorMenuBridge.shared.quitRequest) { _ in
            let needsPanelDismissal = showsExportSheet
                || showsShortcutCheatsheet
                || isNamingStylePreset
                || pendingStylePreset != nil
            showsExportSheet = false
            showsShortcutCheatsheet = false
            isNamingStylePreset = false
            pendingStylePreset = nil
            if needsPanelDismissal {
                // Let AppKit detach the SwiftUI sheet/alert before it asks the
                // editor window to close. The following terminate call still
                // uses the existing save barrier in windowShouldClose.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
        .task(id: editorMediaRequest) {
            await mediaSession.prepare(editorMediaRequest)
        }
        .task(id: context.cameraTimingRequest(for: editorStore.project)) {
            await mediaSession.updateCameraTiming(
                context.cameraTimingRequest(for: editorStore.project)
            )
        }
        .task(id: EditorPlaybackInstallIdentity(
            lifecycle: mediaSession.lifecycle,
            cameraTimingRevision: mediaSession.cameraTimingRevision
        )) {
            await playbackController.install(
                mediaSession.prepared,
                audio: editorStore.project.audio,
                primarySegmentAudioOverrides:
                    editorStore.project.timeline.primarySegmentAudioOverrides,
                frameRate: editorStore.project.capture.captureFrameRate.rawValue,
                cameraTimingRevision: mediaSession.cameraTimingRevision
            )
            playbackController.updateAudio(
                editorStore.project.audio,
                primarySegmentAudioOverrides:
                    editorStore.project.timeline.primarySegmentAudioOverrides
            )
        }
        .task(id: mediaSession.lifecycle) {
            await prewarmReadyPointerTrack()
        }
        .onChange(of: editorStore.project.audio) { _, audio in
            playbackController.updateAudio(
                audio,
                primarySegmentAudioOverrides:
                    editorStore.previewProject.timeline.primarySegmentAudioOverrides
            )
        }
        .onChange(
            of: editorStore.previewProject.timeline.primarySegmentAudioOverrides
        ) { _, overrides in
            playbackController.updateAudio(
                editorStore.previewProject.audio,
                primarySegmentAudioOverrides: overrides
            )
        }
        .onChange(of: timelineTrackVisibility) { _, visibility in
            AppPreferences.rememberTimelineTrackVisibility(
                visibility,
                for: editorStore.project
            )
            restoreSelectionAfterHidingTimelineTrack(visibility)
        }
        .onChange(of: mediaSession.cameraTimingErrorMessage) { _, message in
            if let message { hostActions.reportError(message) }
        }
        .onAppear {
            savedStylePresets = EditorStylePresetStore.load()
            defaultStylePresetID = EditorStylePresetStore.defaultPresetID
            if let matching = savedStylePresets.first(where: { $0.matchesConfiguration(of: editorStore.project, zoomCreationScale: AppPreferences.rememberedZoomCreationScale) }) {
                activeStylePresetID = matching.id
                activeStyleSnapshot = matching
                activeStylePresetBackgroundSources = matching.backgroundAsset == nil ? [] : [editorStore.project.canvas.backgroundSource]
            }
            editorStore.attachUndoManager(undoManager)
            if editorStore.selection == nil {
                editorStore.selection = .canvas
            }
            synchronizePrimarySegmentSelection(with: editorStore.selection)
            installSpaceKeyMonitor()
            installTitleEditingMouseMonitor()
            EditorMenuBridge.shared.attachEditor(undoManager: undoManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { note in
            guard let manager = note.object as? UndoManager, manager === undoManager else { return }
            presentUndoToast(redo: false, actionName: manager.redoActionName)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { note in
            guard let manager = note.object as? UndoManager, manager === undoManager else { return }
            presentUndoToast(redo: true, actionName: manager.undoActionName)
        }
        .onChange(of: undoManager) { _, manager in
            editorStore.attachUndoManager(manager)
            EditorMenuBridge.shared.attachEditor(undoManager: manager)
        }
        .onDisappear {
            stylePresetTask?.cancel()
            resolveExternalAction(.windowClosing)
            playbackController.invalidate()
            mediaSession.invalidate()
            editorStore.detachUndoManager()
            removeSpaceKeyMonitor()
            removeTitleEditingMouseMonitor()
            EditorMenuBridge.shared.detachEditor(undoManager: undoManager)
        }
    }

    var scenePresetSourceDimensions: CanvasDimensions {
        let size = mediaSession.sourceDisplaySize
        return CanvasDimensions(width: max(Int(size.width.rounded()), 2), height: max(Int(size.height.rounded()), 2))
    }

    private func prewarmReadyPointerTrack() async {
        guard case .ready = mediaSession.lifecycle,
              let pointerTrack = mediaSession.mediaPlan?.pointer else { return }
        let motion = editorStore.project.motion
        guard motion.cursor == .smooth else { return }
        let worker = Task.detached(priority: .utility) {
            pointerTrack.prewarmCursorSpring(motion: motion)
        }
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private var selectedInspector: InspectorTab {
        get {
            explicitInspectorTab
                ?? EditorInspectorRouting.tab(for: editorStore.selection)
        }
        nonmutating set {
            let order = InspectorTab.allCases
            inspectorMovesDown = (order.firstIndex(of: newValue) ?? 0) >= (order.firstIndex(of: selectedInspector) ?? 0)
            explicitInspectorTab = newValue
            if newValue == .opening {
                editorStore.selection = .canvas
                return
            }
            switch newValue {
            case .frame: editorStore.selection = .canvas
            case .opening: break
            case .zoom:
                if selectedZoomID == nil { editorStore.selection = .zoomTrack }
            case .cursor: editorStore.selection = .cursor
            case .camera: editorStore.selection = .camera
            case .audio:
                // A primary clip remains the active object while the audio
                // page is open; otherwise there would be no clip left for the
                // per-segment volume control to edit.
                if case .primarySegment = editorStore.selection { break }
                editorStore.selection = .audio(sourceHasAudio ? .system : .microphone)
            }
        }
    }

    private var sourceHasAudio: Bool { mediaSession.inventories.source.hasAudio }
    private var microphoneHasAudio: Bool { mediaSession.inventories.microphone.hasAudio }

    /// A hidden row can no longer explain or reselect the clip being edited.
    /// Leave the authored animation untouched, but return the inspector to the
    /// matching track/global context as soon as its selected row is hidden.
    private func restoreSelectionAfterHidingTimelineTrack(
        _ visibility: EditorTimelineTrackVisibility
    ) {
        let fallback: EditorSelection?
        switch editorStore.selection {
        case .zoom where !visibility.contains(.zoom):
            fallback = .zoomTrack
        case .screenMotion where !visibility.contains(.screenMotion):
            fallback = .screenMotionTrack
        case .cameraMotion where !visibility.contains(.cameraMotion):
            fallback = .camera
        case .mosaic where !visibility.contains(.mosaic):
            fallback = .canvas
        case .sticker where !visibility.contains(.sticker):
            fallback = .canvas
        default:
            fallback = nil
        }
        guard let fallback else { return }
        editorStore.cancelInteraction()
        editorStore.selection = fallback
    }

    /// Crop mode is not independent view state. The interaction draft is the
    /// single owner of both the active tool and its preview project, so every
    /// toolbar, inspector and canvas branch observes the same fact.
    var cropPresentation: EditorCropPresentation {
        editorStore.cropPresentation
    }

    var isCropping: Bool {
        cropPresentation.isActive
    }

    private var editorMediaRequest: EditorMediaRequest {
        context.mediaRequest(for: editorStore.project)
    }

    private var selectedZoomID: UUID? {
        get {
            guard case let .zoom(id) = editorStore.selection else { return nil }
            return id
        }
        nonmutating set {
            editorStore.selection = newValue.map(EditorSelection.zoom) ?? .zoomTrack
        }
    }

    private var selectedInspectorBinding: Binding<InspectorTab> {
        Binding(get: { selectedInspector }, set: { selectedInspector = $0 })
    }

    /// The stage: the canvas centred at its true aspect ratio, with the
    /// floating HUD (canvas tools + transport) beneath it.
    private func editorStage(size: CGSize, layout: EditorWorkspaceLayout) -> some View {
        let inset = layout.value(regular: 32, compact: 16)
        let hudReserve: CGFloat = layout.value(regular: 84, compact: 72)
        var workspaceCanvas = editorStore.previewProject.canvas
        if isCropping {
            workspaceCanvas.aspectRatio = .adaptive
            workspaceCanvas.crop = .full
        }
        let ratio = EditorWorkspaceGeometry.aspectRatio(
            canvas: workspaceCanvas,
            sourceSize: mediaSession.sourceDisplaySize
        )
        let availableWidth = max(size.width - inset * 2, 160)
        let availableHeight = max(size.height - inset - hudReserve, 120)
        let canvasWidth = min(availableWidth, availableHeight * ratio)
        let canvasHeight = canvasWidth / ratio
        return ZStack {
            // A quiet dot field marks the workspace as "not the picture", so
            // a white or flat-colour canvas never melts into its surroundings.
            EditorStageDots()
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isCropping else { return }
                    selectedPrimarySegmentIDs.removeAll()
                    editorStore.selection = nil
                }
            VStack(spacing: 0) {
                Spacer(minLength: inset)
                previewArea
                    .frame(width: canvasWidth, height: canvasHeight)
                    .clipped()
                    .overlay { EditorConsoleHUDOverlay(color: inspectorPalette.fill) }
                    .overlay(alignment: .top) {
                        if let undoToast {
                            EditorUndoToastView(toast: undoToast)
                                .id(undoToast.id)
                                .padding(.top, 14)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .animation(.spring(response: 0.36, dampingFraction: 0.82), value: undoToast?.id)
                    // Clipping trims pixels, not the hit regions of enlarged
                    // screen/camera overlays. Fence them inside the monitor.
                    .contentShape(Rectangle())
                    .shadow(color: EditorTheme.softShadow, radius: 22, y: 10)
                Spacer(minLength: 16)
                stageHUD(layout: layout)
                    .zIndex(1)
                Spacer(minLength: 16)
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(SpringMotion.fluid, value: ratio)
        .animation(nil, value: isCropping)
    }

    /// The colour identity of the current inspector tab (first 3 tabs use
    /// primary lime green, last 3 tabs use secondary coral orange).
    private var inspectorPalette: EditorConsolePalette {
        EditorConsole.palette(for: selectedInspector)
    }

    private func presentUndoToast(redo: Bool, actionName: String) {
        let id = (undoToast?.id ?? 0) + 1
        undoToast = EditorUndoToast(id: id, isRedo: redo, actionName: actionName)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            if undoToast?.id == id { undoToast = nil }
        }
    }

    private func editorInspectorColumn(layout: EditorWorkspaceLayout) -> some View {
        GeometryReader { column in
            VStack(spacing: 0) {
                EditorInspectorTabBar(
                    selection: Binding(get: { selectedInspector }, set: { selectedInspector = $0 }),
                    isCropping: isCropping,
                    cameraAvailable: mediaSession.inventories.camera.hasVideo,
                    audioAvailable: sourceHasAudio || microphoneHasAudio,
                    cursorAvailable: !context.media.pointerEvents.isEmpty
                )
                .firstUseTourTarget("editor.tools", in: .editor, highlight: .rounded(22))
                editorInspector(
                    contentWidth: EditorInspectorSizing.minimumContentWidth,
                    contentHeight: max(column.size.height - EditorInspectorTabBar.height - 1, 0)
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .firstUseTourTarget("editor.inspector", in: .editor, highlight: .rounded(0))
            }
        }
        .frame(width: EditorInspectorSizing.minimumContentWidth)
        .environment(\.consolePalette, inspectorPalette)
        .background(EditorTheme.panelSurface)
        .clipped()
    }

    private func toolbarCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
    }

    private var projectMenu: some View {
        EditorActionMenu(title: "项目", items: [
            .action("打开项目…") { hostActions.openProject() },
            .action("在 Finder 中显示项目包") { hostActions.revealProjectInFinder() },
            .separator,
            .action("导出项目源文件…", isEnabled: context.media.source != nil) { hostActions.exportProjectSourceMedia() },
            .action("替换当前项目摄像头…", isEnabled: editorStore.project.media?.camera != nil) { hostActions.importCameraReplacement() }
        ]) {
            HStack(spacing: 3) {
                AppLineIcon(kind: .folder, size: 15)
                AppLineIcon(kind: .chevronDown, size: 9)
            }.foregroundStyle(EditorTheme.secondaryText).frame(width: 44, height: 30)
        }
        .disabled(isCropping)
        .accessibilityIdentifier("editor.project.menu")
    }

    /// The title bar: project identity and history on the left, scene and
    /// app actions on the right, and the one solid action — Export — last.
    /// It leaves room for the native traffic lights and stays one flat band.
    private func editorToolbar(layout: EditorWorkspaceLayout) -> some View {
        ZStack {
            EditorWindowChromeInteraction().accessibilityHidden(true)
            HStack(spacing: 4) {
                HStack(spacing: 0) {
                    projectMenu
                    titleEditor
                }
                .frame(maxWidth: layout.value(regular: 420, compact: 260), alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                persistenceIndicator
                EditorToolbarDivider()
                Group {
                    Button { undoManager?.undo() } label: {
                        EditorToolbarIconSurface(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle())
                    .disabled(isCropping || undoManager?.canUndo != true)
                    .help("撤销（⌘Z）").accessibilityLabel("撤销")
                    Button { undoManager?.redo() } label: {
                        EditorToolbarIconSurface(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle())
                    .disabled(isCropping || undoManager?.canRedo != true)
                    .help("重做（⌘⇧Z）").accessibilityLabel("重做")
                }
                Spacer(minLength: 16)
                Group {
                    stylePresetControl(compact: layout.isCompact)
                        .disabled(isCropping || isSavingStylePreset)
                        .help("保存或复用完整场景配置")
                    EditorAppearanceToggleButton()
                    Button { AppSettingsWindowController.shared.show() } label: {
                        EditorToolbarIconSurface(systemName: "gearshape")
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle())
                    .help("设置（⌘,）").accessibilityLabel("设置")
                    .accessibilityIdentifier("editor.app-settings")
                    Button { hostActions.deleteProject() } label: {
                        EditorToolbarIconSurface(systemName: "trash")
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle())
                    .disabled(isCropping || isEditingTitle)
                    .help("删除当前项目…")
                    .accessibilityLabel("删除当前项目")
                    .accessibilityIdentifier("editor.project.delete")
                }
                EditorToolbarDivider()
                Button { presentExport(scope: .fullProject) } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .share, size: 14)
                        Text("导出")
                    }
                }
                .buttonStyle(EditorPrimaryPillButtonStyle())
                .disabled(isCropping)
                .help(appLocalized(isCropping ? "请先完成或取消裁切" : "导出成片（⌘E）"))
                .accessibilityLabel("导出")
                .firstUseTourTarget("editor.export", in: .editor, highlight: .rounded(16))
            }
            .padding(.leading, 78)
            .padding(.trailing, 12)
        }
        .frame(height: EditorChromeMetrics.titleBarHeight)
        .background(EditorTheme.chromeBar)
    }

    /// Canvas tools and transport share one floating capsule under the
    /// picture, so everything about "what is on screen now" sits together.
    private func stageHUD(layout: EditorWorkspaceLayout) -> some View {
        HStack(spacing: 2) {
            previewControls
            if !isCropping {
                EditorActionMenu(title: "添加到画面", items: [
                    .action("柔化或突出", systemImage: "viewfinder") { addMosaicAtPlayhead() },
                    .action("导入贴图…", systemImage: "photo.badge.plus") { addStickerAtPlayhead() },
                    .action("粘贴图片", systemImage: "doc.on.clipboard", isEnabled: canPasteOverlayImage) { addPastedSticker() }
                ]) { EditorToolbarIconSurface(systemName: "plus") }
                .disabled(mediaSession.outputDuration <= 0)
                EditorActionMenu(title: "预览选项", items: [
                    .action(EditorPreviewResolutionMode.full.label, detail: EditorPreviewResolutionMode.full.detail,
                            isOn: previewResolutionMode == .full) { previewResolutionMode = .full },
                    .action(EditorPreviewResolutionMode.low.label, detail: EditorPreviewResolutionMode.low.detail,
                            isOn: previewResolutionMode == .low) { previewResolutionMode = .low }
                ]) { EditorToolbarIconSurface(systemName: "slider.horizontal.3") }
                EditorToolbarDivider()
                transportControls
            }
        }
        .padding(4)
        .frame(height: 44)
        .fixedSize()
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay { Capsule(style: .continuous).fill(EditorTheme.panelSurface.opacity(0.55)) }
                .overlay { Capsule(style: .continuous).strokeBorder(EditorTheme.islandOutline, lineWidth: 0.5) }
                .shadow(color: EditorTheme.contactShadow, radius: 1, y: 0.5)
                .shadow(color: EditorTheme.softShadow, radius: 16, y: 6)
        }
        .animation(SpringMotion.settle, value: isCropping)
    }

    private var transportFrameDuration: TimeInterval {
        1 / Double(max(editorStore.project.capture.captureFrameRate.rawValue, 1))
    }

    private func stepTransport(byFrames frames: Int) {
        let duration = max(mediaSession.outputDuration, 0)
        let target = min(max(playbackController.outputTime + Double(frames) * transportFrameDuration, 0), duration)
        playbackController.seek(to: target, pausing: true)
    }

    private var transportControls: some View {
        HStack(spacing: 2) {
            Button { stepTransport(byFrames: -1) } label: {
                AppLineIcon(kind: .previousFrame, size: 15).frame(width: 32, height: 32)
            }
            .buttonStyle(EditorToolbarPressButtonStyle())
            .foregroundStyle(EditorTheme.secondaryText)
            .help("上一帧（←；Shift+← 移动 5 帧）")
            .accessibilityLabel("上一帧")
            Button { playbackController.togglePlayback() } label: {
                ZStack {
                    AppLineIcon(kind: .play, size: 15)
                        .opacity(playbackController.isPlaying ? 0 : 1)
                        .scaleEffect(playbackController.isPlaying ? 0.6 : 1)
                    AppLineIcon(kind: .pause, size: 15)
                        .opacity(playbackController.isPlaying ? 1 : 0)
                        .scaleEffect(playbackController.isPlaying ? 1 : 0.6)
                }
                .animation(SpringMotion.snappy, value: playbackController.isPlaying)
                .foregroundStyle(EditorTheme.onAccent)
                .frame(width: 36, height: 36)
                .background(EditorTheme.platinumAccent, in: Circle())
                .shadow(color: playbackController.isPlaying ? EditorTheme.accentGlow : .clear, radius: 6)
                .animation(.easeOut(duration: 0.2), value: playbackController.isPlaying)
            }
            .buttonStyle(EditorToolbarPressButtonStyle(showsHover: false))
            .disabled(!playbackController.canPlay)
            .help(appLocalized(playbackController.isPlaying ? "暂停（空格）" : "播放（空格）"))
            .accessibilityLabel(appLocalized(playbackController.isPlaying ? "暂停" : "播放"))
            Button { stepTransport(byFrames: 1) } label: {
                AppLineIcon(kind: .nextFrame, size: 15).frame(width: 32, height: 32)
            }
            .buttonStyle(EditorToolbarPressButtonStyle())
            .foregroundStyle(EditorTheme.secondaryText)
            .help("下一帧（→；Shift+→ 移动 5 帧）")
            .accessibilityLabel("下一帧")
            HStack(spacing: 5) {
                NativePlaybackTimeView(playbackController: playbackController)
                    .frame(width: 66, height: 20)
                Text("/ " + Self.transportTimestamp(mediaSession.outputDuration))
                    .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(EditorTheme.tertiaryText)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
        }
    }

    static func transportTimestamp(_ time: TimeInterval) -> String {
        let centiseconds = max(Int((max(time, 0) * 100).rounded(.down)), 0)
        return String(format: "%02d:%02d.%02d", centiseconds / 6_000, (centiseconds / 100) % 60, centiseconds % 100)
    }

    @ViewBuilder
    private var persistenceIndicator: some View {
        let state = EditorPersistenceBadgeState(
            status: hostActions.persistenceStatus, hasDraft: editorStore.interaction != nil
        )
        if case let .failed(message) = hostActions.persistenceStatus {
            Button {
                hostActions.reportError(String(format: appLocalized("自动保存失败：%@"), message))
            } label: {
                EditorPersistenceBadge(state: state)
            }
            .buttonStyle(.editorToolbarPress)
            .help("自动保存失败：\(message)；点击查看")
            .accessibilityLabel("查看自动保存失败原因")
        } else {
            EditorPersistenceBadge(state: state)
        }
    }

    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            TextField(appLocalized("项目名称"), text: $titleDraft)
                .textFieldStyle(.plain).font(.appUI(size: 13, weight: .medium))
                .tint(nil)
                .padding(.horizontal, 10).frame(height: 28)
                .background(EditorTheme.controlWell, in: Capsule(style: .continuous))
                .background(EditorTextInputRegionAnchor(region: titleInputRegion))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(EditorTheme.selectionTint.opacity(0.5))
                        .allowsHitTesting(false)
                }
                .focused($titleFieldFocused)
                .accessibilityLabel(appLocalized("项目名称"))
                .accessibilityIdentifier("editor.project.title-input")
                .onSubmit(commitTitleEdit)
                .onExitCommand(perform: cancelTitleEdit)
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitleEdit() }
                }
        } else {
            Button {
                titleDraft = context.projectIdentity.titleDraft(for: editorStore.project.title)
                isEditingTitle = true
                titleFieldFocused = true
            } label: {
                HStack(spacing: 10) {
                    Text(projectDisplayTitle)
                        .font(.appUI(size: 13, weight: .medium))
                        .foregroundStyle(EditorTheme.primaryText)
                        .lineLimit(1).truncationMode(.middle)
                    AppLineIcon(kind: .pencil, size: 11)
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(EditorToolbarPressButtonStyle())
            .accessibilityLabel("重命名项目").accessibilityValue(projectDisplayTitle)
            .help("点击重命名项目")
        }
    }

    private var projectDisplayTitle: String {
        context.projectIdentity.displayTitle(for: editorStore.project.title)
    }

    private func cancelTitleEdit() {
        guard isEditingTitle else { return }
        // End editing before releasing focus so the blur callback cannot save
        // the discarded draft or create a rename transaction.
        isEditingTitle = false
        titleDraft = context.projectIdentity.titleDraft(for: editorStore.project.title)
        titleFieldFocused = false
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingTitle = false
        titleFieldFocused = false
        guard !trimmed.isEmpty, trimmed != editorStore.project.title else { return }
        var renamed = editorStore.project
        renamed.title = trimmed
        do {
            try editorStore.replaceProject(with: renamed, actionName: "重命名项目")
            hostActions.saveProjectImmediately()
            _ = hostActions.renameProject(to: trimmed)
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private func addMosaicAtPlayhead() {
        let insertionTime = overlayInsertionTime
        playbackController.seek(to: insertionTime, pausing: true)
        do {
            _ = try editorStore.addMosaic(
                at: insertionTime,
                outputDuration: mediaSession.outputDuration
            )
            timelineTrackVisibilityBinding.wrappedValue = timelineTrackVisibility.union(.overlays)
            previewCanvasFocused = true
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private func addStickerAtPlayhead() {
        guard let relativePath = hostActions.importOverlayImage() else { return }
        addSticker(relativePath: relativePath)
    }

    private func addPastedSticker() {
        guard !isCropping,
              mediaSession.outputDuration > 0,
              let relativePath = hostActions.pasteOverlayImage() else { return }
        addSticker(relativePath: relativePath)
    }

    private func addSticker(
        relativePath: String,
        insertionTime: TimeInterval? = nil
    ) {
        do {
            try commitSticker(
                relativePath: relativePath,
                insertionTime: insertionTime
            )
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private func commitSticker(
        relativePath: String,
        insertionTime: TimeInterval? = nil
    ) throws {
        let insertionTime = insertionTime ?? overlayInsertionTime
        playbackController.seek(to: insertionTime, pausing: true)
        _ = try editorStore.addSticker(
            relativePath: relativePath,
            at: insertionTime,
            outputDuration: mediaSession.outputDuration
        )
        timelineTrackVisibilityBinding.wrappedValue = timelineTrackVisibility.union(.overlays)
        previewCanvasFocused = true
    }

    private var overlayInsertionTime: TimeInterval {
        let duration = max(mediaSession.outputDuration, 0)
        let minimumVisibleDuration = min(0.25, duration)
        return min(
            max(playbackController.outputTime, 0),
            max(duration - minimumVisibleDuration, 0)
        )
    }

    private var canPasteOverlayImage: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadItem(
            withDataConformingToTypes: [UTType.image.identifier]
        ) {
            return true
        }
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL] else {
            return false
        }
        return urls.contains { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else {
                return false
            }
            return type.conforms(to: .image)
        }
    }


    private var previewControls: some View {
        toolbarCapsule {
            HStack(spacing: 2) {
                if cropPresentation.toolbarMode == .cropControls {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .crop, size: 13)
                        Text("裁切模式")
                            .font(.appUI(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(EditorTheme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(EditorTheme.selectionWash, in: Capsule(style: .continuous))
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))

                    Button("清除裁切") { resetCrop() }
                        .buttonStyle(.editorGhost)
                    Button("取消") { discardCrop() }
                        .buttonStyle(.editorGhost)
                    Button("完成") { confirmCrop() }
                        .buttonStyle(.editorPrimary(minHeight: 30))
                } else {
                    EditorCanvasRatioSelector(canvas: Binding(
                        get: { editorStore.project.canvas },
                        set: { value in
                            guard cropPresentation.permits(.changeCanvasAspectRatio) else { return }
                            performEditorCommand {
                                try editorStore.replaceCanvas(with: value, actionName: "调整画布比例")
                            }
                        }))
                        .accessibilityIdentifier("editor.canvas.aspect-ratio")

                    Button { beginCrop() } label: {
                        EditorToolbarControlSurface(accessibilityTitle: "裁切") {
                            EditorSymbolLabel("裁切", systemImage: "crop")
                        }
                    }
                    .buttonStyle(.editorToolbarPress)
                    .accessibilityIdentifier("editor.crop.begin")
                    .help("直接拖动八个控制点裁切素材；按 Esc 取消")
                }
            }
        }
        .animation(nil, value: isCropping)
    }

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard cropPresentation.canvasMode != .cropEditor else { return }
                    previewCanvasFocused = true
                    editorStore.selection = .canvas
                }
            CanvasPreview(
                editorStore: editorStore,
                mediaSession: mediaSession,
                playbackController: playbackController,
                renderProject: editorStore.previewProject,
                previewResolutionMode: $previewResolutionMode,
                isCropping: cropPresentation.canvasMode == .cropEditor,
                isSplitterResizing: isWorkspaceReflowing,
                cropDraft: cropDraftBinding,
                wallpaperURLResolver: context.wallpaperURL,
                projectAssetURLResolver: context.projectAssetURL,
                onCanvasFocused: { previewCanvasFocused = true },
                onError: hostActions.reportError
            )
            .focusable(true)
            .focused($previewCanvasFocused)
            .focusEffectDisabled()
            .onPasteCommand(of: [.image, .fileURL]) { _ in
                addPastedSticker()
            }

            previewPreparationOverlay
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(SpringMotion.gentle, value: mediaSession.lifecycle)
        .animation(SpringMotion.gentle, value: playbackController.lifecycle)
    }

    @ViewBuilder
    private var previewPreparationOverlay: some View {
        switch (mediaSession.lifecycle, playbackController.lifecycle) {
        case (.ready, .ready):
            EmptyView()
        case (_, let .failed(message)):
            previewStatusCard(
                title: "预览准备失败",
                detail: message,
                systemImage: "exclamationmark.triangle.fill",
                showsProgress: false,
                isBlocking: true
            )
        case (.empty, _):
            previewStatusCard(
                title: "正在载入项目",
                detail: "准备录屏、摄像头和声音素材",
                systemImage: nil,
                showsProgress: true,
                isBlocking: true
            )
        case (.preparing, _):
            previewStatusCard(
                title: mediaSession.prepared == nil ? "正在准备预览" : "正在更新预览",
                detail: mediaSession.prepared == nil
                    ? "首帧就绪后会自动显示"
                    : "当前画面保持可见，更新完成后自动切换",
                systemImage: nil,
                showsProgress: true,
                isBlocking: mediaSession.prepared == nil
            )
        case (.failed, _):
            previewStatusCard(
                title: "预览准备失败",
                detail: mediaSession.errorMessage ?? "无法读取当前项目素材",
                systemImage: "exclamationmark.triangle.fill",
                showsProgress: false,
                isBlocking: true
            )
        case (.ready, .empty), (.ready, .preparing):
            previewStatusCard(
                title: "正在准备首帧",
                detail: "画面就绪后再启用播放，避免出现黑闪",
                systemImage: nil,
                showsProgress: true,
                isBlocking: playbackController.endpoints == nil
            )
        }
    }

    private func previewStatusCard(
        title: String,
        detail: String,
        systemImage: String?,
        showsProgress: Bool,
        isBlocking: Bool
    ) -> some View {
        let tint = showsProgress ? EditorTheme.platinumAccent : EditorTheme.amberAccent
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(showsProgress ? 0.10 : 0.13))

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else if let systemImage {
                    EditorSymbol(systemImage, size: 17)
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized(title))
                    .font(.appUI(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.94))
                Text(appLocalized(detail))
                    .font(.appUI(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.92))
                    .lineLimit(isBlocking ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, isBlocking ? 14 : 12)
        .padding(.vertical, isBlocking ? 12 : 10)
        .frame(maxWidth: isBlocking ? 320 : 280, alignment: .leading)
        .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(EditorTheme.chrome(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // Cast one shadow from the opaque card, not from its text/spinner or
        // a second highlight strip that forms a double outline on entrance.
        .compositingGroup()
        .shadow(color: EditorTheme.softShadow.opacity(0.28), radius: 10, y: 4)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.985)),
                removal: .opacity
            )
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: isBlocking ? .center : .topTrailing
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: appLocalized("预览状态 · %@，%@"), appLocalized(title), appLocalized(detail)))
        .accessibilityValue(appLocalized(showsProgress ? "处理中" : "需要注意"))
    }

    private func timeline(panelHeight: CGFloat, layout: EditorWorkspaceLayout) -> some View {
        EditorTimelineView(
            context: context,
            editorStore: editorStore,
            mediaSession: mediaSession,
            playbackController: playbackController,
            isCameraSyncEditing: isCameraSyncEditing && selectedInspector == .camera,
            windowDeactivationRevision: windowDeactivationRevision,
            panelHeight: panelHeight,
            layout: layout,
            visibleTracks: timelineTrackVisibilityBinding,
            selectedPrimarySegmentIDs: $selectedPrimarySegmentIDs,
            onError: hostActions.reportError,
            isLayoutTransitioning: isWorkspaceReflowing,
            onPreferredHeightChange: updatePreferredTimelineHeight
        )
        .disabled(isCropping)
    }

    private func updatePreferredTimelineHeight(_ height: CGFloat, animated: Bool) {
        guard preferredTimelineHeight != height else { return }
        guard preferredTimelineHeight != nil, animated else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { preferredTimelineHeight = height }
            return
        }
        performWorkspaceReflow { preferredTimelineHeight = height }
    }

    private var timelineTrackVisibilityBinding: Binding<EditorTimelineTrackVisibility> {
        Binding(get: { timelineTrackVisibility }, set: { visibility in
            guard visibility != timelineTrackVisibility else { return }
            performWorkspaceReflow { timelineTrackVisibility = visibility }
        })
    }

    private func performWorkspaceReflow(_ changes: () -> Void) {
        workspaceReflowTask?.cancel()
        isWorkspaceReflowing = true
        withAnimation(SpringMotion.gentle, changes)
        workspaceReflowTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            isWorkspaceReflowing = false
        }
    }

    private func installSpaceKeyMonitor() {
        guard spaceKeyMonitor == nil else { return }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue
                    == "cn.laogou.dogsc.editor-window", NSApp.modalWindow == nil,
                  !event.targetsPresentedContent else { return event }
            if event.keyCode == 53, isCropping {
                discardCrop()
                return nil
            }
            let exportModifiers = event.modifierFlags.intersection([
                .command, .control, .option,
            ])
            if event.keyCode == 7, // X
               exportModifiers == [.option],
               !event.isARepeat {
                guard event.window?.identifier?.rawValue
                        == "cn.laogou.dogsc.editor-window" else { return event }
                if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
                   textView.isEditable {
                    return event
                }
                presentSelectedPrimaryRangeExport()
                return nil
            }
            guard event.keyCode == 49, !event.isARepeat else { return event }
            if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
               textView.isEditable {
                return event
            }
            // EDT-015: transport owns Space whenever the user is not typing.
            // A focused AppKit button/slider must not remain the first
            // responder and replay its own action on the next key press.
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            // Release timeline-only selections/auditions before transport.
            // Posting synchronously ensures the normal playback request wins
            // over any pending camera-sync audition.
            NotificationCenter.default.post(
                name: .editorWillTogglePlaybackFromSpace,
                object: playbackController
            )
            // Media can be rebuilding after a sync-point edit. Do not discard
            // Space in that interval: queue the user's play request and start
            // as soon as the new generation is ready.
            playbackController.togglePlaybackFromUserIntent()
            return nil
        }
    }

    private func presentExport(scope: EditorExportScope) {
        guard !isCropping, !showsExportSheet else { return }
        exportScope = scope
        hostActions.clearError()
        _ = editorStore.prepareForExternalAction(.export)
        showsExportSheet = true
    }

    private func presentSelectedPrimaryRangeExport() {
        guard !isCropping, !showsExportSheet else { return }
        let sourceDuration = mediaSession.inventories.source.videoTimeRange?.duration ?? 0
        let map = try? EditorPrimaryTimelinePresentation.timelineMap(
            fullSourceDuration: sourceDuration,
            project: editorStore.project
        )
        guard let map else {
            hostActions.reportError("时间线尚未准备完成，暂时无法导出选区。")
            return
        }
        let selected = map.segments.filter {
            selectedPrimarySegmentIDs.contains($0.id)
        }
        guard let start = selected.map(\.outputStart).min(),
              let end = selected.map(\.outputEnd).max(),
              let range = MediaTimeRange(start: start, duration: end - start) else {
            hostActions.reportError("请先选择一个或多个主片段，再按 ⌥X 导出选区。")
            return
        }
        presentExport(
            scope: .timelineRange(
                range,
                selectedSegmentCount: selected.count
            )
        )
    }

    private func synchronizePrimarySegmentSelection(with selection: EditorSelection?) {
        guard case let .primarySegment(id) = selection else {
            selectedPrimarySegmentIDs.removeAll()
            return
        }
        guard !selectedPrimarySegmentIDs.contains(id) else { return }
        selectedPrimarySegmentIDs = [id]
    }

    private func removeSpaceKeyMonitor() {
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
            self.spaceKeyMonitor = nil
        }
    }

    /// SwiftUI's title TextField lives in the full-size custom title bar. In
    /// that hierarchy, clicking the canvas or timeline does not consistently
    /// resign the field editor. Observe editor mouse-downs and end title
    /// editing only when the click is outside any text input; the original
    /// event is still delivered to the clicked control.
    private func installTitleEditingMouseMonitor() {
        guard titleEditingMouseMonitor == nil else { return }
        titleEditingMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            guard event.window?.identifier?.rawValue
                    == "cn.laogou.dogsc.editor-window",
                  !event.targetsPresentedContent else { return event }
            let targetsTextInput = (isEditingTitle && titleInputRegion.contains(event))
                || mouseEventTargetsTextInput(event)

            // NSTextView keeps its caret even after the user resumes working
            // on empty inspector/timeline chrome. End any editable field when
            // the click is genuinely outside another text input, restoring
            // S/Q/W/Space to the global editor shortcut router immediately.
            if !targetsTextInput,
               let textView = event.window?.firstResponder as? NSTextView,
               textView.isEditable {
                event.window?.makeFirstResponder(nil)
            }

            guard isEditingTitle, !targetsTextInput else { return event }
            DispatchQueue.main.async {
                if isEditingTitle { commitTitleEdit() }
            }
            return event
        }
    }

    private func removeTitleEditingMouseMonitor() {
        if let titleEditingMouseMonitor {
            NSEvent.removeMonitor(titleEditingMouseMonitor)
            self.titleEditingMouseMonitor = nil
        }
    }

    private func mouseEventTargetsTextInput(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return EditorTextInputHitTesting.targetsTextInput(at: event.locationInWindow, in: window)
    }

    private func editorInspector(contentWidth: CGFloat, contentHeight: CGFloat) -> some View {
        EditorInspectorView(
            editorStore: editorStore,
            mediaSession: mediaSession,
            playbackController: playbackController,
            pointerEvents: context.media.pointerEvents,
            selectedInspector: selectedInspectorBinding,
            isCameraSyncEditing: $isCameraSyncEditing,
            visibleTimelineTracks: timelineTrackVisibilityBinding,
            isCropping: cropPresentation.inspectorMode == .cropInspector,
            cropDraft: cropDraftBinding,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            tabMovesDown: inspectorMovesDown,
            onChooseWallpaper: hostActions.chooseWallpaper,
            onError: hostActions.reportError
        )
    }
}

struct EditorUndoToast: Equatable {
    let id: Int
    let isRedo: Bool
    let actionName: String
}

/// The chip shown at the top of the canvas after ⌘Z / ⇧⌘Z.
struct EditorUndoToastView: View {
    let toast: EditorUndoToast

    var body: some View {
        HStack(spacing: 7) {
            AppLineIcon(kind: toast.isRedo ? .redo : .undo, size: 13)
            Text(appLocalized(toast.isRedo ? "重做" : "撤销"))
                .font(.appUI(size: 12, weight: .semibold))
            if !toast.actionName.isEmpty {
                Text(appLocalized(toast.actionName))
                    .font(.appUI(size: 12))
                    .opacity(0.72)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.black.opacity(0.62), in: Capsule(style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
