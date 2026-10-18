import AppKit
import RecorderCore

extension EditorSelection {
    var isMotionClip: Bool {
        switch self {
        case .zoom, .screenMotion, .cameraMotion: true
        default: false
        }
    }
}

extension EditorStore {
    func orderedMotionSelections(for item: EditorSelection) -> [EditorSelection] {
        switch item {
        case .zoom:
            return project.timeline.zoomClips.sorted { $0.startTime < $1.startTime }.map { .zoom($0.id) }
        case .screenMotion:
            return project.timeline.screenMotionClips.sorted { $0.timing.startTime < $1.timing.startTime }.map { .screenMotion($0.id) }
        case .cameraMotion:
            return project.timeline.cameraMotionClips.sorted { $0.timing.startTime < $1.timing.startTime }.map { .cameraMotion($0.id) }
        default: return []
        }
    }

    func selectTimelineMotion(_ item: EditorSelection, modifiers: NSEvent.ModifierFlags = []) {
        guard item.isMotionClip else { selection = item; return }
        let ordered = orderedMotionSelections(for: item)
        let current = motionSelections.isEmpty ? Set(selection.map { [$0] } ?? []) : motionSelections
        let existing = current.intersection(Set(ordered))
        var anchor = motionSelectionAnchor ?? selection
        var updated: Set<EditorSelection>
        if modifiers.contains(.shift), let anchor,
           let first = ordered.firstIndex(of: anchor), let last = ordered.firstIndex(of: item) {
            let range = Set(ordered[min(first, last)...max(first, last)])
            updated = modifiers.contains(.command) ? existing.union(range) : range
        } else if modifiers.contains(.command) {
            updated = existing
            if !updated.insert(item).inserted { updated.remove(item) }
            anchor = item
        } else {
            updated = [item]
            anchor = item
        }
        selection = updated.contains(item) ? item : ordered.first(where: { updated.contains($0) })
        motionSelections = updated
        motionSelectionAnchor = anchor
    }

    func isTimelineMotionSelected(_ item: EditorSelection) -> Bool {
        motionSelections.isEmpty ? selection == item : motionSelections.contains(item)
    }

    func reconcileMotionSelections() {
        let valid = Set(project.timeline.zoomClips.map { EditorSelection.zoom($0.id) }
            + project.timeline.screenMotionClips.map { EditorSelection.screenMotion($0.id) }
            + project.timeline.cameraMotionClips.map { EditorSelection.cameraMotion($0.id) })
        motionSelections.formIntersection(valid)
        if let anchor = motionSelectionAnchor, !valid.contains(anchor) { motionSelectionAnchor = nil }
    }

    func removeSelectedMotions() throws {
        let selected = motionSelections
        guard !selected.isEmpty else { return }
        cancelInteraction()
        var candidate = project
        // Reuse single-clip removal semantics, including the return/exit
        // transition repairs when deleting a neighbor in a joined sequence.
        let ordered: [EditorSelection] = candidate.timeline.zoomClips.sorted { $0.startTime < $1.startTime }.map { .zoom($0.id) }
            + candidate.timeline.screenMotionClips.sorted { $0.timing.startTime < $1.timing.startTime }.map { .screenMotion($0.id) }
            + candidate.timeline.cameraMotionClips.sorted { $0.timing.startTime < $1.timing.startTime }.map { .cameraMotion($0.id) }
        for item in ordered.reversed() where selected.contains(item) {
            switch item {
            case let .zoom(id):
                guard candidate.timeline.zoomClips.contains(where: { $0.id == id }) else { continue }
                try ProjectReducer.apply(ProjectCommand.removingZoom(id: id, from: candidate), to: &candidate)
            case let .screenMotion(id):
                guard candidate.timeline.screenMotionClips.contains(where: { $0.id == id }) else { continue }
                candidate.timeline = try ProjectTimelineEditing.removingScreenMotion(
                    id: id, from: candidate.timeline, defaultReturn: candidate.motion.defaultZoomTransitionDuration)
            case let .cameraMotion(id):
                guard candidate.timeline.cameraMotionClips.contains(where: { $0.id == id }) else { continue }
                candidate.timeline = try ProjectTimelineEditing.removingCameraMotion(
                    id: id, from: candidate.timeline, defaultReturn: candidate.motion.defaultZoomTransitionDuration)
            default: break
            }
        }
        // One document replacement gives the whole batch one undo operation.
        try replaceTimeline(with: candidate.timeline, actionName: "批量删除运镜")
        selection = nil
        motionSelections = []
        motionSelectionAnchor = nil
    }
}
