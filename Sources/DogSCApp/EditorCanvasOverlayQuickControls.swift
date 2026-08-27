import RecorderCore
import SwiftUI

extension CanvasPreview {
    @ViewBuilder
    func overlayQuickEditor(
        scene: FrameScene,
        canvasSize: CGSize,
        time: TimeInterval
    ) -> some View {
        switch editorStore.selection {
        case let .mosaic(id):
            if let clip = editorStore.previewProject.timeline.mosaicClips.first(
                where: { $0.id == id && $0.timing.contains(time) }
            ), let quad = mosaicSelectionQuad(clip: clip, screen: scene.screen) {
                mosaicQuickEditor(clip)
                    .position(quickEditorPosition(
                        bounds: CGRect(
                            x: quad.bounds.x,
                            y: quad.bounds.y,
                            width: quad.bounds.width,
                            height: quad.bounds.height
                        ),
                        canvasSize: canvasSize,
                        width: 330
                    ))
            }
        case let .sticker(id):
            if let clip = editorStore.previewProject.timeline.stickerClips.first(
                where: { $0.id == id }
            ), let sticker = scene.stickers.first(where: { $0.id == id }) {
                let width = canvasSize.width * sticker.width * sticker.scale
                let sourceSize = resolvedStickerImages[sticker.relativePath]?.size
                    ?? CGSize(width: 1, height: 1)
                let height = width * max(sourceSize.height, 1) / max(sourceSize.width, 1)
                let center = CGPoint(
                    x: canvasSize.width * (sticker.position.x + sticker.offset.x),
                    y: canvasSize.height * (sticker.position.y + sticker.offset.y)
                )
                stickerQuickEditor(clip)
                    .position(quickEditorPosition(
                        bounds: CGRect(
                            x: center.x - width / 2,
                            y: center.y - height / 2,
                            width: width,
                            height: height
                        ),
                        canvasSize: canvasSize,
                        width: 310
                    ))
            }
        case .progress:
            if let overlay = editorStore.previewProject.timeline.progressOverlay,
               let progress = scene.progress {
                let bandHeight = max(
                    CGFloat(progress.bandHeight) * canvasSize.width / 1_920,
                    24
                )
                let centerY = progressCenterY(
                    progress,
                    canvasHeight: canvasSize.height,
                    bandHeight: bandHeight
                )
                progressQuickEditor(overlay, time: time)
                    .position(quickEditorPosition(
                        bounds: CGRect(
                            x: 0,
                            y: centerY - bandHeight / 2,
                            width: canvasSize.width,
                            height: bandHeight
                        ),
                        canvasSize: canvasSize,
                        width: 390
                    ))
            }
        default:
            EmptyView()
        }
    }

    func mosaicQuickEditor(_ clip: MosaicClip) -> some View {
        quickEditorCard {
            HStack(spacing: 9) {
                quickToggle(
                    title: "柔化",
                    symbol: "drop.halffull",
                    isSelected: clip.style == .blur
                ) {
                    replaceMosaic(id: clip.id, actionName: "切换柔化模式") {
                        $0.style = .blur
                    }
                }
                quickToggle(
                    title: "突出",
                    symbol: "viewfinder",
                    isSelected: clip.style == .spotlight
                ) {
                    replaceMosaic(id: clip.id, actionName: "切换柔化模式") {
                        $0.style = .spotlight
                    }
                }
                Divider().frame(height: 22)
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Slider(
                    value: quickMosaicBinding(
                        id: clip.id,
                        keyPath: \.intensity,
                        fallback: clip.intensity
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: "调整打码强度"
                        )
                    }
                )
                .frame(width: 62)
                Image(systemName: "rectangle.roundedtop")
                    .foregroundStyle(.secondary)
                Slider(
                    value: quickMosaicBinding(
                        id: clip.id,
                        keyPath: \.cornerRadius,
                        fallback: clip.cornerRadius
                    ),
                    in: 0...0.5,
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: "调整打码圆角"
                        )
                    }
                )
                .frame(width: 62)
            }
        }
    }

    func stickerQuickEditor(_ clip: StickerClip) -> some View {
        quickEditorCard {
            HStack(spacing: 10) {
                Menu {
                    ForEach(StickerAnimationPreset.allCases, id: \.self) { preset in
                        Button(stickerAnimationTitle(preset)) {
                            replaceSticker(id: clip.id, actionName: "选择贴图动画") {
                                $0.animation = preset
                            }
                        }
                    }
                } label: {
                    Label(stickerAnimationTitle(clip.animation), systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                Divider().frame(height: 22)
                Image(systemName: "drop.halffull")
                    .foregroundStyle(.secondary)
                    .help("背景虚化")
                Slider(
                    value: quickStickerBinding(
                        id: clip.id,
                        keyPath: \.backdropBlur,
                        fallback: clip.backdropBlur
                    ),
                    in: 0...60,
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: "调整贴图背景虚化"
                        )
                    }
                )
                .frame(width: 72)
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                    .help("入场时长")
                Slider(
                    value: quickStickerBinding(
                        id: clip.id,
                        keyPath: \.enterDuration,
                        fallback: clip.enterDuration
                    ),
                    in: 0...2,
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: "调整贴图入场时长"
                        )
                    }
                )
                .frame(width: 62)
            }
        }
    }

    func progressQuickEditor(
        _ overlay: ProgressOverlay,
        time: TimeInterval
    ) -> some View {
        let chapter = overlay.chapters
            .filter { $0.time <= time }
            .max { $0.time < $1.time }
        return quickEditorCard {
            HStack(spacing: 8) {
                ForEach(ProgressOverlayPlacement.allCases, id: \.self) { placement in
                    quickToggle(
                        title: progressPlacementTitle(placement),
                        symbol: progressPlacementSymbol(placement),
                        isSelected: overlay.placement == placement
                    ) {
                        replaceProgress(actionName: "调整进度条位置") {
                            $0.placement = placement
                        }
                    }
                }
                Divider().frame(height: 22)
                if let chapter {
                    TextField(
                        "节点文字",
                        text: quickProgressChapterTitleBinding(
                            chapter.id,
                            fallback: chapter.title
                        )
                    )
                    .textFieldStyle(.plain)
                    .frame(width: 105)
                } else {
                    Text("尚无节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 105)
                }
                Button {
                    addProgressChapter(at: time)
                } label: {
                    Label("新分段", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    func quickEditorCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .foregroundStyle(Color.white.opacity(0.94))
            .background(
                Color(white: 0.055).opacity(0.97),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 9, y: 3)
    }

    func quickToggle(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    isSelected ? editorAccent : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    func quickEditorPosition(
        bounds: CGRect,
        canvasSize: CGSize,
        width: CGFloat
    ) -> CGPoint {
        let half = width / 2
        let x = min(max(bounds.midX, half + 8), canvasSize.width - half - 8)
        let above = bounds.minY - 27
        let y = above >= 24 ? above : min(bounds.maxY + 27, canvasSize.height - 24)
        return CGPoint(x: x, y: y)
    }

    func quickMosaicBinding(
        id: UUID,
        keyPath: WritableKeyPath<MosaicClip, Double>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                editorStore.previewProject.timeline.mosaicClips.first {
                    $0.id == id
                }?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                _ = editorStore.beginContinuousInteraction(
                    commandScope: .selection,
                    selection: .mosaic(id)
                )
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.mosaicClips.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    project.timeline.mosaicClips[index][keyPath: keyPath] = value
                }
            }
        )
    }

    func quickStickerBinding(
        id: UUID,
        keyPath: WritableKeyPath<StickerClip, Double>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                editorStore.previewProject.timeline.stickerClips.first {
                    $0.id == id
                }?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                _ = editorStore.beginContinuousInteraction(
                    commandScope: .selection,
                    selection: .sticker(id)
                )
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.stickerClips.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    project.timeline.stickerClips[index][keyPath: keyPath] = value
                }
            }
        )
    }

    func finishQuickOverlayInteraction(editing: Bool, actionName: String) {
        guard !editing else { return }
        do {
            _ = try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    func replaceMosaic(
        id: UUID,
        actionName: String,
        update: (inout MosaicClip) -> Void
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&timeline.mosaicClips[index])
        replaceOverlayTimeline(timeline, actionName: actionName)
        editorStore.selection = .mosaic(id)
    }

    func replaceSticker(
        id: UUID,
        actionName: String,
        update: (inout StickerClip) -> Void
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&timeline.stickerClips[index])
        replaceOverlayTimeline(timeline, actionName: actionName)
        editorStore.selection = .sticker(id)
    }

    func replaceProgress(
        actionName: String,
        update: (inout ProgressOverlay) -> Void
    ) {
        var timeline = editorStore.project.timeline
        guard var progress = timeline.progressOverlay else { return }
        update(&progress)
        timeline.progressOverlay = progress
        replaceOverlayTimeline(timeline, actionName: actionName)
        editorStore.selection = .progress
    }

    func replaceOverlayTimeline(_ timeline: ProjectTimeline, actionName: String) {
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func quickProgressChapterTitleBinding(
        _ id: UUID,
        fallback: String
    ) -> Binding<String> {
        Binding(
            get: {
                editorStore.previewProject.timeline.progressOverlay?.chapters
                    .first(where: { $0.id == id })?.title ?? fallback
            },
            set: { title in
                replaceProgress(actionName: "编辑进度节点") { progress in
                    guard let index = progress.chapters.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    progress.chapters[index].title = title
                }
            }
        )
    }

    func addProgressChapter(at time: TimeInterval) {
        replaceProgress(actionName: "添加进度节点") { progress in
            let nextNumber = progress.chapters.count + 1
            progress.insertChapterIfNeeded(
                at: max(time, 0),
                title: "看点 \(nextNumber)"
            )
        }
    }

    func stickerAnimationTitle(_ preset: StickerAnimationPreset) -> String {
        switch preset {
        case .none: return "无动画"
        case .fade: return "淡入"
        case .pop: return "弹出"
        case .slideLeft: return "从左"
        case .slideRight: return "从右"
        case .slideUp: return "从上"
        case .slideDown: return "从下"
        case .slideTopLeft: return "左上"
        case .slideTopRight: return "右上"
        case .slideBottomLeft: return "左下"
        case .slideBottomRight: return "右下"
        }
    }

    func progressPlacementTitle(_ placement: ProgressOverlayPlacement) -> String {
        switch placement {
        case .top: return "顶部"
        case .custom: return "自由"
        case .bottom: return "底部"
        }
    }

    func progressPlacementSymbol(_ placement: ProgressOverlayPlacement) -> String {
        switch placement {
        case .top: return "rectangle.topthird.inset.filled"
        case .custom: return "arrow.up.and.down"
        case .bottom: return "rectangle.bottomthird.inset.filled"
        }
    }
}
