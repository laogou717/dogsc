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
    case progress
}

private enum EditorInspectorScrollContext: Hashable {
    case crop
    case selection(EditorInspectorSelectionKind)
    case tab(InspectorTab)
}

private enum EditorInspectorScrollAnchor: Hashable {
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
    /// 内容面板宽度（不含 70pt 导航轨），由编辑器分栏条实时解析。
    let contentWidth: CGFloat
    let onChooseWallpaper: () -> BackgroundSource?
    let onChooseDesktopWallpaper: () -> BackgroundSource?
    let onError: (String) -> Void

    @State var savedLayoutPresets: [SavedLayoutPreset] = []
    @State var isNamingLayoutPreset = false
    @State var layoutPresetName = ""
    @State var motionInspectorMode = EditorMotionInspectorMode.zoom
    @State var hoveredInspectorTab: InspectorTab?
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
        HStack(spacing: 0) {
            inspectorRail
                .disabled(isCropping)
                .opacity(isCropping ? 0.45 : 1)
            Divider().overlay(dividerColor)
            inspector
        }
        .onChange(of: editorStore.selection) { _, selection in
            switch selection {
            case .screenMotionTrack, .screenMotion:
                motionInspectorMode = .screen3D
            case .zoom, .zoomTrack:
                motionInspectorMode = .zoom
            default:
                break
            }
        }
    }

    @Namespace private var inspectorRailNamespace

    var inspectorRail: some View {
        VStack(spacing: 7) {
            ForEach(InspectorTab.allCases) { tab in
                let isSelected = selectedInspector == tab
                Button {
                    withAnimation(SpringMotion.fluid) {
                        selectedInspector = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: isSelected ? .bold : .semibold))
                            .frame(height: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(width: 56, height: 52)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.14),
                                            Color.white.opacity(0.08)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                                )
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.white, Color(white: 0.85)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(width: 2.5, height: 22)
                                        .offset(x: -1)
                                        .shadow(color: Color.white.opacity(0.4), radius: 3)
                                }
                                .matchedGeometryEffect(id: "activeInspectorTabIndicator", in: inspectorRailNamespace)
                        } else if hoveredInspectorTab == tab && inspectorTabIsAvailable(tab) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .scaleEffect(isSelected ? 1.02 : 1.0)
                }
                // The rail already owns hover and selected surfaces. Reuse
                // the press-only chrome response so a click feels physical
                // without wrapping the tab in another card.
                .buttonStyle(.editorToolbarPress)
                .foregroundStyle(inspectorRailForeground(for: tab))
                .disabled(!inspectorTabIsAvailable(tab))
                .opacity(inspectorTabIsAvailable(tab) ? 1 : 0.32)
                .accessibilityAddTraits(selectedInspector == tab ? .isSelected : [])
                .help(inspectorTabHelp(tab))
                .onHover { isHovering in
                    guard inspectorTabIsAvailable(tab) else { return }
                    withAnimation(SpringMotion.interactive) {
                        if isHovering {
                            hoveredInspectorTab = tab
                        } else if hoveredInspectorTab == tab {
                            hoveredInspectorTab = nil
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 12)
        .frame(width: 70)
        .background(EditorTheme.backgroundDeep)
        .animation(SpringMotion.interactive, value: hoveredInspectorTab)
        .animation(SpringMotion.fluid, value: selectedInspector)
    }

    func inspectorRailBackground(for tab: InspectorTab) -> Color {
        if selectedInspector == tab {
            return Color.white.opacity(0.12)
        }
        if hoveredInspectorTab == tab, inspectorTabIsAvailable(tab) {
            return Color.white.opacity(0.07)
        }
        return .clear
    }

    func inspectorRailForeground(for tab: InspectorTab) -> Color {
        if selectedInspector == tab {
            return .white
        }
        if hoveredInspectorTab == tab, inspectorTabIsAvailable(tab) {
            return Color.white.opacity(0.9)
        }
        return .secondary
    }

    func inspectorTabIsAvailable(_ tab: InspectorTab) -> Bool {
        switch tab {
        case .camera:
            return cameraHasVideo
        case .audio:
            return sourceHasAudio || microphoneHasAudio
        case .cursor:
            return !pointerEvents.isEmpty
        case .frame, .opening, .mockup, .zoom:
            return true
        }
    }

    func inspectorTabHelp(_ tab: InspectorTab) -> String {
        guard !inspectorTabIsAvailable(tab) else { return tab.rawValue }
        switch tab {
        case .camera: return "当前项目没有摄像头素材"
        case .audio: return "当前项目没有系统声音或麦克风素材"
        case .cursor: return "当前项目没有记录鼠标事件"
        case .frame, .opening, .mockup, .zoom: return tab.rawValue
        }
    }

    var inspector: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Text(inspectorHeader.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.94))
                    if let scope = inspectorHeader.scope {
                        Text(scope)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(EditorTheme.platinumMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 23)
                            .background(
                                Color.black.opacity(0.24),
                                in: Capsule(style: .continuous)
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.09), lineWidth: 0.6)
                            }
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
            .background(
                LinearGradient(
                    colors: [EditorTheme.panelRaised.opacity(0.72), panelBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottom) {
                Divider().overlay(dividerColor)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(inspectorTitle)
            .animation(SpringMotion.fluid, value: inspectorPresentationIdentity)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id(EditorInspectorScrollAnchor.top)

                        VStack(alignment: .leading, spacing: 18) {
                            inspectorContent
                        }
                        .padding(16)
                        // Preserve the reader's viewport while moving between
                        // objects of the same kind (notably sticker-to-sticker
                        // animation tuning). A different inspector task still
                        // receives a clean top position.
                        .id(inspectorScrollContext)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .scale(scale: 0.985))
                            )
                        )
                    }
                }
                .animation(SpringMotion.fluid, value: inspectorScrollContext)
                .onChange(of: inspectorScrollContext) { _, _ in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(EditorInspectorScrollAnchor.top, anchor: .top)
                    }
                }
            }
        }
        .frame(width: contentWidth)
        .background(panelBackground)
    }

    var inspectorHeader: (title: String, scope: String?) {
        if isCropping { return ("裁切", "屏幕素材") }
        if selectedInspector == .opening,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return ("开场", "全片")
        }
        if selectedInspector == .mockup,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return ("样机", "屏幕素材")
        }
        switch editorStore.selection {
        case .canvas:
            return ("画面", "全片")
        case .screen:
            return ("屏幕素材", "初始状态")
        case .primarySegment:
            return ("片段", "当前片段")
        case .zoomTrack:
            return ("运镜", "自动缩放")
        case .zoom:
            return ("运镜", "缩放片段")
        case .screenMotionTrack:
            return ("运镜", "屏幕 3D")
        case .screenMotion:
            return ("运镜", "屏幕 3D 片段")
        case .cursor:
            return ("光标", "全片")
        case .camera:
            return ("摄像头", "初始状态")
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
        case .progress:
            return ("进度条", "全片")
        case nil:
            return (selectedInspector.rawValue, nil)
        }
    }

    var inspectorTitle: String {
        guard let scope = inspectorHeader.scope else { return inspectorHeader.title }
        return "\(inspectorHeader.title) · \(scope)"
    }

    private var inspectorPresentationIdentity: EditorInspectorPresentationIdentity {
        if isCropping { return .crop }
        if selectedInspector == .opening || selectedInspector == .mockup,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return .tab(selectedInspector)
        }
        if let selection = editorStore.selection { return .selection(selection) }
        return .tab(selectedInspector)
    }

    private var inspectorScrollContext: EditorInspectorScrollContext {
        if isCropping { return .crop }
        if selectedInspector == .opening || selectedInspector == .mockup,
           editorStore.selection == .canvas || editorStore.selection == nil {
            return .tab(selectedInspector)
        }
        guard let selection = editorStore.selection else {
            return .tab(selectedInspector)
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
        case .progress: .progress
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
        } else if editorStore.selection == .progress {
            overlayInspector
        } else if case let .primarySegment(id) = editorStore.selection {
            // 选中主片段给真正的片段面板：此前标题写着"当前片段"，内容却是
            // 全片初始状态控件，名实不符。
            primarySegmentInspector(id: id)
        } else {
            switch selectedInspector {
        case .frame:
            frameInspector
        case .opening:
            openingInspector
        case .mockup:
            mockupInspector
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

    /// 合并后的"画面"页：背景、画布布局、屏幕素材位置与屏幕外观都是同一
    /// 个 CanvasStyle，按"美化画面"的任务顺序排在一页里，不再让用户在
    /// 两个页签之间猜参数归属。
    var frameInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if editorStore.selection == .screen {
                // Directly selecting the recorded screen is an object task:
                // show its transform and appearance immediately instead of
                // making the user scroll through the wallpaper library first.
                screenMaterialLayoutSection
            } else {
                EditorBackgroundInspector(
                    editorStore: editorStore,
                    onChooseWallpaper: onChooseWallpaper,
                    onChooseDesktopWallpaper: onChooseDesktopWallpaper,
                    onError: onError
                )
                canvasLayoutSection
                screenMaterialLayoutSection
            }
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

    var mockupInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "样机与屏幕内容共用同一投影，缩放、3D 运镜和导出不会分离。",
                systemImage: "cube.transparent"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            screenAppearanceSection
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                    EditorTileSelector(
                        options: OpeningSequencePreset.allCases,
                        title: { $0.rawValue },
                        icon: openingPresetIcon,
                        selection: openingBinding(\.preset, actionName: "更换开场方式"),
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
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.48))
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
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.50))
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
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.055), in: Circle())
            Label(element.rawValue, systemImage: openingElementIcon(element))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.78))
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
        case .progress: "chart.bar.fill"
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
        EditorInspectorSection("画布布局") {
            sliderRow(
                "背景模糊",
                value: canvasBinding(\.backgroundBlur, actionName: "调整背景模糊"),
                range: 0...80,
                format: .points
            )
            .disabled(!editorStore.previewProject.canvas.backgroundSource.usesWallpaperMedia)
            .opacity(
                editorStore.previewProject.canvas.backgroundSource.usesWallpaperMedia
                    ? 1
                    : 0.45
            )
            sliderRow(
                "边距",
                value: canvasBinding(\.padding, actionName: "调整画布边距"),
                range: 0...360,
                format: .points
            )
        }
    }

    var screenMaterialLayoutSection: some View {
        EditorInspectorSection("屏幕素材布局") {
            Label(
                "直接在画布中拖动，拖右下角缩放；动画在“运镜”中添加",
                systemImage: "hand.draw"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            EditorTransactionalPositionPad(
                editorStore: editorStore,
                title: "素材位置",
                point: canvasBinding(
                    \.contentPosition,
                    actionName: "移动屏幕素材"
                ),
                commandScope: .canvas,
                actionName: "移动屏幕素材",
                onError: onError
            )

            sliderRow(
                "素材缩放",
                value: canvasBinding(\.contentScale, actionName: "缩放屏幕素材"),
                range: 0.25...4,
                format: .multiplier
            )

            Button("恢复位置与大小") {
                var canvas = editorStore.project.canvas
                canvas.contentScale = 1
                canvas.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
                performEditorCommand {
                    try editorStore.replaceCanvas(with: canvas, actionName: "居中屏幕素材")
                }
            }
            .buttonStyle(.editorQuiet)
        }
    }

    var screenAppearanceSection: some View {
        EditorInspectorSection("屏幕外观") {
            EditorScreenFramePicker(editorStore: editorStore, onError: onError)
            if editorStore.previewProject.canvas.screenFrame != .none {
                sliderRow(
                    "样式大小",
                    value: canvasBinding(
                        \.screenFrameScale,
                        actionName: "调整屏幕样式大小"
                    ),
                    range: 0.6...1.6,
                    format: .multiplier
                )
            } else {
                sliderRow(
                    "画面圆角",
                    value: canvasBinding(\.cornerRadius, actionName: "调整画面圆角"),
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
                    "描边透明度",
                    value: canvasBinding(\.insetOpacity, actionName: "调整描边透明度"),
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


    var cropInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("在画面上拖动边缘或四角，拖动框内可整体移动。", systemImage: "crop")
                .font(.caption)
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
            .font(.caption)

            Button("恢复全部画面") { cropDraft = .full }
                .buttonStyle(.editorQuiet)
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
                            .font(.callout.weight(.semibold))
                        Text("共 \(context.total) 段")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(playbackRateText(context.segment.playbackRate))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(
                                Color.white.opacity(0.065),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }

                    Divider().overlay(Color.white.opacity(0.07))

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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(width: 14)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .font(.caption)
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
            EditorInspectorSection("运镜类型") {
                EditorSegmentedControl(
                    options: EditorMotionInspectorMode.allCases,
                    title: { $0 == .screen3D ? "屏幕 3D" : "自动缩放" },
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

            if motionInspectorMode == .zoom {
                zoomInspector
            } else if case let .screenMotion(id) = editorStore.selection {
                ScreenMotionTargetInspector(
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

    var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let index = selectedZoomAnimationIndex {
                let animation = editorStore.previewProject.zoomAnimations[index]
                EditorInspectorSection("缩放片段") {
                    EditorSegmentedControl(
                        options: [ZoomKeyframeOrigin.automatic, .manual],
                        title: { $0 == .automatic ? "自动跟随" : "手动定位" },
                        selection: zoomAnimationOriginBinding(index)
                    )

                    sliderRow(
                        "缩放级别",
                        value: zoomAnimationDoubleBinding(index, keyPath: \.scale),
                        range: 1...6,
                        format: .multiplier
                    )
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
                        Text("整张源画面会完整显示；圆圈可到真实四角，成片会自动留出舒适观看距离。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("自动跟随会优先让鼠标保持在画面内", systemImage: "cursorarrow.motionlines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                EditorInspectorSection("动画手感") {
                    sliderRow(
                        "过渡时长",
                        value: zoomAnimationTransitionDurationBinding(index),
                        range: 0.08...3,
                        format: .seconds
                    )
                    Text("进入和退出保持一致；数值越小越干脆，越大越柔和。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    EditorDisclosure(
                        "片段时间",
                        detail: "开始 \(EditorSliderValueFormat.seconds.text(for: animation.startTime)) · 保持 \(EditorSliderValueFormat.seconds.text(for: animation.duration))"
                    ) {
                        VStack(spacing: 9) {
                            zoomTimeStepper(
                                "开始位置",
                                value: zoomAnimationStartBinding(index),
                                range: 0...max(timelineDuration - 0.16, 0),
                                resolvedValue: { resolvedZoomStartValue(index, proposed: $0) }
                            )
                            zoomTimeStepper(
                                "保持时长",
                                value: zoomAnimationDurationBinding(index),
                                range: 0.16...max(timelineDuration, 0.16),
                                resolvedValue: { resolvedZoomDurationValue(index, proposed: $0) }
                            )
                        }
                    }
                }

                Button("删除这个动画片段", role: .destructive) {
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
                    actionTitle: "返回自动缩放",
                    action: { editorStore.selection = .zoomTrack }
                )
            } else {
                // 片段选择交还时间线：这里只保留创建与选中的引导，
                // 不再用间接的文字下拉列表代替时间线。
                Label(
                    "在“缩放”轨道拖动创建；选中片段后在这里调整",
                    systemImage: "timeline.selection"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

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
                range: 0.08...3,
                interactionScope: .motion,
                format: .seconds
            )
        }

    }
}
