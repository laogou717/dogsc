import AVFoundation
import AppKit
import ImageIO
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

/// EDT-054: the left library — a working media browser, not a second
/// inspector. A compact header (text tabs with a thin sliding underline,
/// import and collapse on the panel itself), and the whole panel accepts
/// dropped files. Pages swap with a short crossfade.
struct EditorLibraryPanel: View {
    enum Page: String, CaseIterable, Identifiable {
        case media = "素材"
        case subtitles = "字幕"
        case ai = "AI"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .media: "photo.on.rectangle"
            case .subtitles: "captions.bubble"
            case .ai: "sparkles"
            }
        }
        var lineIcon: AppLineIcon.Kind {
            switch self {
            case .media: .photoAdd
            case .subtitles: .list
            case .ai: .sparkle
            }
        }
    }

    static let pageKey = "editor.libraryPanel.page"
    static func remember(_ page: Page) { UserDefaults.standard.set(page.rawValue, forKey: pageKey) }

    @ObservedObject var editorStore: EditorStore
    let onCollapse: () -> Void
    @AppStorage(EditorLibraryPanel.pageKey) private var pageRaw = Page.media.rawValue
    @State private var isDropTargeted = false
    @State private var visitedPages: Set<Page> = []
    @Namespace private var underline

    private var page: Page {
        // "文本" was this page's earlier stored name.
        pageRaw == "文本" ? .subtitles : Page(rawValue: pageRaw) ?? .media
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(EditorTheme.hairline).frame(height: 1)
            ZStack {
                // EDT-061: pages stay alive in one stack and only fade and
                // shift a little; nothing is rebuilt or resized, so the swap
                // cannot tear. A page is created the first time it is shown.
                pageLayer(.media) {
                    VStack(spacing: 0) {
                        GeometryReader { viewport in
                            ScrollView {
                                EditorMediaLibrary(editorStore: editorStore,
                                                   projectAssets: editorStore.project.timeline.mediaAssets,
                                                   recordingSources: editorStore.project.sources,
                                                   recordingSequence: editorStore.project.timeline.sourceSequence,
                                                   revealedRecordingID: editorStore.revealedRecordingID,
                                                   minimumHeight: max(viewport.size.height - 24, 0),
                                                   isActive: page == .media,
                                                   onImport: importFiles)
                                    .equatable()
                                    .padding(12)
                            }
                            .scrollIndicators(.never)
                        }
                        .overlay(alignment: .bottom) { EditorLibraryRemovalNotice() }
                        if !editorStore.project.sources.isEmpty || !editorStore.previewProject.timeline.mediaAssets.isEmpty || !AssetLibrary.shared.entries.isEmpty {
                            EditorMediaBottomBar(editorStore: editorStore)
                        }
                    }
                }
                pageLayer(.subtitles) {
                    ScrollView {
                        EditorTextLibrary(editorStore: editorStore) { pageRaw = Page.ai.rawValue }.padding(12)
                    }
                    .scrollIndicators(.never)
                }
                pageLayer(.ai) {
                    // The conversation owns its scrolling and keeps the
                    // composer pinned to the bottom.
                    EditorAIInspector()
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                        .strokeBorder(EditorTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous).fill(EditorTheme.selectionWash))
                        .overlay(
                            Text(appLocalized(page == .ai ? "松开作为参考附件" : "松开即可导入"))
                                .font(.appUI(size: 14, weight: .semibold))
                                .foregroundStyle(EditorTheme.primaryText)
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        }
        .background(EditorTheme.panelSurface)
        // One drop target for the whole panel: on the AI page files become
        // reference attachments, everywhere else they join the media bin.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            let toChat = page == .ai
            if !toChat {
                return EditorMediaDrag.readAll(providers,
                    onFailure: { editorStore.reportError?(appLocalized("无法读取拖入的素材，请重新拖入。")) }) { items in
                    let urls = items.compactMap { item -> URL? in
                        if case let .file(url) = item { return url }
                        return nil
                    }
                    editorStore.importMediaAssets(urls)
                    pageRaw = Page.media.rawValue
                }
            }
            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            AgentChatModel.shared.attach([url])
                        }
                    }
                } else if toChat, provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                        guard let image = image as? NSImage else { return }
                        Task { @MainActor in AgentChatModel.shared.attach(image: image) }
                    }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func pageLayer<Content: View>(_ item: Page, @ViewBuilder content: () -> Content) -> some View {
        let current = Page.allCases.firstIndex(of: page) ?? 0
        let mine = Page.allCases.firstIndex(of: item) ?? 0
        if visitedPages.contains(item) || item == page {
            content()
                .opacity(item == page ? 1 : 0)
                .offset(x: item == page ? 0 : (mine < current ? -4 : 4))
                .allowsHitTesting(item == page)
                .accessibilityHidden(item != page)
                // EDT-062: no cross-fade — the page being left disappears at
                // once (no animation); only the page being shown eases in.
                .animation(item == page ? SpringMotion.fade : nil, value: pageRaw)
                .onAppear { visitedPages.insert(item) }
        }
    }

    private var selectedSubtitleID: UUID? {
        if case let .subtitle(id) = editorStore.selection { return id }
        return nil
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { item in
                LibraryTabButton(title: appLocalized(item.rawValue), selected: item == page, underline: underline) {
                    pageRaw = item.rawValue
                }
            }
            Spacer(minLength: 0)
            if page == .media {
                Button(action: importFiles) {
                    EditorToolbarControlSurface(accessibilityTitle: "导入素材") {
                        // Drops its word before anything else is squeezed.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 5) {
                                AppLineIcon(kind: .plus, size: 12)
                                Text("导入").lineLimit(1).fixedSize()
                            }
                            AppLineIcon(kind: .plus, size: 12)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.control))
                .help(appLocalized("导入素材"))
            }
            Button(action: onCollapse) {
                EditorToolbarIconSurface(systemName: "sidebar.left")
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.control))
            .help(appLocalized("收起（⌥⌘L）"))
            .accessibilityLabel(appLocalized("收起素材面板"))
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: 40)
        // Only the underline glides; page content switches instantly.
        .animation(SpringMotion.standard, value: pageRaw)
    }

    private func importFiles() {
        if UserDefaults.standard.string(forKey: "editor.mediaLibrary.filter") == "recording" {
            EditorMenuBridge.shared.importRecordingRequest.send()
            return
        }
        EditorImportFilePicker.choose(
            directory: ProjectFiles.package?.deletingLastPathComponent() ?? ProjectStore.savedProjectsFolder,
            extensions: EditorMediaLibrary.extensions
        ) { urls in
            editorStore.importMediaAssets(urls)
            pageRaw = Page.media.rawValue
        }
    }
}

/// The collapsed library: a slim strip whose icons reopen it on a page.
struct EditorLibraryRail: View {
    let onOpen: (EditorLibraryPanel.Page) -> Void
    @State private var hovered: EditorLibraryPanel.Page?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(EditorLibraryPanel.Page.allCases) { page in
                Button { onOpen(page) } label: {
                    AppLineIcon(kind: page.lineIcon, size: 15)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                                .fill(hovered == page ? EditorTheme.chrome(EditorStateWash.hover) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovered == page ? EditorTheme.primaryText : EditorTheme.secondaryText)
                .help(appLocalized(page.rawValue))
                .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
            }
            Spacer()
        }
        .padding(.top, 8)
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .background(EditorTheme.panelSurface)
        .animation(SpringMotion.micro, value: hovered)
    }
}

/// The media bin: grid or list, adjustable tile size, live previews
/// (Rive plays and video skims under the pointer, audio shows its waveform
/// and can be auditioned), click to select, Delete to remove.
struct EditorMediaLibrary: View, Equatable {
    enum Scope: String { case project, library }
    enum LibraryFilter: String { case favorites, generated, all }

    /// Not observed: the bin redraws only when its own assets change (see
    /// `==`), never on every frame of a timeline or canvas drag.
    let editorStore: EditorStore
    let projectAssets: [MediaAsset]
    let recordingSources: [RecordingSource]
    let recordingSequence: SourceSequence
    let revealedRecordingID: UUID?
    var minimumHeight: CGFloat = 0
    var isActive = true
    let onImport: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.editorStore === rhs.editorStore
            && lhs.projectAssets == rhs.projectAssets && lhs.recordingSources == rhs.recordingSources
            && lhs.recordingSequence == rhs.recordingSequence && lhs.revealedRecordingID == rhs.revealedRecordingID
            && lhs.minimumHeight == rhs.minimumHeight
            && lhs.isActive == rhs.isActive
    }
    @AppStorage("editor.mediaLibrary.filter") private var filterRaw = ""
    @AppStorage("editor.mediaLibrary.scope") private var scopeRaw = Scope.project.rawValue
    @AppStorage("editor.mediaLibrary.libraryFilter") private var libraryFilterRaw = LibraryFilter.favorites.rawValue
    @AppStorage("editor.mediaLibrary.list") private var showsList = false
    @AppStorage("editor.mediaLibrary.tileWidth") private var tileWidth = 120.0
    /// Measured width of the grid, so the tiles can shrink with the panel.
    @State private var gridWidth: CGFloat = 0
    /// Narrower than this a card has no room for a legible name.
    private static let minimumTileWidth: CGFloat = 64
    @State private var hoveredID: UUID?
    @StateObject private var mediaSelection = EditorMediaSelection()
    private var selection: Set<UUID> {
        get { mediaSelection.ids }
        nonmutating set { mediaSelection.ids = newValue }
    }
    @State private var query = ""
    @State private var presentationCache = EditorMediaPresentationCache()
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var contentTop = CGFloat.infinity
    @StateObject private var marquee = EditorMediaMarquee()
    @FocusState private var focused: Bool
    @ObservedObject private var audition = MediaAudition.shared
    @ObservedObject private var library = AssetLibrary.shared
    /// Written, never read for drawing: the monitor's own overlay observes it.
    private let monitor = EditorAssetMonitor.shared
    @Namespace private var scopeIndicator
    @Namespace private var selectionSpace

    private var filter: MediaAssetKind? { MediaAssetKind(rawValue: filterRaw) }
    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .project }
    private var libraryFilter: LibraryFilter { LibraryFilter(rawValue: libraryFilterRaw) ?? .favorites }
    private var allAssets: [MediaAsset] { projectAssets }

    /// Library entries shown with the same tiles as project assets.
    private var recordings: [RecordingSource] {
        guard scope == .project, filterRaw.isEmpty || filterRaw == "recording" else { return [] }
        return recordingSources.filter { query.isEmpty || RecordingSourcePresentation.name($0.id, in: editorStore.project).localizedCaseInsensitiveContains(query) }
    }

    private var assets: [MediaAsset] {
        presentationCache.assets(project: projectAssets, library: library.entries,
            scope: scope.rawValue, filter: filterRaw, libraryFilter: libraryFilter.rawValue, query: query)
    }

    static let extensions = ["mov", "mp4", "m4v", "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff",
                             "mp3", "m4a", "wav", "aiff", "aif", "aac", "caf", "flac", "dmhtml", "dogscproject"]

    var body: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 10) {
            scopeBar
            Group {
            if scope == .library { libraryFilters }
            mediaTypeFilters
            if scope == .project, allAssets.isEmpty && recordingSources.isEmpty {
                emptyImport
            } else {
                searchField
                mediaItems
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: EditorMediaContentTop.self,
                            value: geometry.frame(in: .named(selectionSpace)).minY)
                    })
            }
            }
            // EDT-062: switching scope replaces the content at once and lets
            // only the new content ease in — never two lists overlapping.
            .id(scopeRaw)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .identity))
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(marqueeGesture)
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(selectionSpace)).onEnded { tap in
                    if tap.location.y >= contentTop { onImport() }
                })
        }
        .overlay(alignment: .topLeading) { EditorMediaMarqueeOverlay(marquee: marquee) }
        .clipped()
        .coordinateSpace(name: selectionSpace)
        .onPreferenceChange(EditorMediaItemFrames.self) { if itemFrames != $0 { itemFrames = $0 } }
        .onPreferenceChange(EditorMediaContentTop.self) { if contentTop != $0 { contentTop = $0 } }
        .focusable(isActive)
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand {
            guard isActive else { return }
            deleteSelection()
        }
        // A full keyboard's forward delete reads as "remove" too.
        .onKeyPress(.deleteForward) {
            guard isActive else { return .ignored }
            deleteSelection()
            return .handled
        }
        .onKeyPress(.return) {
            guard isActive else { return .ignored }
            if selection.count == 1, let id = selection.first, recordings.contains(where: { $0.id == id }) {
                insertRecording(id); return .handled
            }
            if selection.isEmpty, let id = revealedRecordingID, recordings.contains(where: { $0.id == id }) {
                insertRecording(id); return .handled
            }
            guard selection.count == 1, let asset = assets.first(where: { selection.contains($0.id) }) else { return .ignored }
            place(asset)
            return .handled
        }
        .onKeyPress(.escape) {
            guard isActive else { return .ignored }
            clearMediaSelection(); return .handled
        }
        // I and O mark the preview, as everywhere else in editing. Only while
        // the bin itself holds the keyboard, so they stay typable in search.
        .onKeyPress("i") {
            guard isActive, focused, monitor.isPreviewing else { return .ignored }
            monitor.playback.markInHere(); return .handled
        }
        .onKeyPress("o") {
            guard isActive, focused, monitor.isPreviewing else { return .ignored }
            monitor.playback.markOutHere(); return .handled
        }
        .onChange(of: focused) { _, value in editorStore.mediaLibraryHasKeyboardFocus = value }
        .onChange(of: isActive) { _, value in
            if !value { focused = false; editorStore.mediaLibraryHasKeyboardFocus = false; marquee.end() }
        }
        .onDisappear { editorStore.mediaLibraryHasKeyboardFocus = false; marquee.end(); monitor.returnToProgramme() }
        .onAppear { library.reload() }
        .onChange(of: revealedRecordingID, initial: true) { _, id in
            guard let id else { return }
            selection = [id]
            Task { @MainActor in
                await Task.yield()
                withAnimation(SpringMotion.standard) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onChange(of: scopeRaw) { _, _ in
            clearMediaSelection(); hoveredID = nil
            if scope == .library, filterRaw == "recording" { filterRaw = "" }
        }
        .onChange(of: filterRaw) { _, _ in clearMediaSelection() }
        .onChange(of: libraryFilterRaw) { _, _ in clearMediaSelection() }
        .onChange(of: query) { _, _ in clearMediaSelection() }
        }
    }

    @ViewBuilder private var mediaItems: some View {
        if assets.isEmpty && recordings.isEmpty { emptyResult }
        else if showsList {
            LazyVStack(spacing: 10) {
                recordingCards
                ForEach(assets) { row($0).background(itemFrame($0.id)) }
            }
        } else {
            // The thumbnail size is a preference, not a promise: a panel
            // dragged narrower than one tile has to shrink its tiles, or the
            // grid keeps laying out 120pt cards in an 80pt column and clips
            // them, squeezing each name into a vertical strip of characters.
            let columnMinimum = gridWidth > 0
                ? min(tileWidth, max(gridWidth - 2, Self.minimumTileWidth))
                : tileWidth
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnMinimum,
                                                  maximum: max(columnMinimum, tileWidth * 1.6)),
                                         spacing: 8)], spacing: 10) {
                recordingCards
                ForEach(assets) { tile($0).background(itemFrame($0.id)) }
                if scope == .project, filterRaw == "recording" { addRecordingCard }
            }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: EditorMediaGridWidthKey.self, value: geometry.size.width)
            })
            .onPreferenceChange(EditorMediaGridWidthKey.self) { width in
                guard abs(width - gridWidth) > 0.5 else { return }
                gridWidth = width
            }
        }
    }

    private func itemFrame(_ id: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: EditorMediaItemFrames.self,
                value: [id: geometry.frame(in: .named(selectionSpace))])
        }
    }

    private func clearMediaSelection() {
        selection.removeAll(); editorStore.revealedRecordingID = nil; marquee.end()
        monitor.returnToProgramme()
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(selectionSpace))
            .onChanged { drag in
                guard drag.startLocation.y >= contentTop,
                      !itemFrames.values.contains(where: { $0.contains(drag.startLocation) }) else { return }
                guard marquee.isActive || hypot(drag.translation.width, drag.translation.height) > 3 else { return }
                if !marquee.isActive {
                    let flags = NSEvent.modifierFlags
                    marquee.begin(at: drag.startLocation,
                        base: flags.contains(.shift) || flags.contains(.command) ? selection : [], frames: itemFrames)
                    editorStore.revealedRecordingID = nil
                    focused = true
                }
                let selected = marquee.update(to: drag.location)
                if selection != selected { selection = selected }
            }
            .onEnded { drag in
                defer { marquee.end() }
                guard drag.startLocation.y >= contentTop else { return }
                if !marquee.isActive, !itemFrames.values.contains(where: { $0.contains(drag.startLocation) }) {
                    clearMediaSelection(); focused = true
                }
            }
    }

    private var recordingCards: some View {
        let durations = editorStore.recordingDurations()
        return ForEach(recordings) { source in
            RecordingSourceLibraryCard(source: source,
                name: RecordingSourcePresentation.name(source.id, in: editorStore.project),
                color: RecordingSourcePresentation.color(source.id, in: editorStore.project),
                usage: RecordingSourceEditing.usageCount(source.id, in: recordingSequence),
                knownDuration: durations[source.id],
                selected: selection.contains(source.id),
                isFocused: editorStore.mediaLibraryHasKeyboardFocus,
                select: { selectMedia(source.id); previewRecording(source) },
                favorite: library.isFavorite(RecordingSourcePresentation.url(source)?.path ?? ""),
                toggleFavorite: { toggleRecordingFavorite(source) },
                actionWidth: tileWidth - 8,
                insert: { insertRecording(source.id) })
                .contextMenu { EditorDeferredMenuContent { recordingMenu(source) } }
                .id(source.id)
                .background(itemFrame(source.id))
        }
    }

    @ViewBuilder
    private func recordingMenu(_ source: RecordingSource) -> some View {
        let targets = mediaSelection.targets(for: source.id)
        Button(appLocalized("插入到主轨")) { insertRecording(source.id) }
        Button(appLocalized(library.isFavorite(RecordingSourcePresentation.url(source)?.path ?? "") ? "取消收藏" : "收藏")) {
            toggleRecordingFavorite(source)
        }
        if source.id != RecordingSource.primaryID {
            Button(appLocalized("重命名录制…")) { editorStore.renameRecordingSource(source.id) }
        }
        if source.id != RecordingSource.primaryID || targets.count > 1 {
            Divider()
            Button(appLocalized(targets.count > 1 ? "移除所选素材" : "从项目移除"), role: .destructive) {
                removeSelection(targets)
            }
        }
    }
    private var addRecordingCard: some View {
        Button { EditorMenuBridge.shared.importRecordingRequest.send() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(.clear)
                    .aspectRatio(1.6, contentMode: .fit)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RecordingDesign.fill2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                    .overlay { AppLineIcon(kind: .plus, size: 20) }
                Text(appLocalized("导入录屏项目")).font(.appUI(size: 12))
            }.foregroundStyle(RecordingDesign.tertiary).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    /// Six chips that refuse to compress used to set the panel's minimum
    /// width: dragging the sidebar narrower than their sum pushed the whole
    /// column — tabs, search and the grid with it — past the panel's edge and
    /// it was simply clipped. They scroll instead, so every filter stays
    /// reachable at any width and nothing else is pulled out of view.
    private var mediaTypeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                mediaTypeChip("", "全部")
                if scope == .project { mediaTypeChip("recording", "录制") }
                mediaTypeChip("video", "视频")
                mediaTypeChip("image", "图片")
                mediaTypeChip("audio", "音频")
                mediaTypeChip("animation", "动效")
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func mediaTypeChip(_ raw: String, _ title: String) -> some View {
        Button { withAnimation(SpringMotion.standard) { filterRaw = raw } } label: {
            Text(appLocalized(title)).font(.appUI(size: 13, weight: filterRaw == raw ? .medium : .regular))
                .foregroundStyle(filterRaw == raw ? RecordingDesign.ink : RecordingDesign.secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(filterRaw == raw ? RecordingDesign.fill2 : .clear, in: RoundedRectangle(cornerRadius: 7))
                .fixedSize()
        }.buttonStyle(.plain)
    }

    // MARK: Header

    /// 本项目 / 素材库: a quiet two-way switch.
    private var scopeBar: some View {
        HStack(spacing: 2) {
            scopeButton(.project, "本项目", count: allAssets.count)
            scopeButton(.library, "素材库", count: library.entries.count)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control + 2, style: .continuous).fill(EditorTheme.controlWell))
    }

    private func scopeButton(_ value: Scope, _ title: String, count: Int) -> some View {
        let selected = scope == value
        return Button { withAnimation(SpringMotion.standard) { scopeRaw = value.rawValue } } label: {
            HStack(spacing: 4) {
                Text(appLocalized(title)).font(.appUI(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)").font(.appUI(size: 11).monospacedDigit()).foregroundStyle(EditorTheme.secondaryText)
                }
            }
            .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(EditorTheme.segmentThumb)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "scope", in: scopeIndicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var libraryFilters: some View {
        HStack(spacing: 2) {
            libraryChip(.favorites, "收藏", symbol: "star")
            libraryChip(.generated, "AI 生成", symbol: "sparkles")
            libraryChip(.all, "全部", symbol: nil)
            Spacer(minLength: 0)
            Button { NSWorkspace.shared.activateFileViewerSelecting([library.folder]) } label: {
                AppLineIcon(kind: .folder, size: 13).frame(width: 24, height: 24)
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.control))
            .foregroundStyle(EditorTheme.secondaryText)
            .help(appLocalized("在访达中打开素材库文件夹"))
        }
    }

    private func libraryChip(_ value: LibraryFilter, _ title: String, symbol: String?) -> some View {
        let selected = libraryFilter == value
        return Button { libraryFilterRaw = value.rawValue } label: {
            HStack(spacing: 3) {
                if let symbol { EditorSymbol(selected ? symbol + ".fill" : symbol, size: 9).font(.system(size: 9, weight: .semibold)) }
                Text(appLocalized(title)).font(.appUI(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).fill(selected ? EditorTheme.selectionWash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            AppLineIcon(kind: .search, size: 12).foregroundStyle(EditorTheme.tertiaryText)
            TextField(appLocalized("搜索素材"), text: $query).textFieldStyle(.plain).font(.appUI(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    EditorSymbol("xmark.circle.fill", size: 10).font(.system(size: 10)).foregroundStyle(EditorTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).fill(EditorTheme.controlWell))
    }

    private var emptyResult: some View {
        let message: String = if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            "没有找到相关素材"
        } else if scope == .library {
            switch libraryFilter {
            case .favorites: "点素材上的星标收藏，所有项目都能在这里找到它"
            case .generated: "AI 生成的动效、图片和音乐会保存在这里"
            case .all: "素材库还是空的"
            }
        } else {
            "这一类还没有素材"
        }
        return Text(appLocalized(message))
            .font(.appUI(size: 13))
            .foregroundStyle(EditorTheme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 12)
    }

    private var emptyImport: some View {
        Button(action: onImport) {
            VStack(spacing: 10) {
                AppLineIcon(kind: .download, size: 22)
                    .foregroundStyle(EditorTheme.secondaryText)
                Text(appLocalized("导入素材"))
                    .font(.appUI(size: 14, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                Text(appLocalized("点击选择，或把视频、图片、音频、Rive 文件拖到这里"))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .multilineTextAlignment(.center)
                Text(appLocalized("只记录原文件位置，不复制"))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(
                RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                    .fill(EditorTheme.cardFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Items

    /// Absolute path of a tile (library entries are already absolute).
    private func absolutePath(_ asset: MediaAsset) -> String {
        scope == .library ? asset.path : ProjectFiles.resolve(asset.path)
    }

    private func isMissing(_ asset: MediaAsset) -> Bool { EditorMediaPresence.shared.isMissing(absolutePath(asset)) }

    private func libraryEntry(_ asset: MediaAsset) -> AssetLibrary.Entry? {
        scope == .library ? library.entries.first { $0.id == asset.id } : nil
    }

    /// Adds a library item to this project's bin (by reference) and places
    /// it. Placing is a timeline edit, so the monitor goes back to the
    /// programme to show what just landed there — unless the viewer is
    /// pulling marked spans out of the file in the monitor, where the marks
    /// and the position have to survive the add so the next span is one
    /// gesture away. What the marks enclose is all that is placed.
    private func place(_ asset: MediaAsset) {
        let range = monitor.sourceRange(forPath: absolutePath(asset))
        if range == nil { monitor.returnToProgramme() }
        let target: MediaAsset? = scope == .library
            ? editorStore.importMediaAssets([URL(fileURLWithPath: asset.path)]).first
            : asset
        guard let target else { return }
        editorStore.placeMediaAsset(target, sourceRange: range)
    }

    /// A recording goes into the main track the same way: as itself, or as
    /// the span the monitor marked.
    private func insertRecording(_ id: UUID) {
        let range = recordings.first { $0.id == id }
            .flatMap { RecordingSourcePresentation.url($0) }
            .flatMap { monitor.sourceRange(forPath: $0.path) }
        if range == nil { monitor.returnToProgramme() }
        editorStore.insertRecording(id, sourceRange: range)
    }

    /// Favouriting copies the file into the library; a failed copy must not
    /// leave a favourite pointing at a file the library does not have.
    private func toggleFavorite(_ asset: MediaAsset) {
        do { try library.toggleFavorite(path: absolutePath(asset), kind: asset.kind, name: asset.name) }
        catch { editorStore.reportError?(appErrorDescription(error)) }
    }

    /// A recording is favourited by its screen file, so the library keeps it
    /// even after this project goes.
    private func toggleRecordingFavorite(_ source: RecordingSource) {
        guard let url = RecordingSourcePresentation.url(source) else { return }
        let name = RecordingSourcePresentation.name(source.id, in: editorStore.project)
        do { try library.toggleFavorite(path: url.path, kind: .video, name: name) }
        catch { editorStore.reportError?(appErrorDescription(error)) }
    }

    private func dragPayload(_ asset: MediaAsset) -> NSItemProvider {
        EditorMediaDrag.provider(for: scope == .library ? .library(asset.path) : .asset(asset.id))
    }

    /// A single click selects and shows the file in the monitor; placing it
    /// stays on the double click and on the card's own plus.
    private func tap(_ asset: MediaAsset) {
        selectMedia(asset.id)
        if !isMissing(asset) { monitor.preview(asset, at: absolutePath(asset)) }
    }

    private func previewRecording(_ source: RecordingSource) {
        monitor.previewRecording(source, name: RecordingSourcePresentation.name(source.id, in: editorStore.project),
            audio: editorStore.project.audio, camera: editorStore.project.camera)
    }

    private func selectMedia(_ id: UUID) {
        focused = true
        editorStore.revealedRecordingID = nil
        let flags = NSEvent.modifierFlags
        if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.type == .rightMouseUp || flags.contains(.control) {
            if !selection.contains(id) { selection = [id] }
        } else if flags.contains(.command) || flags.contains(.shift) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private func tile(_ asset: MediaAsset) -> some View {
        let missing = isMissing(asset)
        let hovered = hoveredID == asset.id
        let selected = selection.contains(asset.id)
        let favorite = library.isFavorite(absolutePath(asset))
        return VStack(alignment: .leading, spacing: 4) {
            EditorMediaThumbnail(selected: selected, isFocused: editorStore.mediaLibraryHasKeyboardFocus) {
                ZStack {
                    MediaPreview(asset: asset,
                                 isHovered: hovered && !missing)
                        .frame(maxWidth: .infinity)
                        .opacity(missing ? 0.35 : 1)
                    if missing {
                        if scope == .project {
                            Button(appLocalized("重新关联")) { relink(asset) }
                                .font(.appUI(size: 12, weight: .semibold))
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(Capsule().fill(EditorTheme.amberAccent.opacity(0.9)))
                                .foregroundStyle(.white)
                        } else {
                            Text(appLocalized("文件缺失")).font(.appUI(size: 12, weight: .semibold)).foregroundStyle(RecorderStyle.amberInk)
                        }
                    }
                    VStack {
                        // One cluster in the corner the pointer reaches for,
                        // trimmed to what the tile's width can hold.
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            EditorMediaCardActions(
                                items: cardActions(asset, missing: missing, hovered: hovered, favorite: favorite),
                                available: tileWidth - 8)
                        }
                        Spacer(minLength: 0)
                        HStack {
                            Spacer(minLength: 0)
                            if !missing, asset.kind == .video || asset.kind == .audio {
                                MediaDurationBadge(path: absolutePath(asset))
                            }
                        }
                    }
                    .padding(4)
                }
            }
            // A tile is 120pt wide: keep the start, which is what tells two
            // generated motions apart, and put the full name in the tooltip.
            Text(asset.displayName)
                .font(.appUI(size: 12))
                .lineLimit(1).truncationMode(.tail)
                // Takes the card's width and truncates. Left to size itself, a
                // very narrow card wrapped the name one character per line.
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(missing ? EditorTheme.secondaryText : EditorTheme.primaryText)
                .help(asset.name)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hoveredID = inside ? asset.id : (hoveredID == asset.id ? nil : hoveredID) } }
        // Not simultaneous: a click on the star or the plus is a click on
        // that button, and must not also select the tile and take over the
        // monitor. A button inside the card wins over the card's own tap.
        .onTapGesture(count: 2) { if !missing { place(asset) } }
        .onTapGesture { tap(asset) }
        .onDrag { dragPayload(asset) }
        .contextMenu { EditorDeferredMenuContent { menu(asset, missing: missing) } }
    }

    private func row(_ asset: MediaAsset) -> some View {
        let missing = isMissing(asset)
        let hovered = hoveredID == asset.id
        let selected = selection.contains(asset.id)
        let favorite = library.isFavorite(absolutePath(asset))
        return HStack(spacing: 8) {
            MediaPreview(asset: asset, isHovered: hovered && !missing)
                .frame(width: 52, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(missing ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if favorite { EditorSymbol("star.fill", size: 8).font(.system(size: 8)).foregroundStyle(EditorTheme.amberAccent) }
                    Text(asset.displayName)
                        .font(.appUI(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(EditorTheme.primaryText)
                        .help(asset.name)
                }
                HStack(spacing: 4) {
                    Text(missing ? appLocalized("文件缺失") : kindName(asset.kind))
                        .foregroundStyle(missing ? RecorderStyle.amberInk : EditorTheme.secondaryText)
                    if !missing, asset.kind == .video || asset.kind == .audio {
                        MediaDurationBadge(path: absolutePath(asset), plain: true)
                    }
                }
                .font(.appUI(size: 11))
            }
            Spacer(minLength: 4)
            if hovered {
                if missing, scope == .project {
                    Button(appLocalized("重新关联")) { relink(asset) }.buttonStyle(.plain).font(.appUI(size: 12, weight: .semibold))
                }
                // Same actions as the grid card, in the same order.
                EditorMediaCardActions(items: cardActions(asset, missing: missing, hovered: hovered, favorite: favorite))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? EditorTheme.selectionWash : hovered ? EditorTheme.chrome(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in hoveredID = inside ? asset.id : (hoveredID == asset.id ? nil : hoveredID) }
        .onTapGesture(count: 2) { if !missing { place(asset) } }
        .onTapGesture { tap(asset) }
        .onDrag { dragPayload(asset) }
        .contextMenu { EditorDeferredMenuContent { menu(asset, missing: missing) } }
    }

    /// Every card in every category offers the same thing: add it at the
    /// playhead, audition a sound, keep it in the library. The star stays
    /// visible once it is on, which is state rather than an invitation.
    private func cardActions(_ asset: MediaAsset, missing: Bool, hovered: Bool,
                             favorite: Bool) -> [EditorMediaCardActions.Item] {
        var items: [EditorMediaCardActions.Item] = []
        if hovered, !missing {
            items.append(.init(id: "place", symbol: "plus", help: "添加到播放头") { place(asset) })
            if asset.kind == .audio {
                let path = absolutePath(asset)
                let playing = audition.playingPath == path
                items.append(.init(id: "audition", symbol: playing ? "stop.fill" : "play.fill",
                                   help: playing ? "停止试听" : "试听") {
                    // One sound at a time, and auditioning says nothing about
                    // what the monitor should be showing.
                    monitor.playback.pause()
                    audition.toggle(path)
                })
            }
        }
        if hovered || favorite {
            items.append(.init(id: "favorite", symbol: favorite ? "star.fill" : "star",
                               help: favorite ? "取消收藏" : "收藏，所有项目都能在素材库里找到它",
                               tint: favorite ? EditorTheme.amberAccent : .white) { toggleFavorite(asset) })
        }
        return items
    }

    @ViewBuilder
    private func menu(_ asset: MediaAsset, missing: Bool) -> some View {
        if !missing { Button(appLocalized("添加到播放头")) { place(asset) } }
        Button(appLocalized(library.isFavorite(absolutePath(asset)) ? "取消收藏" : "收藏")) { toggleFavorite(asset) }
        if scope == .project { Button(appLocalized("重新关联")) { relink(asset) } }
        Button(appLocalized("在访达中显示")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath(asset))])
        }
        Divider()
        let targets = mediaSelection.targets(for: asset.id)
        let title = targets.count > 1 ? "移除所选素材"
            : libraryEntry(asset).map { $0.ownedFiles.isEmpty ? "从素材库移除" : "移到废纸篓" } ?? "从素材箱移除"
        Button(appLocalized(title), role: .destructive) {
            removeSelection(targets)
        }
    }

    private func kindName(_ kind: MediaAssetKind) -> String {
        switch kind {
        case .video: appLocalized("视频")
        case .image: appLocalized("图片")
        case .audio: appLocalized("音频")
        case .animation: appLocalized("动效")
        }
    }

    // MARK: Removal

    /// Delete is how a card is removed; the cards themselves carry no
    /// remove button, so nothing is ever one stray click from going.
    private func deleteSelection() {
        monitor.returnToProgramme()
        if selection.isEmpty, let id = revealedRecordingID, recordings.contains(where: { $0.id == id }) {
            editorStore.removeRecordingSource(id)
        } else { removeSelection() }
    }

    private func removeSelection(_ targets: Set<UUID>? = nil) {
        let selected = targets ?? selection
        guard !selected.isEmpty else { return }
        monitor.returnToProgramme()
        if scope == .library {
            if let path = audition.playingPath, library.entries.contains(where: { selected.contains($0.id) && $0.path == path }) { audition.stop() }
            library.remove(selected)
            selection.subtract(selected)
        } else {
            let sourceIDs = Set(recordingSources.map(\.id)).intersection(selected)
            let assetIDs = Set(allAssets.map(\.id)).intersection(selected)
            if sourceIDs.isEmpty { remove(assetIDs) }
            else {
                editorStore.removeProjectMedia(assets: assetIDs, recordings: sourceIDs) {
                    selection.subtract(selected)
                }
            }
        }
    }

    /// Removing from the bin never touches the file or clips already placed.
    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        monitor.returnToProgramme()
        if let path = audition.playingPath, allAssets.contains(where: { ids.contains($0.id) && ProjectFiles.resolve($0.path) == path }) { audition.stop() }
        withAnimation(.easeOut(duration: 0.18)) {
            commitTimelineEdit(editorStore, action: "移除素材") { $0.mediaAssets.removeAll { ids.contains($0.id) } }
        }
        selection.subtract(ids)
    }

    /// Points the asset and every clip using its old path at the new file.
    private func relink(_ asset: MediaAsset) {
        AppFilePanel.open(configure: { panel in
            panel.message = asset.name
        }) { urls in
            guard let url = urls?.first else { return }
            let old = asset.path, new = ProjectFiles.portable(url.path)
            EditorMediaPresence.shared.invalidate(absolutePath(asset))
            commitTimelineEdit(editorStore, action: "重新关联素材") { timeline in
                if let i = timeline.mediaAssets.firstIndex(where: { $0.id == asset.id }) { timeline.mediaAssets[i].path = new }
                for i in timeline.animationClips.indices where timeline.animationClips[i].sourcePath == old {
                    timeline.animationClips[i].sourcePath = new
                }
                for i in timeline.audioClips.indices where timeline.audioClips[i].sourcePath == old {
                    timeline.audioClips[i].sourcePath = new
                }
                for i in timeline.videoClips.indices where timeline.videoClips[i].sourcePath == old {
                    timeline.videoClips[i].sourcePath = new
                }
            }
        }
    }
}

/// Length of a video or audio file, loaded once and cached.
private struct MediaDurationBadge: View {
    let path: String
    var plain = false
    @State private var seconds: Double?

    var body: some View {
        Group {
            if let seconds {
                let text = Self.format(seconds)
                if plain {
                    Text(text).monospacedDigit()
                } else {
                    EditorMediaTimeBadge(text: text)
                }
            }
        }
        .task(id: path) { seconds = await MediaThumbnailCache.shared.duration(for: path) }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One player for auditioning audio in the bin.
@MainActor
final class MediaAudition: ObservableObject {
    static let shared = MediaAudition()
    @Published private(set) var playingPath: String?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ path: String) {
        if playingPath == path { stop(); return }
        stop()
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in Task { @MainActor in MediaAudition.shared.stop() } }
        player.play()
        self.player = player
        playingPath = path
    }

    func stop() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingPath = nil
    }
}

/// What the file actually looks like: image thumbnail, video frame that
/// follows the pointer, Rive animation that plays while hovered, waveform.
private struct MediaPreview: View {
    let asset: MediaAsset
    let isHovered: Bool
    @State private var still: NSImage?
    @State private var live: NSImage?
    @State private var waveform: [Double] = []
    @State private var skim: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                if let image = live ?? still {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: asset.kind == .animation ? .fit : .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else if asset.kind == .audio {
                    WaveformBars(samples: waveform).padding(.horizontal, 8).padding(.vertical, 10)
                }
                if asset.kind == .video, let skim, isHovered {
                    Rectangle().fill(.white).frame(width: 1.5)
                        .position(x: proxy.size.width * skim, y: proxy.size.height / 2)
                        .frame(height: proxy.size.height)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard asset.kind == .video else { return }
                switch phase {
                case let .active(point): skim = min(max(point.x / max(proxy.size.width, 1), 0), 1)
                case .ended: skim = nil; live = nil
                }
            }
        }
        .task(id: asset.path) {
            switch asset.kind {
            case .audio: waveform = await MediaThumbnailCache.shared.waveform(for: asset)
            default: still = await MediaThumbnailCache.shared.thumbnail(for: asset)
            }
        }
        .task(id: skim.map { Int($0 * 40) }) {
            guard asset.kind == .video, let skim else { return }
            live = await MediaThumbnailCache.shared.videoFrame(for: asset, fraction: skim)
        }
        .task(id: isHovered) {
            guard asset.kind == .animation, isHovered else { live = nil; return }
            await playMotion()
        }
    }

    private var background: some View {
        switch asset.kind {
        case .audio: AnyView(EditorTheme.chrome(0.08))
        case .animation: AnyView(EditorTheme.chrome(0.06))
        default: AnyView(EditorTheme.chrome(0.08))
        }
    }

    /// Plays the motion at ~30 fps on its own instance while hovered.
    @MainActor
    private func playMotion() async {
        let scene0 = MediaThumbnailCache.motionScene(for: asset, at: 0)
        var time = 0.0
        while !Task.isCancelled {
            var scene = scene0
            scene.localTime = time
            if let image = await AnimationFrames.image(
                for: scene, frameRate: 30, pixelSize: CGSize(width: 320, height: 200), projectURL: nil),
               let rendered = MediaThumbnailCache.nsImage(from: image) {
                live = rendered
            }
            try? await Task.sleep(for: .milliseconds(33))
            time += 1.0 / 30
        }
    }
}

struct WaveformBars: View {
    let samples: [Double]
    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let step = size.width / CGFloat(samples.count)
            for (index, value) in samples.enumerated() {
                let height = max(size.height * CGFloat(min(max(value, 0), 1)), 1.5)
                let rect = CGRect(x: CGFloat(index) * step + step * 0.2, y: (size.height - height) / 2,
                                  width: max(step * 0.6, 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.85)))
            }
        }
    }
}

actor MediaThumbnailCache {
    static let shared = MediaThumbnailCache()
    private var images: [String: NSImage] = [:]
    private var waveforms: [String: [Double]] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A preview-only scene with its own renderer instance id per file.
    nonisolated static func motionScene(for asset: MediaAsset, at time: Double) -> FrameAnimationScene {
        var clip = AnimationClip(id: asset.id, timing: OverlayTiming(startTime: 0, duration: 3600), sourcePath: asset.path)
        clip.width = 1
        return FrameAnimationScene(clip: clip, at: time)
    }

    nonisolated static func nsImage(from image: CIImage) -> NSImage? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func thumbnail(for asset: MediaAsset) async -> NSImage? {
        if let cached = images[asset.path] { return cached }
        let url = ProjectFiles.url(asset.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var result: NSImage?
        switch asset.kind {
        case .image:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: 400,
                   kCGImageSourceCreateThumbnailWithTransform: true,
               ] as CFDictionary) {
                result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        case .video:
            result = await videoFrame(for: asset, fraction: 0.1)
        case .animation:
            let scene = Self.motionScene(for: asset, at: 1)
            if let image = await AnimationFrames.image(
                for: scene, frameRate: 30, pixelSize: CGSize(width: 320, height: 200), projectURL: nil) {
                result = Self.nsImage(from: image)
            }
        case .audio:
            return nil
        }
        if let result { images[asset.path] = result }
        return result
    }

    func videoFrame(for asset: MediaAsset, fraction: Double) async -> NSImage? {
        await Self.frame(path: ProjectFiles.resolve(asset.path), fraction: fraction)
    }

    private nonisolated static func frame(path: String, fraction: Double) async -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: max(duration * fraction, 0), preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private var durations: [String: Double] = [:]

    func duration(for path: String) async -> Double? {
        if let cached = durations[path] { return cached }
        guard let seconds = try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        durations[path] = seconds
        return seconds
    }

    func waveform(for asset: MediaAsset) async -> [Double] {
        if let cached = waveforms[asset.path] { return cached }
        let samples = (try? await MediaAnalyzer.waveform(ProjectFiles.url(asset.path), sampleCount: 48)) ?? []
        waveforms[asset.path] = samples
        return samples
    }
}

extension EditorStore {
    /// Removes bin entries that nothing on the timeline uses (images are
    /// copied into stickers on placement, so they never count as used).
    func removeUnusedMedia() {
        let timeline = project.timeline
        let used = Set(timeline.animationClips.map(\.sourcePath) + timeline.audioClips.map(\.sourcePath)
            + timeline.videoClips.map(\.sourcePath))
        commitTimelineEdit(self, action: "移除未使用的素材") { $0.mediaAssets.removeAll { !used.contains($0.path) } }
    }

    func removeAllMedia() {
        commitTimelineEdit(self, action: "移除素材") { $0.mediaAssets.removeAll() }
    }
}

/// Filter, tile size and view mode, pinned to the bottom of the media page.
struct EditorMediaBottomBar: View {
    @ObservedObject var editorStore: EditorStore
    @AppStorage("editor.mediaLibrary.filter") private var filterRaw = ""
    @AppStorage("editor.mediaLibrary.list") private var showsList = false
    @AppStorage("editor.mediaLibrary.tileWidth") private var tileWidth = 120.0

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 4)
            toggle(.grid, label: "网格", active: !showsList) { showsList = false }
            toggle(.list, label: "列表", active: showsList) { showsList = true }
            EditorActionMenu(title: "素材箱", items: [
                .action("放大缩略图", isEnabled: !showsList && tileWidth < 200) { tileWidth = min(tileWidth + 30, 200) },
                .action("缩小缩略图", isEnabled: !showsList && tileWidth > 80) { tileWidth = max(tileWidth - 30, 80) },
                .separator,
                .action("移除未使用的素材") { editorStore.removeUnusedMedia() },
                .action("全部移除…") { confirmRemoveAll() }
            ]) {
                EditorToolbarIconSurface(systemName: "ellipsis")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(EditorTheme.panelSurface)
        .overlay(alignment: .top) { Rectangle().fill(EditorTheme.hairline).frame(height: 1) }
    }

    private func confirmRemoveAll() {
        Task { @MainActor in
            let response = await AppDialogPresenter.response(to: AppDialog(
                title: "移除全部素材？",
                message: "只从素材箱移除，不删除文件，也不影响已放到时间线上的片段。可以撤销。",
                symbol: "trash",
                actions: [
                    .init(id: "cancel", title: "取消", role: .cancel),
                    .init(id: "remove", title: "全部移除", role: .destructive)
                ]
            ))
            if response.actionID == "remove" { editorStore.removeAllMedia() }
        }
    }

    private func chip(_ raw: String, _ title: String) -> some View {
        let selected = filterRaw == raw
        return Button { filterRaw = raw } label: {
            Text(appLocalized(title))
                .font(.appUI(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).fill(selected ? EditorTheme.selectionWash : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ icon: AppLineIcon.Kind, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppLineIcon(kind: icon, size: 13)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).fill(active ? EditorTheme.selectionWash : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? EditorTheme.primaryText : EditorTheme.secondaryText)
        .help(appLocalized(label))
        .accessibilityLabel(appLocalized(label))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Removing from the library touches files, which the timeline's ⌘Z cannot
/// put back, so the removal says what it did and offers one click back.
private struct EditorLibraryRemovalNotice: View {
    @ObservedObject private var library = AssetLibrary.shared

    var body: some View {
        if let removal = library.lastRemoval {
            let count = removal.entries.count
            HStack(spacing: 8) {
                Text(removal.trashed.isEmpty
                     ? String(format: appLocalized("已从素材库移除 %ld 项"), count)
                     : String(format: appLocalized("已从素材库移除 %ld 项，文件已移到废纸篓"), count))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(appLocalized("撤销")) { library.undoLastRemoval() }.buttonStyle(.editorGhost)
            }
            .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 6)
            .modifier(EditorFloatingSurface())
            .padding(.horizontal, 12).padding(.bottom, 10)
            .transition(.opacity)
            .task(id: removal) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                library.forgetLastRemoval()
            }
        }
    }
}

/// A library tab: the whole tab (not just its word) is the target, with a
/// soft hover wash so it is obvious what a click will hit.
private struct LibraryTabButton: View {
    let title: String
    let selected: Bool
    let underline: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.appUI(size: 14, weight: selected ? .semibold : .regular))
                // A narrow panel must never stack a two-character tab name
                // vertically; the row gives up its own labels instead.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(selected || hovered ? EditorTheme.primaryText : EditorTheme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(selected ? EditorTheme.selectionWash : hovered ? EditorTheme.chrome(EditorStateWash.hover * 0.6) : .clear)
                        .matchedGeometryEffect(id: selected ? "underline" : "hover-\(title)", in: underline)
                        .padding(.vertical, 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside }
        .animation(SpringMotion.micro, value: hovered)
    }
}


/// File presence for media tiles, checked once per path and refreshed when
/// the app returns to the foreground; a tile never touches the disk in body.
@MainActor
final class EditorMediaPresence {
    static let shared = EditorMediaPresence()
    private var missing: [String: Bool] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.missing.removeAll() }
        }
    }

    func isMissing(_ path: String) -> Bool {
        if let known = missing[path] { return known }
        let value = !FileManager.default.fileExists(atPath: path)
        missing[path] = value
        return value
    }

    func invalidate(_ path: String) { missing.removeValue(forKey: path) }
}

/// The grid's own width, so adaptive columns can be clamped to what the panel
/// actually offers rather than to the remembered thumbnail size.
private struct EditorMediaGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
