import AppKit
import Foundation
import RecorderCore
import SwiftUI

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
    let isCropping: Bool
    @Binding var cropDraft: NormalizedCrop
    /// 内容面板宽度（不含 66pt 图标轨），由编辑器分栏条实时解析。
    let contentWidth: CGFloat
    let onChooseWallpaper: () -> String?
    let onChooseDesktopWallpaper: () -> String?
    let onError: (String) -> Void

    @State var selectedBackgroundTab: BackgroundPanelTab = .wallpaper
    @State var selectedWallpaperCollection = "Photography"
    @State var savedLayoutPresets: [SavedLayoutPreset] = []
    @State var isNamingLayoutPreset = false
    @State var layoutPresetName = ""
    @State var zoomAuditionTask: Task<Void, Never>?
    @State var hoveredInspectorTab: InspectorTab?
    /// 纯色背景的候选色。浏览"颜色"页签不再写项目；只有明确点击
    /// "使用纯色背景"才把候选色提交为一次可撤销的项目命令。
    @State var candidateBackgroundHex = HexColor(rgb24: 0xD9_C8_FF)

    /// Keep the grid cache bounded. Full-resolution wallpaper decoding belongs
    /// to the preview renderer; this cache stores only ImageIO-downsampled tiles.
    static let wallpaperThumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    init(
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        pointerEvents: [PointerEventRecord],
        selectedInspector: Binding<InspectorTab>,
        isCameraSyncEditing: Binding<Bool>,
        isCropping: Bool,
        cropDraft: Binding<NormalizedCrop>,
        contentWidth: CGFloat = EditorInspectorSizing.defaultContentWidth,
        onChooseWallpaper: @escaping () -> String?,
        onChooseDesktopWallpaper: @escaping () -> String?,
        onError: @escaping (String) -> Void
    ) {
        _editorStore = ObservedObject(wrappedValue: editorStore)
        _mediaSession = ObservedObject(wrappedValue: mediaSession)
        _playbackController = ObservedObject(wrappedValue: playbackController)
        self.pointerEvents = pointerEvents
        cursorAssets = CursorAssetLibrary.availableAssets
        _selectedInspector = selectedInspector
        _isCameraSyncEditing = isCameraSyncEditing
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

    var isScreenMotionSelected: Bool {
        if case .screenMotion = editorStore.selection { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            inspectorRail
                .disabled(isCropping)
                .opacity(isCropping ? 0.45 : 1)
            Divider().overlay(dividerColor)
            inspector
        }
        .onAppear {
            synchronizeBackgroundNavigation(
                with: editorStore.project.canvas.backgroundSource
            )
        }
        .onChange(of: editorStore.project.canvas.backgroundSource) { _, source in
            synchronizeBackgroundNavigation(with: source)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .editorWillTogglePlaybackFromSpace)
        ) { _ in
            zoomAuditionTask?.cancel()
            zoomAuditionTask = nil
        }
        .onDisappear {
            zoomAuditionTask?.cancel()
            zoomAuditionTask = nil
        }
    }

    var inspectorRail: some View {
        VStack(spacing: 6) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    selectedInspector = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(height: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: selectedInspector == tab ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(width: 52, height: 48)
                    .background(
                        inspectorRailBackground(for: tab),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .leading) {
                        if selectedInspector == tab {
                            Capsule()
                                .fill(editorAccent)
                                .frame(width: 2.5, height: 21)
                                .offset(x: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(inspectorRailForeground(for: tab))
                .disabled(!inspectorTabIsAvailable(tab))
                .opacity(inspectorTabIsAvailable(tab) ? 1 : 0.32)
                .help(inspectorTabHelp(tab))
                .onHover { isHovering in
                    guard inspectorTabIsAvailable(tab) else { return }
                    if isHovering {
                        hoveredInspectorTab = tab
                    } else if hoveredInspectorTab == tab {
                        hoveredInspectorTab = nil
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 66)
        .background(Color.black.opacity(0.16))
        .animation(.easeOut(duration: 0.13), value: hoveredInspectorTab)
        .animation(.easeOut(duration: 0.13), value: selectedInspector)
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
            return Color.white.opacity(0.88)
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
        case .frame, .zoom:
            return true
        }
    }

    func inspectorTabHelp(_ tab: InspectorTab) -> String {
        guard !inspectorTabIsAvailable(tab) else { return tab.rawValue }
        switch tab {
        case .camera: return "当前项目没有摄像头素材"
        case .audio: return "当前项目没有系统声音或麦克风素材"
        case .cursor: return "当前项目没有记录鼠标事件"
        case .frame, .zoom: return tab.rawValue
        }
    }

    var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text(inspectorTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(panelBackground)
            .overlay(alignment: .bottom) {
                Divider().overlay(dividerColor)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inspectorContent
                }
                .padding(16)
            }
        }
        .frame(width: contentWidth)
        .background(panelBackground)
    }

    var inspectorTitle: String {
        if isCropping { return "裁切 · 屏幕素材" }
        switch editorStore.selection {
        case .canvas:
            return "画面 · 全片"
        case .screen:
            return "画面 · 初始状态"
        case .primarySegment:
            return "片段 · 当前片段"
        case .zoomTrack:
            return "运镜 · 全局设置"
        case .zoom:
            return "运镜 · 缩放片段"
        case .screenMotion:
            return "运镜 · 屏幕 3D"
        case .cursor:
            return "鼠标 · 全片"
        case .camera:
            return "摄像头 · 初始状态"
        case .cameraMotion:
            return "摄像头 · 动画目标"
        case .audio:
            return "音频 · 全片"
        case .crop:
            return "裁切 · 屏幕素材"
        case nil:
            return selectedInspector.rawValue
        }
    }

    @ViewBuilder
    var inspectorContent: some View {
        if isCropping {
            cropInspector
        } else if case let .primarySegment(id) = editorStore.selection {
            // 选中主片段给真正的片段面板：此前标题写着"当前片段"，内容却是
            // 全片初始状态控件，名实不符。
            primarySegmentInspector(id: id)
        } else {
            switch selectedInspector {
        case .frame:
            frameInspector
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
            EditorInspectorSection("背景") {
                GeometryReader { proxy in
                    let spacing: CGFloat = 3
                    let tabs = BackgroundPanelTab.allCases
                    let count = max(tabs.count, 1)
                    let itemWidth = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
                    HStack(spacing: spacing) {
                        ForEach(tabs) { tab in
                            Button {
                                // 页签切换只是浏览：任何写入都必须来自页内的
                                // 明确动作（点选壁纸/渐变/图片，或点击"使用纯色背景"）。
                                selectedBackgroundTab = tab
                            } label: {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(
                                        selectedBackgroundTab == tab
                                            ? Color.white.opacity(0.14) : Color(white: 0.12)
                                    )
                                    .frame(width: itemWidth, height: 28)
                                    .overlay {
                                        Text(tab.rawValue)
                                            .font(.caption.weight(.medium))
                                    }
                            }
                            .buttonStyle(.plain)
                            .frame(width: itemWidth, height: 28)
                            .contentShape(Rectangle())
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(height: 28)
                .padding(3)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))

                switch selectedBackgroundTab {
                case .wallpaper:
                    wallpaperLibraryGrid
                case .gradient:
                    gradientGrid
                case .color:
                    if case let .solidColor(hex) = editorStore.project.canvas.backgroundSource {
                        EditorHexColorInput(title: "背景颜色", value: hex) { color in
                            var canvas = editorStore.project.canvas
                            canvas.backgroundSource = .solidColor(hex: color)
                            performEditorCommand {
                                try editorStore.replaceCanvas(
                                    with: canvas,
                                    actionName: "调整背景颜色"
                                )
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            EditorHexColorInput(title: "纯色背景", value: candidateBackgroundHex) { color in
                                candidateBackgroundHex = color
                            }
                            Button {
                                var canvas = editorStore.project.canvas
                                canvas.backgroundSource = .solidColor(hex: candidateBackgroundHex)
                                performEditorCommand {
                                    try editorStore.replaceCanvas(
                                        with: canvas,
                                        actionName: "选择纯色背景"
                                    )
                                }
                            } label: {
                                Label("使用纯色背景", systemImage: "paintbucket")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.editorQuiet)
                            Text("只有点击按钮才会切换背景；浏览页签不会再改动项目。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .image:
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: chooseWallpaper) {
                            Label("选择自己的图片…", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.editorQuiet)
                        Button(action: chooseDesktopWallpaper) {
                            Label("使用当前桌面壁纸", systemImage: "desktopcomputer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.editorQuiet)
                        Text("支持你自己设置的桌面图片；macOS 系统默认壁纸不提供可读文件，那时会提示原因。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            EditorInspectorSection("画布布局") {
                sliderRow(
                    "背景模糊",
                    value: canvasBinding(\.backgroundBlur, actionName: "调整背景模糊"),
                    range: 0...80,
                    format: .points
                )
                .disabled(!editorStore.previewProject.canvas.backgroundSource.isImage)
                .opacity(editorStore.previewProject.canvas.backgroundSource.isImage ? 1 : 0.45)
                sliderRow(
                    "边距",
                    value: canvasBinding(\.padding, actionName: "调整画布边距"),
                    range: 0...360,
                    format: .points
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("屏幕素材 · 初始状态")
                    .font(.caption.weight(.semibold))
                Text("以下设置第一个动画开始前全片共用的位置与外观；自动缩放和屏幕 3D 动画在“运镜”中创建。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            Label("直接在画布中拖动素材；拖右下角圆点缩放", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)

            EditorInspectorSection("快速对齐") {
                screenPositionGrid

                Button("居中并恢复大小") {
                    var canvas = editorStore.project.canvas
                    canvas.contentScale = 1
                    canvas.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
                    performEditorCommand {
                        try editorStore.replaceCanvas(with: canvas, actionName: "居中屏幕素材")
                    }
                }
                .buttonStyle(.editorQuiet)

                EditorDisclosure("精确数值") {
                    VStack(spacing: 10) {
                        sliderRow(
                            "素材缩放",
                            value: canvasBinding(\.contentScale, actionName: "缩放屏幕素材"),
                            range: 0.25...4,
                            format: .multiplier
                        )
                        sliderRow(
                            "水平位置",
                            value: canvasBinding(\.contentPosition.x, actionName: "移动屏幕素材"),
                            range: 0...1,
                            format: .percent
                        )
                        sliderRow(
                            "垂直位置",
                            value: canvasBinding(\.contentPosition.y, actionName: "移动屏幕素材"),
                            range: 0...1,
                            format: .percent
                        )
                    }
                }
            }

            EditorInspectorSection("屏幕外观") {
                EditorScreenFramePicker(editorStore: editorStore, onError: onError)
                sliderRow(
                    "圆角",
                    value: canvasBinding(\.cornerRadius, actionName: "调整屏幕圆角"),
                    range: 0...160,
                    format: .points
                )
                sliderRow(
                    "外描边",
                    value: canvasBinding(\.borderWidth, actionName: "调整屏幕描边"),
                    range: 0...40,
                    format: .points
                )
                if editorStore.project.canvas.borderWidth > 0 {
                    EditorHexColorInput(
                        title: "描边颜色",
                        value: editorStore.project.canvas.borderColor
                    ) { color in
                        var canvas = editorStore.project.canvas
                        canvas.borderColor = color
                        performEditorCommand {
                            try editorStore.replaceCanvas(
                                with: canvas,
                                actionName: "调整描边颜色"
                            )
                        }
                    }
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
    }

    var wallpaperLibraryGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("内置壁纸").font(.caption.weight(.semibold))
                Spacer()
                Button {
                    if let preset = selectedBundledWallpaperCollection?.wallpapers.randomElement() {
                        selectBundledWallpaper(preset)
                    }
                } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.borderless)
                .help("随机壁纸")
            }

            // 集合清理后只剩 3 组且全部容纳在一行：不再需要横向滚动，
            // 顺带消除滚动手势与胶囊点击的潜在竞争。命中面覆盖整颗胶囊
            // （contentShape 在 label 内部），文字间隙同样可点。
            // 分类胶囊不用 Button：macOS 的 AppKit 桥接命中判定在半透明/
            // overlay 文本结构上反复回归（UX-024），只有当前选中的那颗能点。
            // 整行不存在任何 Button 后，SwiftUI 手势层（contentShape +
            // onTapGesture）不再与子按钮竞争，命中面即整颗胶囊。
            GeometryReader { proxy in
                let spacing: CGFloat = 6
                let count = max(BundledWallpaperLibrary.collections.count, 1)
                let itemWidth = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
                HStack(spacing: spacing) {
                    ForEach(BundledWallpaperLibrary.collections) { collection in
                        let isSelected = selectedWallpaperCollection == collection.name
                        Capsule()
                            .fill(isSelected ? editorAccent : Color(white: 0.16))
                            .frame(width: itemWidth, height: 26)
                            .overlay {
                                Text(collection.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(
                                        isSelected
                                            ? Color.black.opacity(0.85)
                                            : Color.primary.opacity(0.9)
                                    )
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedWallpaperCollection = collection.name
                            }
                            .help("切换到\(collection.displayName)分类")
                            .accessibilityLabel(collection.displayName)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .frame(height: 26)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(selectedBundledWallpaperCollection?.wallpapers ?? []) { preset in
                    Button {
                        selectBundledWallpaper(preset)
                    } label: {
                        // 命中框必须由固定尺寸且**不透明**的占位 label 决定：
                        // ①图片一旦参与 label 布局（scaledToFill 的竖图可达
                        //   92×161），AppKit 桥接按钮的命中框随之膨胀，向上
                        //   盖住整行分类胶囊（UX-024 根因；
                        //   clipShape/frame/clipped 都约束不了该命中框）；
                        // ②label 若是 Color.clear（全透明），macOS 命中区
                        //   塌缩为零像素，壁纸反而点不了。
                        // 因此 label 用不透明深色占位定命中框，图片放
                        // overlay 只绘制、不参与命中。
                        Color(white: 0.12)
                            .frame(height: 50)
                            .overlay {
                                BundledWallpaperThumbnail(preset: preset)
                                    .frame(height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        selectedBundledWallpaperPath == preset.relativePath
                                            ? editorAccent : Color.white.opacity(0.1),
                                        lineWidth: selectedBundledWallpaperPath == preset.relativePath ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                }
            }


            if BundledWallpaperLibrary.collections.isEmpty {
                Text("未找到内置壁纸资源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // 后台预热全部缩略图：首次切换集合的网格立即呈现，不再逐格
            // 等待大图首次解码（此前让切换看起来"没反应"）。
            await WallpaperThumbnailLoader.prewarmAll(
                into: EditorInspectorView.wallpaperThumbnailCache
            )
        }

    }

    var selectedBundledWallpaperCollection: BundledWallpaperCollection? {
        BundledWallpaperLibrary.collections.first { $0.name == selectedWallpaperCollection }
            ?? BundledWallpaperLibrary.collections.first
    }

    var selectedBundledWallpaperPath: String? {
        guard case let .bundledImage(relativePath) = editorStore.project.canvas.backgroundSource else {
            return nil
        }
        return relativePath
    }

    func selectBundledWallpaper(_ preset: BundledWallpaperPreset) {
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = .bundledImage(relativePath: preset.relativePath)
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "选择内置壁纸")
        }
    }

    func chooseWallpaper() {
        guard let relativePath = onChooseWallpaper() else { return }
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = .projectImage(relativePath: relativePath)
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "选择自定义壁纸")
        }
    }

    func chooseDesktopWallpaper() {
        guard let relativePath = onChooseDesktopWallpaper() else { return }
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = .projectImage(relativePath: relativePath)
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "使用当前桌面壁纸")
        }
    }

    func synchronizeBackgroundNavigation(with source: BackgroundSource) {
        switch source {
        case let .bundledImage(relativePath):
            selectedBackgroundTab = .wallpaper
            if let collection = BundledWallpaperLibrary.collections.first(where: {
                $0.wallpapers.contains(where: { $0.relativePath == relativePath })
            }) {
                selectedWallpaperCollection = collection.name
            }
        case .projectImage, .systemImage:
            selectedBackgroundTab = .image
        case .gradient:
            selectedBackgroundTab = .gradient
        case let .solidColor(hex):
            selectedBackgroundTab = .color
            // 记住当前纯色作为候选：切去壁纸再切回"颜色"页时仍可一键还原，
            // 不再因为页签切换丢掉用户选过的颜色。
            candidateBackgroundHex = hex
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
            LabeledContent("起始位置") {
                Text(cropPositionText).monospacedDigit()
            }
            .font(.caption)

            Button("恢复全部画面") { cropDraft = .full }
                .buttonStyle(.editorQuiet)

            Text("拖动八个控制点进行四向裁切；按 Esc 放弃修改。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    func cropEdgeStepper(_ title: String, edge: CropEdge, pixels: CGFloat) -> some View {
        Stepper(
            value: cropPixelBinding(edge, pixels: pixels),
            in: 0...max(Int(pixels.rounded()) - 2, 0),
            step: 1
        ) {
            HStack(spacing: 5) {
                Text(title)
                Spacer(minLength: 2)
                Text("\(cropPixelValue(edge, pixels: pixels)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
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

    var gradientGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(BackgroundGradientPreset.allCases, id: \.self) { preset in
                Button {
                    var canvas = editorStore.project.canvas
                    canvas.backgroundSource = .gradient(preset)
                    performEditorCommand {
                        try editorStore.replaceCanvas(with: canvas, actionName: "选择渐变背景")
                    }
                } label: {
                    LinearGradient(
                        colors: gradientColors(for: preset),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(alignment: .bottomLeading) {
                        Text(gradientName(for: preset))
                            .font(.caption2.weight(.semibold))
                            .padding(7)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(
                                editorStore.project.canvas.backgroundSource == .gradient(preset)
                                    ? .white : .white.opacity(0.1),
                                lineWidth: editorStore.project.canvas.backgroundSource == .gradient(preset) ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    func positionName(for index: Int) -> String {
        let names = [
            "左上", "上方居中", "右上",
            "左侧居中", "正中", "右侧居中",
            "左下", "下方居中", "右下",
        ]
        return names.indices.contains(index) ? names[index] : "位置"
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
                EditorInspectorSection("片段信息") {
                    LabeledContent("片段") {
                        Text("第 \(context.index + 1) 段，共 \(context.total) 段")
                    }
                    LabeledContent("时长") {
                        Text(segmentTimestamp(context.segment.sourceDuration))
                            .monospacedDigit()
                    }
                    LabeledContent("输出区间") {
                        Text(
                            "\(segmentTimestamp(context.segment.outputStart)) – "
                                + segmentTimestamp(context.segment.outputEnd)
                        )
                        .monospacedDigit()
                    }
                    LabeledContent("源区间") {
                        Text(
                            "\(segmentTimestamp(context.segment.sourceStart)) – "
                                + segmentTimestamp(context.segment.sourceEnd)
                        )
                        .monospacedDigit()
                    }
                }
                .font(.caption)

                EditorInspectorSection("片段操作") {
                    Button {
                        splitPrimarySegmentFromInspector(context: context)
                    } label: {
                        Label("在播放头处分割", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
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

                    Button("删除这个片段", role: .destructive) {
                        deletePrimarySegmentFromInspector(context: context)
                    }
                    .buttonStyle(.borderless)
                }

                Text("也可以直接在时间线中拖动片段调整顺序、拖两端修剪；快捷键 S 分割、D 删除。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView(
                    "片段已不存在",
                    systemImage: "film",
                    description: Text("可能已在时间线中删除或被撤销。")
                )
                Button("返回画面设置") { editorStore.selection = .canvas }
                    .buttonStyle(.editorQuiet)
            }
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
            EditorInspectorSection("运镜类型") {
                EditorSegmentedControl(
                    options: [false, true],
                    title: { $0 ? "屏幕 3D" : "自动缩放" },
                    icon: { $0 ? "cube.transparent" : "scope" },
                    selection: Binding(
                        get: { isScreenMotionSelected },
                        set: { screenMotion in
                            if screenMotion {
                                addScreenMotionAtPlayhead()
                            } else {
                                editorStore.selection = .zoomTrack
                            }
                        }
                    )
                )
                .accessibilityLabel("运镜类型")

                Text("自动缩放负责镜头裁切与鼠标跟随；屏幕 3D 负责整块屏幕对象的位置、大小和透视运动。屏幕 3D 会选中播放头处已有片段，没有时就在这里创建。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .screenMotion(id) = editorStore.selection {
                ScreenMotionTargetInspector(
                    editorStore: editorStore,
                    clipID: id,
                    onError: onError
                )
                EditorFrameMotionBlurControls(editorStore: editorStore, onError: onError)
            } else {
                zoomInspector
            }
        }
    }

    var screenPositionGrid: some View {
        positionPickerGrid(
            selected: editorStore.project.canvas.contentPosition,
            onSelect: { position in
                var canvas = editorStore.project.canvas
                canvas.contentPosition = position
                performEditorCommand {
                    try editorStore.replaceCanvas(with: canvas, actionName: "快速对齐屏幕素材")
                }
            }
        )
    }

    var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let index = selectedZoomAnimationIndex {
                EditorInspectorSection("缩放片段") {
                    HStack {
                        Text("动画类型").font(.caption)
                        Spacer()
                        Label("自动缩放", systemImage: "scope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    EditorSegmentedControl(
                        options: [ZoomKeyframeOrigin.automatic, .manual],
                        title: { $0 == .automatic ? "自动跟随" : "手动定位" },
                        selection: zoomAnimationOriginBinding(index)
                    )
                    .accessibilityLabel("缩放模式")

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
                            }
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
                    Picker(
                        "动画手感",
                        selection: zoomMotionFeelPresetBinding(index)
                    ) {
                        ForEach(ZoomMotionFeelPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(
                        ZoomMotionFeelPreset(
                            animation: editorStore.previewProject.zoomAnimations[index]
                        ).detail
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    EditorDisclosure("高级曲线与速度") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("动画曲线").font(.caption.weight(.semibold))
                            ZoomCurveEditor(
                                preset: zoomAnimationEasingBinding(index),
                                customCurve: zoomAnimationCustomCurveBinding(index),
                                motion: editorStore.previewProject.motion,
                                onEditingChanged: {
                                    updateEditorContinuousInteraction(
                                        store: editorStore, isEditing: $0,
                                        commandScope: .selection,
                                        actionName: "调整缩放曲线",
                                        onError: onError
                                    )
                                }
                            )

                            sliderRow(
                                "进入时长",
                                value: zoomAnimationDoubleBinding(index, keyPath: \.enterDuration),
                                range: 0.08...3,
                                format: .seconds
                            )
                            sliderRow(
                                "退出时长",
                                value: zoomAnimationDoubleBinding(index, keyPath: \.exitDuration),
                                range: 0.08...3,
                                format: .seconds
                            )
                            Text("紫色片段结束时才开始退出；数值越大，过渡越慢。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Button("将当前曲线与速度应用到全部片段") {
                                let baseline = editorStore.project
                                var timeline = baseline.timeline
                                let easing = timeline.zoomClips[index].easing
                                let curve = timeline.zoomClips[index].customCurve
                                let enterDuration = timeline.zoomClips[index].enterDuration
                                let exitDuration = timeline.zoomClips[index].exitDuration
                                for animationIndex in timeline.zoomClips.indices {
                                    timeline.zoomClips[animationIndex].easing = easing
                                    timeline.zoomClips[animationIndex].customCurve = curve
                                    timeline.zoomClips[animationIndex].enterDuration = enterDuration
                                    timeline.zoomClips[animationIndex].exitDuration = exitDuration
                                }
                                var motion = baseline.motion
                                if easing != .custom {
                                    motion.defaultZoomEasing = easing
                                }
                                do {
                                    try editorStore.performBatch(
                                        [
                                            ProjectCommand.replacingTimeline(in: baseline, with: timeline),
                                            ProjectCommand.replacingMotion(in: baseline, with: motion),
                                        ],
                                        actionName: "应用片段运动到全部"
                                    )
                                } catch {
                                    onError(error.localizedDescription)
                                }
                            }
                            .buttonStyle(.editorQuiet)
                        }
                    }

                    EditorDisclosure("时间与精确数值") {
                        VStack(spacing: 9) {
                            zoomTimeStepper(
                                "开始位置",
                                value: zoomAnimationStartBinding(index),
                                range: 0...max(timelineDuration - 0.16, 0)
                            )
                            zoomTimeStepper(
                                "保持时长",
                                value: zoomAnimationDurationBinding(index),
                                range: 0.16...max(timelineDuration, 0.16)
                            )
                            sliderRow(
                                "焦点 X",
                                value: zoomAnimationFocusComponentBinding(index, keyPath: \.x),
                                range: 0...1,
                                format: .percent
                            )
                            sliderRow(
                                "焦点 Y",
                                value: zoomAnimationFocusComponentBinding(index, keyPath: \.y),
                                range: 0...1,
                                format: .percent
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
                .buttonStyle(.borderless)
            } else {
                // 片段选择交还时间线：这里只保留创建与选中的引导，
                // 不再用间接的文字下拉列表代替时间线。
                VStack(alignment: .leading, spacing: 6) {
                    Label("在时间线“缩放”轨道上拖动即可创建片段", systemImage: "timeline.selection")
                        .font(.caption)
                    Text("拖两端改保持时长；渐变尾部是退出。点选紫色片段后，这里会显示它的倍数、焦点与手感。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }

            EditorDisclosure("全局缩放手感") {
                VStack(alignment: .leading, spacing: 11) {
                    Picker(
                        "自动运镜风格",
                        selection: automaticCameraMotionPresetBinding
                    ) {
                        ForEach(AutomaticCameraMotionPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(automaticCameraMotionPresetDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    EditorDisclosure("高级默认参数") {
                        VStack(spacing: 10) {
                            Picker(
                                "新动画默认曲线",
                                selection: motionBinding(\.defaultZoomEasing, actionName: "调整默认缩放曲线")
                            ) {
                                ForEach(ZoomEasingPreset.allCases.filter { $0 != .custom }) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            sliderRow(
                                "新动画过渡时长",
                                value: motionBinding(
                                    \.defaultZoomTransitionDuration,
                                    actionName: "调整默认过渡时长"
                                ),
                                range: 0.08...3,
                                interactionScope: .motion,
                                format: .seconds
                            )
                            sliderRow(
                                "质量",
                                value: motionBinding(\.screenSpringMass, actionName: "调整屏幕弹簧质量"),
                                range: 0.2...8,
                                interactionScope: .motion,
                                format: .decimal1
                            )
                            sliderRow(
                                "刚度",
                                value: motionBinding(\.screenSpringStiffness, actionName: "调整屏幕弹簧刚度"),
                                range: 40...1_000,
                                interactionScope: .motion,
                                format: .points
                            )
                            sliderRow(
                                "阻尼",
                                value: motionBinding(\.screenSpringDamping, actionName: "调整屏幕弹簧阻尼"),
                                range: 4...180,
                                interactionScope: .motion,
                                format: .points
                            )
                        }
                    }
                }
            }

            EditorFrameMotionBlurControls(editorStore: editorStore, onError: onError)
        }
    }
}

private struct BundledWallpaperThumbnail: View {
    let preset: BundledWallpaperPreset
    @State private var image: NSImage?

    var body: some View {
        // 底色决定 label 的布局尺寸（≈92×50）。图片只能作为 overlay：
        // 竖幅壁纸 scaledToFill 的布局高度可达 ~161pt，若由 Image 决定
        // 尺寸，AppKit 桥接的按钮命中框会向上盖住整行分类胶囊
        // （UX-024 反复回归"切到地平线后无法换分类"的真正根因）。
        // clipShape 只裁绘制不裁布局，救不了命中框。
        Color.secondary.opacity(0.2)
            .overlay {
                if let image {
                    // scaledToFill 的 Image 自身布局尺寸是整图等比尺寸
                    // （竖幅约 92×161），会撑大 AppKit 桥接按钮的命中框并
                    // 盖住上方分类胶囊。强制其布局尺寸等于格子再 clipped。
                    GeometryReader { proxy in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                }
            }
            .task(id: preset.id) {
            let key = preset.relativePath as NSString
            if let cached = EditorInspectorView.wallpaperThumbnailCache.object(forKey: key) {
                image = cached
                return
            }
            guard let decoded = await WallpaperThumbnailLoader.image(at: preset.url),
                  !Task.isCancelled else { return }
            EditorInspectorView.wallpaperThumbnailCache.setObject(
                decoded,
                forKey: key,
                cost: WallpaperThumbnailDecoder.decodedByteCost(of: decoded)
            )
            image = decoded
        }
    }
}
