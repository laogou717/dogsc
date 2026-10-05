import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorInspectorView {
    var cursorInspector: some View {
        let cursorIsHidden = editorStore.previewProject.cursorStyle.assetID == .hidden

        return VStack(alignment: .leading, spacing: 12) {
            EditorCursorStylePreview(style: editorStore.previewProject.cursorStyle)
            EditorSegmentedControl(
                options: cursorAssets.map(\.id),
                title: { id in appLocalized(cursorAssets.first(where: { $0.id == id })?.displayName ?? "系统") },
                selection: cursorBinding(\.assetID, actionName: "调整光标样式")
            )
            VStack(alignment: .leading, spacing: 12) {
                if cursorIsHidden {
                    Text("预览和导出均不显示光标及点击反馈。选择“系统”或“触控圆点”可恢复。")
                        .font(.appUI(.caption2))
                        .foregroundStyle(.secondary)
                } else {
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
                    if editorStore.previewProject.cursorStyle.hideWhenIdle {
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
                EditorInspectorSection("点击反馈") {
                    CursorClickEffectStylePicker(
                        selection: editorStore.previewProject.cursorStyle.clickEffectStyle,
                        onSelect: { newStyle in
                            var style = editorStore.project.cursorStyle
                            style.clickEffectStyle = newStyle
                            performEditorCommand {
                                try editorStore.replaceCursor(with: style, actionName: "调整点击动画样式")
                            }
                        }
                    )

                    if editorStore.previewProject.cursorStyle.clickEffectStyle != .none {
                        let defaultColor = CursorAssetLibrary.resolvedAsset(
                            for: editorStore.previewProject.cursorStyle.assetID
                        )?.metrics.clickColor ?? CursorAssetLibrary.defaultClickColor

                        CursorClickColorPicker(
                            editorStore: editorStore,
                            selectedColor: editorStore.previewProject.cursorStyle.clickColor,
                            defaultColor: defaultColor,
                            onError: onError,
                            onSelect: { newColor in
                                var style = editorStore.project.cursorStyle
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

                EditorDisclosure("移动手感", detail: editorStore.previewProject.motion.cursor == .none
                    ? appLocalized("线性") : appLocalized(editorStore.previewProject.motion.cursor.rawValue)) {
                    EditorSegmentedControl(
                        options: CursorMotionStyle.allCases,
                        title: { style in
                            style == .none ? appLocalized("线性") : appLocalized(style.rawValue)
                        },
                        selection: motionBinding(\.cursor, actionName: "调整光标动画")
                    )

                    if editorStore.previewProject.motion.cursor != .none {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("摆动强度")
                                .font(.appUI(.caption, weight: .semibold))
                            EditorSegmentedControl(
                                options: [2.0, 2.5, 3.0, 3.5, 4.0],
                                title: { "\(Int($0 * 100))" },
                                accessibilityTitle: { "\(appLocalized("光标摆动强度")) \(Int($0 * 100))%" },
                                selection: cursorBinding(
                                    \.motionTiltStrength,
                                    actionName: "调整光标摆动强度"
                                )
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("光标摆动强度")
                        }
                        Text("强度以百分比表示")
                            .font(.appUI(.caption2))
                            .foregroundStyle(.secondary)
                    }

                    if editorStore.previewProject.motion.cursor == .smooth {
                        EditorDisclosure(
                            "高级平滑参数",
                            detail: String(
                                format: appLocalized("质量 %@ · 刚度 %@ · 阻尼 %@"),
                                EditorSliderValueFormat.decimal1.text(for: editorStore.previewProject.motion.cursorSpringMass),
                                EditorSliderValueFormat.points.text(for: editorStore.previewProject.motion.cursorSpringStiffness),
                                EditorSliderValueFormat.points.text(for: editorStore.previewProject.motion.cursorSpringDamping)
                            )
                        ) {
                            VStack(spacing: 10) {
                                sliderRow(
                                    "光标质量",
                                    value: motionBinding(\.cursorSpringMass, actionName: "调整光标弹簧质量"),
                                    range: 0.2...8,
                                    interactionScope: .motion,
                                    format: .decimal1
                                )
                                sliderRow(
                                    "光标刚度",
                                    value: motionBinding(\.cursorSpringStiffness, actionName: "调整光标弹簧刚度"),
                                    range: 40...1_200,
                                    interactionScope: .motion,
                                    format: .points
                                )
                                sliderRow(
                                    "光标阻尼",
                                    value: motionBinding(\.cursorSpringDamping, actionName: "调整光标弹簧阻尼"),
                                    range: 4...220,
                                    interactionScope: .motion,
                                    format: .points
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var cameraInspector: some View {
        Group {
            if cameraHasVideo {
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
                EditorInspectorEmptyState(
                    title: "没有摄像头轨",
                    detail: "这个项目没有可编辑的摄像头素材。",
                    systemImage: "video.slash"
                )
            }
        }
    }

    var cameraInspectorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("基础布局作用于全片；时间线动画可在指定时段覆盖它。")
                .font(.appUI(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EditorToggle(
                isOn: Binding(
                    get: { !editorStore.previewProject.camera.isHidden },
                    set: { cameraBinding(\.isHidden, actionName: "切换摄像头显示").wrappedValue = !$0 }
                ),
                title: "显示摄像头"
            )

            if editorStore.previewProject.camera.isHidden {
                Text("摄像头初始隐藏；仍可在播放头添加出现动画。开启后可调整布局和外观。")
                    .font(.appUI(.caption2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    addCameraMotionAtPlayhead()
                } label: {
                    Label("在播放头添加出现动画", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorPrimary(minHeight: 32))
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous), color: EditorTheme.onAccent.opacity(0.65))
            } else {
                EditorInspectorSection("位置与形状") {
                    Label(
                        "直接在画布中拖动，拖右下角调整大小",
                        systemImage: "hand.draw"
                    )
                    .font(.appUI(.caption2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                    sliderRow(
                        "摄像头大小",
                        value: cameraBinding(\.size, actionName: "调整摄像头大小"),
                        range: 0.05...0.8,
                        format: .percent
                    )

                    CameraShapeIconPicker(
                        selection: editorStore.previewProject.camera.shape,
                        onSelect: { cameraBinding(\.shape, actionName: "调整摄像头形状").wrappedValue = $0 }
                    )

                    if editorStore.previewProject.camera.shape != .circle {
                        sliderRow(
                            "圆角程度",
                            value: cameraBinding(\.roundness, actionName: "调整摄像头圆角"),
                            range: 0...1,
                            format: .percent
                        )
                    }
                }

                EditorInspectorSection("基础外观") {
                    EditorToggle(
                        isOn: cameraBinding(\.isMirrored, actionName: "切换摄像头镜像"),
                        title: "镜像摄像头"
                    )
                    sliderRow("描边", value: cameraBinding(\.borderWidth, actionName: "调整摄像头描边"),
                              range: 0...18, format: .points)
                    sliderRow("阴影", value: cameraBinding(\.shadowStrength, actionName: "调整摄像头阴影"),
                              range: 0...1, format: .percent)
                }

                cameraLayoutAnimationSection

                EditorDisclosure("缩放联动", detail: EditorSliderValueFormat.multiplier.text(for: editorStore.previewProject.camera.scaleDuringZoom)) {
                    sliderRow("屏幕放大时的摄像头倍率",
                              value: cameraBinding(\.scaleDuringZoom, actionName: "调整摄像头缩放跟随"),
                              range: 0.35...1.25, format: .multiplier)
                    Text("跟随屏幕缩放调整摄像头大小；1 倍保持原大小。")
                        .font(.appUI(.caption2)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                EditorDisclosure(
                    "蒙版内取景",
                    detail: "\(EditorSliderValueFormat.multiplier.text(for: editorStore.previewProject.camera.contentScale)) · \(Int((editorStore.previewProject.camera.contentPosition.x * 100).rounded())), \(Int((editorStore.previewProject.camera.contentPosition.y * 100).rounded()))"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("只调整原摄像素材在当前蒙版内显示的位置和大小，不移动蒙版本身。")
                            .font(.appUI(.caption2))
                            .foregroundStyle(.secondary)
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
                                var camera = editorStore.project.camera
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
                iconTint: cameraSyncIsUnmodified ? Color.green : editorAccent,
                expanded: $isCameraSyncEditing,
                accessibilityHint: isCameraSyncEditing ? "收起校正设置" : "展开校正设置"
            ) {
                cameraSyncCorrectionControls
                    .padding(.top, 6)
            }
        }
    }

    var cameraLayoutAnimationSection: some View {
        EditorInspectorSection("播放头布局动画") {
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
                        layout: .shape(editorStore.project.camera.shape),
                        position: editorStore.project.camera.position,
                        size: editorStore.project.camera.size
                    )
                }
            }
            Label("在播放头创建布局动画；播放头位于已有动画内时直接更新", systemImage: "info.circle")
                .font(.appUI(.caption2))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    layoutPresetName = ""
                    isNamingLayoutPreset = true
                } label: {
                    Label("保存摄像头布局预设", systemImage: "square.and.arrow.down")
                        .font(.appUI(.caption2))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .foregroundStyle(.secondary)

                if !savedLayoutPresets.isEmpty {
                    EditorActionMenu(title: "我的摄像头布局预设", items:
                        savedLayoutPresets.map { preset in
                            .action(preset.name) { applySavedLayoutPreset(preset) }
                        } + [.separator] + savedLayoutPresets.map { preset in
                            .action("删除“\(preset.name)”") { deleteSavedLayoutPreset(preset) }
                        }
                    ) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up")
                            Text("我的预设")
                            Spacer(minLength: 2)
                            Image(systemName: "chevron.down")
                                .font(.appUI(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.appUI(.caption2, weight: .medium))
                        .foregroundStyle(
                            Color.primary.opacity(
                                savedLayoutPresetMenuHovered ? 1 : 0.88
                            )
                        )
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            EditorTheme.chrome(
                                savedLayoutPresetMenuHovered ? 0.085 : 0.045
                            ),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    EditorTheme.chrome(
                                        savedLayoutPresetMenuHovered ? 0.15 : 0.08
                                    ),
                                    lineWidth: 0.75
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .scaleEffect(savedLayoutPresetMenuHovered ? 1.01 : 1)
                    .onHover { hovering in
                        withAnimation(SpringMotion.interactive) {
                            savedLayoutPresetMenuHovered = hovering
                        }
                    }
                    .accessibilityLabel("我的摄像头布局预设")
                }
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
        guard let camera = editorStore.project.media?.camera else { return 0 }
        let microphoneStart = editorStore.project.media?.microphone?.sourceStartTime ?? 0
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
            HStack(spacing: 8) {
                Text("全片偏移").font(.appUI(.caption, weight: .semibold))
                Spacer()
                Text(cameraSyncOffsetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    resetCameraSync()
                } label: {
                    Label("归零", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.editorGhost)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .disabled(abs(cameraSyncOffset) < 0.000_5)
                .help("只归零全片偏移，保留分段同步点")
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

            Text("声音先出来、嘴后动：点“画面提前”。每次调整会自动试听，预览与导出使用同一结果。")
                .font(.appUI(.caption2))
                .foregroundStyle(.secondary)

            Divider().overlay(dividerColor)

            HStack(spacing: 8) {
                Text("分段同步点").font(.appUI(.caption, weight: .semibold))
                Spacer()
                Text(String(
                    format: appLocalized("%lld 个 · 当前 %@"),
                    Int64(cameraSyncAnchors.count), cameraAnchorTotalOffsetLabel
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if cameraAnchorSourceTime == nil {
                Label("当前播放头无法映射到源素材", systemImage: "exclamationmark.triangle")
                    .font(.appUI(.caption2))
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
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Button {
                    adjustCameraAnchor(by: 0)
                } label: {
                    Label("在播放头固定同步点", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            }

            Text("先在错位前固定当前，再到错位后调整；两点之间自动平滑重映射。")
                .font(.appUI(.caption2))
                .foregroundStyle(.secondary)
        }
    }

    func cameraSyncNudgeRow(
        stepTitle: String,
        onDelay: @escaping () -> Void,
        onAdvance: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onDelay) {
                Label(
                    String(format: appLocalized("画面延后 %@"), appLocalized(stepTitle)),
                    systemImage: "arrow.left"
                )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            Button(action: onAdvance) {
                Label(
                    String(format: appLocalized("画面提前 %@"), appLocalized(stepTitle)),
                    systemImage: "arrow.right"
                )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        }
        .buttonStyle(.editorQuiet)
    }

    var cameraSyncFrameDuration: TimeInterval {
        1 / max(cameraInventory.videoFrameRate ?? 25, 1)
    }

    var cameraSyncAnchors: [MediaSyncAnchor] {
        editorStore.project.media?.camera?.syncAnchors ?? []
    }

    var cameraAnchorSourceTime: TimeInterval? {
        mediaSession.mediaPlan?.timelineMap.sourceTime(atOutputTime: playbackTime)
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
        guard var media = project.media, var camera = media.camera else { return }
        camera.sourceStartTime = max(camera.sourceStartTime + delta, 0)
        media.camera = camera
        project.media = media
        commitCameraSyncProject(
            project,
            actionName: "校准摄像头音画同步",
            auditionAt: playbackTime
        )
    }

    func resetCameraSync() {
        var project = editorStore.project
        guard var media = project.media,
              var camera = media.camera else { return }
        camera.sourceStartTime = media.microphone?.sourceStartTime ?? 0
        media.camera = camera
        project.media = media
        commitCameraSyncProject(
            project,
            actionName: "归零摄像头音画同步",
            auditionAt: playbackTime
        )
    }

    func adjustCameraAnchor(by delta: TimeInterval) {
        guard let sourceTime = cameraAnchorSourceTime else { return }
        var project = editorStore.project
        guard var media = project.media, var camera = media.camera else { return }
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
        project.media = media
        commitCameraSyncProject(
            project,
            actionName: "调整摄像头分段同步",
            auditionAt: playbackTime
        )
    }

    func removeCameraAnchorAtPlayhead() {
        guard let sourceTime = cameraAnchorSourceTime else { return }
        var project = editorStore.project
        guard var media = project.media, var camera = media.camera,
              let index = camera.syncAnchors.indices.min(by: {
                  abs(camera.syncAnchors[$0].sourceTime - sourceTime)
                      < abs(camera.syncAnchors[$1].sourceTime - sourceTime)
              }), abs(camera.syncAnchors[index].sourceTime - sourceTime) <= cameraAnchorTolerance
        else { return }
        camera.syncAnchors.remove(at: index)
        media.camera = camera
        project.media = media
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
                    if sourceHasAudio {
                        audioVolumeRow(
                            "系统声音",
                            symbol: "speaker.wave.2.fill",
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
                            symbol: "mic.fill",
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
            } else if sourceHasAudio || microphoneHasAudio {
                EditorInspectorSection("全片音轨") {
                    if sourceHasAudio {
                        audioVolumeRow(
                            "系统声音",
                            symbol: "speaker.wave.2.fill",
                            detail: "录屏中的应用与系统声音",
                            value: audioBinding(\.systemVolume, actionName: "调整系统声音音量"),
                            isMuted: audioBinding(\.isSystemMuted, actionName: "切换系统声音"),
                            accessibilityStem: "editor.audio.system"
                        )
                    }
                    if microphoneHasAudio {
                        audioVolumeRow(
                            "麦克风",
                            symbol: "mic.fill",
                            detail: "独立录制的人声轨道",
                            value: audioBinding(\.microphoneVolume, actionName: "调整麦克风音量"),
                            isMuted: audioBinding(\.isMicrophoneMuted, actionName: "切换麦克风"),
                            accessibilityStem: "editor.audio.microphone"
                        )
                    }
                }
            }
            if selectedPrimarySegmentForAudio == nil,
               !sourceHasAudio && !microphoneHasAudio {
                EditorInspectorEmptyState(
                    title: "没有音频轨",
                    detail: "这个项目中没有可编辑的系统声音或麦克风素材。",
                    systemImage: "speaker.slash"
                )
            }
        }
    }

    private var selectedPrimarySegmentForAudio: UUID? {
        guard case let .primarySegment(id) = editorStore.selection else { return nil }
        return id
    }

    private func primarySegmentSystemVolumeBinding(segmentID: UUID) -> Binding<Double> {
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

    private func primarySegmentSystemMuteBinding(segmentID: UUID) -> Binding<Bool> {
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

    private func primarySegmentMicrophoneVolumeBinding(
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

    private func primarySegmentMicrophoneMuteBinding(
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
        symbol: String,
        detail: String,
        value: Binding<Double>,
        isMuted: Binding<Bool>,
        commandScope: EditorInteractionCommandScope = .audio,
        accessibilityStem: String
    ) -> some View {
        let isEnabled = Binding(
            get: { !isMuted.wrappedValue },
            set: { isMuted.wrappedValue = !$0 }
        )
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                        .fill(EditorTheme.chrome(isEnabled.wrappedValue ? 0.075 : 0.035))
                    Image(systemName: symbol)
                        .font(.appUI(size: 14, weight: .semibold))
                        .foregroundStyle(
                            isEnabled.wrappedValue
                                ? EditorTheme.platinumAccent
                                : Color.secondary
                        )
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appLocalized(title))
                        .font(.appUI(.caption, weight: .semibold))
                    Text(appLocalized(detail))
                        .font(.appUI(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                Spacer()
                EditorToggle(isOn: isEnabled)
                    .accessibilityLabel(String(format: appLocalized("%@启用"), appLocalized(title)))
                    .accessibilityValue(
                        appLocalized(isEnabled.wrappedValue ? "开关状态 · 开启" : "开关状态 · 关闭")
                    )
                    .accessibilityIdentifier(
                        "\(accessibilityStem).enabled"
                    )
            }
            EditorTransactionalSliderRow(
                editorStore: editorStore, title: "音量", value: value, range: 0...1,
                commandScope: commandScope, format: .percent,
                accessibilityTitle: "\(title)音量", onError: onError
            )
            .disabled(isMuted.wrappedValue)
            .opacity(isMuted.wrappedValue ? 0.45 : 1)
        }
        .padding(12)
        .background(
            EditorTheme.chrome(isEnabled.wrappedValue ? 0.028 : 0.015),
            in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                .stroke(
                    EditorTheme.chrome(isEnabled.wrappedValue ? 0.085 : 0.055),
                    lineWidth: 0.75
                )
        }
        .animation(SpringMotion.fluid, value: isEnabled.wrappedValue)
        .accessibilityElement(children: .contain)
    }

    func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        interactionScope: EditorInteractionCommandScope? = nil,
        format: EditorSliderValueFormat = .decimal2,
        compact: Bool = false
    ) -> some View {
        let commandScope = interactionScope ?? inferredContinuousCommandScope
        return EditorTransactionalSliderRow(
            editorStore: editorStore,
            title: title,
            value: value,
            range: range,
            commandScope: commandScope,
            format: format,
            compact: compact,
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
                                color: isSelected ? EditorTheme.selectionTint : Color.secondary
                            )
                            Text(appLocalized(shortName(for: style)))
                                .font(.appUI(size: 11, weight: isSelected ? .medium : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(
                            isSelected ? Color.primary : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                                .fill(
                                    isSelected
                                        ? EditorTheme.cardElevated
                                        : EditorTheme.chrome(hoveredStyle == style ? 0.045 : 0)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? EditorTheme.chrome(0.12)
                                        : EditorTheme.chrome(hoveredStyle == style ? 0.10 : 0),
                                    lineWidth: 0.75
                                )
                        )
                    }
                    .buttonStyle(.editorThumbnail)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                    .onHover { isHovering in
                        hoveredStyle = isHovering ? style : (hoveredStyle == style ? nil : hoveredStyle)
                    }
                    .help(appLocalized(style.displayName))
                    .accessibilityLabel("\(appLocalized("点击动画"))：\(appLocalized(style.displayName))")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(
                EditorTheme.groupSurface,
                in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                    .strokeBorder(EditorTheme.hairline, lineWidth: 0.75)
            }
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
            Image(systemName: "sparkles")
                .font(.appUI(size: 15, weight: .medium))
                .foregroundStyle(color)
                .rotationEffect(.degrees(-8 + wave * 16))
                .scaleEffect(0.84 + wave * 0.24)
                .shadow(color: color.opacity(0.44), radius: 1.5 + wave * 2)

        case .none:
            Image(systemName: "slash.circle")
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
        ("极光紫", HexColor(rgb24: 0x7C_5C_FC)),
        ("天际蓝", HexColor(rgb24: 0x38_BD_F8)),
        ("薄荷绿", HexColor(rgb24: 0x10_B9_81)),
        ("日落橙", HexColor(rgb24: 0xF9_73_16)),
        ("炫目粉", HexColor(rgb24: 0xEC_48_99)),
        ("冰川白", HexColor(rgb24: 0xFF_FF_FF)),
    ]

    @State private var showsCustomColor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("颜色").font(.appUI(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { onSelect(nil) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.appUI(size: 11))
                        .frame(width: 25, height: 28)
                }
                .buttonStyle(.editorToolbarPress).help("恢复光标默认颜色")
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("点击颜色：跟随光标主题")
                ForEach(Self.presets, id: \.hex) { preset in
                    Button { onSelect(preset.hex) } label: {
                        RoundedRectangle(cornerRadius: 5).fill(Color(hex: preset.hex))
                            .frame(width: 18, height: 18).padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selectedColor == preset.hex ? EditorTheme.selectionTint : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 7, cornerStyle: .circular)).help(appLocalized(preset.name))
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel(String(format: appLocalized("预设颜色：%@"), appLocalized(preset.name)))
                    .accessibilityAddTraits(selectedColor == preset.hex ? .isSelected : [])
                }
                Button { showsCustomColor = true } label: {
                    Circle().fill(Color(hex: selectedColor ?? defaultColor)).frame(width: 20, height: 20)
                        .overlay(Image(systemName: "plus").font(.appUI(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.65)))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 14, cornerStyle: .circular)).accessibilityLabel("自定义点击颜色")
                .appButtonKeyboardFocus(in: Circle())
                .editorPopoverKeyboardEntry { showsCustomColor = true }
                .editorPopover(isPresented: $showsCustomColor, establishesKeyboardEntry: false) {
                    EditorTransactionalColorInput(editorStore: editorStore, title: "点击颜色",
                        value: customColorBinding, commandScope: .cursor,
                        actionName: "调整点击动画颜色", onError: onError, presentsPalette: true)
                }
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
                EditorTheme.chrome(0.018)
                EditorWorkspaceGrid()
                if cursorIsHidden {
                    Label("光标已始终隐藏", systemImage: "eye.slash")
                        .font(.appUI(.caption))
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
            .frame(height: 124)
            .overlay(alignment: .topLeading) {
                Text("效果预览").font(.appUI(size: 10)).foregroundStyle(.tertiary).padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if !cursorIsHidden {
                    Image(systemName: "arrow.clockwise").font(.appUI(size: 11)).foregroundStyle(.secondary).padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EditorTheme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(cursorIsHidden)
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 14))
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
