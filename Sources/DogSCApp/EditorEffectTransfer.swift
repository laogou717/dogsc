import AppKit
import RecorderCore
import SwiftUI

private enum EditorClipPayload: Codable {
    case zoom(ZoomAnimationClip)
    case screen(ScreenMotionClip)
    case camera(CameraMotionClip)
    case mosaic(MosaicClip)
    case sticker(StickerClip)

    var duration: TimeInterval {
        switch self {
        case let .zoom(clip): clip.duration
        case let .screen(clip): clip.timing.duration
        case let .camera(clip): clip.timing.duration
        case let .mosaic(clip): clip.timing.duration
        case let .sticker(clip): clip.timing.duration
        }
    }

    func supportsAttributes(_ selection: EditorSelection?) -> Bool {
        switch (self, selection) {
        case (.zoom, .zoom), (.screen, .screenMotion), (.camera, .cameraMotion),
             (.mosaic, .mosaic), (.sticker, .sticker): true
        default: false
        }
    }
}

private struct EditorCopiedClip: Codable {
    let payload: EditorClipPayload
    let stickerSourceURL: URL?
}

private enum EditorClipPasteError: LocalizedError {
    case insufficientSpace, occupiedLane, unavailableImage, unavailableCamera, changedDuringImport
    var errorDescription: String? {
        switch self {
        case .insufficientSpace: appLocalized("此位置到片尾的时长不足，无法粘贴完整片段。请选择更靠前的位置。")
        case .occupiedLane: appLocalized("此处已有同轨道动画，无法粘贴完整片段。请在足够长的空白处粘贴。")
        case .unavailableImage: appLocalized("复制的贴图源文件已不可用，请重新复制该贴图。")
        case .unavailableCamera: appLocalized("当前项目没有摄像头素材，无法粘贴摄像运动片段。")
        case .changedDuringImport: appLocalized("导入贴图期间时间线已改变，请重新粘贴。")
        }
    }
}

/// One clipboard snapshot supports two commands: duplicate the full authored
/// clip, or transfer attributes into a compatible selection without retiming it.
@MainActor
final class EditorClipClipboard {
    static let shared = EditorClipClipboard()
    private let pasteboardType = NSPasteboard.PasteboardType("cn.laogou.dogsc.timeline-clip.v2")

    var hasClip: Bool { copiedClip() != nil }
    func supportsAttributes(_ selection: EditorSelection?) -> Bool {
        copiedClip()?.payload.supportsAttributes(selection) == true
    }

    static func isClip(_ selection: EditorSelection?) -> Bool {
        switch selection {
        case .zoom, .screenMotion, .cameraMotion, .mosaic, .sticker: true
        default: false
        }
    }

    func copy(from store: EditorStore, selection: EditorSelection?,
              context: EditorSessionContext) throws {
        try store.commitInteraction()
        let value: EditorClipPayload?
        var imageURL: URL?
        switch selection {
        case let .zoom(id):
            value = store.project.zoomAnimations.first { $0.id == id }.map(EditorClipPayload.zoom)
        case let .screenMotion(id):
            value = store.project.timeline.screenMotionClips.first { $0.id == id }.map(EditorClipPayload.screen)
        case let .cameraMotion(id):
            value = store.project.timeline.cameraMotionClips.first { $0.id == id }.map(EditorClipPayload.camera)
        case let .mosaic(id):
            value = store.project.timeline.mosaicClips.first { $0.id == id }.map(EditorClipPayload.mosaic)
        case let .sticker(id):
            let clip = store.project.timeline.stickerClips.first { $0.id == id }
            value = clip.map(EditorClipPayload.sticker)
            imageURL = clip.flatMap { context.projectAssetURL(for: $0.relativePath) }
        default: value = nil
        }
        guard let value else { return }
        let data = try JSONEncoder().encode(EditorCopiedClip(payload: value, stickerSourceURL: imageURL))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: pasteboardType)
    }

    func pasteAttributes(into store: EditorStore, selection: EditorSelection?) throws {
        guard let source = copiedClip()?.payload, source.supportsAttributes(selection) else { return }
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
        default: return
        }
        fitReturnBesideSuccessor(in: &timeline, selection: selection, includePredecessor: false,
                                 defaultTransition: store.project.motion.defaultZoomTransitionDuration)
        try store.replaceTimeline(with: timeline, actionName: appLocalized("粘贴属性"))
        store.selection = selection
    }

    func pasteClip(into store: EditorStore, context: EditorSessionContext,
                   at proposedTime: TimeInterval, outputDuration: TimeInterval,
                   frameDuration: TimeInterval, edgeTolerance: TimeInterval) async throws
        -> (selection: EditorSelection, startTime: TimeInterval)? {
        guard let copied = copiedClip() else { return nil }
        try store.commitInteraction()
        let before = store.project.timeline
        var timeline = before
        let length = copied.payload.duration
        let time = insertionTime(for: copied.payload, in: before, proposed: proposedTime,
                                 outputDuration: outputDuration, frameDuration: frameDuration,
                                 edgeTolerance: edgeTolerance)
        // Never silently shorten the copied clip or overwrite occupied effects.
        guard time.isFinite, length.isFinite, time >= 0, length > 0,
              time + length <= outputDuration + 0.000_001 else { throw EditorClipPasteError.insufficientSpace }
        let id = UUID()
        let selection: EditorSelection
        var imported: ImportedProjectOverlayAsset?
        do {
            switch copied.payload {
            case var .zoom(clip):
                try requireSpace(at: time, duration: length, intervals: timeline.zoomClips.map { ($0.startTime, $0.endTime) })
                clip.id = id
                clip.startTime = time
                clip.endTime = time + length
                timeline.zoomClips.append(clip)
                timeline.zoomClips.sort { $0.startTime < $1.startTime }
                selection = .zoom(id)
            case var .screen(clip):
                try requireSpace(at: time, duration: length, intervals: timeline.screenMotionClips.map { ($0.timing.startTime, $0.timing.endTime) })
                clip.id = id
                clip.groupID = nil
                clip.timing.startTime = time
                timeline.screenMotionClips.append(clip)
                timeline.screenMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
                selection = .screenMotion(id)
            case var .camera(clip):
                guard context.media.camera != nil else { throw EditorClipPasteError.unavailableCamera }
                try requireSpace(at: time, duration: length, intervals: timeline.cameraMotionClips.map { ($0.timing.startTime, $0.timing.endTime) })
                clip.id = id
                clip.groupID = nil
                clip.timing.startTime = time
                timeline.cameraMotionClips.append(clip)
                timeline.cameraMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
                selection = .cameraMotion(id)
            case var .mosaic(clip):
                clip.id = id
                clip.timing.startTime = time
                timeline.mosaicClips.append(clip)
                selection = .mosaic(id)
            case var .sticker(clip):
                guard let sourceURL = copied.stickerSourceURL, sourceURL.isFileURL,
                      FileManager.default.fileExists(atPath: sourceURL.path) else { throw EditorClipPasteError.unavailableImage }
                let destinationURL = context.projectAssetURL(for: clip.relativePath)
                if destinationURL?.standardizedFileURL != sourceURL.standardizedFileURL {
                    let asset = try await context.projectAssetTransfer.importOverlayAsset(from: sourceURL)
                    imported = asset
                    clip.relativePath = asset.relativePath
                }
                clip.id = id
                clip.timing.startTime = time
                clip.layerIndex = (timeline.stickerClips.map(\.layerIndex).max() ?? -1) + 1
                timeline.stickerClips.append(clip)
                selection = .sticker(id)
            }
            try Task.checkCancellation()
            fitReturnBesideSuccessor(in: &timeline, selection: selection, includePredecessor: true,
                                     defaultTransition: store.project.motion.defaultZoomTransitionDuration)
            guard store.project.timeline == before else { throw EditorClipPasteError.changedDuringImport }
            try store.replaceTimeline(with: timeline, actionName: appLocalized("粘贴片段"))
            store.selection = selection
            return (selection, time)
        } catch {
            if let imported { try? await context.projectAssetTransfer.discard(imported) }
            throw error
        }
    }

    /// Preserve exact authored edges before quantizing an ordinary insertion
    /// to frames. Source cuts and retiming can leave valid fractional edges.
    private func insertionTime(for payload: EditorClipPayload, in timeline: ProjectTimeline,
                               proposed: TimeInterval, outputDuration: TimeInterval,
                               frameDuration: TimeInterval, edgeTolerance: TimeInterval) -> TimeInterval {
        guard proposed.isFinite, frameDuration.isFinite, frameDuration > 0 else { return proposed }
        let intervals: [(start: TimeInterval, end: TimeInterval)]
        let exclusive: Bool
        switch payload {
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
        }
        let length = payload.duration
        let tolerance = max(edgeTolerance, frameDuration / 2)
        // Either append at an existing end, or fit the full duplicate directly
        // before the next start. Never choose a nearby but occupied candidate.
        var candidates: [TimeInterval] = [0, outputDuration - length]
        for interval in intervals {
            candidates.append(interval.end)
            candidates.append(interval.start - length)
        }
        let target = candidates.filter { start in
            start.isFinite && start >= 0 && start + length <= outputDuration + 0.000_001
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
    private func fitReturnBesideSuccessor(in timeline: inout ProjectTimeline, selection: EditorSelection?,
                                         includePredecessor: Bool, defaultTransition: TimeInterval) {
        func indices(_ selected: Int?) -> [Int] {
            guard let selected else { return [] }
            return includePredecessor && selected > 0 ? [selected - 1, selected] : [selected]
        }
        switch selection {
        case let .zoom(id):
            timeline.zoomClips.sort { $0.startTime < $1.startTime }
            for index in indices(timeline.zoomClips.firstIndex { $0.id == id }) where index + 1 < timeline.zoomClips.count {
                let gap = timeline.zoomClips[index + 1].startTime - timeline.zoomClips[index].endTime
                if gap > ZoomInterpolator.adjacencyTolerance, gap < timeline.zoomClips[index].exitDuration {
                    timeline.zoomClips[index].preserveTransitionIntent(defaultTransition: defaultTransition)
                    timeline.zoomClips[index].exitDuration = gap
                }
            }
        case let .screenMotion(id):
            timeline.screenMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
            for index in indices(timeline.screenMotionClips.firstIndex { $0.id == id }) where index + 1 < timeline.screenMotionClips.count {
                let gap = timeline.screenMotionClips[index + 1].timing.startTime - timeline.screenMotionClips[index].timing.endTime
                fitReturn(&timeline.screenMotionClips[index].timing, gap: gap, defaultTransition: defaultTransition)
            }
        case let .cameraMotion(id):
            timeline.cameraMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
            for index in indices(timeline.cameraMotionClips.firstIndex { $0.id == id }) where index + 1 < timeline.cameraMotionClips.count {
                let gap = timeline.cameraMotionClips[index + 1].timing.startTime - timeline.cameraMotionClips[index].timing.endTime
                fitReturn(&timeline.cameraMotionClips[index].timing, gap: gap, defaultTransition: defaultTransition)
            }
        default: break
        }
    }

    private func fitReturn(_ timing: inout TransitionTiming, gap: TimeInterval, defaultTransition: TimeInterval) {
        if gap > ZoomInterpolator.adjacencyTolerance, gap < timing.returnDuration {
            timing.preserveTransitionIntent(defaultTransition: defaultTransition)
            timing.returnDuration = gap
        }
    }

    private func requireSpace(at start: TimeInterval, duration: TimeInterval,
                              intervals: [(TimeInterval, TimeInterval)]) throws {
        if intervals.contains(where: { start < $0.1 - 0.000_001 && start + duration > $0.0 + 0.000_001 }) {
            throw EditorClipPasteError.occupiedLane
        }
    }

    private func copiedClip() -> EditorCopiedClip? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType), data.count < 65_536 else { return nil }
        return try? JSONDecoder().decode(EditorCopiedClip.self, from: data)
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

    func copyTimelineClip(_ selection: EditorSelection?) {
        do { try EditorClipClipboard.shared.copy(from: editorStore, selection: selection, context: context) }
        catch { onError(error.localizedDescription) }
    }

    func pasteTimelineAttributes(_ selection: EditorSelection?) {
        do { try EditorClipClipboard.shared.pasteAttributes(into: editorStore, selection: selection) }
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
                guard let pasted = try await EditorClipClipboard.shared.pasteClip(
                    into: editorStore, context: context, at: time, outputDuration: duration,
                    frameDuration: timelineFrameDuration, edgeTolerance: edgeTolerance) else { return }
                switch pasted.selection {
                case .zoom: visibleTracks.insert(.zoom)
                case .screenMotion: visibleTracks.insert(.screenMotion)
                case .cameraMotion: visibleTracks.insert(.cameraMotion)
                case .mosaic, .sticker: visibleTracks.insert(.overlays)
                default: break
                }
                playbackController.seek(to: pasted.startTime, pausing: true)
                scrollTimelineToEndpointIfNeeded(pasted.startTime)
            } catch is CancellationError { }
            catch { onError(error.localizedDescription) }
        }
    }

    @ViewBuilder func clipClipboardMenu(for selection: EditorSelection) -> some View {
        Button("复制片段") { copyTimelineClip(selection) }
            .keyboardShortcut("c", modifiers: .command)
        Button("粘贴片段") { pasteTimelineClip(at: clipboardContextTime ?? clipboardInsertionTime) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!EditorClipClipboard.shared.hasClip)
        Button("粘贴属性") { pasteTimelineAttributes(selection) }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!EditorClipClipboard.shared.supportsAttributes(selection))
    }
}
