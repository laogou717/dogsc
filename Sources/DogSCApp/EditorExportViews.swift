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
        project: RecorderProject,
        outputKind: ExportOutputKind,
        includesAudio: Bool,
        outputRange: MediaTimeRange? = nil
    ) -> EditorExportEstimate? {
        let outputDuration = outputRange?.duration ?? mediaPlan.outputDuration
        guard outputDuration.isFinite,
              outputDuration > 0 else { return nil }
        let totalBitsPerSecond: Int
        switch outputKind {
        case .audio:
            guard includesAudio else { return nil }
            totalBitsPerSecond = ExportEncodingPolicy.audioBitrate
        case .video:
            guard sourceDisplaySize.width.isFinite,
                  sourceDisplaySize.height.isFinite,
                  sourceDisplaySize.width > 0,
                  sourceDisplaySize.height > 0 else { return nil }
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
            totalBitsPerSecond = ExportEncodingPolicy.videoBitrate(
                width: dimensions.width,
                height: dimensions.height,
                frameRate: settings.frameRate.rawValue
            ) + (includesAudio ? ExportEncodingPolicy.audioBitrate : 0)
        }
        let byteCount = Double(totalBitsPerSecond)
            * outputDuration / 8
        guard byteCount.isFinite,
              byteCount >= 0,
              byteCount <= Double(Int64.max) else { return nil }
        return EditorExportEstimate(
            outputDuration: outputDuration,
            byteCount: Int64(byteCount)
        )
    }
}

/// Compact options share the editor's raised selected surface.
private struct ExportChoiceTile: View {
    let title: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(appLocalized(title)).font(.appUI(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1).minimumScaleFactor(0.9)
                if isSelected {
                    Image(systemName: "checkmark").font(.appUI(size: 9, weight: .medium))
                        .foregroundStyle(EditorTheme.selectionTint)
                }
            }
            .foregroundStyle(EditorTheme.chrome(isSelected ? 0.88 : 0.6))
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(isSelected ? EditorTheme.cardElevated : EditorTheme.chrome(0.035),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(EditorTheme.chrome(isSelected ? 0.075 : 0.025), lineWidth: 0.75))
            .shadow(color: EditorTheme.softShadow.opacity(isSelected ? 0.6 : 0), radius: 3, y: 1)
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 12, cornerStyle: .circular)).focusEffectDisabled()
        .help(appLocalized(detail))
        .accessibilityLabel(appLocalized(title)).accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(SpringMotion.interactive, value: isSelected)
    }
}

private struct ExportPrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appUI(size: 13, weight: .medium))
            .foregroundStyle(EditorTheme.onAccent)
            .padding(.horizontal, 22).frame(height: 42)
            .background(EditorTheme.platinumAccent, in: RoundedRectangle(cornerRadius: 13))
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 13), color: EditorTheme.onAccent.opacity(0.65))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.32)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(SpringMotion.interactive, value: configuration.isPressed)
    }
}

struct ExportSheet: View {
    let wallpaperURLResolver: EditorSessionContext.WallpaperURLResolver
    let projectAssetURLResolver: EditorSessionContext.ProjectAssetURLResolver
    let projectDisplayName: String
    let exportScope: EditorExportScope
    @ObservedObject var exporter: VideoExporter
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var requestErrorMessage: String?
    @State private var selectedOutputURL: URL?
    @State private var usesSuggestedOutputURL = true
    @State private var selectedOutputKind: ExportOutputKind = .video

    init(
        wallpaperURLResolver: @escaping EditorSessionContext.WallpaperURLResolver,
        projectAssetURLResolver: @escaping EditorSessionContext.ProjectAssetURLResolver,
        projectDisplayName: String,
        exportScope: EditorExportScope = .fullProject,
        exporter: VideoExporter,
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController
    ) {
        self.wallpaperURLResolver = wallpaperURLResolver
        self.projectAssetURLResolver = projectAssetURLResolver
        self.projectDisplayName = projectDisplayName
        self.exportScope = exportScope
        self.exporter = exporter
        self.editorStore = editorStore
        self.mediaSession = mediaSession
        self.playbackController = playbackController
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.appUI(size: 19, weight: .regular)).foregroundStyle(EditorTheme.chrome(0.72))
                VStack(alignment: .leading, spacing: 4) {
                    Text(exportScope.outputRange == nil ? "导出作品" : "导出选区")
                        .font(.appUI(size: 18, weight: .medium))
                    Text(projectDisplayName).font(.appUI(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.editorDismissIcon)
                    .disabled(exporter.isExporting)
                    .help(exporter.isExporting ? "取消导出后可关闭" : "关闭导出面板")
                    .accessibilityLabel("关闭导出面板")
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Divider().overlay(EditorTheme.hairline)
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        exportDestination
                        exportOutputKindChoices
                        if selectedOutputKind == .video {
                            exportResolutionChoices
                            exportFrameRateChoices
                        } else {
                            Text("导出剪辑后的系统声音与麦克风混音。")
                                .font(.appUI(size: 12)).foregroundStyle(.secondary)
                        }
                        if let range = exportScope.outputRange { exportRangeSummary(range) }
                    }
                    .padding(1)
                    .padding(.bottom, 8)
                }.scrollIndicators(.automatic).frame(width: 376)
                Rectangle().fill(EditorTheme.hairline).frame(width: 1)
                exportPreviewSummary.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(28).frame(height: 460)
            Divider().overlay(EditorTheme.hairline)
            VStack(alignment: .leading, spacing: 14) {
                if showsExportStatusRegion { exportStatusRegion }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let disabledExportReason {
                            Text(disabledExportReason).foregroundStyle(.secondary)
                        } else if let outputEstimate {
                            Text("预计大小 · 约 \(ByteCountFormatter.string(fromByteCount: outputEstimate.byteCount, countStyle: .file))")
                                .foregroundStyle(.secondary)
                        }
                        if mediaSession.prepared == nil, let message = mediaSession.errorMessage {
                            Text(message).foregroundStyle(.orange).lineLimit(2)
                        }
                    }.font(.appUI(size: 11))
                    Spacer(minLength: 12)
                    if !exporter.isExporting {
                        Button("取消") { dismiss() }.buttonStyle(.editorGhost)
                    }
                    Button {
                        if exporter.isExporting { exporter.cancelExport() }
                        else { startExport() }
                    } label: {
                        Label(exporter.isExporting ? "取消导出" : (selectedOutputKind == .video ? exportActionTitle("视频") : exportActionTitle("音频")),
                              systemImage: exporter.isExporting ? "stop.fill" : "square.and.arrow.up")
                    }
                    .buttonStyle(ExportPrimaryActionStyle())
                    .disabled(!exporter.isExporting && !canStartExport)
                }
            }.padding(.horizontal, 28).padding(.vertical, 20)
        }
        .frame(width: 840)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
        .animation(SpringMotion.fluid, value: selectedOutputKind)
        .interactiveDismissDisabled(exporter.isExporting)
        .onAppear {
            prepareSuggestedOutputURLIfNeeded()
        }
        .onChange(of: editorStore.project.exportSettings.frameRate) { _, _ in
            guard selectedOutputKind == .video,
                  usesSuggestedOutputURL,
                  !exporter.isExporting else { return }
            refreshSuggestedOutputURL()
        }
        .onChange(of: selectedOutputKind) { _, _ in
            guard !exporter.isExporting else { return }
            exporter.resetResultForNewExportSelection()
            refreshSuggestedOutputURL()
        }
    }

    private var exportDestination: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("文件名").font(.appUI(size: 12)).foregroundStyle(.secondary)
            Button { chooseOutputLocation() } label: {
                HStack(spacing: 8) {
                    Text(selectedOutputURL?.deletingPathExtension().lastPathComponent ?? projectDisplayName)
                        .font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("." + selectedOutputKind.fileExtension)
                        .font(.appUI(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(EditorTheme.chrome(0.035), in: Capsule())
                    Image(systemName: "pencil").font(.appUI(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).frame(height: 44)
                    .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(EditorTheme.hairline))
            }.buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 12, cornerStyle: .circular)).disabled(exporter.isExporting)
                .help("更改文件名与保存位置").accessibilityLabel("更改文件名与保存位置")
            Button { chooseOutputLocation() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder").font(.appUI(size: 12))
                    Text(selectedOutputDirectory ?? "选择保存位置")
                        .font(.appUI(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.appUI(size: 9))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
            }.buttonStyle(.editorToolbarPress).disabled(exporter.isExporting)
                .accessibilityLabel("保存位置").accessibilityValue(selectedOutputDirectory ?? "尚未选择")
        }
    }

    private var exportPreviewSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selectedOutputKind == .video ? "当前画面" : "音频导出")
                .font(.appUI(size: 12)).foregroundStyle(.secondary)
            ZStack {
                EditorTheme.chrome(0.025)
                if selectedOutputKind == .video {
                    CanvasPreview(
                        editorStore: editorStore, mediaSession: mediaSession,
                        playbackController: playbackController, renderProject: editorStore.project,
                        previewResolutionMode: .constant(.low), isCropping: false,
                        cropDraft: .constant(editorStore.project.canvas.crop),
                        wallpaperURLResolver: wallpaperURLResolver,
                        projectAssetURLResolver: projectAssetURLResolver,
                        onCanvasFocused: {}, onError: { requestErrorMessage = $0 }
                    )
                    .allowsHitTesting(false).accessibilityHidden(true)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform").font(.appUI(size: 38, weight: .ultraLight))
                        Text("M4A").font(.appUI(size: 12)).foregroundStyle(.secondary)
                    }.foregroundStyle(EditorTheme.platinumMuted)
                }
            }
            .frame(height: 194).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EditorTheme.hairline))
            VStack(spacing: 0) {
                exportSummaryRow("格式", value: selectedOutputKind == .video ? "MP4" : "M4A")
                if selectedOutputKind == .video {
                    exportSummaryRow("分辨率", value: exportDimensionsText)
                    exportSummaryRow("帧率", value: "\(editorStore.project.exportSettings.frameRate.rawValue) fps")
                }
                exportSummaryRow("时长", value: Self.exportTimecode(exportScope.outputRange?.duration ?? mediaSession.outputDuration))
            }
            .accessibilityLabel("导出规格").accessibilityValue(outputConfigurationSummary)
        }
    }

    private func exportSummaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(appLocalized(title)).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(EditorTheme.chrome(0.8)).monospacedDigit()
        }.font(.appUI(size: 12)).frame(height: 28)
    }

    private var exportDimensionsText: String {
        let source = mediaSession.sourceDisplaySize
        guard source.width > 0, source.height > 0 else { return "准备中" }
        let canvas = editorStore.project.canvas
        let crop = canvas.crop.clamped()
        let dimensions = canvas.pixelDimensions(
            resolution: editorStore.project.exportSettings.resolution,
            sourceAspectRatio: Double(source.width / source.height) * crop.width / crop.height,
            sourcePixelSize: CanvasDimensions(width: max(Int(source.width.rounded()), 2), height: max(Int(source.height.rounded()), 2)))
        return "\(dimensions.width) × \(dimensions.height)"
    }

    private var exportOutputKindChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出内容")
                .font(.appUI(size: 12))
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                ExportChoiceTile(
                    title: "视频成片",
                    detail: "画面与剪辑后的混音",
                    icon: "film.stack.fill",
                    isSelected: selectedOutputKind == .video
                ) {
                    selectedOutputKind = .video
                }
                ExportChoiceTile(
                    title: "仅音频",
                    detail: "M4A · 剪辑后的混音",
                    icon: "waveform",
                    isSelected: selectedOutputKind == .audio
                ) {
                    selectedOutputKind = .audio
                }
            }
            .disabled(exporter.isExporting)
        }
    }

    private var outputConfigurationSummary: String {
        let duration = exportScope.outputRange?.duration ?? mediaSession.outputDuration
        let time = Self.exportTimecode(duration)
        guard selectedOutputKind == .video else { return "M4A · \(time)" }
        let size = mediaSession.sourceDisplaySize
        guard size.width > 0, size.height > 0 else { return "MP4 · \(time)" }
        let crop = editorStore.project.canvas.crop.clamped()
        let settings = editorStore.project.exportSettings
        let dimensions = editorStore.project.canvas.pixelDimensions(
            resolution: settings.resolution,
            sourceAspectRatio: Double(size.width / size.height) * crop.width / crop.height,
            sourcePixelSize: CanvasDimensions(width: max(Int(size.width.rounded()), 2), height: max(Int(size.height.rounded()), 2))
        )
        return "\(dimensions.width) × \(dimensions.height) px · \(settings.frameRate.rawValue) fps · \(time) · MP4"
    }

    private var exportResolutionChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分辨率")
                .font(.appUI(size: 12))
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                ForEach(CanvasResolution.allCases) { resolution in
                    ExportChoiceTile(
                        title: resolution == .source ? "原始素材" : resolution.rawValue,
                        detail: resolutionDetail(resolution),
                        icon: resolutionIcon(resolution),
                        isSelected: editorStore.project.exportSettings.resolution
                            == resolution
                    ) {
                        resolutionBinding.wrappedValue = resolution
                    }
                }
            }
            .disabled(exporter.isExporting)
        }
    }

    private var exportFrameRateChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("帧率")
                .font(.appUI(size: 12))
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                ForEach(OutputFrameRate.exportProductChoices) { rate in
                    ExportChoiceTile(
                        title: rate.label,
                        detail: rate == .fps60 ? "更流畅" : "更小体积",
                        icon: rate == .fps60 ? "film.stack" : "film",
                        isSelected: editorStore.project.exportSettings.frameRate
                            == rate
                    ) {
                        frameRateBinding.wrappedValue = rate
                    }
                }
            }
            .disabled(exporter.isExporting)
        }
    }

    @ViewBuilder
    private var exportStatusRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            if exporter.isExporting {
                let progress = min(max(exporter.exportProgress, 0), 0.99)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Label(
                            exporter.status.title,
                            systemImage: selectedOutputKind == .video
                                ? "film.stack" : "waveform"
                        )
                            .font(.appUI(.caption, weight: .semibold))
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(EditorTheme.platinumAccent)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(EditorTheme.chrome(0.07))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(EditorTheme.chrome(0.08), lineWidth: 0.75)
                                }

                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [EditorTheme.selectionTint, EditorTheme.selectionTint],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: progress > 0
                                        ? max(proxy.size.width * CGFloat(progress), 8)
                                        : 0
                                )
                                .animation(.linear(duration: 0.18), value: progress)
                        }
                    }
                    .frame(height: 8)
                    HStack(alignment: .top, spacing: 12) {
                        Text(exporter.status.elapsedLabel).monospacedDigit()
                        Spacer(minLength: 4)
                        Text(exporter.status.remainingLabel)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.appUI(.caption2))
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("导出进度")
                .accessibilityValue("\(Int((progress * 100).rounded()))%")
            } else if mediaSession.prepared == nil {
                HStack(alignment: .top, spacing: 8) {
                    if mediaSession.errorMessage == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(mediaSession.errorMessage ?? "正在准备与预览同一代的导出素材…")
                        .font(.appUI(.caption))
                        .foregroundStyle(.secondary)
                }
            } else if let url = exporter.lastExportURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.45))
                        .font(.appUI(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导出完成")
                            .font(.appUI(.caption, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        .buttonStyle(.editorGhost)
                        .accessibilityLabel("在 Finder 中显示导出文件")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("导出完成")
            } else {
                Label("已准备好导出", systemImage: "checkmark.circle")
                    .font(.appUI(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("导出状态")
                    .accessibilityValue("已准备好导出")
            }

            if let message = exporter.errorMessage ?? requestErrorMessage {
                Text(message)
                    .font(.appUI(.caption))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(EditorTheme.chrome(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(EditorTheme.chrome(0.08), lineWidth: 0.75)
        )
        .animation(SpringMotion.interactive, value: exporter.isExporting)
    }

    private var disabledExportReason: String? {
        guard !exporter.isExporting else { return nil }
        if mediaSession.prepared == nil {
            return mediaSession.errorMessage == nil
                ? "预览素材准备完成后即可导出"
                : "请先解决上方的素材错误"
        }
        if selectedOutputURL == nil {
            return "请先选择保存位置"
        }
        if selectedOutputKind == .audio, !preparedMixHasAudio {
            return "当前剪辑没有可导出的声音"
        }
        return nil
    }

    private var canStartExport: Bool {
        mediaSession.prepared != nil
            && selectedOutputURL != nil
            && (selectedOutputKind == .video || preparedMixHasAudio)
    }

    private var showsExportStatusRegion: Bool {
        exporter.isExporting
            || exporter.lastExportURL != nil
            || exporter.errorMessage != nil
            || requestErrorMessage != nil
    }

    private var selectedOutputDirectory: String? {
        guard let selectedOutputURL else { return nil }
        return (selectedOutputURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
    }

    private var outputEstimate: EditorExportEstimate? {
        return mediaSession.prepared.flatMap {
            EditorExportEstimate.make(
                mediaPlan: $0.plan,
                sourceDisplaySize: $0.sourceDisplaySize,
                project: editorStore.project,
                outputKind: selectedOutputKind,
                includesAudio: preparedMixHasAudio,
                outputRange: exportScope.outputRange
            )
        }
    }

    private var preparedMixHasAudio: Bool {
        guard let composition = mediaSession.prepared?.composition else { return false }
        return composition.systemAudioTrack != nil
            || composition.microphoneAudioTrack != nil
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
            guard let outputURL = selectedOutputURL else {
                requestErrorMessage = "请先选择导出保存位置。"
                return
            }
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
                outputURL: outputURL,
                outputKind: selectedOutputKind,
                outputRange: exportScope.outputRange
            )
            exporter.export(request: request)
        } catch {
            requestErrorMessage = error.localizedDescription
        }
    }

    private func prepareSuggestedOutputURLIfNeeded() {
        guard selectedOutputURL == nil else { return }
        refreshSuggestedOutputURL()
    }

    private func refreshSuggestedOutputURL() {
        do {
            selectedOutputURL = try EditorExportRequestBuilder.makeDefaultOutputURL(
                for: editorStore.project,
                preferredProjectName: suggestedProjectName,
                outputKind: selectedOutputKind
            )
            usesSuggestedOutputURL = true
            requestErrorMessage = nil
        } catch {
            selectedOutputURL = nil
            requestErrorMessage = error.localizedDescription
        }
    }

    private func chooseOutputLocation() {
        let suggested = selectedOutputURL ?? (try? EditorExportRequestBuilder
            .makeDefaultOutputURL(
                for: editorStore.project,
                preferredProjectName: suggestedProjectName,
                outputKind: selectedOutputKind
            ))
        let panel = NSSavePanel()
        panel.title = selectedOutputKind == .video
            ? "选择视频导出位置" : "选择音频导出位置"
        panel.prompt = "选择"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = selectedOutputKind == .video
            ? [.mpeg4Movie] : [.mpeg4Audio]
        panel.isExtensionHidden = false
        panel.directoryURL = suggested?.deletingLastPathComponent()
            ?? AppPreferences.exportDirectoryURL
        panel.nameFieldStringValue = suggested?.lastPathComponent
            ?? "\(projectDisplayName).\(selectedOutputKind.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedOutputURL = url
        usesSuggestedOutputURL = false
        requestErrorMessage = nil
        AppPreferences.rememberExportDirectory(url.deletingLastPathComponent())
    }

    private func resolutionIcon(_ resolution: CanvasResolution) -> String {
        switch resolution {
        case .source: "viewfinder.rectangular"
        case .fullHD: "rectangle"
        case .quadHD: "rectangle.inset.filled"
        case .ultraHD: "4k.tv.fill"
        }
    }

    private var suggestedProjectName: String {
        exportScope.outputRange == nil
            ? projectDisplayName
            : "\(projectDisplayName)-选区"
    }

    private func exportActionTitle(_ kind: String) -> String {
        exportScope.outputRange == nil
            ? "开始导出\(kind)"
            : "开始导出选区\(kind)"
    }

    private func exportRangeSummary(_ range: MediaTimeRange) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "selection.pin.in.out")
                .font(.appUI(size: 16, weight: .semibold))
                .foregroundStyle(EditorTheme.platinumAccent)
                .frame(width: 34, height: 34)
                .background(EditorTheme.chrome(0.06), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("已选择 \(exportScope.selectedSegmentCount) 个主片段")
                    .font(.appUI(.subheadline, weight: .semibold))
                Text(
                    "\(Self.exportTimecode(range.start)) – \(Self.exportTimecode(range.end))"
                    + "  ·  时长 \(Self.exportTimecode(range.duration))"
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(EditorTheme.platinumAccent.opacity(0.22), lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("选区导出")
        .accessibilityValue(
            "\(exportScope.selectedSegmentCount) 个片段，"
            + "从 \(Self.exportTimecode(range.start)) 到 \(Self.exportTimecode(range.end))"
        )
    }

    private static func exportTimecode(_ time: TimeInterval) -> String {
        let safe = max(time.isFinite ? time : 0, 0)
        let minutes = Int(safe) / 60
        let seconds = safe - TimeInterval(minutes * 60)
        return String(format: "%d:%05.2f", minutes, seconds)
    }

    private func resolutionDetail(_ resolution: CanvasResolution) -> String {
        switch resolution {
        case .source: "跟随素材"
        case .fullHD: "轻量高清"
        case .quadHD: "细节优先"
        case .ultraHD: "超清输出"
        }
    }
}
