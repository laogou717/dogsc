import RecorderCore
import SwiftUI

private struct CanvasQuickEditorPlacement {
    let point: CGPoint
    let transitionAnchor: UnitPoint
}

private struct CanvasQuickMenuLabel: View {
    let title: String
    let systemImage: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Label(title, systemImage: systemImage)
            Image(systemName: "chevron.down")
                .font(.appUI(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
        .background(
            EditorTheme.chrome(isHovered ? 0.10 : 0.055),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    EditorTheme.chrome(isHovered ? 0.18 : 0.09),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .scaleEffect(isHovered ? 1.018 : 1)
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
    }
}

extension CanvasPreview {
    @ViewBuilder
    func overlayQuickEditor(
        scene: FrameScene,
        canvasSize: CGSize,
        time: TimeInterval
    ) -> some View {
        Group {
            switch editorStore.selection {
            case let .mosaic(id):
                if let clip = editorStore.previewProject.timeline.mosaicClips.first(
                    where: { $0.id == id && $0.timing.contains(time) }
                ), let quad = mosaicSelectionQuad(clip: clip, screen: scene.screen) {
                    let placement = quickEditorPlacement(
                        bounds: CGRect(
                            x: quad.bounds.x,
                            y: quad.bounds.y,
                            width: quad.bounds.width,
                            height: quad.bounds.height
                        ),
                        canvasSize: canvasSize,
                        width: 420
                    )
                    mosaicQuickEditor(clip)
                        .position(placement.point)
                        .transition(
                            quickEditorTransition(anchor: placement.transitionAnchor)
                        )
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
                    let bounds = rotatedStickerBounds(
                        center: center,
                        size: CGSize(width: width, height: height),
                        rotation: sticker.rotationRadians
                    )
                    let rotationHandle = stickerRotationHandleGeometry(
                        center: center,
                        size: CGSize(width: width, height: height),
                        rotation: sticker.rotationRadians,
                        canvasSize: canvasSize
                    )
                    let interactionBounds = bounds.union(CGRect(
                        x: rotationHandle.handle.x - 9,
                        y: rotationHandle.handle.y - 9,
                        width: 18,
                        height: 18
                    ))
                    let placement = quickEditorPlacement(
                        bounds: interactionBounds,
                        canvasSize: canvasSize,
                        width: 324
                    )
                    stickerQuickEditor(clip)
                        .position(placement.point)
                        .transition(
                            quickEditorTransition(anchor: placement.transitionAnchor)
                        )
                }
            default:
                EmptyView()
            }
        }
        .animation(SpringMotion.fluid, value: editorStore.selection)
    }

    func quickEditorTransition(anchor: UnitPoint) -> AnyTransition {
        .scale(scale: 0.94, anchor: anchor).combined(with: .opacity)
    }

    func mosaicQuickEditor(_ clip: MosaicClip) -> some View {
        quickEditorCard {
            HStack(spacing: 8) {
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
                let editsSpotlight = clip.style == .spotlight
                Label(
                    editsSpotlight ? "暗度" : "强度",
                    systemImage: "circle.lefthalf.filled"
                )
                    .font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(EditorTheme.chrome(0.68))
                EditorSlider(
                    value: quickMosaicBinding(
                        id: clip.id,
                        keyPath: editsSpotlight
                            ? \.spotlightDimming
                            : \.intensity,
                        fallback: editsSpotlight
                            ? clip.spotlightDimming
                            : clip.intensity
                    ),
                    range: editsSpotlight ? 0...0.75 : 0...1,
                    formatValue: { "\(Int(($0 * 100).rounded()))%" },
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: editsSpotlight
                                ? "调整突出暗度"
                                : "调整柔化强度"
                        )
                    }
                )
                .frame(width: 70)
                .accessibilityLabel(editsSpotlight ? "突出暗度" : "柔化强度")
                .accessibilityValue(
                    "\(Int(((editsSpotlight ? clip.spotlightDimming : clip.intensity) * 100).rounded()))%"
                )
                Divider().frame(height: 22)
                Label("圆角", systemImage: "square")
                    .font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(EditorTheme.chrome(0.68))
                EditorSlider(
                    value: quickMosaicBinding(
                        id: clip.id,
                        keyPath: \.cornerRadius,
                        fallback: clip.cornerRadius
                    ),
                    range: 0...0.5,
                    formatValue: { "\(Int(($0 * 100).rounded()))%" },
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: "调整柔化圆角"
                        )
                    }
                )
                .frame(width: 70)
                .accessibilityLabel("柔化区域圆角")
                .accessibilityValue("\(Int((clip.cornerRadius * 100).rounded()))%")
            }
        }
    }

    func stickerQuickEditor(_ clip: StickerClip) -> some View {
        quickEditorCard {
            HStack(spacing: 9) {
                EditorActionMenu(title: "贴图动画", items: StickerAnimationPreset.allCases.map { preset in
                    .action(stickerAnimationTitle(preset), isOn: clip.animation == preset) {
                        replaceSticker(id: clip.id, actionName: "选择贴图动画") { $0.animation = preset }
                    }
                }) {
                    CanvasQuickMenuLabel(
                        title: stickerAnimationTitle(clip.animation),
                        systemImage: "sparkles"
                    )
                }
                .help("选择贴图动画")
                .accessibilityLabel("贴图动画")
                .accessibilityValue(stickerAnimationTitle(clip.animation))
                Divider().frame(height: 22)
                Label("虚化", systemImage: "drop.halffull")
                    .font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(EditorTheme.chrome(clip.hidesScreen ? 0.30 : 0.68))
                EditorSlider(
                    value: quickStickerBinding(
                        id: clip.id,
                        keyPath: \.backdropBlur,
                        fallback: clip.backdropBlur
                    ),
                    range: 0...60,
                    formatValue: { String(format: "%.0f", $0) },
                    onEditingChanged: { editing in
                        finishQuickOverlayInteraction(
                            editing: editing,
                            actionName: "调整贴图录屏虚化"
                        )
                    }
                )
                .frame(width: 72)
                .disabled(clip.hidesScreen)
                .opacity(clip.hidesScreen ? 0.42 : 1)
                .accessibilityLabel("贴图录屏虚化")
                .accessibilityValue(
                    clip.hidesScreen
                        ? "仅背景模式下不可用"
                        : String(format: "%.0f", clip.backdropBlur)
                )
                Divider().frame(height: 22)
                quickToggle(
                    title: "仅背景",
                    symbol: "rectangle.slash",
                    isSelected: clip.hidesScreen
                ) {
                    replaceSticker(
                        id: clip.id,
                        actionName: clip.hidesScreen
                            ? "关闭贴图仅背景"
                            : "开启贴图仅背景"
                    ) {
                        $0.hidesScreen.toggle()
                    }
                }
                .help(
                    clip.hidesScreen
                        ? "恢复录屏画面"
                        : "隐藏录屏画面，仅保留画布背景与贴图"
                )
            }
        }
    }

    func quickEditorCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.appUI(size: 11, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 48)
            .foregroundStyle(EditorTheme.chrome(0.94))
            .background(
                EditorTheme.cardElevated.opacity(0.94),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: Color.black.opacity(0.45), radius: 10, y: 4)
    }

    func quickToggle(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(SpringMotion.interactive) {
                action()
            }
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(isSelected ? Color.black.opacity(0.9) : Color.primary.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    isSelected
                        ? LinearGradient(
                            colors: [Color.white, Color(white: 0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.35 : 0.08), lineWidth: 0.5)
                )
                .scaleEffect(isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.editorThumbnail)
        .animation(SpringMotion.interactive, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func quickEditorPlacement(
        bounds: CGRect,
        canvasSize: CGSize,
        width: CGFloat
    ) -> CanvasQuickEditorPlacement {
        let editorHeight: CGFloat = 48
        let edgeMargin: CGFloat = 8
        let objectGap: CGFloat = 8
        let half = width / 2
        let halfHeight = editorHeight / 2
        let x = min(
            max(bounds.midX, half + edgeMargin),
            canvasSize.width - half - edgeMargin
        )
        let aboveY = bounds.minY - objectGap - halfHeight
        let belowY = bounds.maxY + objectGap + halfHeight
        let fitsAbove = aboveY - halfHeight >= edgeMargin
        let fitsBelow = belowY + halfHeight <= canvasSize.height - edgeMargin

        if fitsAbove {
            return CanvasQuickEditorPlacement(
                point: CGPoint(x: x, y: aboveY),
                transitionAnchor: .bottom
            )
        }
        if fitsBelow {
            return CanvasQuickEditorPlacement(
                point: CGPoint(x: x, y: belowY),
                transitionAnchor: .top
            )
        }

        let prefersAbove = bounds.midY >= canvasSize.height / 2
        let proposedY = prefersAbove ? aboveY : belowY
        let clampedY = min(
            max(proposedY, halfHeight + edgeMargin),
            canvasSize.height - halfHeight - edgeMargin
        )
        return CanvasQuickEditorPlacement(
            point: CGPoint(x: x, y: clampedY),
            transitionAnchor: prefersAbove ? .bottom : .top
        )
    }

    private func rotatedStickerBounds(
        center: CGPoint,
        size: CGSize,
        rotation: Double
    ) -> CGRect {
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        let width = size.width * cosine + size.height * sine
        let height = size.width * sine + size.height * cosine
        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
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

    func replaceOverlayTimeline(_ timeline: ProjectTimeline, actionName: String) {
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
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

}
