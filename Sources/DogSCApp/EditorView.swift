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
        Image(systemName: systemName)
            .font(.appUI(size: 15, weight: .regular))
            .foregroundStyle(EditorTheme.chrome(0.78))
            .frame(width: 32, height: 32)
            .background(isActive ? EditorTheme.selectionWash : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct EditorToolbarControlSurface<Content: View>: View {
    let accessibilityTitle: String
    var isActive = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .font(.appUI(size: 13, weight: .medium))
            .foregroundStyle(EditorTheme.chrome(0.82))
            .padding(.horizontal, 12).frame(height: 32)
            .background(isActive ? EditorTheme.selectionWash : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
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
    @State var showsScenePresetPopover = false
    @State var savedStylePresets: [EditorStylePreset] = []
    @State var isNamingStylePreset = false
    @State var stylePresetName = ""
    @State var activeStylePresetID: UUID?
    @State var activeStyleSnapshot: EditorStylePreset?
    @State var updatingStylePresetID: UUID?
    @State var defaultStylePresetID: UUID?
    @State var stylePresetTask: Task<Void, Never>?
    @State var isSavingStylePreset = false
    @State var stylePresetError: String?
    @State var stylePresetNotice: String?
    @State var pendingStylePreset: EditorStylePreset?
    @State private var spaceKeyMonitor: Any?
    @State private var titleEditingMouseMonitor: Any?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// Sync repair is an exceptional workflow, not a permanent editor lane.
    /// The camera inspector owns its disclosure while the timeline mirrors it.
    @State private var isCameraSyncEditing = false
    @State private var explicitInspectorTab: InspectorTab?
    @State private var timelineTrackVisibility: EditorTimelineTrackVisibility
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.low
    @State private var preferredTimelineHeight: CGFloat?
    @State private var isEditorActive = true
    @State private var workspaceWidth: CGFloat = 1510
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
        VStack(spacing: 0) {
            editorToolbar
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    GeometryReader { workspace in
                        editorWorkspace(size: workspace.size)
                    }
                    .background { EditorWorkspaceGrid() }

                    Color.clear.frame(height: 12)
                    timeline(panelHeight: resolvedTimelinePanelHeight(availableHeight: geometry.size.height))
                        .modifier(EditorFloatingSurface())
                        .firstUseTourTarget("editor.timeline", in: .editor, highlight: .rounded(24))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .onAppear { workspaceWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in workspaceWidth = width }
            }
        }
        .frame(minWidth: 1120, minHeight: 680)
        .frame(idealWidth: 1510, idealHeight: 980)
        .background(appBackground)
        // 界面交互使用铂金强调；橙/红/绿只表达内容身份与录制状态。
        .tint(editorAccent)
        .font(.appUI(.body))
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
                }
            )
            .frame(width: 0, height: 0)
        }
        .overlay(alignment: .top) {
            if let message = hostActions.errorMessage {
                editorErrorBanner(message)
                    .padding(.top, 52)
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
                    .zIndex(20)
            }
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
        .alert("场景预设", isPresented: Binding(
            get: { stylePresetNotice != nil },
            set: { if !$0 { stylePresetNotice = nil } }
        )) {
            Button("好", role: .cancel) { stylePresetNotice = nil }
        } message: {
            Text(stylePresetNotice ?? "")
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
        .animation(SpringMotion.fluid, value: hostActions.errorMessage)
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

    private func editorWorkspace(size: CGSize) -> some View {
        let minimumGap: CGFloat = size.width < 1250 ? 38 : 60
        let edge: CGFloat = size.width < 1250 ? 24 : 40
        let innerWidth = max(size.width - edge * 2, 1)
        let availableWidth = max(innerWidth - 72 - minimumGap * 2 - resolvedInspectorContentWidth, 160)
        let availableHeight = max(size.height - 32 - 46, 80)
        var workspaceCanvas = editorStore.previewProject.canvas
        if isCropping {
            workspaceCanvas.aspectRatio = .adaptive
            workspaceCanvas.crop = .full
        }
        let ratio = EditorWorkspaceGeometry.aspectRatio(
            canvas: workspaceCanvas,
            sourceSize: mediaSession.sourceDisplaySize
        )
        let canvasWidth = min(availableWidth, availableHeight * ratio)
        let canvasHeight = canvasWidth / ratio
        // The user prefers the two floating tool surfaces anchored to the workspace edges.
        let gap = max((innerWidth - 72 - resolvedInspectorContentWidth - canvasWidth) / 2, minimumGap)
        return HStack(alignment: .top, spacing: gap) {
            EditorWorkspaceToolRail(
                selection: Binding(get: { selectedInspector }, set: { selectedInspector = $0 }),
                isCropping: isCropping,
                cameraAvailable: mediaSession.inventories.camera.hasVideo,
                audioAvailable: sourceHasAudio || microphoneHasAudio,
                cursorAvailable: !context.media.pointerEvents.isEmpty
            )
            .firstUseTourTarget("editor.tools", in: .editor, highlight: .rounded(24))
            .frame(height: canvasHeight)
            .padding(.top, 46)
            VStack(spacing: 8) {
                canvasToolbar
                previewArea.frame(height: canvasHeight).clipped()
            }
            .frame(width: canvasWidth)
            editorInspector
                .frame(height: canvasHeight)
                .modifier(EditorFloatingSurface())
                .firstUseTourTarget("editor.inspector", in: .editor, highlight: .rounded(24))
                .padding(.top, 46)
        }
        .padding(.horizontal, edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(SpringMotion.fluid, value: ratio)
        .animation(nil, value: isCropping)
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture {
                guard !isCropping else { return }
                selectedPrimarySegmentIDs.removeAll()
                editorStore.selection = nil
            }
        }
    }

    private func toolbarCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .padding(.horizontal, 4).frame(height: 40)
    }

    private var projectMenu: some View {
        EditorActionMenu(title: "项目", items: [
            .action("打开项目…") { hostActions.openProject() },
            .action("在 Finder 中显示项目包") { hostActions.revealProjectInFinder() },
            .separator,
            .action("导出项目源文件…", isEnabled: context.media.source != nil) { hostActions.exportProjectSourceMedia() },
            .action("替换当前项目摄像头…", isEnabled: editorStore.project.media?.camera != nil) { hostActions.importCameraReplacement() },
            .separator,
            .action("删除当前项目…") { hostActions.deleteProject() }
        ]) {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.appUI(size: 17))
                Image(systemName: "chevron.down").font(.appUI(size: 9, weight: .medium))
            }.foregroundStyle(.secondary).frame(width: 48, height: 38)
        }
        .disabled(isCropping)
        .accessibilityIdentifier("editor.project.menu")
    }

    private var editorToolbar: some View {
        ZStack {
            EditorWindowChromeInteraction().accessibilityHidden(true)
            HStack(spacing: 12) {
                projectMenu
                titleEditor.frame(maxWidth: 360, alignment: .leading)
                persistenceIndicator
                Spacer(minLength: 20)
                HStack(spacing: 0) {
                    Button { undoManager?.undo() } label: {
                        EditorToolbarIconSurface(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.editorToolbarPress)
                    .disabled(isCropping || undoManager?.canUndo != true)
                    .help("撤销（⌘Z）").accessibilityLabel("撤销")
                    Button { undoManager?.redo() } label: {
                        EditorToolbarIconSurface(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(.editorToolbarPress)
                    .disabled(isCropping || undoManager?.canRedo != true)
                    .help("重做（⌘⇧Z）").accessibilityLabel("重做")
                }
                .padding(2).background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(EditorTheme.hairline, lineWidth: 0.75))
                stylePresetControl(compact: false)
                    .disabled(isCropping || isSavingStylePreset)
                    .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(EditorTheme.hairline, lineWidth: 0.75))
                    .help("保存或复用完整场景配置")
                Button { presentExport(scope: .fullProject) } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.appUI(size: 13, weight: .medium))
                        .padding(.horizontal, 18).frame(height: 40)
                }
                .buttonStyle(EditorSoftRaisedButtonStyle())
                .disabled(isCropping)
                .help(isCropping ? "请先完成或取消裁切" : "导出成片（⌘E）")
                .firstUseTourTarget("editor.export", in: .editor, highlight: .rounded(12))
                Button { AppSettingsWindowController.shared.show() } label: {
                    EditorToolbarIconSurface(systemName: "gearshape")
                }
                .buttonStyle(.editorToolbarPress)
                .help("设置（⌘,）").accessibilityLabel("设置")
                .accessibilityIdentifier("editor.app-settings")
                EditorAppearanceToggleButton()
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 72)
        .background(EditorTheme.panelSurface.opacity(0.88))
    }

    private var canvasToolbar: some View {
        HStack(spacing: 4) {
            previewControls
            if !isCropping {
                EditorActionMenu(title: "添加到画面", items: [
                    .action("柔化或突出", systemImage: "viewfinder") { addMosaicAtPlayhead() },
                    .action("导入贴图…", systemImage: "photo.badge.plus") { addStickerAtPlayhead() },
                    .action("粘贴图片", systemImage: "doc.on.clipboard", isEnabled: canPasteOverlayImage) { addPastedSticker() }
                ]) { EditorToolbarIconSurface(systemName: "plus") }
                .disabled(mediaSession.outputDuration <= 0)
                EditorActionMenu(title: "预览选项", items: [
                    .action("完整分辨率", isOn: previewResolutionMode == .full) { previewResolutionMode = .full },
                    .action("清晰预览", isOn: previewResolutionMode == .low) { previewResolutionMode = .low },
                    .separator,
                    .action("动态模糊", isOn: editorStore.project.motion.frameMotionBlur.isEnabled,
                            isEnabled: mediaSession.outputDuration > 0) { toggleFrameMotionBlur() }
                ]) { EditorToolbarIconSurface(systemName: "slider.horizontal.3") }
            }
        }
        .padding(4)
        .fixedSize(horizontal: true, vertical: false)
        .background(EditorTheme.panelSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private var persistenceIndicator: some View {
        switch hostActions.persistenceStatus {
        case .clean:
            // 自动保存成功是默认状态，不长期占用顶部栏。只有正在保存
            // 或保存失败时才出现反馈，避免一个没有操作价值的常驻图标。
            EmptyView()
        case .saving:
            ProgressView()
                .controlSize(.small)
                .help("正在保存项目")
        case let .failed(message):
            Button {
                hostActions.reportError("自动保存失败：\(message)")
            } label: {
                Label("保存失败", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.editorWarning)
            .help("自动保存失败：\(message)；点击查看")
            .accessibilityLabel("查看自动保存失败原因")
        }
    }

    private func editorErrorBanner(_ message: String) -> some View {
        let projectNoticePrefix = "项目已打开，但"
        let isProjectNotice = message.hasPrefix(projectNoticePrefix)
        let title = isProjectNotice ? "项目已打开，需要留意" : "操作未完成"
        let detail = isProjectNotice
            ? String(message.dropFirst(projectNoticePrefix.count))
            : message

        return HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: isProjectNotice
                    ? "exclamationmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.appUI(.caption, weight: .semibold))
                Text(detail)
                    .font(.appUI(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                hostActions.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.appUI(.caption, weight: .bold))
            }
            .buttonStyle(.editorDismissIcon(size: 28))
            .help("关闭提示")
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.leading, 13)
        .padding(.trailing, 9)
        .padding(.vertical, 10)
        .frame(maxWidth: 480, alignment: .leading)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.96),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)：\(detail)")
    }

    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            TextField("项目名称", text: $titleDraft)
                .textFieldStyle(.plain).font(.appUI(size: 15, weight: .medium))
                .padding(.horizontal, 10).frame(height: 36)
                .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(EditorTheme.selectionTint.opacity(0.5)))
                .focused($titleFieldFocused)
                .onSubmit(commitTitleEdit)
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
                        .font(.appUI(size: 15, weight: .medium))
                        .foregroundStyle(EditorTheme.chrome(0.88))
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "pencil")
                        .font(.appUI(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.editorToolbarPress)
            .accessibilityLabel("重命名项目").accessibilityValue(projectDisplayTitle)
            .help("点击重命名项目")
        }
    }

    private var projectDisplayTitle: String {
        context.projectIdentity.displayTitle(for: editorStore.project.title)
    }

    private func commitTitleEdit() {
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


    private func toggleFrameMotionBlur() {
        var motion = editorStore.project.motion
        motion.frameMotionBlur.isEnabled.toggle()
        do {
            try editorStore.replaceMotion(with: motion, actionName: "切换动态模糊")
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }


    private var previewControls: some View {
        toolbarCapsule {
            HStack(spacing: 2) {
                if cropPresentation.toolbarMode == .cropControls {
                    HStack(spacing: 5) {
                        Image(systemName: "crop")
                            .font(.appUI(size: 11, weight: .bold))
                            .foregroundStyle(Color.orange)
                        Text("裁切模式")
                            .font(.appUI(.caption, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.horizontal, 8)

                    Button("清除裁切") { resetCrop() }
                        .buttonStyle(.editorGhost)
                    Button("取消") { discardCrop() }
                        .buttonStyle(.editorGhost)
                    Button("完成") { confirmCrop() }
                        .buttonStyle(.editorPrimary(minHeight: 24))
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
                            Label("裁切", systemImage: "crop")
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(tint.opacity(showsProgress ? 0.20 : 0.30), lineWidth: 0.75)

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.appUI(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.94))
                Text(detail)
                    .font(.appUI(.caption2))
                    .foregroundStyle(Color.secondary.opacity(0.92))
                    .lineLimit(isBlocking ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, isBlocking ? 14 : 12)
        .padding(.vertical, isBlocking ? 12 : 10)
        .frame(maxWidth: isBlocking ? 320 : 280, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    EditorTheme.panelRaised.opacity(0.98),
                    EditorTheme.panelSurface.opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [EditorTheme.chrome(0.18), EditorTheme.chrome(0.055)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(EditorTheme.chrome(0.12))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
        .shadow(color: EditorTheme.softShadow.opacity(0.72), radius: 14, y: 6)
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
        .accessibilityLabel("\(title)，\(detail)")
        .accessibilityValue(showsProgress ? "处理中" : "需要注意")
    }

    private func timeline(panelHeight: CGFloat) -> some View {
        EditorTimelineView(
            editorStore: editorStore,
            mediaSession: mediaSession,
            playbackController: playbackController,
            isCameraSyncEditing: isCameraSyncEditing && selectedInspector == .camera,
            windowDeactivationRevision: windowDeactivationRevision,
            panelHeight: panelHeight,
            visibleTracks: timelineTrackVisibilityBinding,
            selectedPrimarySegmentIDs: $selectedPrimarySegmentIDs,
            onError: hostActions.reportError,
            isLayoutTransitioning: isWorkspaceReflowing,
            onPreferredHeightChange: updatePreferredTimelineHeight
        )
        .disabled(isCropping)
    }

    private func resolvedTimelinePanelHeight(availableHeight: CGFloat) -> CGFloat {
        // Grow upward by the actual sum of visible rows, including overlay
        // lanes and camera sync. Only a genuinely small window needs scrolling.
        // The budget is measured below the toolbar, without a stale height
        // preference or a percentage cap that clips ordinary expanded tracks.
        let minimumWorkspaceHeight: CGFloat = 320
        let surroundingSpacing: CGFloat = 12 + 16
        let budget = max(availableHeight - minimumWorkspaceHeight - surroundingSpacing, 170)
        return min((preferredTimelineHeight ?? 300).rounded(.up), budget)
    }

    private func updatePreferredTimelineHeight(_ height: CGFloat) {
        guard preferredTimelineHeight != height else { return }
        guard preferredTimelineHeight != nil else {
            preferredTimelineHeight = height
            return
        }
        performWorkspaceReflow { preferredTimelineHeight = height }
    }

    private var resolvedInspectorContentWidth: CGFloat {
        min(max(workspaceWidth * 0.23, 384), 432)
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
                    == "cn.laogou.dogsc.editor-window" else { return event }
            let targetsTextInput = mouseEventTargetsTextInput(event)

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
        guard let contentView = event.window?.contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        var candidate = contentView.hitTest(point)
        while let view = candidate {
            if view is NSTextField { return true }
            if let textView = view as? NSTextView, textView.isEditable { return true }
            candidate = view.superview
        }
        return false
    }

    private var editorInspector: some View {
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
            contentWidth: resolvedInspectorContentWidth,
            onChooseWallpaper: hostActions.chooseWallpaper,
            onChooseDesktopWallpaper: hostActions.importDesktopWallpaper,
            onError: hostActions.reportError
        )
    }
}
