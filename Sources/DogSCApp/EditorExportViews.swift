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

/// Every export choice is visible before the user acts. A tile is both the
/// complete hit target and the current-value indicator; there is no hidden
/// menu layered over decorative content.
private struct ExportChoiceTile: View {
    let title: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(
                            isSelected
                                ? Color.black.opacity(0.82)
                                : EditorTheme.platinumMuted
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            isSelected
                                ? EditorTheme.platinumAccent
                                : Color.black.opacity(0.24),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )

                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(EditorTheme.platinumAccent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background(
                LinearGradient(
                    colors: isSelected
                        ? [
                            EditorTheme.platinumAccent.opacity(0.16),
                            EditorTheme.platinumAccent.opacity(0.07),
                        ]
                        : [
                            Color.white.opacity(isHovered && isEnabled ? 0.10 : 0.065),
                            Color.white.opacity(isHovered && isEnabled ? 0.055 : 0.035),
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        isSelected
                            ? EditorTheme.platinumAccent.opacity(0.78)
                            : Color.white.opacity(isHovered && isEnabled ? 0.22 : 0.11),
                        lineWidth: isSelected ? 1.1 : 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.editorToolbarPress)
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
        .animation(SpringMotion.interactive, value: isSelected)
        .animation(SpringMotion.interactive, value: isEnabled)
    }
}

private struct ExportDestinationLabel: View {
    let fileName: String?
    let directory: String?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: fileName == nil ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 40, height: 40)
                .background(
                    EditorTheme.platinumAccent,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("保存位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(fileName ?? "选择导出文件")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let directory {
                    Text(directory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Text(fileName == nil ? "选择" : "更改")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(EditorTheme.platinumAccent)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(isHovered && isEnabled ? 0.12 : 0.08),
                    Color.white.opacity(isHovered && isEnabled ? 0.065 : 0.04),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    Color.white.opacity(isHovered && isEnabled ? 0.24 : 0.13),
                    lineWidth: 0.8
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
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
    @State private var selectedOutputURL: URL?
    @State private var usesSuggestedOutputURL = true

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
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .frame(width: 44, height: 44)
                    .background(
                        EditorTheme.platinumAccent,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("导出成片")
                        .font(.title2.weight(.semibold))
                    Text(projectDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !exporter.isExporting {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.editorDismissIcon)
                    .help("关闭导出面板")
                    .accessibilityLabel("关闭导出面板")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)

            Divider().overlay(dividerColor)

            VStack(alignment: .leading, spacing: 20) {
                exportResolutionChoices
                exportFrameRateChoices

                Button {
                    chooseOutputLocation()
                } label: {
                    ExportDestinationLabel(
                        fileName: selectedOutputURL?.lastPathComponent,
                        directory: selectedOutputDirectory
                    )
                }
                .buttonStyle(.editorToolbarPress)
                .disabled(exporter.isExporting)
                .accessibilityLabel("保存位置")
                .accessibilityValue(
                    selectedOutputURL?.path ?? "尚未选择"
                )

                HStack(spacing: 10) {
                    if mediaSession.prepared == nil {
                        if mediaSession.errorMessage == nil {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(mediaSession.errorMessage ?? "正在准备导出素材")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(EditorTheme.success)
                        Text("素材已准备")
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)
                    if let outputEstimate {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(EditorTheme.platinumMuted)
                            .accessibilityHidden(true)
                        Text(
                            "建议预留 · 约 \(ByteCountFormatter.string(fromByteCount: outputEstimate.byteCount, countStyle: .file))"
                        )
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    }
                }
                .font(.caption)

                if showsExportStatusRegion {
                    exportStatusRegion
                }
            }
            .padding(24)

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
                    Label(
                        exporter.isExporting ? "取消导出" : "开始导出",
                        systemImage: exporter.isExporting
                            ? "stop.fill"
                            : "arrow.up.forward"
                    )
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.editorPrimary(minHeight: 50))
                .disabled(!exporter.isExporting && !canStartExport)
            }
            .padding(22)
        }
        .frame(width: 600)
        .background(panelBackground)
        .interactiveDismissDisabled(exporter.isExporting)
        .onAppear {
            prepareSuggestedOutputURLIfNeeded()
        }
        .onChange(of: editorStore.project.exportSettings.frameRate) { _, _ in
            guard usesSuggestedOutputURL, !exporter.isExporting else { return }
            refreshSuggestedOutputURL()
        }
    }

    private var exportResolutionChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分辨率", systemImage: "rectangle.inset.filled")
                .font(.headline)
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                ForEach(CanvasResolution.allCases) { resolution in
                    ExportChoiceTile(
                        title: resolution.rawValue,
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
            Label("帧率", systemImage: "speedometer")
                .font(.headline)
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
                let progress = min(max(exporter.exportProgress, 0), 1)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Label("正在导出成片", systemImage: "film.stack")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(EditorTheme.platinumAccent)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.32))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.75)
                                }

                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white, EditorTheme.platinumAccent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: progress > 0
                                        ? max(proxy.size.width * CGFloat(progress), 8)
                                        : 0
                                )
                                .shadow(color: EditorTheme.platinumAccent.opacity(0.24), radius: 4)
                        }
                    }
                    .frame(height: 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("导出进度")
                .accessibilityValue("\(Int((progress * 100).rounded()))%")
                .animation(.linear(duration: 0.18), value: progress)
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
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.45))
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导出完成")
                            .font(.caption.weight(.semibold))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("导出状态")
                    .accessibilityValue("已准备好导出")
            }

            if let message = exporter.errorMessage ?? requestErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.75)
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
        return nil
    }

    private var canStartExport: Bool {
        mediaSession.prepared != nil && selectedOutputURL != nil
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
            guard let outputURL = selectedOutputURL else {
                requestErrorMessage = "请先选择成片保存位置。"
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
                outputURL: outputURL
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
                preferredProjectName: projectDisplayName
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
                preferredProjectName: projectDisplayName
            ))
        let panel = NSSavePanel()
        panel.title = "选择成片导出位置"
        panel.prompt = "选择"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.isExtensionHidden = false
        panel.directoryURL = suggested?.deletingLastPathComponent()
            ?? AppPreferences.exportDirectoryURL
        panel.nameFieldStringValue = suggested?.lastPathComponent
            ?? "\(projectDisplayName)-\(editorStore.project.exportSettings.frameRate.rawValue)fps.mp4"
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

    private func resolutionDetail(_ resolution: CanvasResolution) -> String {
        switch resolution {
        case .source: "跟随素材"
        case .fullHD: "轻量高清"
        case .quadHD: "细节优先"
        case .ultraHD: "超清输出"
        }
    }
}
