import AppKit
import RecorderCore
import SwiftUI

let editorTimelineDocumentCoordinateSpace = "editor.timeline.document"

enum EditorTimelineSizing {
    static let defaultPrimaryLaneHeight: CGFloat = 132
    static let minimumPrimaryLaneHeight: CGFloat = 124
    static let maximumPrimaryLaneHeight: CGFloat = 280

    static func clampedPrimaryLaneHeight(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed.isFinite ? proposed : defaultPrimaryLaneHeight,
                minimumPrimaryLaneHeight),
            maximumPrimaryLaneHeight)
    }

    /// Dragging the divider upward has a negative screen-space translation and
    /// should therefore enlarge the timeline lane.
    static func resizedPrimaryLaneHeight(
        start: CGFloat,
        verticalTranslation: CGFloat
    ) -> CGFloat {
        clampedPrimaryLaneHeight(start - verticalTranslation)
    }
}

/// Pure timing constraints for motion bars. A gesture can change only its own
/// typed clip and cannot cross a neighbour, reorder targets, or escape the
/// final output clock. 与缩放轨同一语义：可以拖到与邻段相接（回落休眠），
/// 落在回落窗口"洞口"时磁吸到最近的合法位置，间隙放不下则拒绝。
enum EditorMotionTimelinePresentation {
    static let minimumDuration: TimeInterval = 0.08

    static func bounds(
        for id: UUID,
        timings: [(id: UUID, timing: TransitionTiming)],
        timelineDuration: TimeInterval
    ) -> EditorMotionTimelineBounds? {
        bounds(
            for: id,
            items: timings,
            id: { $0.id },
            timing: { $0.timing },
            timelineDuration: timelineDuration
        )
    }

    static func bounds<Element>(
        for targetID: UUID,
        items: [Element],
        id: (Element) -> UUID,
        timing: (Element) -> TransitionTiming,
        timelineDuration: TimeInterval,
        itemsAreOrdered: Bool = false
    ) -> EditorMotionTimelineBounds? {
        let previousTiming: TransitionTiming?
        let nextTiming: TransitionTiming?
        if itemsAreOrdered {
            guard let index = items.firstIndex(where: { id($0) == targetID }) else {
                return nil
            }
            previousTiming = index > 0 ? timing(items[index - 1]) : nil
            nextTiming = items.indices.contains(index + 1) ? timing(items[index + 1]) : nil
        } else {
            let orderedIndices = items.indices.sorted { lhs, rhs in
                let lhsTiming = timing(items[lhs])
                let rhsTiming = timing(items[rhs])
                return lhsTiming.startTime == rhsTiming.startTime
                    ? id(items[lhs]).uuidString < id(items[rhs]).uuidString
                    : lhsTiming.startTime < rhsTiming.startTime
            }
            guard let position = orderedIndices.firstIndex(where: {
                id(items[$0]) == targetID
            }) else { return nil }
            previousTiming = position > 0
                ? timing(items[orderedIndices[position - 1]])
                : nil
            nextTiming = orderedIndices.indices.contains(position + 1)
                ? timing(items[orderedIndices[position + 1]])
                : nil
        }
        let previousEnd = previousTiming?.endTime ?? 0
        let previousClear = previousTiming?.effectEndTime ?? 0
        let nextStart = nextTiming?.startTime ?? timelineDuration
        return EditorMotionTimelineBounds(
            previousEnd: max(previousEnd, 0),
            previousClear: max(previousClear, 0),
            nextStart: max(nextStart, 0)
        )
    }

    static func adjustedTiming(
        original: TransitionTiming,
        mode: EditorMotionTimelineEditMode,
        delta: TimeInterval,
        bounds: EditorMotionTimelineBounds,
        timelineDuration: TimeInterval
    ) -> TransitionTiming {
        guard delta.isFinite, timelineDuration.isFinite, timelineDuration > 0 else {
            return original
        }
        let previousEnd = max(bounds.previousEnd, 0)
        let previousClear = max(bounds.previousClear, 0)
        let nextStart = min(max(bounds.nextStart, 0), timelineDuration)
        let ownReturn = max(original.returnDuration, 0)
        var timing = original
        timing.preserveTransitionIntent()

        func isValid(start: TimeInterval, end: TimeInterval) -> Bool {
            let touchesPrevious = start <= previousEnd + ZoomInterpolator.adjacencyTolerance
                && start >= previousEnd - 0.000_1
            let clearsPrevious = start >= previousClear - 0.000_1
            let touchesNext = nextStart - end <= ZoomInterpolator.adjacencyTolerance
                && end <= nextStart + 0.000_1
            let clearsNext = end + ownReturn <= nextStart + 0.000_1
            return (touchesPrevious || clearsPrevious) && (touchesNext || clearsNext)
        }

        func snap(
            proposed: TimeInterval,
            lower: TimeInterval,
            upper: TimeInterval,
            candidates: [TimeInterval],
            value: (TimeInterval) -> (start: TimeInterval, end: TimeInterval)
        ) -> TimeInterval? {
            let clamped = min(max(proposed, lower), upper)
            let probe = value(clamped)
            if isValid(start: probe.start, end: probe.end) { return clamped }
            let valid = candidates.filter { candidate in
                guard candidate >= lower - 0.000_1, candidate <= upper + 0.000_1 else { return false }
                let probe = value(candidate)
                return isValid(start: probe.start, end: probe.end)
            }
            return valid.min { abs($0 - proposed) < abs($1 - proposed) }
        }

        switch mode {
        case .move:
            let lower = previousEnd
            let upper = nextStart - original.duration
            // 间隙连片段区间本身都放不下（贴住两侧也不够长）：拒绝移动。
            guard upper >= previousEnd - 0.000_1 else { return original }
            let proposed = original.startTime + delta
            let candidates = [previousEnd, previousClear, upper, upper - ownReturn]
            guard let start = snap(
                proposed: proposed,
                lower: lower,
                upper: max(upper, lower),
                candidates: candidates,
                value: { ($0, $0 + original.duration) }
            ) else { return original }
            timing.startTime = start

        case .leading:
            let lower = previousEnd
            let upper = original.endTime - minimumDuration
            guard upper >= previousEnd - 0.000_1 else { return original }
            let proposed = original.startTime + delta
            let candidates = [previousEnd, previousClear, upper]
            guard let start = snap(
                proposed: proposed,
                lower: lower,
                upper: max(upper, lower),
                candidates: candidates,
                value: { ($0, original.endTime) }
            ) else { return original }
            timing.startTime = start
            timing.duration = original.endTime - start

        case .trailing:
            let lower = original.startTime + minimumDuration
            let upper = nextStart
            let proposed = original.endTime + delta
            let candidates = [upper, upper - ownReturn, lower]
            guard let end = snap(
                proposed: proposed,
                lower: lower,
                upper: max(upper, lower),
                candidates: candidates,
                value: { (original.startTime, $0) }
            ) else { return original }
            timing.duration = end - original.startTime
        }
        if abs(timing.startTime - original.startTime) > 0.000_001 {
            timing.leadInDuration = min(timing.requestedLeadInDuration, timing.duration)
            timing.leadInProgressOffset = 0
        }
        if abs(timing.endTime - original.endTime) > 0.000_001 {
            timing.returnProgressOffset = 0
        }
        return timing
    }
}

enum EditorTimelineScrollWheelIntent: Equatable {
    case horizontalScroll
    case zoom
}

enum EditorTimelineScrollWheelPolicy {
    static func intent(deltaX: CGFloat, deltaY: CGFloat) -> EditorTimelineScrollWheelIntent {
        // Precision trackpads often report a small Y component during a
        // deliberate horizontal swipe. Let NSScrollView consume that gesture;
        // treating the noise as zoom changes the whole document width and is
        // perceived as a hard hitch in the middle of scrolling.
        abs(deltaX) > abs(deltaY) ? .horizontalScroll : .zoom
    }
}

enum EditorTimelineRangeCreationPolicy {
    static let minimumHorizontalDrag: CGFloat = 4

    static func shouldCommit(horizontalTranslation: CGFloat) -> Bool {
        horizontalTranslation.isFinite
            && abs(horizontalTranslation) >= minimumHorizontalDrag
    }
}

struct EditorTimelineRulerTick: Equatable {
    let time: TimeInterval
    let isMajor: Bool
}

struct EditorTimelineRulerScaleLayer: Equatable {
    let majorStep: TimeInterval
    let opacity: Double
}

/// Fixed nine marks leave a highly zoomed viewport with no readable time
/// context. Choose pleasant intervals from the actual document width instead.
enum EditorTimelineRulerPresentation {
    static func majorStep(
        duration: TimeInterval,
        width: CGFloat,
        targetSpacing: CGFloat = 128
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else { return 1 }
        let rawStep = duration / max(Double(width / max(targetSpacing, 1)), 1)
        let magnitude = pow(10, floor(log10(max(rawStep, 0.000_1))))
        let normalized = rawStep / magnitude
        let nice: Double
        if normalized <= 1 { nice = 1 }
        else if normalized <= 2 { nice = 2 }
        else if normalized <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * magnitude
    }

    /// A ruler needs readable 1/2/5 time divisions, but replacing the complete
    /// tick set at each division boundary makes an otherwise continuous zoom
    /// look like it jumped. Blend the adjacent levels across the whole scale
    /// interval so the finer ticks arrive progressively and the coarser ticks
    /// leave at the same rate.
    static func scaleLayers(
        duration: TimeInterval,
        width: CGFloat,
        targetSpacing: CGFloat = 128
    ) -> [EditorTimelineRulerScaleLayer] {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else {
            return []
        }
        let rawStep = duration / max(Double(width / max(targetSpacing, 1)), 1)
        let coarseStep = majorStep(
            duration: duration,
            width: width,
            targetSpacing: targetSpacing
        )
        let fineStep = nextFinerStep(than: coarseStep)
        let denominator = log(coarseStep / fineStep)
        let rawProgress = denominator > 0
            ? log(coarseStep / max(rawStep, fineStep)) / denominator
            : 0
        let progress = min(max(rawProgress, 0), 1)
        if progress <= 0.001 {
            return [EditorTimelineRulerScaleLayer(majorStep: coarseStep, opacity: 1)]
        }
        if progress >= 0.999 {
            return [EditorTimelineRulerScaleLayer(majorStep: fineStep, opacity: 1)]
        }
        return [
            EditorTimelineRulerScaleLayer(
                majorStep: coarseStep,
                opacity: 1 - progress
            ),
            EditorTimelineRulerScaleLayer(
                majorStep: fineStep,
                opacity: progress
            ),
        ]
    }

    /// Build only the ticks inside the buffered viewport. This removes the old
    /// full-document array replacement at a ruler level boundary and keeps the
    /// synchronous Canvas cheap even for a multi-hour project at 120×.
    static func visibleTicks(
        majorStep: TimeInterval,
        duration: TimeInterval,
        width: CGFloat,
        visibleRange: ClosedRange<CGFloat>,
        guardBand: CGFloat = 80
    ) -> [EditorTimelineRulerTick] {
        guard majorStep.isFinite, majorStep > 0,
              duration.isFinite, duration > 0,
              width.isFinite, width > 0 else {
            return []
        }
        let lower = max(visibleRange.lowerBound - max(guardBand, 0), 0)
        let upper = min(visibleRange.upperBound + max(guardBand, 0), width)
        let lowerTime = duration * Double(lower / width)
        let upperTime = duration * Double(upper / width)
        let minorStep = majorStep / 2
        let firstIndex = max(Int(floor(lowerTime / minorStep)) - 1, 0)
        let finalIndex = min(
            Int(ceil(upperTime / minorStep)) + 1,
            Int(floor(duration / minorStep))
        )
        guard finalIndex >= firstIndex else { return [] }
        return (firstIndex...finalIndex).map { index in
            EditorTimelineRulerTick(
                time: min(Double(index) * minorStep, duration),
                isMajor: index.isMultiple(of: 2)
            )
        }
    }

    private static func nextFinerStep(than step: TimeInterval) -> TimeInterval {
        guard step.isFinite, step > 0 else { return 0.5 }
        let magnitude = pow(10, floor(log10(step)))
        let normalized = step / magnitude
        if normalized <= 1.000_001 { return 5 * magnitude / 10 }
        if normalized <= 2.000_001 { return magnitude }
        return 2 * magnitude
    }
}

/// 桥接 SwiftUI ScrollView 与底层 NSScrollView：滚轮缩放需要读/写真实滚动
/// 偏移，macOS 14 没有 scrollPosition API 可用，只能从 enclosingScrollView 取。
struct TimelineScrollViewBridge: NSViewRepresentable {
    let playbackController: EditorPlaybackController
    let onResolve: (NSScrollView?) -> Void

    @MainActor
    final class Coordinator: NSObject, EditorPlaybackTimelineObserver {
        weak var resolvedScrollView: NSScrollView?
        weak var playbackController: EditorPlaybackController?
        var resolutionIsScheduled = false
        private var previousIsPlaying: Bool?

        func configure(playbackController: EditorPlaybackController) {
            guard self.playbackController !== playbackController else { return }
            self.playbackController?.removeNativeTimelineObserver(self)
            previousIsPlaying = nil
            self.playbackController = playbackController
            playbackController.addNativeTimelineObserver(self)
        }

        func resolve(_ scrollView: NSScrollView?) {
            resolvedScrollView = scrollView
        }

        func invalidate() {
            playbackController?.removeNativeTimelineObserver(self)
            playbackController = nil
            resolvedScrollView = nil
            previousIsPlaying = nil
        }

        func editorPlaybackTimelineDidUpdate(
            _ snapshot: EditorPlaybackTimelineSnapshot
        ) {
            let previous = previousIsPlaying
            previousIsPlaying = snapshot.isPlaying
            // Initial attachment and ordinary clock ticks never move the
            // viewport. Only a real play/pause transition may reveal it.
            guard let previous, previous != snapshot.isPlaying,
                  snapshot.allowsViewportReveal,
                  let playbackController else { return }
            // Pause publishes its state before the final sampled time. Wait
            // until that synchronous operation finishes, then use the actual
            // stopped position rather than the preceding display refresh.
            DispatchQueue.main.async { [weak self, weak playbackController] in
                guard let self, let playbackController,
                      self.playbackController === playbackController else { return }
                self.revealPlayheadIfOutsideViewport(
                    outputTime: playbackController.outputTime,
                    duration: playbackController.duration
                )
            }
        }

        private func revealPlayheadIfOutsideViewport(
            outputTime: TimeInterval,
            duration: TimeInterval
        ) {
            guard let scrollView = resolvedScrollView,
                  outputTime.isFinite,
                  duration.isFinite,
                  duration > 0 else { return }
            let clipView = scrollView.contentView
            let viewportWidth = max(clipView.bounds.width, 1)
            let documentWidth = max(
                scrollView.documentView?.bounds.width ?? viewportWidth,
                viewportWidth
            )
            let progress = min(max(outputTime / duration, 0), 1)
            let playheadX = documentWidth * CGFloat(progress)
            guard playheadX < clipView.bounds.minX ||
                  playheadX > clipView.bounds.maxX else { return }
            let maximumOffset = max(documentWidth - viewportWidth, 0)
            let targetOffset = min(
                max(playheadX - viewportWidth / 2, 0),
                maximumOffset
            )
            guard abs(clipView.bounds.origin.x - targetOffset) > 0.5 else { return }
            clipView.scroll(
                to: NSPoint(x: targetOffset, y: clipView.bounds.origin.y)
            )
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.configure(playbackController: playbackController)
        resolveScrollView(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(playbackController: playbackController)
        resolveScrollView(for: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    func resolveScrollView(for view: NSView, coordinator: Coordinator) {
        guard !coordinator.resolutionIsScheduled else { return }
        coordinator.resolutionIsScheduled = true
        DispatchQueue.main.async {
            coordinator.resolutionIsScheduled = false
            let resolved = view.enclosingScrollView
            guard coordinator.resolvedScrollView !== resolved else { return }
            coordinator.resolve(resolved)
            // The timeline document owns the complete 0...duration range.
            // Native content/scroller insets create unreachable-looking air
            // at both ends when the document is highly zoomed.
            resolved?.automaticallyAdjustsContentInsets = false
            resolved?.contentInsets = NSEdgeInsets()
            resolved?.scrollerInsets = NSEdgeInsets()
            resolved?.horizontalScrollElasticity = .none
            onResolve(resolved)
        }
    }
}

/// Keeps interactive timeline views bounded to the portion of the document
/// that can actually become visible. The native scroll view still owns the
/// complete document and all hit testing continues to use the complete model;
/// this only limits SwiftUI view creation to a buffered viewport window.
enum EditorTimelineViewportPresentation {
    /// Bounds notifications are coalesced for scrolling performance. A
    /// structural edit can render before that notification is delivered, so
    /// culling must read the live native viewport whenever it is available.
    static func visibleDocumentRange(
        documentWidth: CGFloat,
        nativeVisibleRect: CGRect?,
        fallback: ClosedRange<CGFloat>
    ) -> ClosedRange<CGFloat> {
        let width = max(documentWidth.isFinite ? documentWidth : 0, 1)
        let range: ClosedRange<CGFloat>
        if let rect = nativeVisibleRect,
           rect.minX.isFinite, rect.maxX.isFinite, rect.width > 1, rect.height > 0 {
            range = rect.minX...rect.maxX
        } else {
            range = fallback
        }
        let lower = min(max(range.lowerBound, 0), width)
        let upper = min(max(range.upperBound, lower), width)
        return lower...upper
    }

    static func bufferedDocumentRange(
        documentWidth: CGFloat,
        visibleRange: ClosedRange<CGFloat>,
        minimumGuardBand: CGFloat = 160
    ) -> ClosedRange<CGFloat> {
        let safeWidth = max(documentWidth.isFinite ? documentWidth : 0, 1)
        let lower = min(max(visibleRange.lowerBound, 0), safeWidth)
        let upper = min(max(visibleRange.upperBound, lower), safeWidth)
        let measuredViewportWidth = upper - lower
        // Before TimelineScrollViewBridge resolves, 0...1 is only a sentinel.
        // Prepare a realistic first viewport instead of briefly materializing
        // either the complete document or a one-point strip.
        let viewportWidth = measuredViewportWidth > 1
            ? measuredViewportWidth
            : min(safeWidth, 1_200)
        let bucketWidth = max(viewportWidth / 2, minimumGuardBand)
        let windowBucket = max(Int(floor(lower / bucketWidth)) - 1, 0)
        let origin = CGFloat(windowBucket) * bucketWidth
        let end = min(max(origin + bucketWidth * 4, upper), safeWidth)
        return origin...max(end, min(origin + 1, safeWidth))
    }

    static func bufferedTimeRange(
        documentWidth: CGFloat,
        duration: TimeInterval,
        visibleRange: ClosedRange<CGFloat>,
        minimumGuardBand: CGFloat = 160
    ) -> ClosedRange<TimeInterval> {
        guard duration.isFinite, duration > 0 else { return 0...0 }
        let safeWidth = max(documentWidth.isFinite ? documentWidth : 0, 1)
        let documentRange = bufferedDocumentRange(
            documentWidth: safeWidth,
            visibleRange: visibleRange,
            minimumGuardBand: minimumGuardBand
        )
        let lower = duration * Double(documentRange.lowerBound / safeWidth)
        let upper = duration * Double(documentRange.upperBound / safeWidth)
        return lower...upper
    }

    /// Intervals are ordered and non-overlapping, so both viewport boundaries
    /// can be found without rescanning a long project on every scroll bucket.
    /// A small number of explicitly retained indices keeps an active offscreen
    /// selection or drag alive without turning that lookup back into O(n).
    static func visibleIntervalIndices<Element>(
        in elements: [Element],
        timeRange: ClosedRange<TimeInterval>,
        startTime: (Element) -> TimeInterval,
        endTime: (Element) -> TimeInterval,
        retainingIndices: [Int] = []
    ) -> [Int] {
        var lower = elements.startIndex
        var upper = elements.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if endTime(elements[middle]) < timeRange.lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let start = lower

        upper = elements.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if startTime(elements[middle]) <= timeRange.upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let end = lower

        let retained = Array(Set(retainingIndices.filter(elements.indices.contains))).sorted()
        var result: [Int] = []
        result.reserveCapacity(end - start + retained.count)
        result.append(contentsOf: retained.lazy.filter { $0 < start })
        result.append(contentsOf: start..<end)
        result.append(contentsOf: retained.lazy.filter { $0 >= end })
        return result
    }

    /// Point markers are ordered by output time. Binary search prevents a
    /// long pointer-event recording from being scanned on every scroll bucket.
    static func visiblePointIndices<Element>(
        in elements: [Element],
        timeRange: ClosedRange<TimeInterval>,
        time: (Element) -> TimeInterval
    ) -> Range<Int> {
        var lower = elements.startIndex
        var upper = elements.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if time(elements[middle]) < timeRange.lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let start = lower
        upper = elements.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if time(elements[middle]) <= timeRange.upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return start..<lower
    }
}

struct EditorTimelineWaveformPresentation {
    struct VisibleWindow: Equatable {
        let documentOriginX: CGFloat
        let width: CGFloat
        let outputStart: TimeInterval
        let outputDuration: TimeInterval
    }

    static func bufferedVisibleRange(
        documentWidth: CGFloat,
        visibleRange: ClosedRange<CGFloat>,
        minimumGuardBand: CGFloat = 160,
        samplingSpacing: CGFloat = 2
    ) -> ClosedRange<CGFloat> {
        let safeWidth = max(documentWidth.isFinite ? documentWidth : 0, 1)
        let bufferedRange = EditorTimelineViewportPresentation.bufferedDocumentRange(
            documentWidth: safeWidth,
            visibleRange: visibleRange,
            minimumGuardBand: minimumGuardBand
        )
        let rawOrigin = bufferedRange.lowerBound
        let rawEnd = bufferedRange.upperBound
        let spacing = max(samplingSpacing, 1)
        let snappedOrigin = max(floor(rawOrigin / spacing) * spacing, 0)
        let snappedEnd = min(ceil(rawEnd / spacing) * spacing, safeWidth)
        return snappedOrigin...max(snappedEnd, snappedOrigin + 1)
    }

    /// A highly zoomed timeline can be tens of thousands of points wide, but
    /// only about one viewport contributes visible waveform pixels. Keep one
    /// extra half-viewport on either side and move the window in half-viewport
    /// buckets. Small horizontal scrolls then reuse the exact same equatable
    /// Canvas instead of resampling both audio lanes on every native bounds
    /// notification.
    static func visibleWindow(
        documentWidth: CGFloat,
        outputDuration: TimeInterval,
        visibleRange: ClosedRange<CGFloat>,
        minimumGuardBand: CGFloat = 160,
        samplingSpacing: CGFloat = 2
    ) -> VisibleWindow {
        let safeWidth = max(documentWidth.isFinite ? documentWidth : 0, 1)
        let safeDuration = max(outputDuration.isFinite ? outputDuration : 0, 0.001)
        // Before the NSScrollView bridge resolves, the range is 0...1. The
        // helper substitutes a realistic viewport instead of briefly drawing
        // the whole zoomed document or showing only one point of waveform.
        // Its snapped boundaries also keep the two-pixel sampling phase stable
        // when the buffered window moves.
        let bufferedRange = bufferedVisibleRange(
            documentWidth: safeWidth,
            visibleRange: visibleRange,
            minimumGuardBand: minimumGuardBand,
            samplingSpacing: samplingSpacing
        )
        let snappedOrigin = bufferedRange.lowerBound
        let snappedEnd = bufferedRange.upperBound
        let windowWidth = max(snappedEnd - snappedOrigin, 1)
        return VisibleWindow(
            documentOriginX: snappedOrigin,
            width: windowWidth,
            outputStart: safeDuration * Double(snappedOrigin / safeWidth),
            outputDuration: safeDuration * Double(windowWidth / safeWidth)
        )
    }

    /// 波形不自己猜剪辑后的时间：先通过与预览/导出相同的
    /// `TimelineMediaPlan` 回到音频母片时间，再取实际 PCM 峰值。
    static func peak(
        samples: [Double],
        sourceRange: MediaTimeRange,
        plan: TimelineMediaPlan,
        atOutputTime outputTime: TimeInterval
    ) -> Double {
        guard !samples.isEmpty,
              let sourceTime = plan.sourceTime(atOutputTime: outputTime),
              sourceTime >= sourceRange.start,
              sourceTime < sourceRange.end else { return 0 }
        let progress = (sourceTime - sourceRange.start) / sourceRange.duration
        let index = min(max(Int(progress * Double(samples.count)), 0), samples.count - 1)
        return samples[index]
    }

    /// Normalize typical audible peaks instead of a single transient outlier.
    /// This affects only display; mute and authored segment gains still apply afterwards.
    static func displayAmplitudeGain(samples: [Double]) -> Double {
        var histogram = [Int](repeating: 0, count: 256)
        var audibleCount = 0
        for sample in samples where sample.isFinite && sample >= 0.03 {
            histogram[min(Int(min(sample, 1) * 255), 255)] += 1
            audibleCount += 1
        }
        guard audibleCount > 0 else { return 1 }
        let target = max(Int(Double(audibleCount) * 0.90), 1)
        var accumulated = 0
        for index in histogram.indices {
            accumulated += histogram[index]
            if accumulated >= target {
                return min(max(0.90 / max(Double(index) / 255, 0.03), 1), 12)
            }
        }
        return 1
    }

    static func volumeGain(
        at outputTime: TimeInterval,
        ranges: [EditorTimelineWaveformGainRange]
    ) -> Double {
        var lower = ranges.startIndex
        var upper = ranges.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].endTime <= outputTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < ranges.endIndex,
              outputTime >= ranges[lower].startTime else { return 0 }
        return ranges[lower].gain
    }
}

struct EditorTimelineWaveformData: Equatable, Sendable {
    let version: EditorMediaFileVersion
    let sourceRange: MediaTimeRange
    let samples: [Double]
    let displayGain: Double

    init(version: EditorMediaFileVersion, sourceRange: MediaTimeRange, samples: [Double]) {
        self.version = version
        self.sourceRange = sourceRange
        self.samples = samples
        self.displayGain = EditorTimelineWaveformPresentation.displayAmplitudeGain(samples: samples)
    }
}

struct CameraSyncAnchorDrag {
    let original: MediaSyncAnchor
    var draft: MediaSyncAnchor
}

enum EditorTimelineWaveformLane: Equatable {
    case system
    case microphone

    var title: String {
        switch self {
        case .system: appLocalized("系统")
        case .microphone: appLocalized("麦克风")
        }
    }


}

struct EditorTimelineWaveformGainRange: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let gain: Double

    init(startTime: TimeInterval, endTime: TimeInterval, gain: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.gain = min(max(gain.isFinite ? gain : 0, 0), 1)
    }
}

enum EditorTimelineWaveformLoader {
    static func load(
        input: EditorMediaInput?,
        sourceRange: MediaTimeRange?,
        cached: EditorTimelineWaveformData?
    ) async -> EditorTimelineWaveformData? {
        guard let input, let sourceRange else { return nil }
        if let cached,
           cached.version == input.version,
           cached.sourceRange == sourceRange {
            return cached
        }
        // 高密度采样支持超高缩放（120x）下每帧拥有 4~8 个采样点，细节更丰富。
        let sampleCount = min(max(Int(sourceRange.duration * 240), 1024), 36_000)
        if let samples = await EditorTimelineWaveformCache.shared.samples(
            for: input,
            sourceRange: sourceRange,
            sampleCount: sampleCount
        ) {
            return EditorTimelineWaveformData(
                version: input.version,
                sourceRange: sourceRange,
                samples: samples
            )
        }
        guard let samples = try? await MediaAnalyzer.waveform(
            input.url,
            sampleCount: sampleCount
        ) else { return nil }
        guard !Task.isCancelled else { return nil }
        await EditorTimelineWaveformCache.shared.store(
            samples,
            for: input,
            sourceRange: sourceRange,
            sampleCount: sampleCount
        )
        return EditorTimelineWaveformData(
            version: input.version,
            sourceRange: sourceRange,
            samples: samples
        )
    }
}

/// Owns timeline-only presentation and gesture state. The editor remains the
/// source of truth for editing and error display. Media inventory comes from
/// EditorMediaSession; transport and the output clock come from the sole
/// EditorPlaybackController.
struct EditorTimelineView: View {
    let context: EditorSessionContext
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    let isCameraSyncEditing: Bool
    /// Parent-window key-loss epoch. It changes even when the app itself stays
    /// active, for example when a system notification covers the editor.
    let windowDeactivationRevision: UInt64
    let panelHeight: CGFloat
    let layout: EditorWorkspaceLayout
    let onPreferredHeightChange: (CGFloat, Bool) -> Void
    let isLayoutTransitioning: Bool
    @Binding var visibleTracks: EditorTimelineTrackVisibility
    @Binding var selectedPrimarySegmentIDs: Set<UUID>
    let onError: (String) -> Void

    @State private var lastHeightReportLayout: EditorWorkspaceLayout?
    @State var derivedPresentationCache: EditorTimelineDerivedPresentationCache
    @State var timelineZoom: Double
    @State var timelineZoomPersistenceTask: Task<Void, Never>?
    @State var timelineContentWidth: CGFloat = 1
    @State var timelineScrollView: NSScrollView?
    @State var timelineVisibleDocumentRange: ClosedRange<CGFloat> = 0...1
    @State var timelineBoundsObservation: NSObjectProtocol?
    @State var isTimelineTrackManagerPresented = false
    @State var timelineHoverLocation = EditorTimelineHoverLocation()
    // Only an explicit Option-cut target needs to update the ruler's controls.
    @State var hoveredTimelineCutPoint: CGPoint?
    @State var timelineZoomInputCoalescer = EditorTimelineZoomInputCoalescer()
    @State var isOptionHeld = false
    @State var modifierFlagsMonitor: Any?
    @State var scrollWheelMonitor: Any?
    @State var hoverTrackingMonitor: Any?
    @State var hoverPreviewGate = EditorTimelineHoverPreviewGate()
    @State var hoveredPrimarySegmentID: UUID?
    @State var draggedPrimarySegmentID: UUID?
    @State var primarySegmentDragTranslation: CGFloat = 0
    @State var primaryReorderDraft: PrimarySegmentReorderDraft?
    @State var primaryReorderPreviewTimeline: ProjectTimeline?
    @State var primarySegmentDragDocumentX: CGFloat?
    @State var primarySegmentDragLocalMonitor: Any?
    @State var primarySegmentDragGlobalMonitor: Any?
    @State var primaryTrimDraft: PrimarySegmentTrimDraft?
    @State var primaryRetimeDraft: PrimarySegmentRetimeDraft?
    @State var isRestoreCutMode = false
    @State var usesWaveformClips: Bool
    @Namespace var displayModeSelection
    /// 时间轴悬浮预览轴开关（Skimming）：默认开启；关闭后恢复传统固定播放头模式。
    @AppStorage(AppPreferences.editorTimelineHoverPreviewEnabledKey)
    var isHoverPreviewEnabled = true
    @AppStorage("editorTimelineSnappingEnabled") var isSnappingEnabled = true
    @State var manualZoomDragStart: TimeInterval?
    @State var manualZoomDragEnd: TimeInterval?
    @State var hoveredZoomTrackLocation: CGPoint?
    @State var hoveredZoomID: UUID?
    @State var zoomGestureOrigin: ZoomAnimationClip?
    @State var zoomTrackDrag: ZoomTrackDrag?
    @State var hoveredMotionClip: EditorMotionTimelineClip?
    @State var motionGestureOrigin: EditorMotionTimelineGestureOrigin?
    @State var motionTrackDrag: MotionTrackDrag?
    @State var motionCreateDrag: MotionCreateDragState?
    @State var motionTrackHover: [EditorMotionTimelineTrack: CGPoint] = [:]
    @State var hoveredOverlaySelection: EditorSelection?
    @State var overlayTimelineDrag: EditorOverlayTimelineDrag?
    @State var overlayCreateStart: TimeInterval?
    @State var overlayCreateRange: ClosedRange<TimeInterval>?
    @State var timelineInteractionID: UUID?
    @State var emptyClickClearsSelection = false
    @StateObject var timelineSnap = EditorTimelineMagneticSnap()
    @State var gestureOwnership = EditorTimelineGestureOwnership()
    @State var deleteKeyMonitor: Any?
    @State var clipboardContextTime: TimeInterval?
    @State var clipPasteTask: Task<Void, Never>?
    @State var systemWaveform: EditorTimelineWaveformData?
    @State var microphoneWaveform: EditorTimelineWaveformData?
    @State var selectedCameraSyncAnchorID: UUID?
    @State var cameraSyncAnchorDrag: CameraSyncAnchorDrag?

    init(
        context: EditorSessionContext,
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        isCameraSyncEditing: Bool,
        windowDeactivationRevision: UInt64 = 0,
        panelHeight: CGFloat = 320,
        layout: EditorWorkspaceLayout = EditorWorkspaceLayout(size: CGSize(width: 1510, height: 980)),
        visibleTracks: Binding<EditorTimelineTrackVisibility>,
        selectedPrimarySegmentIDs: Binding<Set<UUID>>,
        onError: @escaping (String) -> Void,
        isLayoutTransitioning: Bool = false,
        onPreferredHeightChange: @escaping (CGFloat, Bool) -> Void = { _, _ in }
    ) {
        self.context = context
        self.isLayoutTransitioning = isLayoutTransitioning
        _usesWaveformClips = State(initialValue: UserDefaults.standard.bool(forKey: "cn.laogou.dogsc.editor.waveform-clips"))
        _editorStore = ObservedObject(wrappedValue: editorStore)
        _mediaSession = ObservedObject(wrappedValue: mediaSession)
        _playbackController = ObservedObject(wrappedValue: playbackController)
        self.isCameraSyncEditing = isCameraSyncEditing
        self.windowDeactivationRevision = windowDeactivationRevision
        self.panelHeight = panelHeight
        self.layout = layout
        self.onPreferredHeightChange = onPreferredHeightChange
        _visibleTracks = visibleTracks
        _selectedPrimarySegmentIDs = selectedPrimarySegmentIDs
        self.onError = onError
        _timelineZoom = State(
            initialValue: AppPreferences.timelineZoom(for: editorStore.project)
        )
        _timelineZoomPersistenceTask = State(initialValue: nil)
        _derivedPresentationCache = State(
            initialValue: EditorTimelineDerivedPresentationCache()
        )
    }

    var playbackTime: TimeInterval { playbackController.outputTime }

    static func resolvedDuration(
        sourceInventory: MediaAssetInventory,
        project: RecorderProject
    ) -> TimeInterval {
        let fullSourceDuration = sourceInventory.videoTimeRange?.duration ?? 0
        guard let map = try? EditorPrimaryTimelinePresentation.timelineMap(
            fullSourceDuration: fullSourceDuration,
            project: project
        ) else { return 0 }
        return map.outputDuration
    }

    var sourceInventory: MediaAssetInventory { mediaSession.inventories.source }

    var fullSourceDuration: TimeInterval {
        sourceInventory.videoTimeRange?.duration ?? 0
    }

    var timelineMap: TimelineMap? {
        // Structural edits are committed to the project before AVFoundation
        // finishes rebuilding preview media. Derive lane geometry and the
        // displayed total immediately from that committed sequence; otherwise
        // clips move first while the clock keeps the previous duration and
        // then visibly snaps into place when preparation completes.
        if fullSourceDuration > 0,
           let current = derivedPresentationCache.timelineMap(
               sourceSequence: editorStore.project.timeline.sourceSequence,
               fullSourceDuration: fullSourceDuration
           ) {
            return current
        }
        return mediaSession.mediaPlan?.timelineMap
    }

    var timelineDuration: TimeInterval {
        if let currentDuration = timelineMap?.outputDuration,
           currentDuration > 0 {
            return currentDuration
        }
        if mediaSession.outputDuration > 0 {
            return mediaSession.outputDuration
        }
        let project = editorStore.project
        let zoomEnd = project.zoomAnimations.map(\.endTime).max() ?? 0
        let screenMotionEnd = project.timeline.screenMotionClips
            .map(\.timing.endTime).max() ?? 0
        let cameraMotionEnd = project.timeline.cameraMotionClips
            .map(\.timing.endTime).max() ?? 0
        let mosaicEnd = project.timeline.mosaicClips
            .map(\.timing.endTime).max() ?? 0
        let stickerEnd = project.timeline.stickerClips
            .map(\.timing.endTime).max() ?? 0
        let effectEnd = [
            zoomEnd,
            screenMotionEnd,
            cameraMotionEnd,
            mosaicEnd,
            stickerEnd,
        ].max() ?? 0
        return max(effectEnd, 1)
    }

    /// Convert the stable viewport hover to document coordinates only when a
    /// timeline operation actually needs it. NSScrollView moves its cached
    /// document layers without publishing a SwiftUI state change per pixel.
    var hoveredTimelineViewportX: CGFloat? { timelineHoverLocation.viewportPoint?.x }
    var hoveredTimelineViewportY: CGFloat? { timelineHoverLocation.viewportPoint?.y }

    var hoveredTimelineContentX: CGFloat? {
        hoveredTimelineViewportX.map {
            $0 + (timelineScrollView?.documentVisibleRect.origin.x ?? 0)
        }
    }

    var hoveredTimelineTime: TimeInterval? {
        hoveredTimelineContentX.map { contentX in
            EditorTimelineMath.clampedTime(
                atX: Double(contentX),
                width: Double(max(timelineContentWidth, 1)),
                duration: timelineDuration
            )
        }
    }

    var hoveredTimelineContentY: CGFloat? {
        hoveredTimelineViewportY
    }

    var selectedZoomID: UUID? {
        get {
            guard case let .zoom(id) = editorStore.selection else { return nil }
            return id
        }
        nonmutating set {
            editorStore.selection = newValue.map(EditorSelection.zoom) ?? .zoomTrack
        }
    }

    var selectedPrimarySegmentID: UUID? {
        EditorTimelineSelectionPresentation.primarySegmentID(from: editorStore.selection)
    }

    var selectedScreenMotionID: UUID? {
        guard case let .screenMotion(id) = editorStore.selection else { return nil }
        return id
    }

    var selectedCameraMotionID: UUID? {
        guard case let .cameraMotion(id) = editorStore.selection else { return nil }
        return id
    }

    /// One activation path for mouse, keyboard and accessibility. Timed clips
    /// reveal themselves only when the playhead is outside their authored
    /// interval, so an intentional frame inside the clip is never disturbed.
    func activateTimelineSelection(_ selection: EditorSelection) {
        primaryTrimDraft = nil
        primaryRetimeDraft = nil
        editorStore.selection = selection
        guard let revealTime = EditorTimelineSelectionReveal.time(
            for: selection,
            in: editorStore.project,
            currentTime: playbackTime,
            outputDuration: timelineDuration
        ) else { return }
        playbackController.seek(to: revealTime, pausing: true)
    }

    var showsScreenMotionTimeline: Bool {
        visibleTracks.contains(.screenMotion)
    }

    var showsCameraMotionTimeline: Bool {
        visibleTracks.contains(.cameraMotion)
    }

    var showsZoomTimeline: Bool { visibleTracks.contains(.zoom) }

    var showsOverlayTimeline: Bool {
        !visibleTracks.intersection(.overlays).isEmpty
    }

    var showsSystemWaveform: Bool {
        mediaSession.inventories.source.hasAudio
    }

    var showsMicrophoneWaveform: Bool {
        mediaSession.inventories.microphone.hasAudio
    }

    var showsClipWaveforms: Bool {
        showsSystemWaveform || showsMicrophoneWaveform
    }

    var showsCameraSyncTimeline: Bool {
        isCameraSyncEditing && editorStore.project.media?.camera != nil
    }

    var cameraSyncAnchors: [MediaSyncAnchor] {
        editorStore.project.media?.camera?.syncAnchors ?? []
    }

    var cameraSyncBaselineOffset: TimeInterval {
        guard let camera = editorStore.project.media?.camera else { return 0 }
        let microphoneStart = editorStore.project.media?.microphone?.sourceStartTime ?? 0
        return camera.sourceStartTime - microphoneStart
    }

    /// A lip-sync correction smaller than one captured camera frame is hard to
    /// judge by eye. Keep 40 ms as the useful minimum even for higher-FPS
    /// sources, while slower cameras still advance by one native frame.
    var cameraSyncAdjustmentStep: TimeInterval {
        let frameRate = max(mediaSession.inventories.camera.videoFrameRate ?? 25, 1)
        return max(1 / frameRate, 0.040)
    }

    var cameraSyncAdjustmentStepMilliseconds: Int {
        Int((cameraSyncAdjustmentStep * 1_000).rounded())
    }

    var body: some View {
        let duration = max(timelineDuration, 0.001)
        return VStack(spacing: 0) {
            timelineControls(duration: duration)
            Divider()
                .overlay(dividerColor)
                .frame(height: timelineDividerHeight)
            GeometryReader { geometry in
                let viewportWidth = max(geometry.size.width - timelineLabelWidth, 1)
                let contentWidth = viewportWidth * CGFloat(timelineZoom)

                ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    timelineLabels
                        .frame(width: timelineLabelWidth)

                    ScrollView(.horizontal, showsIndicators: false) {
                        timelineCanvas(width: contentWidth, duration: duration)
                            .allowsHitTesting(!isLayoutTransitioning)
                            .background {
                                TimelineScrollViewBridge(
                                    playbackController: playbackController
                                ) { resolved in
                                    guard timelineScrollView !== resolved else { return }
                                    timelineScrollView = resolved
                                    installTimelineBoundsObservation(on: resolved)
                                }
                                .frame(width: 0, height: 0)
                            }
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .ended = phase {
                            clearTimelineHoverLocation()
                        }
                    }
                }
                .frame(height: timelineDocumentHeight, alignment: .top)
                .background { timelineRowGrid }
                .background { Color.clear.contentShape(Rectangle()).onTapGesture { clearTimelineSelection() } }
                .overlay(alignment: .topLeading) {
                    NativeTimelinePlayheadView(
                        playbackController: playbackController,
                        duration: duration,
                        part: .knob,
                        scrollView: timelineScrollView,
                        leadingInset: timelineLabelWidth,
                        documentWidth: contentWidth
                    )
                    .frame(height: timelineCanvasHeight)
                    .allowsHitTesting(false)
                }
                }
                .onAppear { timelineContentWidth = contentWidth }
                .onChange(of: contentWidth) { _, newValue in
                    timelineContentWidth = newValue
                }
            }
            .frame(height: timelineViewportHeight)
            HStack(spacing: 0) {
                Color.clear.frame(width: timelineLabelWidth)
                NativeTimelineOverviewView(
                    scrollView: timelineScrollView,
                    playbackController: playbackController,
                    duration: duration
                )
                .accessibilityLabel("时间线总览")
                .accessibilityValue(
                    "当前缩放 \(String(format: "%.1f", timelineZoom)) 倍；拖动可定位"
                )
                .help("拖动总览快速定位播放头和当前可视范围")
            }
            .frame(height: timelineOverviewHeight)

        }
        .frame(height: timelineHeight)
        .onChange(of: preferredPanelHeight, initial: true) { _, height in
            // Live window resizing must follow the pointer, without repeatedly
            // starting the track-expansion animation or disabling gestures.
            let animate = lastHeightReportLayout == layout
            lastHeightReportLayout = layout
            onPreferredHeightChange(height, animate)
        }
        .background(EditorTheme.panelSurface)
        // The parent freezes the preview raster during workspace reflow; the
        // timeline may animate its layout without issuing intermediate renders.
        .onChange(of: editorStore.project.timeline) { _, _ in
            // A ripple edit can remove the SwiftUI view that owned the current
            // mouse sequence before `onEnded` arrives. End every local gesture
            // together with the structural timeline change; otherwise a dead
            // zoom/motion ID can continue intercepting the next drag.
            recoverAbandonedTimelineGesture()
            // 媒体重建会置换传输层与输出端点，悬浮预览的所指时刻随之失效。
            playbackController.endHoverPreview()
            let reconciledSelection = EditorTimelineSelectionPresentation.reconcilingPrimarySelection(
                editorStore.selection,
                sourceSequence: editorStore.project.timeline.sourceSequence
            )
            if reconciledSelection != editorStore.selection {
                editorStore.selection = reconciledSelection
            }
            switch editorStore.selection {
            case let .screenMotion(id)
                where !editorStore.project.timeline.screenMotionClips.contains(where: { $0.id == id }):
                editorStore.selection = .screenMotionTrack
            case let .cameraMotion(id)
                where !editorStore.project.timeline.cameraMotionClips.contains(where: { $0.id == id }):
                editorStore.selection = .camera
            case let .zoom(id)
                where !editorStore.project.zoomAnimations.contains(where: { $0.id == id }):
                editorStore.selection = .zoomTrack
            case let .mosaic(id)
                where !editorStore.project.timeline.mosaicClips.contains(where: { $0.id == id }):
                editorStore.selection = .canvas
            case let .sticker(id)
                where !editorStore.project.timeline.stickerClips.contains(where: { $0.id == id }):
                editorStore.selection = .canvas
            default:
                break
            }
            if let hoveredZoomID,
               !editorStore.project.zoomAnimations.contains(where: { $0.id == hoveredZoomID }) {
                self.hoveredZoomID = nil
            }
            if let hoveredMotionClip {
                let stillExists: Bool
                switch hoveredMotionClip.track {
                case .screen:
                    stillExists = editorStore.project.timeline.screenMotionClips.contains {
                        $0.id == hoveredMotionClip.id
                    }
                case .camera:
                    stillExists = editorStore.project.timeline.cameraMotionClips.contains {
                        $0.id == hoveredMotionClip.id
                    }
                }
                if !stillExists { self.hoveredMotionClip = nil }
            }
        }
        .onChange(of: editorStore.interaction?.id) { _, id in
            if let owned = timelineInteractionID, owned != id { cancelActiveTimelineGesture() }
        }
        .onChange(of: editorStore.selection) { _, selection in
            if selectedCameraSyncAnchorID != nil {
                dismissCameraSyncSelection()
            }
            guard case let .primarySegment(id) = selection,
                  primaryTrimDraft?.segmentID == id
                    || primaryRetimeDraft?.segmentID == id else {
                primaryTrimDraft = nil
                primaryRetimeDraft = nil
                return
            }
        }
        .onChange(of: cameraSyncAnchors) { _, anchors in
            guard let selectedCameraSyncAnchorID,
                  anchors.contains(where: { $0.id == selectedCameraSyncAnchorID }) else {
                self.selectedCameraSyncAnchorID = nil
                cameraSyncAnchorDrag = nil
                return
            }
        }
        .onChange(of: isCameraSyncEditing) { _, isEditing in
            if !isEditing { dismissCameraSyncSelection() }
        }
        .onChange(of: isSnappingEnabled) { _, _ in timelineSnap.reset() }
        .onChange(of: isHoverPreviewEnabled) { _, isEnabled in
            hoverPreviewGate.isEnabled = isEnabled
            if !isEnabled {
                playbackController.endHoverPreview()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .editorWillTogglePlaybackFromSpace)
        ) { notification in
            guard let controller = notification.object as? EditorPlaybackController,
                  controller === playbackController,
                  selectedCameraSyncAnchorID != nil
                    || playbackController.cameraSyncAuditionIsActive else { return }
            dismissCameraSyncSelection()
        }
        .onAppear(perform: installDeleteKeyMonitor)
        .onAppear(perform: installScrollWheelMonitor)
        .onAppear(perform: installHoverTrackingMonitor)
        .onAppear(perform: installModifierFlagsMonitor)
        .onAppear(perform: installPrimarySegmentDragCompletionMonitors)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in
            // A drag released over another app may not produce a SwiftUI drop
            // callback. Losing application focus is nevertheless a terminal
            // drag outcome and must clear the transient source state.
            endPrimarySegmentDrag()
        }
        .onChange(of: windowDeactivationRevision) { _, _ in
            // EDT-015/016: store-owned drafts were already cancelled at this
            // boundary, but the timeline's own drag and sync states were not.
            // End them together so no marker remains focused and no segment
            // stays dimmed after a notification or sibling panel takes key.
            cancelActiveTimelineGesture()
            dismissCameraSyncSelection()
            playbackController.endHoverPreview()
        }
        .task(id: mediaSession.prepared?.generation) {
            await loadAudioWaveforms()
        }
        .task(id: usesWaveformClips) {
            // Persist only the settled preference; rapid reversals stay local to the timeline.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            UserDefaults.standard.set(usesWaveformClips, forKey: "cn.laogou.dogsc.editor.waveform-clips")
        }
        .onDisappear {
            clipPasteTask?.cancel()
            UserDefaults.standard.set(usesWaveformClips, forKey: "cn.laogou.dogsc.editor.waveform-clips")
            persistTimelineZoomImmediately()
            cancelActiveTimelineGesture()
            endPrimarySegmentDrag()
            playbackController.cancelCameraSyncAudition()
            timelineZoomInputCoalescer.cancel()
            removeDeleteKeyMonitor()
            removeScrollWheelMonitor()
            removeHoverTrackingMonitor()
            removeModifierFlagsMonitor()
            removePrimarySegmentDragCompletionMonitors()
            removeTimelineBoundsObservation()
            playbackController.endHoverPreview()
        }
    }
}
