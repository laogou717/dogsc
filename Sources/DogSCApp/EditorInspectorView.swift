import AppKit
import Foundation
import RecorderCore
import SwiftUI

enum EditorMotionInspectorMode: String, CaseIterable, Identifiable {
    case zoom
    case screen3D

    var id: String { rawValue }
}

private enum EditorInspectorSelectionKind: Hashable {
    case canvas
    case screen
    case primarySegment
    case crop
    case zoomTrack
    case zoom
    case screenMotionTrack
    case screenMotion
    case cursor
    case camera
    case cameraMotion
    case audio
    case mosaic
    case sticker
    case animation
    case audioClip
    case subtitle
    case videoClip
}

private enum EditorInspectorScrollContext: Hashable {
    case crop
    case selection(EditorInspectorSelectionKind)
    case tab(InspectorTab)
    case frameTab(FrameInspectorTab)
}

/// Owns inspector navigation, controls, and interactive undo grouping. The
/// parent editor coordinates crop completion and provides system-facing work.
struct EditorInspectorView: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject private var timelinePreview: EditorTimelineInteractionState
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    @ObservedObject private var restingClock: EditorPlaybackRestingClock

    let cursorAssets: [ResolvedCursorAsset]
    @Binding var selectedInspector: InspectorTab
    @Binding var isCameraSyncEditing: Bool
    @Binding var visibleTimelineTracks: EditorTimelineTrackVisibility
    let isCropping: Bool
    @Binding var cropDraft: NormalizedCrop
    let cropSourceID: UUID?
    /// Parameter panel width. Tool navigation is owned by the workspace.
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    /// Direction of the last tool change on the rail, so pages arrive from it.
    var tabMovesDown = true
    let onChooseWallpaper: () async -> BackgroundSource?
    let onError: (String) -> Void

    @State var savedLayoutPresets: [SavedLayoutPreset] = []
    @State var isNamingLayoutPreset = false
    @State var layoutPresetName = ""
    @State var motionInspectorMode = EditorMotionInspectorMode.zoom
    @State var selectedFrameInspectorTab = FrameInspectorTab.background
    /// The settings page pushed from 全片设置; nil shows the overview.
    @Binding var settingsPage: EditorSettingsPage?
    @State private var scrollPositions = AppScrollPositionMemory<EditorInspectorScrollContext>()
    /// The page "forward" returns to after going back to 全片设置.
    @State private var forwardPage: EditorSettingsPage?
    @State private var swipeProgress: CGFloat?
    @ObservedObject private var systemWallpaperCatalog = SystemWallpaperCatalog.shared
    /// Set only while a frame sub-page change is being presented.

    init(
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        selectedInspector: Binding<InspectorTab>,
        isCameraSyncEditing: Binding<Bool>,
        settingsPage: Binding<EditorSettingsPage?>,
        visibleTimelineTracks: Binding<EditorTimelineTrackVisibility>,
        isCropping: Bool,
        cropDraft: Binding<NormalizedCrop>,
        cropSourceID: UUID? = nil,
        contentWidth: CGFloat = EditorInspectorSizing.defaultContentWidth,
        contentHeight: CGFloat = .infinity,
        tabMovesDown: Bool = true,
        onChooseWallpaper: @escaping () async -> BackgroundSource?,
        onError: @escaping (String) -> Void
    ) {
        _editorStore = ObservedObject(wrappedValue: editorStore)
        _timelinePreview = ObservedObject(wrappedValue: editorStore.timelinePreview)
        _mediaSession = ObservedObject(wrappedValue: mediaSession)
        _playbackController = ObservedObject(wrappedValue: playbackController)
        _restingClock = ObservedObject(wrappedValue: playbackController.restingClock)
        cursorAssets = CursorAssetLibrary.availableAssets
        _selectedInspector = selectedInspector
        _isCameraSyncEditing = isCameraSyncEditing
        _settingsPage = settingsPage
        _visibleTimelineTracks = visibleTimelineTracks
        self.isCropping = isCropping
        _cropDraft = cropDraft
        self.cropSourceID = cropSourceID
        self.contentWidth = EditorInspectorSizing.clampedContentWidth(contentWidth)
        self.contentHeight = contentHeight
        self.tabMovesDown = tabMovesDown
        self.onChooseWallpaper = onChooseWallpaper
        self.onError = onError
    }

    var playbackTime: TimeInterval { restingClock.time }

    var playheadSourcePosition: RecordingSourcePosition? {
        guard let map = try? TimelineMap(sourceSequence: editorStore.project.timeline.sourceSequence,
            sourceDurations: mediaSession.sourceDurations) else { return nil }
        return map.sourcePosition(atOutputTime: EditorPlaybackClockPolicy.frameLookupTime(playbackTime, duration: map.outputDuration))
    }
    var playheadSourceID: UUID? { playheadSourcePosition?.sourceID }
    var inspectedRecordingSourceID: UUID? {
        if case let .primarySegment(id) = editorStore.selection {
            switch editorStore.project.timeline.sourceSequence {
            case .fullRecording: return RecordingSource.primaryID
            case let .edited(segments):
                guard let segment = segments.first(where: { $0.id == id }), segment.media == nil else { return nil }
                return segment.resolvedSourceID
            }
        }
        return playheadSourceID
    }
    var inspectedInventories: EditorMediaInventories {
        inspectedRecordingSourceID.map { mediaSession.inventories(for: $0) } ?? .empty
    }
    var sourceInventory: MediaAssetInventory { inspectedInventories.source }
    var cameraInventory: MediaAssetInventory { inspectedInventories.camera }
    var microphoneInventory: MediaAssetInventory { inspectedInventories.microphone }
    var sourcePixelSize: CGSize {
        (isCropping ? cropSourceID : inspectedRecordingSourceID).flatMap { mediaSession.sourceDisplaySize(for: $0) } ?? mediaSession.primarySourceDisplaySize
    }
    var timelineDuration: TimeInterval { mediaSession.outputDuration }
    var sourceHasAudio: Bool { sourceInventory.hasAudio }
    var cameraHasVideo: Bool { cameraInventory.hasVideo }
    var microphoneHasAudio: Bool { microphoneInventory.hasAudio }
    /// Whole-video pages describe the programme, not the clip under the
    /// playhead: an inserted clip has no recording source, but the project
    /// still owns every camera, microphone and pointer track it recorded.
    var projectHasSystemAudio: Bool { mediaSession.hasSystemAudio }
    var projectHasMicrophoneAudio: Bool { mediaSession.hasMicrophoneAudio }
    var projectHasCameraVideo: Bool { mediaSession.hasCameraVideo }
    var projectHasPointerEvents: Bool {
        editorStore.project.sources.contains { $0.media.pointerEvents != nil }
    }

    /// A clip's own page is the clip, not whichever tool was last used: the
    /// rail tool only owns the panel once a settings page has been pushed
    /// under that clip (声音 then still scopes itself to the clip).
    private var primarySelectionKeepsInspectorTask: Bool {
        guard case .primarySegment = editorStore.selection, settingsPage != nil else { return false }
        return selectedInspector != .frame
    }

    private func header(for tab: InspectorTab) -> (title: String, scope: String?) {
        if tab == .audio,
           case let .primarySegment(id) = editorStore.selection,
           let context = primarySegmentContext(id: id) {
            return ("声音", String(format: appLocalized("第 %lld 段"), context.index + 1))
        }
        return switch tab {
        case .frame: ("画面", nil)
        case .opening: ("开场", "全片")
        case .zoom: ("运镜", "缩放")
        case .cursor: ("光标", sceneScopeLabel ?? "全片")
        case .camera: ("摄像头", sceneScopeLabel ?? "全片基础布局")
        case .audio: ("声音", "全片")
        }
    }

    /// Appearance edits land on one occurrence. The header must say so
    /// instead of claiming the whole programme.
    var sceneScopeLabel: String? {
        guard let id = sceneEditingCandidateID, let context = primarySegmentContext(id: id) else { return nil }
        return String(format: appLocalized("第 %lld 段"), Int64(context.index + 1))
    }

    /// The clip whose framing no longer follows its recording, for the pages
    /// a crop is visible on. Separate from the appearance scope: a clip can be
    /// framed on its own without carrying an appearance override.
    var segmentCropScopeID: UUID? {
        guard !isCropping, !isGroupSelection else { return nil }
        let candidate: UUID?
        if case let .primarySegment(selected) = editorStore.selection {
            candidate = selected
        } else {
            candidate = editorStore.previewProject.timeline.recordingSegment(atOutputTime: playbackTime)?.id
        }
        guard let candidate,
              editorStore.previewProject.timeline.recordingSegment(id: candidate)?.crop != nil else { return nil }
        if stackLevel == .settings, let page = settingsPage, page == .sound || page == .opening { return nil }
        if stackLevel == .object, selectedInspector == .audio || selectedInspector == .opening { return nil }
        return candidate
    }

    /// Which clip the appearance controls are routed to while the page
    /// itself still presents as whole-video.
    var sceneScopeContextSegmentID: UUID? {
        guard !isCropping, !isGroupSelection, let id = sceneEditingCandidateID else { return nil }
        switch stackLevel {
        case .overview:
            return id
        case .settings:
            guard let page = settingsPage, page != .sound, page != .opening else { return nil }
            return id
        case .object:
            guard case .primarySegment = editorStore.selection else { return nil }
            return id
        }
    }

    /// The clip the timeline has to mark. Only while the clip is edited
    /// *through* an appearance page: once it is the selection, the timeline's
    /// own selection ring already says which clip the controls are on.
    var sceneEditingMarkerTarget: UUID? {
        guard let id = sceneScopeContextSegmentID else { return nil }
        if case let .primarySegment(selected) = editorStore.selection, selected == id { return nil }
        return id
    }

    var selectedZoomID: UUID? {
        get {
            guard case let .zoom(id) = editorStore.selection else { return nil }
            return id
        }
        nonmutating set {
            editorStore.selection = newValue.map(EditorSelection.zoom) ?? .zoomTrack
        }
    }

    var body: some View {
        inspector
        .onChange(of: sceneEditingCandidateID, initial: true) { _, id in
            if editorStore.interaction == nil { editorStore.sceneEditingSegmentID = id }
        }
        .onChange(of: editorStore.interaction == nil) { _, finished in
            if finished { editorStore.sceneEditingSegmentID = sceneEditingCandidateID }
        }
        .onChange(of: sceneEditingMarkerTarget, initial: true) { _, id in
            editorStore.sceneEditingMarkerSegmentID = id
        }
        .onDisappear { editorStore.sceneEditingMarkerSegmentID = nil }
        .onChange(of: editorStore.selection) { previous, selection in
            // Selecting a whole-video object on the canvas or timeline (the
            // camera bubble, the zoom track…) opens its settings page.
            let page: EditorSettingsPage? = switch selection {
            case .screen: .layout
            case .camera: .camera
            case .cursor: .cursor
            case .audio: .sound
            case .zoomTrack, .screenMotionTrack: .motion
            default: nil
            }
            if let page, settingsPage != page {
                withAnimation(SpringMotion.panel) { settingsPage = page }
            }
            // Entering a clip shows what that clip has, not whichever page the
            // programme was left on. Hopping between clips keeps the page, so
            // tuning the same setting clip by clip stays one click each.
            if case .primarySegment = selection, settingsPage != nil {
                if case .primarySegment = previous {} else { closeSettingsPage() }
            }
            switch selection {
            case .screen:
                selectedFrameInspectorTab = .layout
            case .screenMotionTrack, .screenMotion:
                motionInspectorMode = .screen3D
            case .zoom, .zoomTrack:
                motionInspectorMode = .zoom
            default:
                break
            }
        }
    }

    /// The 画面 page's own controls show (as opposed to an object page).
    private var showsFrameInspectorNavigation: Bool {
        guard selectedInspector == .frame, !isCropping else { return false }
        switch editorStore.selection {
        case .canvas, .screen, nil:
            return true
        case .primarySegment:
            return stackLevel == .settings
        default:
            return false
        }
    }

    /// A short material browser keeps its fixed blur control while making
    /// room for the thumbnails. Other inspector tasks keep their spacing.
    var usesCompactBackgroundLayout: Bool {
        showsFrameInspectorNavigation && selectedFrameInspectorTab == .background
            && contentHeight < 340
    }

    /// Keep the selected clip's context visible without pushing its audio
    /// controls out of a short inspector. Other audio scopes keep their layout.
    var usesCompactSelectedAudioLayout: Bool {
        guard selectedInspector == .audio, !isCropping, contentHeight < 340,
              case .primarySegment = editorStore.selection else { return false }
        return true
    }

    private var usesCompactInspectorChrome: Bool {
        usesCompactBackgroundLayout || usesCompactSelectedAudioLayout
    }

    /// Which level of the stack is showing. Objects selected on the canvas or
    /// timeline always win; otherwise a pushed settings page, else the overview.
    var stackLevel: EditorInspectorStackLevel {
        if isCropping { return .object }
        if isGroupSelection { return .object }
        switch editorStore.selection {
        case .canvas, .screen, nil, .cursor, .camera, .audio, .zoomTrack, .screenMotionTrack:
            return settingsPage == nil ? .overview : .settings
        // A clip is a scope, not a leaf: its own page lists the same settings
        // rows, and opening one pushes that page scoped to this clip.
        case .primarySegment:
            return settingsPage == nil ? .object : .settings
        default:
            return .object
        }
    }

    var inspector: some View {
        VStack(spacing: 0) {
            // Header and page travel together as one page.
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    inspectorStackHeader
                    AppKeyboardFocusScrollView(
                        savedPosition: scrollPositions.position(for: inspectorScrollContext)
                    ) {
                        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
                            if let id = sceneScopeContextSegmentID { sceneScopeContext(id) }
                            else if let id = segmentCropScopeID { segmentCropScopeNote(id) }
                            if stackLevel == .overview {
                                EditorSettingsOverview(
                                    editorStore: editorStore,
                                    rows: overviewRows,
                                    open: openSettingsPage
                                )
                            } else if isGroupSelection {
                                EditorGroupInspector(editorStore: editorStore, items: editorStore.groupSelection)
                            } else {
                                inspectorContent
                            }
                        }
                        .padding(.horizontal, EditorInterfaceSpacing.inspectorInset)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                        .coordinateSpace(name: EditorConsole.scrollSpace)
                    }
                    .scrollIndicators(.hidden)
                }
                .id(stackPageID)
                .transition(.editorSubpage(edge: stackLevel == .overview ? .leading : .trailing))
            }
            .clipped()
            if showsBackgroundFooter {
                backgroundBlurSection
                    .padding(.horizontal, EditorInterfaceSpacing.inspectorInset)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: contentWidth)
        .background(Color.clear)
        .background(EditorInspectorNavigationGestures(
            canGoBack: stackLevel != .overview && !isCropping,
            canGoForward: stackLevel == .overview && forwardPage != nil,
            onBack: goBack, onForward: goForward, progress: $swipeProgress))
        .overlay { EditorInspectorSwipeIndicator(progress: swipeProgress) }
        .background {
            // ⌘[ goes back one level, ⌘] returns to the page it left. Both are
            // commands of the panel, not of whichever crumb is on screen.
            Button("", action: goBack).keyboardShortcut("[", modifiers: .command).hidden()
            Button("", action: goForward).keyboardShortcut("]", modifiers: .command).hidden()
        }
    }

    /// One identity per visible page: changing it swaps the page.
    private var stackPageID: String {
        "\(stackLevel)|\(settingsPage?.rawValue ?? "")|\(inspectorScrollContext)|\(isGroupSelection)"
    }

    /// EDT-079: a breadcrumb (全片设置 › 片段 › 元素, each level clickable),
    /// the name, and one line of context — time span or scope.
    private var inspectorStackHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            if stackLevel != .overview, !isCropping {
                HStack(spacing: 2) {
                    ForEach(Array(breadcrumbCrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            AppLineIcon(kind: .chevron, size: 10).foregroundStyle(EditorTheme.tertiaryText)
                        }
                        crumbView(crumb)
                    }
                }
                .frame(height: 20)
            }
            Text(appLocalized(stackTitle))
                .font(.appUI(size: 19, weight: .semibold))
                .foregroundStyle(EditorTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle = stackSubtitle {
                Text(appLocalized(subtitle))
                    .font(.appUI(size: 12.5))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, EditorInterfaceSpacing.inspectorInset)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorTheme.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inspectorTitle)
    }

    /// One level of the breadcrumb. No action means it is the page you are on.
    private struct InspectorCrumb {
        let title: String
        var action: (() -> Void)?
        var help: String?
        var identifier: String?
    }

    /// The trail to the page on screen. A segment's page is not a child of
    /// 全片设置 — it *is* that segment, with the same settings rows on it — so
    /// its trail starts at itself: 「片段 · 第 N 段」, then the page opened from
    /// it. Everything else still hangs under 全片设置.
    private var breadcrumbCrumbs: [InspectorCrumb] {
        if case let .primarySegment(id) = editorStore.selection, !isGroupSelection {
            let label = primarySegmentContext(id: id)
                .map { String(format: appLocalized("片段 · 第 %lld 段"), Int64($0.index + 1)) }
                ?? appLocalized("片段")
            let editsElement = MotionElementEditor.shared.target != nil
                && !MotionElementEditor.shared.selected.isEmpty
            guard settingsPage != nil || editsElement else { return [InspectorCrumb(title: label)] }
            return [
                InspectorCrumb(title: label,
                               action: { MotionElementEditor.shared.selected = []; closeSettingsPage() },
                               help: "返回这一段（⌘[）", identifier: "editor.segment.back"),
                InspectorCrumb(title: breadcrumbLeaf),
            ]
        }
        var crumbs = [InspectorCrumb(title: "全片设置", action: { goToOverview() },
                                     help: "返回全片设置（⌘[）", identifier: "editor.settings.back")]
        if let parent = breadcrumbParent {
            crumbs.append(InspectorCrumb(title: parent.title, action: parent.action))
        }
        crumbs.append(InspectorCrumb(title: breadcrumbLeaf))
        return crumbs
    }

    @ViewBuilder
    private func crumbView(_ crumb: InspectorCrumb) -> some View {
        if let action = crumb.action, let help = crumb.help {
            crumbButton(crumb.title, isCurrent: false, action: action)
                .help(appLocalized(help))
                .accessibilityIdentifier(crumb.identifier ?? "")
        } else if let action = crumb.action {
            crumbButton(crumb.title, isCurrent: false, action: action)
        } else {
            Text(appLocalized(crumb.title))
                .font(.appUI(size: 12.5))
                .foregroundStyle(EditorTheme.tertiaryText)
                .lineLimit(1)
        }
    }

    private func crumbButton(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(appLocalized(title))
                .font(.appUI(size: 12.5))
                .foregroundStyle(isCurrent ? EditorTheme.tertiaryText : EditorTheme.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 5))
        .padding(.leading, -4)
    }

    /// The middle crumb: the clip an element belongs to, or the settings
    /// page a clip belongs to (运镜 for zooms and 3D moves).
    private var breadcrumbParent: (title: String, action: () -> Void)? {
        if MotionElementEditor.shared.target != nil, !MotionElementEditor.shared.selected.isEmpty {
            let clip = editorStore.selection
            return (inspectorHeader.title, { [editorStore] in
                MotionElementEditor.shared.selected = []
                editorStore.selection = clip
            })
        }
        switch editorStore.selection {
        case .zoom, .screenMotion:
            return ("运镜", { openSettingsPage(.motion) })
        case .cameraMotion:
            return ("摄像头", { openSettingsPage(.camera) })
        default:
            return nil
        }
    }

    private var breadcrumbLeaf: String {
        if isGroupSelection { return stackTitle }
        if MotionElementEditor.shared.target != nil, let id = MotionElementEditor.shared.selected.first {
            return MotionElementEditor.shared.elements.first { $0.id == id }?.name ?? "元素"
        }
        return stackLevel == .settings ? (settingsPage?.title ?? inspectorHeader.title) : inspectorHeader.title
    }

    private var isGroupSelection: Bool { editorStore.groupSelection.count >= 2 }

    private var stackTitle: String {
        if isGroupSelection {
            return EditorGroupInspector.title(for: editorStore.groupSelection, timeline: editorStore.previewProject.timeline)
        }
        switch stackLevel {
        case .overview: return "全片设置"
        case .settings: return settingsPage?.title ?? inspectorHeader.title
        case .object: return inspectorHeader.title
        }
    }

    private var stackSubtitle: String? {
        if isGroupSelection { return "值不同的显示 —" }
        switch stackLevel {
        case .overview:
            guard let label = sceneScopeLabel else { return "作用于整段视频" }
            return String(format: appLocalized("画面外观只作用于%@"), label)
        case .settings:
            guard sceneScopeContextSegmentID != nil, let label = sceneScopeLabel else { return nil }
            return String(format: appLocalized("只作用于%@"), label)
        case .object: return inspectorHeader.scope.flatMap { $0 == "全片" ? nil : $0 }
        }
    }

    func openSettingsPage(_ page: EditorSettingsPage) {
        withAnimation(SpringMotion.panel) {
            settingsPage = page
            if let frame = page.frameTab { selectedFrameInspectorTab = frame }
            if page == .motion { motionInspectorMode = .zoom }
            selectedInspector = page.tab
        }
    }

    func goToOverview() {
        // Remember where we were so "forward" can come back to it.
        if stackLevel != .overview {
            forwardPage = settingsPage ?? EditorSettingsPage.page(for: selectedInspector, frame: selectedFrameInspectorTab)
        }
        withAnimation(SpringMotion.panel) {
            settingsPage = nil
            if editorStore.selection != .canvas { editorStore.selection = .canvas }
        }
    }

    /// Leaves a clip's settings page without leaving the clip.
    func closeSettingsPage() {
        withAnimation(SpringMotion.panel) { settingsPage = nil }
    }

    /// Back: a clip's page returns to that clip, everything else to 全片设置.
    func goBack() {
        guard stackLevel != .overview, !isCropping else { return }
        if case .primarySegment = editorStore.selection, settingsPage != nil {
            closeSettingsPage()
            return
        }
        goToOverview()
    }

    /// Forward: from 全片设置 to the page that was last left.
    func goForward() {
        guard stackLevel == .overview, let page = forwardPage else { return }
        forwardPage = nil
        openSettingsPage(page)
    }

    private var showsBackgroundFooter: Bool {
        stackLevel == .settings && settingsPage == .background
            && editorStore.sceneEditingPreviewProject.canvas.backgroundSource.usesWallpaperMedia
    }

    var inspectorHeader: (title: String, scope: String?) {
        if isCropping {
            let name = cropSourceID.map { RecordingSourcePresentation.name($0, in: editorStore.project) } ?? ""
            return (String(format: appLocalized("裁切 · %@"), name), nil)
        }
        if primarySelectionKeepsInspectorTask {
            return header(for: selectedInspector)
        }
        if selectedInspector == .opening,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return ("开场", "全片")
        }
        switch editorStore.selection {
        case .canvas:
            return ("画面", sceneScopeLabel ?? "全片")
        case .screen:
            return ("屏幕", sceneScopeLabel ?? "全片")
        case let .primarySegment(id):
            if let context = primarySegmentContext(id: id), context.segment.media == nil,
               let map = mediaSession.mediaPlan?.timelineMap {
                return (RecordingSourcePresentation.segmentName(context.segment, in: editorStore.project, segments: map.segments),
                    "\(segmentTimestamp(context.segment.outputStart)) – \(segmentTimestamp(context.segment.outputEnd)) · \(segmentTimestamp(context.segment.outputDuration))")
            }
            return ("片段", "当前片段")
        case .zoomTrack:
            return ("运镜", "缩放")
        case .zoom:
            return ("运镜", "缩放片段")
        case .screenMotionTrack:
            return ("运镜", "屏幕 3D")
        case .screenMotion:
            return ("运镜", "屏幕 3D 片段")
        case .cursor:
            return ("光标", sceneScopeLabel ?? "全片")
        case .camera:
            return ("摄像头", sceneScopeLabel ?? "全片")
        case .cameraMotion:
            return ("摄像头", "运动片段")
        case .audio:
            return ("声音", "全片")
        case .crop:
            return ("裁切", "屏幕素材")
        case let .mosaic(id):
            let style = editorStore.previewProject.timeline.mosaicClips.first(where: { $0.id == id })?.style
            return (style.map { $0 == .spotlight ? "突出" : "柔化" } ?? "区域效果", "选中区域")
        case .sticker:
            return ("贴图", "选中图片")
        case .animation:
            return ("动效", "选中动效")
        case .audioClip:
            return ("音乐与音效", "选中片段")
        case .subtitle:
            return ("字幕", "当前字幕")
        case .videoClip:
            return ("视频", "选中视频")
        case nil:
            return (selectedInspector.localizedLabel, nil)
        }
    }

    var inspectorTitle: String {
        guard let scope = inspectorHeader.scope else {
            return appLocalized(inspectorHeader.title)
        }
        return "\(appLocalized(inspectorHeader.title)) · \(appLocalized(scope))"
    }

    private var inspectorScrollContext: EditorInspectorScrollContext {
        if isCropping { return .crop }
        if primarySelectionKeepsInspectorTask {
            return .tab(selectedInspector)
        }
        if selectedInspector == .opening,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return .tab(selectedInspector)
        }
        guard let selection = editorStore.selection else {
            return selectedInspector == .frame
                ? .frameTab(selectedFrameInspectorTab)
                : .tab(selectedInspector)
        }
        if selectedInspector == .frame,
           selection == .canvas || selection == .screen || stackLevel == .settings {
            return .frameTab(selectedFrameInspectorTab)
        }
        let kind: EditorInspectorSelectionKind = switch selection {
        case .canvas: .canvas
        case .screen: .screen
        case .primarySegment: .primarySegment
        case .crop: .crop
        case .zoomTrack: .zoomTrack
        case .zoom: .zoom
        case .screenMotionTrack: .screenMotionTrack
        case .screenMotion: .screenMotion
        case .cursor: .cursor
        case .camera: .camera
        case .cameraMotion: .cameraMotion
        case .audio: .audio
        case .mosaic: .mosaic
        case .sticker: .sticker
        case .animation: .animation
        case .audioClip: .audioClip
        case .subtitle: .subtitle
        case .videoClip: .videoClip
        }
        return .selection(kind)
    }

    @ViewBuilder
    var inspectorContent: some View {
        if isCropping {
            cropInspector
        } else if case .mosaic = editorStore.selection {
            overlayInspector
        } else if case .sticker = editorStore.selection {
            overlayInspector
        } else if case let .animation(id) = editorStore.selection {
            EditorAnimationInspector(editorStore: editorStore, clipID: id)
        } else if case let .audioClip(id) = editorStore.selection {
            EditorAudioClipInspector(editorStore: editorStore, clipID: id)
        } else if case let .subtitle(id) = editorStore.selection {
            EditorSubtitleInspector(editorStore: editorStore, selectedID: id)
        } else if case let .videoClip(id) = editorStore.selection {
            EditorVideoClipInspector(editorStore: editorStore, clipID: id)
        } else if case let .primarySegment(id) = editorStore.selection,
                  stackLevel == .object {
            // 选中主片段给真正的片段面板：此前标题写着"当前片段"，内容却是
            // 全片初始状态控件，名实不符。这一层现在也列出这一段的外观入口，
            // 改某一段不必再绕去点画布空白。
            primarySegmentInspector(id: id)
        } else {
            switch selectedInspector {
        case .frame:
            frameInspector
        case .opening:
            openingInspector
        case .zoom:
            motionInspector
        case .cursor:
            cursorInspector
        case .camera:
            cameraInspector
        case .audio:
            audioInspector
            }
        }
    }

    /// Background media, layout/appearance and mockups are the three frame
    /// tasks. Canvas ratio and crop entry belong to the monitor toolbar.
    @ViewBuilder
    var frameInspector: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            if !usesCompactBackgroundLayout {
                let canvasSourceSize = mediaSession.canvasSourceSize(for: editorStore.previewProject)
                EditorFramePreview(
                    canvas: screenAppearanceCanvas,
                    screenImage: playbackController.pausedScreenImage,
                    usesFrameStyle: inspectorUsesFrameStyle,
                    isMainTrackImage: sceneEditingCandidateID.flatMap {
                        editorStore.previewProject.timeline.recordingSegment(id: $0)?.media?.imagePath
                    } != nil,
                    wallpaper: currentWallpaperAsset,
                    sourceAspectRatio: Double(sourcePixelSize.width / max(sourcePixelSize.height, 1)),
                    canvasAspectRatio: screenAppearanceCanvas.resolvedFixedAspectRatio
                        ?? Double(canvasSourceSize.width / max(canvasSourceSize.height, 1))
                )
            }
            switch selectedFrameInspectorTab {
            case .background:
                VStack(alignment: .leading, spacing: 14) {
                    EditorBackgroundInspector(
                        editorStore: editorStore,
                        systemWallpaperCatalog: systemWallpaperCatalog,
                        onChooseWallpaper: onChooseWallpaper,
                        onError: onError,
                        usesCompactLayout: usesCompactBackgroundLayout
                    )
                    if !showsFrameInspectorNavigation { backgroundBlurSection }
                }
            case .layout:
                VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
                    screenSurfaceAppearanceSection
                    screenMaterialLayoutSection
                }
            case .mockup:
                screenMockupSection
            }
        }
    }

    /// The system wallpaper the canvas currently uses, so the preview above
    /// the controls shows the same picture the frame is sitting on.
    private var currentWallpaperAsset: SystemWallpaperAsset? {
        let path: String
        switch editorStore.sceneEditingPreviewProject.canvas.backgroundSource {
        case let .systemImage(absolutePath), let .systemVideo(absolutePath): path = absolutePath
        default: return nil
        }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return systemWallpaperCatalog.assets.first {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path == normalized
        }
    }

    /// Project-wide choreography is a distinct authoring task. Keeping it in
    /// its own rail destination makes the Canvas page begin with the visual
    /// background controls while preserving the same opening data and renderer.
    var openingInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            openingSequenceSection
        }
    }

    var openingSequenceSection: some View {
        let sequence = editorStore.previewProject.openingSequence
        // Same rule the renderer uses: the roster belongs to the recording the
        // programme opens on, not to any camera anywhere in the project.
        let hasOpeningCamera = editorStore.previewProject.openingDeclaresCamera
            && !editorStore.sceneEditingPreviewProject.camera.isHidden
        let hasOpeningSticker = editorStore.previewProject.timeline.stickerClips.contains {
            $0.timing.startTime <= 0.000_1 && $0.timing.endTime > 0.000_1
        }
        let availableElements = sequence.availableElements(
            hasCamera: hasOpeningCamera, hasOpeningSticker: hasOpeningSticker
        )
        let participants = sequence.participatingElements(
            hasCamera: hasOpeningCamera, hasOpeningSticker: hasOpeningSticker
        )
        return EditorInspectorSection("全局开场", icon: "sparkles.rectangle.stack", showsTitle: false) {
            EditorOpeningStage(
                sequence: sequence,
                screenImage: playbackController.pausedScreenImage,
                elements: availableElements,
                isPaused: playbackController.isPlaying,
                height: 172
            )

            EditorToggle(
                isOn: openingBinding(
                    \.isEnabled,
                    actionName: sequence.isEnabled ? "关闭全局开场" : "启用全局开场"
                ),
                title: "启用开场"
            )
            .frame(minHeight: EditorPropertyRowMetrics.height)

            if sequence.isEnabled {
                VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("方式")
                        .font(EditorTypography.controlLabel)
                        .foregroundStyle(EditorTheme.primaryText)
                    EditorTileSelector(
                        options: OpeningSequencePreset.allCases,
                        title: { appLocalized($0.rawValue) },
                        icon: openingPresetIcon,
                        selection: openingBinding(\.preset, actionName: "更换开场方式"),
                        columnCount: 3
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("节奏")
                        .font(EditorTypography.controlLabel)
                        .foregroundStyle(EditorTheme.primaryText)
                    EditorTileSelector(
                        options: ElementMotionCurve.allCases,
                        title: { $0.editorTitle },
                        icon: { $0.editorSymbol },
                        selection: openingBinding(
                            \.motionCurve,
                            actionName: "调整开场节奏"
                        ),
                        columnCount: 3
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("时序")
                        .font(EditorTypography.controlLabel)
                        .foregroundStyle(EditorTheme.primaryText)
                    EditorOpeningTimeline(
                        editorStore: editorStore,
                        sequence: sequence,
                        elements: participants,
                        stagger: openingBinding(\.stagger, actionName: "调整开场元素间隔"),
                        duration: openingBinding(\.duration, actionName: "调整开场总时长"),
                        title: { $0.rawValue },
                        icon: openingElementIcon,
                        onError: onError
                    )
                }

                EditorDisclosure(
                    "数值"
                ) {
                    VStack(spacing: 6) {
                        sliderRow(
                            "总时长",
                            value: openingBinding(\.duration, actionName: "调整开场总时长"),
                            range: 0.4...8,
                            interactionScope: .project,
                            format: .seconds
                        )
                        if participants.count > 1 {
                            sliderRow(
                                "元素间隔",
                                value: openingBinding(\.stagger, actionName: "调整开场元素间隔"),
                                range: 0...sequence.maximumStagger(
                                    for: sequence.includedElements.count
                                ),
                                interactionScope: .project,
                                format: .seconds
                            )
                        } else if participants.isEmpty {
                            Text("无参与元素")
                                .font(EditorTypography.helper)
                                .foregroundStyle(EditorTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                EditorDisclosure(
                    "元素与顺序",
                    icon: "list.number"
                ) {
                    VStack(spacing: 7) {
                        ForEach(sequence.elementOrder, id: \.self) { element in
                            openingElementRow(
                                element,
                                order: sequence.elementOrder
                            )
                        }
                    }
                    .padding(.top, 10)
                }

                Button {
                    playbackController.seek(
                        to: 0,
                        pausing: true,
                        resumeAfterCompletion: true
                    )
                } label: {
                    EditorSymbolLabel("预览开场", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))

                }
                .transition(.editorSwap(edge: .top))
            }
        }
        .animation(SpringMotion.settle, value: editorStore.previewProject.openingSequence.isEnabled)
    }

    func openingElementRow(
        _ element: OpeningSequenceElement,
        order: [OpeningSequenceElement]
    ) -> some View {
        let index = order.firstIndex(of: element) ?? 0
        return HStack(spacing: 7) {
            Text("\(index + 1)")
                .font(.appUI(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(EditorTheme.chrome(0.45))
                .frame(width: 18, height: 18)
                .background(EditorTheme.chrome(0.055), in: Circle())
            EditorSymbolLabel(appLocalized(element.rawValue), systemImage: openingElementIcon(element))
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.78))
            Spacer(minLength: 4)
            Button {
                moveOpeningElement(element, offset: -1)
            } label: {
                EditorSymbol("chevron.up", size: 14)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.editorInlineAction)
            .disabled(index == 0)
            .help("提前进入")
            Button {
                moveOpeningElement(element, offset: 1)
            } label: {
                EditorSymbol("chevron.down", size: 14)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.editorInlineAction)
            .disabled(index >= order.count - 1)
            .help("延后进入")
            EditorToggle(isOn: openingElementBinding(element))
        }
        .padding(.vertical, 2)
    }

    func openingPresetIcon(_ preset: OpeningSequencePreset) -> String {
        switch preset {
        case .converge: "arrow.down.right.and.arrow.up.left"
        case .sideSlide: "arrow.left.and.right"
        case .light3D: "cube.transparent"
        }
    }

    func openingElementIcon(_ element: OpeningSequenceElement) -> String {
        switch element {
        case .screen: "rectangle.on.rectangle"
        case .camera: "video.fill"
        case .stickers: "photo.on.rectangle.angled"
        }
    }

    func openingBinding<Value>(
        _ keyPath: WritableKeyPath<OpeningSequence, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorOpeningBinding(
            store: editorStore,
            keyPath: keyPath,
            actionName: actionName,
            onError: onError
        )
    }

    func openingElementBinding(_ element: OpeningSequenceElement) -> Binding<Bool> {
        Binding(
            get: {
                editorStore.previewProject.openingSequence.includedElements.contains(element)
            },
            set: { included in
                updateOpeningSequence(
                    actionName: included ? "加入开场元素" : "移出开场元素"
                ) { sequence in
                    sequence.includedElements.removeAll { $0 == element }
                    if included { sequence.includedElements.append(element) }
                }
            }
        )
    }

    func moveOpeningElement(_ element: OpeningSequenceElement, offset: Int) {
        updateOpeningSequence(actionName: "调整开场顺序") { sequence in
            guard let source = sequence.elementOrder.firstIndex(of: element) else { return }
            let destination = min(max(source + offset, 0), sequence.elementOrder.count - 1)
            guard destination != source else { return }
            sequence.elementOrder.remove(at: source)
            sequence.elementOrder.insert(element, at: destination)
        }
    }

    func updateOpeningSequence(
        actionName: String,
        _ update: (inout OpeningSequence) -> Void
    ) {
        var project = editorStore.project
        update(&project.openingSequence)
        project.openingSequence.normalizeTiming()
        do {
            try editorStore.replaceProject(with: project, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
        }
    }

    var inspectorUsesFrameStyle: Bool {
        guard let id = sceneEditingCandidateID else { return true }
        return editorStore.previewProject.timeline.recordingSegment(id: id)?.media?.usesFrameStyle ?? true
    }

    var screenMaterialLayoutSection: some View {
        EditorInspectorSection("位置与大小") {
            EditorTransactionalPositionPad(
                editorStore: editorStore,
                title: "素材位置",
                point: canvasBinding(\.contentPosition, actionName: "移动屏幕素材"),
                commandScope: .canvas,
                actionName: "移动屏幕素材",
                compactLayout: false,
                onError: onError
            )
            sliderRow("素材缩放", value: canvasBinding(\.contentScale, actionName: "缩放屏幕素材"),
                      range: 0.25...4, format: .multiplier)
            HStack {
                Spacer(minLength: 8)
                Button("恢复位置与大小") {
                    var canvas = editorStore.sceneEditingProject.canvas
                    canvas.contentScale = 1
                    canvas.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
                    performEditorCommand {
                        try editorStore.replaceCanvas(with: canvas, actionName: "居中屏幕素材")
                    }
                }
                .font(.appUI(size: 11))
                .buttonStyle(.editorGhost)
            }
        }
    }

    /// Padding, corner, stroke and shadow are one family of "how the screen
    /// sits on the canvas": four knobs on one row.
    var screenAppearanceTarget: ScreenAppearanceTarget {
        if let id = sceneEditingCandidateID { return .segment(id) }
        if case let .primarySegment(id) = editorStore.selection,
           let context = primarySegmentContext(id: id) {
            return context.segment.media == nil ? .recording(context.segment.sourceID) : .insertedSegment(id)
        }
        if let map = try? TimelineMap(sourceSequence: editorStore.previewProject.timeline.sourceSequence,
                                      sourceDurations: mediaSession.sourceDurations),
           let segment = map.segment(atOutputTime: EditorPlaybackClockPolicy.frameLookupTime(playbackTime, duration: map.outputDuration)) {
            return segment.media == nil ? .recording(segment.sourceID) : .insertedSegment(segment.id)
        }
        return .recording(RecordingSource.primaryID)
    }

    var screenAppearanceCanvas: CanvasStyle {
        editorStore.previewProject.screenCanvas(for: screenAppearanceTarget)
    }

    private func screenAppearanceBinding<Value>(
        _ keyPath: WritableKeyPath<CanvasStyle, Value>, actionName: String
    ) -> Binding<Value> {
        editorScreenAppearanceBinding(store: editorStore, target: screenAppearanceTarget,
            keyPath: keyPath, actionName: actionName, onError: onError)
    }

    var screenSurfaceAppearanceSection: some View {
        let canvas = screenAppearanceCanvas
        return EditorInspectorSection("画面与外观") {
            EditorKnobRow {
                knob(
                    "画布边距", label: "边距",
                    value: canvasBinding(\.padding, actionName: "调整画布边距"),
                    range: 0...360, format: .points
                )
                if canvas.screenFrame == .none {
                    knob(
                        "画面圆角", label: "圆角",
                        value: screenAppearanceBinding(\.cornerRadius, actionName: "调整画面圆角"),
                        range: 0...160, interactionScope: .project, format: .points
                    )
                } else {
                    knob(
                        "内容圆角", label: "圆角",
                        value: screenFrameRadiusBinding(
                            \.screenFrameContentCornerRadius,
                            fallback: canvas.screenFrame.defaultContentCornerRadius,
                            actionName: "调整样机内容圆角"
                        ),
                        range: 0...160, interactionScope: .project, format: .points
                    )
                }
                knob(
                    "外描边", label: "描边",
                    value: screenAppearanceBinding(\.borderWidth, actionName: "调整屏幕描边"),
                    range: 0...40, interactionScope: .project, format: .points
                )
                knob(
                    "阴影强度", label: "阴影",
                    value: screenAppearanceBinding(\.shadowStrength, actionName: "调整屏幕阴影"),
                    range: 0...1, interactionScope: .project, format: .percent
                )
            }
            if canvas.borderWidth > 0 {
                EditorTransactionalColorInput(
                    editorStore: editorStore,
                    title: "描边颜色",
                    value: screenAppearanceBinding(
                        \.borderColor,
                        actionName: "调整描边颜色"
                    ),
                    commandScope: .project,
                    actionName: "调整描边颜色",
                    onError: onError
                )
                sliderRow(
                    "描边不透明度",
                    value: screenAppearanceBinding(\.insetOpacity, actionName: "调整描边不透明度"),
                    range: 0...1,
                    interactionScope: .project,
                    format: .percent
                )
            }
        }
    }

    var screenMockupSection: some View {
        VStack(alignment: .leading, spacing: 14) {

            EditorInspectorSection("样机", showsTitle: false) {
                EditorScreenFramePicker(editorStore: editorStore,
                                        target: screenAppearanceTarget,
                                        screenImage: playbackController.pausedScreenImage,
                                        onError: onError)
                    .id(screenAppearanceTarget)

                if screenAppearanceCanvas.screenFrame != .none {
                    EditorKnobRow {
                        knob(
                            "框体比例",
                            value: screenAppearanceBinding(\.screenFrameScale, actionName: "调整屏幕样机大小"),
                            range: 0.6...1.6, interactionScope: .project, format: .multiplier
                        )
                        if screenAppearanceCanvas.screenFrame.isWindowFrame
                            || screenAppearanceCanvas.screenFrame.isBrowserFrame {
                            knob(
                                "顶栏高度",
                                value: screenAppearanceBinding(\.screenFrameToolbarScale, actionName: "调整样机顶栏高度"),
                                range: 0.65...1.6, interactionScope: .project, format: .multiplier
                            )
                        }
                        knob(
                            "框体外圆角", label: "外圆角",
                            value: screenFrameRadiusBinding(
                                \.screenFrameOuterCornerRadius,
                                fallback: screenAppearanceCanvas.screenFrame
                                    .defaultOuterCornerRadius,
                                actionName: "调整样机外圆角"
                            ),
                            range: 0...160, interactionScope: .project, format: .points
                        )
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func screenFrameRadiusBinding(
        _ keyPath: WritableKeyPath<CanvasStyle, Double?>,
        fallback: Double,
        actionName: String
    ) -> Binding<Double> {
        let optionalBinding = screenAppearanceBinding(keyPath, actionName: actionName)
        return Binding(
            get: { optionalBinding.wrappedValue ?? fallback },
            set: { optionalBinding.wrappedValue = $0 }
        )
    }

    var cropInspector: some View {
        EditorCropInspector(cropDraft: $cropDraft, sourcePixelSize: sourcePixelSize, scope: cropScope)
    }

    private var cropScope: EditorCropInspector.Scope? {
        let scope = EditorCropScope.shared
        guard scope.offersChoice, let id = scope.segmentID,
              let context = primarySegmentContext(id: id) else { return nil }
        return EditorCropInspector.Scope(
            segmentLabel: String(format: appLocalized("第 %lld 段"), Int64(context.index + 1)),
            onChange: { [editorStore, cropSourceID] segmentOnly in
                scope.setSegmentOnly(segmentOnly, in: editorStore, sourceID: cropSourceID)
            }
        )
    }

    // MARK: - Primary segment panel

    struct PrimarySegmentPanelContext {
        let segment: ResolvedRecordingSegment
        let index: Int
        let total: Int
        let junctionBefore: EditorTimelineSegmentJunction?
        let junctionAfter: EditorTimelineSegmentJunction?
        let leadingGap: EditorTimelineLeadingGap?
        let trailingGap: EditorTimelineTrailingGap?
        let sourceDurations: [UUID: TimeInterval]
        let frameDuration: TimeInterval
    }

    func insertedMotionPath(_ id: UUID) -> String? {
        guard case let .edited(segments) = editorStore.project.timeline.sourceSequence else { return nil }
        return segments.first { $0.id == id }?.media?.motionPath
    }

    func insertedUsesFrameStyle(_ id: UUID) -> Bool {
        guard case let .edited(segments) = editorStore.project.timeline.sourceSequence else { return false }
        return segments.first { $0.id == id }?.media?.usesFrameStyle ?? false
    }

    func primarySegmentContext(id: UUID) -> PrimarySegmentPanelContext? {
        guard let map = try? TimelineMap(sourceSequence: editorStore.project.timeline.sourceSequence,
            sourceDurations: mediaSession.sourceDurations),
              let index = map.segments.firstIndex(where: { $0.id == id }) else { return nil }
        let junctions = EditorPrimaryTimelinePresentation.segmentJunctions(from: map)
        let frameRate = max(editorStore.project.captureFrameRate(for: map.segments[index].sourceID).rawValue, 1)
        return PrimarySegmentPanelContext(
            segment: map.segments[index],
            index: index,
            total: map.segments.count,
            junctionBefore: junctions.first { $0.nextSegmentID == id },
            junctionAfter: junctions.first { $0.previousSegmentID == id },
            leadingGap: EditorPrimaryTimelinePresentation.leadingGap(from: map),
            trailingGap: EditorPrimaryTimelinePresentation.trailingGap(from: map),
            sourceDurations: map.sourceDurations,
            frameDuration: 1 / Double(frameRate)
        )
    }

    /// 选中主片段时的面板，和「全片设置」是同一个页面：同一套设置行、同一种
    /// 分区节奏，只是选中时在「这一段的外观」之上多出一块「片段」区，说明这是
    /// 哪一段、来自哪份录制。读数一类的诊断信息收在「详情」里，破坏性操作在
    /// 页面最底下、用一条分隔线断开。
    @ViewBuilder
    func primarySegmentInspector(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context = primarySegmentContext(id: id) {
                primarySegmentSection(context)
                if showsPrimarySegmentDetails {
                    // 这一段的外观：和「全片设置」总览同一套行样式，点进去的页面
                    // 只作用于这一段，作用范围由面板顶部的范围区块说明。
                    EditorInspectorSection("这一段的外观") {
                        EditorSettingsOverview(
                            editorStore: editorStore,
                            rows: segmentOverviewRows(context.segment),
                            open: openSettingsPage
                        )
                    }
                    if context.segment.media == nil {
                        recordingSourceSoundSection(context.segment)
                        primarySegmentCropSection(context)
                    } else if insertedSegmentHasControllableSound(context.segment) {
                        EditorInspectorSection("声音", icon: "speaker.wave.2") {
                            VStack(alignment: .leading, spacing: 4) {
                                insertedSegmentSoundRows(segmentID: id, segment: context.segment)
                            }
                        }
                    }
                }

                if insertedMotionPath(id) != nil {
                    EditorMotionElementsSection(editorStore: editorStore, target: .mainTrack(id))
                    EditorInspectorSection("动效内容", icon: "sparkles") {
                        EditorInsertedMotionFields(editorStore: editorStore, segmentID: id)
                    }
                }

                if showsPrimarySegmentDetails,
                   context.segment.media != nil, context.segment.media?.imagePath == nil {
                    EditorInspectorSection("显示方式", icon: "rectangle.inset.filled") {
                        EditorSegmentedControl(
                            options: [false, true],
                            title: { $0 ? "套用画面样式" : "全屏" },
                            selection: Binding(
                                get: { insertedUsesFrameStyle(id) },
                                set: { editorStore.setInsertedSegmentUsesFrameStyle(id, $0) }
                            )
                        )
                        Text(appLocalized(insertedUsesFrameStyle(id)
                            ? "和录屏一样显示在背景上，带边距、圆角和阴影。"
                            : "铺满整个画面，不带背景和边框，适合开场、标题和黑场。"))
                            .font(.appUI(size: 13))
                            .foregroundStyle(EditorTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                primarySegmentEditingSection(id: id, context: context)
                primarySegmentDestructiveFooter(context: context)
            } else {
                EditorInspectorEmptyState(
                    title: "片段已不存在",
                    detail: "它可能已在时间线中删除或被撤销。",
                    systemImage: "film",
                    actionTitle: "返回画面设置",
                    action: { editorStore.selection = .canvas }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 声音 页在底部嵌了一份片段面板。片段页现在自己就有来源、外观和裁切，
    /// 整份嵌进去就是重复；在那一层只留时间与操作，面包屑的「片段」负责
    /// 回到完整的片段页。
    private var showsPrimarySegmentDetails: Bool {
        !(stackLevel == .settings && settingsPage == .sound)
    }

    func insertedSegmentHasControllableSound(_ segment: ResolvedRecordingSegment) -> Bool {
        guard let media = segment.media else { return false }
        if media.hasEmbeddedAudio { return true }
        return !editorStore.previewProject.timeline
            .associatedEffectAudioClips(overlappingStart: segment.outputStart, end: segment.outputEnd)
            .isEmpty
    }

    func insertedSegmentSoundSummary(_ segment: ResolvedRecordingSegment) -> String? {
        guard let media = segment.media else { return nil }
        let timeline = editorStore.previewProject.timeline
        let associated = timeline.associatedEffectAudioClips(
            overlappingStart: segment.outputStart,
            end: segment.outputEnd
        )
        let hasEmbedded = media.hasEmbeddedAudio
        guard hasEmbedded || !associated.isEmpty else { return nil }
        var parts: [String] = []
        if hasEmbedded {
            let overrides = timeline.primarySegmentAudioOverrides[segment.id] ?? PrimarySegmentAudioOverrides()
            if overrides.isSystemMuted == true {
                parts.append(appLocalized("静音"))
            } else {
                let defaultVolume = media.transferSound?.volume ?? 1
                let pct = Int(((overrides.systemVolume ?? defaultVolume) * 100).rounded())
                parts.append("\(pct)%")
            }
        }
        for clip in associated {
            if clip.isMuted {
                parts.append(appLocalized("静音"))
            } else {
                parts.append("\(Int((clip.volume * 100).rounded()))%")
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    func insertedSegmentSoundRows(segmentID: UUID, segment: ResolvedRecordingSegment) -> some View {
        let hasEmbedded = segment.media?.hasEmbeddedAudio == true
        let defaultEmbeddedVolume = segment.media?.transferSound?.volume ?? 1
        let associatedClips = editorStore.previewProject.timeline.associatedEffectAudioClips(
            overlappingStart: segment.outputStart,
            end: segment.outputEnd
        )
        if hasEmbedded {
            let embeddedTitle = segment.media?.motionPath != nil ? "音效音量" : "音量"
            let embeddedDetail = (segment.media?.transferSound?.path ?? segment.media?.soundPath)
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            audioVolumeRow(
                embeddedTitle,
                icon: .speaker,
                detail: embeddedDetail,
                value: editorPrimarySegmentAudioBinding(
                    store: editorStore,
                    segmentID: segmentID,
                    get: { _, overrides in overrides.systemVolume ?? defaultEmbeddedVolume },
                    set: { $0.systemVolume = min(max($1, 0), 1) },
                    actionName: "调整片段音量",
                    onError: onError
                ),
                isMuted: editorPrimarySegmentAudioBinding(
                    store: editorStore,
                    segmentID: segmentID,
                    get: { _, overrides in overrides.isSystemMuted ?? false },
                    set: { $0.isSystemMuted = $1 },
                    actionName: "切换片段静音",
                    onError: onError
                ),
                commandScope: .selection,
                accessibilityStem: "editor.inserted.audio"
            )
        }
        ForEach(associatedClips) { clip in
            let clipStem = URL(fileURLWithPath: clip.sourcePath).deletingPathExtension().lastPathComponent
            let rowTitle = (!hasEmbedded && associatedClips.count == 1) ? "音效音量" : clipStem
            audioVolumeRow(
                rowTitle,
                icon: .speaker,
                detail: URL(fileURLWithPath: clip.sourcePath).lastPathComponent,
                value: editorAudioClipBinding(
                    store: editorStore,
                    clipID: clip.id,
                    default: clip.volume,
                    keyPath: \.volume,
                    actionName: "调整音效音量",
                    onError: onError
                ),
                isMuted: editorAudioClipBinding(
                    store: editorStore,
                    clipID: clip.id,
                    default: clip.isMuted,
                    keyPath: \.isMuted,
                    actionName: "切换音效静音",
                    onError: onError
                ),
                commandScope: .selection,
                accessibilityStem: "editor.inserted.audioClip.\(clip.id.uuidString)"
            )
        }
    }

    /// 「裁切这份录制」在逐片段裁切已经存在的前提下会误导：裁切会话打开时
    /// 才选范围，这里只说明范围怎么选。
    @ViewBuilder
    private func primarySegmentCropSection(_ context: PrimarySegmentPanelContext) -> some View {
        let occurrences = editorStore.project.segmentCount(forSourceID: context.segment.sourceID)
        EditorInspectorSection("裁切", icon: "crop") {
            Button { editorStore.cropRecording(context.segment.sourceID) } label: {
                EditorSymbolLabel("裁切画面…", systemImage: "crop")
            }
            .buttonStyle(.editorQuiet)
            Text(appLocalized(occurrences > 1
                ? "这份录制在主轨上出现多次，裁切时可以选择只裁这一段，或整份录制。"
                : "这份录制只出现这一次，裁切作用于它本身。"))
                .font(.appUI(size: 11)).foregroundStyle(EditorTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「片段」区：这是第几段、来自哪份录制、在整片的哪个位置，倍速写在右上。
    /// 区间、时长、录到了什么这些读数谁都不是每次都要看，收进折叠的「详情」。
    @ViewBuilder
    private func primarySegmentSection(_ context: PrimarySegmentPanelContext) -> some View {
        EditorInspectorSection("片段", icon: "film") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("第 \(context.index + 1) 段")
                    .font(.appUI(size: 12, weight: .semibold))
                Text("共 \(context.total) 段")
                    .font(.appUI(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(playbackRateText(context.segment.playbackRate))
                    .font(.appUI(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(
                        EditorTheme.chrome(0.065),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }

            // 「声音」页底部嵌的是这一块的精简版：那里不重复来源卡片。
            if context.segment.media == nil, showsPrimarySegmentDetails {
                recordingSourceCard(context.segment)
            }

            if let map = mediaSession.mediaPlan?.timelineMap {
                EditorSegmentMap(
                    segments: map.segments,
                    selectedIndex: context.index,
                    totalDuration: map.segments.last?.outputEnd ?? 0
                )
                .padding(.vertical, 2)
            }

            EditorDisclosure("详情") {
                VStack(spacing: 8) {
                    primarySegmentInfoRow(
                        "输出时长",
                        value: segmentTimestamp(context.segment.outputDuration),
                        systemImage: "clock"
                    )
                    primarySegmentInfoRow(
                        "输出区间",
                        value: "\(segmentTimestamp(context.segment.outputStart)) – "
                            + segmentTimestamp(context.segment.outputEnd),
                        systemImage: "rectangle.inset.filled"
                    )
                    primarySegmentInfoRow(
                        "源区间",
                        value: "\(segmentTimestamp(context.segment.sourceStart)) – "
                            + segmentTimestamp(context.segment.sourceEnd),
                        systemImage: "film.stack"
                    )
                    if context.segment.media == nil {
                        recordingAvailabilityRow("麦克风", recorded: microphoneHasAudio)
                        recordingAvailabilityRow(
                            "摄像头",
                            recorded: editorStore.project.source(context.segment.sourceID)?.media.camera != nil
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分割、合并、还原剪切在时间线上都有手势、快捷键和右键菜单，面板里
    /// 再铺一遍长列表只是噪音；它们收进「更多剪辑操作」，还原剪切的
    /// "已剪多少"仍能看到。删除不在这里：破坏性操作在页面最底下。
    @ViewBuilder
    private func primarySegmentEditingSection(id: UUID, context: PrimarySegmentPanelContext) -> some View {
        EditorInspectorSection("剪辑", icon: "scissors") {
            EditorDisclosure("更多剪辑操作") {
                VStack(spacing: 2) {
                    segmentActionRow(
                        "在播放头处分割",
                        icon: "scissors",
                        disabled: !canSplitPrimarySegmentFromInspector(context: context),
                        help: canSplitPrimarySegmentFromInspector(context: context)
                            ? "在播放头处分割（S）"
                            : "把播放头移进这个片段内部后才能分割"
                    ) {
                        splitPrimarySegmentFromInspector(context: context)
                    }

                    if let junctionBefore = context.junctionBefore,
                       junctionBefore.hasRemovedSourceGap {
                        segmentActionRow(
                            String(format: appLocalized("还原之前的剪切（已剪 %@）"),
                                   segmentTimestamp(junctionBefore.removedDuration)),
                            icon: "arrow.uturn.backward"
                        ) {
                            restorePrimaryGapFromInspector(
                                junction: junctionBefore,
                                sourceDurations: context.sourceDurations
                            )
                        }
                    }

                    if let junctionAfter = context.junctionAfter {
                        if junctionAfter.hasRemovedSourceGap {
                            segmentActionRow(
                                String(format: appLocalized("还原之后的剪切（已剪 %@）"),
                                       segmentTimestamp(junctionAfter.removedDuration)),
                                icon: "arrow.uturn.backward"
                            ) {
                                restorePrimaryGapFromInspector(
                                    junction: junctionAfter,
                                    sourceDurations: context.sourceDurations
                                )
                            }
                        } else {
                            segmentActionRow(
                                "合并与下一片段",
                                icon: "link"
                            ) {
                                mergeWithNextSegmentFromInspector(context: context)
                            }
                        }
                    }

                    if let leadingGap = context.leadingGap,
                       leadingGap.nextSegmentID == id {
                        segmentActionRow(
                            "还原开头剪切（已剪 \(segmentTimestamp(leadingGap.removedDuration))）",
                            icon: "arrow.uturn.backward"
                        ) {
                            do {
                                try editorStore.restorePrimaryLeadingGap(
                                    sourceDurations: context.sourceDurations,
                                    actionName: "还原开头剪切"
                                )
                            } catch {
                                onError(error.localizedDescription)
                            }
                        }
                    }

                    if let trailingGap = context.trailingGap,
                       trailingGap.previousSegmentID == id {
                        segmentActionRow(
                            "还原结尾剪切（已剪 \(segmentTimestamp(trailingGap.removedDuration))）",
                            icon: "arrow.uturn.backward"
                        ) {
                            do {
                                try editorStore.restorePrimaryTrailingGap(
                                    sourceDurations: context.sourceDurations,
                                    actionName: "还原结尾剪切"
                                )
                            } catch {
                                onError(error.localizedDescription)
                            }
                        }
                    }
                }
                .padding(4)
                .background(EditorTheme.cardFill, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 删除是这一页唯一不可挽回的操作，所以它不混在别的分区里：它在页面最
    /// 底下，和上面的内容之间只有「剪辑」那一区收尾的分隔线——页面上每一区
    /// 之间都是这条线，删除也就读作"这一段结束之后的事"。
    @ViewBuilder
    private func primarySegmentDestructiveFooter(context: PrimarySegmentPanelContext) -> some View {
        segmentActionRow(
            "删除这个片段",
            icon: "trash",
            destructive: true
        ) {
            deletePrimarySegmentFromInspector(context: context)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    func primarySegmentInfoRow(
        _ title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            EditorSymbol(systemImage, size: 13)
                .font(.appUI(size: 10, weight: .semibold))
                .foregroundStyle(EditorTheme.chrome(0.52))
                .frame(width: 14)
            Text(appLocalized(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .font(.appUI(size: 11))
        .frame(maxWidth: .infinity)
    }

    func playbackRateText(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.000_1 {
            return "\(Int(rate.rounded()))×"
        }
        return EditorSliderValueFormat.compact(rate, unit: "×")
    }

    /// One row inside the grouped 片段操作 list: icon tile + title + hover lift.
    @ViewBuilder
    func segmentActionRow(
        _ title: String,
        icon: String,
        destructive: Bool = false,
        disabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let row = Button(action: action) {
            HStack(spacing: 9) {
                EditorSymbol(icon, size: 13.5)
                    .font(.appUI(size: 11, weight: .semibold))
                    .foregroundStyle(
                        destructive
                            ? Color.red.opacity(0.86)
                            : EditorTheme.primaryText.opacity(0.68)
                    )
                    .frame(width: 24, height: 24)
                    .background(
                        destructive
                            ? Color.red.opacity(0.10)
                            : EditorTheme.chrome(0.055),
                        in: Circle()
                    )
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(
                        destructive ? Color.red.opacity(0.92) : EditorTheme.primaryText
                    )
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SegmentActionRowStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)

        if let help {
            row.help(appLocalized(help))
        } else {
            row
        }
    }

    func canSplitPrimarySegmentFromInspector(context: PrimarySegmentPanelContext) -> Bool {
        playbackTime - context.segment.outputStart >= context.frameDuration
            && context.segment.outputEnd - playbackTime >= context.frameDuration
    }

    func splitPrimarySegmentFromInspector(context: PrimarySegmentPanelContext) {
        let rightID = UUID()
        do {
            try editorStore.splitPrimarySegment(
                atOutputTime: playbackTime,
                sourceDurations: context.sourceDurations,
                newRightSegmentID: rightID,
                actionName: "分割主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        // 与时间线 S 键同一习惯：分割后选中右侧新片段。
        editorStore.selection = .primarySegment(rightID)
    }

    func deletePrimarySegmentFromInspector(context: PrimarySegmentPanelContext) {
        do {
            try editorStore.removePrimarySegment(
                id: context.segment.id,
                sourceDurations: context.sourceDurations,
                actionName: "删除主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        editorStore.selection = .canvas
    }

    func restorePrimaryGapFromInspector(
        junction: EditorTimelineSegmentJunction,
        sourceDurations: [UUID: TimeInterval]
    ) {
        do {
            try editorStore.restorePrimaryGap(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                sourceDurations: sourceDurations,
                actionName: "还原该处剪切"
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    func mergeWithNextSegmentFromInspector(context: PrimarySegmentPanelContext) {
        guard let junctionAfter = context.junctionAfter else { return }
        do {
            try editorStore.mergeAdjacentPrimarySegments(
                previousSegmentID: junctionAfter.previousSegmentID,
                nextSegmentID: junctionAfter.nextSegmentID,
                sourceDurations: context.sourceDurations,
                actionName: "合并相邻主片段"
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    func segmentTimestamp(_ time: TimeInterval) -> String {
        let centiseconds = max(Int((time * 100).rounded(.down)), 0)
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        return String(format: "%d:%02d.%02d", minutes, seconds, fraction)
    }

    @ViewBuilder
    var motionInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if motionInspectorMode == .zoom, let index = selectedZoomAnimationIndex {
                EditorSegmentedControl(
                    options: [ZoomKeyframeOrigin.automatic, .manual],
                    title: { $0 == .automatic ? "自动跟随" : "手动定位" },
                    selection: zoomAnimationOriginBinding(index)
                )
            } else {
                motionTypeSelector
            }

            if motionInspectorMode == .zoom {
                zoomInspector
            } else if case let .screenMotion(id) = editorStore.selection {
                ScreenMotionTargetInspector(
                    editorStore: editorStore,
                    clipID: id,
                    onError: onError
                )
            } else {
                EditorScreenMotionStage(
                    screenImage: playbackController.pausedScreenImage,
                    height: 170
                )

                MotionInspectorScopeHeader(
                    title: "屏幕 3D",
                    statusTitle: "未选中片段",
                    showsContextHeader: false,
                    addTitle: "在播放头添加屏幕 3D",
                    onAdd: addScreenMotionAtPlayhead
                )

                if !editorStore.project.timeline.screenMotionClips.isEmpty,
                   !visibleTimelineTracks.contains(.screenMotion) {
                    Button {
                        visibleTimelineTracks.insert(.screenMotion)
                    } label: {
                        EditorSymbolLabel("显示屏幕 3D 轨道", systemImage: "eye")
                    }
                    .buttonStyle(.editorQuiet)
                }

                motionGlobalDefaults
            }
        }
    }

    var motionTypeSelector: some View {
        // A page switch, like 背景/布局/样机 on the 画面 page: no caption,
        // no card around it.
            EditorSegmentedControl(
                options: EditorMotionInspectorMode.allCases,
                title: { $0 == .screen3D ? "屏幕 3D" : "缩放" },
                icon: { $0 == .screen3D ? "cube.transparent" : "scope" },
                selection: Binding(
                    get: { motionInspectorMode },
                    set: { mode in
                        motionInspectorMode = mode
                        switch mode {
                        case .zoom:
                            if case .zoom = editorStore.selection { return }
                            if editorStore.selection != .zoomTrack {
                                editorStore.selection = .zoomTrack
                            }
                        case .screen3D:
                            if case .screenMotion = editorStore.selection { return }
                            if editorStore.selection != .screenMotionTrack {
                                editorStore.selection = .screenMotionTrack
                            }
                        }
                    }
                )
            )
    }

    var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let index = selectedZoomAnimationIndex {
                let animation = editorStore.previewProject.zoomAnimations[index]
                let zoomTrack = ZoomAnimationTrack(
                    editorStore.previewProject.zoomAnimations, outputDuration: timelineDuration
                )
                ZoomFocusMap(
                    mediaSession: mediaSession,
                    outputTime: animation.startTime,
                    sourcePixelSize: sourcePixelSize,
                    focus: displayedZoomFocusBinding(index),
                    refreshesDuringPlayback: animation.origin == .automatic,
                    isPlaying: playbackController.isPlaying,
                    onEditingChanged: {
                        updateEditorContinuousInteraction(
                            store: editorStore, isEditing: $0,
                            commandScope: .selection,
                            actionName: "调整缩放焦点",
                            onError: onError
                        )
                    },
                    onEditingCancelled: { editorStore.cancelInteraction() },
                    onTextPreviewValidityChanged: {
                        updateEditorTextPreviewValidity(
                            store: editorStore, isValid: $0,
                            commandScope: .selection, selection: .zoom(animation.id),
                            actionName: "调整缩放焦点"
                        )
                    }
                )
                if animation.origin == .automatic {
                    EditorInfoNote(
                        systemImage: "cursorarrow.motionlines",
                        lines: [appLocalized("录制鼠标位置 · 调整焦点切换为手动定位")]
                    )
                }

                motionTypeSelector

                EditorInspectorSection("缩放曲线") {
                    EditorZoomEnvelope(
                        editorStore: editorStore,
                        animation: zoomTrack.animations.first(where: { $0.id == animation.id }) ?? animation,
                        track: zoomTrack,
                        scale: zoomAnimationDoubleBinding(index, keyPath: \.scale),
                        enter: zoomAnimationTransitionDurationBinding(index, entering: true),
                        exit: zoomAnimationTransitionDurationBinding(index, entering: false),
                        playbackTime: playbackTime,
                        onError: onError
                    )
                    EditorKnobRow {
                        knob(
                            "放大比例", label: "放大",
                            value: zoomAnimationDoubleBinding(index, keyPath: \.scale),
                            range: 1...6, format: .multiplier
                        )
                        knob(
                            "进入时长", label: "进入",
                            value: zoomAnimationTransitionDurationBinding(index, entering: true),
                            range: 0...3, format: .seconds
                        )
                        knob(
                            "退出时长", label: "退出",
                            value: zoomAnimationTransitionDurationBinding(index, entering: false),
                            range: 0...3, format: .seconds
                        )
                    }
                    .padding(.top, 4)
                    zoomTransitionAvailability(animation)
                    Button {
                        applySelectedZoomScaleToAll(animation.scale)
                    } label: {
                        EditorSymbolLabel("将倍率应用到全部缩放", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.editorQuiet)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                    .disabled(editorStore.previewProject.zoomAnimations.count < 2)
                    .help("应用倍率到全部缩放")
                }

                EditorInspectorSection("片段时间", showsTitle: false) {
                    EditorDisclosure(
                        "片段时间",
                        detail: String(
                            format: appLocalized("开始 %@ · 范围 %@"),
                            EditorSliderValueFormat.seconds.text(for: animation.startTime),
                            EditorSliderValueFormat.seconds.text(for: animation.duration)
                        )
                    ) {
                        VStack(spacing: 9) {
                            zoomTimeStepper(
                                "开始位置",
                                value: zoomAnimationStartBinding(index),
                                range: 0...max(timelineDuration - 0.16, 0),
                                resolvedValue: { resolvedZoomStartValue(index, proposed: $0) }
                            )
                            zoomTimeStepper(
                                "片段长度",
                                value: zoomAnimationDurationBinding(index),
                                range: 0.16...max(timelineDuration, 0.16),
                                resolvedValue: { resolvedZoomDurationValue(index, proposed: $0) }
                            )
                        }
                    }
                }

                EditorFocusEffectInspector(editorStore: editorStore,
                    selection: .zoom(animation.id), onError: onError)

                Button("删除片段", role: .destructive) {
                    if let selectedZoomID {
                        do {
                            try editorStore.removeZoom(id: selectedZoomID, actionName: "删除缩放")
                        } catch {
                            onError(error.localizedDescription)
                        }
                    }
                    selectedZoomID = nil
                }
                .buttonStyle(.editorDestructive)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .padding(.top, 4)
            } else if case .zoom = editorStore.selection {
                EditorInspectorEmptyState(
                    title: "缩放片段已不存在",
                    detail: "它可能已在时间线中删除或被撤销。",
                    systemImage: "scope",
                    actionTitle: "返回缩放",
                    action: { editorStore.selection = .zoomTrack }
                )
            } else {
                // Selection stays on the timeline. When its track is hidden,
                // reveal that workspace before offering the creation gesture.
                if visibleTimelineTracks.contains(.zoom) {
                    VStack(alignment: .leading, spacing: 10) {
                        EditorZoomStage(
                            screenImage: playbackController.pausedScreenImage,
                            height: 170
                        )
                        EditorSymbolLabel(
                            "在“缩放”轨道拖动创建；选中片段后在这里调整",
                            systemImage: "timeline.selection"
                        )
                        .font(.appUI(size: 12))
                        .foregroundStyle(EditorTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 10) {
                        EditorSymbolLabel("缩放轨道已隐藏", systemImage: "eye.slash")
                            .font(EditorTypography.controlLabel)
                            .foregroundStyle(EditorTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("显示") {
                            visibleTimelineTracks.insert(.zoom)
                        }
                        .buttonStyle(.editorQuiet)
                        .help("显示缩放轨道")
                        .fixedSize(horizontal: true, vertical: false)
                        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                        .accessibilityIdentifier("editor.inspector.zoom.show-track")
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            guard !isCropping,
                                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                                return .ignored
                            }
                            visibleTimelineTracks.insert(.zoom)
                            return .handled
                        }
                    }
                    .padding(.horizontal, EditorInterfaceSpacing.tileInset)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EditorTheme.cardFill, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
                }

                motionGlobalDefaults
            }
        }
    }

    @ViewBuilder
    var motionGlobalDefaults: some View {
        EditorInspectorSection("新建片段") {
            sliderRow(
                "过渡时长",
                value: motionBinding(
                    \.defaultZoomTransitionDuration,
                    actionName: "调整默认过渡时长"
                ),
                range: 0...3,
                interactionScope: .motion,
                format: .seconds
            )
        }

    }
}

/// Row body for the grouped 片段操作 list: clear normally, a soft rounded
/// lift on hover or press so the whole panel reads as one list.
private struct SegmentActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.card - 4, style: .continuous)
                        .fill(
                            EditorTheme.chrome(
                                configuration.isPressed ? 0.10 : hovered ? 0.06 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.card - 4, style: .continuous))
                .appKeyboardFocus(
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card - 4, style: .continuous)
                )
                .onHover { hovered = $0 }
                .animation(SpringMotion.hover, value: hovered)
        }
    }
}

/// The vertical rhythm under an inspector title. The scroll area keeps a
/// fixed top inset (its edge fade lives there), so the header supplies the
/// rest of the gap.
enum EditorInspectorRhythm {
    static let titleGap: CGFloat = 14
    static let scrollTop: CGFloat = 8
}
