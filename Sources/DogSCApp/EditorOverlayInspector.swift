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
        case .progress:
            progressInspector
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
                    Picker(
                        "模式",
                        selection: mosaicBinding(id: id, keyPath: \.style, fallback: clip.style)
                    ) {
                        Text("柔化").tag(MosaicEffectStyle.blur)
                        Text("突出").tag(MosaicEffectStyle.spotlight)
                    }
                    .pickerStyle(.segmented)
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
                    if clip.style == .spotlight {
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
                    Picker(
                        "方式",
                        selection: mosaicBinding(
                            id: id,
                            keyPath: \.transitionStyle,
                            fallback: clip.transitionStyle
                        )
                    ) {
                        Text("无").tag(MosaicTransitionStyle.none)
                        Text("线性").tag(MosaicTransitionStyle.linear)
                        Text("平滑").tag(MosaicTransitionStyle.smooth)
                    }
                    .pickerStyle(.segmented)
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
                    MotionPositionPad(
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
                    MotionPositionPad(
                        title: "位置",
                        point: clip.position,
                        onChanged: { point in
                            updateStickerPositionDraft(id: id, point: point)
                        },
                        onEnded: {
                            commitOverlayDraft(actionName: "移动贴图")
                        },
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
                            .font(.caption2)
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
                    overlaySlider("背景虚化", value: stickerBinding(id: id, keyPath: \.backdropBlur, fallback: clip.backdropBlur), range: 0...60, format: .points)
                }

                EditorInspectorSection("出入场") {
                    Picker(
                        "入场",
                        selection: stickerBinding(
                            id: id,
                            keyPath: \.animation,
                            fallback: clip.animation
                        )
                    ) {
                        ForEach(StickerAnimationPreset.allCases, id: \.self) { preset in
                            Text(stickerAnimationLabel(preset)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker(
                        "退场",
                        selection: stickerBinding(
                            id: id,
                            keyPath: \.exitAnimation,
                            fallback: clip.exitAnimation
                        )
                    ) {
                        Text("自动反向").tag(Optional<StickerAnimationPreset>.none)
                        ForEach(StickerAnimationPreset.allCases, id: \.self) { preset in
                            Text(stickerAnimationLabel(preset)).tag(Optional(preset))
                        }
                    }
                    .pickerStyle(.menu)
                    overlaySlider("入场时长", value: stickerBinding(id: id, keyPath: \.enterDuration, fallback: clip.enterDuration), range: 0...2, format: .seconds)
                    overlaySlider("出场时长", value: stickerBinding(id: id, keyPath: \.exitDuration, fallback: clip.exitDuration), range: 0...2, format: .seconds)
                }

                removeOverlayButton(title: "删除贴图")
            }
        } else {
            missingOverlayView
        }
    }

    var progressInspector: some View {
        Group {
            if let overlay = editorStore.previewProject.timeline.progressOverlay {
                VStack(alignment: .leading, spacing: 14) {
                    EditorInspectorSection("位置与尺寸") {
                        Picker(
                            "位置",
                            selection: progressBinding(
                                keyPath: \.placement,
                                fallback: overlay.placement
                            )
                        ) {
                            Text("顶部").tag(ProgressOverlayPlacement.top)
                            Text("自由").tag(ProgressOverlayPlacement.custom)
                            Text("底部").tag(ProgressOverlayPlacement.bottom)
                        }
                        .pickerStyle(.segmented)
                        if overlay.placement == .custom {
                            overlaySlider(
                                "垂直位置",
                                value: progressPositionBinding(
                                    keyPath: \.y,
                                    fallback: overlay.position.y
                                ),
                                range: 0...1,
                                format: .percent
                            )
                        }
                        overlaySlider(
                            "宽度",
                            value: progressBinding(
                                keyPath: \.width,
                                fallback: overlay.width
                            ),
                            range: 0.2...1,
                            format: .percent
                        )
                        overlaySlider(
                            "条带高度",
                            value: progressBinding(
                                keyPath: \.bandHeight,
                                fallback: overlay.bandHeight
                            ),
                            range: 28...180,
                            format: .points
                        )
                        overlaySlider(
                            "文字大小",
                            value: progressBinding(
                                keyPath: \.textSize,
                                fallback: overlay.textSize
                            ),
                            range: 10...72,
                            format: .points
                        )
                    }

                    EditorInspectorSection("颜色") {
                        progressColorInput(
                            "条带背景",
                            value: overlay.backgroundColor,
                            keyPath: \.backgroundColor
                        )
                        overlaySlider(
                            "背景透明度",
                            value: progressBinding(
                                keyPath: \.backgroundOpacity,
                                fallback: overlay.backgroundOpacity
                            ),
                            range: 0...1,
                            format: .percent
                        )
                        progressColorInput("进度颜色", value: overlay.fillColor, keyPath: \.fillColor)
                        progressColorInput("分隔线", value: overlay.nodeColor, keyPath: \.nodeColor)
                        progressColorInput("文字颜色", value: overlay.textColor, keyPath: \.textColor)
                    }

                    EditorInspectorSection("当期看点") {
                        ForEach(overlay.chapters) { chapter in
                            let isOpening = abs(chapter.time) <= 1.0 / 120.0
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    TextField(
                                        "看点名称",
                                        text: progressChapterTitleBinding(chapter.id, fallback: chapter.title)
                                    )
                                    if !isOpening {
                                        Button(role: .destructive) {
                                            removeProgressChapter(chapter.id)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                if isOpening {
                                    Text("从 0:00 开始")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    overlaySlider(
                                        "开始时间",
                                        value: progressChapterTimeBinding(
                                            chapter.id,
                                            fallback: chapter.time
                                        ),
                                        range: 1.0 / 30.0...max(timelineDuration, 0.1),
                                        format: .seconds
                                    )
                                }
                            }
                            .padding(9)
                            .background(
                                Color.white.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        }
                        Button {
                            addProgressChapter()
                        } label: {
                            Label("在当前时间开始新一段", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }
                    removeOverlayButton(title: "删除进度条")
                }
            } else {
                missingOverlayView
            }
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
        .buttonStyle(.borderless)
    }

    var missingOverlayView: some View {
        ContentUnavailableView(
            "内容已不存在",
            systemImage: "rectangle.slash",
            description: Text("它可能已被删除或撤销。")
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

    func stickerAnimationLabel(_ preset: StickerAnimationPreset) -> String {
        switch preset {
        case .none: "无动画"
        case .fade: "淡入淡出"
        case .pop: "弹出收回"
        case .slideLeft: "从左"
        case .slideRight: "从右"
        case .slideUp: "从上"
        case .slideDown: "从下"
        case .slideTopLeft: "从左上"
        case .slideTopRight: "从右上"
        case .slideBottomLeft: "从左下"
        case .slideBottomRight: "从右下"
        }
    }

    func progressBinding<Value>(
        keyPath: WritableKeyPath<ProgressOverlay, Value>,
        fallback: Value
    ) -> Binding<Value> {
        editorTimelineBinding(
            store: editorStore,
            selection: .progress,
            get: { $0.progressOverlay?[keyPath: keyPath] ?? fallback },
            set: { timeline, value in
                timeline.progressOverlay?[keyPath: keyPath] = value
            },
            actionName: "调整进度条",
            onError: onError
        )
    }

    func progressPositionBinding(
        keyPath: WritableKeyPath<NormalizedPoint, Double>,
        fallback: Double
    ) -> Binding<Double> {
        editorTimelineBinding(
            store: editorStore,
            selection: .progress,
            get: { $0.progressOverlay?.position[keyPath: keyPath] ?? fallback },
            set: { timeline, value in
                timeline.progressOverlay?.position[keyPath: keyPath] = min(max(value, 0), 1)
            },
            actionName: "移动进度条",
            onError: onError
        )
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
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                Color.white.opacity(disabled ? 0.025 : 0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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

    func progressColorInput(
        _ title: String,
        value: HexColor,
        keyPath: WritableKeyPath<ProgressOverlay, HexColor>
    ) -> some View {
        EditorTransactionalColorInput(
            editorStore: editorStore,
            title: title,
            value: progressBinding(keyPath: keyPath, fallback: value),
            commandScope: .selection,
            selection: .progress,
            actionName: "调整进度条颜色",
            onError: onError
        )
    }

    func progressChapterTitleBinding(
        _ id: UUID,
        fallback: String
    ) -> Binding<String> {
        editorTimelineBinding(
            store: editorStore,
            selection: .progress,
            get: { timeline in
                timeline.progressOverlay?.chapters.first { $0.id == id }?.title
                    ?? fallback
            },
            set: { timeline, value in
                guard let index = timeline.progressOverlay?.chapters.firstIndex(
                    where: { $0.id == id }
                ) else { return }
                timeline.progressOverlay?.chapters[index].title = value
            },
            actionName: "编辑看点名称",
            onError: onError
        )
    }

    func progressChapterTimeBinding(
        _ id: UUID,
        fallback: TimeInterval
    ) -> Binding<Double> {
        editorTimelineBinding(
            store: editorStore,
            selection: .progress,
            get: { timeline in
                timeline.progressOverlay?.chapters.first { $0.id == id }?.time
                    ?? fallback
            },
            set: { timeline, value in
                guard let index = timeline.progressOverlay?.chapters.firstIndex(
                    where: { $0.id == id }
                ) else { return }
                timeline.progressOverlay?.chapters[index].time = value
                timeline.progressOverlay?.chapters.sort { $0.time < $1.time }
            },
            actionName: "调整看点时间",
            onError: onError
        )
    }

    func addProgressChapter() {
        var timeline = editorStore.project.timeline
        guard var progress = timeline.progressOverlay else { return }
        progress.insertChapterIfNeeded(
            at: min(max(playbackTime, 0), timelineDuration),
            title: "看点 \(progress.chapters.count + 1)"
        )
        timeline.progressOverlay = progress
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "添加看点")
        } catch {
            onError(error.localizedDescription)
        }
    }

    func removeProgressChapter(_ id: UUID) {
        var timeline = editorStore.project.timeline
        guard let chapter = timeline.progressOverlay?.chapters.first(where: {
            $0.id == id
        }), abs(chapter.time) > 1.0 / 120.0 else { return }
        timeline.progressOverlay?.chapters.removeAll { $0.id == id }
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "删除看点")
        } catch {
            onError(error.localizedDescription)
        }
    }
}
