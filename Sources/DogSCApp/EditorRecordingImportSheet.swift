import AVFoundation
import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorRecordingImportSheet: View {
    let previews: [RecordingImportPreview]
    /// Where the import used to be placed. An import now only joins the
    /// media bin, so these are unused; they go away with the call site.
    let initialTime: TimeInterval?
    let playheadTime: TimeInterval
    let outputDuration: TimeInterval
    let perform: (RecordingProjectImportOptions, TimeInterval) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copyCost = RecordingImportCopyCost()
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(previews.count == 1 ? appLocalized("导入录屏项目")
                     : String(format: appLocalized("导入 %ld 个录屏项目"), previews.count))
                    .font(.appUI(size: 17, weight: .semibold))
                Text(appLocalized("导入到素材箱，之后拖到时间线上使用")).font(.appUI(size: 12.5)).foregroundStyle(RecordingDesign.tertiary)
            }.padding(.horizontal, 20).padding(.top, 18)
            VStack(spacing: 0) {
                importGroup {
                    if previews.count == 1, let preview = previews.first {
                        projectCard(preview)
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(previews) { projectCard($0) }
                            }
                        }
                        .frame(height: CGFloat(min(previews.count, 3)) * 92 - 8)
                    }
                }
                importGroup(divider: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        note(appLocalized("录制会出现在素材面板的「录制」里，原项目的缩放、字幕和叠加编辑不会一起导入。"))
                        // Only worth a word when the bytes are really copied:
                        // on one APFS volume the copy clones blocks instead.
                        if copyCost.crossesVolumes, copyCost.bytes > 0 {
                            note(String(format: appLocalized("与本项目不在同一磁盘，导入会复制约 %@ 素材。"),
                                        ByteCountFormatter.string(fromByteCount: copyCost.bytes, countStyle: .file)))
                        }
                        if let errorMessage { Text(errorMessage).font(.appUI(size: 12)).foregroundStyle(RecorderStyle.destructiveInk) }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 6).disabled(busy)
            HStack(spacing: 6) {
                Text(appLocalized("一步导入，⌘Z 可撤销")).font(.appUI(size: 12)).foregroundStyle(RecordingDesign.tertiary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(appLocalized("取消")) { dismiss() }.buttonStyle(.plain).padding(.horizontal, 13).frame(height: 30).disabled(busy).keyboardShortcut(.cancelAction)
                Button(appLocalized("导入")) {
                    busy = true; errorMessage = nil
                    Task { @MainActor in
                        do {
                            // Nothing on this panel is a choice any more:
                            // the recording joins the bin, files are copied.
                            try await perform(RecordingProjectImportOptions(), 0)
                            dismiss()
                        } catch { errorMessage = appErrorDescription(error) }
                        busy = false
                    }
                }
                .buttonStyle(.plain).font(.appUI(size: 13, weight: .medium))
                .padding(.horizontal, 13).frame(height: 30)
                .foregroundStyle(RecordingDesign.panel).background(RecordingDesign.ink, in: RoundedRectangle(cornerRadius: 8))
                .disabled(busy).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
        }
        .foregroundStyle(RecordingDesign.ink)
        .frame(width: 460).background(RecordingDesign.raised)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.recordingDesignControls, true)
        .interactiveDismissDisabled(busy)
        .task {
            let previews = previews, destination = ProjectFiles.package
            copyCost = await Task.detached { RecordingProjectImporter.copyCost(of: previews, into: destination) }.value
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.appUI(size: 12)).foregroundStyle(RecordingDesign.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func projectCard(_ preview: RecordingImportPreview) -> some View {
        HStack(spacing: 12) {
            RecordingSourceThumbnail(url: preview.project.media.flatMap {
                ProjectStore.resolveMediaPath($0.screen.relativePath, session: RecordingSession(packageURL: preview.packageURL))
            }).frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.name).font(.appUI(size: 14, weight: .semibold)).lineLimit(1)
                Text(metadata(preview)).font(.system(size: 12, design: .monospaced)).foregroundStyle(RecordingDesign.tertiary)
                HStack(spacing: 4) {
                    chip("鼠标", symbol: "cursorarrow", available: preview.project.sources.contains { $0.media.pointerEvents != nil })
                    chip("麦克风", symbol: "mic", available: preview.hasMicrophone)
                    chip("摄像头", symbol: "video", available: preview.hasCamera)
                }
            }
            Spacer(minLength: 0)
        }.padding(12).background(RecordingDesign.fill, in: RoundedRectangle(cornerRadius: 10))
    }
    private func metadata(_ preview: RecordingImportPreview) -> String {
        let size = preview.sourceSizes[RecordingSource.primaryID] ?? .zero
        return "\(RecordingSourcePresentation.duration(preview.outputDuration)) · \(Int(size.width)) × \(Int(size.height)) · \(preview.frameRate) fps"
    }
    private func importGroup<C: View>(divider: Bool = true, @ViewBuilder content: () -> C) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            .overlay(alignment: .bottom) { if divider { Rectangle().fill(RecordingDesign.line).frame(height: 1) } }
    }
    private func chip(_ title: String, symbol: String, available: Bool) -> some View {
        HStack(spacing: 4) {
            EditorSymbol(symbol, size: 12)
            Text(appLocalized(title)).strikethrough(!available)
        }.font(.appUI(size: 11.5)).foregroundStyle(RecordingDesign.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RecordingDesign.fill2, in: RoundedRectangle(cornerRadius: 5)).opacity(available ? 1 : 0.45)
    }
}

struct RecordingSourceThumbnail: View {
    let url: URL?
    @State private var image: CGImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RecordingDesign.fill
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 200)
            if let frame = try? await generator.image(at: .zero), !Task.isCancelled { image = frame.image }
        }
    }
}

enum RecordingSourcePresentation {
    static func duration(_ seconds: Double) -> String {
        let whole = max(Int(seconds.isFinite ? seconds : 0), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

extension EditorView {
    func chooseRecordingProject() {
        guard pendingRecordingImport == nil, recordingImportTask == nil else { return }
        EditorImportFilePicker.choose(
            directory: hostActions.projectPackageURL()?.deletingLastPathComponent() ?? ProjectStore.savedProjectsFolder,
            extensions: ["dogscproject"]
        ) { urls in prepareRecordingImports(urls, at: nil) }
    }
    func prepareRecordingImports(_ urls: [URL], at time: TimeInterval?) {
        guard !urls.isEmpty else { return }
        guard pendingRecordingImport == nil, recordingImportTask == nil else {
            queuedRecordingImports.append((urls, time)); return
        }
        resolveExternalAction(.importRecording)
        playbackController.pause()
        recordingImportTime = time
        recordingImportTask = Task { @MainActor in
            defer {
                recordingImportTask = nil
                if pendingRecordingImport == nil, !Task.isCancelled { advanceRecordingImportQueue() }
            }
            do {
                var previews: [RecordingImportPreview] = []
                for url in urls {
                    try Task.checkCancellation()
                    previews.append(try await RecordingProjectImporter.inspect(url))
                }
                try Task.checkCancellation()
                pendingRecordingImport = RecordingImportBatch(previews: previews)
            } catch is CancellationError { }
            catch { hostActions.reportError(appErrorDescription(error)) }
        }
    }
    func advanceRecordingImportQueue() {
        guard pendingRecordingImport == nil, recordingImportTask == nil, !queuedRecordingImports.isEmpty else { return }
        let next = queuedRecordingImports.removeFirst()
        prepareRecordingImports(next.0, at: next.1)
    }

}
