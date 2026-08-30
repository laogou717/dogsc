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
        case .canvas, .screen, .primarySegment, .crop,
             .mosaic, .sticker, .progress, nil: return .frame
        case .zoomTrack, .zoom, .screenMotionTrack, .screenMotion: return .zoom
        case .cursor: return .cursor
        case .camera, .cameraMotion: return .camera
        case .audio: return .audio
        }
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
    static let defaultContentWidth: CGFloat = 320
    static let minimumContentWidth: CGFloat = 280
    static let maximumContentWidth: CGFloat = 400

    static func clampedContentWidth(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed.isFinite ? proposed : defaultContentWidth,
                minimumContentWidth),
            maximumContentWidth)
    }
}

private struct EditorToolbarIconSurface: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let systemName: String
    var isActive = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
            .foregroundStyle(foregroundColor)
            .frame(width: 32, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isActive
                            ? EditorTheme.platinumAccent.opacity(isHovered ? 0.20 : 0.14)
                            : Color.white.opacity(isHovered && isEnabled ? 0.085 : 0)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isActive
                            ? EditorTheme.platinumAccent.opacity(isHovered ? 0.52 : 0.30)
                            : Color.white.opacity(isHovered && isEnabled ? 0.12 : 0),
                        lineWidth: 0.75
                    )
            }
            .shadow(
                color: Color.black.opacity(isActive ? 0.16 : 0),
                radius: 2,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(isHovered && isEnabled ? 1.045 : 1.0)
            .onHover { isHovered = $0 }
            .animation(SpringMotion.interactive, value: isHovered)
    }

    private var foregroundColor: Color {
        if isActive {
            return EditorTheme.platinumAccent.opacity(0.96)
        }
        return isEnabled ? Color.primary.opacity(0.85) : Color.secondary
    }
}

/// Text controls and menus in the toolbar use the same compact material and
/// hover motion. The label owns this feedback so native macOS menus keep their
/// normal presentation and keyboard behaviour.
struct EditorToolbarControlSurface<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let accessibilityTitle: String
    var isActive = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundStyle)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: borderColors,
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(isHovered && isEnabled ? 0.18 : 0))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
            }
            .shadow(
                color: Color.black.opacity(isActive ? 0.16 : isHovered ? 0.20 : 0),
                radius: isHovered ? 4 : 2,
                y: isHovered ? 2 : 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(isHovered && isEnabled ? 1.02 : 1)
            .offset(y: isHovered && isEnabled ? -0.5 : 0)
            .onHover { hovering in
                withAnimation(SpringMotion.snappy) {
                    isHovered = hovering
                }
            }
            .animation(SpringMotion.interactive, value: isActive)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
    }

    private var foregroundColor: Color {
        if isActive {
            return EditorTheme.platinumAccent.opacity(0.98)
        }
        return isEnabled ? Color.primary.opacity(isHovered ? 1 : 0.86) : .secondary
    }

    private var backgroundStyle: LinearGradient {
        if isActive {
            return LinearGradient(
                colors: [
                    EditorTheme.platinumAccent.opacity(isHovered ? 0.24 : 0.18),
                    EditorTheme.platinumAccent.opacity(isHovered ? 0.14 : 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(isHovered && isEnabled ? 0.105 : 0),
                Color.white.opacity(isHovered && isEnabled ? 0.045 : 0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var borderColors: [Color] {
        if isActive {
            return [
                EditorTheme.platinumAccent.opacity(isHovered ? 0.58 : 0.42),
                EditorTheme.platinumAccent.opacity(0.16)
            ]
        }
        if isHovered && isEnabled {
            return [Color.white.opacity(0.18), Color.white.opacity(0.055)]
        }
        return [.clear, .clear]
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
    @State private var showsShortcutCheatsheet = false
    @State private var showsAddPalette = false
    @State var savedStylePresets: [EditorStylePreset] = []
    @State var isNamingStylePreset = false
    @State var stylePresetName = ""
    @State private var spaceKeyMonitor: Any?
    @State private var isEditingTitle = false
    @State private var isProjectTitleHovered = false
    @State private var titleDraft = ""
    /// Sync repair is an exceptional workflow, not a permanent editor lane.
    /// The camera inspector owns its disclosure while the timeline mirrors it.
    @State private var isCameraSyncEditing = false
    @State private var explicitInspectorTab: InspectorTab?
    @State private var timelineTrackVisibility: EditorTimelineTrackVisibility
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.low
    @AppStorage(AppPreferences.editorTimelinePrimaryLaneHeightKey)
    private var timelinePrimaryLaneHeight = Double(
        EditorTimelineSizing.defaultPrimaryLaneHeight
    )
    /// PRE-033: 分栏拖动期间的瞬态高度。每一帧都写 @AppStorage 会把
    /// UserDefaults 持久化卷进拖动热路径；拖动过程只写内存，松手才落盘。
    @State private var dragTimelinePrimaryLaneHeight: CGFloat?
    @AppStorage(AppPreferences.editorInspectorVisibleKey)
    private var isInspectorVisible = true
    @AppStorage(AppPreferences.editorInspectorWidthKey)
    private var inspectorContentWidth = Double(
        EditorInspectorSizing.defaultContentWidth
    )
    /// 检查器分栏拖动期间的瞬态宽度：同 PRE-033，拖动只写内存，松手落盘。
    @State private var dragInspectorContentWidth: CGFloat?
    @State private var inspectorResizeStartWidth: CGFloat?
    @State private var isInspectorResizeHandleHovered = false
    @FocusState private var titleFieldFocused: Bool
    @FocusState private var previewCanvasFocused: Bool
    @State private var timelineResizeStartHeight: CGFloat?
    @State private var isTimelineResizeHandleHovered = false
    /// A notification or another panel can take key status while this process
    /// remains active. Timeline-local gestures need that window boundary too;
    /// an application-level resign notification alone is insufficient.
    @State private var windowDeactivationRevision: UInt64 = 0

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
            Divider().overlay(dividerColor)

            HStack(spacing: 0) {
                previewArea
                if isInspectorVisible {
                    inspectorResizeHandle
                    editorInspector
                }
            }

            timelineResizeHandle
            timeline
        }
        .frame(minWidth: 1120, minHeight: 680)
        .frame(idealWidth: 1510, idealHeight: 820)
        .background(appBackground)
        // 界面交互使用铂金强调；橙/红/绿只表达内容身份与录制状态。
        .tint(editorAccent)
        .onChange(of: editorStore.selection) { _, selection in
            if selection != .canvas {
                explicitInspectorTab = nil
            }
        }
        .background {
            EditorWindowLifecycleBridge(
                projectTitle: projectDisplayTitle,
                onResignKey: {
                    resolveExternalAction(.windowDeactivation)
                    windowDeactivationRevision &+= 1
                    // 分栏拖动被失焦打断时 DragGesture 可能不再回调 onEnded；
                    // 丢弃瞬态高度（不落盘），避免预览栅格永久冻结。
                    dragTimelinePrimaryLaneHeight = nil
                    timelineResizeStartHeight = nil
                    dragInspectorContentWidth = nil
                    inspectorResizeStartWidth = nil
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
                exporter: exporter,
                editorStore: editorStore,
                mediaSession: mediaSession
            )
        }
        .sheet(isPresented: $showsShortcutCheatsheet) {
            EditorShortcutCheatsheet()
        }
        .alert("保存工作样式", isPresented: $isNamingStylePreset) {
            TextField("样式名称", text: $stylePresetName)
            Button("保存") { saveCurrentStylePreset() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("保存画布、屏幕外观、摄像头、光标和运镜默认值；不会保存裁切、片段或动画。")
        }
        .onReceive(EditorMenuBridge.shared.exportRequest) { _ in
            // 菜单栏 ⌘E 与工具栏导出按钮同一条路径。
            guard !isCropping, !showsExportSheet else { return }
            _ = editorStore.prepareForExternalAction(.export)
            showsExportSheet = true
        }
        .onReceive(EditorMenuBridge.shared.shortcutCheatsheetRequest) { _ in
            guard !isCropping, !showsShortcutCheatsheet else { return }
            showsShortcutCheatsheet = true
        }
        .onReceive(EditorMenuBridge.shared.quitRequest) { _ in
            let needsPanelDismissal = showsExportSheet
                || showsShortcutCheatsheet
                || isNamingStylePreset
            showsExportSheet = false
            showsShortcutCheatsheet = false
            isNamingStylePreset = false
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
                frameRate: editorStore.project.capture.captureFrameRate.rawValue,
                cameraTimingRevision: mediaSession.cameraTimingRevision
            )
            playbackController.updateAudio(editorStore.project.audio)
        }
        .task(id: mediaSession.lifecycle) {
            await prewarmReadyPointerTrack()
        }
        .onChange(of: editorStore.project.audio) { _, audio in
            playbackController.updateAudio(audio)
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
            editorStore.attachUndoManager(undoManager)
            if editorStore.selection == nil {
                editorStore.selection = .canvas
            }
            installSpaceKeyMonitor()
            EditorMenuBridge.shared.attachEditor(undoManager: undoManager)
        }
        .onChange(of: undoManager) { _, manager in
            editorStore.attachUndoManager(manager)
            EditorMenuBridge.shared.attachEditor(undoManager: manager)
        }
        .onDisappear {
            resolveExternalAction(.windowClosing)
            playbackController.invalidate()
            mediaSession.invalidate()
            editorStore.detachUndoManager()
            removeSpaceKeyMonitor()
            EditorMenuBridge.shared.detachEditor(undoManager: undoManager)
        }
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
            if newValue == .opening || newValue == .mockup {
                explicitInspectorTab = newValue
                editorStore.selection = .canvas
                return
            }
            explicitInspectorTab = nil
            switch newValue {
            case .frame: editorStore.selection = .canvas
            case .opening, .mockup: break
            case .zoom:
                if selectedZoomID == nil { editorStore.selection = .zoomTrack }
            case .cursor: editorStore.selection = .cursor
            case .camera: editorStore.selection = .camera
            case .audio:
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
        case .progress where !visibility.contains(.progress):
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

    /// 工具栏按任务分区，每组只承载一种意图。
    private func toolbarCapsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.062), Color.white.opacity(0.032)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.13),
                                Color.white.opacity(0.025)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: Color.black.opacity(0.22), radius: 3, y: 1)
    }

    private var editorToolbar: some View {
        GeometryReader { proxy in
            let usesCompactPresentation = proxy.size.width < 1_320
            ZStack {
                titleEditor
                    .frame(maxWidth: usesCompactPresentation ? 260 : 340)

                HStack(spacing: 8) {
                    toolbarCapsule {
                        Menu {
                            Button(action: hostActions.openProject) {
                                Label("打开项目…", systemImage: "folder")
                            }
                            Button(action: hostActions.revealProjectInFinder) {
                                Label("在 Finder 中显示项目包", systemImage: "magnifyingglass")
                            }
                            Divider()
                            Button(action: hostActions.exportProjectSourceMedia) {
                                Label("导出项目源文件…", systemImage: "square.and.arrow.up")
                            }
                            .disabled(context.media.source == nil)
                            Button(action: hostActions.importCameraReplacement) {
                                Label("替换当前项目摄像头…", systemImage: "video.badge.plus")
                            }
                            .disabled(editorStore.project.media?.camera == nil)
                            Divider()
                            Button(role: .destructive, action: hostActions.deleteProject) {
                                Label("删除当前项目…", systemImage: "trash")
                            }
                        } label: {
                            Label {
                                Text("项目")
                            } icon: {
                                EditorToolbarIconSurface(systemName: "folder")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(isCropping)
                        .help("项目")
                        .accessibilityIdentifier("editor.project.menu")
                    }

                    previewControls

                    toolbarCapsule {
                        Button {
                            showsAddPalette.toggle()
                        } label: {
                            EditorToolbarControlSurface(
                                accessibilityTitle: "添加",
                                isActive: showsAddPalette
                            ) {
                                // The toolbar surface must receive one label
                                // view. Passing three sibling views caused its
                                // material/focus modifiers to be distributed
                                // into three small controls when the popover
                                // took focus, and exposed three duplicate AX
                                // buttons with the same identifier.
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .bold))
                                    if !usesCompactPresentation {
                                        Text("添加")
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .rotationEffect(
                                                .degrees(showsAddPalette ? 180 : 0)
                                            )
                                    }
                                }
                            }
                        }
                        .buttonStyle(.editorToolbarPress)
                        .focusEffectDisabled()
                        .popover(isPresented: $showsAddPalette, arrowEdge: .top) {
                            EditorAddPalette(
                                insertionTime: overlayInsertionTime,
                                hasProgressOverlay: editorStore.previewProject.timeline.progressOverlay != nil,
                                canPasteImage: canPasteOverlayImage,
                                onAddMosaic: {
                                    dismissAddPaletteAndPerform(addMosaicAtPlayhead)
                                },
                                onImportSticker: {
                                    dismissAddPaletteAndPerform(addStickerAtPlayhead)
                                },
                                onPasteSticker: {
                                    dismissAddPaletteAndPerform(addPastedSticker)
                                },
                                onSelectProgress: {
                                    dismissAddPaletteAndPerform(addOrSelectProgressOverlay)
                                }
                            )
                        }
                        .help("添加柔化、贴图或成片进度条")
                        .accessibilityIdentifier("editor.add.palette")
                    }
                    .disabled(isCropping || mediaSession.outputDuration <= 0)

                    Spacer(minLength: usesCompactPresentation ? 272 : 356)

                    persistenceIndicator

                    toolbarCapsule {
                        Button { undoManager?.undo() } label: {
                            EditorToolbarIconSurface(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.editorToolbarPress)
                        .disabled(isCropping || undoManager?.canUndo != true)
                        .help(undoManager?.undoActionName.isEmpty == false
                            ? "撤销“\(undoManager?.undoActionName ?? "")”（⌘Z）"
                            : "撤销（⌘Z）")
                        .accessibilityLabel(undoManager?.undoActionName.isEmpty == false
                            ? "撤销\(undoManager?.undoActionName ?? "")"
                            : "撤销")

                        Button { undoManager?.redo() } label: {
                            EditorToolbarIconSurface(systemName: "arrow.uturn.forward")
                        }
                        .buttonStyle(.editorToolbarPress)
                        .disabled(isCropping || undoManager?.canRedo != true)
                        .help(undoManager?.redoActionName.isEmpty == false
                            ? "重做“\(undoManager?.redoActionName ?? "")”（⌘⇧Z）"
                            : "重做（⌘⇧Z）")
                        .accessibilityLabel(undoManager?.redoActionName.isEmpty == false
                            ? "重做\(undoManager?.redoActionName ?? "")"
                            : "重做")
                    }

                    toolbarCapsule {
                        previewResolutionMenu(compact: usesCompactPresentation)

                        Button {
                            isInspectorVisible.toggle()
                        } label: {
                            EditorToolbarIconSurface(
                                systemName: "sidebar.right",
                                isActive: isInspectorVisible
                            )
                        }
                        .buttonStyle(.editorToolbarPress)
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(
                            isInspectorVisible
                                ? "隐藏检查器（⌥⌘I）"
                                : "显示检查器（⌥⌘I）"
                        )
                        .accessibilityLabel(
                            isInspectorVisible ? "隐藏检查器" : "显示检查器"
                        )
                        .accessibilityValue(isInspectorVisible ? "已显示" : "已隐藏")
                        .accessibilityIdentifier("editor.inspector.visibility")
                    }

                    toolbarCapsule {
                        Button(action: toggleFrameMotionBlur) {
                            EditorToolbarControlSurface(
                                accessibilityTitle: "动态模糊",
                                isActive: editorStore.project.motion.frameMotionBlur.isEnabled
                            ) {
                                if usesCompactPresentation {
                                    Image(systemName: "wind")
                                } else {
                                    Label("动态模糊", systemImage: "wind")
                                }
                            }
                        }
                        .buttonStyle(.editorToolbarPress)
                        .disabled(isCropping || mediaSession.outputDuration <= 0)
                        .animation(SpringMotion.interactive, value: editorStore.project.motion.frameMotionBlur.isEnabled)
                        .help(
                            editorStore.project.motion.frameMotionBlur.isEnabled
                                ? "关闭动态模糊"
                                : "开启动态模糊"
                        )
                        .accessibilityLabel("动态模糊")
                        .accessibilityValue(
                            editorStore.project.motion.frameMotionBlur.isEnabled
                                ? "已开启"
                                : "已关闭"
                        )

                        stylePresetControl(compact: usesCompactPresentation)
                            .disabled(isCropping)
                            .help(
                                savedStylePresets.isEmpty
                                    ? "保存当前画布、摄像头、光标与运镜样式"
                                    : "保存或复用自己的画布、摄像头、光标与运镜样式"
                            )
                    }

                    Button {
                        _ = editorStore.prepareForExternalAction(.export)
                        showsExportSheet = true
                    } label: {
                        Label("导出", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.editorPrimary)
                    .disabled(isCropping)
                    .help(isCropping ? "请先完成或取消裁切" : "导出成片（⌘E）")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 52)
        .background(
            LinearGradient(
                colors: [EditorTheme.panelRaised.opacity(0.72), EditorTheme.panelSurface.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("操作未完成")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                hostActions.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
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
        .accessibilityLabel("操作未完成：\(message)")
    }

    /// 居中项目名：点击进入编辑，回车或失焦提交，改名命令走撤销与自动保存。
    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            TextField("项目名称", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(width: 220)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(EditorTheme.platinumAccent.opacity(0.10))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            EditorTheme.platinumAccent.opacity(0.44),
                            lineWidth: 0.75
                        )
                }
                .shadow(color: Color.black.opacity(0.20), radius: 3, y: 1)
                .focused($titleFieldFocused)
                .onSubmit(commitTitleEdit)
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitleEdit() }
                }
        } else {
            Button {
                titleDraft = context.projectIdentity.titleDraft(
                    for: editorStore.project.title
                )
                isEditingTitle = true
                titleFieldFocused = true
            } label: {
                Text(projectDisplayTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // ZStack 绝对居中：限制最大宽度，窄窗或裁切模式下不与
                    // 两侧控件簇重叠。
                    .frame(maxWidth: 340)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(isProjectTitleHovered ? 0.085 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(isProjectTitleHovered ? 0.20 : 0.12),
                                                Color.white.opacity(isProjectTitleHovered ? 0.075 : 0.04)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.75
                                    )
                            )
                    }
                    .shadow(
                        color: Color.black.opacity(isProjectTitleHovered ? 0.18 : 0),
                        radius: 3,
                        y: 1
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .scaleEffect(isProjectTitleHovered ? 1.012 : 1)
            }
            .buttonStyle(.editorToolbarPress)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isProjectTitleHovered = hovering
                }
            }
            .accessibilityLabel("重命名项目")
            .accessibilityValue(projectDisplayTitle)
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
            timelineTrackVisibility.formUnion(.overlays)
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

    private func addSticker(relativePath: String) {
        let insertionTime = overlayInsertionTime
        playbackController.seek(to: insertionTime, pausing: true)
        do {
            _ = try editorStore.addSticker(
                relativePath: relativePath,
                at: insertionTime,
                outputDuration: mediaSession.outputDuration
            )
            timelineTrackVisibility.formUnion(.overlays)
            previewCanvasFocused = true
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
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

    private func dismissAddPaletteAndPerform(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        showsAddPalette = false
        Task { @MainActor in
            action()
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

    private func addOrSelectProgressOverlay() {
        do {
            try editorStore.enableProgressOverlay()
            timelineTrackVisibility.insert(.progress)
            previewCanvasFocused = true
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
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.orange)
                        Text("裁切模式")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.horizontal, 8)

                    Button("重置") { resetCrop() }
                        .buttonStyle(.editorGhost)
                    Button("取消") { discardCrop() }
                        .buttonStyle(.editorGhost)
                    Button("完成") { confirmCrop() }
                        .buttonStyle(.editorPrimary(minHeight: 24))
                } else {
                    Menu {
                        ForEach(CanvasAspectRatio.allCases) { ratio in
                            Button {
                                setCanvasAspectRatio(ratio)
                            } label: {
                                if editorStore.project.canvas.aspectRatio == ratio {
                                    Label(ratio.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(ratio.rawValue)
                                }
                            }
                        }
                    } label: {
                        EditorToolbarControlSurface(accessibilityTitle: "画布比例") {
                            HStack(spacing: 6) {
                                Image(systemName: "aspectratio")
                                    .font(.system(size: 12, weight: .medium))
                                Text(editorStore.project.canvas.aspectRatio.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(minWidth: 38, alignment: .leading)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityIdentifier("editor.canvas.aspect-ratio")
                    .accessibilityLabel("画布比例")
                    .accessibilityValue(editorStore.project.canvas.aspectRatio.rawValue)

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
    }

    /// 预览画质只影响本地预览流畅度，属于"视图"范畴：与检查器开关同区，
    /// 不再与写项目的画布比例/裁切混在同一胶囊里。
    private func previewResolutionMenu(compact: Bool) -> some View {
        Menu {
            ForEach(EditorPreviewResolutionMode.allCases) { mode in
                Button {
                    previewResolutionMode = mode
                } label: {
                    if previewResolutionMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            EditorToolbarControlSurface(accessibilityTitle: "预览分辨率") {
                Text(
                    compact
                        ? (previewResolutionMode == .full ? "完整" : "流畅")
                        : (previewResolutionMode == .full ? "画质 · 完整" : "画质 · 流畅")
                )
            }
            // A borderless macOS Menu may rebuild its native accessibility
            // cell after first display and drop modifiers applied only to the
            // outer Menu. Pin the stable name/value to the extracted label too.
            .accessibilityLabel("预览分辨率")
            .accessibilityValue(previewResolutionMode.label)
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("editor.preview.resolution")
        .accessibilityLabel("预览分辨率")
        .accessibilityValue(previewResolutionMode.label)
        .help("流畅模式降低预览分辨率；完整模式保留素材细节")
    }

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.16)
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
                isSplitterResizing: isTimelineHeightResizing || isInspectorWidthResizing,
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
            .padding(.horizontal, 54)
            .padding(.vertical, 28)

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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.94))
                Text(detail)
                    .font(.caption2)
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
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.055)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(0.12))
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

    private var timeline: some View {
        EditorTimelineView(
            editorStore: editorStore,
            mediaSession: mediaSession,
            playbackController: playbackController,
            isCameraSyncEditing: isCameraSyncEditing && selectedInspector == .camera,
            windowDeactivationRevision: windowDeactivationRevision,
            primaryLaneHeight: resolvedTimelinePrimaryLaneHeight,
            visibleTracks: $timelineTrackVisibility,
            onError: hostActions.reportError
        )
    }

    private var resolvedTimelinePrimaryLaneHeight: CGFloat {
        EditorTimelineSizing.clampedPrimaryLaneHeight(
            dragTimelinePrimaryLaneHeight ?? CGFloat(timelinePrimaryLaneHeight)
        )
    }

    /// 分栏拖动进行中。预览栅格与时间线波形据此冻结重型重渲染，
    /// 松手后一次性按最终尺寸重评估。
    private var isTimelineHeightResizing: Bool {
        dragTimelinePrimaryLaneHeight != nil
    }

    private var resolvedInspectorContentWidth: CGFloat {
        EditorInspectorSizing.clampedContentWidth(
            dragInspectorContentWidth ?? CGFloat(inspectorContentWidth)
        )
    }

    private var isInspectorWidthResizing: Bool {
        dragInspectorContentWidth != nil
    }

    /// 预览与检查器之间的低干扰分栏条：向左拖加宽参数面板，向右拖把
    /// 空间归还预览；双击恢复默认。持久化值是编辑器界面偏好，不是项目内容。
    private var inspectorResizeHandle: some View {
        ZStack {
            Color.clear
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.16))
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1)
                Capsule()
                    .fill(
                        isInspectorResizeHandleHovered
                            ? Color.white.opacity(0.85)
                            : Color.white.opacity(0.22)
                    )
                    .frame(
                        width: isInspectorResizeHandleHovered ? 3 : 2,
                        height: 42
                    )
                    .shadow(
                        color: .white.opacity(isInspectorResizeHandleHovered ? 0.25 : 0),
                        radius: 4
                    )
            }
            .frame(width: 7)
        }
        // Keep the divider visually quiet while giving the pointer a practical
        // target. The extra width belongs to editor chrome, not project data.
        .frame(width: 13)
        .contentShape(Rectangle())
        .animation(SpringMotion.interactive, value: isInspectorResizeHandleHovered)
        .onHover { hovering in
            isInspectorResizeHandleHovered = hovering
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            // PRE-033 同一坐标系约束：必须用全局坐标测量，否则每次布局
            // 都会把面板自身位移折进 translation，形成来回振荡。
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = inspectorResizeStartWidth
                        ?? resolvedInspectorContentWidth
                    if inspectorResizeStartWidth == nil {
                        inspectorResizeStartWidth = start
                    }
                    // 向左拖（负屏幕位移）加宽检查器。
                    dragInspectorContentWidth = EditorInspectorSizing
                        .clampedContentWidth(start - value.translation.width)
                }
                .onEnded { _ in
                    if let finalWidth = dragInspectorContentWidth {
                        inspectorContentWidth = Double(finalWidth)
                    }
                    dragInspectorContentWidth = nil
                    inspectorResizeStartWidth = nil
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                inspectorResizeStartWidth = nil
                inspectorContentWidth = Double(
                    EditorInspectorSizing.defaultContentWidth
                )
            }
        )
        .help("左右拖动调整检查器宽度；双击恢复默认")
        .accessibilityElement()
        .accessibilityLabel("调整检查器宽度")
        .accessibilityValue(
            "内容面板 \(Int(resolvedInspectorContentWidth.rounded())) 点"
        )
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = switch direction {
            case .increment: 12
            case .decrement: -12
            @unknown default: 0
            }
            inspectorContentWidth = Double(
                EditorInspectorSizing.clampedContentWidth(
                    resolvedInspectorContentWidth + delta
                )
            )
        }
        .accessibilityAction(named: "恢复默认宽度") {
            inspectorContentWidth = Double(
                EditorInspectorSizing.defaultContentWidth
            )
        }
    }

    /// The timeline is a precision workspace, not a fixed footer. A quiet
    /// splitter lets editors enlarge waveforms while trimming and returns that
    /// space to the canvas when composition work resumes. The persisted value
    /// is global editor chrome, not project content.
    private var timelineResizeHandle: some View {
        ZStack {
            Color.clear
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.16))
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 1)
                Capsule()
                    .fill(
                        isTimelineResizeHandleHovered
                            ? Color.white.opacity(0.85)
                            : Color.white.opacity(0.22)
                    )
                    .frame(
                        width: 42,
                        height: isTimelineResizeHandleHovered ? 3 : 2
                    )
                    .shadow(
                        color: .white.opacity(isTimelineResizeHandleHovered ? 0.25 : 0),
                        radius: 4
                    )
            }
            .frame(height: 7)
        }
        .frame(height: 13)
        .contentShape(Rectangle())
        .animation(SpringMotion.interactive, value: isTimelineResizeHandleHovered)
        .onHover { hovering in
            isTimelineResizeHandleHovered = hovering
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            // PRE-033: 必须在稳定的全局坐标系测量位移。默认的视图局部坐标
            // 系随手道高度一起移动，每次布局都会把手柄自身的位移折进
            // translation，形成无阻尼的来回翻跳（拖动抖动/振荡的根因）。
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = timelineResizeStartHeight
                        ?? resolvedTimelinePrimaryLaneHeight
                    if timelineResizeStartHeight == nil {
                        timelineResizeStartHeight = start
                    }
                    dragTimelinePrimaryLaneHeight = EditorTimelineSizing
                        .resizedPrimaryLaneHeight(
                            start: start,
                            verticalTranslation: value.translation.height
                        )
                }
                .onEnded { _ in
                    if let finalHeight = dragTimelinePrimaryLaneHeight {
                        timelinePrimaryLaneHeight = Double(finalHeight)
                    }
                    dragTimelinePrimaryLaneHeight = nil
                    timelineResizeStartHeight = nil
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                timelineResizeStartHeight = nil
                timelinePrimaryLaneHeight = Double(
                    EditorTimelineSizing.defaultPrimaryLaneHeight
                )
            }
        )
        .help("上下拖动调整时间线高度；双击恢复默认")
        .accessibilityElement()
        .accessibilityLabel("调整时间线高度")
        .accessibilityValue(
            "主片段轨道 \(Int(resolvedTimelinePrimaryLaneHeight.rounded())) 点"
        )
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = switch direction {
            case .increment: 12
            case .decrement: -12
            @unknown default: 0
            }
            timelinePrimaryLaneHeight = Double(
                EditorTimelineSizing.clampedPrimaryLaneHeight(
                    resolvedTimelinePrimaryLaneHeight + delta
                )
            )
        }
        .accessibilityAction(named: "恢复默认高度") {
            timelinePrimaryLaneHeight = Double(
                EditorTimelineSizing.defaultPrimaryLaneHeight
            )
        }
    }

    private func installSpaceKeyMonitor() {
        guard spaceKeyMonitor == nil else { return }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, isCropping {
                discardCrop()
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

    private func removeSpaceKeyMonitor() {
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
            self.spaceKeyMonitor = nil
        }
    }

    private var editorInspector: some View {
        EditorInspectorView(
            editorStore: editorStore,
            mediaSession: mediaSession,
            playbackController: playbackController,
            pointerEvents: context.media.pointerEvents,
            selectedInspector: selectedInspectorBinding,
            isCameraSyncEditing: $isCameraSyncEditing,
            visibleTimelineTracks: $timelineTrackVisibility,
            isCropping: cropPresentation.inspectorMode == .cropInspector,
            cropDraft: cropDraftBinding,
            contentWidth: resolvedInspectorContentWidth,
            onChooseWallpaper: hostActions.chooseWallpaper,
            onChooseDesktopWallpaper: hostActions.importDesktopWallpaper,
            onError: hostActions.reportError
        )
    }
}
