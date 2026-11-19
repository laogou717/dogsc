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
            + postLanesHeight
    }

    // EDT-062: track heights scale with the panel. Shrinking the timeline
    // makes every track thinner (all stay visible); enlarging makes them
    // taller. The ruler and controls keep their size.
    var trackScale: CGFloat {
        let natural = naturalTracksHeight
        return Self.resolvedTrackScale(natural: natural, viewport: timelineViewportHeight, ruler: timelineRulerHeight)
    }

    static func resolvedTrackScale(natural: CGFloat, viewport: CGFloat, ruler: CGFloat) -> CGFloat {
        let available = viewport - ruler
        guard natural > 0, available > 0 else { return 1 }
        return min(max(available / natural, 0.5), 2)
    }

    /// Height of all tracks at scale 1.
    var naturalTracksHeight: CGFloat {
        // Lane rows only change when the overlay clips do (cached), so the
        // cheap identity of the clip cache plus visibility is a sound key.
        _ = overlayTimelineClips
        let key = EditorTimelineDerivedPresentationCache.NaturalHeightKey(
            tracks: visibleTracks.rawValue, hidden: hiddenPostLanesRaw + "#" + laneGroupLayoutKey + "#drop:\(timelineMediaDragActive)",
            cameraSync: showsCameraSyncTimeline, primary: basePrimaryVideoHeight,
            motion: baseMotionHeight, overlays: derivedPresentationCache.overlayGeneration
        )
        return derivedPresentationCache.naturalTracksHeight(key: key) {
            basePrimaryVideoHeight + 12
                + (showsZoomTimeline ? baseMotionHeight : 0)
                + (showsCameraSyncTimeline ? 62 : 0)
                + (showsScreenMotionTimeline ? baseMotionHeight : 0)
                + (showsCameraMotionTimeline ? baseMotionHeight : 0)
                + (upperLanes + lowerLanes).reduce(0) { $0 + baseLaneHeight($1) }
        }
    }

    var baseMotionHeight: CGFloat { 32 }
    var basePrimaryVideoHeight: CGFloat { layout.value(regular: 52, compact: 44) }

    var cameraSyncTimelineHeight: CGFloat { 62 * trackScale }
    var motionTimelineHeight: CGFloat { baseMotionHeight * trackScale }
    var zoomTimelineHeight: CGFloat { baseMotionHeight * trackScale }
    var zoomBarHeight: CGFloat { layout.value(regular: 24, compact: 22) * trackScale }
    var overlayTimelineHeight: CGFloat {
        max(CGFloat(max(overlayTimelineRows.count, 1) * 34 + 16), motionTimelineHeight)
    }
    var timelineRulerHeight: CGFloat { layout.value(regular: 28, compact: 26) }
    var timelineControlsHeight: CGFloat { layout.value(regular: 44, compact: 40) }
    var timelineOverviewHeight: CGFloat { layout.value(regular: 20, compact: 16) }
    var timelineDividerHeight: CGFloat { 1 }
    var timelineLabelWidth: CGFloat {
        timelineLabelsCollapsed ? 52 : layout.value(regular: 140, compact: 124)
    }
    /// What the tracks need at their natural size (never the scaled size,
    /// which depends on the panel and would feed back into it).
    var preferredPanelHeight: CGFloat {
        timelineRulerHeight + naturalTracksHeight
            + timelineControlsHeight + timelineOverviewHeight + timelineDividerHeight
    }
    // Compact windows use one row geometry for drawing, labels and hit testing.
    var primaryTimelineHeight: CGFloat { primaryVideoHeight + 12 }
    var waveformContentHeight: CGFloat { primaryVideoHeight }
    // Display mode changes the contents, never the workspace geometry.
    var primaryVideoHeight: CGFloat { min(basePrimaryVideoHeight * trackScale, 76) }
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
        let sourceID = mediaSession.sourceID(at: playbackController.latestOutputTime)
        let frameRate = max(editorStore.project.captureFrameRate(for: sourceID).rawValue, 1)
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
        finishTimelineMarquee()
        if gestureOwnership.activeIntent?.seeksDuringDrag == true {
            playbackController.endScrubbing()
        }
        rulerPress = nil
        primaryPointerSession = nil
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
        overlayPointerPress = nil
        overlayGroupOriginals = [:]
        overlayTimelineDrag = nil
        overlayDragTarget = nil
        overlayDragOffsetY = 0
        overlayDragOriginY = nil
        mainTrackDropX = nil
        mediaDropLane = nil
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
