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
    @State private var customOutputBaseName: String?
    @State private var outputDirectoryURL: URL?
    @State private var isEditingOutputName = false
    @State private var outputNameDraft = ""
    @State private var outputNameAtEditingStart = ""
    @State private var outputNameError: String?
    @FocusState private var outputNameFocused: Bool
    @State private var selectedOutputKind: ExportOutputKind = .video
    @State private var showsSupportSheet = false
    @State private var didPrepareOutput = false

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
                AppLineIcon(kind: .share, size: 22)
                    .foregroundStyle(EditorTheme.primaryText)
                    .frame(width: 44, height: 44)
                    .background(EditorTheme.controlWell, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized(exportScope.outputRange == nil ? "导出作品" : "导出选区"))
                        .font(.appUI(size: 18, weight: .medium))
                    Text(projectDisplayName).font(.appUI(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: { AppLineIcon(kind: .close, size: 13) }
                    .buttonStyle(.editorDismissIcon)
                    .disabled(exporter.isExporting)
                    .help(appLocalized(exporter.isExporting ? "取消导出后可关闭" : "关闭导出面板"))
                    .accessibilityLabel("关闭导出面板")
            }.padding(.horizontal, 28).padding(.vertical, 22)
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
                    }
                    .padding(1)
                    .padding(.bottom, 8)
                }.scrollIndicators(.automatic).frame(width: 376)
                exportPreviewSummary
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, 28).padding(.bottom, 24).frame(height: exportContentHeight)
            Divider().overlay(EditorTheme.hairline)
            exportFooter.padding(.horizontal, 28).padding(.vertical, 20)
        }
        .frame(width: 840)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
        .animation(RecorderMotion.reduces ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: selectedOutputKind)
        .interactiveDismissDisabled(exporter.isExporting)
        .onExitCommand {
            guard !exporter.isExporting else { return }
            dismiss()
        }
        .onAppear {
            guard !didPrepareOutput else { return }
            didPrepareOutput = true
            exporter.resetResultForNewExportSelection()
            prepareSuggestedOutputURLIfNeeded()
        }
        .onChange(of: selectedOutputURL) { _, _ in
            resetExportCompletionIfNeeded()
        }
        .onChange(of: editorStore.project.exportSettings) { _, _ in
            resetExportCompletionIfNeeded()
        }
        .onChange(of: editorStore.project.exportSettings.frameRate) { _, _ in
            guard selectedOutputKind == .video,
                  customOutputBaseName == nil,
                  !exporter.isExporting else { return }
            refreshSuggestedOutputURL()
        }
        .onChange(of: selectedOutputKind) { _, _ in
            guard !exporter.isExporting else { return }
            exporter.resetResultForNewExportSelection()
            refreshSuggestedOutputURL()
        }
        .sheet(isPresented: $showsSupportSheet) { AppSupportSheet() }
    }

    @ViewBuilder
    private var exportFooter: some View {
        if let url = completedExportURL {
            HStack(spacing: 12) {
                Label { Text("导出完成").foregroundStyle(EditorTheme.primaryText) } icon: {
                    AppLineIcon(kind: .checkCircle, size: 18).foregroundStyle(EditorTheme.success)
                }
                    .font(.appUI(size: 13, weight: .medium))
                    .fixedSize()

                Spacer(minLength: 16)

                Button { showsSupportSheet = true } label: {
                    Label { Text("请杯咖啡") } icon: { AppLineIcon(kind: .cup, size: 16) }
                        .foregroundStyle(EditorTheme.secondaryText)
                        .fixedSize().frame(height: 34)
                }
                .buttonStyle(.editorQuiet)
                .accessibilityIdentifier("export.completed.support")
                .accessibilityHint("打开赞赏码")

                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label { Text("在 Finder 中显示") } icon: { AppLineIcon(kind: .folder, size: 16) }
                        .fixedSize().frame(height: 34)
                }
                .buttonStyle(.editorQuiet)
                .accessibilityLabel("在 Finder 中显示导出文件")

                Button { dismiss() } label: {
                    Text("完成").frame(minWidth: 44)
                }
                .buttonStyle(EditorPrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if showsExportStatusRegion { exportStatusRegion }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let disabledExportReason {
                            Text(appLocalized(disabledExportReason)).foregroundStyle(.secondary)
                        } else if let outputEstimate {
                            Text(String(format: appLocalized("预计大小 · 约 %@"), ByteCountFormatter.string(fromByteCount: outputEstimate.byteCount, countStyle: .file)))
                                .foregroundStyle(.secondary)
                        }
                        if mediaSession.prepared == nil, let message = mediaSession.errorMessage {
                            Text(message).foregroundStyle(.orange).lineLimit(2)
                        }
                    }.font(.appUI(size: 11))
                    Spacer(minLength: 12)
                    if !exporter.isExporting {
                        Button { dismiss() } label: {
                            Text("取消").frame(minWidth: 44, minHeight: EditorInterfaceHeight.action)
                        }.buttonStyle(.editorGhost)
                    }
                    Button {
                        if exporter.isExporting { exporter.cancelExport() }
                        else { startExport() }
                    } label: {
                        Label {
                            Text(exporter.isExporting ? appLocalized("取消导出") : exportActionTitle)
                        } icon: {
                            AppLineIcon(kind: exporter.isExporting ? .stop : .share, size: 16)
                        }
                    }
                    .buttonStyle(EditorPrimaryPillButtonStyle())
                    .disabled(!exporter.isExporting && !canStartExport)
                }
            }
        }
    }

    private var completedExportURL: URL? {
        guard !exporter.isExporting, !isEditingOutputName,
              exporter.errorMessage == nil, requestErrorMessage == nil else { return nil }
        return exporter.lastExportURL
    }

    private func resetExportCompletionIfNeeded() {
        guard !exporter.isExporting, exporter.lastExportURL != nil else { return }
        exporter.resetResultForNewExportSelection()
    }

    private var exportContentHeight: CGFloat {
        if selectedOutputKind == .video { return 460 }
        return exportScope.outputRange == nil ? 356 : 400
    }

    private var exportDestination: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("文件名").font(.appUI(size: 12)).foregroundStyle(.secondary)
            Group {
                if isEditingOutputName {
                    exportFileNameRow
                } else {
                    Button { beginOutputNameEditing() } label: {
                        exportFileNameRow
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.group))
                    .help(appLocalized("更改文件名"))
                    .accessibilityLabel(appLocalized("更改文件名"))
                    .accessibilityValue(selectedOutputURL?.lastPathComponent ?? "\(projectDisplayName).\(selectedOutputKind.fileExtension)")
                }
            }
            .disabled(exporter.isExporting)
            if let outputNameError {
                Text(appLocalized(outputNameError))
                    .font(.appUI(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { chooseOutputLocation() } label: {
                HStack(spacing: 7) {
                    AppLineIcon(kind: .folder, size: 15)
                    Text(selectedOutputDirectory ?? appLocalized("选择保存位置"))
                        .font(.appUI(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    AppLineIcon(kind: .chevron, size: 11)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
            }.buttonStyle(.editorToolbarPress).disabled(exporter.isExporting)
                .help(appLocalized("选择导出文件夹"))
                .accessibilityLabel("保存位置").accessibilityValue(selectedOutputDirectory ?? appLocalized("尚未选择"))
        }
    }

    private var exportFileNameRow: some View {
        HStack(spacing: 8) {
            if isEditingOutputName {
                TextField("", text: $outputNameDraft)
                    .textFieldStyle(.plain)
                    .tint(nil)
                    .font(.appUI(size: 13))
                    .focused($outputNameFocused)
                    .onSubmit { _ = commitOutputNameEditing() }
                    .onExitCommand { cancelOutputNameEditing() }
                    .onChange(of: outputNameDraft) { _, _ in
                        outputNameError = nil
                    }
                    .onChange(of: outputNameFocused) { _, focused in
                        guard !focused, isEditingOutputName else { return }
                        if outputFileNameValidationError(outputNameDraft) == nil {
                            _ = commitOutputNameEditing()
                        } else {
                            cancelOutputNameEditing()
                        }
                    }
                    .accessibilityLabel(appLocalized("文件名"))
            } else {
                Text(selectedOutputURL?.deletingPathExtension().lastPathComponent ?? projectDisplayName)
                    .font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
            }
            Text("." + selectedOutputKind.fileExtension)
                .font(.appUI(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(EditorTheme.chrome(0.035), in: Capsule())
            if !isEditingOutputName {
                AppLineIcon(kind: .pencil, size: 14).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var exportPreviewSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appLocalized(selectedOutputKind == .video ? "当前画面" : "音频导出"))
                .font(.appUI(size: 12)).foregroundStyle(.secondary)
            ZStack {
                EditorTheme.chrome(0.025)
                if selectedOutputKind == .video {
                    CanvasPreview(
                        editorStore: editorStore, mediaSession: mediaSession,
                        playbackController: playbackController, renderProject: editorStore.project,
                        previewResolutionMode: .constant(.low), isCropping: false,
                        showsEditingControls: false,
                        cropDraft: .constant(editorStore.project.canvas.crop),
                        wallpaperURLResolver: wallpaperURLResolver,
                        projectAssetURLResolver: projectAssetURLResolver,
                        onCanvasFocused: {}, onError: { requestErrorMessage = $0 }
                    )
                    .allowsHitTesting(false).accessibilityHidden(true)
                } else {
                    VStack(spacing: 10) {
                        AppLineIcon(kind: .waveform, size: 38)
                        Text("M4A").font(.appUI(size: 12)).foregroundStyle(.secondary)
                    }.foregroundStyle(EditorTheme.platinumMuted)
                }
            }
            .frame(height: exportScope.outputRange == nil ? 168 : 140).clipShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
            .accessibilityHidden(true)
            VStack(spacing: 0) {
                exportSummaryRow("格式", value: selectedOutputKind == .video ? "MP4" : "M4A")
                if selectedOutputKind == .video {
                    exportSummaryRow("分辨率", value: exportDimensionsText)
                    exportSummaryRow("帧率", value: "\(editorStore.project.exportSettings.frameRate.rawValue) fps")
                }
                exportSummaryRow("时长", value: Self.exportTimecode(exportScope.outputRange?.duration ?? mediaSession.outputDuration))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("导出规格").accessibilityValue(outputConfigurationSummary)
            if let range = exportScope.outputRange {
                exportRangeSummary(range)
            }
        }
    }

    private func exportSummaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(appLocalized(title)).foregroundStyle(EditorTheme.secondaryText)
            Spacer()
            Text(value).foregroundStyle(EditorTheme.primaryText).monospacedDigit()
        }.font(EditorTypography.helper).frame(height: 28)
    }

    private var exportDimensionsText: String {
        let source = mediaSession.sourceDisplaySize
        guard source.width > 0, source.height > 0 else { return appLocalized("准备中") }
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
            Text("导出内容").font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.primaryText)
            EditorSegmentedControl(
                options: [ExportOutputKind.video, .audio],
                title: { $0 == .video ? "视频成片" : "仅音频" },
                icon: { $0 == .video ? "film" : "waveform" },
                optionHelp: { $0 == .video ? "画面与剪辑后的混音" : "M4A · 剪辑后的混音" },
                selection: $selectedOutputKind
            )
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
            Text("分辨率").font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.primaryText)
            EditorSegmentedControl(
                options: CanvasResolution.allCases,
                title: { $0 == .source ? "原始素材" : $0.rawValue },
                accessibilityTitle: { ($0 == .source ? appLocalized("原始素材") : $0.rawValue) + " · " + resolutionDetail($0) },
                optionHelp: resolutionDetail,
                selection: resolutionBinding
            )
            .disabled(exporter.isExporting)
        }
    }

    private var exportFrameRateChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("帧率").font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.primaryText)
            EditorSegmentedControl(
                options: OutputFrameRate.exportProductChoices,
                title: { $0.label },
                accessibilityTitle: { $0.label + " · " + appLocalized($0 == .fps60 ? "更流畅" : "更小体积") },
                optionHelp: { $0 == .fps60 ? "更流畅" : "更小体积" },
                selection: frameRateBinding
            )
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
                        Label { Text(exporter.status.title) } icon: {
                            AppLineIcon(kind: selectedOutputKind == .video ? .film : .waveform, size: 16)
                        }
                            .font(EditorTypography.controlLabel)
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(EditorTheme.platinumAccent)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(EditorTheme.controlWell)

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
                    .frame(height: 5)
                    HStack(alignment: .top, spacing: 12) {
                        Text(exporter.status.elapsedLabel).monospacedDigit()
                        Spacer(minLength: 4)
                        Text(exporter.status.remainingLabel)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(EditorTypography.helper)
                    .foregroundStyle(EditorTheme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("导出进度")
                .accessibilityValue("\(Int((progress * 100).rounded()))%")
            } else if mediaSession.prepared == nil {
                HStack(alignment: .top, spacing: 8) {
                    if mediaSession.errorMessage == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        AppLineIcon(kind: .warning, size: 16)
                            .foregroundStyle(.orange)
                    }
                    Text(mediaSession.errorMessage ?? appLocalized("正在准备与预览同一代的导出素材…"))
                        .font(.appUI(.caption))
                        .foregroundStyle(.secondary)
                }
            } else {
                Label { Text("已准备好导出") } icon: { AppLineIcon(kind: .checkCircle, size: 16) }
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

        .animation(RecorderMotion.fade, value: exporter.isExporting)
    }

    private var disabledExportReason: String? {
        guard !exporter.isExporting else { return nil }
        if mediaSession.prepared == nil {
            return mediaSession.errorMessage == nil
                ? "预览素材准备完成后即可导出"
                : "请先解决上方的素材错误"
        }
        if isEditingOutputName, let error = outputFileNameValidationError(outputNameDraft) {
            return error
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
            && (!isEditingOutputName || outputFileNameValidationError(outputNameDraft) == nil)
            && (selectedOutputKind == .video || preparedMixHasAudio)
    }

    private var showsExportStatusRegion: Bool {
        exporter.isExporting
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
        guard commitOutputNameEditing() else { return }
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
            let directory = outputDirectoryURL ?? AppPreferences.exportDirectoryURL
            if let customOutputBaseName {
                selectedOutputURL = try EditorExportRequestBuilder.makeOutputURL(
                    in: directory,
                    baseName: customOutputBaseName,
                    outputKind: selectedOutputKind
                )
            } else {
                selectedOutputURL = try EditorExportRequestBuilder.makeDefaultOutputURL(
                    for: editorStore.project,
                    preferredProjectName: suggestedProjectName,
                    outputKind: selectedOutputKind,
                    directoryURL: directory
                )
            }
            requestErrorMessage = nil
        } catch {
            selectedOutputURL = nil
            requestErrorMessage = error.localizedDescription
        }
    }

    private func beginOutputNameEditing() {
        outputNameDraft = selectedOutputURL?.deletingPathExtension().lastPathComponent
            ?? projectDisplayName
        outputNameAtEditingStart = outputNameDraft
        outputNameError = nil
        isEditingOutputName = true
        DispatchQueue.main.async { outputNameFocused = true }
    }

    @discardableResult
    private func commitOutputNameEditing() -> Bool {
        guard isEditingOutputName else { return true }
        if let error = outputFileNameValidationError(outputNameDraft) {
            outputNameError = error
            outputNameFocused = true
            return false
        }
        let baseName = normalizedOutputFileName(outputNameDraft)
        if baseName != outputNameAtEditingStart {
            customOutputBaseName = baseName
            refreshSuggestedOutputURL()
        }
        guard selectedOutputURL != nil else { return false }
        isEditingOutputName = false
        outputNameFocused = false
        outputNameError = nil
        return true
    }

    private func cancelOutputNameEditing() {
        isEditingOutputName = false
        outputNameFocused = false
        outputNameError = nil
    }

    private func normalizedOutputFileName(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The extension is displayed separately and follows the output kind.
        for ext in [ExportOutputKind.video.fileExtension, ExportOutputKind.audio.fileExtension] {
            if name.lowercased().hasSuffix("." + ext.lowercased()) {
                name.removeLast(ext.count + 1)
                break
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func outputFileNameValidationError(_ text: String) -> String? {
        let name = normalizedOutputFileName(text)
        if name.isEmpty { return "请输入文件名。" }
        if name == "." || name == ".." { return "文件名不能是 . 或 ..。" }
        let forbidden = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        if name.rangeOfCharacter(from: forbidden) != nil {
            return "文件名不能包含 /、: 或换行。"
        }
        return nil
    }

    private func chooseOutputLocation() {
        guard commitOutputNameEditing() else { return }
        let panel = NSOpenPanel()
        panel.title = appLocalized("选择导出文件夹")
        panel.prompt = appLocalized("选择")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = selectedOutputURL?.deletingLastPathComponent()
            ?? outputDirectoryURL
            ?? AppPreferences.exportDirectoryURL
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        outputDirectoryURL = directory
        AppPreferences.rememberExportDirectory(directory)
        refreshSuggestedOutputURL()
    }

    private var suggestedProjectName: String {
        exportScope.outputRange == nil
            ? projectDisplayName
            : "\(projectDisplayName)-选区"
    }

    private var exportActionTitle: String {
        if exportScope.outputRange == nil {
            return appLocalized(selectedOutputKind == .video ? "开始导出视频" : "开始导出音频")
        }
        return appLocalized(selectedOutputKind == .video ? "开始导出选区视频" : "开始导出选区音频")
    }

    private func exportRangeSummary(_ range: MediaTimeRange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: appLocalized("已选择 %d 个主片段"), exportScope.selectedSegmentCount))
                .font(.appUI(size: 12, weight: .medium))
            Text(
                String(format: appLocalized("%@ – %@  ·  时长 %@"),
                       Self.exportTimecode(range.start), Self.exportTimecode(range.end), Self.exportTimecode(range.duration))
            )
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("选区导出")
        .accessibilityValue(
            String(format: appLocalized("%d 个片段，从 %@ 到 %@"),
                   exportScope.selectedSegmentCount, Self.exportTimecode(range.start), Self.exportTimecode(range.end))
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
