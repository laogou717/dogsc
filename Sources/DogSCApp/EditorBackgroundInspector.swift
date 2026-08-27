import AppKit
import RecorderCore
import SwiftUI

/// Owns background navigation state, wallpaper selection, gradient selection,
/// custom-image commands, and the bounded thumbnail cache.
struct EditorBackgroundInspector: View {
    @ObservedObject var editorStore: EditorStore
    let onChooseWallpaper: () -> String?
    let onChooseDesktopWallpaper: () -> String?
    let onError: (String) -> Void

    @State private var selectedBackgroundTab: BackgroundPanelTab = .wallpaper
    @State private var selectedWallpaperCollection = "Photography"
    @State private var candidateBackgroundHex = HexColor(rgb24: 0xD9_C8_FF)

    static let wallpaperThumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    var body: some View {
            EditorInspectorSection("背景") {
                GeometryReader { proxy in
                    let spacing: CGFloat = 3
                    let tabs = BackgroundPanelTab.allCases
                    let count = max(tabs.count, 1)
                    let itemWidth = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
                    HStack(spacing: spacing) {
                        ForEach(tabs) { tab in
                            let isSelected = selectedBackgroundTab == tab
                            Button {
                                // 页签切换只是浏览；真正选择资源或调整颜色时
                                // 才把可见结果写入项目。
                                selectedBackgroundTab = tab
                            } label: {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(
                                        isSelected
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
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                }
                .buttonStyle(.borderless)
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
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        isSelected ? editorAccent : Color.white.opacity(0.1),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
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
        }
        .task {
            // 后台预热全部缩略图：首次切换集合的网格立即呈现，不再逐格
            // 等待大图首次解码（此前让切换看起来"没反应"）。
            await WallpaperThumbnailLoader.prewarmAll(
                into: EditorBackgroundInspector.wallpaperThumbnailCache
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
                .buttonStyle(.plain)
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
