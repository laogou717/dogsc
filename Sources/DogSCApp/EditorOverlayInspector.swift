import RecorderCore
import SwiftUI

private enum StickerLayerMove {
    case backward
    case forward
    case bottom
    case top
}

/// The four entrance families the inspector offers. Saved presets keep
/// their exact value; this only groups them for the controls.
enum StickerMotionStyle: CaseIterable, Hashable {
    case none, fade, pop, slide

    init(_ preset: StickerAnimationPreset) {
        switch preset {
        case .none: self = .none
        case .fade: self = .fade
        case .pop: self = .pop
        case .slideLeft, .slideRight, .slideUp, .slideDown,
             .slideTopLeft, .slideTopRight, .slideBottomLeft, .slideBottomRight:
            self = .slide
        }
    }

    var entranceTitle: String {
        switch self {
        case .none: "无"
        case .fade: "淡入"
        case .pop: "弹出"
        case .slide: "滑入"
        }
    }

    func preset(direction: StickerSlideDirection) -> StickerAnimationPreset {
        switch self {
        case .none: .none
        case .fade: .fade
        case .pop: .pop
        case .slide: direction.preset
        }
    }
}

/// Where a slide comes in from. Legacy diagonals read as their horizontal
/// side (左上 → 从左) and keep rendering diagonally until changed.
enum StickerSlideDirection: CaseIterable, Hashable {
    case left, up, right, down

    init?(_ preset: StickerAnimationPreset) {
        switch preset {
        case .slideLeft, .slideTopLeft, .slideBottomLeft: self = .left
        case .slideRight, .slideTopRight, .slideBottomRight: self = .right
        case .slideUp: self = .up
        case .slideDown: self = .down
        case .none, .fade, .pop: return nil
        }
    }

    var title: String {
        switch self {
        case .left: "从左"
        case .up: "从上"
        case .right: "从右"
        case .down: "从下"
        }
    }

    var preset: StickerAnimationPreset {
        switch self {
        case .left: .slideLeft
        case .up: .slideUp
        case .right: .slideRight
        case .down: .slideDown
        }
    }
}

/// 退场 choices. `nil` (同入场) plays the entrance backwards. Explicit slide
/// exits from older projects show as 同入场 and render unchanged.
enum StickerExitStyle: CaseIterable, Hashable {
    case mirror, none, fade, shrink

    init(_ exit: StickerAnimationPreset?) {
        switch exit {
        case nil: self = .mirror
        case .none?: self = .none
        case .fade?: self = .fade
        case .pop?: self = .shrink
        case .slideLeft?, .slideRight?, .slideUp?, .slideDown?,
             .slideTopLeft?, .slideTopRight?, .slideBottomLeft?, .slideBottomRight?:
            self = .mirror
        }
    }

    var title: String {
        switch self {
        case .mirror: "同入场"
        case .none: "无"
        case .fade: "淡出"
        case .shrink: "收缩"
        }
    }

    var preset: StickerAnimationPreset? {
        switch self {
        case .mirror: nil
        case .none: StickerAnimationPreset.none
        case .fade: .fade
        case .shrink: .pop
        }
    }
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
                EditorInspectorSection("区域效果") {
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
                            commitOverlayDraft(actionName: "移动效果区域")
                        },
                        onCancelled: { editorStore.cancelInteraction() },
                        onTextPreviewValidityChanged: {
                            updateEditorTextPreviewValidity(
                                store: editorStore, isValid: $0,
                                commandScope: .selection, selection: .mosaic(id),
                                actionName: "移动效果区域"
                            )
                        },
                        snapsToGrid: false
                    )
                    overlaySlider("宽度", value: mosaicRectBinding(id: id, keyPath: \.width, fallback: clip.sourceRect.width), range: 0.01...1, format: .percent)
                    overlaySlider("高度", value: mosaicRectBinding(id: id, keyPath: \.height, fallback: clip.sourceRect.height), range: 0.01...1, format: .percent)
                }

                removeOverlayButton(title: clip.style == .spotlight ? "删除突出" : "删除柔化")
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
            VStack(alignment: .leading, spacing: 0) {
                EditorInspectorSection("外观") {
                    overlaySlider("圆角", value: stickerBinding(id: id, keyPath: \.cornerRadius, fallback: clip.cornerRadius), range: 0...160, format: .points)
                    overlaySlider("阴影", value: stickerBinding(id: id, keyPath: \.shadowOpacity, fallback: clip.shadowOpacity), range: 0...1, format: .percent)
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
                    overlaySlider("透明度", value: stickerBinding(id: id, keyPath: \.opacity, fallback: clip.opacity), range: 0...1, format: .percent)
                }

                EditorInspectorSection("背景") {
                    if !clip.hidesScreen {
                        overlaySlider("虚化", value: stickerBinding(id: id, keyPath: \.backdropBlur, fallback: clip.backdropBlur), range: 0...60, format: .points)
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
                        title: "隐藏录屏"
                    )
                    .help(appLocalized("贴图期间隐藏录屏画面"))
                    EditorToggle(
                        isOn: stickerBinding(
                            id: id,
                            keyPath: \.hidesCamera,
                            fallback: clip.hidesCamera
                        ),
                        title: "隐藏摄像头"
                    )
                    .help(appLocalized("贴图期间隐藏摄像头"))
                }

                EditorInspectorSection("位置与尺寸") {
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
                        onTextPreviewValidityChanged: {
                            updateEditorTextPreviewValidity(
                                store: editorStore, isValid: $0,
                                commandScope: .selection, selection: .sticker(id),
                                actionName: "移动贴图"
                            )
                        },
                        snapsToGrid: false,
                        anchorSteps: [0.15, 0.5, 0.85]
                    )
                    overlaySlider("大小", value: stickerBinding(id: id, keyPath: \.width, fallback: clip.width), range: 0.02...1.5, format: .percent)
                    overlaySlider("旋转", value: stickerBinding(id: id, keyPath: \.rotationDegrees, fallback: clip.rotationDegrees), range: -180...180, format: .degrees)
                    if editorStore.previewProject.timeline.stickerClips.count > 1 {
                        stickerLayerRow(id: id)
                    }
                }

                EditorInspectorSection("动画") {
                    stickerEntranceRows(id: id, clip: clip)
                    stickerExitRow(id: id, clip: clip)
                    stickerDurationRow(id: id, clip: clip)
                }

                removeOverlayButton(title: "删除贴图")
                    .padding(.top, 14)
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
        Button(appLocalized(title), role: .destructive) {
            do {
                try editorStore.removeSelectedOverlay()
            } catch {
                onError(error.localizedDescription)
            }
        }
        .buttonStyle(.editorDestructive)
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            actionName: "调整区域效果",
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
            actionName: "调整效果区域",
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

    // MARK: 贴图 · 动画

    /// 入场: 无 / 淡入 / 弹出 / 滑入; 滑入 adds a four-way 方向 row.
    /// Diagonal slides from older projects keep rendering exactly as saved;
    /// the controls only show their nearest choice until the user picks one.
    @ViewBuilder
    func stickerEntranceRows(id: UUID, clip: StickerClip) -> some View {
        let motion = StickerMotionStyle(clip.animation)
        stickerPropertyRow("入场") {
            EditorSegmentedControl(
                options: StickerMotionStyle.allCases,
                title: \.entranceTitle,
                selection: Binding(
                    get: { motion },
                    set: { style in
                        guard style != motion else { return }
                        setStickerAnimation(id: id) { clip in
                            clip.animation = style.preset(
                                direction: StickerSlideDirection(clip.animation) ?? .left
                            )
                        }
                    }
                )
            )
            .accessibilityLabel(appLocalized("贴图入场方式"))
        }
        if motion == .slide {
            let direction = StickerSlideDirection(clip.animation) ?? .left
            stickerPropertyRow("方向") {
                EditorSegmentedControl(
                    options: StickerSlideDirection.allCases,
                    title: \.title,
                    selection: Binding(
                        get: { direction },
                        set: { next in
                            guard next.preset != clip.animation else { return }
                            setStickerAnimation(id: id) { $0.animation = next.preset }
                        }
                    )
                )
                .accessibilityLabel(appLocalized("贴图滑入方向"))
            }
        }
    }

    /// 退场: 同入场 (the reverse path, the default) / 无 / 淡出 / 收缩.
    func stickerExitRow(id: UUID, clip: StickerClip) -> some View {
        let current = StickerExitStyle(clip.exitAnimation)
        return stickerPropertyRow("退场") {
            EditorSegmentedControl(
                options: StickerExitStyle.allCases,
                title: \.title,
                optionHelp: { $0 == .mirror ? "按入场的反向动作退场" : $0.title },
                selection: Binding(
                    get: { current },
                    set: { style in
                        // Compare saved values, so a legacy explicit slide
                        // shown as 同入场 can still be reset to the mirror.
                        guard style.preset != clip.exitAnimation else { return }
                        setStickerAnimation(id: id) { $0.exitAnimation = style.preset }
                    }
                )
            )
            .accessibilityLabel(appLocalized("贴图退场方式"))
        }
    }

    /// One 时长 row: entrance and exit as a pair of scrub boxes.
    func stickerDurationRow(id: UUID, clip: StickerClip) -> some View {
        stickerPropertyRow("时长") {
            EditorPairedParameterReadouts(
                first: EditorPairedParameterValue(
                    title: "入",
                    accessibilityTitle: "入场时长",
                    value: clip.enterDuration,
                    range: 0...2,
                    displayText: EditorSliderValueFormat.seconds.text(for: clip.enterDuration),
                    inputFormat: .seconds
                ),
                second: EditorPairedParameterValue(
                    title: "出",
                    accessibilityTitle: "出场时长",
                    value: clip.exitDuration,
                    range: 0...2,
                    displayText: EditorSliderValueFormat.seconds.text(for: clip.exitDuration),
                    inputFormat: .seconds
                ),
                onChanged: { enter, exit in
                    _ = editorStore.beginContinuousInteraction(
                        commandScope: .selection,
                        selection: .sticker(id)
                    )
                    editorStore.updateInteraction { project in
                        guard let index = project.timeline.stickerClips.firstIndex(
                            where: { $0.id == id }
                        ) else { return }
                        project.timeline.stickerClips[index].enterDuration = (enter * 20).rounded() / 20
                        project.timeline.stickerClips[index].exitDuration = (exit * 20).rounded() / 20
                    }
                },
                onEnded: { commitOverlayDraft(actionName: "调整贴图时长") },
                onCancelled: { editorStore.cancelInteraction() },
                onTextPreviewValidityChanged: {
                    updateEditorTextPreviewValidity(
                        store: editorStore, isValid: $0,
                        commandScope: .selection, selection: .sticker(id),
                        actionName: "调整贴图时长"
                    )
                }
            )
        }
    }

    func setStickerAnimation(id: UUID, update: (inout StickerClip) -> Void) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else { return }
        update(&timeline.stickerClips[index])
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "调整贴图动画")
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Label 64 + control, 30 high — the inspector's one row grammar.
    func stickerPropertyRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: EditorPropertyRowMetrics.gap) {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
            control()
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: EditorPropertyRowMetrics.height)
    }

    /// 层级 as one row of four quiet icon buttons; the rank sits in the help.
    func stickerLayerRow(id: UUID) -> some View {
        let state = stickerLayerState(id: id)
        let atBottom = state.rank == 0
        let atTop = state.rank >= state.count - 1
        return stickerPropertyRow("层级") {
            HStack(spacing: 2) {
                stickerLayerButton(title: "置底", symbol: "square.3.layers.3d.bottom.filled", disabled: atBottom) {
                    moveStickerLayer(id: id, move: .bottom)
                }
                stickerLayerButton(title: "下移", symbol: "square.2.layers.3d.bottom.filled", disabled: atBottom) {
                    moveStickerLayer(id: id, move: .backward)
                }
                stickerLayerButton(title: "上移", symbol: "square.2.layers.3d.top.filled", disabled: atTop) {
                    moveStickerLayer(id: id, move: .forward)
                }
                stickerLayerButton(title: "置顶", symbol: "square.3.layers.3d.top.filled", disabled: atTop) {
                    moveStickerLayer(id: id, move: .top)
                }
            }
            .padding(2)
            .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help(String(
                format: appLocalized("当前第 %lld 层，共 %lld 层（摄像头始终在贴图上方）"),
                Int64(state.rank + 1), Int64(state.count)
            ))
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
            EditorSymbol(symbol, size: 14)
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(disabled ? EditorTheme.tertiaryText.opacity(0.5) : EditorTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 7))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .disabled(disabled)
        .help(appLocalized(title))
        .accessibilityLabel(appLocalized(title + "贴图"))
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
