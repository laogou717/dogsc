import AVFoundation
import AppKit
import RecorderCore
import SwiftUI

extension RecordingSourcePresentation {
    static func name(_ sourceID: UUID, in project: RecorderProject) -> String {
        sourceID == RecordingSource.primaryID ? appLocalized("本项目录制") : (project.source(sourceID)?.name ?? "—")
    }
    static func color(_ sourceID: UUID, in project: RecorderProject) -> Color? {
        guard let index = project.additionalSources.firstIndex(where: { $0.id == sourceID }) else { return nil }
        return RecordingDesign.sourceColors[max(project.additionalSources[index].colorIndex ?? index, 0) % 3]
    }
    static func segmentName(_ segment: ResolvedRecordingSegment, in project: RecorderProject, segments: [ResolvedRecordingSegment]) -> String {
        let ordinal = (segments.prefix { $0.id != segment.id }.filter { $0.media == nil && $0.sourceID == segment.sourceID }.count) + 1
        return String(format: appLocalized("%@ · 第 %ld 段"), name(segment.sourceID, in: project), ordinal)
    }
    static func url(_ source: RecordingSource) -> URL? {
        guard let package = ProjectFiles.package else { return source.media.screen.relativePath.hasPrefix("/") ? URL(fileURLWithPath: source.media.screen.relativePath) : nil }
        return ProjectStore.resolveMediaPath(source.media.screen.relativePath, session: RecordingSession(packageURL: package))
    }
}

struct RecordingSourceLibraryCard: View {
    let source: RecordingSource
    let name: String
    let color: Color?
    let usage: Int
    var knownDuration: TimeInterval? = nil
    var selected = false
    /// Mirrors the bin's focus so an unfocused selection stops wearing the accent.
    var isFocused = true
    var select: () -> Void = {}
    var favorite = false
    var toggleFavorite: () -> Void = {}
    /// Width the hover actions may use, as for any other media card.
    var actionWidth: CGFloat = 0
    let insert: () -> Void
    @State private var duration = 0.0
    @State private var isHovered = false
    private var url: URL? { RecordingSourcePresentation.url(source) }
    /// The same set every media card shows: place it, keep it.
    private var actions: [EditorMediaCardActions.Item] {
        var items: [EditorMediaCardActions.Item] = []
        if isHovered { items.append(.init(id: "insert", symbol: "plus", help: "插入到主轨", action: insert)) }
        if isHovered || favorite {
            items.append(.init(id: "favorite", symbol: favorite ? "star.fill" : "star",
                               help: favorite ? "取消收藏" : "收藏，所有项目都能在素材库里找到它",
                               tint: favorite ? EditorTheme.amberAccent : .white, action: toggleFavorite))
        }
        return items
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorMediaThumbnail(selected: selected, isFocused: isFocused) {
                RecordingSourceThumbnail(url: url)
                .overlay(alignment: .top) { if let color { Rectangle().fill(color).frame(height: 3) } }
                .overlay(alignment: .topTrailing) {
                    EditorMediaCardActions(items: actions, available: actionWidth).padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    EditorMediaTimeBadge(text: RecordingSourcePresentation.duration(knownDuration ?? duration)).padding(4)
                }
            }
            HStack(spacing: 5) {
                if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8) }
                Text(name).font(.appUI(size: 12)).lineLimit(1)
            }.foregroundStyle(EditorTheme.primaryText)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = inside }
        }
        .contentShape(Rectangle()).onTapGesture(count: 2, perform: insert)
        .simultaneousGesture(TapGesture().onEnded { select() })
        .onDrag { EditorMediaDrag.provider(for: .recording(source.id)) }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(appLocalized("插入到主轨")), insert)
        .task(id: url) {
            guard let url else { return }
            if let track = try? await TimelinePreviewCompositionLoader.loadTrack(at: url, mediaType: .video, role: "录制") {
                duration = track.timeRange.duration.seconds
            }
        }
    }
}

extension EditorStore {
    func renameRecordingSource(_ sourceID: UUID) {
        guard sourceID != RecordingSource.primaryID, let source = project.source(sourceID) else { return }
        Task { @MainActor in
            let response = await AppDialogPresenter.response(to: AppDialog(
                title: "重命名录制", message: "", symbol: "pencil", input: source.name,
                inputPlaceholder: "录制名称",
                actions: [.init(id: "cancel", title: "取消", role: .cancel),
                          .init(id: "rename", title: "保存", role: .primary, requiresInput: true)]))
            let name = response.input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response.actionID == "rename", !name.isEmpty,
                  let index = project.additionalSources.firstIndex(where: { $0.id == sourceID }) else { return }
            var updated = project
            updated.additionalSources[index].name = name
            do { try replaceProject(with: updated, actionName: "重命名录制") }
            catch { reportError?(appErrorDescription(error)) }
        }
    }

    func removeRecordingSource(_ sourceID: UUID) {
        removeProjectMedia(recordings: [sourceID])
    }

    /// One bin selection produces one confirmation and one undoable edit.
    func removeProjectMedia(assets: Set<UUID> = [], recordings: Set<UUID>, completion: @escaping () -> Void = {}) {
        let ids = recordings.subtracting([RecordingSource.primaryID])
        guard !isRemovingProjectMedia, !ids.isEmpty || !assets.isEmpty else { return }
        isRemovingProjectMedia = true
        Task { @MainActor in
            defer { isRemovingProjectMedia = false }
            let usage = ids.reduce(0) { $0 + RecordingSourceEditing.usageCount($1, in: project.timeline.sourceSequence) }
            if usage > 0 {
                let answer = await AppDialogPresenter.response(to: AppDialog(
                    title: String(format: appLocalized("有 %ld 段在用，一起删除？"), usage),
                    message: "录制及其时间线片段会一起移除，⌘Z 可撤销。", symbol: "trash",
                    actions: [.init(id: "cancel", title: "取消", role: .cancel),
                              .init(id: "remove", title: "一起删除", role: .destructive)]))
                guard answer.actionID == "remove" else { return }
            }
            do {
                var updated = project
                let durations = recordingDurations()
                for source in project.additionalSources where ids.contains(source.id) {
                    updated = try RecordingSourceEditing.removing(source.id, from: updated, sourceDurations: durations)
                }
                updated.timeline.mediaAssets.removeAll { assets.contains($0.id) }
                try replaceProject(with: updated, actionName: ids.isEmpty ? "移除素材" : "从项目移除录制")
                if !ids.isEmpty { selection = .screen }
                completion()
            } catch { reportError?(appErrorDescription(error)) }
        }
    }
}

extension EditorView {
    /// `sourceRange` is the span of the recording to insert, as marked in the
    /// monitor; nil inserts the whole recording.
    func insertRecordingSource(_ sourceID: UUID, at requestedTime: TimeInterval?,
                               sourceRange: ClosedRange<TimeInterval>? = nil) {
        playbackController.pause()
        let time = requestedTime ?? playbackController.outputTime
        Task { @MainActor in
            do {
                guard let source = editorStore.project.source(sourceID), let url = RecordingSourcePresentation.url(source) else {
                    throw RecordingImportError.missingRecording
                }
                let generation = editorStore.recordingImportGeneration
                let track = try await TimelinePreviewCompositionLoader.loadTrack(at: url, mediaType: .video, role: "录制")
                guard generation == editorStore.recordingImportGeneration, editorStore.project.source(sourceID) == source else {
                    throw RecordingImportError.changed
                }
                var durations = mediaSession.sourceDurations
                durations[sourceID] = track.timeRange.duration.seconds
                let replacement = try RecordingSourceEditing.insertingFullRecording(sourceID, into: editorStore.project,
                    atOutputTime: time, sourceDurations: durations, sourceRange: sourceRange)
                try editorStore.replaceProject(with: replacement, actionName: "插入录制")
            } catch { hostActions.reportError(appErrorDescription(error)) }
        }
    }
}
