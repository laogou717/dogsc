import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorExportEstimate: Equatable, Sendable {
    let byteCount: Int64

    static func make(
        mediaPlan: ProjectTimelineMediaPlan,
        sourceDisplaySize: CGSize,
        project: RecorderProject,
        outputKind: ExportOutputKind,
        includesAudio: Bool,
        outputRange: MediaTimeRange? = nil,
        videoCodecOverride: ExportVideoCodec? = nil
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
            var settings = project.exportSettings
            if let videoCodecOverride { settings.videoCodec = videoCodecOverride }
            let requested = project.canvas.pixelDimensions(
                resolution: settings.resolution,
                sourceAspectRatio: croppedSourceAspectRatio,
                sourcePixelSize: CanvasDimensions(
                    width: max(Int(sourceDisplaySize.width.rounded()), 2),
                    height: max(Int(sourceDisplaySize.height.rounded()), 2)
                )
            )
            let dimensions = settings.outputDimensions(for: requested)
            totalBitsPerSecond = ExportEncodingPolicy.videoBitrate(
                width: dimensions.width,
                height: dimensions.height,
                frameRate: settings.frameRate.rawValue,
                codec: settings.resolvedVideoCodec(for: requested),
                quality: settings.quality
            ) + (includesAudio ? ExportEncodingPolicy.audioBitrate : 0)
        }
        let byteCount = Double(totalBitsPerSecond)
            * outputDuration / 8
        guard byteCount.isFinite,
              byteCount >= 0,
              byteCount <= Double(Int64.max) else { return nil }
        return EditorExportEstimate(
            byteCount: Int64(byteCount)
        )
    }
}

/// What the sheet remembers about a running job, so reopening the sheet
/// after 在后台继续 shows that job rather than a fresh suggestion.
@MainActor
enum ExportSheetSession {
    static var activeOutputURL: URL?
    static var activeOutputKind: ExportOutputKind = .video
    static var activeDuration: TimeInterval = 0
    static var activeVideoCodec: ExportVideoCodec = .h264
    static var activeDimensions: CanvasDimensions?
    static var activeFrameRate: OutputFrameRate = .fps60
    static var activeQuality: ExportQuality = .high
    static var continuedInBackground = false
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
    /// A job finished while the sheet was closed; keep its result on reopen.
    @State private var showsBackgroundResult = false
    @State private var hoverFraction: Double?
    @State private var showsResolutionNotice = false

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

    private enum Phase { case options, running, done }

    private var phase: Phase {
        if exporter.isExporting { return .running }
        if completedExportURL != nil { return .done }
        return .options
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 22) {
                previewColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Group {
                    switch phase {
                    case .options: optionsColumn
                    case .running: runningColumn
                    case .done: doneColumn
                    }
                }
                .frame(width: 300)
                .frame(minHeight: 270)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 6)
            footer
        }
        .frame(width: 760)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
        .animation(RecorderMotion.reduces ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.22), value: selectedOutputKind)
        .animation(RecorderMotion.reduces ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.22), value: phase)
        .onExitCommand { closeSheet() }
        .onAppear {
            guard !didPrepareOutput else { return }
            didPrepareOutput = true
            if exporter.isExporting {
                selectedOutputKind = ExportSheetSession.activeOutputKind
            } else if ExportSheetSession.continuedInBackground,
                      let url = exporter.lastExportURL,
                      url == ExportSheetSession.activeOutputURL {
                showsBackgroundResult = true
                selectedOutputKind = ExportSheetSession.activeOutputKind
            } else {
                exporter.resetResultForNewExportSelection()
            }
            ExportSheetSession.continuedInBackground = false
            prepareSuggestedOutputURLIfNeeded()
        }
        .onDisappear {
            playbackController.endHoverPreview()
            if exporter.isExporting { ExportSheetSession.continuedInBackground = true }
        }
        .onChange(of: selectedOutputURL) { _, _ in
            resetExportCompletionIfNeeded()
        }
        .onChange(of: editorStore.project.exportSettings) { _, _ in
            showsResolutionNotice = false
            resetExportCompletionIfNeeded()
        }
        .onChange(of: editorStore.project.exportSettings.frameRate) { _, _ in
            guard selectedOutputKind == .video,
                  customOutputBaseName == nil,
                  !exporter.isExporting else { return }
            refreshSuggestedOutputURL()
        }
        .onChange(of: selectedOutputKind) { _, _ in
            showsResolutionNotice = false
            guard !exporter.isExporting, !showsBackgroundResult else { return }
            exporter.resetResultForNewExportSelection()
            refreshSuggestedOutputURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageDidChange)) { _ in
            refreshAutomaticOutputNameIfNeeded()
        }
        .onChange(of: isEditingOutputName) { _, editing in
            if !editing { refreshAutomaticOutputNameIfNeeded() }
        }
        .sheet(isPresented: $showsSupportSheet) { AppSupportSheet() }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Text(appLocalized(exportScope.outputRange == nil || phase != .options ? "导出" : "导出选区"))
                .font(.appUI(size: 17, weight: .semibold))
                .foregroundStyle(EditorTheme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { closeSheet() } label: { AppLineIcon(kind: .close, size: 16) }
                .buttonStyle(.editorDismissIcon(size: 28))
                .help(appLocalized(exporter.isExporting ? "关闭，导出在后台继续 (Esc)" : "关闭 (Esc)"))
                .accessibilityLabel(appLocalized("关闭导出面板"))
        }
        .padding(.leading, 22).padding(.trailing, 16).padding(.top, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .options:
                if let range = exportScope.outputRange {
                    rangeTag(range)
                } else if let outputEstimate {
                    HStack(spacing: 8) {
                        (Text(String(format: appLocalized("约 %@"),
                                 ByteCountFormatter.string(fromByteCount: outputEstimate.byteCount, countStyle: .file)))
                        .foregroundColor(EditorTheme.secondaryText).fontWeight(.medium))
                        .font(.appUI(size: 12.5))
                        .monospacedDigit()
                        if let percent = estimatedCodecSavingPercentage {
                            Text(String(format: appLocalized("预计省约 %d%%"), percent))
                                .font(.appUI(size: 11, weight: .medium))
                                .foregroundStyle(EditorTheme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(EditorTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .help(appLocalized("按当前画质、分辨率、编码和帧率估算，实际大小随内容变化"))
                }
                Spacer(minLength: 10)
                Button { dismiss() } label: { Text("取消") }
                    .buttonStyle(.appSheet(.ghost, large: true))
                Button { startExport() } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .export, size: 16)
                        Text("导出")
                    }
                }
                .buttonStyle(.appSheet(.primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canStartExport)
                .help(disabledExportReason.map(appLocalized) ?? exportActionTitle)
                .accessibilityLabel(exportActionTitle)
            case .running:
                Spacer(minLength: 10)
                Button { exporter.cancelExport() } label: { Text("停止导出") }
                    .buttonStyle(.appSheet(.ghost, large: true))
                    .disabled(exporter.status.stage == .cancelling)
                Button { dismiss() } label: { Text("在后台继续") }
                    .buttonStyle(.appSheet(.normal, large: true))
                    .keyboardShortcut(.defaultAction)
                    .help(appLocalized("收起面板，导出在后台继续"))
            case .done:
                Spacer(minLength: 10)
                Button { finishAndClose() } label: { Text("完成") }
                    .buttonStyle(.appSheet(.primary, large: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.leading, 22).padding(.trailing, 16).padding(.top, 14).padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(EditorTheme.chrome(0.075)).frame(height: 1) }
        .padding(.top, 10)
    }

    private func rangeTag(_ range: MediaTimeRange) -> some View {
        HStack(spacing: 8) {
            Text(appLocalized("选区")).fontWeight(.semibold)
            Text("\(rangeSegmentsText) · \(Self.clockText(range.duration))")
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(appLocalized("只导出选中的主片段"))
        }
        .font(.appUI(size: 12.5))
        .foregroundStyle(EditorTheme.accent)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 420)
        .background(EditorTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized("选区导出"))
        .accessibilityValue("\(rangeSegmentsText) · \(Self.clockText(range.duration))")
    }

    /// "第 3–5 段": the primary segments the range covers, counted along the
    /// timeline. Falls back to the selection count when the map is not ready.
    private var rangeSegmentsText: String {
        guard let range = exportScope.outputRange else { return "" }
        let durations = mediaSession.sourceDurations
        if let map = try? EditorPrimaryTimelinePresentation.timelineMap(
            sourceDurations: durations, project: editorStore.project
        ) {
            let epsilon = 1.0 / 120.0
            let covered = map.segments.indices.filter {
                map.segments[$0].outputStart >= range.start - epsilon
                    && map.segments[$0].outputEnd <= range.end + epsilon
            }
            if let first = covered.first, let last = covered.last {
                return first == last
                    ? String(format: appLocalized("第 %d 段"), first + 1)
                    : String(format: appLocalized("第 %d–%d 段"), first + 1, last + 1)
            }
        }
        return String(format: appLocalized("%d 个主片段"), exportScope.selectedSegmentCount)
    }

    // MARK: - Preview

    private var previewDuration: TimeInterval {
        if phase != .options, ExportSheetSession.activeDuration > 0 { return ExportSheetSession.activeDuration }
        return exportScope.outputRange?.duration ?? mediaSession.outputDuration
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            exportPreview
            facts.padding(.top, 12).padding(.leading, 2)
        }
    }

    private var exportPreview: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let start = exportScope.outputRange?.start ?? 0
        let duration = max(exportScope.outputRange?.duration ?? mediaSession.outputDuration, 0)
        let restingFraction = duration > 0
            ? min(max((playbackController.outputTime - start) / duration, 0), 1) : 0
        let fraction: Double = phase == .running
            ? min(max(exporter.exportProgress, 0), 1)
            : (hoverFraction ?? restingFraction)
        return ZStack {
            EditorCanvasRestingCover(showsNote: false)
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
            .allowsHitTesting(false)
            if selectedOutputKind == .audio {
                Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.18)
            }
            VStack {
                HStack {
                    Text(Self.clockText(fraction * duration))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Spacer()
                }
                Spacer()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.45))
                        Capsule().fill(Color.white).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
            .padding(10)
            .allowsHitTesting(false)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(EditorTheme.chrome(0.075), lineWidth: 1))
        .contentShape(shape)
        .onContinuousHover { hover in
            guard phase == .options || phase == .done else { return }
            switch hover {
            case let .active(location):
                // The preview's own width is the full clip; map by fraction.
                hoverLocation(location.x, start: start, duration: duration)
            case .ended:
                hoverFraction = nil
                playbackController.endHoverPreview()
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ExportPreviewWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(ExportPreviewWidthKey.self) { previewWidth = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized("成片预览"))
        .accessibilityHint(appLocalized("在预览上左右移动指针可以快速浏览全片"))
    }

    @State private var previewWidth: CGFloat = 1

    private func hoverLocation(_ x: CGFloat, start: TimeInterval, duration: TimeInterval) {
        guard duration > 0, previewWidth > 0 else { return }
        let p = min(max(Double(x / previewWidth), 0), 1)
        hoverFraction = p
        playbackController.updateHoverPreview(to: start + p * duration)
    }

    private var facts: some View {
        let isVideo = selectedOutputKind == .video
        return HStack(alignment: .top, spacing: 14) {
            fact("时长", Self.clockText(previewDuration))
            resolutionFact(isVideo: isVideo)
            fact("帧率", isVideo ? "\(outputFrameRate.rawValue)" : "—")
            fact("编码", isVideo ? selectedVideoCodec.displayName : "AAC")
            fact("格式", isVideo ? "MP4" : "M4A")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized("导出规格"))
        .accessibilityValue(outputConfigurationSummary)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLocalized(title))
                .font(.appUI(size: 12.5))
                .foregroundStyle(EditorTheme.tertiaryText)
            Text(value)
                .font(.appUI(size: 13.5, weight: .medium))
                .foregroundStyle(EditorTheme.primaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func resolutionFact(isVideo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLocalized("分辨率"))
                .font(.appUI(size: 12.5)).foregroundStyle(EditorTheme.tertiaryText)
            HStack(spacing: 4) {
                Text(isVideo ? exportDimensionsText : "—")
                    .font(.appUI(size: 13.5, weight: .medium))
                    .foregroundStyle(EditorTheme.primaryText).monospacedDigit()
                if isVideo, let notice = resolutionAdjustmentNotice {
                    Button { showsResolutionNotice.toggle() } label: {
                        AppLineIcon(kind: .warning, size: 12)
                            .foregroundStyle(EditorTheme.accent)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(notice)
                    .accessibilityLabel(appLocalized("导出尺寸已适配"))
                    .popover(isPresented: $showsResolutionNotice) {
                        Text(notice).font(.appUI(size: 13))
                            .foregroundStyle(EditorTheme.primaryText)
                            .padding(14).frame(width: 280, alignment: .leading)
                            .background(EditorTheme.panelSurface)
                    }
                }
            }
        }.fixedSize()
    }

    private var resolutionAdjustmentNotice: String? {
        guard phase == .options,
              let requested = requestedExportDimensions,
              let output = exportDimensions, output != requested else { return nil }
        return String(format: appLocalized("当前 H.264 编码器的长边上限为 4096 像素，导出已从 %@ 等比调整为 %@。选择 HEVC 可使用所选分辨率。"),
                      "\(requested.width) × \(requested.height)", "\(output.width) × \(output.height)")
    }

    private var outputFrameRate: OutputFrameRate {
        phase == .options ? editorStore.project.exportSettings.frameRate : ExportSheetSession.activeFrameRate
    }

    private var selectedVideoCodec: ExportVideoCodec {
        if phase != .options { return ExportSheetSession.activeVideoCodec }
        return editorStore.project.exportSettings.resolvedVideoCodec(
            for: requestedExportDimensions ?? CanvasDimensions(width: 1920, height: 1080)
        )
    }

    private var selectedQuality: ExportQuality {
        phase == .options ? editorStore.project.exportSettings.quality : ExportSheetSession.activeQuality
    }

    private var exportDimensions: CanvasDimensions? {
        if phase != .options, let dimensions = ExportSheetSession.activeDimensions { return dimensions }
        return requestedExportDimensions.map { editorStore.project.exportSettings.outputDimensions(for: $0) }
    }

    private var requestedExportDimensions: CanvasDimensions? {
        let source = mediaSession.canvasSourceSize(for: editorStore.project)
        guard source.width > 0, source.height > 0 else { return nil }
        let canvas = editorStore.project.canvas
        let crop = canvas.crop.clamped()
        return canvas.pixelDimensions(
            resolution: editorStore.project.exportSettings.resolution,
            sourceAspectRatio: Double(source.width / source.height) * crop.width / crop.height,
            sourcePixelSize: CanvasDimensions(width: max(Int(source.width.rounded()), 2), height: max(Int(source.height.rounded()), 2)))
    }

    private var exportDimensionsText: String {
        guard let dimensions = exportDimensions else { return appLocalized("准备中") }
        return "\(dimensions.width) × \(dimensions.height)"
    }

    private var outputConfigurationSummary: String {
        let time = Self.clockText(previewDuration)
        guard selectedOutputKind == .video else { return "M4A · \(time)" }
        return "\(exportDimensionsText) · \(outputFrameRate.rawValue) fps · \(selectedVideoCodec.displayName) · \(appLocalized(selectedQuality.displayName)) · \(time) · MP4"
    }

    // MARK: - Options

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            option("导出") {
                HStack(spacing: 8) {
                    outputKindCard(.video, title: "视频", detail: "画面和混音 · MP4", icon: .camera)
                    outputKindCard(.audio, title: "仅声音", detail: "剪辑后的混音 · M4A", icon: .waveform)
                }
            }
            if selectedOutputKind == .video {
                option("分辨率") {
                    AppSegmentedChoice(
                        options: CanvasResolution.allCases,
                        selection: resolutionBinding,
                        label: { $0 == .source ? "原始" : $0.rawValue },
                        optionMinWidth: nil, fillsWidth: true
                    )
                }
                .transition(.opacity)
                HStack(alignment: .top, spacing: 10) {
                    compactOption("帧率", note: outputFrameRate == .fps60 ? "更流畅" : "更小") {
                        AppSegmentedChoice(
                            options: OutputFrameRate.exportProductChoices,
                            selection: frameRateBinding,
                            label: { "\($0.rawValue)" },
                            optionMinWidth: nil, fillsWidth: true
                        )
                    }.frame(width: 122)
                    compactOption("编码", note: selectedVideoCodec == .hevc ? "更省空间" : "兼容好") {
                        AppSegmentedChoice(
                            options: ExportVideoCodec.allCases,
                            selection: videoCodecBinding,
                            label: { $0.displayName },
                            optionMinWidth: nil, fillsWidth: true
                        )
                    }
                }
                .transition(.opacity)
                option("画质") {
                    AppSegmentedChoice(
                        options: ExportQuality.allCases,
                        selection: qualityBinding,
                        label: { $0.displayName },
                        optionMinWidth: nil, fillsWidth: true
                    )
                    Text(appLocalized(selectedQuality.detail))
                        .font(.appUI(size: 11.5))
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            option("文件") {
                VStack(alignment: .leading, spacing: 6) {
                    fileNameField
                    placeRow
                }
            }
            if let message = statusMessage {
                Text(message.text)
                    .font(.appUI(size: 12))
                    .foregroundStyle(message.isError ? EditorTheme.destructiveText : EditorTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func compactOption<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(appLocalized(title)).font(.appUI(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
                Text(appLocalized(note)).font(.appUI(size: 11.5))
            }
            .foregroundStyle(EditorTheme.tertiaryText)
            content()
        }
    }

    private func option<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appLocalized(title))
                .font(.appUI(size: 12.5, weight: .medium))
                .foregroundStyle(EditorTheme.tertiaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func outputKindCard(_ kind: ExportOutputKind, title: String, detail: String, icon: AppLineIcon.Kind) -> some View {
        let selected = selectedOutputKind == kind
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            selectedOutputKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AppLineIcon(kind: icon, size: 13)
                    Text(appLocalized(title))
                }
                .font(.appUI(size: 13.5, weight: .medium))
                .foregroundStyle(EditorTheme.primaryText)
                Text(appLocalized(detail))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? EditorTheme.accent.opacity(0.12) : .clear, in: shape)
            .overlay(shape.strokeBorder(selected ? EditorTheme.accent : EditorTheme.chrome(0.075),
                                        lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 10))
        .appButtonKeyboardFocus(in: shape)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(SpringMotion.micro, value: selected)
    }

    private var fileNameField: some View {
        HStack(spacing: 0) {
            if isEditingOutputName {
                TextField("", text: $outputNameDraft)
                    .textFieldStyle(.plain)
                    .font(.appUI(size: 14))
                    .focused($outputNameFocused)
                    .onSubmit { _ = commitOutputNameEditing() }
                    .onExitCommand { cancelOutputNameEditing() }
                    .onChange(of: outputNameDraft) { _, _ in outputNameError = nil }
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
                    .font(.appUI(size: 14))
                    .foregroundStyle(EditorTheme.primaryText)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginOutputNameEditing() }
            }
            Text("." + selectedOutputKind.fileExtension)
                .font(.appUI(size: 14))
                .foregroundStyle(EditorTheme.tertiaryText)
                .padding(.trailing, 4)
            Button { isEditingOutputName ? (_ = commitOutputNameEditing()) : beginOutputNameEditing() } label: {
                AppLineIcon(kind: isEditingOutputName ? .check : .pencil, size: 13)
            }
            .buttonStyle(.editorDismissIcon(size: 28))
            .help(appLocalized(isEditingOutputName ? "完成改名" : "改名"))
            .accessibilityLabel(appLocalized(isEditingOutputName ? "完成改名" : "更改文件名"))
            .accessibilityValue(selectedOutputURL?.lastPathComponent ?? "")
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 34)
        .background(EditorTheme.chrome(isEditingOutputName ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let outputNameError {
                Text(appLocalized(outputNameError))
                    .font(.appUI(size: 11.5))
                    .foregroundStyle(EditorTheme.destructiveText)
                    .offset(y: 16)
            }
        }
        .disabled(exporter.isExporting)
    }

    private var placeRow: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { chooseOutputLocation() } label: {
            HStack(spacing: 8) {
                AppLineIcon(kind: .folder, size: 13)
                Text(selectedOutputFolderName ?? appLocalized("选择保存位置"))
                    .font(.appUI(size: 13))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(appLocalized("更改"))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.tertiaryText)
            }
            .foregroundStyle(EditorTheme.secondaryText)
            .padding(.leading, 10).padding(.trailing, 6)
            .frame(height: 32)
            .overlay(shape.strokeBorder(EditorTheme.chrome(0.075), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8))
        .padding(.top, outputNameError == nil ? 0 : 14)
        .disabled(exporter.isExporting)
        .help(selectedOutputDirectory ?? appLocalized("选择导出文件夹"))
        .accessibilityLabel(appLocalized("保存位置"))
        .accessibilityValue(selectedOutputDirectory ?? appLocalized("尚未选择"))
    }

    private var selectedOutputFolderName: String? {
        guard let folder = selectedOutputURL?.deletingLastPathComponent() else { return nil }
        return FileManager.default.displayName(atPath: folder.path)
    }

    private var statusMessage: (text: String, isError: Bool)? {
        if let message = exporter.errorMessage ?? requestErrorMessage { return (message, true) }
        if mediaSession.prepared == nil, let message = mediaSession.errorMessage { return (message, true) }
        if let disabledExportReason { return (appLocalized(disabledExportReason), false) }
        return nil
    }

    // MARK: - Running and done

    private var runningColumn: some View {
        let progress = min(max(exporter.exportProgress, 0), 0.99)
        let percent = Int((progress * 100).rounded())
        let isAudio = ExportSheetSession.activeOutputKind == .audio
        let duration = previewDuration
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(EditorTheme.chrome(0.08), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(EditorTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.18), value: progress)
                    Text("\(percent)%")
                        .font(.appUI(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(2.5)
                .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 0) {
                    Text(appLocalized(exporter.status.stage == .processing
                                      ? (isAudio ? "正在导出声音" : "正在导出视频")
                                      : exporter.status.title))
                        .font(.appUI(size: 15, weight: .medium))
                    Text(appLocalized("可以继续编辑，导出在后台进行"))
                        .font(.appUI(size: 12.5))
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    kvKey("已完成")
                    kvValue("\(Self.clockText(progress * duration)) / \(Self.clockText(duration))")
                }
                GridRow {
                    if !isAudio {
                        kvKey("编码规格")
                        kvValue("\(ExportSheetSession.activeVideoCodec.displayName) · \(exportDimensionsText) · \(ExportSheetSession.activeFrameRate.rawValue) fps · \(appLocalized(ExportSheetSession.activeQuality.displayName))")
                    }
                }
                GridRow {
                    if let remaining = remainingText {
                        kvKey("剩余约"); kvValue(remaining)
                    } else {
                        kvKey("状态"); kvValue(exporter.status.remainingLabel)
                    }
                }
                GridRow {
                    kvKey("文件")
                    kvValue(ExportSheetSession.activeOutputURL?.lastPathComponent ?? "")
                }
            }
            .font(.appUI(size: 13))
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appLocalized("导出进度"))
        .accessibilityValue("\(percent)%")
    }

    private var remainingText: String? {
        let status = exporter.status
        guard status.stage == .processing, status.secondsWithoutProgress < 20,
              let remaining = status.remaining else { return nil }
        return Self.spokenDuration(remaining)
    }

    private func kvKey(_ key: String) -> some View {
        Text(appLocalized(key)).foregroundStyle(EditorTheme.tertiaryText)
    }

    private func kvValue(_ value: String) -> some View {
        Text(value)
            .fontWeight(.medium)
            .foregroundStyle(EditorTheme.primaryText)
            .monospacedDigit()
            .lineLimit(1).truncationMode(.middle)
    }

    @ViewBuilder
    private var doneColumn: some View {
        if let url = completedExportURL {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AppLineIcon(kind: .check, size: 16)
                        .foregroundStyle(EditorTheme.success)
                        .frame(width: 36, height: 36)
                        .background(EditorTheme.success.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("导出完成").font(.appUI(size: 15, weight: .medium))
                        Text(String(format: appLocalized("用时 %@"), Self.spokenDuration(exporter.status.elapsed)))
                            .font(.appUI(size: 12.5))
                            .foregroundStyle(EditorTheme.tertiaryText)
                    }
                }
                HStack(spacing: 10) {
                    AppLineIcon(kind: url.pathExtension == ExportOutputKind.audio.fileExtension ? .waveform : .camera, size: 16)
                        .foregroundStyle(EditorTheme.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(url.lastPathComponent)
                            .font(.appUI(size: 13.5, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(completedFileDetail(url))
                            .font(.appUI(size: 12))
                            .foregroundStyle(EditorTheme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(EditorTheme.chrome(0.075), lineWidth: 1))
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 6) { AppLineIcon(kind: .play, size: 13); Text("播放") }
                    }
                    .buttonStyle(.appSheet)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        HStack(spacing: 6) { AppLineIcon(kind: .folder, size: 13); Text("在 Finder 中显示") }
                    }
                    .buttonStyle(.appSheet)
                    .accessibilityLabel(appLocalized("在 Finder 中显示导出文件"))
                }
                Button { showsSupportSheet = true } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .cup, size: 13)
                        Text("喜欢 DogSC？请作者喝杯咖啡")
                    }
                    .font(.appUI(size: 12.5))
                }
                .buttonStyle(ExportCoffeeLinkStyle())
                .accessibilityIdentifier("export.completed.support")
                .accessibilityHint(appLocalized("打开赞赏码"))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func completedFileDetail(_ url: URL) -> String {
        let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard let size else { return folder }
        let format = ExportSheetSession.activeOutputKind == .video
            ? "MP4 (\(ExportSheetSession.activeVideoCodec.displayName))" : "M4A (AAC)"
        return "\(folder) · \(format) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private var completedExportURL: URL? {
        guard !exporter.isExporting, !isEditingOutputName,
              exporter.errorMessage == nil, requestErrorMessage == nil else { return nil }
        return exporter.lastExportURL
    }

    private func resetExportCompletionIfNeeded() {
        guard !showsBackgroundResult, !exporter.isExporting, exporter.lastExportURL != nil else { return }
        exporter.resetResultForNewExportSelection()
    }

    private func closeSheet() {
        guard !isEditingOutputName else { cancelOutputNameEditing(); return }
        if phase == .done { finishAndClose() } else { dismiss() }
    }

    private func finishAndClose() {
        showsBackgroundResult = false
        ExportSheetSession.continuedInBackground = false
        exporter.resetResultForNewExportSelection()
        dismiss()
    }

    /// "3 分 40 秒" / "40 秒" / "1 小时 2 分".
    private static func spokenDuration(_ seconds: TimeInterval) -> String {
        let value = max(Int(seconds.isFinite ? seconds.rounded() : 0), 0)
        if value >= 3_600 {
            return String(format: appLocalized("%d 小时 %d 分"), value / 3_600, (value / 60) % 60)
        }
        if value >= 60 {
            return String(format: appLocalized("%d 分 %d 秒"), value / 60, value % 60)
        }
        return String(format: appLocalized("%d 秒"), value)
    }

    /// m:ss (h:mm:ss past an hour).
    private static func clockText(_ time: TimeInterval) -> String {
        ExportStatus.durationText(max(time.isFinite ? time.rounded(.down) : 0, 0))
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

    private var selectedOutputDirectory: String? {
        guard let selectedOutputURL else { return nil }
        return (selectedOutputURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
    }

    private var outputEstimate: EditorExportEstimate? {
        return mediaSession.prepared.flatMap {
            EditorExportEstimate.make(
                mediaPlan: $0.plan,
                sourceDisplaySize: mediaSession.canvasSourceSize(for: editorStore.project),
                project: editorStore.project,
                outputKind: selectedOutputKind,
                includesAudio: preparedMixHasAudio,
                outputRange: exportScope.outputRange
            )
        }
    }

    private var estimatedCodecSavingPercentage: Int? {
        guard selectedOutputKind == .video, selectedVideoCodec == .hevc,
              let requested = requestedExportDimensions,
              ExportSettings(videoCodec: .h264).outputDimensions(for: requested) == exportDimensions,
              let prepared = mediaSession.prepared, let estimate = outputEstimate,
              let reference = EditorExportEstimate.make(
                mediaPlan: prepared.plan,
                sourceDisplaySize: mediaSession.canvasSourceSize(for: editorStore.project),
                project: editorStore.project, outputKind: .video, includesAudio: preparedMixHasAudio,
                outputRange: exportScope.outputRange, videoCodecOverride: .h264
              ), reference.byteCount > estimate.byteCount else { return nil }
        return Int((100 * (1 - Double(estimate.byteCount) / Double(reference.byteCount))).rounded())
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
                let codec = selectedVideoCodec
                updateExportSettings(actionName: "调整导出帧率") {
                    $0.frameRate = frameRate
                    $0.videoCodec = codec
                }
            }
        )
    }

    private var videoCodecBinding: Binding<ExportVideoCodec> {
        Binding(get: { selectedVideoCodec }, set: { codec in
            updateExportSettings(actionName: "调整导出编码") { $0.videoCodec = codec }
        })
    }

    private var qualityBinding: Binding<ExportQuality> {
        Binding(get: { editorStore.project.exportSettings.quality }, set: { quality in
            updateExportSettings(actionName: "调整导出画质") { $0.quality = quality }
        })
    }

    private var resolutionBinding: Binding<CanvasResolution> {
        Binding(
            get: { editorStore.project.exportSettings.resolution },
            set: { resolution in
                let codec = selectedVideoCodec
                updateExportSettings(actionName: "调整导出分辨率") {
                    $0.resolution = resolution
                    $0.videoCodec = codec
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
            requestErrorMessage = mediaSession.errorMessage ?? appLocalized("导出素材尚未准备完成。")
            return
        }
        do {
            let project = editorStore.project
            guard let outputURL = selectedOutputURL else {
                requestErrorMessage = appLocalized("请先选择导出保存位置。")
                return
            }
            let request = try EditorExportRequestBuilder.make(
                editorSessionID: editorStore.sessionID,
                mediaGeneration: preparedMedia.generation,
                project: project,
                preparedMedia: preparedMedia,
                wallpaperURL: wallpaperURLResolver(project.canvas.backgroundSource),
                sceneWallpaperURLs: Dictionary(uniqueKeysWithValues: project.sceneBackgroundSources.compactMap { source in
                    guard let key = source.sceneResourceKey, let url = wallpaperURLResolver(source) else { return nil }
                    return (key, url)
                }),
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
            ExportSheetSession.activeOutputURL = outputURL
            ExportSheetSession.activeOutputKind = selectedOutputKind
            ExportSheetSession.activeDuration = exportScope.outputRange?.duration ?? mediaSession.outputDuration
            ExportSheetSession.activeVideoCodec = selectedVideoCodec
            ExportSheetSession.activeDimensions = exportDimensions
            ExportSheetSession.activeFrameRate = project.exportSettings.frameRate
            ExportSheetSession.activeQuality = project.exportSettings.quality
            ExportSheetSession.continuedInBackground = false
            showsBackgroundResult = false
            exporter.export(request: request)
        } catch {
            requestErrorMessage = error.localizedDescription
        }
    }

    private func prepareSuggestedOutputURLIfNeeded() {
        guard selectedOutputURL == nil else { return }
        refreshSuggestedOutputURL()
    }

    private func refreshAutomaticOutputNameIfNeeded() {
        guard customOutputBaseName == nil,
              !isEditingOutputName,
              !exporter.isExporting else { return }
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
        AppFilePanel.open(configure: { panel in
            panel.title = appLocalized("选择导出文件夹")
            panel.prompt = appLocalized("选择")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = selectedOutputURL?.deletingLastPathComponent()
                ?? outputDirectoryURL
                ?? AppPreferences.exportDirectoryURL
        }) { urls in
            guard let directory = urls?.first else { return }
            outputDirectoryURL = directory
            AppPreferences.rememberExportDirectory(directory)
            refreshSuggestedOutputURL()
        }
    }

    private var suggestedProjectName: String {
        exportScope.outputRange == nil
            ? projectDisplayName
            : "\(projectDisplayName)-\(appLocalized("选区"))"
    }

    private var exportActionTitle: String {
        if exportScope.outputRange == nil {
            return appLocalized(selectedOutputKind == .video ? "开始导出视频" : "开始导出音频")
        }
        return appLocalized(selectedOutputKind == .video ? "开始导出选区视频" : "开始导出选区音频")
    }
}

private struct ExportPreviewWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The quiet coffee line under a finished export.
private struct ExportCoffeeLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovered ? EditorTheme.secondaryText : EditorTheme.tertiaryText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(EditorTheme.chrome(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.leading, -6)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
