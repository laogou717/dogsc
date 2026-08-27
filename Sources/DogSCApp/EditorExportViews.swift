import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorExportEstimate: Equatable, Sendable {
    let outputDuration: TimeInterval
    let byteCount: Int64

    static func make(
        mediaPlan: ProjectTimelineMediaPlan,
        sourceDisplaySize: CGSize,
        project: RecorderProject
    ) -> EditorExportEstimate? {
        guard sourceDisplaySize.width.isFinite,
              sourceDisplaySize.height.isFinite,
              sourceDisplaySize.width > 0,
              sourceDisplaySize.height > 0,
              mediaPlan.outputDuration.isFinite,
              mediaPlan.outputDuration > 0 else { return nil }
        let sourceAspectRatio = Double(
            sourceDisplaySize.width / sourceDisplaySize.height
        )
        let crop = project.canvas.crop.clamped()
        let croppedSourceAspectRatio = sourceAspectRatio * crop.width / crop.height
        let settings = project.exportSettings
        let dimensions = project.canvas.pixelDimensions(
            resolution: settings.resolution,
            sourceAspectRatio: croppedSourceAspectRatio,
            sourcePixelSize: CanvasDimensions(
                width: max(Int(sourceDisplaySize.width.rounded()), 2),
                height: max(Int(sourceDisplaySize.height.rounded()), 2)
            )
        )
        let videoBitsPerSecond = ExportEncodingPolicy.videoBitrate(
            width: dimensions.width,
            height: dimensions.height,
            frameRate: settings.frameRate.rawValue
        )
        let requiredMedia = RequiredProjectMedia(project: project)
        let includesAudio = (
            requiredMedia.systemAudio && mediaPlan.systemAudio != nil
        ) || (
            requiredMedia.microphoneAudio && mediaPlan.microphone != nil
        )
        let totalBitsPerSecond = videoBitsPerSecond
            + (includesAudio ? ExportEncodingPolicy.audioBitrate : 0)
        let byteCount = Double(totalBitsPerSecond)
            * mediaPlan.outputDuration / 8
        guard byteCount.isFinite,
              byteCount >= 0,
              byteCount <= Double(Int64.max) else { return nil }
        return EditorExportEstimate(
            outputDuration: mediaPlan.outputDuration,
            byteCount: Int64(byteCount)
        )
    }
}

struct ExportSheet: View {
    let wallpaperURLResolver: EditorSessionContext.WallpaperURLResolver
    let projectAssetURLResolver: EditorSessionContext.ProjectAssetURLResolver
    let projectDisplayName: String
    @ObservedObject var exporter: VideoExporter
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @Environment(\.dismiss) private var dismiss
    @State private var requestErrorMessage: String?

    init(
        wallpaperURLResolver: @escaping EditorSessionContext.WallpaperURLResolver,
        projectAssetURLResolver: @escaping EditorSessionContext.ProjectAssetURLResolver,
        projectDisplayName: String,
        exporter: VideoExporter,
        editorStore: EditorStore,
        mediaSession: EditorMediaSession
    ) {
        self.wallpaperURLResolver = wallpaperURLResolver
        self.projectAssetURLResolver = projectAssetURLResolver
        self.projectDisplayName = projectDisplayName
        self.exporter = exporter
        self.editorStore = editorStore
        self.mediaSession = mediaSession
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导出").font(.title2.weight(.semibold))
                Spacer()
                if !exporter.isExporting {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help("关闭导出面板")
                    .accessibilityLabel("关闭导出面板")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(dividerColor)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("格式") {
                        Text("MP4")
                            .foregroundStyle(.secondary)
                            .frame(width: 160)
                    }
                    LabeledContent("帧率") {
                        Picker("", selection: frameRateBinding) {
                            ForEach(OutputFrameRate.exportProductChoices) { rate in
                                Text(rate.label).tag(rate)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .disabled(exporter.isExporting)
                    }
                    LabeledContent("分辨率") {
                        Picker("", selection: resolutionBinding) {
                            ForEach(CanvasResolution.allCases) { resolution in
                                Text(resolution.rawValue).tag(resolution)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .disabled(exporter.isExporting)
                    }
                    if let outputEstimate {
                        LabeledContent("建议预留") {
                            Text(
                                "约 \(ByteCountFormatter.string(fromByteCount: outputEstimate.byteCount, countStyle: .file))"
                            )
                                .foregroundStyle(.secondary)
                        }
                    }

                }
                .padding(.horizontal, 22)

                exportStatusRegion
                    .padding(.horizontal, 22)
            }
            .padding(.vertical, 20)

            Divider().overlay(dividerColor)

            VStack(spacing: 8) {
                if let disabledExportReason {
                    Text(disabledExportReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Button {
                    if exporter.isExporting {
                        exporter.cancelExport()
                    } else {
                        startExport()
                    }
                } label: {
                    Text(exporter.isExporting
                        ? "取消导出"
                        : "导出 MP4")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color.black.opacity(0.85))
                .tint(exporter.isExporting ? Color.orange : editorAccent)
                .disabled(!exporter.isExporting && mediaSession.prepared == nil)
            }
            .padding(18)
        }
        .frame(width: 440)
        .background(panelBackground)
        .interactiveDismissDisabled(exporter.isExporting)
    }

    @ViewBuilder
    private var exportStatusRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            if exporter.isExporting {
                ProgressView(value: exporter.exportProgress, total: 1) {
                    Text("正在渲染并编码…")
                } currentValueLabel: {
                    Text("\(Int((exporter.exportProgress * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                }
            } else if mediaSession.prepared == nil {
                HStack(alignment: .top, spacing: 8) {
                    if mediaSession.errorMessage == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(mediaSession.errorMessage ?? "正在准备与预览同一代的导出素材…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let url = exporter.lastExportURL {
                Label("导出完成", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.weight(.semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("导出状态")
                    .accessibilityValue("导出完成")
                Button("在 Finder 中显示导出文件") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            } else {
                Label("已就绪，导出时再选择保存位置", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("导出状态")
                    .accessibilityValue("已就绪，导出时再选择保存位置")
            }

            if let message = exporter.errorMessage ?? requestErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var disabledExportReason: String? {
        guard !exporter.isExporting, mediaSession.prepared == nil else { return nil }
        return mediaSession.errorMessage == nil
            ? "预览素材准备完成后即可导出"
            : "请先解决上方的素材错误"
    }

    private var outputEstimate: EditorExportEstimate? {
        return mediaSession.prepared.flatMap {
            EditorExportEstimate.make(
                mediaPlan: $0.plan,
                sourceDisplaySize: $0.sourceDisplaySize,
                project: editorStore.project
            )
        }
    }

    private var frameRateBinding: Binding<OutputFrameRate> {
        Binding(
            get: { editorStore.project.exportSettings.frameRate },
            set: { frameRate in
                updateExportSettings(actionName: "调整导出帧率") {
                    $0.frameRate = frameRate
                }
            }
        )
    }

    private var resolutionBinding: Binding<CanvasResolution> {
        Binding(
            get: { editorStore.project.exportSettings.resolution },
            set: { resolution in
                updateExportSettings(actionName: "调整导出分辨率") {
                    $0.resolution = resolution
                }
            }
        )
    }

    private func updateExportSettings(
        actionName: String,
        _ update: (inout ExportSettings) -> Void
    ) {
        var settings = editorStore.project.exportSettings
        update(&settings)
        do {
            try editorStore.replaceExportSettings(
                with: settings,
                actionName: actionName
            )
            requestErrorMessage = nil
        } catch {
            requestErrorMessage = error.localizedDescription
        }
    }

    private func startExport() {
        requestErrorMessage = nil
        _ = editorStore.prepareForExternalAction(.export)
        guard let preparedMedia = mediaSession.prepared else {
            requestErrorMessage = mediaSession.errorMessage ?? "导出素材尚未准备完成。"
            return
        }
        do {
            let project = editorStore.project
            guard let outputURL = chooseExportURL(for: project) else { return }
            let request = try EditorExportRequestBuilder.make(
                editorSessionID: editorStore.sessionID,
                mediaGeneration: preparedMedia.generation,
                project: project,
                preparedMedia: preparedMedia,
                wallpaperURL: wallpaperURLResolver(project.canvas.backgroundSource),
                stickerURLs: Dictionary(
                    uniqueKeysWithValues: Set(
                        project.timeline.stickerClips.map(\.relativePath)
                    ).compactMap { relativePath in
                        projectAssetURLResolver(relativePath).map {
                            (relativePath, $0)
                        }
                    }
                ),
                outputURL: outputURL
            )
            exporter.export(request: request)
        } catch {
            requestErrorMessage = error.localizedDescription
        }
    }

    private func chooseExportURL(for project: RecorderProject) -> URL? {
        let suggested = try? EditorExportRequestBuilder.makeDefaultOutputURL(
            for: project,
            preferredProjectName: projectDisplayName
        )
        let panel = NSSavePanel()
        panel.title = "选择成片导出位置"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.isExtensionHidden = false
        panel.directoryURL = AppPreferences.exportDirectoryURL
        panel.nameFieldStringValue = suggested?.lastPathComponent
            ?? "\(projectDisplayName)-\(project.exportSettings.frameRate.rawValue)fps.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        AppPreferences.rememberExportDirectory(url.deletingLastPathComponent())
        return url
    }
}
