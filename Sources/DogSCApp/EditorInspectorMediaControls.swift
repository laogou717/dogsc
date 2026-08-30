import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorInspectorView {
    var cursorInspector: some View {
        let cursorIsHidden = editorStore.previewProject.cursorStyle.assetID == .hidden

        return VStack(alignment: .leading, spacing: 15) {
            EditorInspectorSection("光标样式") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(cursorAssets) { asset in
                        cursorAssetButton(asset)
                    }
                }

                if cursorIsHidden {
                    Text("当前已隐藏光标。选择一种光标样式后，才需要调整大小、点击动画和移动手感。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    sliderRow(
                        "光标大小",
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
                            "动画不透明度",
                            value: cursorBinding(\.clickOpacity, actionName: "调整点击不透明度"),
                            range: 0.1...1.0,
                            format: .percent
                        )

                        sliderRow(
                            "动画大小",
                            value: cursorBinding(\.clickScale, actionName: "调整点击动画大小"),
                            range: 0.5...2.0,
                            format: .multiplier
                        )
                    }
                }

                EditorInspectorSection("移动手感") {
                    EditorSegmentedControl(
                        options: CursorMotionStyle.allCases,
                        title: { style in
                            style == .none ? "线性" : style.rawValue
                        },
                        selection: motionBinding(\.cursor, actionName: "调整光标动画")
                    )

                    if editorStore.previewProject.motion.cursor != .none {
                        sliderRow(
                            "摆动强度",
                            value: cursorBinding(
                                \.motionTiltStrength,
                                actionName: "调整光标摆动强度"
                            ),
                            range: 0...2,
                            format: .percent
                        )
                    }

                    if editorStore.previewProject.motion.cursor == .smooth {
                        EditorDisclosure(
                            "高级平滑参数",
                            detail: "质量 \(EditorSliderValueFormat.decimal1.text(for: editorStore.previewProject.motion.cursorSpringMass)) · 刚度 \(EditorSliderValueFormat.points.text(for: editorStore.previewProject.motion.cursorSpringStiffness)) · 阻尼 \(EditorSliderValueFormat.points.text(for: editorStore.previewProject.motion.cursorSpringDamping))"
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

    func cursorAssetButton(_ asset: ResolvedCursorAsset) -> some View {
        let isSelected = editorStore.previewProject.cursorStyle.assetID == asset.id
        return Button {
            var style = editorStore.project.cursorStyle
            style.assetID = asset.id
            performEditorCommand {
                try editorStore.replaceCursor(with: style, actionName: "调整光标样式")
            }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if asset.id == .automatic {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let image = asset.image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(6.5)
                    } else {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))

                Text(asset.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                isSelected ? editorAccent.opacity(0.22) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? editorAccent.opacity(0.95) : Color.white.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.editorThumbnail)
        .accessibilityLabel("光标样式，\(asset.displayName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            EditorToggle(
                isOn: Binding(
                    get: { !editorStore.previewProject.camera.isHidden },
                    set: { cameraBinding(\.isHidden, actionName: "切换摄像头显示").wrappedValue = !$0 }
                ),
                title: "显示摄像头"
            )

            if editorStore.previewProject.camera.isHidden {
                Text("摄像头初始隐藏；仍可在播放头添加出现动画。开启后可调整布局和外观。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    addCameraMotionAtPlayhead()
                } label: {
                    Label("在播放头添加出现动画", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorPrimary(minHeight: 32))
            } else {
                EditorInspectorSection("位置与形状") {
                    Label(
                        "直接在画布中拖动，拖右下角调整大小",
                        systemImage: "hand.draw"
                    )
                    .font(.caption2)
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

                cameraLayoutAnimationSection

                EditorDisclosure(
                    "蒙版内取景",
                    detail: "\(EditorSliderValueFormat.multiplier.text(for: editorStore.previewProject.camera.contentScale)) · \(Int((editorStore.previewProject.camera.contentPosition.x * 100).rounded())), \(Int((editorStore.previewProject.camera.contentPosition.y * 100).rounded()))"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("只调整原摄像素材在当前蒙版内显示的位置和大小，不移动蒙版本身。")
                            .font(.caption2)
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
                        }
                    }
                }

                EditorDisclosure(
                    "全片外观",
                    detail: "\(editorStore.previewProject.camera.isMirrored ? "镜像" : "正常") · 描边 \(EditorSliderValueFormat.points.text(for: editorStore.previewProject.camera.borderWidth)) · 阴影 \(EditorSliderValueFormat.percent.text(for: editorStore.previewProject.camera.shadowStrength))"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        EditorToggle(
                            isOn: cameraBinding(\.isMirrored, actionName: "切换摄像头镜像"),
                            title: "镜像摄像头"
                        )
                        sliderRow(
                            "缩放时大小",
                            value: cameraBinding(\.scaleDuringZoom, actionName: "调整摄像头缩放跟随"),
                            range: 0.35...1.25,
                            format: .multiplier
                        )
                        sliderRow(
                            "描边",
                            value: cameraBinding(\.borderWidth, actionName: "调整摄像头描边"),
                            range: 0...18,
                            format: .points
                        )
                        sliderRow(
                            "阴影",
                            value: cameraBinding(\.shadowStrength, actionName: "调整摄像头阴影"),
                            range: 0...1,
                            format: .percent
                        )
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
                expanded: $isCameraSyncEditing
            ) {
                cameraSyncCorrectionControls
                    .padding(.top, 6)
            }
            .accessibilityHint(isCameraSyncEditing ? "收起校正设置" : "展开校正设置")
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
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    layoutPresetName = ""
                    isNamingLayoutPreset = true
                } label: {
                    Label("保存当前为预设", systemImage: "square.and.arrow.down")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                .foregroundStyle(.secondary)

                if !savedLayoutPresets.isEmpty {
                    Menu {
                        ForEach(savedLayoutPresets, id: \.name) { preset in
                            Button(preset.name) { applySavedLayoutPreset(preset) }
                        }
                        Divider()
                        ForEach(savedLayoutPresets, id: \.name) { preset in
                            Button("删除“\(preset.name)”", role: .destructive) {
                                deleteSavedLayoutPreset(preset)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up")
                            Text("我的预设")
                            Spacer(minLength: 2)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(
                            Color.primary.opacity(
                                savedLayoutPresetMenuHovered ? 1 : 0.88
                            )
                        )
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            Color.white.opacity(
                                savedLayoutPresetMenuHovered ? 0.085 : 0.045
                            ),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    Color.white.opacity(
                                        savedLayoutPresetMenuHovered ? 0.15 : 0.08
                                    ),
                                    lineWidth: 0.75
                                )
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
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
            .alert("保存布局预设", isPresented: $isNamingLayoutPreset) {
                TextField("预设名称", text: $layoutPresetName)
                Button("保存") { saveCurrentLayoutAsPreset() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("记录当前的摄像头位置/大小/形状与录屏画面构图，之后在播放头一键复用。")
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
        if cameraSyncIsUnmodified { return "同步正常" }
        if cameraSyncAnchors.isEmpty { return "已应用 \(cameraSyncOffsetLabel)" }
        return "已应用 \(cameraSyncOffsetLabel) · \(cameraSyncAnchors.count) 个分段点"
    }

    var cameraSyncCorrectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("全片偏移").font(.caption.weight(.semibold))
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
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider().overlay(dividerColor)

            HStack(spacing: 8) {
                Text("分段同步点").font(.caption.weight(.semibold))
                Spacer()
                Text("\(cameraSyncAnchors.count) 个 · 当前 \(cameraAnchorTotalOffsetLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if cameraAnchorSourceTime == nil {
                Label("当前播放头无法映射到源素材", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
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
            } else {
                Button {
                    adjustCameraAnchor(by: 0)
                } label: {
                    Label("在播放头固定同步点", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
            }

            Text("先在错位前固定当前，再到错位后调整；两点之间自动平滑重映射。")
                .font(.caption2)
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
                Label("画面延后 \(stepTitle)", systemImage: "arrow.left")
                    .frame(maxWidth: .infinity)
            }
            Button(action: onAdvance) {
                Label("画面提前 \(stepTitle)", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
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
        VStack(alignment: .leading, spacing: 14) {
            if sourceHasAudio {
                audioVolumeRow(
                    "系统声音",
                    symbol: "speaker.wave.2.fill",
                    detail: "录屏中的应用与系统声音",
                    value: audioBinding(\.systemVolume, actionName: "调整系统声音音量"),
                    isMuted: audioBinding(\.isSystemMuted, actionName: "切换系统声音")
                )
            }
            if microphoneHasAudio {
                audioVolumeRow(
                    "麦克风",
                    symbol: "mic.fill",
                    detail: "独立录制的人声轨道",
                    value: audioBinding(\.microphoneVolume, actionName: "调整麦克风音量"),
                    isMuted: audioBinding(\.isMicrophoneMuted, actionName: "切换麦克风")
                )
            }
            if !sourceHasAudio && !microphoneHasAudio {
                EditorInspectorEmptyState(
                    title: "没有音频轨",
                    detail: "这个项目中没有可编辑的系统声音或麦克风素材。",
                    systemImage: "speaker.slash"
                )
            }
        }
    }

    func audioVolumeRow(
        _ title: String,
        symbol: String,
        detail: String,
        value: Binding<Double>,
        isMuted: Binding<Bool>
    ) -> some View {
        let isEnabled = Binding(
            get: { !isMuted.wrappedValue },
            set: { isMuted.wrappedValue = !$0 }
        )
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isEnabled.wrappedValue ? 0.13 : 0.055),
                                    Color.white.opacity(isEnabled.wrappedValue ? 0.065 : 0.025)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            isEnabled.wrappedValue
                                ? EditorTheme.platinumAccent
                                : Color.secondary
                        )
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityHidden(true)
                Spacer()
                EditorToggle(isOn: isEnabled)
                    .accessibilityLabel("\(title)启用")
                    .accessibilityValue(
                        isEnabled.wrappedValue ? "开启" : "关闭"
                    )
                    .accessibilityIdentifier(
                        title == "系统声音"
                            ? "editor.audio.system.enabled"
                            : "editor.audio.microphone.enabled"
                    )
            }
            HStack(spacing: 10) {
                EditorTransactionalSlider(
                    editorStore: editorStore,
                    value: value,
                    range: 0...1,
                    commandScope: .audio,
                    actionName: "调整\(title)音量",
                    formatValue: { "\(Int(($0 * 100).rounded()))%" },
                    showsFloatingValue: false,
                    onError: onError
                )
                    .disabled(isMuted.wrappedValue)
                    .accessibilityLabel("\(title)音量")
                    .accessibilityValue(
                        "\(Int((value.wrappedValue * 100).rounded()))%"
                    )
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(
                        isEnabled.wrappedValue
                            ? Color.primary.opacity(0.86)
                            : Color.secondary
                    )
                    .padding(.horizontal, 7)
                    .frame(minWidth: 42, minHeight: 22)
                    .background(
                        Color.black.opacity(0.22),
                        in: Capsule(style: .continuous)
                    )
                    .accessibilityHidden(true)
            }
            .opacity(isMuted.wrappedValue ? 0.45 : 1)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(isEnabled.wrappedValue ? 0.065 : 0.035),
                    Color.white.opacity(0.024)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(
                    isEnabled.wrappedValue
                        ? EditorTheme.platinumAccent.opacity(0.72)
                        : Color.white.opacity(0.08)
                )
                .frame(width: 2.5, height: 38)
                .padding(.leading, 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.white.opacity(isEnabled.wrappedValue ? 0.10 : 0.055),
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
        format: EditorSliderValueFormat = .decimal2
    ) -> some View {
        let commandScope = interactionScope ?? inferredContinuousCommandScope
        return EditorTransactionalSliderRow(
            editorStore: editorStore,
            title: title,
            value: value,
            range: range,
            commandScope: commandScope,
            format: format,
            onError: onError
        )
    }

    var inferredContinuousCommandScope: EditorInteractionCommandScope {
        switch selectedInspector {
        case .frame, .mockup: return .canvas
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
            HStack {
                Text("动画样式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selection.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            // Every option below already carries the complete
            // "点击动画：…" name and selected state. Keep this compact
            // visual summary out of the reading order to avoid hearing the
            // current style twice before reaching the actual controls.
            .accessibilityHidden(true)
            HStack(spacing: 5) {
                ForEach(CursorClickEffectStyle.allCases, id: \.self) { style in
                    let isSelected = selection == style
                    let isPreviewing = isSelected || hoveredStyle == style
                    Button {
                        onSelect(style)
                    } label: {
                        VStack(spacing: 4) {
                            CursorClickEffectPreviewGlyph(
                                style: style,
                                isActive: isPreviewing,
                                color: isSelected ? EditorTheme.amberAccent : Color.secondary
                            )
                            Text(shortName(for: style))
                                .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(
                            isSelected ? Color.primary : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    isSelected
                                        ? EditorTheme.amberAccent.opacity(0.13)
                                        : Color.white.opacity(hoveredStyle == style ? 0.095 : 0.055)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? EditorTheme.amberAccent.opacity(0.72)
                                        : Color.white.opacity(hoveredStyle == style ? 0.16 : 0.06),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.editorThumbnail)
                    .onHover { isHovering in
                        hoveredStyle = isHovering ? style : (hoveredStyle == style ? nil : hoveredStyle)
                    }
                    .help(style.displayName)
                    .accessibilityLabel("点击动画：\(style.displayName)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The picker should explain motion before it changes the project. Only the
/// selected or hovered glyph advances; the other four remain still, so the
/// inspector stays inexpensive while its choices remain visually legible.
private struct CursorClickEffectPreviewGlyph: View {
    let style: CursorClickEffectStyle
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        TimelineView(.animation(paused: !isActive || reducesMotion)) { timeline in
            let rawPhase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.15) / 1.15
            let phase = isActive && !reducesMotion ? rawPhase : 0.34
            glyph(phase: phase)
        }
        .frame(width: 28, height: 20)
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .rotationEffect(.degrees(-8 + wave * 16))
                .scaleEffect(0.84 + wave * 0.24)
                .shadow(color: color.opacity(0.44), radius: 1.5 + wave * 2)

        case .none:
            Image(systemName: "slash.circle")
                .font(.system(size: 15, weight: .medium))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("点击颜色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedColor == nil {
                    Text("跟随光标主题")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // The default, preset and custom controls below all include
            // "点击颜色" in their own names. This header remains a visual
            // summary rather than an extra non-actionable stop.
            .accessibilityHidden(true)

            HStack(spacing: 7) {
                Button {
                    onSelect(nil)
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color(hex: defaultColor))
                            .frame(width: 8, height: 8)
                        Text("默认")
                            .font(.system(size: 10))
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selectedColor == nil ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(selectedColor == nil ? Color.white.opacity(0.75) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.editorThumbnail)
                .help("跟随光标主题色彩")
                .accessibilityLabel("点击颜色：跟随光标主题")
                .accessibilityAddTraits(selectedColor == nil ? .isSelected : [])

                ForEach(Self.presets, id: \.hex) { preset in
                    let isSelected = selectedColor == preset.hex
                    Button {
                        onSelect(preset.hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.hex))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(isSelected ? Color.white : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                            )
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.editorSwatch)
                    .help(preset.name)
                    .accessibilityLabel("预设颜色：\(preset.name)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                Spacer(minLength: 0)
            }

            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: "自定义颜色",
                value: customColorBinding,
                commandScope: .cursor,
                actionName: "调整点击动画颜色",
                onError: onError
            )
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
