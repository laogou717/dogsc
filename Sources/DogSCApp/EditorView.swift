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
            .foregroundStyle(foregroundColor)
            .frame(width: 28, height: 28)
            .background(
                isHovered && isEnabled ? Color.white.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foregroundColor: Color {
        if isActive {
            return editorAccent
        }
        return isEnabled ? Color.primary.opacity(0.85) : Color.secondary
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
    @State var savedStylePresets: [EditorStylePreset] = []
    @State var isNamingStylePreset = false
    @State var stylePresetName = ""
    @State private var spaceKeyMonitor: Any?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// Sync repair is an exceptional workflow, not a permanent editor lane.
    /// The camera inspector owns its disclosure while the timeline mirrors it.
    @State private var isCameraSyncEditing = false
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
        // 编辑器单一强调色：滑块、Toggle、分段控件与选中态同属一个紫色
        // 体系，不再与系统蓝混用；显式颜色（橙/红/青语义色）不受影响。
        .tint(editorAccent)
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
        .animation(.easeOut(duration: 0.16), value: hostActions.errorMessage)
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
            EditorInspectorRouting.tab(for: editorStore.selection)
        }
        nonmutating set {
            switch newValue {
            case .frame: editorStore.selection = .canvas
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

    /// 工具栏按"项目 ｜ 画布 ｜ 历史 ｜ 视图 ｜ 样式 ｜ 导出"分区，
    /// 每区一枚安静胶囊；文字不再裸排在条上。
    private func toolbarCapsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 3)
            .frame(height: 30)
            .background(
                Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    private var editorToolbar: some View {
        ZStack {
            titleEditor

            HStack(spacing: 10) {
                appLogo

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
                    Button {
                        showsShortcutCheatsheet = true
                    } label: {
                        Label("快捷键速查", systemImage: "keyboard")
                    }
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

                previewControls

                toolbarCapsule {
                    Button(action: addMosaicAtPlayhead) {
                        EditorToolbarIconSurface(systemName: "drop.halffull")
                    }
                    .buttonStyle(.plain)
                    .help("在播放头添加柔化或突出区域")

                    Button(action: addStickerAtPlayhead) {
                        EditorToolbarIconSurface(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .help("导入贴图（也可直接 ⌘V 粘贴）")

                    Button(action: addOrSelectProgressOverlay) {
                        EditorToolbarIconSurface(systemName: "chart.bar.fill")
                    }
                    .buttonStyle(.plain)
                    .help("添加或选中进度条")

                    Button(action: toggleFrameMotionBlur) {
                        Label("动态模糊", systemImage: "wind")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(
                                editorStore.project.motion.frameMotionBlur.isEnabled
                                    ? Color.black.opacity(0.88)
                                    : Color.primary.opacity(0.85)
                            )
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(
                                editorStore.project.motion.frameMotionBlur.isEnabled
                                    ? Color(white: 0.92)
                                    : Color.white.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(
                                        editorStore.project.motion.frameMotionBlur.isEnabled
                                            ? Color.white.opacity(0.68)
                                            : Color.white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .animation(
                        .easeOut(duration: 0.14),
                        value: editorStore.project.motion.frameMotionBlur.isEnabled
                    )
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
                }
                .disabled(isCropping || mediaSession.outputDuration <= 0)

                Spacer()

                persistenceIndicator

                toolbarCapsule {
                    Button { undoManager?.undo() } label: {
                        EditorToolbarIconSurface(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .disabled(isCropping || undoManager?.canUndo != true)
                    .help(undoManager?.undoActionName.isEmpty == false
                        ? "撤销“\(undoManager?.undoActionName ?? "")”（⌘Z）"
                        : "撤销（⌘Z）")

                    Button { undoManager?.redo() } label: {
                        EditorToolbarIconSurface(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(.plain)
                    .disabled(isCropping || undoManager?.canRedo != true)
                    .help(undoManager?.redoActionName.isEmpty == false
                        ? "重做“\(undoManager?.redoActionName ?? "")”（⌘⇧Z）"
                        : "重做（⌘⇧Z）")
                }

                toolbarCapsule {
                    previewResolutionMenu

                    Button {
                        isInspectorVisible.toggle()
                    } label: {
                        EditorToolbarIconSurface(
                            systemName: "sidebar.right",
                            isActive: isInspectorVisible
                        )
                    }
                    .buttonStyle(.plain)
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
                    stylePresetControl
                }
                .disabled(isCropping)
                .help(
                    savedStylePresets.isEmpty
                        ? "保存当前画布、摄像头、光标与运镜样式"
                        : "保存或复用自己的画布、摄像头、光标与运镜样式"
                )

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
        .frame(height: 46)
        .background(Color.white.opacity(0.028))
    }

    @ViewBuilder
    private var persistenceIndicator: some View {
        switch hostActions.persistenceStatus {
        case .clean:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .help("项目已自动保存")
                .accessibilityLabel("项目已自动保存")
                .accessibilityRemoveTraits(.isSelected)
        case .saving:
            ProgressView()
                .controlSize(.small)
                .help("正在保存项目")
        case let .failed(message):
            Button {
                hostActions.reportError("自动保存失败：\(message)")
            } label: {
                Label("保存失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("自动保存失败：\(message)；点击查看")
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭提示")
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

    /// 应用图标（顶部栏左上角）：固定使用打包的 AppIcon.icns；
    /// 资源缺失时退回系统图形，避免空槽。
    private var appLogo: some View {
        Group {
            if let icon = AppPreferences.bundledAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "record.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(editorAccent)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        .accessibilityHidden(true)
    }

    /// 居中项目名：点击进入编辑，回车或失焦提交，改名命令走撤销与自动保存。
    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            TextField("项目名称", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(width: 240)
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
                        Capsule()
                            .fill(Color.white.opacity(0.055))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private var overlayInsertionTime: TimeInterval {
        min(
            max(playbackController.outputTime, 0),
            max(mediaSession.outputDuration, 0)
        )
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
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    private var previewControls: some View {
        HStack(spacing: 2) {
            if cropPresentation.toolbarMode == .cropControls {
                Label("裁切模式", systemImage: "crop")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)

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
                    HStack(spacing: 6) {
                        Image(systemName: "aspectratio")
                        Text(editorStore.project.canvas.aspectRatio.rawValue)
                            .frame(minWidth: 38, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("editor.canvas.aspect-ratio")
                .accessibilityLabel("画布比例")
                .accessibilityValue(editorStore.project.canvas.aspectRatio.rawValue)

                Button { beginCrop() } label: {
                    Label("裁切", systemImage: "crop")
                        .padding(.horizontal, 7)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.editorGhost)
                    .accessibilityIdentifier("editor.crop.begin")
                    .help("直接拖动八个控制点裁切素材；按 Esc 取消")
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 30)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    /// 预览画质只影响本地预览流畅度，属于"视图"范畴：与检查器开关同区，
    /// 不再与写项目的画布比例/裁切混在同一胶囊里。
    private var previewResolutionMenu: some View {
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
            Text(previewResolutionMode == .full ? "画质·完整" : "画质·低清")
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
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
        .help("低清优先流畅；完整分辨率在播放与暂停时都保留素材细节")
    }

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.16)
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
        .animation(.easeOut(duration: 0.18), value: mediaSession.lifecycle)
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
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: isBlocking ? 300 : 260, alignment: .leading)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.94),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: isBlocking ? .center : .topTrailing
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var timeline: some View {
        EditorTimelineView(
            editorStore: editorStore,
            mediaSession: mediaSession,
            playbackController: playbackController,
            pointerEvents: context.media.pointerEvents,
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
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isInspectorResizeHandleHovered)
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
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isTimelineResizeHandleHovered)
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
