import AppKit
import SwiftUI

/// Shared timeline geometry, frame snapping and gesture lifecycle. Keeping
/// these responsibilities outside the zoom lane prevents zoom editing from
/// becoming the owner of transport behavior used by every visible track.
extension EditorTimelineView {
    var timelineCanvasHeight: CGFloat {
        timelineRulerHeight + primaryTimelineHeight
            + (showsZoomTimeline ? zoomTimelineHeight : 0)
            + (showsCameraSyncTimeline ? cameraSyncTimelineHeight : 0)
            + (showsScreenMotionTimeline ? motionTimelineHeight : 0)
            + (showsCameraMotionTimeline ? motionTimelineHeight : 0)
            + (showsOverlayTimeline ? overlayTimelineHeight : 0)
    }

    var cameraSyncTimelineHeight: CGFloat { 62 }
    var motionTimelineHeight: CGFloat { layout.value(regular: 56, compact: 44) }
    var zoomTimelineHeight: CGFloat { layout.value(regular: 56, compact: 44) }
    var zoomBarHeight: CGFloat { layout.value(regular: 42, compact: 32) }
    var overlayTimelineHeight: CGFloat {
        max(CGFloat(max(overlayTimelineRows.count, 1) * 34 + 16), motionTimelineHeight)
    }
    var timelineRulerHeight: CGFloat { layout.value(regular: 44, compact: 32) }
    var timelineControlsHeight: CGFloat { layout.value(regular: 68, compact: 52) }
    var timelineOverviewHeight: CGFloat { layout.value(regular: 20, compact: 16) }
    var timelineDividerHeight: CGFloat { 1 }
    var timelineLabelWidth: CGFloat { layout.value(regular: 156, compact: 124) }
    var preferredPanelHeight: CGFloat {
        timelineCanvasHeight + timelineControlsHeight + timelineOverviewHeight + timelineDividerHeight
    }
    // Compact windows use one row geometry for drawing, labels and hit testing.
    var primaryTimelineHeight: CGFloat { primaryVideoHeight + 12 }
    var waveformContentHeight: CGFloat { primaryVideoHeight }
    // Display mode changes the contents, never the workspace geometry.
    var primaryVideoHeight: CGFloat { layout.value(regular: 96, compact: 72) }
    var timelineViewportHeight: CGFloat {
        max(panelHeight - timelineControlsHeight - timelineOverviewHeight - timelineDividerHeight, 80)
    }
    var timelineDocumentHeight: CGFloat { max(timelineCanvasHeight, timelineViewportHeight) }
    var timelineHeight: CGFloat { panelHeight }

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
        if gestureOwnership.activeIntent == nil { timelineSnap.reset() }
        return gestureOwnership.begin(intent)
    }

    func endTimelineGesture(_ intent: EditorTimelineGestureIntent) {
        guard gestureOwnership.activeIntent == intent else { return }
        gestureOwnership.end(intent)
        timelineInteractionID = nil
        timelineSnap.reset()
    }

    func cancelActiveTimelineGesture() {
        if gestureOwnership.activeIntent?.seeksDuringDrag == true {
            playbackController.endScrubbing()
        }
        gestureOwnership.cancel()
        timelineSnap.reset()
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
        overlayCreateRange = nil
        overlayCreateStart = nil
        // Recovery is allowed to retire its own draft only. A delayed mouse-up
        // must never cancel a crop/inspector interaction started since then.
        if let owned = timelineInteractionID, editorStore.interaction?.id == owned {
            editorStore.cancelInteraction()
        }
        timelineInteractionID = nil
    }

    func stepTimeline(byFrames frames: Int) {
        seekTimeline(to: playbackTime + Double(frames) * timelineFrameDuration)
    }
}
