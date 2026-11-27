import AppKit
import AVFoundation
import RecorderCore
import SwiftUI

extension EditorTimelineView {
    func canMoveVisualToMain(_ id: UUID) -> Bool {
        guard let clip = TransferableVisualClip.find(id, in: editorStore.project.timeline) else { return false }
        if case let .animation(c) = clip { return HTMLMotion.isHTMLMotion(c.sourcePath) }
        return true
    }

    /// Cross-track intent only belongs to a clip body. Endpoints keep their
    /// original trim/retime session, regardless of vertical pointer movement.
    func updatePrimaryVisualTransfer(_ press: PrimarySegmentPointerSession, location: CGPoint,
                                     translation: CGSize) -> Bool {
        guard press.edge == nil, press.segment.media != nil,
              !selectedPrimarySegmentIDs.contains(press.segment.id) || selectedPrimarySegmentIDs.count <= 1,
              translation.height < -8, location.y < primaryLaneTop else {
            if primaryVisualTransferTarget != nil { endPrimarySegmentDrag(); mediaDropLane = nil }
            return false
        }
        guard beginTimelineGesture(.primaryMove(press.segment.id)) else { return false }
        if draggedPrimarySegmentID == nil {
            selectPrimarySegment(press.segment.id)
            playbackController.pause(revealingPlayhead: false)
        }
        draggedPrimarySegmentID = press.segment.id
        primaryReorderDraft = nil; primaryReorderPreviewTimeline = nil
        primarySegmentDragTranslation = translation.width
        primaryVisualTransferOffsetY = translation.height
        let wanted = magneticTime(min(max(press.segment.outputStart
            + Double(translation.width / max(press.laneWidth, 1)) * press.duration, 0), press.duration),
            width: press.laneWidth, duration: press.duration)
        let latestStart = max(press.duration - press.segment.outputDuration * 2, 0)
        primaryVisualTransferTime = min(max(wanted, 0), latestStart)
        var target = EditorDropLane.newLayer
        mediaDropLane = nil
        for lane in upperLanes where location.y >= laneTop(lane) && location.y < laneTop(lane) + laneHeight(lane) {
            switch lane {
            case let .layer(n): target = .layer(n); mediaDropLane = lane
            case .groupHeader(.layers), .moreLayers: mediaDropLane = lane
            default: break
            }
        }
        primaryVisualTransferTarget = target
        return true
    }

    func moveVisualToOverlay(_ id: UUID, at time: TimeInterval, target: EditorDropLane) {
        guard visualTransferTask == nil else { return }
        let layer: Int? = if case let .layer(n) = target { n } else { nil }
        let original = editorStore.project.timeline
        let package = ProjectFiles.package
        visualTransferTask = Task { @MainActor in
            defer { visualTransferTask = nil }
            do {
                let segment = try TimelineMap(sourceSequence: original.sourceSequence, sourceDurations: sourceDurations)
                    .segments.first { $0.id == id }
                let videoEnd: Double?
                if let media = segment?.media, media.imagePath == nil, media.motionPath == nil {
                    videoEnd = try await OverlayVideoSource.end(of: ProjectFiles.url(media.path))
                } else { videoEnd = nil }
                try Task.checkCancellation()
                guard editorStore.project.timeline == original, ProjectFiles.package == package else { throw RecordingImportError.changed }
                let timeline = try VisualTrackTransfer.moveToOverlay(id, at: time, layer: layer,
                    in: original, sourceDurations: sourceDurations,
                    defaultTransition: editorStore.project.motion.defaultZoomTransitionDuration,
                    newVideoCameraMode: AppPreferences.newVideoCameraMode(), videoSourceEnd: videoEnd)
                try editorStore.replaceTimeline(with: timeline, actionName: "移到画面叠加")
                selectedPrimarySegmentIDs = []; multiSelection = []
                if timeline.animationClips.contains(where: { $0.id == id }) { editorStore.selection = .animation(id) }
                else if timeline.stickerClips.contains(where: { $0.id == id }) { editorStore.selection = .sticker(id) }
                else { editorStore.selection = .videoClip(id) }
                revealTransferredOverlay()
            } catch is CancellationError { }
            catch { reportVisualTransferError(error) }
        }
    }

    func moveVisualToMain(_ id: UUID, at time: TimeInterval) {
        guard visualTransferTask == nil, let clip = TransferableVisualClip.find(id, in: editorStore.project.timeline) else { return }
        let original = editorStore.project.timeline
        let durations = sourceDurations
        playbackController.pause(revealingPlayhead: false)
        visualTransferTask = Task { @MainActor in
            var generated: URL?
            var committed = false
            defer {
                visualTransferTask = nil
                if !committed, let generated { try? FileManager.default.removeItem(at: generated) }
            }
            do {
                guard let package = ProjectFiles.package else { throw CocoaError(.fileNoSuchFile) }
                let folder = package.appendingPathComponent("Inserted", isDirectory: true)
                let media: InsertedMedia
                switch clip {
                case let .video(c):
                    let duration = try await OverlayVideoSource.end(of: ProjectFiles.url(c.sourcePath))
                    media = InsertedMedia(path: c.sourcePath, fileDuration: duration,
                        name: URL(fileURLWithPath: c.sourcePath).deletingPathExtension().lastPathComponent,
                        sourceAspectRatio: 1 / max(c.aspect, 0.001))
                case let .animation(c):
                    guard HTMLMotion.isHTMLMotion(c.sourcePath) else { throw VisualTrackTransferError.unsupportedClip }
                    let length = max(c.timeOffset + c.timing.duration * c.playbackRate + 0.1, 0.2)
                    let file = try await StillVideoMaker.makeSolid(color: CGColor(gray: 0, alpha: 1), into: folder, duration: length)
                    generated = file
                    media = InsertedMedia(path: ProjectFiles.portable(file.path), fileDuration: length,
                        name: URL(fileURLWithPath: c.sourcePath).deletingPathExtension().lastPathComponent, motionPath: c.sourcePath)
                case let .sticker(c):
                    let length = max(c.sourceStart + c.timing.duration * c.playbackRate, StillVideoMaker.fileDuration)
                    let file = try await StillVideoMaker.makeImageStandIn(into: folder, duration: length)
                    generated = file
                    guard let information = ImageMediaFrameCache.shared.information(at: ProjectFiles.url(c.relativePath)) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    media = InsertedMedia(path: ProjectFiles.portable(file.path), fileDuration: length,
                        name: URL(fileURLWithPath: c.relativePath).deletingPathExtension().lastPathComponent,
                        sourceAspectRatio: information.aspectRatio, imagePath: c.relativePath)
                }
                try Task.checkCancellation()
                guard editorStore.project.timeline == original else { throw RecordingImportError.changed }
                let timeline = try VisualTrackTransfer.moveToMain(id, media: media, at: time,
                    in: original, sourceDurations: durations)
                try editorStore.replaceTimeline(with: timeline, actionName: "移到主轨道")
                committed = true
                selectPrimarySegment(id)
            } catch is CancellationError { }
            catch { reportVisualTransferError(error) }
        }
    }

    private func revealTransferredOverlay() {
        visibleTracks.insert(.overlays)
        setPostLane(.layers, visible: true)
        collapsedTimelineGroupsRaw = collapsedLaneGroups.subtracting([TimelinePostLane.layers.rawValue]).sorted().joined(separator: ",")
        showsAllOverlayLayers = true
    }

    private func reportVisualTransferError(_ error: Error) {
        switch error {
        case VisualTrackTransferError.insufficientMainDuration:
            onError(appLocalized("主轨道剩余时长不足以容纳完整叠加片段，请先延长主轨道。"))
        case VisualTrackTransferError.unsupportedClip:
            onError(appLocalized("此片段不支持在主轨道与画面叠加之间移动。"))
        default: onError(appErrorDescription(error))
        }
    }

    @ViewBuilder func primaryVisualTransferHint() -> some View {
        if primaryVisualTransferTarget != nil {
            Text(appLocalized("移到画面叠加"))
                .font(.appUI(size: 11, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(EditorTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                .offset(x: CGFloat(primaryVisualTransferTime / max(timelineDuration, 0.001)) * timelineContentWidth,
                        y: max(primaryLaneTop - 26, 2))
                .allowsHitTesting(false)
        }
    }
}
