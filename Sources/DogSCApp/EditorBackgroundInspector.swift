import AppKit
import RecorderCore
import SwiftUI

/// Owns background navigation state, wallpaper selection, gradient selection,
/// custom-image commands, and the bounded thumbnail cache.
struct EditorBackgroundInspector: View {
    @ObservedObject var editorStore: EditorStore
    let onChooseWallpaper: () -> BackgroundSource?
    let onChooseDesktopWallpaper: () -> BackgroundSource?
    let onError: (String) -> Void

    @State private var selectedBackgroundTab: BackgroundPanelTab = .wallpaper
    @State private var selectedWallpaperCollection = "Photography"
    @State private var candidateBackgroundHex = HexColor(rgb24: 0xD8_B2_6A)
    @State private var selectedSystemAssetID: String?
    @State private var selectedSystemVariantByGroup: [String: String] = [:]
    @State private var systemImageGroupLimit = 12
    @State private var systemVideoGroupLimit = 12
    @StateObject private var systemWallpaperCatalog = SystemWallpaperCatalog()

    static let wallpaperThumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    var body: some View {
            EditorInspectorSection("背景") {
                // 页签切换只浏览候选；真正选择资源或调整颜色时才写入项目。
                EditorTileSelector(
                    options: BackgroundPanelTab.allCases,
                    title: { $0.rawValue },
                    icon: { $0.icon },
                    selection: $selectedBackgroundTab
                )

                switch selectedBackgroundTab {
                case .wallpaper:
                    wallpaperLibraryGrid
                case .pattern:
                    patternGrid
                case .dynamic:
                    dynamicFlowGrid
                case .gradient:
                    gradientGrid
                case .color:
                    EditorTransactionalColorInput(
                        editorStore: editorStore,
                        title: "背景颜色",
                        value: backgroundColorBinding,
                        commandScope: .canvas,
                        actionName: "调整背景颜色",
                        onError: onError
                    )
                case .image:
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: chooseWallpaper) {
                            Label("选择图片或视频…", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.editorQuiet)
                        Button(action: chooseDesktopWallpaper) {
                            Label("使用当前桌面壁纸", systemImage: "desktopcomputer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.editorQuiet)
                        Text("支持静态图片和 MOV/MP4 动态背景；视频会循环播放并参与导出。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .onAppear {
                synchronizeBackgroundNavigation(
                    with: editorStore.project.canvas.backgroundSource
                )
            }
            .onChange(of: editorStore.project.canvas.backgroundSource) { _, source in
                synchronizeBackgroundNavigation(with: source)
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
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.editorQuiet)
                .help("随机壁纸")
                .accessibilityLabel("随机壁纸")
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
                            .frame(width: itemWidth, height: 30)
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
                                withAnimation(SpringMotion.interactive) {
                                    selectedWallpaperCollection = collection.name
                                }
                            }
                            .help("切换到\(collection.displayName)分类")
                            .accessibilityLabel(collection.displayName)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .frame(height: 30)
            .animation(SpringMotion.interactive, value: selectedWallpaperCollection)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(selectedBundledWallpaperCollection?.wallpapers ?? []) { preset in
                    let isSelected = selectedBundledWallpaperPath == preset.relativePath
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
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(
                                        isSelected
                                            ? LinearGradient(
                                                colors: [Color.white, Color(white: 0.85)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            : LinearGradient(
                                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                            .overlay(alignment: .topTrailing) {
                                if isSelected {
                                    ZStack {
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 15, height: 15)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(Color.black)
                                    }
                                    .padding(3)
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .scaleEffect(isSelected ? 1.02 : 1.0)
                            .animation(SpringMotion.interactive, value: isSelected)
                    }
                    .buttonStyle(.editorThumbnail)
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }


            if BundledWallpaperLibrary.collections.isEmpty {
                Text("未找到内置壁纸资源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            systemWallpaperSection
        }
        .task {
            // 后台预热全部缩略图：首次切换集合的网格立即呈现，不再逐格
            // 等待大图首次解码（此前让切换看起来"没反应"）。
            await WallpaperThumbnailLoader.prewarmAll(
                into: EditorBackgroundInspector.wallpaperThumbnailCache
            )
            await systemWallpaperCatalog.refresh()
            synchronizeSystemWallpaperSelection(
                with: editorStore.project.canvas.backgroundSource
            )
            await systemWallpaperCatalog.monitorChanges()
        }
        .onChange(of: systemWallpaperCatalog.assets) { _, _ in
            synchronizeSystemWallpaperSelection(
                with: editorStore.project.canvas.backgroundSource
            )
        }

    }

    var selectedBundledWallpaperCollection: BundledWallpaperCollection? {
        BundledWallpaperLibrary.collections.first { $0.name == selectedWallpaperCollection }
            ?? BundledWallpaperLibrary.collections.first
    }

    @ViewBuilder
    var systemWallpaperSection: some View {
        Divider().padding(.vertical, 2)

        HStack {
            Text("本机壁纸").font(.caption.weight(.semibold))
            Spacer()
            if systemWallpaperCatalog.isLoading {
                ProgressView().controlSize(.mini)
            }
            Button {
                Task { await systemWallpaperCatalog.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.editorQuiet)
            .disabled(systemWallpaperCatalog.isLoading)
            .help("重新读取本机壁纸")
            .accessibilityLabel("重新读取本机壁纸")
        }

        if let currentGroup = systemWallpaperCatalog.currentDesktopGroup {
            Text("当前桌面")
                .font(.caption2)
                .foregroundStyle(.secondary)
            systemGroupGrid([currentGroup])
        } else if let issue = systemWallpaperCatalog.currentDesktopIssue {
            Label(issue, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !systemWallpaperCatalog.imageGroups.isEmpty {
            Text("系统壁纸")
                .font(.caption2)
                .foregroundStyle(.secondary)
            systemGroupGrid(
                Array(systemWallpaperCatalog.imageGroups.prefix(systemImageGroupLimit))
            )
            if systemWallpaperCatalog.imageGroups.count > systemImageGroupLimit {
                Button("显示更多系统壁纸") {
                    systemImageGroupLimit += 16
                }
                .buttonStyle(.editorQuiet)
            }
        }

        Text("已安装屏保视频")
            .font(.caption2)
            .foregroundStyle(.secondary)
        if systemWallpaperCatalog.videoGroups.isEmpty, !systemWallpaperCatalog.isLoading {
            Label(
                "当前 Mac 没有可读的本地屏保视频；下载后会自动出现在这里。",
                systemImage: "film.stack"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            systemGroupGrid(
                Array(systemWallpaperCatalog.videoGroups.prefix(systemVideoGroupLimit))
            )
            if systemWallpaperCatalog.videoGroups.count > systemVideoGroupLimit {
                Button("显示更多屏保视频") {
                    systemVideoGroupLimit += 16
                }
                .buttonStyle(.editorQuiet)
            }
        }
        Text("引用本机原始资源，不复制进项目；同款颜色已合并。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func systemGroupGrid(_ groups: [SystemWallpaperGroup]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 9
        ) {
            ForEach(groups) { group in
                systemWallpaperGroupCard(group)
            }
        }
    }

    @ViewBuilder
    func systemWallpaperGroupCard(_ group: SystemWallpaperGroup) -> some View {
        if let asset = preferredAsset(for: group) {
            let isSelected = group.assets.contains { $0.id == selectedSystemAssetID }
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    selectSystemAsset(asset, in: group)
                } label: {
                    Color(white: 0.12)
                        .frame(height: 72)
                        .overlay {
                            SystemWallpaperThumbnail(asset: asset)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(
                                    isSelected ? Color.white : Color.white.opacity(0.12),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        }
                        .overlay(alignment: .topTrailing) {
                            if asset.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(.black.opacity(0.55), in: Circle())
                                    .padding(5)
                            }
                        }
                }
                .buttonStyle(.editorThumbnail)
                .help("\(group.name) · \(asset.variantName)")
                .accessibilityLabel("\(group.name)，\(asset.variantName)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                HStack(spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if group.assets.count > 1 {
                        Menu {
                            ForEach(group.assets) { variant in
                                Button {
                                    selectSystemAsset(variant, in: group)
                                } label: {
                                    if selectedSystemAssetID == variant.id {
                                        Label(variant.variantName, systemImage: "checkmark")
                                    } else {
                                        Text(variant.variantName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                variantSwatch(for: asset)
                                Text("\(group.assets.count)")
                                    .font(.system(size: 8, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .padding(.horizontal, 5)
                            .frame(height: 20)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("选择 \(group.name) 的颜色或版本")
                        .accessibilityLabel("\(group.name) 版本，当前 \(asset.variantName)")
                    } else {
                        Text(asset.variantName)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func variantSwatch(for asset: SystemWallpaperAsset) -> some View {
        if let rgb = asset.variantColorRGB {
            Circle()
                .fill(Color(hex: HexColor(rgb24: rgb)))
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        } else {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 8))
        }
    }

    func preferredAsset(for group: SystemWallpaperGroup) -> SystemWallpaperAsset? {
        if let id = selectedSystemVariantByGroup[group.id],
           let remembered = group.assets.first(where: { $0.id == id }) {
            return remembered
        }
        if let selectedSystemAssetID,
           let selected = group.assets.first(where: { $0.id == selectedSystemAssetID }) {
            return selected
        }
        return group.preferredAsset
    }

    func selectSystemAsset(
        _ asset: SystemWallpaperAsset,
        in group: SystemWallpaperGroup
    ) {
        selectedSystemVariantByGroup[group.id] = asset.id
        selectedSystemAssetID = asset.id
        selectedBackgroundTab = .wallpaper
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = asset.isVideo
            ? .systemVideo(absolutePath: asset.url.path)
            : .systemImage(absolutePath: asset.url.path)
        performEditorCommand {
            try editorStore.replaceCanvas(
                with: canvas,
                actionName: asset.isVideo ? "选择屏保视频" : "选择系统壁纸"
            )
        }
    }

    var selectedBundledWallpaperPath: String? {
        guard case let .bundledImage(relativePath) = editorStore.project.canvas.backgroundSource else {
            return nil
        }
        return relativePath
    }

    func selectBundledWallpaper(_ preset: BundledWallpaperPreset) {
        selectedSystemAssetID = nil
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = .bundledImage(relativePath: preset.relativePath)
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "选择内置壁纸")
        }
    }

    func chooseWallpaper() {
        guard let source = onChooseWallpaper() else { return }
        selectedSystemAssetID = nil
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = source
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "选择自定义壁纸")
        }
    }

    func chooseDesktopWallpaper() {
        guard let source = onChooseDesktopWallpaper() else { return }
        selectedSystemAssetID = nil
        var canvas = editorStore.project.canvas
        canvas.backgroundSource = source
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "使用当前桌面壁纸")
        }
    }

    func synchronizeBackgroundNavigation(with source: BackgroundSource) {
        switch source {
        case let .bundledImage(relativePath):
            selectedSystemAssetID = nil
            selectedBackgroundTab = .wallpaper
            if let collection = BundledWallpaperLibrary.collections.first(where: {
                $0.wallpapers.contains(where: { $0.relativePath == relativePath })
            }) {
                selectedWallpaperCollection = collection.name
            }
        case .pattern:
            selectedSystemAssetID = nil
            selectedBackgroundTab = .pattern
        case .dynamicFlow:
            selectedSystemAssetID = nil
            selectedBackgroundTab = .dynamic
        case .projectImage, .projectVideo:
            selectedSystemAssetID = nil
            selectedBackgroundTab = .image
        case let .systemImage(absolutePath), let .systemVideo(absolutePath):
            selectedBackgroundTab = .wallpaper
            let normalized = URL(fileURLWithPath: absolutePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            selectedSystemAssetID = systemWallpaperCatalog.assets.first(where: {
                $0.url.standardizedFileURL.resolvingSymlinksInPath().path == normalized
            })?.id
        case .gradient:
            selectedSystemAssetID = nil
            selectedBackgroundTab = .gradient
        case let .solidColor(hex):
            selectedSystemAssetID = nil
            selectedBackgroundTab = .color
            // 记住当前纯色作为候选：切去壁纸再切回"颜色"页时仍可一键还原，
            // 不再因为页签切换丢掉用户选过的颜色。
            candidateBackgroundHex = hex
        }
    }

    /// Loading the system catalog finishes after the wallpaper browser is
    /// already visible. At that point only restore the matching system asset;
    /// re-running the full navigation synchronizer would read the project's
    /// current background (for example `.dynamicFlow`) and bounce the user's
    /// freshly selected "壁纸" tab straight back to another tab.
    func synchronizeSystemWallpaperSelection(with source: BackgroundSource) {
        let absolutePath: String
        switch source {
        case let .systemImage(path), let .systemVideo(path):
            absolutePath = path
        default:
            return
        }

        let normalized = URL(fileURLWithPath: absolutePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        selectedSystemAssetID = systemWallpaperCatalog.assets.first(where: {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path == normalized
        })?.id
    }

    var patternGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(BackgroundPatternPreset.allCases) { preset in
                    let isSelected = editorStore.project.canvas.backgroundSource == .pattern(preset)
                    Button {
                        var canvas = editorStore.project.canvas
                        canvas.backgroundSource = .pattern(preset)
                        performEditorCommand {
                            try editorStore.replaceCanvas(with: canvas, actionName: "选择纹理网格")
                        }
                    } label: {
                        PatternMiniatureView(preset: preset)
                            .frame(height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(alignment: .bottomLeading) {
                                Text(preset.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(preset == .engineeringWhiteGrid || preset == .architecturalDots ? .black.opacity(0.85) : .white)
                                    .padding(7)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(
                                        isSelected ? editorAccent : .white.opacity(0.12),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.editorThumbnail)
                    .accessibilityLabel(preset.rawValue)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            patternControlSliders
        }
    }

    var dynamicFlowGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(DynamicBackgroundPreset.allCases) { preset in
                    let isSelected = editorStore.project.canvas.backgroundSource == .dynamicFlow(preset)
                    Button {
                        var canvas = editorStore.project.canvas
                        canvas.backgroundSource = .dynamicFlow(preset)
                        performEditorCommand {
                            try editorStore.replaceCanvas(with: canvas, actionName: "选择动态背景")
                        }
                    } label: {
                        DynamicFlowMiniatureView(preset: preset)
                            .frame(height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(alignment: .bottomLeading) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(editorAccent)
                                        .frame(width: 5, height: 5)
                                    Text(preset.displayName)
                                        .font(.caption2.weight(.semibold))
                                }
                                .padding(7)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(
                                        isSelected ? editorAccent : .white.opacity(0.12),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.editorThumbnail)
                    .accessibilityLabel(preset.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            patternControlSliders
        }
    }

    private var patternScaleBinding: Binding<Double> {
        editorCanvasBinding(
            store: editorStore,
            keyPath: \.patternScale,
            actionName: "调整图案大小",
            onError: onError
        )
    }

    private var patternOpacityBinding: Binding<Double> {
        editorCanvasBinding(
            store: editorStore,
            keyPath: \.patternOpacity,
            actionName: "调整图案不透明度",
            onError: onError
        )
    }

    private var patternControlSliders: some View {
        VStack(spacing: 8) {
            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: "图案大小",
                value: patternScaleBinding,
                range: 0.5...5.0,
                commandScope: .canvas,
                format: .multiplier,
                onError: onError
            )

            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: "不透明度",
                value: patternOpacityBinding,
                range: 0.0...1.0,
                commandScope: .canvas,
                format: .percent,
                onError: onError
            )
        }
        .padding(.top, 6)
    }

    var gradientGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(BackgroundGradientPreset.allCases, id: \.self) { preset in
                let isSelected = editorStore.project.canvas.backgroundSource == .gradient(preset)
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
                                isSelected ? .white : .white.opacity(0.1),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.editorThumbnail)
                .accessibilityLabel(gradientName(for: preset))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func performEditorCommand(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private var backgroundColorBinding: Binding<HexColor> {
        Binding(
            get: {
                if case let .solidColor(hex) = editorStore.previewProject.canvas.backgroundSource {
                    return hex
                }
                return candidateBackgroundHex
            },
            set: { color in
                candidateBackgroundHex = color
                if editorStore.interaction?.commandScope == .canvas {
                    editorStore.updateInteraction { project in
                        project.canvas.backgroundSource = .solidColor(hex: color)
                    }
                    return
                }
                var canvas = editorStore.project.canvas
                canvas.backgroundSource = .solidColor(hex: color)
                performEditorCommand {
                    try editorStore.replaceCanvas(
                        with: canvas,
                        actionName: "调整背景颜色"
                    )
                }
            }
        )
    }

    func gradientName(for preset: BackgroundGradientPreset) -> String {
        switch preset {
        case .aurora: return "极光"
        case .twilight: return "暮色"
        case .sunrise: return "日出"
        case .graphite: return "石墨"
        }
    }

    func gradientColors(for preset: BackgroundGradientPreset) -> [Color] {
        switch preset {
        case .aurora:
            return [
                Color(hex: HexColor(rgb24: 0x6A_5A_E0)),
                Color(hex: HexColor(rgb24: 0x2D_B7_D3)),
            ]
        case .twilight:
            return [
                Color(hex: HexColor(rgb24: 0x30_2B_63)),
                Color(hex: HexColor(rgb24: 0xD7_6D_77)),
            ]
        case .sunrise:
            return [
                Color(hex: HexColor(rgb24: 0xFF_8A_5B)),
                Color(hex: HexColor(rgb24: 0xFF_D5_6B)),
            ]
        case .graphite:
            return [
                Color(hex: HexColor(rgb24: 0x12_15_1C)),
                Color(hex: HexColor(rgb24: 0x45_4B_58)),
            ]
        }
    }
}

private struct PatternMiniatureView: View {
    let preset: BackgroundPatternPreset

    var body: some View {
        ZStack {
            switch preset {
            case .obsidianGrid:
                Color(white: 0.06)
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 12
                    for x in stride(from: CGFloat(0), through: size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: CGFloat(0), through: size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(path, with: .color(Color(white: 0.24)), lineWidth: 0.75)
                }
            case .engineeringWhiteGrid:
                Color(white: 0.97)
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 12
                    for x in stride(from: CGFloat(0), through: size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: CGFloat(0), through: size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(path, with: .color(Color(white: 0.79)), lineWidth: 0.75)
                }
            case .midnightDots:
                Color(white: 0.065)
                Canvas { context, size in
                    let step: CGFloat = 10
                    for x in stride(from: step / 2, through: size.width, by: step) {
                        for y in stride(from: step / 2, through: size.height, by: step) {
                            let dotRect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                            context.fill(Path(ellipseIn: dotRect), with: .color(Color(red: 0.76, green: 0.68, blue: 0.54)))
                        }
                    }
                }
            case .architecturalDots:
                Color(white: 0.975)
                Canvas { context, size in
                    let step: CGFloat = 10
                    for x in stride(from: step / 2, through: size.width, by: step) {
                        for y in stride(from: step / 2, through: size.height, by: step) {
                            let dotRect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                            context.fill(Path(ellipseIn: dotRect), with: .color(Color(white: 0.58)))
                        }
                    }
                }
            case .isometricMesh:
                Color(white: 0.075)
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 14
                    for offset in stride(from: -size.height, through: size.width + size.height, by: step) {
                        path.move(to: CGPoint(x: offset, y: 0))
                        path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                        path.move(to: CGPoint(x: offset, y: size.height))
                        path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                    }
                    context.stroke(path, with: .color(Color(red: 0.31, green: 0.29, blue: 0.26)), lineWidth: 0.75)
                }
            }
        }
    }
}

private struct DynamicFlowMiniatureView: View {
    let preset: DynamicBackgroundPreset
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducesMotion)) { timeline in
            let time = reducesMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                switch preset {
                case .cyberDriftGrid:
                    RadialGradient(
                        colors: [
                            Color(red: 0.28, green: 0.20, blue: 0.11),
                            Color(white: 0.045),
                        ],
                        center: UnitPoint(
                            x: 0.5 + 0.12 * sin(time * 0.35),
                            y: 0.5 + 0.12 * cos(time * 0.35)
                        ),
                        startRadius: 4,
                        endRadius: 50
                    )
                    movingGrid(time: time)
                case .starfieldDots:
                    Color(white: 0.055)
                    movingDots(time: time)
                case .auroraFluid:
                    fluidClouds(time: time)
                }
            }
        }
    }

    private func fluidClouds(time: TimeInterval) -> some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.085, blue: 0.20),
                        Color(red: 0.015, green: 0.028, blue: 0.075),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                fluidBlob(
                    color: Color(red: 0.08, green: 0.42, blue: 0.96),
                    size: proxy.size.width * 0.92,
                    x: proxy.size.width * (0.28 + 0.16 * cos(time * 0.19)),
                    y: proxy.size.height * (0.32 + 0.18 * sin(time * 0.27))
                )
                fluidBlob(
                    color: Color(red: 0.08, green: 0.83, blue: 0.96),
                    size: proxy.size.width * 0.70,
                    x: proxy.size.width * (0.72 + 0.13 * sin(time * 0.14)),
                    y: proxy.size.height * (0.68 + 0.16 * cos(time * 0.22))
                )
                fluidBlob(
                    color: Color.white,
                    size: proxy.size.width * 0.48,
                    x: proxy.size.width * (0.52 + 0.17 * cos(time * 0.11 + 1.4)),
                    y: proxy.size.height * (0.45 + 0.14 * sin(time * 0.17 + 1.4))
                )
            }
            .clipped()
        }
    }

    private func fluidBlob(
        color: Color,
        size: CGFloat,
        x: CGFloat,
        y: CGFloat
    ) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.86), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .position(x: x, y: y)
            .blendMode(.screen)
    }

    private func movingGrid(time: TimeInterval) -> some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 18
            let xPhase = CGFloat((time * 1.8).truncatingRemainder(dividingBy: step))
            let yPhase = CGFloat((time * 1.2).truncatingRemainder(dividingBy: step))
            for x in stride(from: -step + xPhase, through: size.width + step, by: step) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: -step + yPhase, through: size.height + step, by: step) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                path,
                with: .color(Color(red: 0.72, green: 0.62, blue: 0.46).opacity(0.55)),
                lineWidth: 0.75
            )
        }
    }

    private func movingDots(time: TimeInterval) -> some View {
        Canvas { context, size in
            let step: CGFloat = 15
            let xPhase = CGFloat((time * 1.1).truncatingRemainder(dividingBy: step))
            let yPhase = CGFloat((time * 0.7).truncatingRemainder(dividingBy: step))
            for x in stride(from: -step / 2 + xPhase, through: size.width + step, by: step) {
                for y in stride(from: -step / 2 + yPhase, through: size.height + step, by: step) {
                    let dotRect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    context.fill(
                        Path(ellipseIn: dotRect),
                        with: .color(Color(red: 0.78, green: 0.69, blue: 0.54).opacity(0.82))
                    )
                }
            }
        }
    }
}

private struct BundledWallpaperThumbnail: View {
    let preset: BundledWallpaperPreset
    @State private var image: NSImage?

    var body: some View {
        Color.secondary.opacity(0.2)
            .overlay {
                if let image {
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
            if let cached = EditorBackgroundInspector.wallpaperThumbnailCache.object(forKey: key) {
                image = cached
                return
            }
            guard let decoded = await WallpaperThumbnailLoader.image(at: preset.url),
                  !Task.isCancelled else { return }
            EditorBackgroundInspector.wallpaperThumbnailCache.setObject(
                decoded,
                forKey: key,
                cost: WallpaperThumbnailDecoder.decodedByteCost(of: decoded)
            )
            image = decoded
        }
    }
}
