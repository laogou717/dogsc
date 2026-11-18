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
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController

    let pointerEvents: [PointerEventRecord]
    let cursorAssets: [ResolvedCursorAsset]
    @Binding var selectedInspector: InspectorTab
    @Binding var isCameraSyncEditing: Bool
    @Binding var visibleTimelineTracks: EditorTimelineTrackVisibility
    let isCropping: Bool
    @Binding var cropDraft: NormalizedCrop
    /// Parameter panel width. Tool navigation is owned by the workspace.
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    /// Direction of the last tool change on the rail, so pages arrive from it.
    var tabMovesDown = true
    let onChooseWallpaper: () -> BackgroundSource?
    let onError: (String) -> Void

    @State var savedLayoutPresets: [SavedLayoutPreset] = []
    @State var isNamingLayoutPreset = false
    @State var layoutPresetName = ""
    @State var motionInspectorMode = EditorMotionInspectorMode.zoom
    @State var selectedFrameInspectorTab = FrameInspectorTab.background
    @State var savedLayoutPresetMenuHovered = false
    @State private var scrollPositions = AppScrollPositionMemory<EditorInspectorScrollContext>()
    @StateObject private var systemWallpaperCatalog = SystemWallpaperCatalog()
    /// Set only while a frame sub-page change is being presented.
    @State private var frameTabDrift: CGFloat?
    @State private var settledPageKey = ""


    init(
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        pointerEvents: [PointerEventRecord],
        selectedInspector: Binding<InspectorTab>,
        isCameraSyncEditing: Binding<Bool>,
        visibleTimelineTracks: Binding<EditorTimelineTrackVisibility>,
        isCropping: Bool,
        cropDraft: Binding<NormalizedCrop>,
        contentWidth: CGFloat = EditorInspectorSizing.defaultContentWidth,
        contentHeight: CGFloat = .infinity,
        tabMovesDown: Bool = true,
        onChooseWallpaper: @escaping () -> BackgroundSource?,
        onError: @escaping (String) -> Void
    ) {
        _editorStore = ObservedObject(wrappedValue: editorStore)
        _mediaSession = ObservedObject(wrappedValue: mediaSession)
        _playbackController = ObservedObject(wrappedValue: playbackController)
        self.pointerEvents = pointerEvents
        cursorAssets = CursorAssetLibrary.availableAssets
        _selectedInspector = selectedInspector
        _isCameraSyncEditing = isCameraSyncEditing
        _visibleTimelineTracks = visibleTimelineTracks
        self.isCropping = isCropping
        _cropDraft = cropDraft
        self.contentWidth = EditorInspectorSizing.clampedContentWidth(contentWidth)
        self.contentHeight = contentHeight
        self.tabMovesDown = tabMovesDown
        self.onChooseWallpaper = onChooseWallpaper
        self.onError = onError
    }

    var playbackTime: TimeInterval { playbackController.outputTime }

    var sourceInventory: MediaAssetInventory { mediaSession.inventories.source }
    var cameraInventory: MediaAssetInventory { mediaSession.inventories.camera }
    var microphoneInventory: MediaAssetInventory { mediaSession.inventories.microphone }
    var sourcePixelSize: CGSize { mediaSession.sourceDisplaySize }
    var timelineDuration: TimeInterval { mediaSession.outputDuration }
    var sourceHasAudio: Bool { sourceInventory.hasAudio }
    var cameraHasVideo: Bool { cameraInventory.hasVideo }
    var microphoneHasAudio: Bool { microphoneInventory.hasAudio }

    /// Primary-clip selection normally routes to audio. The selected task owns
    /// its panel content; audio uses the selected clip as its editing scope.
    private var primarySelectionKeepsInspectorTask: Bool {
        guard case .primarySegment = editorStore.selection else { return false }
        return selectedInspector != .frame
    }

    private func header(for tab: InspectorTab) -> (title: String, scope: String?) {
        if tab == .audio,
           case let .primarySegment(id) = editorStore.selection,
           let context = primarySegmentContext(id: id) {
            return ("声音", String(format: appLocalized("第 %lld 段"), context.index + 1))
        }
        switch tab {
        case .frame: return ("画面", "全片")
        case .opening: return ("开场", "全片")
        case .zoom: return ("运镜", "缩放")
        case .cursor: return ("光标", "全片")
        case .camera: return ("摄像头", "全片基础布局")
        case .audio: return ("声音", "全片")
        }
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
        .onChange(of: editorStore.selection) { _, selection in
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

    private var showsFrameInspectorNavigation: Bool {
        guard selectedInspector == .frame, !isCropping else { return false }
        switch editorStore.selection {
        case .canvas, .screen, nil:
            return true
        default:
            return false
        }
    }

    private var frameInspectorNavigation: some View {
        EditorSegmentedControl(
            options: FrameInspectorTab.allCases,
            title: { $0.localizedLabel },
            icon: { $0.icon },
            selection: Binding(
                get: { selectedFrameInspectorTab },
                set: { next in
                    // Sub-pages sit side by side: the next one arrives from its side.
                    let order = FrameInspectorTab.allCases
                    let forward = (order.firstIndex(of: next) ?? 0) > (order.firstIndex(of: selectedFrameInspectorTab) ?? 0)
                    frameTabDrift = forward ? 18 : -18
                    selectedFrameInspectorTab = next
                }
            )
        )
        .padding(.horizontal, EditorInterfaceSpacing.inspectorInset)
        .padding(.top, EditorInspectorRhythm.scrollTop)
        .padding(.bottom, EditorInspectorRhythm.titleGap - EditorInspectorRhythm.scrollTop)
        .accessibilityIdentifier("editor.inspector.frame-subnavigation")
    }

    private var pageSwapEdge: Edge {
        if let frameTabDrift { return frameTabDrift > 0 ? .trailing : .leading }
        return tabMovesDown ? .bottom : .top
    }

    private var headerIcon: AppLineIcon.Kind {
        if isCropping { return .crop }
        switch editorStore.selection {
        case .mosaic: return .grid
        case .sticker: return .scene
        case .crop: return .crop
        default: return selectedInspector.lineIcon
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

    var inspector: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    EditorRollingTitle(
                        text: appLocalized(inspectorHeader.title),
                        size: usesCompactInspectorChrome ? 26 : 34
                    )
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let scope = inspectorHeader.scope {
                        Text(appLocalized(scope))
                            .font(.appUI(size: 12, weight: .medium))
                            .foregroundStyle(EditorTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(EditorTheme.chrome(0.06), in: Capsule(style: .continuous))
                            .padding(.bottom, 5)
                            .id(scope)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                .padding(.horizontal, EditorInterfaceSpacing.inspectorInset + 4)
                .frame(height: usesCompactInspectorChrome ? 42 : 54, alignment: .bottom)
                // Every page keeps the same 14 pt between its title and the
                // first thing under it (sub-navigation or content).
                .padding(.bottom, EditorInspectorRhythm.titleGap - EditorInspectorRhythm.scrollTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(inspectorTitle)
                .accessibilityAddTraits(.isHeader)

                if showsFrameInspectorNavigation {
                    frameInspectorNavigation
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }

            ZStack(alignment: .top) {
                AppKeyboardFocusScrollView(
                    savedPosition: scrollPositions.position(for: inspectorScrollContext)
                ) {
                    VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) { inspectorContent }
                        .padding(.horizontal, EditorInterfaceSpacing.inspectorInset)
                        .padding(.top, EditorInspectorRhythm.scrollTop)
                        .padding(.bottom, usesCompactInspectorChrome ? 10 : 20)
                        .coordinateSpace(name: EditorConsole.scrollSpace)
                        .consolePageArrival()
                }
                .scrollIndicators(.hidden)
                .id(inspectorScrollContext)
                .transition(.consolePage)
            }
            .modifier(EditorScrollEdgeFade(top: 8, bottom: showsBackgroundFooter ? 10 : 18))
            .clipped()
            if showsBackgroundFooter {
                backgroundBlurSection
                    .padding(.horizontal, EditorInterfaceSpacing.inspectorInset)
                    .padding(.top, 4)
                    .padding(.bottom, usesCompactBackgroundLayout ? 10 : 16)
            }
        }
        .frame(width: contentWidth)
        // The floating island beneath owns the lit material; an opaque fill
        // here would flatten its gradient into a single tone.
        .background(Color.clear)
        .animation(SpringMotion.crossfade, value: inspectorTitle)
        .animation(SpringMotion.settle, value: showsFrameInspectorNavigation)
        .environment(\.consoleReveal, settledPageKey != consolePageKey)
        .task(id: consolePageKey) { await settleConsolePage(consolePageKey) }
        .onChange(of: selectedFrameInspectorTab) { _, _ in frameTabDrift = nil }
        .onChange(of: selectedInspector) { _, _ in frameTabDrift = nil }
    }

    /// Changes with the task (and the frame sub-page): the moment modules
    /// assemble and knobs sweep. It settles a moment later so selecting a
    /// different clip inside the same page never replays the arrival.
    private var consolePageKey: String {
        "\(selectedInspector.rawValue)|\(selectedInspector == .frame ? String(describing: selectedFrameInspectorTab) : "")"
    }

    private func settleConsolePage(_ key: String) async {
        guard !Task.isCancelled, key == consolePageKey else { return }
        settledPageKey = ""
        do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
        guard !Task.isCancelled, key == consolePageKey else { return }
        settledPageKey = key
    }

    private var showsBackgroundFooter: Bool {
        showsFrameInspectorNavigation && selectedFrameInspectorTab == .background
            && editorStore.previewProject.canvas.backgroundSource.usesWallpaperMedia
    }

    var inspectorHeader: (title: String, scope: String?) {
        if isCropping { return ("裁切", "屏幕素材") }
        if primarySelectionKeepsInspectorTask {
            return header(for: selectedInspector)
        }
        if selectedInspector == .opening,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return ("开场", "全片")
        }
        switch editorStore.selection {
        case .canvas:
            return ("画面", "全片")
        case .screen:
            return ("屏幕素材", "全片基础布局")
        case .primarySegment:
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
            return ("光标", "全片")
        case .camera:
            return ("摄像头", "全片基础布局")
        case .cameraMotion:
            return ("摄像头", "动画目标")
        case .audio:
            return ("声音", "全片")
        case .crop:
            return ("裁切", "屏幕素材")
        case let .mosaic(id):
            let style = editorStore.previewProject.timeline.mosaicClips.first(where: { $0.id == id })?.style
            return (style.map { $0 == .spotlight ? "突出" : "柔化" } ?? "区域效果", "选中区域")
        case .sticker:
            return ("贴图", "选中图片")
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
           (selection == .canvas || selection == .screen) {
            return .frameTab(selectedFrameInspectorTab)
        }
        let kind: EditorInspectorSelectionKind
        switch selection {
        case .canvas: kind = .canvas
        case .screen: kind = .screen
        case .primarySegment: kind = .primarySegment
        case .crop: kind = .crop
        case .zoomTrack: kind = .zoomTrack
        case .zoom: kind = .zoom
        case .screenMotionTrack: kind = .screenMotionTrack
        case .screenMotion: kind = .screenMotion
        case .cursor: kind = .cursor
        case .camera: kind = .camera
        case .cameraMotion: kind = .cameraMotion
        case .audio: kind = .audio
        case .mosaic: kind = .mosaic
        case .sticker: kind = .sticker
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
        } else if case let .primarySegment(id) = editorStore.selection,
                  selectedInspector == .frame {
            // 选中主片段给真正的片段面板：此前标题写着"当前片段"，内容却是
            // 全片初始状态控件，名实不符。
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
                EditorFramePreview(
                    canvas: editorStore.previewProject.canvas,
                    screenImage: playbackController.pausedScreenImage,
                    wallpaper: currentWallpaperAsset
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
        switch editorStore.previewProject.canvas.backgroundSource {
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
        let hasOpeningCamera = cameraHasVideo && !editorStore.previewProject.camera.isHidden
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
        case .converge: return "arrow.down.right.and.arrow.up.left"
        case .sideSlide: return "arrow.left.and.right"
        case .light3D: return "cube.transparent"
        }
    }

    func openingElementIcon(_ element: OpeningSequenceElement) -> String {
        switch element {
        case .screen: return "rectangle.on.rectangle"
        case .camera: return "video.fill"
        case .stickers: return "photo.on.rectangle.angled"
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

    var canvasLayoutSection: some View {
        EditorInspectorSection("画面留白") {
            sliderRow("边距", value: canvasBinding(\.padding, actionName: "调整画布边距"),
                      range: 0...360, format: .points)
        }
    }

    var screenMaterialLayoutSection: some View {
        EditorInspectorSection("位置与大小") {
            EditorTransactionalPositionPad(
                editorStore: editorStore,
                title: "素材位置",
                point: canvasBinding(\.contentPosition, actionName: "移动屏幕素材"),
                commandScope: .canvas,
                actionName: "移动屏幕素材",
                compactLayout: true,
                onError: onError
            )
            sliderRow("素材缩放", value: canvasBinding(\.contentScale, actionName: "缩放屏幕素材"),
                      range: 0.25...4, format: .multiplier)
            HStack {
                Spacer(minLength: 8)
                Button("恢复位置与大小") {
                    var canvas = editorStore.project.canvas
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
    var screenSurfaceAppearanceSection: some View {
        let canvas = editorStore.previewProject.canvas
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
                        value: canvasBinding(\.cornerRadius, actionName: "调整画面圆角"),
                        range: 0...160, format: .points
                    )
                } else {
                    knob(
                        "内容圆角", label: "圆角",
                        value: screenFrameRadiusBinding(
                            \.screenFrameContentCornerRadius,
                            fallback: canvas.screenFrame.defaultContentCornerRadius,
                            actionName: "调整样机内容圆角"
                        ),
                        range: 0...160, format: .points
                    )
                }
                knob(
                    "外描边", label: "描边",
                    value: canvasBinding(\.borderWidth, actionName: "调整屏幕描边"),
                    range: 0...40, format: .points
                )
                knob(
                    "阴影强度", label: "阴影",
                    value: canvasBinding(\.shadowStrength, actionName: "调整屏幕阴影"),
                    range: 0...1, format: .percent
                )
            }
            if canvas.borderWidth > 0 {
                EditorTransactionalColorInput(
                    editorStore: editorStore,
                    title: "描边颜色",
                    value: canvasBinding(
                        \.borderColor,
                        actionName: "调整描边颜色"
                    ),
                    commandScope: .canvas,
                    actionName: "调整描边颜色",
                    onError: onError
                )
                sliderRow(
                    "描边不透明度",
                    value: canvasBinding(\.insetOpacity, actionName: "调整描边不透明度"),
                    range: 0...1,
                    format: .percent
                )
            }
        }
    }

    var screenMockupSection: some View {
        VStack(alignment: .leading, spacing: 14) {

            EditorInspectorSection("样机", showsTitle: false) {
                EditorScreenFramePicker(editorStore: editorStore,
                                        screenImage: playbackController.pausedScreenImage,
                                        onError: onError)

                if editorStore.previewProject.canvas.screenFrame != .none {
                    EditorKnobRow {
                        knob(
                            "框体比例",
                            value: canvasBinding(\.screenFrameScale, actionName: "调整屏幕样机大小"),
                            range: 0.6...1.6, format: .multiplier
                        )
                        if editorStore.previewProject.canvas.screenFrame.isWindowFrame
                            || editorStore.previewProject.canvas.screenFrame.isBrowserFrame {
                            knob(
                                "顶栏高度",
                                value: canvasBinding(\.screenFrameToolbarScale, actionName: "调整样机顶栏高度"),
                                range: 0.65...1.6, format: .multiplier
                            )
                        }
                        knob(
                            "框体外圆角", label: "外圆角",
                            value: screenFrameRadiusBinding(
                                \.screenFrameOuterCornerRadius,
                                fallback: editorStore.previewProject.canvas.screenFrame
                                    .defaultOuterCornerRadius,
                                actionName: "调整样机外圆角"
                            ),
                            range: 0...160, format: .points
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
        let optionalBinding = canvasBinding(keyPath, actionName: actionName)
        return Binding(
            get: { optionalBinding.wrappedValue ?? fallback },
            set: { optionalBinding.wrappedValue = $0 }
        )
    }


    var cropInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSymbolLabel("在画面上拖动边缘或四角，拖动框内可整体移动。", systemImage: "crop")
                .font(.appUI(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                cropEdgeStepper("左", edge: .left, pixels: sourcePixelSize.width)
                cropEdgeStepper("右", edge: .right, pixels: sourcePixelSize.width)
            }
            HStack(spacing: 8) {
                cropEdgeStepper("上", edge: .top, pixels: sourcePixelSize.height)
                cropEdgeStepper("下", edge: .bottom, pixels: sourcePixelSize.height)
            }

            Divider().overlay(dividerColor)

            LabeledContent("裁切后尺寸") {
                Text(cropSizeText).monospacedDigit()
            }
            .font(.appUI(size: 11))

        }
    }

    func cropEdgeStepper(_ title: String, edge: CropEdge, pixels: CGFloat) -> some View {
        let pixelBinding = cropPixelBinding(edge, pixels: pixels)
        let maximumPixels = cropMaximumPixelValue(edge, pixels: pixels)
        let current = pixelBinding.wrappedValue
        return VStack(alignment: .leading, spacing: 4) {
            Text(appLocalized(title))
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(EditorTheme.secondaryText)
                .fixedSize()
            EditorNumericStepControl(
                title,
                valueText: "\(current) px",
                accessibilityTitle: "\(title)侧裁切",
                canDecrease: current > 0,
                canIncrease: current < maximumPixels,
                onDecrease: {
                    pixelBinding.wrappedValue = max(pixelBinding.wrappedValue - 1, 0)
                },
                onIncrease: {
                    pixelBinding.wrappedValue = min(pixelBinding.wrappedValue + 1, maximumPixels)
                },
                editConfiguration: EditorNumericStepEditConfiguration(
                    draftText: "\(current)",
                    onPreview: { text in
                        guard let value = cropPixelInputValue(text) else {
                            return false
                        }
                        pixelBinding.wrappedValue = min(max(value, 0), maximumPixels)
                        return true
                    },
                    onCancel: { originText in
                        guard let value = cropPixelInputValue(originText) else {
                            return
                        }
                        pixelBinding.wrappedValue = min(max(value, 0), maximumPixels)
                    }
                ),
                showsTitle: false
            )
        }
    }

    func cropMaximumPixelValue(_ edge: CropEdge, pixels: CGFloat) -> Int {
        let dimension = max(Double(pixels), 1)
        let crop = cropDraft.clamped()
        let opposite: Double
        switch edge {
        case .left: opposite = crop.right
        case .right: opposite = crop.left
        case .top: opposite = crop.bottom
        case .bottom: opposite = crop.top
        }
        let minimum = min(max(24 / dimension, 0.001), 0.5)
        return max(Int(floor((1 - opposite - minimum) * dimension)), 0)
    }

    func cropPixelInputValue(_ text: String) -> Int? {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        for token in ["像素", "pixels", "pixel", "px"] {
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(normalized), value.isFinite else { return nil }
        return Int(value.rounded())
    }

    func cropPixelBinding(_ edge: CropEdge, pixels: CGFloat) -> Binding<Int> {
        Binding(
            get: { cropPixelValue(edge, pixels: pixels) },
            set: { newValue in
                let dimension = max(Double(pixels), 1)
                let normalized = min(max(Double(newValue) / dimension, 0), 1)
                let current = cropDraft.clamped()
                var left = current.left
                var right = current.right
                var top = current.top
                var bottom = current.bottom
                let minimum = min(max(24 / dimension, 0.001), 0.5)
                switch edge {
                case .left:
                    left = min(normalized, max(1 - right - minimum, 0))
                case .right:
                    right = min(normalized, max(1 - left - minimum, 0))
                case .top:
                    top = min(normalized, max(1 - bottom - minimum, 0))
                case .bottom:
                    bottom = min(normalized, max(1 - top - minimum, 0))
                }
                cropDraft = .fromEdges(left: left, right: right, top: top, bottom: bottom)
            }
        )
    }

    func cropPixelValue(_ edge: CropEdge, pixels: CGFloat) -> Int {
        let crop = cropDraft.clamped()
        let value: Double
        switch edge {
        case .left: value = crop.left
        case .right: value = crop.right
        case .top: value = crop.top
        case .bottom: value = crop.bottom
        }
        return max(Int((value * Double(max(pixels, 1))).rounded()), 0)
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
        let fullSourceDuration: TimeInterval
        let frameDuration: TimeInterval
    }

    func primarySegmentContext(id: UUID) -> PrimarySegmentPanelContext? {
        guard let map = mediaSession.mediaPlan?.timelineMap,
              let index = map.segments.firstIndex(where: { $0.id == id }) else { return nil }
        let junctions = EditorPrimaryTimelinePresentation.segmentJunctions(from: map)
        let frameRate = max(editorStore.project.capture.captureFrameRate.rawValue, 1)
        return PrimarySegmentPanelContext(
            segment: map.segments[index],
            index: index,
            total: map.segments.count,
            junctionBefore: junctions.first { $0.nextSegmentID == id },
            junctionAfter: junctions.first { $0.previousSegmentID == id },
            leadingGap: EditorPrimaryTimelinePresentation.leadingGap(from: map),
            trailingGap: EditorPrimaryTimelinePresentation.trailingGap(from: map),
            fullSourceDuration: map.fullSourceDuration,
            frameDuration: 1 / Double(frameRate)
        )
    }

    /// 选中主片段时的专属面板。此前这里显示的是全片初始状态控件，标题却
    /// 写着"当前片段"，名实不符；现在给片段自己的信息与操作，与时间线
    /// 手势/快捷键共享同一组 EditorStore 命令。
    @ViewBuilder
    func primarySegmentInspector(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context = primarySegmentContext(id: id) {
                EditorInspectorSection("片段信息", icon: "film") {
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

                    if let map = mediaSession.mediaPlan?.timelineMap {
                        EditorSegmentMap(
                            segments: map.segments,
                            selectedIndex: context.index,
                            totalDuration: map.segments.last?.outputEnd
                                ?? context.fullSourceDuration
                        )
                        .padding(.vertical, 2)
                    }

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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                EditorInspectorSection("片段操作", icon: "scissors") {
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
                                "还原之前的剪切（已剪 \(segmentTimestamp(junctionBefore.removedDuration))）",
                                icon: "arrow.uturn.backward"
                            ) {
                                restorePrimaryGapFromInspector(
                                    junction: junctionBefore,
                                    fullSourceDuration: context.fullSourceDuration
                                )
                            }
                        }

                        if let junctionAfter = context.junctionAfter {
                            if junctionAfter.hasRemovedSourceGap {
                                segmentActionRow(
                                    "还原之后的剪切（已剪 \(segmentTimestamp(junctionAfter.removedDuration))）",
                                    icon: "arrow.uturn.backward"
                                ) {
                                    restorePrimaryGapFromInspector(
                                        junction: junctionAfter,
                                        fullSourceDuration: context.fullSourceDuration
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
                                        fullSourceDuration: context.fullSourceDuration,
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
                                        fullSourceDuration: context.fullSourceDuration,
                                        actionName: "还原结尾剪切"
                                    )
                                } catch {
                                    onError(error.localizedDescription)
                                }
                            }
                        }

                        segmentActionRow(
                            "删除这个片段",
                            icon: "trash",
                            destructive: true
                        ) {
                            deletePrimarySegmentFromInspector(context: context)
                        }
                    }
                    .padding(4)
                    .background(EditorTheme.cardFill, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(title)
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
                fullSourceDuration: context.fullSourceDuration,
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
                fullSourceDuration: context.fullSourceDuration,
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
        fullSourceDuration: TimeInterval
    ) {
        do {
            try editorStore.restorePrimaryGap(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                fullSourceDuration: fullSourceDuration,
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
                fullSourceDuration: context.fullSourceDuration,
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
                    sourceImage: playbackController.pausedScreenImage,
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
        EditorInspectorSection("运镜类型") {
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
                    .appButtonKeyboardFocus(in: Capsule(style: .continuous))
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
                .appButtonKeyboardFocus(in: Capsule(style: .continuous))
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
                            .font(.appUI(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("显示缩放轨道") {
                            visibleTimelineTracks.insert(.zoom)
                        }
                        .buttonStyle(.editorQuiet)
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
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EditorTheme.cardFill, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
                }

                motionGlobalDefaults
            }
        }
    }

    @ViewBuilder
    var motionGlobalDefaults: some View {
        EditorDisclosure(
            "新动画过渡",
            detail: EditorSliderValueFormat.seconds.text(
                for: editorStore.previewProject.motion.defaultZoomTransitionDuration
            )
        ) {
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
