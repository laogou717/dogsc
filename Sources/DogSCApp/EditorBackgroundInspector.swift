import AppKit
import RecorderCore
import SwiftUI

/// Keeps the canvas background focused on four useful sources: the current
/// Mac's wallpapers, simple patterns, dynamic backgrounds, and custom media.
struct EditorBackgroundInspector: View {
    @ObservedObject var editorStore: EditorStore
    let onChooseWallpaper: () -> BackgroundSource?
    let onChooseDesktopWallpaper: () -> BackgroundSource?
    let onError: (String) -> Void

    @State private var selectedBackgroundTab: BackgroundPanelTab = .wallpaper
    @State private var selectedSystemAssetID: String?
    @State private var selectedSystemVariantByGroup: [String: String] = [:]
    @State private var systemImageGroupLimit = 12
    @State private var systemVideoGroupLimit = 12
    @StateObject private var systemWallpaperCatalog = SystemWallpaperCatalog()

    var body: some View {
            EditorInspectorSection("背景素材") {
                // 页签切换只浏览候选；真正选择资源或调整颜色时才写入项目。
                EditorSegmentedControl(
                    options: BackgroundPanelTab.allCases,
                    title: { $0.localizedLabel },
                    icon: { $0.icon },
                    selection: $selectedBackgroundTab
                )

                Group {
                switch selectedBackgroundTab {
                case .wallpaper:
                    wallpaperLibraryGrid
                case .pattern:
                    patternGrid
                case .dynamic:
                    dynamicFlowGrid
                case .image:
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: chooseWallpaper) {
                            Label("选择图片或视频…", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.editorQuiet)
                        Text("支持静态图片和 MOV/MP4 动态背景；视频会循环播放并参与导出。")
                            .font(.appUI(.caption2))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }
                .id(selectedBackgroundTab)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            .animation(SpringMotion.fluid, value: selectedBackgroundTab)
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
        systemWallpaperSection
            .task {
                await systemWallpaperCatalog.loadIfNeeded()
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

    @ViewBuilder
    var systemWallpaperSection: some View {
        HStack {
            Text("本机壁纸").font(.appUI(size: 12, weight: .medium)).foregroundStyle(.secondary)
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

        let current = systemWallpaperCatalog.currentDesktopGroup
        let images = Array(systemWallpaperCatalog.imageGroups.prefix(systemImageGroupLimit))
        let groups = (current.map { [$0] } ?? []) + images.filter { $0.id != current?.id }
        systemGroupGrid(groups)
        if let issue = systemWallpaperCatalog.currentDesktopIssue, current == nil {
            Text(issue).font(.appUI(size: 11)).foregroundStyle(.secondary)
        }
        if systemWallpaperCatalog.imageGroups.count > systemImageGroupLimit {
            Button("显示更多壁纸") { systemImageGroupLimit += 16 }
                .buttonStyle(.editorGhost)
        }
        if !systemWallpaperCatalog.videoGroups.isEmpty {
            Text("动态壁纸").font(.appUI(size: 11)).foregroundStyle(.secondary)
            systemGroupGrid(Array(systemWallpaperCatalog.videoGroups.prefix(systemVideoGroupLimit)))
            if systemWallpaperCatalog.videoGroups.count > systemVideoGroupLimit {
                Button("显示更多动态壁纸") { systemVideoGroupLimit += 16 }
                    .buttonStyle(.editorGhost)
            }
        }
    }

    func systemGroupGrid(_ groups: [SystemWallpaperGroup]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
            ForEach(groups) { group in systemWallpaperGroupCard(group) }
        }
    }

    @ViewBuilder
    func systemWallpaperGroupCard(_ group: SystemWallpaperGroup) -> some View {
        if let asset = preferredAsset(for: group) {
            let isSelected = group.assets.contains { $0.id == selectedSystemAssetID }
            VStack(spacing: 5) {
                Button { selectSystemAsset(asset, in: group) } label: {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { SystemWallpaperThumbnail(asset: asset) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isSelected ? EditorTheme.selectionTint : EditorTheme.chrome(0.08), lineWidth: isSelected ? 2 : 0.75)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.appUI(size: 8, weight: .semibold))
                                    .foregroundStyle(EditorTheme.selectionTint)
                                    .frame(width: 17, height: 17).background(.white, in: Circle()).padding(5)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if asset.isVideo {
                                Image(systemName: "play.fill").font(.appUI(size: 8))
                                    .foregroundStyle(.white).padding(5)
                                    .background(.black.opacity(0.4), in: Circle()).padding(5)
                            }
                        }
                }
                .buttonStyle(.editorThumbnail)
                .focusEffectDisabled()
                .help("\(group.name) · \(asset.variantName)")
                .accessibilityLabel("\(group.name)，\(asset.variantName)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if group.assets.count > 1 {
                    EditorActionMenu(title: group.name, items: group.assets.map { variant in
                        .action(variant.variantName, isOn: selectedSystemAssetID == variant.id) {
                            selectSystemAsset(variant, in: group)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Text(group.name).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.appUI(size: 8))
                        }.font(.appUI(size: 11)).foregroundStyle(EditorTheme.chrome(0.65))
                            .frame(maxWidth: .infinity).frame(height: 20)
                    }
                    .accessibilityLabel("\(group.name) 版本，当前 \(asset.variantName)")
                } else {
                    Text(group.name).font(.appUI(size: 11)).foregroundStyle(EditorTheme.chrome(0.65))
                        .lineLimit(1).frame(height: 20)
                }
            }
            .animation(SpringMotion.interactive, value: isSelected)
        }
    }

    @ViewBuilder
    func variantSwatch(for asset: SystemWallpaperAsset) -> some View {
        if let rgb = asset.variantColorRGB {
            Circle()
                .fill(Color(hex: HexColor(rgb24: rgb)))
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(EditorTheme.chrome(0.25), lineWidth: 0.5))
        } else {
            Image(systemName: "circle.lefthalf.filled")
                .font(.appUI(size: 8))
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 110), spacing: 10)], spacing: 10) {
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
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(alignment: .bottomLeading) {
                                Text(appLocalized(preset.rawValue))
                                    .font(.appUI(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(6)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(
                                        isSelected ? editorAccent : EditorTheme.chrome(0.12),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.editorThumbnail)
                    .accessibilityLabel(appLocalized(preset.rawValue))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            patternControlSliders
        }
    }

    var dynamicFlowGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 110), spacing: 10)], spacing: 10) {
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
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(alignment: .bottomLeading) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 5, height: 5)
                                    Text(appLocalized(preset.displayName))
                                        .font(.appUI(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(6)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(
                                        isSelected ? editorAccent : EditorTheme.chrome(0.12),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.editorThumbnail)
                    .accessibilityLabel(appLocalized(preset.displayName))
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


    private func performEditorCommand(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            onError(error.localizedDescription)
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
    @Environment(\.editorIsActive) private var isEditorActive
    @State private var isHovered = false
    @State private var isAnimating = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducesMotion || !isEditorActive || !isAnimating)) { timeline in
            let time = reducesMotion || !isEditorActive || !isAnimating ? 0 : timeline.date.timeIntervalSinceReferenceDate
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
        .onHover { isHovered = $0 }
        .task(id: "\(isHovered):\(isEditorActive)") {
            isAnimating = isHovered && isEditorActive && !reducesMotion
            guard isAnimating else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            isAnimating = false
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
