import AppKit
import RecorderCore
import SwiftUI

private enum EditorClipPayload: Codable {
    case primary([RecordingSegment], [UUID: PrimarySegmentAudioOverrides])
    case zoom(ZoomAnimationClip)
    case screen(ScreenMotionClip)
    case camera(CameraMotionClip)
    case mosaic(MosaicClip)
    case sticker(StickerClip)
    case animation(AnimationClip)
    case audio(AudioClip)
    case subtitle(SubtitleCue)
    case video(VideoClip)

    var duration: TimeInterval {
        switch self {
        case let .primary(segments, _): segments.reduce(0) { $0 + $1.outputDuration }
        case let .zoom(clip): clip.duration
        case let .screen(clip): clip.timing.duration
        case let .camera(clip): clip.timing.duration
        case let .mosaic(clip): clip.timing.duration
        case let .sticker(clip): clip.timing.duration
        case let .animation(clip): clip.timing.duration
        case let .audio(clip): clip.timing.duration
        case let .subtitle(cue): cue.timing.duration
        case let .video(clip): clip.timing.duration
        }
    }

    func supportsAttributes(_ selection: EditorSelection?) -> Bool {
        switch (self, selection) {
        case (.zoom, .zoom), (.screen, .screenMotion), (.camera, .cameraMotion),
             (.mosaic, .mosaic), (.sticker, .sticker), (.animation, .animation), (.audio, .audioClip): true
        default: false
        }
    }
}

private struct LegacyEditorCopiedClip: Decodable {
    let payload: EditorClipPayload
    let stickerSourceURL: URL?
    var projectURL: URL?
    var sessionID: EditorSessionID?
}

private struct EditorCopiedSelection: Codable {
    struct Item: Codable {
        let start: TimeInterval
        let payload: EditorClipPayload
        var stickerSourceURL: URL?
    }

    let items: [Item]
    let projectURL: URL?
    let sessionID: EditorSessionID?

    var attributeSource: EditorClipPayload? {
        items.count == 1 ? items[0].payload : nil
    }
}

private enum EditorClipPasteError: LocalizedError {
    case insufficientSpace, occupiedLane, unavailableImage, unavailableCamera, changedDuringImport, differentProject
    var errorDescription: String? {
        switch self {
        case .insufficientSpace: appLocalized("此位置到片尾的时长不足，无法粘贴完整片段。请选择更靠前的位置。")
        case .occupiedLane: appLocalized("此处已有同轨道动画，无法粘贴完整片段。请在足够长的空白处粘贴。")
        case .unavailableImage: appLocalized("复制的贴图源文件已不可用，请重新复制该贴图。")
        case .unavailableCamera: appLocalized("当前项目没有摄像头素材，无法粘贴摄像运动片段。")
        case .changedDuringImport: appLocalized("导入贴图期间时间线已改变，请重新粘贴。")
        case .differentProject: appLocalized("请在原项目内粘贴主轨道片段；跨项目请使用“导入录屏项目”。")
        }
    }
}

/// One clipboard snapshot supports two commands: duplicate the full authored
/// clip, or transfer attributes into a compatible selection without retiming it.
@MainActor
final class EditorClipClipboard {
    static let shared = EditorClipClipboard()
    private let pasteboard: NSPasteboard
    private var cachedChangeCount: Int?
    private var cachedSelection: EditorCopiedSelection?
    private let maximumPayloadSize = 16 * 1_024 * 1_024
    private let pasteboardType = NSPasteboard.PasteboardType("cn.laogou.dogsc.timeline-clips.v3")
    private let legacyType = NSPasteboard.PasteboardType("cn.laogou.dogsc.timeline-clip.v2")

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var hasClip: Bool { copiedSelection() != nil }

    func supportsAttributes(_ selection: EditorSelection?) -> Bool {
        copiedSelection()?.attributeSource?.supportsAttributes(selection) == true
    }

    static func isClip(_ selection: EditorSelection?) -> Bool {
        switch selection {
        case .primarySegment, .zoom, .screenMotion, .cameraMotion, .mosaic, .sticker, .animation, .audioClip, .subtitle, .videoClip: true
        default: false
        }
    }

    func copy(from store: EditorStore, selections: Set<EditorSelection>, context: EditorSessionContext) throws {
        try store.commitInteraction()
        let timeline = store.project.timeline
        var items: [EditorCopiedSelection.Item] = []
        let primaryIDs = Set(selections.compactMap { selection -> UUID? in
            if case let .primarySegment(id) = selection { return id }
            return nil
        })
        if !primaryIDs.isEmpty {
            let map = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: store.recordingDurations())
            // A primary-only copy has always packed the selected cuts together.
            // In a mixed selection keep each run aligned with the timed tracks.
            var runs: [[ResolvedRecordingSegment]] = []
            var startsRun = true
            for segment in map.segments {
                guard primaryIDs.contains(segment.id) else {
                    startsRun = primaryIDs.count != selections.count
                    continue
                }
                if startsRun || runs.isEmpty { runs.append([]) }
                runs[runs.count - 1].append(segment)
                startsRun = false
            }
            for run in runs {
                let segments = run.map {
                    RecordingSegment(id: $0.id, sourceStart: $0.sourceStart, sourceDuration: $0.sourceDuration,
                                     playbackRate: $0.playbackRate, media: $0.media, sourceID: $0.sourceID,
                                     sceneStyle: $0.sceneStyle, crop: $0.crop)
                }
                var overrides: [UUID: PrimarySegmentAudioOverrides] = [:]
                for segment in segments { overrides[segment.id] = timeline.primarySegmentAudioOverrides[segment.id] }
                items.append(.init(start: run[0].outputStart, payload: .primary(segments, overrides)))
            }
        }
        for clip in timeline.zoomClips where selections.contains(.zoom(clip.id)) {
            items.append(.init(start: clip.startTime, payload: .zoom(clip)))
        }
        for clip in timeline.screenMotionClips where selections.contains(.screenMotion(clip.id)) {
            items.append(.init(start: clip.timing.startTime, payload: .screen(clip)))
        }
        for clip in timeline.cameraMotionClips where selections.contains(.cameraMotion(clip.id)) {
            items.append(.init(start: clip.timing.startTime, payload: .camera(clip)))
        }
        for clip in timeline.mosaicClips where selections.contains(.mosaic(clip.id)) {
            items.append(.init(start: clip.timing.startTime, payload: .mosaic(clip)))
        }
        for clip in timeline.audioClips where selections.contains(.audioClip(clip.id)) {
            items.append(.init(start: clip.timing.startTime, payload: .audio(clip)))
        }
        for cue in timeline.subtitleCues where selections.contains(.subtitle(cue.id)) {
            items.append(.init(start: cue.timing.startTime, payload: .subtitle(cue)))
        }
        // Allocate destination visual layers back to front, even when the
        // upper clip starts earlier than the lower one.
        var visuals: [(layer: Int, rank: Int, id: String, item: EditorCopiedSelection.Item)] = []
        for clip in timeline.videoClips where selections.contains(.videoClip(clip.id)) {
            visuals.append((clip.layerIndex, 0, clip.id.uuidString, .init(start: clip.timing.startTime, payload: .video(clip))))
        }
        for clip in timeline.stickerClips where selections.contains(.sticker(clip.id)) {
            visuals.append((clip.layerIndex, 1, clip.id.uuidString, .init(start: clip.timing.startTime, payload: .sticker(clip),
                                                                        stickerSourceURL: context.projectAssetURL(for: clip.relativePath))))
        }
        for clip in timeline.animationClips where selections.contains(.animation(clip.id)) {
            visuals.append((clip.layerIndex, 2, clip.id.uuidString, .init(start: clip.timing.startTime, payload: .animation(clip))))
        }
        items += visuals.sorted { ($0.layer, $0.rank, $0.id) < ($1.layer, $1.rank, $1.id) }.map(\.item)
        guard !items.isEmpty else { return }
        let snapshot = EditorCopiedSelection(items: items, projectURL: context.hostActions.projectPackageURL()?.standardizedFileURL,
                                             sessionID: store.sessionID)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumPayloadSize else { throw CocoaError(.fileReadTooLarge) }
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: pasteboardType) else { throw CocoaError(.fileWriteUnknown) }
    }

    func pasteAttributes(into store: EditorStore, selection: EditorSelection?) throws {
        guard let selection, let source = copiedSelection()?.attributeSource, source.supportsAttributes(selection) else { return }
        try store.commitInteraction()
        var timeline = store.project.timeline
        switch (source, selection) {
        case let (.zoom(source), .zoom(id)):
            guard let index = timeline.zoomClips.firstIndex(where: { $0.id == id }) else { return }
            let target = timeline.zoomClips[index]
            var copy = source
            copy.id = target.id
            copy.startTime = target.startTime
            copy.endTime = target.endTime
            copy.enterDuration = source.preferredEnterDuration ?? source.enterDuration
            copy.exitDuration = source.preferredExitDuration ?? source.exitDuration
            copy.preferredEnterDuration = copy.enterDuration
            copy.preferredExitDuration = copy.exitDuration
            copy.enterProgressOffset = 0
            copy.exitProgressOffset = 0
            timeline.zoomClips[index] = copy
        case let (.screen(source), .screenMotion(id)):
            guard let index = timeline.screenMotionClips.firstIndex(where: { $0.id == id }) else { return }
            let target = timeline.screenMotionClips[index]
            var copy = source
            copy.id = target.id
            copy.groupID = target.groupID
            preservePlacement(of: target.timing, in: &copy.timing)
            timeline.screenMotionClips[index] = copy
        case let (.camera(source), .cameraMotion(id)):
            guard let index = timeline.cameraMotionClips.firstIndex(where: { $0.id == id }) else { return }
            let target = timeline.cameraMotionClips[index]
            var copy = source
            copy.id = target.id
            copy.groupID = target.groupID
            preservePlacement(of: target.timing, in: &copy.timing)
            timeline.cameraMotionClips[index] = copy
        case let (.mosaic(source), .mosaic(id)):
            guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else { return }
            var copy = source
            copy.id = id
            copy.timing = timeline.mosaicClips[index].timing
            timeline.mosaicClips[index] = copy
        case let (.sticker(source), .sticker(id)):
            guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else { return }
            let target = timeline.stickerClips[index]
            var copy = source
            copy.id = target.id
            copy.timing = target.timing
            copy.relativePath = target.relativePath
            copy.layerIndex = target.layerIndex
            timeline.stickerClips[index] = copy
        case let (.animation(source), .animation(id)):
            guard let index = timeline.animationClips.firstIndex(where: { $0.id == id }) else { return }
            let target = timeline.animationClips[index]
            var copy = source
            copy.id = target.id
            copy.timing = target.timing
            copy.sourcePath = target.sourcePath
            copy.layerIndex = target.layerIndex
            copy.timeOffset = target.timeOffset
            copy.playbackRate = target.playbackRate
            copy.soundtrack = target.soundtrack
            copy.mainTrackStyle = target.mainTrackStyle
            timeline.animationClips[index] = copy
        case let (.audio(source), .audioClip(id)):
            guard let index = timeline.audioClips.firstIndex(where: { $0.id == id }) else { return }
            timeline.audioClips[index].volume = source.volume
            timeline.audioClips[index].fadeIn = source.fadeIn
            timeline.audioClips[index].fadeOut = source.fadeOut
            timeline.audioClips[index].kind = source.kind
        default: return
        }
        try finishPlacement(in: &timeline, selections: [selection], includePredecessor: false,
                            defaultTransition: store.project.motion.defaultZoomTransitionDuration)
        try store.replaceTimeline(with: timeline, actionName: appLocalized("粘贴属性"))
        store.selection = selection
    }

    func pasteClip(into store: EditorStore, context: EditorSessionContext,
                   at proposedTime: TimeInterval, outputDuration: TimeInterval,
                   frameDuration: TimeInterval, edgeTolerance: TimeInterval) async throws
        -> (selections: [EditorSelection], startTime: TimeInterval)? {
        guard let copied = copiedSelection(), let first = copied.items.min(by: { $0.start < $1.start }) else { return nil }
        try Task.checkCancellation()
        try store.commitInteraction()
        let before = store.project.timeline
        var timeline = before
        let includesPrimary = copied.items.contains { if case .primary = $0.payload { true } else { false } }
        let span = copied.items.reduce(0.0) { max($0, ($1.start - first.start) + $1.payload.duration) }
        var start = insertionTime(for: first.payload, in: before, proposed: proposedTime, outputDuration: outputDuration,
                                  span: includesPrimary ? first.payload.duration : span,
                                  frameDuration: frameDuration, edgeTolerance: edgeTolerance)
        var end = outputDuration
        var pasted: [EditorSelection] = []
        let sourceDurations = store.recordingDurations()
        // Ripple the destination first. All timed clips then use one translation
        // from the copied group's earliest start on the final output clock.
        for item in copied.items {
            guard case let .primary(originals, overrides) = item.payload else { continue }
            guard copied.sessionID == store.sessionID || (copied.projectURL != nil &&
                    copied.projectURL == context.hostActions.projectPackageURL()?.standardizedFileURL) else {
                throw EditorClipPasteError.differentProject
            }
            let map = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: sourceDurations)
            let offset = item.start - first.start
            let proposed = start + offset
            if offset > 0, proposed > map.outputDuration + 0.000_001 { throw EditorClipPasteError.insufficientSpace }
            let time = RecordingProjectImport.insertionTime(proposed, map: map)
            if pasted.isEmpty { start = time - offset }
            var copiedOverrides: [UUID: PrimarySegmentAudioOverrides] = [:]
            let segments = originals.map { original in
                var segment = original
                segment.id = UUID()
                copiedOverrides[segment.id] = overrides[original.id]
                return segment
            }
            timeline = try ProjectTimelineEditing.insertPrimarySegments(in: timeline, segments: segments,
                audioOverrides: copiedOverrides, atOutputTime: time, sourceDurations: sourceDurations)
            end = map.outputDuration + item.payload.duration
            pasted += segments.map { .primarySegment($0.id) }
        }
        var imports: [ImportedProjectOverlayAsset] = []
        var screenGroups: Set<UUID> = []
        var cameraGroups: Set<UUID> = []
        for item in copied.items {
            switch item.payload {
            case let .screen(clip): if let group = clip.groupID { screenGroups.insert(group) }
            case let .camera(clip): if let group = clip.groupID { cameraGroups.insert(group) }
            default: break
            }
        }
        let newGroups = Dictionary(uniqueKeysWithValues: screenGroups.intersection(cameraGroups).map { ($0, UUID()) })
        do {
            for item in copied.items {
                if case .primary = item.payload { continue }
                try Task.checkCancellation()
                let time = start + (item.start - first.start)
                let length = item.payload.duration
                guard time.isFinite, length.isFinite, time >= 0, length > 0,
                      time + length <= end + 0.000_001 else { throw EditorClipPasteError.insufficientSpace }
                let selection = try await appendTimedClip(item, at: time, to: &timeline, store: store, context: context,
                                                          newGroups: newGroups, imports: &imports)
                pasted.append(selection)
            }
            try Task.checkCancellation()
            timeline.isolateCopiedVideoAudio(ids: Set(pasted.compactMap {
                switch $0 {
                case let .primarySegment(id), let .videoClip(id), let .audioClip(id): id
                default: nil
                }
            }))
            try finishPlacement(in: &timeline, selections: pasted, includePredecessor: true,
                                defaultTransition: store.project.motion.defaultZoomTransitionDuration)
            guard store.project.timeline == before else { throw EditorClipPasteError.changedDuringImport }
            try store.replaceTimeline(with: timeline, actionName: appLocalized("粘贴片段"))
            store.selection = pasted.first
            return (pasted, start)
        } catch {
            for asset in imports { try? await context.projectAssetTransfer.discard(asset) }
            throw error
        }
    }

    private func appendTimedClip(_ item: EditorCopiedSelection.Item, at time: TimeInterval,
                                 to timeline: inout ProjectTimeline, store: EditorStore, context: EditorSessionContext,
                                 newGroups: [UUID: UUID], imports: inout [ImportedProjectOverlayAsset]) async throws -> EditorSelection {
        let id = UUID()
        switch item.payload {
        case .primary: throw ProjectTimelineEditingError.invalidSourceSequence
        case var .zoom(clip):
            clip.id = id
            clip.startTime = time
            clip.endTime = time + item.payload.duration
            timeline.zoomClips.append(clip)
            return .zoom(id)
        case var .screen(clip):
            clip.id = id
            clip.groupID = clip.groupID.flatMap { newGroups[$0] }
            clip.timing.startTime = time
            timeline.screenMotionClips.append(clip)
            return .screenMotion(id)
        case var .camera(clip):
            guard context.media.camera != nil || store.project.sources.contains(where: { $0.media.camera != nil })
            else { throw EditorClipPasteError.unavailableCamera }
            clip.id = id
            clip.groupID = clip.groupID.flatMap { newGroups[$0] }
            clip.timing.startTime = time
            timeline.cameraMotionClips.append(clip)
            return .cameraMotion(id)
        case var .mosaic(clip):
            clip.id = id
            clip.timing.startTime = time
            timeline.mosaicClips.append(clip)
            return .mosaic(id)
        case var .sticker(clip):
            guard let sourceURL = item.stickerSourceURL, sourceURL.isFileURL,
                  FileManager.default.fileExists(atPath: sourceURL.path) else { throw EditorClipPasteError.unavailableImage }
            let destinationURL = context.projectAssetURL(for: clip.relativePath)
            if destinationURL?.standardizedFileURL != sourceURL.standardizedFileURL {
                let asset = try await context.projectAssetTransfer.importOverlayAsset(from: sourceURL)
                imports.append(asset)
                clip.relativePath = asset.relativePath
            }
            clip.id = id
            clip.timing.startTime = time
            clip.layerIndex = timeline.visualLayer(for: clip.timing)
            timeline.stickerClips.append(clip)
            return .sticker(id)
        case var .animation(clip):
            clip.id = id
            clip.timing.startTime = time
            clip.layerIndex = timeline.visualLayer(for: clip.timing)
            timeline.animationClips.append(clip)
            return .animation(id)
        case var .audio(clip):
            clip.id = id
            clip.timing.startTime = time
            timeline.audioClips.append(clip)
            return .audioClip(id)
        case var .subtitle(cue):
            cue.id = id
            cue.timing.startTime = time
            timeline.subtitleCues.append(cue)
            return .subtitle(id)
        case var .video(clip):
            clip.id = id
            clip.timing.startTime = time
            clip.layerIndex = timeline.visualLayer(for: clip.timing)
            timeline.videoClips.append(clip)
            return .videoClip(id)
        }
    }

    /// Preserve exact authored edges before quantizing an ordinary insertion
    /// to frames. Source cuts and retiming can leave valid fractional edges.
    private func insertionTime(for payload: EditorClipPayload, in timeline: ProjectTimeline,
                               proposed: TimeInterval, outputDuration: TimeInterval,
                               span: TimeInterval, frameDuration: TimeInterval, edgeTolerance: TimeInterval) -> TimeInterval {
        guard proposed.isFinite, frameDuration.isFinite, frameDuration > 0 else { return proposed }
        let intervals: [(start: TimeInterval, end: TimeInterval)]
        let exclusive: Bool
        switch payload {
        case .primary: return proposed
        case .zoom:
            intervals = timeline.zoomClips.map { ($0.startTime, $0.endTime) }; exclusive = true
        case .screen:
            intervals = timeline.screenMotionClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = true
        case .camera:
            intervals = timeline.cameraMotionClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = true
        case .mosaic:
            intervals = timeline.mosaicClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = false
        case .sticker:
            intervals = timeline.stickerClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = false
        case .animation:
            intervals = timeline.animationClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = false
        case .audio:
            intervals = timeline.audioClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = false
        case .subtitle:
            intervals = timeline.subtitleCues.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = true
        case .video:
            intervals = timeline.videoClips.map { ($0.timing.startTime, $0.timing.endTime) }; exclusive = false
        }
        let length = payload.duration
        let tolerance = max(edgeTolerance, frameDuration / 2)
        // Either append at an existing end, or fit the full duplicate directly
        // before the next start. Never choose a nearby but occupied candidate.
        var candidates: [TimeInterval] = [0, outputDuration - span]
        for interval in intervals {
            candidates.append(interval.end)
            candidates.append(interval.start - length)
        }
        let target = candidates.filter { start in
            start.isFinite && start >= 0 && start + span <= outputDuration + 0.000_001
                && abs(start - proposed) <= tolerance
                && (!exclusive || !intervals.contains { start < $0.end - 0.000_001 && start + length > $0.start + 0.000_001 })
        }.min { abs($0 - proposed) < abs($1 - proposed) }
        if let target { return target }
        return (proposed / frameDuration).rounded() * frameDuration
    }

    private func preservePlacement(of target: TransitionTiming, in copied: inout TransitionTiming) {
        copied.startTime = target.startTime
        copied.duration = target.duration
        copied.leadInDuration = copied.preferredLeadInDuration ?? copied.leadInDuration
        copied.returnDuration = copied.preferredReturnDuration ?? copied.returnDuration
        copied.preferredLeadInDuration = copied.leadInDuration
        copied.preferredReturnDuration = copied.returnDuration
        copied.leadInProgressOffset = 0
        copied.returnProgressOffset = 0
    }

    // Fit only the effective return window at the newly affected junction.
    // Keep requested duration, all main clip bounds and the neighbour's target.
    private func finishPlacement(in timeline: inout ProjectTimeline, selections: [EditorSelection],
                                 includePredecessor: Bool, defaultTransition: TimeInterval) throws {
        var zoom: Set<UUID> = [], screen: Set<UUID> = [], camera: Set<UUID> = [], subtitles: Set<UUID> = []
        for selection in selections {
            switch selection {
            case let .zoom(id): zoom.insert(id)
            case let .screenMotion(id): screen.insert(id)
            case let .cameraMotion(id): camera.insert(id)
            case let .subtitle(id): subtitles.insert(id)
            default: break
            }
        }
        func affected(_ left: UUID, _ right: UUID, in ids: Set<UUID>) -> Bool {
            ids.contains(left) || (includePredecessor && ids.contains(right))
        }
        if !zoom.isEmpty {
            timeline.zoomClips.sort { $0.startTime < $1.startTime }
            for i in timeline.zoomClips.indices.dropLast() where affected(timeline.zoomClips[i].id, timeline.zoomClips[i + 1].id, in: zoom) {
                let gap = timeline.zoomClips[i + 1].startTime - timeline.zoomClips[i].endTime
                if gap < -0.000_001 { throw EditorClipPasteError.occupiedLane }
                if gap > ZoomInterpolator.adjacencyTolerance, gap < timeline.zoomClips[i].exitDuration {
                    timeline.zoomClips[i].preserveTransitionIntent(defaultTransition: defaultTransition)
                    timeline.zoomClips[i].exitDuration = gap
                }
            }
        }
        func fitMotion<C: Identifiable>(_ clips: inout [C], timing: WritableKeyPath<C, TransitionTiming>,
                                        ids: Set<UUID>) throws where C.ID == UUID {
            guard !ids.isEmpty else { return }
            clips.sort { $0[keyPath: timing].startTime < $1[keyPath: timing].startTime }
            for i in clips.indices.dropLast() where affected(clips[i].id, clips[i + 1].id, in: ids) {
                let gap = clips[i + 1][keyPath: timing].startTime - clips[i][keyPath: timing].endTime
                if gap < -0.000_001 { throw EditorClipPasteError.occupiedLane }
                fitReturn(&clips[i][keyPath: timing], gap: gap, defaultTransition: defaultTransition)
            }
        }
        try fitMotion(&timeline.screenMotionClips, timing: \.timing, ids: screen)
        try fitMotion(&timeline.cameraMotionClips, timing: \.timing, ids: camera)
        if !subtitles.isEmpty {
            // Imported cues may already overlap. Preserve overlaps within the
            // copied material, while protecting every existing destination cue.
            timeline.subtitleCues.sort { $0.timing.startTime < $1.timing.startTime }
            var existingEnd = -TimeInterval.infinity, pastedEnd = -TimeInterval.infinity
            for cue in timeline.subtitleCues {
                let isPasted = subtitles.contains(cue.id)
                if cue.timing.startTime < (isPasted ? existingEnd : pastedEnd) - 0.000_001 {
                    throw EditorClipPasteError.occupiedLane
                }
                if isPasted { pastedEnd = max(pastedEnd, cue.timing.endTime) }
                else { existingEnd = max(existingEnd, cue.timing.endTime) }
            }
        }
    }

    private func fitReturn(_ timing: inout TransitionTiming, gap: TimeInterval, defaultTransition: TimeInterval) {
        if gap > ZoomInterpolator.adjacencyTolerance, gap < timing.returnDuration {
            timing.preserveTransitionIntent(defaultTransition: defaultTransition)
            timing.returnDuration = gap
        }
    }

    private func copiedSelection() -> EditorCopiedSelection? {
        let changeCount = pasteboard.changeCount
        if cachedChangeCount != changeCount {
            cachedChangeCount = changeCount
            cachedSelection = readSelection()
        }
        return cachedSelection
    }

    private func readSelection() -> EditorCopiedSelection? {
        let decoder = JSONDecoder()
        if let data = pasteboard.data(forType: pasteboardType), data.count <= maximumPayloadSize,
           let snapshot = try? decoder.decode(EditorCopiedSelection.self, from: data), !snapshot.items.isEmpty {
            return snapshot
        }
        guard let data = pasteboard.data(forType: legacyType), data.count <= maximumPayloadSize,
              let clip = try? decoder.decode(LegacyEditorCopiedClip.self, from: data) else { return nil }
        return .init(items: [.init(start: 0, payload: clip.payload, stickerSourceURL: clip.stickerSourceURL)],
                     projectURL: clip.projectURL, sessionID: clip.sessionID)
    }
}

extension EditorTimelineView {
    var clipboardInsertionTime: TimeInterval {
        guard let window = timelineScrollView?.window else {
            return playbackController.outputTime
        }
        return clipboardTime(at: window.mouseLocationOutsideOfEventStream, in: window)
            ?? playbackController.outputTime
    }

    /// Read the physical pointer when the command runs: the last mouse-moved
    /// event can be stale after the pointer leaves the editor window.
    func clipboardTime(at windowPoint: NSPoint, in window: NSWindow?) -> TimeInterval? {
        guard !editorStore.cropPresentation.isActive,
              let scrollView = timelineScrollView, window === scrollView.window else { return nil }
        let point = scrollView.convert(windowPoint, from: nil)
        guard scrollView.visibleRect.contains(point), scrollView.bounds.contains(point) else { return nil }
        let contentX = point.x - scrollView.bounds.minX + scrollView.documentVisibleRect.minX
        return EditorTimelineMath.clampedTime(
            atX: Double(contentX), width: Double(max(timelineContentWidth, 1)), duration: timelineDuration)
    }

    func timelineCopyTargets(clicked: EditorSelection? = nil) -> Set<EditorSelection> {
        Self.timelineCopyTargets(focus: editorStore.selection, items: multiSelection,
                                 primaryIDs: selectedPrimarySegmentIDs, clicked: clicked)
    }

    static func timelineCopyTargets(focus: EditorSelection?, items: Set<EditorSelection>,
                                    primaryIDs: Set<UUID>, clicked: EditorSelection?) -> Set<EditorSelection> {
        var targets = items.union(primaryIDs.map(EditorSelection.primarySegment))
        if targets.isEmpty, let focus, EditorClipClipboard.isClip(focus) { targets.insert(focus) }
        if let clicked, !targets.contains(clicked) { return [clicked] }
        return targets
    }

    func copyTimelineClips(_ targets: Set<EditorSelection>) {
        do { try clipClipboard.copy(from: editorStore, selections: targets, context: context) }
        catch { onError(error.localizedDescription) }
    }

    func pasteTimelineAttributes(_ selection: EditorSelection?) {
        do { try clipClipboard.pasteAttributes(into: editorStore, selection: selection) }
        catch { onError(error.localizedDescription) }
    }

    func pasteTimelineClip(at time: TimeInterval) {
        guard clipPasteTask == nil else { return }
        let duration = timelineDuration
        let edgeTolerance = isSnappingEnabled ? 7 * duration / Double(max(timelineContentWidth, 1)) : 0
        playbackController.pause()
        clipPasteTask = Task { @MainActor in
            defer { clipPasteTask = nil }
            do {
                guard let pasted = try await clipClipboard.pasteClip(
                    into: editorStore, context: context, at: time, outputDuration: duration,
                    frameDuration: timelineFrameDuration, edgeTolerance: edgeTolerance) else { return }
                selectedPrimarySegmentIDs = Set(pasted.selections.compactMap {
                    if case let .primarySegment(id) = $0 { return id }
                    return nil
                })
                multiSelection = pasted.selections.count > 1 ? Set(pasted.selections.filter(Self.isGroupSelectable)) : []
                revealPastedTracks(pasted.selections)
                playbackController.seek(to: pasted.startTime, pausing: true)
                scrollTimelineToEndpointIfNeeded(pasted.startTime)
            } catch is CancellationError { }
            catch { onError(error.localizedDescription) }
        }
    }

    private func revealPastedTracks(_ selections: [EditorSelection]) {
        var lanes: Set<TimelinePostLane> = []
        for selection in selections {
            switch selection {
            case .zoom: visibleTracks.insert(.zoom)
            case .screenMotion: visibleTracks.insert(.screenMotion)
            case .cameraMotion: visibleTracks.insert(.cameraMotion)
            case .mosaic: lanes.insert(.effects)
            case .sticker, .animation, .videoClip: lanes.insert(.layers)
            case .audioClip: lanes.insert(.audio)
            case .subtitle: lanes.insert(.subtitles)
            default: break
            }
        }
        for lane in lanes { setPostLane(lane, visible: true) }
        let groups = lanes.intersection([.effects, .layers])
        if !groups.isEmpty {
            visibleTracks.insert(.overlays)
            collapsedTimelineGroupsRaw = collapsedLaneGroups.subtracting(groups.map(\.rawValue)).sorted().joined(separator: ",")
        }
        if lanes.contains(.layers) { showsAllOverlayLayers = true }
    }

    @ViewBuilder func clipClipboardMenu(for selection: EditorSelection) -> some View {
        Button("复制片段") { copyTimelineClips(timelineCopyTargets(clicked: selection)) }
            .keyboardShortcut("c", modifiers: .command)
        Button("粘贴片段") { pasteTimelineClip(at: clipboardContextTime ?? clipboardInsertionTime) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!clipClipboard.hasClip)
        Button("粘贴属性") { pasteTimelineAttributes(selection) }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!clipClipboard.supportsAttributes(selection))
    }
}
