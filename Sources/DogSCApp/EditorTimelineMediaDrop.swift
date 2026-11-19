import RecorderCore
import SwiftUI

extension EditorTimelineView {
    private enum MediaDropTarget {
        case main
        case overlay(TimelineLane)
    }

    private func mediaDropTarget(at point: CGPoint) -> MediaDropTarget? {
        if point.y >= primaryLaneTop && point.y < primaryLaneTop + primaryTimelineHeight { return .main }
        for lane in upperLanes + lowerLanes where point.y >= laneTop(lane) && point.y < laneTop(lane) + laneHeight(lane) {
            switch lane {
            case .layer, .audio, .groupHeader(.layers), .moreLayers: return .overlay(lane)
            default: break
            }
        }
        return nil
    }

    func updateMediaDrop(at point: CGPoint, offersOverlay: Bool) -> Bool {
        timelineMediaDragActive = offersOverlay
        mainTrackDropX = nil
        mediaDropLane = nil
        switch mediaDropTarget(at: point) {
        case .main:
            mainTrackDropX = point.x
            return true
        case let .overlay(lane) where offersOverlay:
            mediaDropLane = lane
            return true
        default: return false
        }
    }

    func clearMediaDrop() {
        timelineMediaDragActive = false
        mainTrackDropX = nil
        mediaDropLane = nil
        recordingDropPreview.end()
    }

    func prepareMediaDrop(at point: CGPoint, width: CGFloat, duration: TimeInterval) -> (@MainActor ([EditorMediaDrag.Item]) -> Void)? {
        guard let target = mediaDropTarget(at: point) else { return nil }
        let time = mainTrackDropTime(atX: point.x, width: width, duration: duration)
        return { items in
            let projects = items.compactMap { item -> URL? in
                if case let .file(url) = item, url.pathExtension.lowercased() == "dogscproject" { return url }
                return nil
            }
            // A dropped project is imported into the bin wherever it landed:
            // the drop position would have nothing to say about it.
            if !projects.isEmpty { editorStore.requestRecordingImports(projects, nil) }
            guard let item = items.first(where: {
                if case let .file(url) = $0 { return url.pathExtension.lowercased() != "dogscproject" }
                return true
            }) else { return }
            // A file dragged out of the monitor brings its in and out marks:
            // the drop lands the marked span at the point it was dropped on.
            if case let .recording(id) = item {
                guard case .main = target else { return }
                let range = editorStore.project.source(id)
                    .flatMap { RecordingSourcePresentation.url($0) }
                    .flatMap { EditorAssetMonitor.shared.sourceRange(forPath: $0.path) }
                editorStore.insertRecording(id, at: time, sourceRange: range)
                return
            }
            guard let asset = EditorMediaDrag.asset(for: item, in: editorStore) else {
                onError(appLocalized("无法读取拖入的素材，请重新拖入。"))
                return
            }
            let range = EditorAssetMonitor.shared.sourceRange(forPath: ProjectFiles.resolve(asset.path))
            switch target {
            case .main:
                insertAssetOnMainTrack(asset.id, atX: point.x, width: width,
                                       duration: duration, sourceRange: range)
            case let .overlay(lane):
                let destination: EditorDropLane
                switch lane {
                case let .audio(n) where asset.kind == .audio: destination = .audio(n)
                case let .layer(n) where asset.kind != .audio: destination = .layer(n)
                default: destination = asset.kind == .audio ? .newAudio : .newLayer
                }
                editorStore.placeMediaAssetAt(asset.id, time, lane: destination, sourceRange: range)
            }
        }
    }
}
