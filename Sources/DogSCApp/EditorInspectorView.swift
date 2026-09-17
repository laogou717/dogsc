import AppKit
import Foundation
import RecorderCore
import SwiftUI

enum EditorMotionInspectorMode: String, CaseIterable, Identifiable {
    case zoom
    case screen3D

    var id: String { rawValue }
}

private enum EditorInspectorPresentationIdentity: Hashable {
    case crop
    case selection(EditorSelection)
    case tab(InspectorTab)
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

enum EditorInspectorScrollAnchor: Hashable {
    case top
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
    let onChooseWallpaper: () -> BackgroundSource?
    let onChooseDesktopWallpaper: () -> BackgroundSource?
    let onError: (String) -> Void

    @State var savedLayoutPresets: [SavedLayoutPreset] = []
    @State var isNamingLayoutPreset = false
    @State var layoutPresetName = ""
    @State var motionInspectorMode = EditorMotionInspectorMode.zoom
    @State var selectedFrameInspectorTab = FrameInspectorTab.background
    @State var savedLayoutPresetMenuHovered = false


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
        onChooseWallpaper: @escaping () -> BackgroundSource?,
        onChooseDesktopWallpaper: @escaping () -> BackgroundSource?,
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
        self.onChooseWallpaper = onChooseWallpaper
        self.onChooseDesktopWallpaper = onChooseDesktopWallpaper
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

    /// Selecting another primary clip must not replace a global inspector task
    /// the user deliberately kept open. The frame tab remains the one place
    /// where primary selection opens the clip-specific panel.
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
        return switch tab {
        case .frame: ("画面", "全片")
        case .opening: ("开场", "全片")
        case .zoom: ("运镜", "缩放")
        case .cursor: ("光标", "全片")
        case .camera: ("摄像头", "全片基础布局")
        case .audio: ("声音", "全片")
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
            selection: $selectedFrameInspectorTab
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(panelBackground)
        .overlay(alignment: .bottom) {
            Divider().overlay(dividerColor)
        }
        .accessibilityIdentifier("editor.inspector.frame-subnavigation")
    }

    var inspector: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Text(appLocalized(inspectorHeader.title))
                        .font(.appUI(size: 17, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.94))
                    if let scope = inspectorHeader.scope {
                        Text(appLocalized(scope))
                            .font(.appUI(size: 10.5, weight: .semibold))
                            .foregroundStyle(EditorTheme.platinumMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 23)
                            .background(
                                EditorTheme.chrome(0.065),
                                in: Capsule(style: .continuous)
                            )

                        }
                    Spacer()
                }
                .id(inspectorPresentationIdentity)
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.97, anchor: .leading)
                    )
                )
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(panelBackground)
            .overlay(alignment: .bottom) {
                Divider().overlay(dividerColor)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(inspectorTitle)
            .animation(SpringMotion.fluid, value: inspectorPresentationIdentity)

            if showsFrameInspectorNavigation {
                frameInspectorNavigation
            }

            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { inspectorContent }
                        .padding(.horizontal, 22).padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
                .id(inspectorScrollContext)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 10)),
                    removal: .opacity.combined(with: .offset(y: -5))))
            }
            .clipped()
            .animation(SpringMotion.fluid, value: inspectorScrollContext)
            if showsFrameInspectorNavigation, selectedFrameInspectorTab == .background,
               editorStore.previewProject.canvas.backgroundSource.usesWallpaperMedia {
                backgroundBlurSection
                    .padding(.horizontal, 22).padding(.bottom, 14)
                    .background(panelBackground)
            }
        }
        .frame(width: contentWidth)
        .background(panelBackground)
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
        case .mosaic:
            return ("打码", "选中区域")
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

    private var inspectorPresentationIdentity: EditorInspectorPresentationIdentity {
        if isCropping { return .crop }
        if primarySelectionKeepsInspectorTask {
            return .tab(selectedInspector)
        }
        if selectedInspector == .opening,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return .tab(selectedInspector)
        }
        if let selection = editorStore.selection { return .selection(selection) }
        return .tab(selectedInspector)
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
        switch selectedFrameInspectorTab {
        case .background:
            VStack(alignment: .leading, spacing: 14) {
            EditorBackgroundInspector(
                editorStore: editorStore,
                onChooseWallpaper: onChooseWallpaper,
                onChooseDesktopWallpaper: onChooseDesktopWallpaper,
                onError: onError
            )
                if !showsFrameInspectorNavigation { backgroundBlurSection }
            }
        case .layout:
            VStack(alignment: .leading, spacing: 14) {
                canvasLayoutSection
                screenMaterialLayoutSection
                screenSurfaceAppearanceSection
            }
        case .mockup:
            screenMockupSection
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
        return EditorInspectorSection("全局开场", icon: "sparkles.rectangle.stack") {
            EditorToggle(
                isOn: openingBinding(
                    \.isEnabled,
                    actionName: sequence.isEnabled ? "关闭全局开场" : "启用全局开场"
                ),
                title: "让所有元素有序进入画面"
            )

            if sequence.isEnabled {
                VStack(alignment: .leading, spacing: 7) {
                    Text("开场方式")
                        .font(.appUI(.caption2, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.62))
                    EditorTileSelector(
                        options: OpeningSequencePreset.allCases,
                        title: { appLocalized($0.rawValue) },
                        icon: openingPresetIcon,
                        selection: openingBinding(\.preset, actionName: "更换开场方式"),
                        columnCount: 3
                    )
                    Text(sequence.motionCurve.editorDetail)
                        .font(.appUI(.caption2))
                        .foregroundStyle(EditorTheme.chrome(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("动效节奏")
                        .font(.appUI(.caption2, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.62))
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

                sliderRow(
                    "总时长",
                    value: openingBinding(\.duration, actionName: "调整开场总时长"),
                    range: 0.4...8,
                    interactionScope: .project,
                    format: .seconds
                )
                if sequence.includedElements.count > 1 {
                    sliderRow(
                        "元素间隔",
                        value: openingBinding(\.stagger, actionName: "调整开场元素间隔"),
                        range: 0...sequence.maximumStagger(
                            for: sequence.includedElements.count
                        ),
                        interactionScope: .project,
                        format: .seconds
                    )
                } else {
                    Text("只有一个元素参与时无需设置间隔。")
                        .font(.appUI(.caption2))
                        .foregroundStyle(EditorTheme.chrome(0.48))
                }

                EditorDisclosure(
                    "参与元素与顺序",
                    detail: "\(sequence.includedElements.count) 项参与",
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
                    Label("从片头预览", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)

                Text("柔化和突出从首帧保持生效；从 0 秒开始的贴图自身入场由全局开场接管，避免两套动画叠加。")
                    .font(.appUI(.caption2))
                    .foregroundStyle(EditorTheme.chrome(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func openingElementRow(
        _ element: OpeningSequenceElement,
        order: [OpeningSequenceElement]
    ) -> some View {
        let index = order.firstIndex(of: element) ?? 0
        return HStack(spacing: 7) {
            Text("\(index + 1)")
                .font(.appUI(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(EditorTheme.chrome(0.45))
                .frame(width: 18, height: 18)
                .background(EditorTheme.chrome(0.055), in: Circle())
            Label(appLocalized(element.rawValue), systemImage: openingElementIcon(element))
                .font(.appUI(.caption, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.78))
            Spacer(minLength: 4)
            Button {
                moveOpeningElement(element, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.editorInlineAction)
            .disabled(index == 0)
            .help("提前进入")
            Button {
                moveOpeningElement(element, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
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
                Text("可直接在画面中拖动")
                    .font(.appUI(size: 11)).foregroundStyle(.secondary)
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

    var screenSurfaceAppearanceSection: some View {
        EditorInspectorSection("圆角、描边与阴影", icon: "square.on.square") {
            if editorStore.previewProject.canvas.screenFrame == .none {
                sliderRow(
                    "画面圆角",
                    value: canvasBinding(\.cornerRadius, actionName: "调整画面圆角"),
                    range: 0...160,
                    format: .points
                )
            } else {
                sliderRow(
                    "内容圆角",
                    value: screenFrameRadiusBinding(
                        \.screenFrameContentCornerRadius,
                        fallback: editorStore.previewProject.canvas.screenFrame
                            .defaultContentCornerRadius,
                        actionName: "调整样机内容圆角"
                    ),
                    range: 0...160,
                    format: .points
                )
            }

            sliderRow(
                "外描边",
                value: canvasBinding(\.borderWidth, actionName: "调整屏幕描边"),
                range: 0...40,
                format: .points
            )
            if editorStore.previewProject.canvas.borderWidth > 0 {
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
            sliderRow(
                "阴影强度",
                value: canvasBinding(\.shadowStrength, actionName: "调整屏幕阴影"),
                range: 0...1,
                format: .percent
            )
        }
    }

    var screenMockupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "选择样机；内容圆角、描边与阴影在“布局”中调整。",
                systemImage: "macwindow"
            )
            .font(.appUI(.caption2))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            EditorInspectorSection("样机") {
                EditorScreenFramePicker(editorStore: editorStore, onError: onError)

                if editorStore.previewProject.canvas.screenFrame != .none {
                    sliderRow(
                        "框体比例",
                        value: canvasBinding(
                            \.screenFrameScale,
                            actionName: "调整屏幕样机大小"
                        ),
                        range: 0.6...1.6,
                        format: .multiplier
                    )
                    if editorStore.previewProject.canvas.screenFrame.isWindowFrame || editorStore.previewProject.canvas.screenFrame.isBrowserFrame {
                        sliderRow(
                            "顶栏高度",
                            value: canvasBinding(
                                \.screenFrameToolbarScale,
                                actionName: "调整样机顶栏高度"
                            ),
                            range: 0.65...1.6,
                            format: .multiplier
                        )
                    }
                    sliderRow(
                        "框体外圆角",
                        value: screenFrameRadiusBinding(
                            \.screenFrameOuterCornerRadius,
                            fallback: editorStore.previewProject.canvas.screenFrame
                                .defaultOuterCornerRadius,
                            actionName: "调整样机外圆角"
                        ),
                        range: 0...160,
                        format: .points
                    )
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
            Label("在画面上拖动边缘或四角，拖动框内可整体移动。", systemImage: "crop")
                .font(.appUI(.caption))
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
            .font(.appUI(.caption))

        }
    }

    func cropEdgeStepper(_ title: String, edge: CropEdge, pixels: CGFloat) -> some View {
        let pixelBinding = cropPixelBinding(edge, pixels: pixels)
        let maximumPixels = cropMaximumPixelValue(edge, pixels: pixels)
        let current = pixelBinding.wrappedValue
        return EditorNumericStepControl(
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
            )
        )
    }

    func cropMaximumPixelValue(_ edge: CropEdge, pixels: CGFloat) -> Int {
        let dimension = max(Double(pixels), 1)
        let crop = cropDraft.clamped()
        let opposite: Double = switch edge {
        case .left: crop.right
        case .right: crop.left
        case .top: crop.bottom
        case .bottom: crop.top
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
                            .font(.appUI(.callout, weight: .semibold))
                        Text("共 \(context.total) 段")
                            .font(.appUI(.caption))
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

                    Divider().overlay(EditorTheme.chrome(0.07))

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
                .frame(maxWidth: .infinity, alignment: .leading)

                EditorInspectorSection("片段操作", icon: "scissors") {
                    Button {
                        splitPrimarySegmentFromInspector(context: context)
                    } label: {
                        Label("在播放头处分割", systemImage: "scissors")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.editorQuiet)
                    .disabled(!canSplitPrimarySegmentFromInspector(context: context))
                    .help(
                        canSplitPrimarySegmentFromInspector(context: context)
                            ? "在播放头处分割（S）"
                            : "把播放头移进这个片段内部后才能分割"
                    )

                    if let junctionBefore = context.junctionBefore,
                       junctionBefore.hasRemovedSourceGap {
                        Button {
                            restorePrimaryGapFromInspector(
                                junction: junctionBefore,
                                fullSourceDuration: context.fullSourceDuration
                            )
                        } label: {
                            Label(
                                "还原之前的剪切（已剪 \(segmentTimestamp(junctionBefore.removedDuration))）",
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }

                    if let junctionAfter = context.junctionAfter {
                        if junctionAfter.hasRemovedSourceGap {
                            Button {
                                restorePrimaryGapFromInspector(
                                    junction: junctionAfter,
                                    fullSourceDuration: context.fullSourceDuration
                                )
                            } label: {
                                Label(
                                    "还原之后的剪切（已剪 \(segmentTimestamp(junctionAfter.removedDuration))）",
                                    systemImage: "arrow.uturn.backward"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.editorQuiet)
                        } else {
                            Button {
                                mergeWithNextSegmentFromInspector(context: context)
                            } label: {
                                Label("合并与下一片段", systemImage: "link")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.editorQuiet)
                        }
                    }

                    if let leadingGap = context.leadingGap,
                       leadingGap.nextSegmentID == id {
                        Button {
                            do {
                                try editorStore.restorePrimaryLeadingGap(
                                    fullSourceDuration: context.fullSourceDuration,
                                    actionName: "还原开头剪切"
                                )
                            } catch {
                                onError(error.localizedDescription)
                            }
                        } label: {
                            Label(
                                "还原开头剪切（已剪 \(segmentTimestamp(leadingGap.removedDuration))）",
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }

                    if let trailingGap = context.trailingGap,
                       trailingGap.previousSegmentID == id {
                        Button {
                            do {
                                try editorStore.restorePrimaryTrailingGap(
                                    fullSourceDuration: context.fullSourceDuration,
                                    actionName: "还原结尾剪切"
                                )
                            } catch {
                                onError(error.localizedDescription)
                            }
                        } label: {
                            Label(
                                "还原结尾剪切（已剪 \(segmentTimestamp(trailingGap.removedDuration))）",
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }

                    Button(role: .destructive) {
                        deletePrimarySegmentFromInspector(context: context)
                    } label: {
                        Label("删除这个片段", systemImage: "trash")
                    }
                    .buttonStyle(.editorDestructive)
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
            Image(systemName: systemImage)
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
        .font(.appUI(.caption))
        .frame(maxWidth: .infinity)
    }

    func playbackRateText(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.000_1 {
            return "\(Int(rate.rounded()))×"
        }
        return String(format: "%.1f×", rate)
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
                MotionInspectorScopeHeader(
                    title: "屏幕 3D",
                    detail: "在播放头创建位置、大小和透视动画；可与缩放重叠。",
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
                        Label("显示屏幕 3D 轨道", systemImage: "eye")
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
                Group {
                    if editorStore.previewProject.zoomAnimations[index].origin == .manual {
                        ZoomFocusMap(
                            mediaSession: mediaSession,
                            outputTime: editorStore.project.zoomAnimations[index].startTime,
                            sourcePixelSize: sourcePixelSize,
                            focus: zoomAnimationFocusBinding(index),
                            onEditingChanged: {
                                updateEditorContinuousInteraction(
                                    store: editorStore, isEditing: $0,
                                    commandScope: .selection,
                                    actionName: "调整缩放焦点",
                                    onError: onError
                                )
                            },
                            onEditingCancelled: { editorStore.cancelInteraction() }
                        )
                    } else {
                        ZoomFocusMap(mediaSession: mediaSession,
                            outputTime: animation.startTime, sourcePixelSize: sourcePixelSize,
                            focus: .constant(animation.focus), allowsEditing: false)
                        Label("焦点随鼠标自动移动", systemImage: "cursorarrow.motionlines")
                            .font(.appUI(size: 11)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    motionTypeSelector

                    sliderRow(
                        "放大比例",
                        value: zoomAnimationDoubleBinding(index, keyPath: \.scale),
                        range: 1...6,
                        format: .multiplier
                    )

                    Button {
                        applySelectedZoomScaleToAll(animation.scale)
                    } label: {
                        Label("将倍率应用到全部缩放", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.editorQuiet)
                    .disabled(editorStore.previewProject.zoomAnimations.count < 2)
                    .help("将当前缩放级别应用到全部缩放动画，保留每段的时间和焦点")
                }

                EditorInspectorSection("过渡") {
                    EditorInspectorZoomPhases(animation: animation)
                    sliderRow(
                        "进入时长",
                        value: zoomAnimationTransitionDurationBinding(index, entering: true),
                        range: 0...3,
                        format: .seconds
                    )
                    sliderRow(
                        "退出时长",
                        value: zoomAnimationTransitionDurationBinding(index, entering: false),
                        range: 0...3,
                        format: .seconds
                    )
                    zoomTransitionAvailability(animation)

                    EditorDisclosure(
                        "片段时间",
                        detail: "开始 \(EditorSliderValueFormat.seconds.text(for: animation.startTime)) · 范围 \(EditorSliderValueFormat.seconds.text(for: animation.duration))"
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
            } else if case .zoom = editorStore.selection {
                EditorInspectorEmptyState(
                    title: "缩放片段已不存在",
                    detail: "它可能已在时间线中删除或被撤销。",
                    systemImage: "scope",
                    actionTitle: "返回缩放",
                    action: { editorStore.selection = .zoomTrack }
                )
            } else {
                // 片段选择交还时间线：这里只保留创建与选中的引导，
                // 不再用间接的文字下拉列表代替时间线。
                Label(
                    "在“缩放”轨道拖动创建；选中片段后在这里调整",
                    systemImage: "timeline.selection"
                )
                .font(.appUI(.caption))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EditorTheme.chrome(0.035), in: RoundedRectangle(cornerRadius: 10))

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
