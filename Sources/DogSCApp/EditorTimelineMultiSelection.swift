import AppKit
import RecorderCore
import SwiftUI

/// EDT-055: a rubber-band selection drawn on empty timeline space. Only the
/// box layer observes it, so moving the pointer never re-renders the whole
/// timeline; clip rectangles are captured once when the drag begins.
@MainActor
final class TimelineMarqueeModel: ObservableObject {
    struct Target {
        let rect: CGRect
        let item: EditorSelection?
        let primary: UUID?
    }

    @Published private(set) var rect: CGRect?
    private(set) var isActive = false
    private var start: CGPoint = .zero
    private(set) var baseItems: Set<EditorSelection> = []
    private(set) var basePrimary: Set<UUID> = []
    private var targets: [Target] = []
    private var lastHit: (items: Set<EditorSelection>, primary: Set<UUID>)?

    func begin(at point: CGPoint, baseItems: Set<EditorSelection>, basePrimary: Set<UUID>, targets: [Target]) {
        isActive = true
        start = point
        self.baseItems = baseItems
        self.basePrimary = basePrimary
        self.targets = targets
        lastHit = nil
    }

    /// Moves the box; returns the new hit sets only when they changed.
    func update(to point: CGPoint) -> (items: Set<EditorSelection>, primary: Set<UUID>)? {
        let box = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                         width: max(abs(point.x - start.x), 1), height: max(abs(point.y - start.y), 1))
        rect = box
        var items = baseItems, primary = basePrimary
        for target in targets where target.rect.intersects(box) {
            if let item = target.item { items.insert(item) }
            if let id = target.primary { primary.insert(id) }
        }
        if let lastHit, lastHit.items == items, lastHit.primary == primary { return nil }
        lastHit = (items, primary)
        return (items, primary)
    }

    func end() {
        isActive = false
        rect = nil
        targets = []
        lastHit = nil
    }
}

private struct TimelineMarqueeLayer: View {
    @ObservedObject var model: TimelineMarqueeModel

    var body: some View {
        if let rect = model.rect, rect.width > 1 || rect.height > 1 {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(EditorTheme.selectionTint.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(EditorTheme.selectionTint.opacity(0.6), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

/// Hit area made of a row's clips only, so empty space passes through.
struct TimelineClipsShape: Shape {
    let ranges: [ClosedRange<CGFloat>]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for range in ranges {
            path.addRect(CGRect(x: range.lowerBound, y: rect.minY,
                                width: max(range.upperBound - range.lowerBound, 3), height: rect.height))
        }
        return path
    }
}

extension EditorTimelineView {
    /// Clips that can join a group selection (primary segments keep their own set).
    static func isGroupSelectable(_ selection: EditorSelection) -> Bool {
        switch selection {
        case .zoom, .screenMotion, .cameraMotion, .mosaic, .sticker, .animation, .audioClip, .subtitle, .videoClip:
            true
        default:
            false
        }
    }

    /// Everything selected together, primary segments included.
    var groupSelectionCount: Int {
        multiSelection.count + (multiSelection.isEmpty && selectedPrimarySegmentIDs.count <= 1 ? 0 : selectedPrimarySegmentIDs.count)
    }

    /// ⇧/⌘-click: add the clip, or take it out if it is already selected.
    func toggleInMultiSelection(_ selection: EditorSelection) {
        var items = multiSelection
        if items.isEmpty, let current = editorStore.selection, Self.isGroupSelectable(current) {
            items.insert(current)
        }
        if items.contains(selection) {
            items.remove(selection)
            multiSelection = items
            editorStore.selection = items.first
                ?? selectedPrimarySegmentIDs.first.map(EditorSelection.primarySegment)
            return
        }
        items.insert(selection)
        multiSelection = items
        editorStore.selection = selection
    }

    // MARK: Marquee

    static func isTimelinePointerDrag(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > 3
    }

    func timelineMarqueeGesture(
        width: CGFloat,
        duration: TimeInterval,
        onClick: ((CGPoint) -> Void)? = nil
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(editorTimelineDocumentCoordinateSpace))
            .onChanged { value in
                updateTimelineMarquee(value, width: width, duration: duration)
            }
            .onEnded { value in
                finishTimelineBackgroundPress(value, width: width, duration: duration, onClick: onClick)
            }
    }

    func updateTimelineMarquee(_ value: DragGesture.Value, width: CGFloat, duration: TimeInterval) {
        if !marqueeModel.isActive {
            guard Self.isTimelinePointerDrag(value.translation), beginTimelineGesture(.marquee) else { return }
            let additive = !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty
            var baseItems = additive ? multiSelection : []
            if additive, baseItems.isEmpty, let current = editorStore.selection, Self.isGroupSelectable(current) {
                baseItems.insert(current)
            }
            playbackController.pause(revealingPlayhead: false)
            playbackController.endHoverPreview()
            marqueeModel.begin(at: value.startLocation, baseItems: baseItems,
                               basePrimary: additive ? selectedPrimarySegmentIDs : [],
                               targets: marqueeTargets(width: width, duration: duration))
        }
        guard let hit = marqueeModel.update(to: value.location) else { return }
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            multiSelection = hit.items
            selectedPrimarySegmentIDs = hit.primary
        }
    }

    func finishTimelineBackgroundPress(
        _ value: DragGesture.Value, width: CGFloat, duration: TimeInterval, onClick: ((CGPoint) -> Void)? = nil
    ) {
        if marqueeModel.isActive {
            updateTimelineMarquee(value, width: width, duration: duration)
            finishTimelineMarquee()
            return
        }
        guard gestureOwnership.activeIntent == nil, !Self.isTimelinePointerDrag(value.translation) else { return }
        if let onClick {
            onClick(value.location)
        } else if NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty, width > 0, duration > 0 {
            clearTimelineSelection()
            seekTimeline(to: TimeInterval(value.location.x / width) * duration)
        }
    }

    func finishTimelineMarquee() {
        guard marqueeModel.isActive else { return }
        if let first = timelineMap?.segments.first(where: { selectedPrimarySegmentIDs.contains($0.id) }) {
            editorStore.selection = .primarySegment(first.id)
        } else {
            editorStore.selection = multiSelection.min { startTime(of: $0) < startTime(of: $1) }
        }
        marqueeModel.end()
        endTimelineGesture(.marquee)
    }

    func timelineMarqueeOverlay() -> some View {
        TimelineMarqueeLayer(model: marqueeModel).allowsHitTesting(false)
    }

    private func startTime(of selection: EditorSelection) -> TimeInterval {
        let timeline = editorStore.project.timeline
        return switch selection {
        case let .zoom(id): timeline.zoomClips.first { $0.id == id }?.startTime ?? 0
        case let .screenMotion(id): timeline.screenMotionClips.first { $0.id == id }?.timing.startTime ?? 0
        case let .cameraMotion(id): timeline.cameraMotionClips.first { $0.id == id }?.timing.startTime ?? 0
        default: overlayTimelineClips.first { $0.kind.selection(id: $0.id) == selection }?.timing.startTime ?? 0
        }
    }

    /// Every selectable clip's rectangle in timeline document coordinates.
    func marqueeTargets(width: CGFloat, duration: TimeInterval) -> [TimelineMarqueeModel.Target] {
        guard width > 0, duration > 0 else { return [] }
        func x(_ time: TimeInterval) -> CGFloat { CGFloat(time / duration) * width }
        func rect(_ start: TimeInterval, _ end: TimeInterval, _ top: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: x(start), y: top, width: max(x(end) - x(start), 3), height: height)
        }
        var targets: [TimelineMarqueeModel.Target] = []
        for lane in upperLanes + lowerLanes {
            let top = laneTop(lane)
            for (row, clips) in laneRows(lane).enumerated() {
                for clip in clips {
                    targets.append(.init(rect: rect(clip.timing.startTime, clip.timing.endTime,
                                                    top + clipRowInset + CGFloat(row) * (clipRowHeight + clipRowSpacing), clipRowHeight),
                                         item: clip.kind.selection(id: clip.id), primary: nil))
                }
            }
        }
        for segment in primaryDisplaySegments {
            targets.append(.init(rect: rect(segment.outputStart, segment.outputEnd, primaryLaneTop, primaryTimelineHeight),
                                 item: nil, primary: segment.id))
        }
        var top = primaryLaneTop + primaryTimelineHeight + (showsCameraSyncTimeline ? cameraSyncTimelineHeight : 0)
        let timeline = editorStore.project.timeline
        if showsZoomTimeline {
            for clip in timeline.zoomClips {
                targets.append(.init(rect: rect(clip.startTime, clip.endTime, top, zoomTimelineHeight), item: .zoom(clip.id), primary: nil))
            }
            top += zoomTimelineHeight
        }
        if showsScreenMotionTimeline {
            for clip in timeline.screenMotionClips {
                targets.append(.init(rect: rect(clip.timing.startTime, clip.timing.endTime, top, motionTimelineHeight),
                                     item: .screenMotion(clip.id), primary: nil))
            }
            top += motionTimelineHeight
        }
        if showsCameraMotionTimeline {
            for clip in timeline.cameraMotionClips {
                targets.append(.init(rect: rect(clip.timing.startTime, clip.timing.endTime, top, motionTimelineHeight),
                                     item: .cameraMotion(clip.id), primary: nil))
            }
        }
        return targets
    }

    // MARK: Group edits

    /// Start timings of the other selected added-material clips.
    func groupOverlayTimings(excluding dragged: EditorSelection) -> [EditorSelection: OverlayTiming] {
        var result: [EditorSelection: OverlayTiming] = [:]
        for clip in overlayTimelineClips {
            let selection = clip.kind.selection(id: clip.id)
            if selection != dragged, multiSelection.contains(selection) { result[selection] = clip.timing }
        }
        return result
    }

    static func setOverlayTiming(_ timing: OverlayTiming, of selection: EditorSelection, in timeline: inout ProjectTimeline) {
        switch selection {
        case let .mosaic(id): if let i = timeline.mosaicClips.firstIndex(where: { $0.id == id }) { timeline.mosaicClips[i].timing = timing }
        case let .sticker(id): if let i = timeline.stickerClips.firstIndex(where: { $0.id == id }) { timeline.stickerClips[i].timing = timing }
        case let .animation(id): if let i = timeline.animationClips.firstIndex(where: { $0.id == id }) { timeline.animationClips[i].timing = timing }
        case let .audioClip(id): if let i = timeline.audioClips.firstIndex(where: { $0.id == id }) { timeline.audioClips[i].timing = timing }
        case let .subtitle(id): if let i = timeline.subtitleCues.firstIndex(where: { $0.id == id }) { timeline.subtitleCues[i].timing = timing }
        case let .videoClip(id): if let i = timeline.videoClips.firstIndex(where: { $0.id == id }) { timeline.videoClips[i].timing = timing }
        default: break
        }
    }

    /// Deletes everything selected as one undo step. Effects go first, then
    /// primary segments ripple out one by one (at least one always stays).
    func removeGroupSelection() {
        let items = multiSelection
        let primary = selectedPrimarySegmentIDs
        editorStore.cancelInteraction()
        editorStore.beginUndoBatch()
        defer { editorStore.endUndoBatch(actionName: appLocalized("删除所选")) }
        do {
            var timeline = editorStore.project.timeline
            for item in items {
                switch item {
                case let .zoom(id): timeline.zoomClips.removeAll { $0.id == id }
                case let .screenMotion(id): timeline = try ProjectTimelineEditing.removingScreenMotion(id: id, from: timeline)
                case let .cameraMotion(id): timeline = try ProjectTimelineEditing.removingCameraMotion(id: id, from: timeline)
                case let .mosaic(id): timeline.mosaicClips.removeAll { $0.id == id }
                case let .sticker(id): timeline.stickerClips.removeAll { $0.id == id }
                case let .animation(id): timeline.animationClips.removeAll { $0.id == id }
                case let .audioClip(id): timeline.audioClips.removeAll { $0.id == id }
                case let .subtitle(id): timeline.subtitleCues.removeAll { $0.id == id }
                case let .videoClip(id): timeline.videoClips.removeAll { $0.id == id }
                default: break
                }
            }
            if let map = timelineMap {
                let removable = map.segments.filter { primary.contains($0.id) }.map(\.id)
                for id in removable.prefix(max(map.segments.count - 1, 0)) {
                    timeline = try ProjectTimelineEditing.removePrimarySegment(
                        from: timeline, segmentID: id, sourceDurations: sourceDurations,
                        defaultTransitionDuration: editorStore.project.motion.defaultZoomTransitionDuration)
                }
            }
            try editorStore.replaceTimeline(with: timeline, actionName: appLocalized("删除所选"))
        } catch {
            onError(error.localizedDescription)
        }
        clearTimelineSelection()
    }
}
