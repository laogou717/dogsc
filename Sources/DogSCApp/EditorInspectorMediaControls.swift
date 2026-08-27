import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorInspectorView {
    var cursorInspector: some View {
        let cursorIsHidden = editorStore.previewProject.cursorStyle.assetID == .hidden

        return VStack(alignment: .leading, spacing: 15) {
            EditorInspectorSection("光标外观与点击") {
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
                        )?.metrics.clickColor ?? HexColor(rgb24: 0x7C_5C_FC)

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
            }

            if !cursorIsHidden {
                EditorInspectorSection("光标移动手感") {
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
                }

                if editorStore.previewProject.motion.cursor == .smooth {
                    EditorDisclosure("高级平滑参数") {
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
                    if let image = asset.image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(5)
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
        .buttonStyle(.plain)
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
                ContentUnavailableView(
                    "没有摄像头轨",
                    systemImage: "video.slash",
                    description: Text("这个项目没有可编辑的摄像头素材。")
                )
            }
        }
    }

    var cameraInspectorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            MotionInspectorScopeHeader(
                title: "摄像头",
                detail: "设置摄像头出现时的位置、大小和形状。",
                addTitle: "在播放头添加摄像运动",
                onAdd: addCameraMotionAtPlayhead
            )

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isCameraSyncEditing.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cameraSyncIsUnmodified
                            ? "checkmark.circle.fill"
                            : "waveform.path.ecg")
                            .foregroundStyle(cameraSyncIsUnmodified ? Color.green : editorAccent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("音画同步")
                                .font(.caption.weight(.semibold))
                            Text(cameraSyncSummaryLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(isCameraSyncEditing ? "收起" : "校正…")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(editorAccent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("音画同步")
                .accessibilityValue(cameraSyncSummaryLabel)
                .accessibilityHint(isCameraSyncEditing ? "收起校正设置" : "展开校正设置")

                if isCameraSyncEditing {
                    cameraSyncCorrectionControls
                        .padding(.top, 10)
                }
            }
            .padding(11)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            EditorToggle(
                isOn: Binding(
                    get: { !editorStore.project.camera.isHidden },
                    set: { cameraBinding(\.isHidden, actionName: "切换摄像头显示").wrappedValue = !$0 }
                ),
                title: "显示摄像头"
            )

            if editorStore.project.camera.isHidden {
                Text("摄像头初始隐藏；仍可在播放头添加出现动画。开启后可调整布局和外观。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("可直接拖动摄像头；拖右下角圆点调整大小", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                EditorInspectorSection("布局预设") {
                    HStack(spacing: 8) {
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
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        if !savedLayoutPresets.isEmpty {
                            Menu("我的预设") {
                                ForEach(savedLayoutPresets, id: \.name) { preset in
                                    Button(preset.name) { applySavedLayoutPreset(preset) }
                                }
                                Divider()
                                ForEach(savedLayoutPresets, id: \.name) { preset in
                                    Button("删除“\(preset.name)”", role: .destructive) {
                                        deleteSavedLayoutPreset(preset)
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .font(.caption2)
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

                EditorInspectorSection("位置与形状") {
                    positionGrid

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

                EditorDisclosure("蒙版内取景") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("只调整原摄像素材在当前蒙版内显示的位置和大小，不移动蒙版本身。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        sliderRow(
                            "水平取景",
                            value: cameraBinding(
                                \.contentPosition.x,
                                actionName: "调整蒙版内水平取景"
                            ),
                            range: 0...1,
                            format: .percent
                        )
                        sliderRow(
                            "垂直取景",
                            value: cameraBinding(
                                \.contentPosition.y,
                                actionName: "调整蒙版内垂直取景"
                            ),
                            range: 0...1,
                            format: .percent
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

                EditorDisclosure("全片外观") {
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
        }
    }

    var positionGrid: some View {
        positionPickerGrid(
            selected: editorStore.project.camera.position,
            onSelect: { position in
                var camera = editorStore.project.camera
                camera.position = position
                performEditorCommand {
                    try editorStore.replaceCamera(with: camera, actionName: "快速对齐摄像头")
                }
            }
        )
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
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("全片偏移").font(.caption.weight(.semibold))
                Spacer()
                Text(cameraSyncOffsetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("画面延后 10ms") { adjustCameraSync(by: -0.010) }
                Button("画面提前 10ms") { adjustCameraSync(by: 0.010) }
            }
            .buttonStyle(.editorQuiet)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button("延后 1 帧") { adjustCameraSync(by: -cameraSyncFrameDuration) }
                Button("提前 1 帧") { adjustCameraSync(by: cameraSyncFrameDuration) }
                Button("归零") { resetCameraSync() }
            }
            .buttonStyle(.editorQuiet)
            .controlSize(.small)

            Text("声音先出来、嘴后动：点“画面提前”；调整同时作用于预览和导出。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider().overlay(dividerColor)

            HStack {
                Text("分段同步点").font(.caption.weight(.semibold))
                Spacer()
                Text("\(cameraSyncAnchors.count) 个 · \(cameraAnchorOffsetLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("固定当前") { adjustCameraAnchor(by: 0) }
                Button("此处延后 10ms") { adjustCameraAnchor(by: -0.010) }
                Button("此处提前 10ms") { adjustCameraAnchor(by: 0.010) }
            }
            .buttonStyle(.editorQuiet)
            .controlSize(.small)
            .disabled(cameraAnchorSourceTime == nil)

            if hasCameraAnchorAtPlayhead {
                Button("删除播放头同步点", role: .destructive) {
                    removeCameraAnchorAtPlayhead()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }

            Text("先在错位前固定当前，再到错位后调整；两点之间自动平滑重映射。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

    var cameraAnchorOffsetLabel: String {
        let milliseconds = Int((cameraAnchorOffset * 1_000).rounded())
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
        performEditorCommand {
            try editorStore.replaceProject(with: project, actionName: "校准摄像头音画同步")
        }
    }

    func resetCameraSync() {
        var project = editorStore.project
        guard var media = project.media,
              var camera = media.camera else { return }
        camera.sourceStartTime = media.microphone?.sourceStartTime ?? 0
        media.camera = camera
        project.media = media
        performEditorCommand {
            try editorStore.replaceProject(with: project, actionName: "归零摄像头音画同步")
        }
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
        performEditorCommand {
            try editorStore.replaceProject(with: project, actionName: "调整摄像头分段同步")
        }
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
        performEditorCommand {
            try editorStore.replaceProject(with: project, actionName: "删除摄像头同步点")
        }
    }

    func positionPickerGrid(
        selected: NormalizedPoint,
        onSelect: @escaping (NormalizedPoint) -> Void
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 7), count: 3), spacing: 7) {
            ForEach(0..<9, id: \.self) { index in
                // The normalized position is already resolved against the
                // remaining canvas after subtracting the camera size. Using
                // 0.12/0.88 here therefore created an unintended second safe
                // area and made every edge preset feel visibly inset.
                let x = [0.03, 0.5, 0.97][index % 3]
                let y = [0.03, 0.5, 0.97][index / 3]
                Button {
                    onSelect(NormalizedPoint(x: x, y: y))
                } label: {
                    Circle()
                        .fill(isNearPosition(selected, x: x, y: y) ? editorAccent : Color.white.opacity(0.2))
                        .frame(width: 10, height: 10)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isNearPosition(selected, x: x, y: y)
                                        ? editorAccent.opacity(0.7) : Color.white.opacity(0.06),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(positionName(for: index))
                .accessibilityValue(
                    isNearPosition(selected, x: x, y: y) ? "已选择" : "未选择"
                )
            }
        }
    }

    var audioInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sourceHasAudio {
                audioVolumeRow(
                    "系统声音",
                    value: audioBinding(\.systemVolume, actionName: "调整系统声音音量"),
                    isMuted: audioBinding(\.isSystemMuted, actionName: "切换系统声音")
                )
            }
            if microphoneHasAudio {
                audioVolumeRow(
                    "麦克风",
                    value: audioBinding(\.microphoneVolume, actionName: "调整麦克风音量"),
                    isMuted: audioBinding(\.isMicrophoneMuted, actionName: "切换麦克风")
                )
            }
            if !sourceHasAudio && !microphoneHasAudio {
                ContentUnavailableView(
                    "没有音频轨",
                    systemImage: "speaker.slash",
                    description: Text("这个项目中没有可编辑的系统声音或麦克风素材。")
                )
            }
        }
    }

    func audioVolumeRow(
        _ title: String,
        value: Binding<Double>,
        isMuted: Binding<Bool>
    ) -> some View {
        let isEnabled = Binding(
            get: { !isMuted.wrappedValue },
            set: { isMuted.wrappedValue = !$0 }
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer()
                Text("启用")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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
            HStack {
                EditorTransactionalSlider(
                    editorStore: editorStore,
                    value: value,
                    range: 0...1,
                    commandScope: .audio,
                    actionName: "调整\(title)音量",
                    onError: onError
                )
                    .disabled(isMuted.wrappedValue)
                    .accessibilityLabel("\(title)音量")
                    .accessibilityValue(
                        "\(Int((value.wrappedValue * 100).rounded()))%"
                    )
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .opacity(isMuted.wrappedValue ? 0.45 : 1)
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
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
        case .frame: return .canvas
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

    private func icon(for style: CursorClickEffectStyle) -> String {
        switch style {
        case .ripple: return "dot.radiowaves.left.and.right"
        case .glow: return "sun.max.fill"
        case .pulse: return "waveform"
        case .burst: return "sparkles"
        case .none: return "slash.circle"
        }
    }

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
                Text("点击动画")
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
                    Button {
                        onSelect(style)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: icon(for: style))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            Text(shortName(for: style))
                                .font(.system(size: 9))
                                .lineLimit(1)
                        }
                        .foregroundStyle(
                            isSelected ? Color.primary : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? Color.white.opacity(0.75) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(style.displayName)
                    .accessibilityLabel("点击动画：\(style.displayName)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .accessibilityElement(children: .contain)
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
                    .frame(height: 26)
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
                .buttonStyle(.plain)
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
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
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
