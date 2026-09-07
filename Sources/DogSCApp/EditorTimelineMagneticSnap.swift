import AppKit
import RecorderCore
import SwiftUI

/// A gesture-local magnet with separate capture and release distances. Targets
/// are cached from committed data, so a moving bar cannot attract itself.
@MainActor
final class EditorTimelineMagneticSnap: ObservableObject {
    @Published private(set) var targetTime: TimeInterval?
    private var candidates: [TimeInterval]?
    private var heldOffset: TimeInterval = 0
    private var suppressed: Set<TimeInterval> = []

    func reset() {
        candidates = nil
        suppressed.removeAll()
        release()
    }

    private func release() {
        if targetTime != nil { targetTime = nil }
        heldOffset = 0
    }

    func resolve(_ proposed: TimeInterval, offsets: [TimeInterval], initial: [TimeInterval],
                 pointsPerSecond: Double, targets: () -> [TimeInterval]) -> TimeInterval {
        guard proposed.isFinite, pointsPerSecond > 0 else { return proposed }
        let capture = 7 / pointsPerSecond
        let escape = 14 / pointsPerSecond
        if candidates == nil {
            candidates = Array(Set(targets().filter(\.isFinite))).sorted()
            suppressed = Set((candidates ?? []).filter { point in
                initial.contains { abs($0 - point) < 0.000_01 }
            })
        }
        suppressed = suppressed.filter { point in
            offsets.contains { abs(proposed + $0 - point) <= escape }
        }
        if NSEvent.modifierFlags.contains(.shift) { release(); return proposed }
        if let targetTime, abs(proposed + heldOffset - targetTime) <= escape {
            return targetTime - heldOffset
        }
        release()
        let points = candidates ?? []
        var best: (distance: Double, time: Double, offset: Double)?
        for offset in offsets {
            let position = proposed + offset
            var lo = 0, hi = points.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if points[mid] < position { lo = mid + 1 } else { hi = mid }
            }
            for index in [lo - 1, lo] where points.indices.contains(index) {
                let point = points[index]
                let distance = abs(point - position)
                guard !suppressed.contains(point), distance <= capture,
                      distance < (best?.distance ?? .infinity) else { continue }
                best = (distance, point, offset)
            }
        }
        guard let best else { return proposed }
        heldOffset = best.offset
        targetTime = best.time
        return best.time - best.offset
    }

    /// Existing overlap/minimum-duration rules remain authoritative. Never
    /// advertise a magnetic alignment that the legal timing did not reach.
    func validate(edges: [TimeInterval]) {
        guard let targetTime else { return }
        if !edges.contains(where: { abs($0 - targetTime) < 0.000_1 }) { release() }
    }
}

extension EditorTimelineView {
    private var snapExcludedIDs: Set<UUID> {
        var ids: Set<UUID> = []
        if let draggedPrimarySegmentID { ids.insert(draggedPrimarySegmentID) }
        switch gestureOwnership.activeIntent {
        case let .primaryTrim(id, _), let .primaryRetime(id), let .zoomMove(id),
             let .zoomResize(id, _), let .motion(_, id, _), let .overlay(_, id, _):
            ids.insert(id)
        default: break
        }
        // Linked screen/camera motion edits must not snap to their own partner.
        if let origin = motionGestureOrigin {
            ids.formUnion(origin.partnerOrigins.map(\.id))
        }
        return ids
    }

    private func magneticTargets(duration: TimeInterval) -> [TimeInterval] {
        let excluded = snapExcludedIDs
        var points: [Double] = [0, duration]
        for clip in primaryDisplaySegments where !excluded.contains(clip.id) {
            points += [clip.outputStart, clip.outputStart + clip.outputDuration]
        }
        let timeline = editorStore.project.timeline
        if showsZoomTimeline {
            for clip in timeline.zoomClips where !excluded.contains(clip.id) {
                points += [clip.startTime, clip.endTime]
            }
        }
        if showsScreenMotionTimeline {
            for clip in timeline.screenMotionClips where !excluded.contains(clip.id) {
                points += [clip.timing.startTime, clip.timing.endTime]
            }
        }
        if showsCameraMotionTimeline {
            for clip in timeline.cameraMotionClips where !excluded.contains(clip.id) {
                points += [clip.timing.startTime, clip.timing.endTime]
            }
        }
        if showsOverlayTimeline {
            for clip in timeline.mosaicClips where !excluded.contains(clip.id) {
                points += [clip.timing.startTime, clip.timing.endTime]
            }
            for clip in timeline.stickerClips where !excluded.contains(clip.id) {
                points += [clip.timing.startTime, clip.timing.endTime]
            }
        }
        if gestureOwnership.activeIntent != .scrub { points.append(playbackTime) }
        return points.filter { $0 >= 0 && $0 <= duration }
    }

    func magneticTime(_ time: TimeInterval, width: CGFloat, duration: TimeInterval,
                      offsets: [TimeInterval] = [0], initial: [TimeInterval] = []) -> TimeInterval {
        guard isSnappingEnabled else { timelineSnap.reset(); return time }
        return timelineSnap.resolve(time, offsets: offsets, initial: initial,
            pointsPerSecond: Double(width) / max(duration, 0.001)) {
                magneticTargets(duration: duration)
            }
    }

    func magneticDelta(_ delta: TimeInterval, start: TimeInterval, end: TimeInterval,
                       mode: EditorMotionTimelineEditMode, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        let offsets: [TimeInterval] = switch mode {
        case .move: [0, end - start]
        case .leading: [0]
        case .trailing: [end - start]
        }
        return magneticTime(start + delta, width: width, duration: duration,
            offsets: offsets, initial: [start, end]) - start
    }

    @ViewBuilder
    func magneticGuide(width: CGFloat, duration: TimeInterval) -> some View {
        if let time = timelineSnap.targetTime {
            Rectangle().fill(EditorTheme.selectionTint.opacity(0.8))
                .frame(width: 1, height: timelineCanvasHeight)
                .overlay(alignment: .top) {
                    Circle().fill(EditorTheme.selectionTint).frame(width: 5, height: 5)
                }
                .offset(x: CGFloat(time / max(duration, 0.001)) * width - 0.5)
                .allowsHitTesting(false).accessibilityHidden(true).zIndex(40)
        }
    }
}
