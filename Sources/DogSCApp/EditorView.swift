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

private struct EditorLiveAudioMixState: Equatable {
    let audio: AudioStyle
    let primarySegmentAudioOverrides: [UUID: PrimarySegmentAudioOverrides]
    let externalClips: [AudioClip]
    let speech: [OverlayTiming]

    init(project: RecorderProject) {
        audio = project.audio
        primarySegmentAudioOverrides = project.timeline.primarySegmentAudioOverrides
        externalClips = project.timeline.programAudioClips
        speech = project.timeline.audioClips.contains(where: \.ducksUnderSpeech)
            ? project.timeline.subtitleCues.map(\.timing)
            : []
    }
}

enum EditorInspectorRouting {
    static func tab(for selection: EditorSelection?) -> InspectorTab {
        switch selection {
        case .canvas, .screen, .crop,
             .mosaic, .sticker, .animation, .subtitle, .videoClip, nil: return .frame
        case .audioClip: return .audio
        case .primarySegment: return .frame
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
            return .frame
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
    let normalizesAudioLoudness: Bool
}

/// The inspector is a workspace pane, not fixed chrome. Mirroring the
/// timeline lane sizing (PRE-033): the drag writes only memory, mouse-up
/// persists, double-click restores the default.
enum EditorInspectorSizing {
    static let defaultContentWidth: CGFloat = 360
    static let minimumContentWidth: CGFloat = 320
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
                EditorSymbol(systemName, size: 18).font(.appUI(size: 13, weight: .regular))
            }
        }
        .foregroundStyle(isActive ? EditorTheme.primaryText : EditorTheme.secondaryText)
        .frame(width: 28, height: 28)
        .background(isActive ? EditorTheme.selectionWash : .clear,
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
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
                .foregroundStyle(EditorTheme.onAccentFill)
                .padding(.horizontal, 16)
                .frame(height: 32)
                // The window's one accent-filled action.
                .background(EditorTheme.accent,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(pressed ? 0.14 : hovered && isEnabled ? 0.07 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(SpringMotion.micro, value: pressed)
                .animation(SpringMotion.micro, value: hovered)
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
            .foregroundStyle(isActive ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .padding(.horizontal, 8).frame(height: 28)
            .background(isActive ? EditorTheme.selectionWash : .clear,
                        in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLocalized(accessibilityTitle))
    }
}

enum EditorChromeMetrics {
    static let titleBarHeight: CGFloat = 44
}

enum EditorCanvasBarMetrics {
    /// 编辑器第二版 · 监视器: a 44-high transport row under a 3-pt progress
    /// line, 12 apart from the picture and from each other.
    static let height: CGFloat = 44
    static let progressHitHeight: CGFloat = 15
    static let gap: CGFloat = 6
}

/// The transport row's quiet button (`.tbtn`): transparent, 30 high, 13-pt
/// label in secondary ink; hover lays a light wash and lifts it to ink.
struct EditorMonitorBarButtonSurface<Content: View>: View {
    let accessibilityTitle: String
    var isActive = false
    var iconOnly = false
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let lit = (hovered && isEnabled) || isActive
        content()
            .font(.appUI(size: 13, weight: .medium))
            .foregroundStyle(lit ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .padding(.horizontal, iconOnly ? 0 : 9)
            .frame(width: iconOnly ? 30 : nil, height: 30)
            .background(EditorTheme.chrome(lit ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
            .animation(SpringMotion.micro, value: hovered)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLocalized(accessibilityTitle))
    }
}

/// Preview quality as a two-way switch, visible without opening a menu.
struct EditorPreviewQualityToggle: View {
    @Binding var mode: EditorPreviewResolutionMode
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach([EditorPreviewResolutionMode.low, .full]) { option in
                let selected = mode == option
                Button {
                    withAnimation(SpringMotion.standard) { mode = option }
                } label: {
                    Text(option.label)
                        .font(.appUI(size: 13, weight: .medium))
                        .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(EditorTheme.segmentThumb)
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(EditorTheme.hairline, lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "quality", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.detail)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized("预览质量"))
    }
}

/// The transport's play disc presses down slightly (`.play:active`), with a
/// round focus ring and no hover wash.
struct EditorMonitorPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .contentShape(Circle())
                .appKeyboardFocus(in: Circle())
                .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.48)
                .animation(SpringMotion.micro, value: configuration.isPressed)
        }
    }
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
    @StateObject var mediaSession: EditorMediaSession
    @StateObject var playbackController: EditorPlaybackController
    /// The bin's preview takes over the monitor, so the stage observes it:
    /// previewing swaps the progress row and the canvas bar for the file's.
    @ObservedObject private var assetMonitor = EditorAssetMonitor.shared
    @Environment(\.undoManager) private var undoManager
    @State var cropSourceID: UUID?
    @State var pendingRecordingImport: RecordingImportBatch?
    @State var recordingImportTime: TimeInterval?
    @State var queuedRecordingImports: [([URL], TimeInterval?)] = []
    @State var recordingImportTask: Task<Void, Never>?
    @State private var showsExportSheet = false
    @State private var exportScope: EditorExportScope = .fullProject
    @State private var showsShortcutCheatsheet = false
    /// UndoManager's flags are not observable; mirror them from its notices.
    @State private var canUndo = false
    @State private var canRedo = false
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
    @State var stylePresetAppliedNotice: String?
    @State var stylePresetAppliedRevision: UInt64?
    @State var stylePresetNotice: String?
    @State var pendingStylePreset: EditorStylePreset?
    @State var scenePresetSelectedIDs: Set<UUID> = []
    @State var scenePresetAppliesToAll = false
    @State private var spaceKeyMonitor: Any?
    @State private var titleEditingMouseMonitor: Any?
    @State private var titleInputRegion = EditorTextInputRegion()
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// Sync repair is an exceptional workflow, not a permanent editor lane.
    /// The camera inspector owns its disclosure while the timeline mirrors it.
    @State private var isCameraSyncEditing = false
    @State private var explicitInspectorTab: InspectorTab?
    /// The 全片设置 page currently pushed in the inspector (nil = overview).
    @State private var inspectorSettingsPage: EditorSettingsPage?
    @State private var showsQuickPrompt = false
    @State private var inspectorMovesDown = true
    @State private var timelineTrackVisibility: EditorTimelineTrackVisibility
    @AppStorage(AppPreferences.audioLoudnessNormalizationEnabledKey)
    private var normalizesAudioLoudness = true
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.defaultValue
    @State private var preferredTimelineHeight: CGFloat?
    /// EDT-061: a height the user dragged the timeline to (0 = automatic).
    @AppStorage("editor.timeline.userHeight") private var userTimelineHeight = 0.0
    @State private var timelineResizeOrigin: CGFloat?
    @State private var isEditorActive = true
    @State private var isPreviewUpdateStatusRevealed = false
    @State private var workspaceScreenSize = NSScreen.main?.visibleFrame.size
    @State private var isWorkspaceReflowing = false
    /// Preview-only canvas shape transition (ratio / orientation changes).
    @State private var canvasAspectMorph: EditorCanvasAspectMorph?
    @State private var settledStageAspect: EditorStageAspectInput?
    @State private var workspaceReflowTask: Task<Void, Never>?
    /// EDT-054: left library panel (media bin, subtitles, AI).
    @AppStorage("editor.libraryPanel.visible") private var showsLibraryPanel = true
    @AppStorage("editor.libraryPanel.width") private var libraryPanelWidth = 280.0
    @State private var libraryResizeOrigin: Double?
    @AppStorage("editor.inspector.visible") private var showsInspector = true
    @AppStorage("editor.inspector.width") private var inspectorWidth = Double(EditorInspectorSizing.defaultContentWidth)
    @State private var inspectorResizeOrigin: Double?
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
                document: context.document,
                selection: .canvas
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
                    let automaticHeight = layout.timelineHeight(
                        preferred: preferredTimelineHeight,
                        availableHeight: geometry.size.height
                    )
                    let maximumHeight = max(geometry.size.height - 220, 150)
                    let timelineHeight = userTimelineHeight > 0
                        ? min(max(CGFloat(userTimelineHeight), 150), maximumHeight) : automaticHeight
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Group {
                                if showsLibraryPanel {
                                    EditorLibraryPanel(editorStore: editorStore) {
                                        performWorkspaceReflow { showsLibraryPanel = false }
                                    }
                                    .frame(width: libraryPanelWidth)
                                    .firstUseTourTarget("editor.library", in: .editor, highlight: .rounded(0))
                                    .overlay(alignment: .trailing) { libraryResizeHandle }
                                    .transition(.opacity)
                                } else {
                                    EditorLibraryRail { page in
                                        EditorLibraryPanel.remember(page)
                                        performWorkspaceReflow { showsLibraryPanel = true }
                                    }
                                    .firstUseTourTarget("editor.library", in: .editor, highlight: .rounded(0))
                                    .transition(.opacity)
                                }
                            }
                            .clipped()
                            Rectangle().fill(EditorTheme.hairline).frame(width: 1)
                            GeometryReader { stage in
                                editorStage(size: stage.size, layout: layout)
                            }
                            .background(EditorTheme.stage)
                            .onDrop(of: [EditorMediaDrag.mediaType, .fileURL], isTargeted: nil) { providers in
                                defer { EditorMediaDrag.endLocalDrag() }
                                return EditorMediaDrag.readAll(providers,
                                    onFailure: { hostActions.reportError(appLocalized("无法读取拖入的素材，请重新拖入。")) }) { items in
                                    let urls = items.compactMap { item -> URL? in
                                        if case let .file(url) = item { return url }
                                        return nil
                                    }
                                    let imported = editorStore.importMediaAssets(urls)
                                    let local = items.first { if case .file = $0 { return false }; return true }
                                    guard let asset = local.flatMap({ EditorMediaDrag.asset(for: $0, in: editorStore) })
                                        ?? imported.first else { return }
                                    place(EditorMediaPlacement(asset: asset))
                                }
                            }
                            if showsInspector {
                                Rectangle().fill(EditorTheme.hairline).frame(width: 1)
                                    .overlay { inspectorResizeHandle }
                                    .zIndex(2)
                                editorInspectorColumn()
                                    .transition(.opacity)
                            }
                        }
                        Rectangle().fill(EditorTheme.hairline).frame(height: 1)
                            .overlay { timelineResizeHandle(current: timelineHeight, maximum: maximumHeight) }
                            .zIndex(2)
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
        .firstUseTour(.editor, enabled: showsInspector && !showsExportSheet && !isCropping && !isNamingStylePreset && !showsShortcutCheatsheet)
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
                    .transition(.opacity)
                }
            }
            .padding(.top, EditorChromeMetrics.titleBarHeight + 12)
            .padding(.trailing, 12)
            .animation(SpringMotion.fade, value: hostActions.errorRevision)
            .zIndex(20)
        }
        .sheet(item: $pendingRecordingImport) { batch in
            EditorRecordingImportSheet(previews: batch.previews, initialTime: recordingImportTime,
                playheadTime: playbackController.outputTime, outputDuration: mediaSession.outputDuration) { options, time in
                    guard let package = hostActions.projectPackageURL() else { throw RecordingImportError.changed }
                    _ = try await editorStore.importRecordingProjects(batch.previews, into: package, at: time,
                        sourceDurations: mediaSession.sourceDurations, options: options)
                }
        }
        .onChange(of: pendingRecordingImport?.id) { _, id in
            if id == nil { advanceRecordingImportQueue() }
        }
        .onReceive(EditorMenuBridge.shared.importRecordingRequest) { _ in chooseRecordingProject() }
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
                project: scenePresetEditingProject,
                sourceSize: scenePresetSourceSize,
                isUpdating: updatingStylePresetID != nil,
                isSaving: isSavingStylePreset,
                error: stylePresetError,
                nameConflict: stylePresetNameConflict,
                onCancel: { isNamingStylePreset = false },
                onSave: saveCurrentStylePreset
            )
        }
        .sheet(item: $pendingStylePreset) { preset in
            EditorScenePresetScopeSheet(
                preset: preset, project: editorStore.project, segments: scenePresetSegments,
                selectedIDs: $scenePresetSelectedIDs, appliesToAll: $scenePresetAppliesToAll,
                isApplying: isSavingStylePreset,
                onCancel: { pendingStylePreset = nil },
                onApply: { applyStylePreset(preset, segmentIDs: scenePresetApplicationIDs) }
            )
            .onChange(of: scenePresetApplicationIDs, initial: true) { _, ids in
                editorStore.scenePresetPreviewSegmentIDs = ids
            }
            .onDisappear { editorStore.scenePresetPreviewSegmentIDs = nil }
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
        .onReceive(EditorMenuBridge.shared.toggleLibraryRequest) { _ in
            guard !isCropping else { return }
            performWorkspaceReflow { showsLibraryPanel.toggle() }
        }
        .onReceive(EditorMenuBridge.shared.quickPromptRequest) { _ in
            guard !isCropping else { return }
            withAnimation(SpringMotion.fade) { showsQuickPrompt.toggle() }
        }
        .onReceive(EditorMenuBridge.shared.revealLibraryRequest) { _ in
            if !showsLibraryPanel { performWorkspaceReflow { showsLibraryPanel = true } }
        }
        .onReceive(EditorMenuBridge.shared.toggleInspectorRequest) { _ in
            guard !isCropping else { return }
            performWorkspaceReflow { showsInspector.toggle() }
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
                || pendingRecordingImport != nil
            queuedRecordingImports.removeAll()
            recordingImportTask?.cancel()
            editorStore.recordingImportGeneration &+= 1
            pendingRecordingImport = nil
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
            cameraTimingRevision: mediaSession.cameraTimingRevision,
            normalizesAudioLoudness: normalizesAudioLoudness
        )) {
            let initialMix = EditorLiveAudioMixState(project: editorStore.previewProject)
            await playbackController.install(
                mediaSession.prepared,
                audio: initialMix.audio,
                primarySegmentAudioOverrides: initialMix.primarySegmentAudioOverrides,
                externalClips: initialMix.externalClips,
                speech: initialMix.speech,
                frameRate: editorStore.project.capture.captureFrameRate.rawValue,
                frameRatesBySource: editorStore.project.sources.reduce(into: [:]) {
                    $0[$1.id] = $1.capture.captureFrameRate.rawValue
                },
                cameraTimingRevision: mediaSession.cameraTimingRevision,
                normalizesAudioLoudness: normalizesAudioLoudness
            )
        }
        .task(id: mediaSession.lifecycle) {
            await prewarmReadyPointerTrack()
        }
        .onChange(of: EditorLiveAudioMixState(project: editorStore.previewProject)) { _, mix in
            playbackController.updateAudio(mix.audio, primarySegmentAudioOverrides: mix.primarySegmentAudioOverrides,
                externalClips: mix.externalClips, speech: mix.speech)
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
            EditorMenuBridge.shared.currentRecordingSourceID = { [mediaSession, playbackController] in
                mediaSession.sourceID(at: playbackController.latestOutputTime)
            }
            editorStore.recordingDurations = { [mediaSession] in mediaSession.sourceDurations }
            editorStore.insertRecordingSourceHook = { id, time, range in
                insertRecordingSource(id, at: time, sourceRange: range)
            }
            editorStore.cropRecording = { id in beginCrop(sourceID: id) }
            editorStore.revealRecording = { id in
                EditorLibraryPanel.remember(.media)
                UserDefaults.standard.set("project", forKey: "editor.mediaLibrary.scope")
                UserDefaults.standard.set("recording", forKey: "editor.mediaLibrary.filter")
                editorStore.revealedRecordingID = id
                if !showsLibraryPanel { performWorkspaceReflow { showsLibraryPanel = true } }
            }
            editorStore.requestRecordingImports = { urls, time in prepareRecordingImports(urls, at: time) }
            editorStore.placeMedia = { placement in place(placement) }
            editorStore.playheadTime = { [playbackController] in playbackController.outputTime }
            editorStore.seekPlayhead = { [playbackController] time in playbackController.seek(to: time) }
            editorStore.reportError = { [hostActions] message in hostActions.reportError(message) }
            editorStore.outputDuration = { [mediaSession] in mediaSession.outputDuration }
            AgentBridgeServer.shared.snapshotWallpaperURL = context.wallpaperURL
            AgentBridgeServer.shared.pointerEventsBySource = { [mediaSession] in mediaSession.pointerEventsBySource }
            AgentBridgeServer.shared.attach(store: editorStore, playback: playbackController, outputDuration: { [mediaSession] in mediaSession.outputDuration },
                                            recordingDurations: { [mediaSession] in mediaSession.sourceDurations },
                                            canvasSize: { [mediaSession, editorStore] in
                                                let size = mediaSession.canvasSourceSize(for: editorStore.project)
                                                guard size.width > 0, size.height > 0 else { return nil }
                                                let crop = editorStore.project.canvas.crop.clamped()
                                                let d = editorStore.project.canvas.pixelDimensions(
                                                    resolution: editorStore.project.exportSettings.resolution,
                                                    sourceAspectRatio: Double(size.width / size.height) * crop.width / crop.height,
                                                    sourcePixelSize: CanvasDimensions(width: Int(size.width), height: Int(size.height)))
                                                return CGSize(width: d.width, height: d.height)
                                            })
            AgentBridgeServer.shared.projectPackageURL = { [hostActions] in hostActions.projectPackageURL() }
            ProjectFiles.setPackage(hostActions.projectPackageURL())
            AgentChatModel.shared.loadConversation()
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
            EditorMenuBridge.shared.attachEditor(undoManager: undoManager, store: editorStore)
            refreshUndoAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { note in
            guard let manager = note.object as? UndoManager, manager === undoManager else { return }
            refreshUndoAvailability()
            presentUndoToast(redo: false, actionName: manager.redoActionName)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { note in
            guard let manager = note.object as? UndoManager, manager === undoManager else { return }
            refreshUndoAvailability()
            presentUndoToast(redo: true, actionName: manager.undoActionName)
        }
        .onChange(of: undoManager) { _, manager in
            editorStore.attachUndoManager(manager)
            EditorMenuBridge.shared.attachEditor(undoManager: manager, store: editorStore)
            refreshUndoAvailability()
        }
        // Not NSUndoManagerCheckpoint: reading canUndo/canRedo posts a
        // checkpoint itself, which would loop.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { note in
            guard (note.object as? UndoManager) === undoManager else { return }
            DispatchQueue.main.async { refreshUndoAvailability() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidOpenUndoGroup)) { note in
            guard (note.object as? UndoManager) === undoManager else { return }
            DispatchQueue.main.async { refreshUndoAvailability() }
        }
        .onChange(of: editorStore.revision) { _, _ in refreshUndoAvailability() }
        .onDisappear {
            recordingImportTask?.cancel()
            editorStore.recordingImportGeneration &+= 1
            editorStore.requestRecordingImports = { _, _ in }
            EditorMenuBridge.shared.currentRecordingSourceID = { nil }
            editorStore.recordingDurations = { [:] }
            editorStore.insertRecordingSourceHook = { _, _, _ in }
            editorStore.cropRecording = { _ in }
            editorStore.revealRecording = { _ in }
            AgentBridgeServer.shared.detach(store: editorStore)
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
        let size = scenePresetSourceSize
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

    private var sourceHasAudio: Bool { mediaSession.hasSystemAudio }
    private var microphoneHasAudio: Bool { mediaSession.hasMicrophoneAudio }

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

    /// The stage: the canvas centred at its true aspect ratio on a plain
    /// field, with the canvas bar docked directly under it.
    private func editorStage(size: CGSize, layout: EditorWorkspaceLayout) -> some View {
        let inset = layout.value(regular: 28, compact: 16)
        let barHeight: CGFloat = EditorCanvasBarMetrics.height + EditorCanvasBarMetrics.progressHitHeight
        let barGap: CGFloat = EditorCanvasBarMetrics.gap * 2
        var workspaceCanvas = editorStore.previewProject.canvas
        if isCropping {
            workspaceCanvas.aspectRatio = .adaptive
            workspaceCanvas.crop = .full
        }
        let stageSourceSize = isCropping
            ? (cropSourceID.flatMap { mediaSession.sourceDisplaySize(for: $0) } ?? mediaSession.primarySourceDisplaySize)
            : mediaSession.primarySourceDisplaySize
        let targetRatio = EditorWorkspaceGeometry.aspectRatio(canvas: workspaceCanvas, sourceSize: stageSourceSize)
        let aspectInput = EditorStageAspectInput(
            ratio: targetRatio,
            isCropping: isCropping,
            sourceSize: stageSourceSize
        )
        // One clock drives the shape change: the stage frame and the rendered
        // canvas read the same interpolated ratio on every display frame, so
        // the picture reflows continuously in both directions. Paused (no
        // per-frame work) whenever no morph is running.
        return TimelineView(.animation(paused: canvasAspectMorph == nil)) { timeline in
            let ratio = EditorCanvasAspectMorph.displayed(
                target: aspectInput,
                settled: settledStageAspect,
                morph: canvasAspectMorph,
                at: timeline.date
            )
            editorStageContent(
                size: size,
                inset: inset,
                barHeight: barHeight,
                barGap: barGap,
                ratio: ratio,
                transientAspect: ratio == targetRatio ? nil : ratio
            )
        }
        .onChange(of: aspectInput, initial: true) { old, new in
            beginCanvasAspectMorph(from: old, to: new)
        }
        .transaction(value: targetRatio) { $0.animation = nil }
    }

    private func beginCanvasAspectMorph(from old: EditorStageAspectInput, to new: EditorStageAspectInput) {
        defer { settledStageAspect = new }
        guard let settled = settledStageAspect, settled.morphs(to: new), settled.ratio != new.ratio else {
            canvasAspectMorph = nil
            return
        }
        let now = Date()
        // Retargeting mid-flight starts from the shape on screen right now.
        let from = canvasAspectMorph?.value(at: now) ?? settled.ratio
        let morph = EditorCanvasAspectMorph(from: from, to: new.ratio, start: now)
        canvasAspectMorph = morph
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(EditorCanvasAspectMorph.duration))
            if canvasAspectMorph?.id == morph.id { canvasAspectMorph = nil }
        }
    }

    private func editorStageContent(
        size: CGSize,
        inset: CGFloat,
        barHeight: CGFloat,
        barGap: CGFloat,
        ratio: CGFloat,
        transientAspect: CGFloat?
    ) -> some View {
        let availableWidth = max(size.width - inset * 2, 160)
        let availableHeight = max(size.height - inset * 2 - barHeight - barGap, 120)
        let canvasWidth = min(availableWidth, availableHeight * ratio)
        let canvasHeight = canvasWidth / ratio
        return ZStack {
            EditorTheme.stage
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isCropping else { return }
                    // Clicking the field around the picture puts the
                    // programme back, as clicking the timeline does.
                    assetMonitor.returnToProgramme()
                    selectedPrimarySegmentIDs.removeAll()
                    editorStore.selection = nil
                }
            if showsQuickPrompt {
                VStack {
                    EditorQuickPrompt(
                        onSend: {
                            showsQuickPrompt = false
                            EditorLibraryPanel.remember(.ai)
                            if !showsLibraryPanel { performWorkspaceReflow { showsLibraryPanel = true } }
                        },
                        onClose: { withAnimation(SpringMotion.fade) { showsQuickPrompt = false } }
                    )
                    .padding(.top, 16)
                    Spacer()
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
                .zIndex(3)
            }
            VStack(spacing: EditorCanvasBarMetrics.gap) {
                previewArea(transientAspect: transientAspect)
                    .frame(width: canvasWidth, height: canvasHeight)
                    .clipped()
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(EditorTheme.islandOutline, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .overlay { EditorConsoleHUDOverlay() }
                    // Previewing one asset takes over the monitor; the
                    // programme must not go on playing behind it.
                    .overlay { EditorAssetMonitorOverlay() }
                    .onChange(of: EditorAssetMonitor.shared.isPreviewing) { _, previewing in
                        if previewing { playbackController.pause() }
                    }
                    .overlay(alignment: .top) {
                        if let undoToast {
                            EditorUndoToastView(toast: undoToast)
                                .id(undoToast.id)
                                .padding(.top, 12)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let message = stylePresetAppliedNotice {
                            HStack(spacing: 10) {
                                AppLineIcon(kind: .check, size: 14).foregroundStyle(EditorTheme.accent)
                                Text(message).font(.appUI(size: 12)).lineLimit(2)
                                if stylePresetAppliedRevision == editorStore.revision, canUndo {
                                    Button("撤销") { undoManager?.undo(); stylePresetAppliedNotice = nil }.buttonStyle(.editorGhost)
                                }
                                Button { stylePresetAppliedNotice = nil } label: {
                                    AppLineIcon(kind: .close, size: 12).frame(width: 20, height: 24).contentShape(Rectangle())
                                }.buttonStyle(.editorGhost).accessibilityLabel("关闭提示")
                            }.padding(.horizontal, 11).padding(.vertical, 7)
                                .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(EditorTheme.hairline, lineWidth: 1))
                                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                                .padding(.horizontal, 12).padding(.bottom, 14).transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: stylePresetAppliedNotice)
                    .animation(SpringMotion.fade, value: undoToast?.id)
                    // Clipping trims pixels, not the hit regions of enlarged
                    // screen/camera overlays. Fence them inside the monitor.
                    .contentShape(Rectangle())
                // The one thin progress line between the picture and the
                // transport: the accent shows what has played; drag to seek.
                Group {
                    if assetMonitor.isPreviewing, !isCropping {
                        EditorAssetPreviewProgress(playback: assetMonitor.playback)
                    } else {
                        NativeMonitorProgressView(
                            playbackController: playbackController,
                            duration: mediaSession.outputDuration
                        )
                        .padding(.horizontal, 2)
                        .help(appLocalized("拖动定位"))
                    }
                }
                .frame(width: canvasWidth, height: EditorCanvasBarMetrics.progressHitHeight)
                canvasBar(width: max(canvasWidth, min(availableWidth, 560)))
                    .firstUseTourTarget("editor.canvasbar", in: .editor, highlight: .rounded(EditorInterfaceRadius.group))
                    .zIndex(1)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// The colour identity of the current inspector tab.
    private var inspectorPalette: EditorConsolePalette {
        EditorConsole.palette(for: selectedInspector)
    }

    private func refreshUndoAvailability() {
        let undo = undoManager?.canUndo == true || editorStore.hasPendingAgentUndoChanges
        let redo = undoManager?.canRedo == true
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }

    private func presentUndoToast(redo: Bool, actionName: String) {
        let id = (undoToast?.id ?? 0) + 1
        undoToast = EditorUndoToast(id: id, isRedo: redo, actionName: actionName)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            if undoToast?.id == id { undoToast = nil }
        }
    }

    /// Every workspace divider behaves the same: drag writes memory only and
    /// freezes the canvas raster, release persists, double-click restores.
    private func beginSplitterDrag() {
        workspaceReflowTask?.cancel()
        if !isWorkspaceReflowing { isWorkspaceReflowing = true }
    }

    private func endSplitterDrag() {
        workspaceReflowTask?.cancel()
        workspaceReflowTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            isWorkspaceReflowing = false
        }
    }

    private func instantly(_ change: () -> Void) {
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant, change)
    }

    /// Drag the library's right edge to resize it (240–480 pt). The floor is
    /// what the panel's own tab row needs; below it the header would clip.
    private var libraryResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .editorCursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        beginSplitterDrag()
                        let origin = libraryResizeOrigin ?? libraryPanelWidth
                        libraryResizeOrigin = origin
                        instantly { libraryPanelWidth = min(max(origin + value.translation.width, 240), 480) }
                    }
                    .onEnded { _ in libraryResizeOrigin = nil; endSplitterDrag() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                instantly { libraryPanelWidth = 280 }
            })
            .help(appLocalized("拖动调整宽度，双击恢复默认"))
            .offset(x: 4)
    }

    /// Drag the inspector's left edge to resize it.
    private var inspectorResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .editorCursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        beginSplitterDrag()
                        let origin = inspectorResizeOrigin ?? inspectorWidth
                        inspectorResizeOrigin = origin
                        instantly {
                            inspectorWidth = Double(EditorInspectorSizing.clampedContentWidth(
                                CGFloat(origin) - value.translation.width))
                        }
                    }
                    .onEnded { _ in inspectorResizeOrigin = nil; endSplitterDrag() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                instantly { inspectorWidth = Double(EditorInspectorSizing.defaultContentWidth) }
            })
            .help(appLocalized("拖动调整宽度，双击恢复默认"))
            .offset(x: -4)
    }

    private var resolvedInspectorWidth: CGFloat {
        EditorInspectorSizing.clampedContentWidth(CGFloat(inspectorWidth))
    }

    private func editorInspectorColumn() -> some View {
        GeometryReader { column in
            VStack(spacing: 0) {
                editorInspector(
                    contentWidth: resolvedInspectorWidth,
                    contentHeight: column.size.height
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .firstUseTourTarget("editor.inspector", in: .editor, highlight: .rounded(0))
            }
        }
        .frame(width: resolvedInspectorWidth)
        .environment(\.consolePalette, inspectorPalette)
        .background(EditorTheme.panelSurface)
        .clipped()
    }

    private var projectMenu: some View {
        EditorActionMenu(title: "项目", items: [
            .action("打开项目…") { hostActions.openProject() },
            .action("在 Finder 中显示项目包") { hostActions.revealProjectInFinder() },
            .separator,
            .action("导出项目源文件…", isEnabled: context.media.source != nil) { hostActions.exportProjectSourceMedia() },
            .action("替换这份录制的摄像头…", isEnabled: mediaSession.sourceID(at: playbackController.outputTime).flatMap { editorStore.project.source($0)?.media.camera } != nil) {
                if let sourceID = mediaSession.sourceID(at: playbackController.outputTime) { hostActions.importCameraReplacement(sourceID: sourceID) }
            },
            .separator,
            .action("键盘快捷键") { showsShortcutCheatsheet = true }
        ]) {
            AppLineIcon(kind: .chevronDown, size: 10)
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: 22, height: 28)
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
                    titleEditor
                    projectMenu
                }
                .frame(maxWidth: layout.value(regular: 420, compact: 260), alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                persistenceIndicator
                EditorToolbarDivider()
                Button { editorStore.prepareForUserUndoOrRedo(); undoManager?.undo() } label: {
                    EditorToolbarIconSurface(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(EditorToolbarPressButtonStyle())
                .disabled(isCropping || !canUndo)
                .help("撤销（⌘Z）").accessibilityLabel("撤销")
                Button { editorStore.prepareForUserUndoOrRedo(); undoManager?.redo() } label: {
                    EditorToolbarIconSurface(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(EditorToolbarPressButtonStyle())
                .disabled(isCropping || !canRedo)
                .help("重做（⌘⇧Z）").accessibilityLabel("重做")
                Spacer(minLength: 16)
                stylePresetControl()
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
                .firstUseTourTarget("editor.export", in: .editor, highlight: .rounded(8))
            }
            .padding(.leading, 78)
            .padding(.trailing, 12)
        }
        .frame(height: EditorChromeMetrics.titleBarHeight)
        .background(EditorTheme.chromeBar)
    }

    /// The canvas bar sits flush under the picture in three fixed groups:
    /// what is on the canvas (ratio, crop, add) on the left, transport in the
    /// centre, time and preview quality on the right. Cropping swaps only the
    /// left group, so the playhead stays reachable while framing. Previewing a
    /// bin file swaps all three: the one bar under the monitor always drives
    /// whatever the monitor is showing.
    private func canvasBar(width: CGFloat) -> some View {
        ZStack {
            if let previewing = assetMonitor.previewing, !isCropping {
                previewBar(previewing: previewing)
            } else {
                programmeBar
            }
        }
        .frame(width: width, height: EditorCanvasBarMetrics.height)
        .transaction(value: isCropping) { $0.animation = nil }
    }

    /// The same three groups, for the file in the monitor.
    private func previewBar(previewing: EditorAssetMonitor.Previewing) -> some View {
        ZStack {
            HStack(spacing: 2) {
                EditorAssetPreviewBarLeading(previewing: previewing)
                Spacer(minLength: 0)
            }
            EditorAssetPreviewBarCenter(playback: assetMonitor.playback)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                EditorAssetPreviewBarTrailing(playback: assetMonitor.playback) {
                    assetMonitor.returnToProgramme()
                }
            }
        }
    }

    @ViewBuilder
    private var programmeBar: some View {
        ZStack {
            HStack(spacing: 2) {
                previewControls
                if !isCropping {
                    EditorActionMenu(title: "添加到画面", items: [
                        .action("柔化或突出", systemImage: "camera.metering.spot") { addMosaicAtPlayhead() },
                        .action("导入贴图…", systemImage: "photo.badge.plus") { addStickerAtPlayhead() },
                        .action("粘贴图片", systemImage: "doc.on.clipboard", isEnabled: canPasteOverlayImage) { addPastedSticker() }
                    ]) {
                        EditorMonitorBarButtonSurface(accessibilityTitle: "添加到画面") {
                            HStack(spacing: 6) {
                                AppLineIcon(kind: .plus, size: 16)
                                Text("添加")
                            }
                        }
                    }
                    .disabled(mediaSession.outputDuration <= 0)
                }
                Spacer(minLength: 0)
            }
            transportButtons
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                transportTime
                if !isCropping {
                    EditorPreviewQualityToggle(mode: $previewResolutionMode)
                }
            }
        }
    }

    private var transportFrameDuration: TimeInterval {
        let sourceID = mediaSession.sourceID(at: playbackController.outputTime)
        return 1 / Double(max(editorStore.project.captureFrameRate(for: sourceID).rawValue, 1))
    }

    private func stepTransport(byFrames frames: Int) {
        let duration = max(mediaSession.outputDuration, 0)
        let target = min(max(playbackController.outputTime + Double(frames) * transportFrameDuration, 0), duration)
        playbackController.seek(to: target, pausing: true)
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            Button { stepTransport(byFrames: -1) } label: {
                EditorMonitorBarButtonSurface(accessibilityTitle: "上一帧", iconOnly: true) {
                    AppLineIcon(kind: .previousFrame, size: 16)
                }
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
            .help("上一帧（←；Shift+← 移动 5 帧）")
            .accessibilityLabel("上一帧")
            // The one solid control: an ink disc, the glyph in the panel tone.
            Button { playbackController.togglePlayback() } label: {
                AppLineIcon(kind: playbackController.isPlaying ? .pause : .play, size: 18)
                    .foregroundStyle(EditorTheme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(EditorTheme.platinumAccent, in: Circle())
            }
            .buttonStyle(EditorMonitorPlayButtonStyle())
            .disabled(!playbackController.canPlay)
            .help(appLocalized(playbackController.isPlaying ? "暂停（空格）" : "播放（空格）"))
            .accessibilityLabel(appLocalized(playbackController.isPlaying ? "暂停" : "播放"))
            Button { stepTransport(byFrames: 1) } label: {
                EditorMonitorBarButtonSurface(accessibilityTitle: "下一帧", iconOnly: true) {
                    AppLineIcon(kind: .nextFrame, size: 16)
                }
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
            .help("下一帧（→；Shift+→ 移动 5 帧）")
            .accessibilityLabel("下一帧")
        }
    }

    private var transportTime: some View {
        HStack(spacing: 4) {
            NativePlaybackTimeView(playbackController: playbackController)
                .frame(width: 70, height: 20)
            Text("/ " + Self.transportTimestamp(mediaSession.outputDuration))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(EditorTheme.tertiaryText)
                .fixedSize()
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
                .padding(.horizontal, 8).frame(height: 28)
                .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .background(EditorTextInputRegionAnchor(region: titleInputRegion))
                .overlay {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
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
                Text(projectDisplayTitle)
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.control))
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
        Task { @MainActor in
            guard let relativePath = await hostActions.importOverlayImage() else { return }
            addSticker(relativePath: relativePath)
        }
    }

    /// The one way a bin file reaches the timeline: it lands where the
    /// placement says — the playhead, a drop point on a layer, or the main
    /// track — and brings only the span its in and out marks enclose.
    private func place(_ placement: EditorMediaPlacement) {
        let asset = placement.asset
        guard ProjectFiles.exists(asset.path) else {
            hostActions.reportError(appLocalized("素材文件找不到了，请在素材箱里重新关联。"))
            return
        }
        let insertionTime = placement.time ?? overlayInsertionTime
        let range = placement.sourceRange
        // Only a file that can carry the programme joins the main track;
        // anything else dropped there goes on a layer of its own.
        if placement.lane == .mainTrack {
            guard asset.kind == .video || asset.kind == .image
                || (asset.kind == .animation && HTMLMotion.isHTMLMotion(asset.path)) else {
                place(EditorMediaPlacement(asset: asset, time: insertionTime, lane: .newLayer, sourceRange: range))
                return
            }
            playbackController.pause()
            let sources = mediaSession.sourceDurations
            Task { @MainActor in
                do {
                    try await editorStore.insertOnMainTrack(asset, at: insertionTime,
                                                            sourceDurations: sources, sourceRange: range)
                } catch {
                    hostActions.reportError(error.localizedDescription)
                }
            }
            return
        }
        playbackController.seek(to: insertionTime, pausing: true)
        let lane = placement.lane
        // Placing and moving onto the dropped-on track is one undo step.
        func settle() {
            guard lane != .newLayer else { return }
            commitTimelineEdit(editorStore, action: "放置素材") { editorStore.assign(editorStore.selection, to: lane, in: &$0) }
        }
        editorStore.beginUndoBatch()
        defer { if asset.kind != .video { settle(); editorStore.endUndoBatch(actionName: appLocalized("放置素材")) } }
        do {
            switch asset.kind {
            case .animation:
                _ = try editorStore.addAnimation(
                    sourcePath: asset.path, at: insertionTime,
                    outputDuration: mediaSession.outputDuration, sourceRange: range)
            case .audio:
                _ = try editorStore.addAudioClip(
                    sourcePath: asset.path, kind: .music, at: insertionTime,
                    outputDuration: mediaSession.outputDuration, sourceRange: range)
            case .image:
                guard let relativePath = hostActions.importOverlayImage(from: ProjectFiles.url(asset.path)) else { return }
                try commitSticker(relativePath: relativePath, insertionTime: insertionTime)
            case .video:
                let path = asset.path, duration = mediaSession.outputDuration
                Task { @MainActor in
                    do {
                        _ = try await editorStore.addVideoClip(sourcePath: path, at: insertionTime,
                                                               outputDuration: duration, sourceRange: range)
                        settle()
                    } catch {
                        hostActions.reportError(error.localizedDescription)
                    }
                    editorStore.endUndoBatch(actionName: appLocalized("放置素材"))
                }
            }
            timelineTrackVisibilityBinding.wrappedValue = timelineTrackVisibility.union(.overlays)
            previewCanvasFocused = true
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private func addPastedSticker() {
        guard !isCropping,
              mediaSession.outputDuration > 0,
              let relativePath = hostActions.pasteOverlayImage() else { return }
        addSticker(relativePath: relativePath, assetName: appLocalized("粘贴的图片"))
    }

    private func addSticker(
        relativePath: String,
        assetName: String? = nil,
        insertionTime: TimeInterval? = nil
    ) {
        do {
            try commitSticker(
                relativePath: relativePath,
                assetName: assetName,
                insertionTime: insertionTime
            )
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private func commitSticker(
        relativePath: String,
        assetName: String? = nil,
        insertionTime: TimeInterval? = nil
    ) throws {
        let insertionTime = insertionTime ?? overlayInsertionTime
        playbackController.seek(to: insertionTime, pausing: true)
        _ = try editorStore.addSticker(
            relativePath: relativePath,
            assetName: assetName,
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
        HStack(spacing: 4) {
            if cropPresentation.toolbarMode == .cropControls {
                EditorCropTransportControls(
                    canReset: cropDraftBinding.wrappedValue.clamped() != .full,
                    onReset: resetCrop,
                    onCancel: discardCrop,
                    onConfirm: confirmCrop
                )
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
                    EditorMonitorBarButtonSurface(accessibilityTitle: "裁切") {
                        HStack(spacing: 6) {
                            AppLineIcon(kind: .crop, size: 16)
                            Text("裁切")
                        }
                    }
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
                .accessibilityIdentifier("editor.crop.begin")
                .help("直接拖动八个控制点裁切素材；按 Esc 取消")
            }
        }
    }

    private func previewArea(transientAspect: CGFloat?) -> some View {
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
                transientAspectRatio: transientAspect,
                previewResolutionMode: $previewResolutionMode,
                isCropping: cropPresentation.canvasMode == .cropEditor,
                isSplitterResizing: isWorkspaceReflowing,
                cropDraft: cropDraftBinding,
                wallpaperURLResolver: context.wallpaperURL,
                projectAssetURLResolver: context.projectAssetURL,
                assetRootURL: hostActions.projectPackageURL(),
                onCanvasFocused: { previewCanvasFocused = true },
                onError: hostActions.reportError
            )
            .focusable(true)
            .focused($previewCanvasFocused)
            .focusEffectDisabled()
            .onPasteCommand(of: [.image, .fileURL]) { _ in
                addPastedSticker()
            }

            ZStack(alignment: .topTrailing) {
                previewPreparationOverlay
                    .padding(14)
            }
            .animation(SpringMotion.fade, value: previewStatusKey)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isPreviewUpdating) {
            isPreviewUpdateStatusRevealed = false
            guard isPreviewUpdating else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isPreviewUpdateStatusRevealed = true
        }
    }

    /// One value for the status card's single fade.
    private var previewStatusKey: String {
        "\(mediaSession.lifecycle)|\(playbackController.lifecycle)|\(isPreviewUpdateStatusRevealed)"
    }

    private var isPreviewUpdating: Bool {
        switch (mediaSession.lifecycle, playbackController.lifecycle) {
        case (_, .failed):
            false
        case (.preparing, _):
            mediaSession.prepared != nil
        case (.ready, .empty), (.ready, .preparing):
            playbackController.endpoints != nil || playbackController.pausedScreenImage != nil
        default:
            false
        }
    }

    @ViewBuilder
    private var previewPreparationOverlay: some View {
        if isPreviewUpdating && !isPreviewUpdateStatusRevealed {
            EmptyView()
        } else {
            previewPreparationStatus
        }
    }

    @ViewBuilder
    private var previewPreparationStatus: some View {
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
                detail: "",
                systemImage: nil,
                showsProgress: true,
                isBlocking: true
            )
        case (.preparing, _):
            previewStatusCard(
                title: mediaSession.prepared == nil ? "正在准备预览" : "正在更新预览",
                detail: "",
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
                title: playbackController.pausedScreenImage == nil ? "正在准备预览" : "正在准备声音",
                detail: "",
                systemImage: nil,
                showsProgress: true,
                isBlocking: playbackController.endpoints == nil && playbackController.pausedScreenImage == nil
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
        return HStack(alignment: detail.isEmpty ? .center : .top, spacing: 10) {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    AppLineIcon(kind: .warning, size: 14).foregroundStyle(RecorderStyle.amberInk)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(EditorTheme.primaryText)
                if !detail.isEmpty {
                    Text(appLocalized(detail))
                        .font(EditorTypography.helper)
                        .foregroundStyle(EditorTheme.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: isBlocking ? 320 : 260, alignment: .leading)
        .fixedSize(horizontal: detail.isEmpty, vertical: false)
        .modifier(EditorFloatingSurface())
        .transition(.opacity)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: isBlocking ? .center : .topTrailing
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.isEmpty
            ? String(format: appLocalized("预览状态 · %@"), appLocalized(title))
            : String(format: appLocalized("预览状态 · %@，%@"), appLocalized(title), appLocalized(detail)))
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

    /// Drag the line above the timeline to give the picture or the tracks
    /// more room; double-click returns to automatic sizing.
    private func timelineResizeHandle(current: CGFloat, maximum: CGFloat) -> some View {
        Color.clear
            .frame(height: 9)
            .contentShape(Rectangle())
            .editorCursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        beginSplitterDrag()
                        let origin = timelineResizeOrigin ?? current
                        timelineResizeOrigin = origin
                        instantly {
                            userTimelineHeight = Double(min(max(origin - value.translation.height, 150), maximum))
                        }
                    }
                    .onEnded { _ in timelineResizeOrigin = nil; endSplitterDrag() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                performWorkspaceReflow { userTimelineHeight = 0 }
            })
            .help(appLocalized("拖动调整时间线高度，双击恢复自动"))
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
        withAnimation(SpringMotion.standard, changes)
        workspaceReflowTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
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
            if event.keyCode == 36 || event.keyCode == 76, isCropping, !event.isARepeat,
               !((NSApplication.shared.keyWindow?.firstResponder as? NSTextView)?.isEditable ?? false) {
                confirmCrop()
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
            // Previewing a bin file borrows the monitor, and with it Space:
            // the key must drive the picture the viewer is looking at.
            if EditorAssetMonitor.shared.isPreviewing {
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                EditorAssetMonitor.shared.playback.toggle()
                return nil
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
        let durations = mediaSession.sourceDurations
        let map = try? EditorPrimaryTimelinePresentation.timelineMap(
            sourceDurations: durations,
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
            // ⇧/⌘-adding a clip keeps the primary segments already selected.
            let modifiers = NSEvent.modifierFlags
            if selection != nil, modifiers.contains(.shift) || modifiers.contains(.command) { return }
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
            selectedInspector: selectedInspectorBinding,
            isCameraSyncEditing: $isCameraSyncEditing,
            settingsPage: $inspectorSettingsPage,
            visibleTimelineTracks: timelineTrackVisibilityBinding,
            isCropping: cropPresentation.inspectorMode == .cropInspector,
            cropDraft: cropDraftBinding,
            cropSourceID: cropSourceID,
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
        EditorCanvasPill {
            AppLineIcon(kind: toast.isRedo ? .redo : .undo, size: 13)
            Text(appLocalized(toast.isRedo ? "重做" : "撤销"))
                .fontWeight(.semibold)
            if !toast.actionName.isEmpty {
                Text(appLocalized(toast.actionName))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
