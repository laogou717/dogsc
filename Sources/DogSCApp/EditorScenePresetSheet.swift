import AppKit
import RecorderCore
import SwiftUI

struct EditorScenePresetSheet: View {
    @Binding var name: String
    let project: RecorderProject
    let sourceSize: CGSize
    let isUpdating: Bool
    let isSaving: Bool
    let error: String?
    let nameConflict: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appLocalized(isUpdating ? "更新场景预设" : "保存场景预设"))
                    .font(.appUI(.title2, weight: .semibold))
                Text("把这套配置留给下一次录制。")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("预设名称").font(.appUI(.callout, weight: .medium))
                TextField("例如：全屏上下裁切", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .disabled(isSaving)
                if nameConflict {
                    Text("这个名称已存在，请换一个名称；更新已有预设请使用“更新此预设”。")
                        .font(.appUI(.caption))
                        .foregroundStyle(EditorTheme.recording)
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                configurationRow("rectangle.inset.filled", "画布与屏幕", "比例、大小、位置、裁切、样机、描边与阴影")
                HStack {
                    Text("裁切").foregroundStyle(.secondary)
                    Spacer()
                    Text(sceneCropSummary(project.canvas.crop, size: sourceSize))
                        .monospacedDigit()
                }
                .font(.appUI(.caption))
                configurationRow("person.crop.rectangle", "摄像头", "显隐、布局、形状、外观与蒙版取景")
                configurationRow("cursorarrow.motionlines", "光标与运镜", "光标效果、开场、运动模糊与新动画默认值")
                configurationRow("speaker.wave.2", "声音与背景", "全片音量、静音和背景资源副本")
            }
            .padding(16)
            .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
            Text("保留当前项目的素材、剪辑、分段声音和时间线动画。新录制默认场景可在预设菜单中单独选择。")
                .font(.appUI(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.appUI(.caption)).foregroundStyle(EditorTheme.recording)
            }
            HStack(spacing: 10) {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("正在保存背景与配置…").font(.appUI(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.editorQuiet)
                    .disabled(isSaving)
                Button(appLocalized(isUpdating ? "更新预设" : "保存预设"), action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.editorPrimary)
                    .disabled(isSaving || nameConflict || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(EditorTheme.panelSurface)
        .interactiveDismissDisabled(isSaving)
        .onAppear { nameFocused = true }
    }

    private func configurationRow(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.appUI(.callout, weight: .medium))
                Text(detail).font(.appUI(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

struct EditorScenePresetPreview: View {
    let preset: EditorStylePreset
    @ObservedObject var mediaSession: EditorMediaSession
    let outputTime: TimeInterval
    let sourceSize: CGSize
    let onCancel: () -> Void
    let onApply: () -> Void
    @State private var thumbnail: NSImage?
    @State private var thumbnailFinished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("检查裁切适配").font(.appUI(.title2, weight: .semibold))
                Text(preset.name).font(.appUI(.callout)).foregroundStyle(.secondary)
            }
            if let source = preset.sourceDimensions {
                Text("\(source.width) × \(source.height) → \(Int(sourceSize.width)) × \(Int(sourceSize.height))")
                    .font(.callout.monospacedDigit())
            }
            Text("录制尺寸不同，裁切将按比例适配。亮框内的画面会保留。")
                .font(.appUI(.callout)).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let crop = preset.canvas.crop.clamped()
                let rect = CGRect(x: crop.x * proxy.size.width, y: crop.y * proxy.size.height,
                                  width: crop.width * proxy.size.width, height: crop.height * proxy.size.height)
                ZStack {
                    Color.black
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: proxy.size))
                            path.addRect(rect)
                        }
                        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                        Rectangle().strokeBorder(.white, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    } else if thumbnailFinished {
                        Text("预览暂不可用，可取消后稍后重试。")
                            .font(.appUI(.caption)).foregroundStyle(.white)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            }
            .frame(width: min(452, 260 * max(sourceSize.width, 1) / max(sourceSize.height, 1)),
                   height: min(260, 452 * max(sourceSize.height, 1) / max(sourceSize.width, 1)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity)
            .accessibilityLabel("裁切适配预览")
            .accessibilityValue(sceneCropSummary(preset.canvas.crop, size: sourceSize))
            Text(sceneCropSummary(preset.canvas.crop, size: sourceSize))
                .font(.callout.monospacedDigit())
            Text("应用后可一次撤销，素材与时间线片段保持原样。")
                .font(.appUI(.caption)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction).buttonStyle(.editorQuiet)
                Button("应用预设", action: onApply).keyboardShortcut(.defaultAction).buttonStyle(.editorPrimary)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(EditorTheme.panelSurface)
        .task {
            if let image = await mediaSession.thumbnail(atOutputTime: outputTime) {
                thumbnail = NSImage(cgImage: image, size: .zero)
            }
            thumbnailFinished = true
        }
    }
}

private func sceneCropSummary(_ value: NormalizedCrop, size: CGSize) -> String {
    let crop = value.clamped()
    if crop == .full { return appLocalized("完整画面") }
    return "\(appLocalized("上")) \(Int((crop.top * size.height).rounded())) · "
        + "\(appLocalized("下")) \(Int((crop.bottom * size.height).rounded())) · "
        + "\(appLocalized("左")) \(Int((crop.left * size.width).rounded())) · "
        + "\(appLocalized("右")) \(Int((crop.right * size.width).rounded())) px"
}
