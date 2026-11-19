import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorInspectorView {
    var cursorInspector: some View {
        let cursorIsHidden = editorStore.sceneEditingPreviewProject.cursorStyle.assetID == .hidden

        return VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            EditorCursorStylePreview(style: editorStore.sceneEditingPreviewProject.cursorStyle)
            EditorInspectorSection("光标样式") {
            EditorSegmentedControl(
                options: cursorAssets.map(\.id),
                title: { id in appLocalized(cursorAssets.first(where: { $0.id == id })?.displayName ?? "系统") },
                selection: cursorBinding(\.assetID, actionName: "调整光标样式")
            )
                if !cursorIsHidden {
                    sliderRow(
                        "大小",
                        value: cursorBinding(\.size, actionName: "调整光标大小"),
                        range: 0.25...6,
                        format: .multiplier
                    )
                    EditorToggle(
                        isOn: cursorBinding(\.hideWhenIdle, actionName: "切换静止隐藏"),
                        title: "静止后隐藏"
                    )
                    if editorStore.sceneEditingPreviewProject.cursorStyle.hideWhenIdle {
                        sliderRow(
                            "静止隐藏延迟",
                            value: cursorBinding(\.idleDelay, actionName: "调整静止隐藏延迟"),
                            range: 0.2...8,
                            format: .seconds
                        )
                    }
                }
            }

            if !cursorIsHidden {
                if playheadSourceID.flatMap({ editorStore.previewProject.source($0)?.media.pointerEvents }) != nil {
                    EditorDisclosure("时间对齐", detail: cursorTimingLabel) {
                        EditorNumericStepControl(
                            "光标偏移",
                            valueText: String(format: "%+.0f ms", cursorTimingAdvance * 1_000),
                            canDecrease: cursorTimingAdvance > -1,
                            canIncrease: cursorTimingAdvance < 1,
                            onDecrease: { adjustCursorTiming(by: -0.010) },
                            onIncrease: { adjustCursorTiming(by: 0.010) },
                            repeatsSteps: false
                        )
                        HStack(spacing: 8) {
                            Button("提前 0.1 秒") { adjustCursorTiming(by: 0.100) }
                                .frame(maxWidth: .infinity)
                            Button("延后 0.1 秒") { adjustCursorTiming(by: -0.100) }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.editorQuiet)
                        HStack {
                            Text("光标比画面早出现时选延后")
                                .font(EditorTypography.helper)
                                .foregroundStyle(EditorTheme.tertiaryText)
                            Spacer(minLength: 4)
                            Button("归零") { adjustCursorTiming(by: -cursorTimingAdvance) }
                                .buttonStyle(.editorGhost)
                                .disabled(abs(cursorTimingAdvance) < 0.000_5)
                                .help("归零光标时间偏移")
                        }
                    }
                }

                EditorInspectorSection("点击反馈") {
                    CursorClickEffectStylePicker(
                        selection: editorStore.sceneEditingPreviewProject.cursorStyle.clickEffectStyle,
                        onSelect: { newStyle in
                            var style = editorStore.sceneEditingProject.cursorStyle
                            style.clickEffectStyle = newStyle
                            performEditorCommand {
                                try editorStore.replaceCursor(with: style, actionName: "调整点击动画样式")
                            }
                        }
                    )

                    EditorToggle(
                        isOn: cursorBinding(\.pressesOnClick, actionName: "切换按下缩放"),
                        title: "按下缩放"
                    )

                    if editorStore.sceneEditingPreviewProject.cursorStyle.clickEffectStyle != .none {
                        let defaultColor = CursorAssetLibrary.resolvedAsset(
                            for: editorStore.sceneEditingPreviewProject.cursorStyle.assetID
                        )?.metrics.clickColor ?? CursorAssetLibrary.defaultClickColor

                        CursorClickColorPicker(
                            editorStore: editorStore,
                            selectedColor: editorStore.sceneEditingPreviewProject.cursorStyle.clickColor,
                            defaultColor: defaultColor,
                            onError: onError,
                            onSelect: { newColor in
                                var style = editorStore.sceneEditingProject.cursorStyle
                                style.clickColor = newColor
                                performEditorCommand {
                                    try editorStore.replaceCursor(with: style, actionName: "调整点击动画颜色")
                                }
                            }
                        )

                        sliderRow(
                            "不透明度",
                            value: cursorBinding(\.clickOpacity, actionName: "调整点击不透明度"),
                            range: 0.1...1.0,
                            format: .percent
                        )

                        sliderRow(
                            "范围",
                            value: cursorBinding(\.clickScale, actionName: "调整点击动画大小"),
                            range: 0.5...2.0,
                            format: .multiplier
                        )
                    }
                }

                EditorDisclosure("移动手感", detail: editorStore.sceneEditingPreviewProject.motion.cursor == .none
                    ? appLocalized("线性") : appLocalized(editorStore.sceneEditingPreviewProject.motion.cursor.rawValue)) {
                    EditorSegmentedControl(
                        options: CursorMotionStyle.allCases,
                        title: { style in
                            style == .none ? appLocalized("线性") : appLocalized(style.rawValue)
                        },
                        selection: motionBinding(\.cursor, actionName: "调整光标动画")
                    )

                    if editorStore.sceneEditingPreviewProject.motion.cursor != .none {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("摆动强度")
                                .font(EditorTypography.controlLabel)
                                .foregroundStyle(EditorTheme.secondaryText)
                            EditorSegmentedControl(
                                options: [2.0, 2.5, 3.0, 3.5, 4.0],
                                title: { String(format: "%.1f×", $0) },
                                accessibilityTitle: { "\(appLocalized("光标摆动强度")) \(String(format: "%.1f×", $0))" },
                                selection: cursorBinding(
                                    \.motionTiltStrength,
                                    actionName: "调整光标摆动强度"
                                )
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("光标摆动强度")
                        }
                    }

                    if editorStore.sceneEditingPreviewProject.motion.cursor == .smooth {
                        EditorDisclosure(
                            "高级平滑参数",
                            detail: String(
                                format: appLocalized("质量 %@ · 刚度 %@ · 阻尼 %@"),
                                EditorSliderValueFormat.decimal1.text(for: editorStore.sceneEditingPreviewProject.motion.cursorSpringMass),
                                EditorSliderValueFormat.points.text(for: editorStore.sceneEditingPreviewProject.motion.cursorSpringStiffness),
                                EditorSliderValueFormat.points.text(for: editorStore.sceneEditingPreviewProject.motion.cursorSpringDamping)
                            )
                        ) {
                            VStack(spacing: 10) {
                                sliderRow(
                                    "光标质量",
                                    value: motionBinding(\.cursorSpringMass, actionName: "调整光标弹簧质量"),
                                    range: 0.2...8,
                                    interactionScope: .motion,
                                    format: .decimal1,
                                    style: .slim
                                )
                                sliderRow(
                                    "光标刚度",
                                    value: motionBinding(\.cursorSpringStiffness, actionName: "调整光标弹簧刚度"),
                                    range: 40...1_200,
                                    interactionScope: .motion,
                                    format: .points,
                                    style: .slim
                                )
                                sliderRow(
                                    "光标阻尼",
                                    value: motionBinding(\.cursorSpringDamping, actionName: "调整光标弹簧阻尼"),
                                    range: 4...220,
                                    interactionScope: .motion,
                                    format: .points,
                                    style: .slim
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var cursorTimingAdvance: TimeInterval {
        guard let reference = playheadSourceID.flatMap({ editorStore.previewProject.source($0)?.media.pointerEvents }) else { return 0 }
        return reference.sourceStartTime - reference.startOffset
    }

    private var cursorTimingLabel: String {
        let value = cursorTimingAdvance
        guard abs(value) >= 0.000_5 else { return "0 ms" }
        return String(
            format: appLocalized(value > 0 ? "提前 %.0f ms" : "延后 %.0f ms"),
            abs(value) * 1_000
        )
    }

    private func adjustCursorTiming(by delta: TimeInterval) {
        var project = editorStore.project
        guard delta.isFinite, let sourceID = playheadSourceID, var media = project.source(sourceID)?.media,
              var reference = media.pointerEvents else { return }
        let advance = min(max(reference.sourceStartTime - reference.startOffset + delta, -1), 1)
        reference.sourceStartTime = max(advance, 0)
        reference.startOffset = max(-advance, 0)
        media.pointerEvents = reference
        project.setMedia(media, for: sourceID)
        performEditorCommand {
            try editorStore.replaceProject(with: project, actionName: "校准光标时间")
        }
    }

    @ViewBuilder
    var cameraInspector: some View {
        Group {
            if playheadSourceID.map({ mediaSession.inventories(for: $0).camera.hasVideo }) == true {
                if case let .cameraMotion(id) = editorStore.selection {
                    CameraMotionTargetInspector(
                        editorStore: editorStore,
                        clipID: id,
                        onError: onError
                    )
                } else {
                    cameraInspectorControls
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(appLocalized("音画同步")).font(.appUI(size: 17, weight: .semibold))
                    if let sourceID = playheadSourceID {
                        Text(String(format: appLocalized("%@ · 播放头所在片段"), RecordingSourcePresentation.name(sourceID, in: editorStore.project)))
                            .font(.appUI(size: 12.5)).foregroundStyle(RecordingDesign.tertiary)
                        Text(String(format: appLocalized("%@没有摄像头，无需同步"), RecordingSourcePresentation.name(sourceID, in: editorStore.project)))
                            .font(.appUI(size: 13)).foregroundStyle(RecordingDesign.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(RecordingDesign.fill, in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        Text(appLocalized("当前片段没有摄像头，无需同步")).font(.appUI(size: 13)).foregroundStyle(RecordingDesign.tertiary)
                    }
                }
            }
        }
    }

    var cameraInspectorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorToggle(
                isOn: Binding(
                    get: { !editorStore.sceneEditingPreviewProject.camera.isHidden },
                    set: { cameraBinding(\.isHidden, actionName: "切换摄像头显示").wrappedValue = !$0 }
                ),
                title: "显示摄像头"
            )

            if editorStore.sceneEditingPreviewProject.camera.isHidden {
                Button {
                    addCameraMotionAtPlayhead()
                } label: {
                    EditorSymbolLabel("在播放头添加出现动画", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
            } else {
                EditorInspectorSection("位置与形状") {
                    EditorTransactionalPositionPad(
                        editorStore: editorStore,
                        title: "摄像头位置",
                        point: cameraBinding(
                            \.position,
                            actionName: "移动摄像头"
                        ),
                        commandScope: .camera,
                        actionName: "移动摄像头",
                        onError: onError
                    )

                    CameraShapeIconPicker(
                        selection: editorStore.sceneEditingPreviewProject.camera.shape,
                        onSelect: { cameraBinding(\.shape, actionName: "调整摄像头形状").wrappedValue = $0 }
                    )
                }

                EditorInspectorSection("外观") {
                    EditorKnobRow {
                        knob(
                            "摄像头大小", label: "大小",
                            value: cameraBinding(\.size, actionName: "调整摄像头大小"),
                            range: 0.05...0.8, format: .percent
                        )
                        if editorStore.sceneEditingPreviewProject.camera.shape != .circle {
                            knob(
                                "圆角程度", label: "圆角",
                                value: cameraBinding(\.roundness, actionName: "调整摄像头圆角"),
                                range: 0...1, format: .percent
                            )
                        }
                        knob(
                            "摄像头描边", label: "描边",
                            value: cameraBinding(\.borderWidth, actionName: "调整摄像头描边"),
                            range: 0...18, format: .points
                        )
                        knob(
                            "摄像头阴影", label: "阴影",
                            value: cameraBinding(\.shadowStrength, actionName: "调整摄像头阴影"),
                            range: 0...1, format: .percent
                        )
                    }
                    EditorToggle(
                        isOn: cameraBinding(\.isMirrored, actionName: "切换摄像头镜像"),
                        title: "镜像摄像头"
                    )
                }

                EditorInspectorSection("美颜") {
                    sliderRow("磨皮", value: cameraBinding(\.beauty.smoothing, actionName: "调整磨皮"),
                              range: 0...1, format: .percent)
                    sliderRow("美白", value: cameraBinding(\.beauty.whitening, actionName: "调整美白"),
                              range: 0...1, format: .percent)
                }

                cameraLayoutAnimationSection

                EditorDisclosure("缩放联动", detail: EditorSliderValueFormat.multiplier.text(for: editorStore.sceneEditingPreviewProject.camera.scaleDuringZoom)) {
                    sliderRow("屏幕放大时的摄像头倍率",
                              value: cameraBinding(\.scaleDuringZoom, actionName: "调整摄像头缩放跟随"),
                              range: 0.35...1.25, format: .multiplier)
                }

                EditorDisclosure(
                    "蒙版内取景",
                    detail: "\(EditorSliderValueFormat.multiplier.text(for: editorStore.sceneEditingPreviewProject.camera.contentScale)) · \(Int((editorStore.sceneEditingPreviewProject.camera.contentPosition.x * 100).rounded())), \(Int((editorStore.sceneEditingPreviewProject.camera.contentPosition.y * 100).rounded()))"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        EditorTransactionalPositionPad(
                            editorStore: editorStore,
                            title: "取景位置",
                            point: cameraBinding(
                                \.contentPosition,
                                actionName: "调整蒙版内取景"
                            ),
                            commandScope: .camera,
                            actionName: "调整蒙版内取景",
                            onError: onError
                        )
                        sliderRow(
                            "蒙版内素材缩放",
                            value: cameraBinding(
                                \.contentScale,
                                actionName: "调整蒙版内素材缩放"
                            ),
                            range: 1...3,
                            format: .multiplier
                        )
                        HStack {
                            Spacer()
                            Button("重置取景") {
                                var camera = editorStore.sceneEditingProject.camera
                                camera.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
                                camera.contentScale = 1
                                performEditorCommand {
                                    try editorStore.replaceCamera(
                                        with: camera,
                                        actionName: "重置蒙版内取景"
                                    )
                                }
                            }
                            .buttonStyle(.editorGhost)
                            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                        }
                    }
                }

            }

            EditorDisclosure(
                "音画同步",
                detail: cameraSyncSummaryLabel,
                icon: cameraSyncIsUnmodified
                    ? "checkmark.circle.fill"
                    : "waveform.path.ecg",
                iconTint: cameraSyncIsUnmodified ? EditorConsole.frame.stroke : EditorConsole.camera.stroke,
                expanded: $isCameraSyncEditing,
                accessibilityHint: isCameraSyncEditing ? "收起校正设置" : "展开校正设置"
            ) {
                cameraSyncCorrectionControls
                    .padding(.top, 6)
            }
        }
    }

    var cameraLayoutAnimationSection: some View {
        EditorInspectorSection("在播放头切换布局") {
            HStack(spacing: 8) {
                cameraLayoutPresetButton("当前", icon: "viewfinder") {
                    addCameraMotionAtPlayhead()
                }
                cameraLayoutPresetButton("全屏", icon: "rectangle.fill") {
                    insertCameraLayoutPreset(
                        layout: .fullscreen,
                        position: NormalizedPoint(x: 0.5, y: 0.5),
                        size: 1
                    )
                }
                cameraLayoutPresetButton("画中画", icon: "rectangle.on.rectangle") {
                    insertCameraLayoutPreset(
                        layout: .shape(editorStore.sceneEditingProject.camera.shape),
                        position: editorStore.sceneEditingProject.camera.position,
                        size: editorStore.sceneEditingProject.camera.size
                    )
                }
                // EDT-063: saved layouts live in one compact menu on the same
                // row instead of a half-empty second row.
                EditorActionMenu(title: "我的摄像头布局预设", items:
                    savedLayoutPresets.map { preset in
                        .action(preset.name) { applySavedLayoutPreset(preset) }
                    }
                    + (savedLayoutPresets.isEmpty ? [] : [.separator])
                    + [.action(appLocalized("存为预设…")) {
                        layoutPresetName = ""
                        isNamingLayoutPreset = true
                    }]
                    + (savedLayoutPresets.isEmpty ? [] : [.separator] + savedLayoutPresets.map { preset in
                        .action(String(format: appLocalized("删除“%@”"), preset.name)) { deleteSavedLayoutPreset(preset) }
                    })
                ) {
                    EditorSymbol("ellipsis", size: 13)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(EditorTheme.secondaryText)
                        .frame(width: 28, height: 28)
                }
                .help(appLocalized("布局预设"))
                .accessibilityLabel("我的摄像头布局预设")
            }

            .onAppear { savedLayoutPresets = Self.loadSavedLayoutPresets() }
            .appDialog(isPresented: $isNamingLayoutPreset) {
                AppDialog(
                    title: "保存布局预设",
                    message: "记录摄像头与画面的构图，之后可在播放头位置复用。同名预设会被替换。",
                    symbol: "rectangle.3.group", input: layoutPresetName,
                    actions: [
                        .init(id: "cancel", title: "取消", role: .cancel),
                        .init(id: "save", title: "保存", role: .primary, requiresInput: true) { name in
                            layoutPresetName = name
                            saveCurrentLayoutAsPreset()
                        }
                    ]
                )
            }
        }
    }

    var cameraSyncOffset: TimeInterval {
        guard let sourceID = playheadSourceID, let camera = editorStore.project.source(sourceID)?.media.camera else { return 0 }
        let microphoneStart = editorStore.project.source(sourceID)?.media.microphone?.sourceStartTime ?? 0
        return camera.sourceStartTime - microphoneStart
    }

    var cameraSyncOffsetLabel: String {
        let milliseconds = Int((cameraSyncOffset * 1_000).rounded())
        return String(format: "%+d ms", milliseconds)
    }

    var cameraSyncIsUnmodified: Bool {
        abs(cameraSyncOffset) < 0.000_5 && cameraSyncAnchors.isEmpty
    }

    var cameraSyncSummaryLabel: String {
        if cameraSyncIsUnmodified { return appLocalized("同步正常") }
        if cameraSyncAnchors.isEmpty {
            return String(format: appLocalized("已应用 %@"), cameraSyncOffsetLabel)
        }
        return String(
            format: appLocalized("已应用 %@ · %lld 个分段点"),
            cameraSyncOffsetLabel, Int64(cameraSyncAnchors.count)
        )
    }

    var cameraSyncCorrectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sourceID = playheadSourceID {
                Text(String(format: appLocalized("%@ · 播放头所在片段"), RecordingSourcePresentation.name(sourceID, in: editorStore.project)))
                    .font(.appUI(size: 12.5)).foregroundStyle(RecordingDesign.tertiary)
            }
            HStack(spacing: 8) {
                Text(appLocalized("这份录制的偏移")).font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.secondaryText)
                Spacer()
                Text(cameraSyncOffsetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    resetCameraSync()
                } label: {
                    EditorSymbolLabel("归零", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.editorGhost)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .disabled(abs(cameraSyncOffset) < 0.000_5)
                .help(appLocalized("只归零这份录制的偏移，保留它的分段同步点"))
            }

            cameraSyncNudgeRow(
                stepTitle: "10 ms",
                onDelay: { adjustCameraSync(by: -0.010) },
                onAdvance: { adjustCameraSync(by: 0.010) }
            )
            cameraSyncNudgeRow(
                stepTitle: "1 帧",
                onDelay: { adjustCameraSync(by: -cameraSyncFrameDuration) },
                onAdvance: { adjustCameraSync(by: cameraSyncFrameDuration) }
            )

            Text("声音比画面先到时选提前")
                .font(EditorTypography.helper)
                .foregroundStyle(EditorTheme.tertiaryText)

            Divider().overlay(dividerColor)

            HStack(spacing: 8) {
                Text("分段同步点").font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.secondaryText)
                Spacer()
                Text(String(
                    format: appLocalized("%lld 个 · 当前 %@"),
                    Int64(cameraSyncAnchors.count), cameraAnchorTotalOffsetLabel
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if cameraAnchorSourceTime == nil {
                EditorSymbolLabel("当前播放头无法映射到源素材", systemImage: "exclamationmark.triangle")
                    .font(.appUI(size: 10))
                    .foregroundStyle(.secondary)
            } else if hasCameraAnchorAtPlayhead {
                cameraSyncNudgeRow(
                    stepTitle: "10 ms",
                    onDelay: { adjustCameraAnchor(by: -0.010) },
                    onAdvance: { adjustCameraAnchor(by: 0.010) }
                )

                Button("删除播放头同步点", role: .destructive) {
                    removeCameraAnchorAtPlayhead()
                }
                .buttonStyle(.editorDestructive)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Button {
                    adjustCameraAnchor(by: 0)
                } label: {
                    EditorSymbolLabel("在播放头固定同步点", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            }

            Text("在错位开始前固定一个点，再到错位处调整")
                .font(EditorTypography.helper)
                .foregroundStyle(EditorTheme.tertiaryText)
        }
    }

    func cameraSyncNudgeRow(
        stepTitle: String,
        onDelay: @escaping () -> Void,
        onAdvance: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(appLocalized(stepTitle))
                .font(.appUI(size: 11).monospacedDigit())
                .foregroundStyle(EditorTheme.secondaryText)
                .fixedSize()
                .frame(minWidth: 36, alignment: .leading)
            // Same order as the cursor's timing: earlier on the left.
            Button(action: onAdvance) {
                Text(appLocalized("提前")).frame(maxWidth: .infinity)
            }
            .accessibilityLabel(String(format: appLocalized("画面提前 %@"), appLocalized(stepTitle)))
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            Button(action: onDelay) {
                Text(appLocalized("延后")).frame(maxWidth: .infinity)
            }
            .accessibilityLabel(String(format: appLocalized("画面延后 %@"), appLocalized(stepTitle)))
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        }
        .buttonStyle(.editorQuiet)
    }

    var cameraSyncFrameDuration: TimeInterval {
        1 / max(playheadSourceID.map { mediaSession.inventories(for: $0).camera.videoFrameRate ?? 25 } ?? 25, 1)
    }

    var cameraSyncAnchors: [MediaSyncAnchor] {
        playheadSourceID.flatMap { editorStore.project.source($0)?.media.camera?.syncAnchors } ?? []
    }

    var cameraAnchorSourceTime: TimeInterval? {
        playheadSourcePosition?.time
    }

    var cameraAnchorOffset: TimeInterval {
        guard let sourceTime = cameraAnchorSourceTime else { return 0 }
        return MediaSyncAnchorCurve(cameraSyncAnchors).offset(atSourceTime: sourceTime)
    }

    var cameraAnchorTotalOffsetLabel: String {
        let milliseconds = Int(((cameraSyncOffset + cameraAnchorOffset) * 1_000).rounded())
        return String(format: "%+d ms", milliseconds)
    }

    var cameraAnchorTolerance: TimeInterval {
        max(cameraSyncFrameDuration / 2, 0.020)
    }

    var hasCameraAnchorAtPlayhead: Bool {
        guard let sourceTime = cameraAnchorSourceTime else { return false }
        return cameraSyncAnchors.contains {
            abs($0.sourceTime - sourceTime) <= cameraAnchorTolerance
        }
    }

    /// Positive delta advances the visible camera by sampling a later source
    /// frame at the same output time. Negative delta delays it. Editing the
    /// persisted source trim means preview and export consume one identical
    /// mapping rather than applying a player-only correction.
    func adjustCameraSync(by delta: TimeInterval) {
        var project = editorStore.project
        guard let sourceID = playheadSourceID, var media = project.source(sourceID)?.media, var camera = media.camera else { return }
        camera.sourceStartTime = max(camera.sourceStartTime + delta, 0)
        media.camera = camera
        project.setMedia(media, for: sourceID)
        commitCameraSyncProject(
            project,
            actionName: "校准摄像头音画同步",
            auditionAt: playbackTime
        )
    }

    func resetCameraSync() {
        var project = editorStore.project
        guard let sourceID = playheadSourceID, var media = project.source(sourceID)?.media,
              var camera = media.camera else { return }
        camera.sourceStartTime = media.microphone?.sourceStartTime ?? 0
        media.camera = camera
        project.setMedia(media, for: sourceID)
        commitCameraSyncProject(
            project,
            actionName: "归零摄像头音画同步",
            auditionAt: playbackTime
        )
    }

    func adjustCameraAnchor(by delta: TimeInterval) {
        guard let sourceTime = cameraAnchorSourceTime else { return }
        var project = editorStore.project
        guard let sourceID = playheadSourceID, var media = project.source(sourceID)?.media, var camera = media.camera else { return }
        let curve = MediaSyncAnchorCurve(camera.syncAnchors)
        if let index = camera.syncAnchors.indices.min(by: {
            abs(camera.syncAnchors[$0].sourceTime - sourceTime)
                < abs(camera.syncAnchors[$1].sourceTime - sourceTime)
        }), abs(camera.syncAnchors[index].sourceTime - sourceTime) <= cameraAnchorTolerance {
            camera.syncAnchors[index].offset = min(
                max(camera.syncAnchors[index].offset + delta, -10),
                10
            )
        } else {
            camera.syncAnchors.append(MediaSyncAnchor(
                sourceTime: sourceTime,
                offset: curve.offset(atSourceTime: sourceTime) + delta
            ))
        }
        media.camera = camera
        project.setMedia(media, for: sourceID)
        commitCameraSyncProject(
            project,
            actionName: "调整摄像头分段同步",
            auditionAt: playbackTime
        )
    }

    func removeCameraAnchorAtPlayhead() {
        guard let sourceTime = cameraAnchorSourceTime else { return }
        var project = editorStore.project
        guard let sourceID = playheadSourceID, var media = project.source(sourceID)?.media, var camera = media.camera,
              let index = camera.syncAnchors.indices.min(by: {
                  abs(camera.syncAnchors[$0].sourceTime - sourceTime)
                      < abs(camera.syncAnchors[$1].sourceTime - sourceTime)
              }), abs(camera.syncAnchors[index].sourceTime - sourceTime) <= cameraAnchorTolerance
        else { return }
        camera.syncAnchors.remove(at: index)
        media.camera = camera
        project.setMedia(media, for: sourceID)
        commitCameraSyncProject(
            project,
            actionName: "删除摄像头同步点",
            auditionAt: playbackTime
        )
    }

    func commitCameraSyncProject(
        _ project: RecorderProject,
        actionName: String,
        auditionAt outputTime: TimeInterval
    ) {
        do {
            try editorStore.replaceProject(with: project, actionName: actionName)
            playbackController.scheduleCameraSyncAudition(at: outputTime)
        } catch {
            onError(error.localizedDescription)
        }
    }

    var audioInspector: some View {
        VStack(alignment: .leading, spacing: usesCompactSelectedAudioLayout ? 8 : 14) {
            if let segmentID = selectedPrimarySegmentForAudio {
                selectedAudioContext(segmentID)
                EditorInspectorSection("片段声音", showsTitle: !usesCompactSelectedAudioLayout) {
                    VStack(alignment: .leading, spacing: 4) {
                    if let context = primarySegmentContext(id: segmentID), context.segment.media != nil {
                        if insertedSegmentHasControllableSound(context.segment) {
                            insertedSegmentSoundRows(segmentID: segmentID, segment: context.segment)
                        } else {
                            audioGhostStrip(
                                "片段声音",
                                icon: .speakerOff
                            )
                        }
                    } else {
                    if sourceHasAudio {
                        audioVolumeRow(
                            "系统声音",
                            icon: .speaker,
                            detail: segmentAudioSourceDetail(segmentID, microphone: false),
                            value: primarySegmentSystemVolumeBinding(
                                segmentID: segmentID
                            ),
                            isMuted: primarySegmentSystemMuteBinding(
                                segmentID: segmentID
                            ),
                            commandScope: .selection,
                            accessibilityStem: "editor.audio.segment.system"
                        )
                    }
                    if microphoneHasAudio {
                        audioVolumeRow(
                            "麦克风",
                            icon: .microphone,
                            detail: segmentAudioSourceDetail(segmentID, microphone: true),
                            value: primarySegmentMicrophoneVolumeBinding(
                                segmentID: segmentID
                            ),
                            isMuted: primarySegmentMicrophoneMuteBinding(
                                segmentID: segmentID
                            ),
                            commandScope: .selection,
                            accessibilityStem: "editor.audio.segment.microphone"
                        )
                    }
                    }
                    }
                }
            } else if projectHasSystemAudio || projectHasMicrophoneAudio {
                // 这一支是全片音量，可用性按项目素材判断：播放头停在插入
                // 片段上时，项目里的声音并没有消失。
                EditorInspectorSection("音量") {
                    VStack(alignment: .leading, spacing: 4) {
                    if projectHasSystemAudio {
                        audioVolumeRow(
                            "系统声音",
                            icon: .speaker,
                            detail: "录屏中的应用与系统声音",
                            value: audioBinding(\.systemVolume, actionName: "调整系统声音音量"),
                            isMuted: audioBinding(\.isSystemMuted, actionName: "切换系统声音"),
                            accessibilityStem: "editor.audio.system"
                        )
                    } else {
                        audioGhostStrip(
                            "系统声音",
                            icon: .speaker
                        )
                    }
                    if projectHasMicrophoneAudio {
                        audioVolumeRow(
                            "麦克风",
                            icon: .microphone,
                            detail: "独立录制的人声轨道",
                            value: audioBinding(\.microphoneVolume, actionName: "调整麦克风音量"),
                            isMuted: audioBinding(\.isMicrophoneMuted, actionName: "切换麦克风"),
                            accessibilityStem: "editor.audio.microphone"
                        )
                    } else {
                        audioGhostStrip(
                            "麦克风",
                            icon: .microphone
                        )
                    }
                    }
                }
            }
            if let segmentID = selectedPrimarySegmentForAudio {
                // The clip's own edits (split, merge, restore, delete) sit with
                // its sound, so selecting a clip never hides what can be done
                // with it behind another tab.
                primarySegmentInspector(id: segmentID)
            }
            if selectedPrimarySegmentForAudio == nil,
               !projectHasSystemAudio && !projectHasMicrophoneAudio {
                EditorInspectorEmptyState(
                    title: "没有音频轨",
                    detail: "这个项目中没有可编辑的系统声音或麦克风素材。",
                    systemImage: "speaker.slash"
                )
            }
        }
    }

    /// A silent placeholder where a channel would sit, so the page shows
    /// what the recording did not capture.
    func audioGhostStrip(
        _ title: String,
        icon: AppLineIcon.Kind
    ) -> some View {
        EditorMixerGhostStrip(title: title, icon: icon)
    }

    private var selectedPrimarySegmentForAudio: UUID? {
        guard case let .primarySegment(id) = editorStore.selection else { return nil }
        return id
    }

    func primarySegmentSystemVolumeBinding(segmentID: UUID) -> Binding<Double> {
        editorPrimarySegmentAudioBinding(
            store: editorStore,
            segmentID: segmentID,
            get: { project, overrides in
                overrides.systemVolume
                    ?? project.audio.systemVolume
            },
            set: { overrides, value in
                overrides.systemVolume = min(max(value, 0), 1)
            },
            actionName: "调整当前片段系统声音",
            onError: onError
        )
    }

    func primarySegmentSystemMuteBinding(segmentID: UUID) -> Binding<Bool> {
        editorPrimarySegmentAudioBinding(
            store: editorStore,
            segmentID: segmentID,
            get: { project, overrides in
                overrides.isSystemMuted ?? project.audio.isSystemMuted
            },
            set: { $0.isSystemMuted = $1 },
            actionName: "切换当前片段系统声音",
            onError: onError
        )
    }

    func primarySegmentMicrophoneVolumeBinding(
        segmentID: UUID
    ) -> Binding<Double> {
        editorPrimarySegmentAudioBinding(
            store: editorStore,
            segmentID: segmentID,
            get: { project, overrides in
                overrides.microphoneVolume
                    ?? project.audio.microphoneVolume
            },
            set: { overrides, value in
                overrides.microphoneVolume = min(max(value, 0), 1)
            },
            actionName: "调整当前片段麦克风",
            onError: onError
        )
    }

    func primarySegmentMicrophoneMuteBinding(
        segmentID: UUID
    ) -> Binding<Bool> {
        editorPrimarySegmentAudioBinding(
            store: editorStore,
            segmentID: segmentID,
            get: { project, overrides in
                overrides.isMicrophoneMuted ?? project.audio.isMicrophoneMuted
            },
            set: { $0.isMicrophoneMuted = $1 },
            actionName: "切换当前片段麦克风",
            onError: onError
        )
    }

    func audioVolumeRow(
        _ title: String,
        icon: AppLineIcon.Kind,
        detail: String,
        value: Binding<Double>,
        isMuted: Binding<Bool>,
        commandScope: EditorInteractionCommandScope = .audio,
        accessibilityStem: String
    ) -> some View {
        EditorMixerStrip(
            editorStore: editorStore,
            title: title,
            icon: icon,
            detail: detail,
            volume: value,
            isMuted: isMuted,
            commandScope: commandScope,
            accessibilityStem: accessibilityStem,
            onError: onError
        )
    }

    /// One rotary control. `title` names the undo step; `label` is the short
    /// caption under the knob.
    func knob(
        _ title: String,
        label: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        interactionScope: EditorInteractionCommandScope? = nil,
        format: EditorSliderValueFormat = .decimal2
    ) -> some View {
        EditorTransactionalKnob(
            editorStore: editorStore,
            title: title,
            label: label,
            value: value,
            range: range,
            commandScope: interactionScope ?? inferredContinuousCommandScope,
            format: format,
            onError: onError
        )
    }

    func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        interactionScope: EditorInteractionCommandScope? = nil,
        format: EditorSliderValueFormat = .decimal2,
        style: EditorSliderRowStyle = .bar
    ) -> some View {
        let commandScope = interactionScope ?? inferredContinuousCommandScope
        return EditorTransactionalSliderRow(
            editorStore: editorStore,
            title: title,
            value: value,
            range: range,
            commandScope: commandScope,
            format: format,
            style: style,
            onError: onError
        )
    }

    var inferredContinuousCommandScope: EditorInteractionCommandScope {
        switch selectedInspector {
        case .frame: return .canvas
        case .opening: return .project
        case .camera: return .camera
        case .audio: return .audio
        case .cursor: return .cursor
        case .zoom: return .selection
        }
    }

    func canvasBinding<Value>(
        _ keyPath: WritableKeyPath<CanvasStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorCanvasBinding(
            store: editorStore, keyPath: keyPath,
            actionName: actionName, onError: onError
        )
    }

    func cameraBinding<Value>(
        _ keyPath: WritableKeyPath<CameraStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorCameraBinding(
            store: editorStore, keyPath: keyPath,
            actionName: actionName, onError: onError
        )
    }

    func audioBinding<Value>(
        _ keyPath: WritableKeyPath<AudioStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorAudioBinding(
            store: editorStore, keyPath: keyPath,
            actionName: actionName, onError: onError
        )
    }

    func cursorBinding<Value>(
        _ keyPath: WritableKeyPath<CursorStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorCursorBinding(
            store: editorStore, keyPath: keyPath,
            actionName: actionName, onError: onError
        )
    }

    func motionBinding<Value>(
        _ keyPath: WritableKeyPath<MotionStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorMotionBinding(
            store: editorStore, keyPath: keyPath,
            actionName: actionName, onError: onError
        )
    }

}

/// 点击动画风格选择器：涟漪扩散、柔和光晕、弹性双环、聚焦微闪、无。
struct CursorClickEffectStylePicker: View {
    let selection: CursorClickEffectStyle
    let onSelect: (CursorClickEffectStyle) -> Void

    @Environment(\.consolePalette) private var palette
    @State private var hoveredStyle: CursorClickEffectStyle?

    private func shortName(for style: CursorClickEffectStyle) -> String {
        switch style {
        case .ripple: return "涟漪"
        case .glow: return "光晕"
        case .pulse: return "双环"
        case .burst: return "微闪"
        case .none: return "无"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(CursorClickEffectStyle.allCases, id: \.self) { style in
                    let isSelected = selection == style
                    let isPreviewing = hoveredStyle == style
                    Button {
                        onSelect(style)
                    } label: {
                        VStack(spacing: 4) {
                            CursorClickEffectPreviewGlyph(
                                style: style,
                                isActive: isPreviewing,
                                color: isSelected ? EditorTheme.primaryText : EditorTheme.secondaryText
                            )
                            Text(appLocalized(shortName(for: style)))
                                .font(.appUI(size: 11, weight: isSelected ? .medium : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(
                            isSelected ? EditorTheme.primaryText : EditorTheme.secondaryText
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background {
                            if isSelected {
                                EditorRaisedThumb(shape: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                                    .fill(hoveredStyle == style ? EditorChoiceStyle.hover : .clear)
                            }
                        }
                        .animation(SpringMotion.settle, value: isSelected)
                    }
                    .buttonStyle(.editorThumbnail)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                    .onHover { isHovering in
                        hoveredStyle = isHovering ? style : (hoveredStyle == style ? nil : hoveredStyle)
                    }
                    .help(appLocalized(style.displayName))
                    .accessibilityLabel(String(format: appLocalized("%@：%@"), appLocalized("点击动画"), appLocalized(style.displayName)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(EditorTheme.controlWell,
                        in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group + 3, style: .continuous))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The picker should explain motion before it changes the project. Only the
/// selected or hovered glyph advances; the other four remain still, so the
/// inspector stays inexpensive while its choices remain visually legible.
struct CursorClickEffectPreviewGlyph: View {
    let style: CursorClickEffectStyle
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.editorIsActive) private var isEditorActive
    @State private var isAnimating = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating || !isEditorActive || reducesMotion)) { timeline in
            let rawPhase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.15) / 1.15
            let phase = isAnimating && isEditorActive && !reducesMotion ? rawPhase : 0.34
            glyph(phase: phase)
        }
        .frame(width: 28, height: 20)
        .task(id: "\(isActive):\(isEditorActive)") {
            isAnimating = isActive && isEditorActive && !reducesMotion
            guard isAnimating else { return }
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            isAnimating = false
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyph(phase: Double) -> some View {
        let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2

        switch style {
        case .ripple:
            let trailingPhase = (phase + 0.48).truncatingRemainder(dividingBy: 1)
            ZStack {
                rippleRing(phase: phase)
                rippleRing(phase: trailingPhase)
                Circle()
                    .fill(color.opacity(0.92))
                    .frame(width: 4, height: 4)
            }

        case .glow:
            Circle()
                .fill(color.opacity(0.34 + wave * 0.18))
                .frame(width: 10, height: 10)
                .scaleEffect(0.86 + wave * 0.22)
                .shadow(color: color.opacity(0.64), radius: 2.5 + wave * 4)

        case .pulse:
            ZStack {
                Circle()
                    .stroke(color.opacity(0.78), lineWidth: 1.4)
                    .scaleEffect(0.62 + wave * 0.48)
                Circle()
                    .stroke(color.opacity(0.42), lineWidth: 1.2)
                    .scaleEffect(1.06 - wave * 0.32)
            }
            .frame(width: 16, height: 16)

        case .burst:
            EditorSymbol("sparkles", size: 19.5)
                .font(.appUI(size: 15, weight: .medium))
                .foregroundStyle(color)
                .rotationEffect(.degrees(-8 + wave * 16))
                .scaleEffect(0.84 + wave * 0.24)
                .shadow(color: color.opacity(0.44), radius: 1.5 + wave * 2)

        case .none:
            EditorSymbol("slash.circle", size: 19.5)
                .font(.appUI(size: 15, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private func rippleRing(phase: Double) -> some View {
        Circle()
            .stroke(color.opacity(max(0.08, 0.76 * (1 - phase))), lineWidth: 1.35)
            .frame(width: 17, height: 17)
            .scaleEffect(0.42 + phase * 0.88)
    }
}

/// 点击颜色选择器：包含跟随光标主题色快捷选项、高频预设色板与自定义拾色器。
struct CursorClickColorPicker: View {
    @ObservedObject var editorStore: EditorStore
    let selectedColor: HexColor?
    let defaultColor: HexColor
    let onError: (String) -> Void
    let onSelect: (HexColor?) -> Void

    private static let presets: [(name: String, hex: HexColor)] = [
        ("紫色", HexColor(rgb24: 0x7C_5C_FC)),
        ("蓝色", HexColor(rgb24: 0x38_BD_F8)),
        ("绿色", HexColor(rgb24: 0x10_B9_81)),
        ("橙色", HexColor(rgb24: 0xF9_73_16)),
        ("粉色", HexColor(rgb24: 0xEC_48_99)),
        ("白色", HexColor(rgb24: 0xFF_FF_FF)),
    ]

    @State private var showsCustomColor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("颜色").font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.primaryText).fixedSize()
                Spacer(minLength: 0)
                Button { onSelect(nil) } label: {
                    AppLineIcon(kind: .undo, size: 13)
                        .foregroundStyle(EditorTheme.chrome(selectedColor == nil ? 0.32 : 0.62))
                        .frame(width: 25, height: 28)
                }
                .buttonStyle(.editorToolbarPress).help("恢复光标默认颜色")
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityLabel(appLocalized("点击颜色：跟随光标主题"))
            }
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.hex) { preset in
                    let isSelected = selectedColor == preset.hex
                    Button { onSelect(preset.hex) } label: {
                        // A hairline keeps light swatches visible on paper;
                        // the selection ring stands off by a hair of island.
                        Circle().fill(Color(hex: preset.hex))
                            .overlay(Circle().strokeBorder(EditorTheme.chrome(0.12), lineWidth: 0.5))
                            .frame(width: 18, height: 18)
                            .padding(3.5)
                            .overlay(Circle().strokeBorder(EditorTheme.selectionTint.opacity(isSelected ? 0.95 : 0), lineWidth: 1.5))
                            .animation(SpringMotion.snappy, value: isSelected)
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 10, cornerStyle: .circular)).help(appLocalized(preset.name))
                    .appButtonKeyboardFocus(in: Circle())
                    .accessibilityLabel(String(format: appLocalized("预设颜色：%@"), appLocalized(preset.name)))
                    .accessibilityAddTraits(selectedColor == preset.hex ? .isSelected : [])
                }
                Button { showsCustomColor = true } label: {
                    let custom = selectedColor.flatMap { hex in Self.presets.contains { $0.hex == hex } ? nil : hex }
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .overlay {
                            Circle().fill(custom.map { Color(hex: $0) } ?? EditorTheme.cardElevated).padding(custom == nil ? 4 : 3)
                        }
                        .overlay {
                            if custom == nil {
                                EditorSymbol("plus", size: 10.5).font(.appUI(size: 10, weight: .bold)).foregroundStyle(EditorTheme.chrome(0.6))
                            }
                        }
                        .frame(width: 20, height: 20)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 10, cornerStyle: .circular)).accessibilityLabel(appLocalized("自定义点击颜色"))
                .appButtonKeyboardFocus(in: Circle())
                .editorPopoverKeyboardEntry { showsCustomColor = true }
                .editorPopover(isPresented: $showsCustomColor, establishesKeyboardEntry: false) {
                    EditorTransactionalColorInput(editorStore: editorStore, title: "点击颜色",
                        value: customColorBinding, commandScope: .cursor,
                        actionName: "调整点击动画颜色", onError: onError, presentsPalette: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var customColorBinding: Binding<HexColor> {
        let optional = editorCursorBinding(
            store: editorStore,
            keyPath: \.clickColor,
            actionName: "调整点击动画颜色",
            onError: onError
        )
        return Binding(
            get: { optional.wrappedValue ?? defaultColor },
            set: { optional.wrappedValue = $0 }
        )
    }
}

/// An illustrative preview responds to an explicit replay or a setting change;
/// it never runs a perpetual animation just because this page is selected.
private struct EditorCursorStylePreview: View {
    let style: CursorStyle
    @State private var replayID = 0
    @State private var isReplaying = false
    @Environment(\.editorIsActive) private var isEditorActive

    private var cursorIsHidden: Bool { style.assetID == .hidden }

    var body: some View {
        Button { replayID += 1 } label: {
            ZStack {
                EditorStageBackdrop.bottom
                if cursorIsHidden {
                    EditorSymbolLabel("光标已始终隐藏", systemImage: "eye.slash")
                        .font(.appUI(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    CursorClickEffectPreviewGlyph(style: style.clickEffectStyle, isActive: isReplaying,
                        color: Color(hex: style.clickColor ?? CursorAssetLibrary.defaultClickColor))
                        .scaleEffect(2.4 * style.clickScale).opacity(style.clickOpacity)
                    Group {
                        if let image = CursorAssetLibrary.resolvedAsset(for: style.assetID)?.image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(nsImage: NSCursor.arrow.image).resizable().scaledToFit()
                        }
                    }
                    .frame(width: min(max(28 * style.size, 20), 70), height: min(max(36 * style.size, 24), 80))
                    .offset(x: 8, y: 12)
                }
            }
            .frame(height: 112)
            .overlay(alignment: .bottomTrailing) {
                if !cursorIsHidden {
                    Text("点击重播").font(EditorTypography.helper).foregroundStyle(EditorTheme.tertiaryText).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous)
                    .strokeBorder(EditorTheme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(cursorIsHidden)
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
        .accessibilityLabel(appLocalized(cursorIsHidden ? "光标已始终隐藏" : "播放光标效果示意"))
        .task(id: "\(replayID):\(style.clickEffectStyle):\(isEditorActive):\(cursorIsHidden)") {
            isReplaying = isEditorActive && !cursorIsHidden
            guard isReplaying else { return }
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            isReplaying = false
        }
    }
}
