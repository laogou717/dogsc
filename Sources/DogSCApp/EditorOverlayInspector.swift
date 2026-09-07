import RecorderCore
import SwiftUI

private enum StickerLayerMove {
    case backward
    case forward
    case bottom
    case top
}

extension EditorInspectorView {
    @ViewBuilder
    var overlayInspector: some View {
        switch editorStore.selection {
        case let .mosaic(id):
            mosaicInspector(id: id)
        case let .sticker(id):
            stickerInspector(id: id)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func mosaicInspector(id: UUID) -> some View {
        if let clip = editorStore.previewProject.timeline.mosaicClips.first(
            where: { $0.id == id }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                EditorInspectorSection("柔化效果") {
                    EditorSegmentedControl(
                        options: [MosaicEffectStyle.blur, MosaicEffectStyle.spotlight],
                        title: { $0 == .blur ? "柔化" : "突出" },
                        selection: mosaicBinding(id: id, keyPath: \.style, fallback: clip.style)
                    )
                    if clip.style == .blur {
                        overlaySlider(
                            "强度",
                            value: mosaicBinding(
                                id: id,
                                keyPath: \.intensity,
                                fallback: clip.intensity
                            ),
                            range: 0...1,
                            format: .percent
                        )
                    } else {
                        overlaySlider(
                            "暗度",
                            value: mosaicBinding(
                                id: id,
                                keyPath: \.spotlightDimming,
                                fallback: clip.spotlightDimming
                            ),
                            range: 0...0.75,
                            format: .percent
                        )
                    }
                    overlaySlider(
                        "圆角",
                        value: mosaicBinding(
                            id: id,
                            keyPath: \.cornerRadius,
                            fallback: clip.cornerRadius
                        ),
                        range: 0...0.5,
                        format: .percent
                    )
                }

                EditorInspectorSection("过渡") {
                    EditorSegmentedControl(
                        options: [MosaicTransitionStyle.none, MosaicTransitionStyle.linear, MosaicTransitionStyle.smooth],
                        title: {
                            switch $0 {
                            case .none: "无"
                            case .linear: "线性"
                            case .smooth: "平滑"
                            }
                        },
                        selection: mosaicBinding(
                            id: id,
                            keyPath: \.transitionStyle,
                            fallback: clip.transitionStyle
                        )
                    )
                    if clip.transitionStyle != .none {
                        overlaySlider(
                            "进入时长",
                            value: mosaicBinding(
                                id: id,
                                keyPath: \.transitionInDuration,
                                fallback: clip.transitionInDuration
                            ),
                            range: 0...2,
                            format: .seconds
                        )
                        overlaySlider(
                            "退出时长",
                            value: mosaicBinding(
                                id: id,
                                keyPath: \.transitionOutDuration,
                                fallback: clip.transitionOutDuration
                            ),
                            range: 0...2,
                            format: .seconds
                        )
                    }
                }

                EditorInspectorSection("位置与尺寸") {
                    EditorPositionPad(
                        title: "位置",
                        point: NormalizedPoint(
                            x: clip.sourceRect.x + clip.sourceRect.width / 2,
                            y: clip.sourceRect.y + clip.sourceRect.height / 2
                        ),
                        onChanged: { point in
                            updateMosaicPositionDraft(id: id, point: point)
                        },
                        onEnded: {
                            commitOverlayDraft(actionName: "移动打码区域")
                        },
                        onCancelled: { editorStore.cancelInteraction() },
                        snapsToGrid: false
                    )
                    overlaySlider("宽度", value: mosaicRectBinding(id: id, keyPath: \.width, fallback: clip.sourceRect.width), range: 0.01...1, format: .percent)
                    overlaySlider("高度", value: mosaicRectBinding(id: id, keyPath: \.height, fallback: clip.sourceRect.height), range: 0.01...1, format: .percent)
                }

                removeOverlayButton(title: "删除柔化")
            }
        } else {
            missingOverlayView
        }
    }

    @ViewBuilder
    func stickerInspector(id: UUID) -> some View {
        if let clip = editorStore.previewProject.timeline.stickerClips.first(
            where: { $0.id == id }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                EditorInspectorSection("贴图布局") {
                    EditorPositionPad(
                        title: "位置",
                        point: clip.position,
                        onChanged: { point in
                            updateStickerPositionDraft(id: id, point: point)
                        },
                        onEnded: {
                            commitOverlayDraft(actionName: "移动贴图")
                        },
                        onCancelled: { editorStore.cancelInteraction() },
                        snapsToGrid: false
                    )
                    overlaySlider("宽度", value: stickerBinding(id: id, keyPath: \.width, fallback: clip.width), range: 0.02...1.5, format: .percent)
                    overlaySlider("旋转", value: stickerBinding(id: id, keyPath: \.rotationDegrees, fallback: clip.rotationDegrees), range: -180...180, format: .degrees)
                    overlaySlider("透明度", value: stickerBinding(id: id, keyPath: \.opacity, fallback: clip.opacity), range: 0...1, format: .percent)
                }

                if editorStore.previewProject.timeline.stickerClips.count > 1 {
                    EditorInspectorSection("层级") {
                        let state = stickerLayerState(id: id)
                        HStack(spacing: 7) {
                            stickerLayerButton(
                                title: "置底",
                                symbol: "square.3.layers.3d.bottom.filled",
                                disabled: state.rank == 0
                            ) {
                                moveStickerLayer(id: id, move: .bottom)
                            }
                            stickerLayerButton(
                                title: "下移",
                                symbol: "square.2.layers.3d.bottom.filled",
                                disabled: state.rank == 0
                            ) {
                                moveStickerLayer(id: id, move: .backward)
                            }
                            stickerLayerButton(
                                title: "上移",
                                symbol: "square.2.layers.3d.top.filled",
                                disabled: state.rank >= state.count - 1
                            ) {
                                moveStickerLayer(id: id, move: .forward)
                            }
                            stickerLayerButton(
                                title: "置顶",
                                symbol: "square.3.layers.3d.top.filled",
                                disabled: state.rank >= state.count - 1
                            ) {
                                moveStickerLayer(id: id, move: .top)
                            }
                        }
                        Text("当前第 \(state.rank + 1) 层，共 \(state.count) 层")
                            .font(.appUI(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }

                EditorInspectorSection("外观") {
                    overlaySlider("圆角", value: stickerBinding(id: id, keyPath: \.cornerRadius, fallback: clip.cornerRadius), range: 0...160, format: .points)
                    overlaySlider("描边", value: stickerBinding(id: id, keyPath: \.borderWidth, fallback: clip.borderWidth), range: 0...40, format: .points)
                    if clip.borderWidth > 0 {
                        EditorTransactionalColorInput(
                            editorStore: editorStore,
                            title: "描边颜色",
                            value: stickerBinding(
                                id: id,
                                keyPath: \.borderColor,
                                fallback: clip.borderColor
                            ),
                            commandScope: .selection,
                            selection: .sticker(id),
                            actionName: "调整贴图描边",
                            onError: onError
                        )
                    }
                    overlaySlider("阴影", value: stickerBinding(id: id, keyPath: \.shadowOpacity, fallback: clip.shadowOpacity), range: 0...1, format: .percent)
                    overlaySlider("阴影柔化", value: stickerBinding(id: id, keyPath: \.shadowRadius, fallback: clip.shadowRadius), range: 0...80, format: .points)
                }

                EditorInspectorSection("背景处理") {
                    if clip.hidesScreen {
                        Label("仅保留画布背景与贴图", systemImage: "rectangle.slash")
                            .font(.appUI(.caption, weight: .semibold))
                            .foregroundStyle(EditorTheme.chrome(0.78))
                        Text("录屏画面已隐藏，录屏虚化不会再让画布背景变得雾蒙蒙；画布自身设置的壁纸模糊仍会保留。")
                            .font(.appUI(.caption2))
                            .foregroundStyle(EditorTheme.chrome(0.50))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        overlaySlider("录屏虚化", value: stickerBinding(id: id, keyPath: \.backdropBlur, fallback: clip.backdropBlur), range: 0...60, format: .points)
                        if clip.backdropBlur > 0.01 {
                            EditorToggle(
                                isOn: stickerBinding(
                                    id: id,
                                    keyPath: \.backdropBlurIncludesCamera,
                                    fallback: clip.backdropBlurIncludesCamera
                                ),
                                title: "同时虚化摄像头"
                            )
                        }
                    }
                    EditorToggle(
                        isOn: stickerBinding(
                            id: id,
                            keyPath: \.hidesScreen,
                            fallback: clip.hidesScreen
                        ),
                        title: "贴图期间隐藏录屏画面"
                    )
                    EditorToggle(
                        isOn: stickerBinding(
                            id: id,
                            keyPath: \.hidesCamera,
                            fallback: clip.hidesCamera
                        ),
                        title: "贴图期间隐藏摄像头"
                    )
                    Text("隐藏与虚化会跟随贴图的入场和退场曲线，不会突然切换。")
                        .font(.appUI(.caption2))
                        .foregroundStyle(EditorTheme.chrome(0.50))
                }

                EditorInspectorSection("出入场") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("动效节奏")
                            .font(.appUI(.caption2, weight: .semibold))
                            .foregroundStyle(EditorTheme.chrome(0.62))
                        EditorTileSelector(
                            options: ElementMotionCurve.allCases,
                            title: { $0.editorTitle },
                            icon: { $0.editorSymbol },
                            selection: stickerBinding(
                                id: id,
                                keyPath: \.animationCurve,
                                fallback: clip.animationCurve
                            ),
                            columnCount: 3
                        )
                        Text(
                            "\(clip.animationCurve.editorDetail) "
                                + "同时影响入场与退场，方向和时长仍可分别调整。"
                        )
                            .font(.appUI(.caption2))
                            .foregroundStyle(EditorTheme.chrome(0.48))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                        .overlay(EditorTheme.chrome(0.05))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("入场方式")
                            .font(.appUI(.caption2, weight: .semibold))
                            .foregroundStyle(EditorTheme.chrome(0.62))
                        EditorTileSelector(
                            options: StickerAnimationPreset.allCases,
                            title: stickerAnimationShortLabel,
                            icon: stickerAnimationSymbol,
                            selection: stickerBinding(
                                id: id,
                                keyPath: \.animation,
                                fallback: clip.animation
                            ),
                            columnCount: 4
                        )
                        .accessibilityLabel("贴图入场方式")
                        overlaySlider(
                            "入场时长",
                            value: stickerBinding(
                                id: id,
                                keyPath: \.enterDuration,
                                fallback: clip.enterDuration
                            ),
                            range: 0...2,
                            format: .seconds
                        )
                    }

                    Divider()
                        .overlay(EditorTheme.chrome(0.05))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("退场方式")
                            .font(.appUI(.caption2, weight: .semibold))
                            .foregroundStyle(EditorTheme.chrome(0.62))
                        EditorTileSelector(
                            options: stickerExitAnimationOptions,
                            title: stickerAnimationShortLabel,
                            icon: stickerAnimationSymbol,
                            selection: stickerBinding(
                                id: id,
                                keyPath: \.exitAnimation,
                                fallback: clip.exitAnimation
                            ),
                            columnCount: 4
                        )
                        .accessibilityLabel("贴图退场方式")
                        if clip.exitAnimation == nil {
                            Label(
                                "自动采用入场方式的反向动作",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.appUI(.caption2))
                            .foregroundStyle(EditorTheme.chrome(0.50))
                        }
                        overlaySlider(
                            "出场时长",
                            value: stickerBinding(
                                id: id,
                                keyPath: \.exitDuration,
                                fallback: clip.exitDuration
                            ),
                            range: 0...2,
                            format: .seconds
                        )
                    }
                }

                removeOverlayButton(title: "删除贴图")
            }
        } else {
            missingOverlayView
        }
    }

    func overlaySlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: EditorSliderValueFormat
    ) -> some View {
        sliderRow(
            title,
            value: value,
            range: range,
            interactionScope: .selection,
            format: format
        )
    }

    func removeOverlayButton(title: String) -> some View {
        Button(title, role: .destructive) {
            do {
                try editorStore.removeSelectedOverlay()
            } catch {
                onError(error.localizedDescription)
            }
        }
        .buttonStyle(.editorDestructive)
    }

    var missingOverlayView: some View {
        EditorInspectorEmptyState(
            title: "内容已不存在",
            detail: "它可能已在时间线中删除或被撤销。",
            systemImage: "rectangle.slash",
            actionTitle: "返回画面设置",
            action: { editorStore.selection = .canvas }
        )
    }

    func mosaicBinding<Value>(
        id: UUID,
        keyPath: WritableKeyPath<MosaicClip, Value>,
        fallback: Value
    ) -> Binding<Value> {
        editorTimelineBinding(
            store: editorStore,
            selection: .mosaic(id),
            get: { timeline in
                timeline.mosaicClips.first { $0.id == id }?[keyPath: keyPath]
                    ?? fallback
            },
            set: { timeline, value in
                guard let index = timeline.mosaicClips.firstIndex(
                    where: { $0.id == id }
                ) else { return }
                timeline.mosaicClips[index][keyPath: keyPath] = value
            },
            actionName: "调整打码",
            onError: onError
        )
    }

    func mosaicRectBinding(
        id: UUID,
        keyPath: WritableKeyPath<NormalizedOverlayRect, Double>,
        fallback: Double
    ) -> Binding<Double> {
        editorTimelineBinding(
            store: editorStore,
            selection: .mosaic(id),
            get: { timeline in
                timeline.mosaicClips.first { $0.id == id }?
                    .sourceRect[keyPath: keyPath] ?? fallback
            },
            set: { timeline, value in
                guard let index = timeline.mosaicClips.firstIndex(
                    where: { $0.id == id }
                ) else { return }
                timeline.mosaicClips[index].sourceRect[keyPath: keyPath] = value
                timeline.mosaicClips[index].sourceRect = timeline.mosaicClips[index]
                    .sourceRect.clamped()
            },
            actionName: "调整打码区域",
            onError: onError
        )
    }

    func stickerBinding<Value>(
        id: UUID,
        keyPath: WritableKeyPath<StickerClip, Value>,
        fallback: Value
    ) -> Binding<Value> {
        editorTimelineBinding(
            store: editorStore,
            selection: .sticker(id),
            get: { timeline in
                timeline.stickerClips.first { $0.id == id }?[keyPath: keyPath]
                    ?? fallback
            },
            set: { timeline, value in
                guard let index = timeline.stickerClips.firstIndex(
                    where: { $0.id == id }
                ) else { return }
                timeline.stickerClips[index][keyPath: keyPath] = value
            },
            actionName: "调整贴图",
            onError: onError
        )
    }

    var stickerExitAnimationOptions: [StickerAnimationPreset?] {
        [nil] + StickerAnimationPreset.allCases.map(Optional.some)
    }

    func stickerAnimationShortLabel(_ preset: StickerAnimationPreset) -> String {
        switch preset {
        case .none: "无"
        case .fade: "淡入"
        case .pop: "弹出"
        case .slideLeft: "从左"
        case .slideRight: "从右"
        case .slideUp: "从上"
        case .slideDown: "从下"
        case .slideTopLeft: "左上"
        case .slideTopRight: "右上"
        case .slideBottomLeft: "左下"
        case .slideBottomRight: "右下"
        }
    }

    func stickerAnimationShortLabel(_ preset: StickerAnimationPreset?) -> String {
        preset.map(stickerAnimationShortLabel) ?? "反向"
    }

    func stickerAnimationSymbol(_ preset: StickerAnimationPreset) -> String {
        switch preset {
        case .none: "minus"
        case .fade: "circle.dotted"
        case .pop: "sparkles"
        case .slideLeft: "arrow.right"
        case .slideRight: "arrow.left"
        case .slideUp: "arrow.down"
        case .slideDown: "arrow.up"
        case .slideTopLeft: "arrow.down.right"
        case .slideTopRight: "arrow.down.left"
        case .slideBottomLeft: "arrow.up.right"
        case .slideBottomRight: "arrow.up.left"
        }
    }

    func stickerAnimationSymbol(_ preset: StickerAnimationPreset?) -> String {
        preset.map(stickerAnimationSymbol) ?? "arrow.triangle.2.circlepath"
    }

    func replaceSticker(
        id: UUID,
        actionName: String,
        update: (inout StickerClip) -> Void
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(
            where: { $0.id == id }
        ) else { return }
        update(&timeline.stickerClips[index])
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func stickerLayerState(id: UUID) -> (rank: Int, count: Int) {
        let ordered = editorStore.previewProject.timeline.stickerClips.sorted {
            $0.layerIndex == $1.layerIndex
                ? $0.id.uuidString < $1.id.uuidString
                : $0.layerIndex < $1.layerIndex
        }
        return (
            ordered.firstIndex(where: { $0.id == id }) ?? 0,
            max(ordered.count, 1)
        )
    }

    func stickerLayerButton(
        title: String,
        symbol: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.appUI(size: 12, weight: .semibold))
                Text(title)
                    .font(.appUI(size: 9.5, weight: .medium))
            }
            .foregroundStyle(
                disabled
                    ? EditorTheme.chrome(0.28)
                    : EditorTheme.chrome(0.84)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                EditorTheme.chrome(disabled ? 0.018 : 0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        EditorTheme.chrome(disabled ? 0.025 : 0.075),
                        lineWidth: 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.editorThumbnail)
        .disabled(disabled)
        .help(title + "贴图")
        .accessibilityLabel(title + "贴图")
    }

    fileprivate func moveStickerLayer(id: UUID, move: StickerLayerMove) {
        var timeline = editorStore.project.timeline
        var orderedIDs = timeline.stickerClips.sorted {
            $0.layerIndex == $1.layerIndex
                ? $0.id.uuidString < $1.id.uuidString
                : $0.layerIndex < $1.layerIndex
        }.map(\.id)
        guard let source = orderedIDs.firstIndex(of: id), orderedIDs.count > 1 else {
            return
        }
        let target: Int = switch move {
        case .backward: max(source - 1, 0)
        case .forward: min(source + 1, orderedIDs.count - 1)
        case .bottom: 0
        case .top: orderedIDs.count - 1
        }
        guard target != source else { return }
        orderedIDs.remove(at: source)
        orderedIDs.insert(id, at: target)
        let ranks = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
            ($0.element, $0.offset)
        })
        for index in timeline.stickerClips.indices {
            timeline.stickerClips[index].layerIndex = ranks[
                timeline.stickerClips[index].id
            ] ?? timeline.stickerClips[index].layerIndex
        }
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "调整贴图层级")
            editorStore.selection = .sticker(id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func updateMosaicPositionDraft(id: UUID, point: NormalizedPoint) {
        _ = editorStore.beginContinuousInteraction(
            commandScope: .selection,
            selection: .mosaic(id)
        )
        editorStore.updateInteraction { project in
            guard let index = project.timeline.mosaicClips.firstIndex(where: {
                $0.id == id
            }) else { return }
            var rect = project.timeline.mosaicClips[index].sourceRect
            rect.x = min(max(point.x - rect.width / 2, 0), 1 - rect.width)
            rect.y = min(max(point.y - rect.height / 2, 0), 1 - rect.height)
            project.timeline.mosaicClips[index].sourceRect = rect.clamped()
        }
    }

    func updateStickerPositionDraft(id: UUID, point: NormalizedPoint) {
        _ = editorStore.beginContinuousInteraction(
            commandScope: .selection,
            selection: .sticker(id)
        )
        editorStore.updateInteraction { project in
            guard let index = project.timeline.stickerClips.firstIndex(where: {
                $0.id == id
            }) else { return }
            project.timeline.stickerClips[index].position = NormalizedPoint(
                x: min(max(point.x, 0), 1),
                y: min(max(point.y, 0), 1)
            )
        }
    }

    func commitOverlayDraft(actionName: String) {
        do {
            _ = try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

}
