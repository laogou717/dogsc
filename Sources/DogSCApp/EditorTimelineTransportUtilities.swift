import AppKit
import SwiftUI

/// Shared timeline geometry, frame snapping and gesture lifecycle. Keeping
/// these responsibilities outside the zoom lane prevents zoom editing from
/// becoming the owner of transport behavior used by every visible track.
extension EditorTimelineView {
    var timelineCanvasHeight: CGFloat {
        timelineRulerHeight + primaryTimelineHeight
            + (showsZoomTimeline ? 56 : 0)
            + (showsCameraSyncTimeline ? cameraSyncTimelineHeight : 0)
            + (showsScreenMotionTimeline ? motionTimelineHeight : 0)
            + (showsCameraMotionTimeline ? motionTimelineHeight : 0)
            + (showsOverlayTimeline ? overlayTimelineHeight : 0)
            + (showsProgressTimeline ? overlayTimelineHeight : 0)
    }

    var cameraSyncTimelineHeight: CGFloat { 62 }
    var motionTimelineHeight: CGFloat { 46 }
    var overlayTimelineHeight: CGFloat { 42 }
    var timelineRulerHeight: CGFloat { 50 }
    var timelineControlsHeight: CGFloat { 50 }
    var timelineOverviewHeight: CGFloat { 20 }
    var timelineDividerHeight: CGFloat { 1 }
    var timelineLabelWidth: CGFloat { 86 }
    var primaryTimelineHeight: CGFloat {
        EditorTimelineSizing.clampedPrimaryLaneHeight(primaryLaneHeight)
    }
    var primaryClipContentHeight: CGFloat {
        max(primaryTimelineHeight - 12, 44)
    }

    var timelineHeight: CGFloat {
        timelineControlsHeight
            + timelineOverviewHeight
            + timelineCanvasHeight
            + timelineDividerHeight * 2
    }

    func seekTimeline(to time: TimeInterval) {
        let snapped = snappedTimelineTime(time)
        playbackController.seek(to: snapped, pausing: true)
        scrollTimelineToEndpointIfNeeded(snapped)
    }

    var timelineFrameDuration: TimeInterval {
        let frameRate = max(editorStore.project.capture.captureFrameRate.rawValue, 1)
        return 1 / Double(frameRate)
    }

    func snappedToProjectFrame(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return (time / timelineFrameDuration).rounded() * timelineFrameDuration
    }

    /// Snap ordinary playhead/edit positions to the project frame grid while
    /// preserving the media's exact final duration even when it is not an
    /// integer multiple of the nominal frame interval.
    func snappedTimelineTime(_ time: TimeInterval) -> TimeInterval {
        let clamped = min(max(time.isFinite ? time : 0, 0), timelineDuration)
        if clamped <= timelineFrameDuration / 2 { return 0 }
        if timelineDuration - clamped <= timelineFrameDuration / 2 {
            return timelineDuration
        }
        return min(max(snappedToProjectFrame(clamped), 0), timelineDuration)
    }

    func snappedEditableTime(
        _ time: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        let lower = min(lowerBound, upperBound)
        let upper = max(lowerBound, upperBound)
        let clamped = min(max(time, lower), upper)
        if clamped - lower <= timelineFrameDuration / 2 { return lower }
        if upper - clamped <= timelineFrameDuration / 2 { return upper }
        return min(max(snappedToProjectFrame(clamped), lower), upper)
    }

    func scrollTimelineToEndpointIfNeeded(_ time: TimeInterval) {
        guard let scrollView = timelineScrollView else { return }
        let viewportWidth = scrollView.contentView.bounds.width
        let documentWidth = max(
            scrollView.documentView?.bounds.width ?? timelineContentWidth,
            viewportWidth
        )
        let targetX: CGFloat?
        if time <= 0.000_001 {
            targetX = 0
        } else if timelineDuration - time <= 0.000_001 {
            targetX = max(documentWidth - viewportWidth, 0)
        } else {
            targetX = nil
        }
        guard let targetX else { return }
        scrollView.contentView.scroll(
            to: NSPoint(x: targetX, y: scrollView.documentVisibleRect.origin.y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func beginTimelineGesture(_ intent: EditorTimelineGestureIntent) -> Bool {
        gestureOwnership.begin(intent)
    }

    func endTimelineGesture(_ intent: EditorTimelineGestureIntent) {
        gestureOwnership.end(intent)
    }

    func cancelActiveTimelineGesture() {
        if gestureOwnership.activeIntent?.seeksDuringDrag == true {
            playbackController.endScrubbing()
        }
        gestureOwnership.cancel()
        endPrimarySegmentDrag()
        primaryTrimDraft = nil
        primaryRetimeDraft = nil
        manualZoomDragStart = nil
        manualZoomDragEnd = nil
        zoomGestureOrigin = nil
        zoomTrackDrag = nil
        motionGestureOrigin = nil
        motionTrackDrag = nil
        motionCreateDrag = nil
        overlayTimelineDrag = nil
        editorStore.cancelInteraction()
    }

    func stepTimeline(byFrames frames: Int) {
        seekTimeline(to: playbackTime + Double(frames) * timelineFrameDuration)
    }
}
