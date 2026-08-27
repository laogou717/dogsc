import AppKit
import RecorderCore
import SwiftUI

let editorTimelineDocumentCoordinateSpace = "editor.timeline.document"

enum EditorTimelineSizing {
    static let defaultPrimaryLaneHeight: CGFloat = 64
    static let minimumPrimaryLaneHeight: CGFloat = 56
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

struct EditorTimelineRulerTick: Identifiable, Equatable {
    let index: Int
    let time: TimeInterval
    let isMajor: Bool

    var id: Int { index }
}

struct EditorTimelineRulerLabel: Identifiable, Equatable {
    let index: Int
    let time: TimeInterval
    let x: CGFloat

    var id: Int { index }
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

    static func ticks(duration: TimeInterval, width: CGFloat) -> [EditorTimelineRulerTick] {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else { return [] }
        let majorStep = majorStep(duration: duration, width: width)
        let minorStep = majorStep / 2
        let requestedCount = Int(floor(duration / minorStep)) + 1
        // Keep even multi-hour, maximum-zoom projects bounded while preserving
        // frame-level resolution at high zoom (up to 120x).
        let strideMultiplier = max(Int(ceil(Double(requestedCount) / 2400)), 1)
        let effectiveStep = minorStep * Double(strideMultiplier)
        let count = min(Int(floor(duration / effectiveStep)) + 1, 2401)
        return (0..<count).map { index in
            let time = min(Double(index) * effectiveStep, duration)
            let majorRatio = time / majorStep
            return EditorTimelineRulerTick(
                index: index,
                time: time,
                isMajor: abs(majorRatio.rounded() - majorRatio) < 0.000_01
            )
        }
    }


    /// Labels outside the visible document rect do not contribute any useful
    /// context, but each SwiftUI Text still participates in layout. On a long
    /// project at 12× this used to keep well over a hundred off-screen labels
    /// alive during every zoom tick. Keep only the visible major labels plus a
    /// small guard band so horizontal scrolling never reveals an empty edge.
    static func visibleLabels(
        ticks: [EditorTimelineRulerTick],
        duration: TimeInterval,
        width: CGFloat,
        visibleRange: ClosedRange<CGFloat>,
        guardBand: CGFloat = 80
    ) -> [EditorTimelineRulerLabel] {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else {
            return []
        }
        let lower = max(visibleRange.lowerBound - max(guardBand, 0), 0)
        let upper = min(visibleRange.upperBound + max(guardBand, 0), width)
        let lowerTime = duration * Double(lower / width)
        let upperTime = duration * Double(upper / width)
        let timeRange = lowerTime...upperTime
        let visibleIndices = EditorTimelineViewportPresentation.visiblePointIndices(
            in: ticks,
            timeRange: timeRange,
            time: \.time
        )
        return visibleIndices.compactMap { index in
            let tick = ticks[index]
            guard tick.isMajor else { return nil }
            let position = width * CGFloat(tick.time / duration)
            return EditorTimelineRulerLabel(
                index: tick.index,
                time: tick.time,
                x: position
            )
        }
    }
}

/// 桥接 SwiftUI ScrollView 与底层 NSScrollView：滚轮缩放需要读/写真实滚动
/// 偏移，macOS 14 没有 scrollPosition API 可用，只能从 enclosingScrollView 取。
struct TimelineScrollViewBridge: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    final class Coordinator {
        weak var resolvedScrollView: NSScrollView?
        var resolutionIsScheduled = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveScrollView(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveScrollView(for: nsView, coordinator: context.coordinator)
    }

    func resolveScrollView(for view: NSView, coordinator: Coordinator) {
        guard !coordinator.resolutionIsScheduled else { return }
        coordinator.resolutionIsScheduled = true
        DispatchQueue.main.async {
            coordinator.resolutionIsScheduled = false
            let resolved = view.enclosingScrollView
            guard coordinator.resolvedScrollView !== resolved else { return }
            coordinator.resolvedScrollView = resolved
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

    /// EDT-WAVE-003 自适应振幅增益：样本是 `pow(peak, 0.72)` 的绝对响度曲
    /// 线，语音等中等响度内容的峰值只有 0.3 左右，车道（尤其分栏放大后）
    /// 里波形只占条带约三成高度、上方大片空白。以整条波形自身峰值为基准
    /// 把最大峰值映射到约 92% 条带高度；近静音轨（峰值 < 0.03）不放大底
    /// 噪，已经很热的轨不缩小，增益封顶 5× 避免把轻微内容拉成满幅假象。
    /// 波形条始终垂直居中，本增益只放大振幅。
    static func displayAmplitudeGain(samples: [Double]) -> Double {
        guard let maxPeak = samples.max(), maxPeak >= 0.03 else { return 1 }
        return min(max(0.92 / maxPeak, 1), 5)
    }
}

struct EditorTimelineWaveformData: Equatable, Sendable {
    let version: EditorMediaFileVersion
    let sourceRange: MediaTimeRange
    let samples: [Double]
}

struct CameraSyncAnchorDrag {
    let original: MediaSyncAnchor
    var draft: MediaSyncAnchor
}

struct CameraSyncAuditionRequest: Equatable {
    let id: UUID
    let outputTime: TimeInterval
    let previousPlaybackTimingRevision: UInt64
}

enum EditorTimelineWaveformLane: Equatable {
    case system
    case microphone

    var title: String {
        switch self {
        case .system: "系统"
        case .microphone: "麦克风"
        }
    }

    /// EDT-WAVE-003: 两路叠放在同一全高条带，靠明度分工——雾白极简下
    /// 系统声用中灰，麦克风用近白色，不再引入紫色。
    var color: Color {
        switch self {
        case .system: Color(white: 0.62)
        case .microphone: Color(red: 0.96, green: 0.99, blue: 1.0)
        }
    }

    /// 系统声略微透明，叠在麦克风下层时不喧宾夺主。
    var barOpacity: Double {
        switch self {
        case .system: 0.62
        case .microphone: 0.96
        }
    }

    /// 系统声振幅再收小一点，保持陪衬层级。
    var amplitudeFactor: Double {
        switch self {
        case .system: 0.72
        case .microphone: 1
        }
    }

    /// 系统声只画对称波形的上半截并贴条带底部；麦克风保持中线对称全幅。
    var drawsBottomRiseOnly: Bool {
        self == .system
    }
}

/// Expensive waveform sampling is isolated behind EquatableView. During a
/// trim, its width and media clock stay unchanged; only the cheap segment mask
/// moves, so pointer events never queue thousands of new Canvas bar samples.
struct EditorTimelineWaveformStripView: View, Equatable {
    let lane: EditorTimelineWaveformLane
    let waveform: EditorTimelineWaveformData
    let plan: TimelineMediaPlan
    let width: CGFloat
    let height: CGFloat
    let outputStart: TimeInterval
    let outputDuration: TimeInterval

    nonisolated static func == (
        lhs: EditorTimelineWaveformStripView,
        rhs: EditorTimelineWaveformStripView
    ) -> Bool {
        lhs.lane == rhs.lane
            && lhs.waveform.version == rhs.waveform.version
            && lhs.waveform.sourceRange == rhs.waveform.sourceRange
            && lhs.plan == rhs.plan
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.outputStart == rhs.outputStart
            && lhs.outputDuration == rhs.outputDuration
    }

    var body: some View {
        // EDT-WAVE-003：整条波形自身的自适应振幅增益，条带加高时波形同步
        // 放大并保持垂直居中，不再上方大片留白。
        let amplitudeGain = EditorTimelineWaveformPresentation.displayAmplitudeGain(
            samples: waveform.samples
        )
        Canvas(rendersAsynchronously: true) { context, size in
            let centerY = size.height / 2
            // 贴底半截波形不画中位线，底部边缘即基线。
            if !lane.drawsBottomRiseOnly {
                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: centerY))
                centerLine.addLine(to: CGPoint(x: size.width, y: centerY))
                context.stroke(
                    centerLine,
                    with: .color(lane.color.opacity(0.18)),
                    lineWidth: 1
                )
            }

            let spacing: CGFloat = 2
            let barCount = max(Int(ceil(size.width / spacing)), 1)
            var bars = Path()
            for index in 0..<barCount {
                let x = min((CGFloat(index) + 0.5) * spacing, size.width)
                let outputTime = outputStart
                    + outputDuration * Double(x / max(size.width, 1))
                let peak = EditorTimelineWaveformPresentation.peak(
                    samples: waveform.samples,
                    sourceRange: waveform.sourceRange,
                    plan: plan,
                    atOutputTime: outputTime
                )
                guard peak > 0 else { continue }
                let amplified = min(peak * amplitudeGain * lane.amplitudeFactor, 1)
                if lane.drawsBottomRiseOnly {
                    // 只保留对称波形的上半截，贴条带底部向上升起。
                    let barHeight = max(
                        CGFloat(amplified) * max(size.height - 6, 1) / 2,
                        0.5
                    )
                    bars.move(to: CGPoint(x: x, y: size.height - 3))
                    bars.addLine(to: CGPoint(x: x, y: size.height - 3 - barHeight))
                } else {
                    let halfHeight = max(
                        CGFloat(amplified) * max(size.height - 6, 1) / 2,
                        0.5
                    )
                    bars.move(to: CGPoint(x: x, y: centerY - halfHeight))
                    bars.addLine(to: CGPoint(x: x, y: centerY + halfHeight))
                }
            }
            context.stroke(
                bars,
                with: .color(lane.color.opacity(lane.barOpacity)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
        .frame(width: width, height: height)
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
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    let pointerEvents: [PointerEventRecord]
    let isCameraSyncEditing: Bool
    /// Parent-window key-loss epoch. It changes even when the app itself stays
    /// active, for example when a system notification covers the editor.
    let windowDeactivationRevision: UInt64
    let primaryLaneHeight: CGFloat
    @Binding var visibleTracks: EditorTimelineTrackVisibility
    let onError: (String) -> Void

    @State var derivedPresentationCache: EditorTimelineDerivedPresentationCache
    @State var timelineZoom: Double = 1
    @State var timelineContentWidth: CGFloat = 1
    @State var timelineScrollView: NSScrollView?
    @State var timelineVisibleDocumentRange: ClosedRange<CGFloat> = 0...1
    @State var timelineBoundsObservation: NSObjectProtocol?
    @State var hoveredTimelineViewportX: CGFloat?
    @State var hoveredTimelineViewportY: CGFloat?
    @State var timelineZoomInputCoalescer = EditorTimelineZoomInputCoalescer()
    @State var isOptionHeld = false
    @State var modifierFlagsMonitor: Any?
    @State var scrollWheelMonitor: Any?
    @State var hoverTrackingMonitor: Any?
    @State var hoveredPrimarySegmentID: UUID?
    @State var draggedPrimarySegmentID: UUID?
    @State var primarySegmentDragTranslation: CGFloat = 0
    @State var primarySegmentDragLocalMonitor: Any?
    @State var primarySegmentDragGlobalMonitor: Any?
    @State var primaryTrimDraft: PrimarySegmentTrimDraft?
    @State var primaryRetimeDraft: PrimarySegmentRetimeDraft?
    @State var isRestoreCutMode = false
    /// 时间轴鼠标点击标记开关（UX-019）：默认隐藏，避免遮挡波形；
    /// 在时间线工具栏剪辑胶囊内切换，跨会话记忆。
    @AppStorage(AppPreferences.editorTimelinePointerClickMarkersKey)
    var showsTimelinePointerClickMarkers = false
    /// 时间轴悬浮预览轴开关（Skimming）：默认开启；关闭后恢复传统固定播放头模式。
    @AppStorage(AppPreferences.editorTimelineHoverPreviewEnabledKey)
    var isHoverPreviewEnabled = true
    @State var manualZoomDragStart: TimeInterval?
    @State var manualZoomDragEnd: TimeInterval?
    @State var isZoomTrackHovered = false
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
    @State var gestureOwnership = EditorTimelineGestureOwnership()
    @State var deleteKeyMonitor: Any?
    @State var systemWaveform: EditorTimelineWaveformData?
    @State var microphoneWaveform: EditorTimelineWaveformData?
    @State var selectedCameraSyncAnchorID: UUID?
    @State var cameraSyncAnchorDrag: CameraSyncAnchorDrag?
    @State var pendingCameraSyncAudition: CameraSyncAuditionRequest?
    @State var cameraSyncAuditionTask: Task<Void, Never>?
    @State var activeCameraSyncAuditionID: UUID?

    init(
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        pointerEvents: [PointerEventRecord],
        isCameraSyncEditing: Bool,
        windowDeactivationRevision: UInt64 = 0,
        primaryLaneHeight: CGFloat = EditorTimelineSizing.defaultPrimaryLaneHeight,
        visibleTracks: Binding<EditorTimelineTrackVisibility>,
        onError: @escaping (String) -> Void
    ) {
        _editorStore = ObservedObject(wrappedValue: editorStore)
        _mediaSession = ObservedObject(wrappedValue: mediaSession)
        _playbackController = ObservedObject(wrappedValue: playbackController)
        self.pointerEvents = pointerEvents
        self.isCameraSyncEditing = isCameraSyncEditing
        self.windowDeactivationRevision = windowDeactivationRevision
        self.primaryLaneHeight = EditorTimelineSizing.clampedPrimaryLaneHeight(
            primaryLaneHeight
        )
        _visibleTracks = visibleTracks
        self.onError = onError
        _derivedPresentationCache = State(
            initialValue: EditorTimelineDerivedPresentationCache(
                pointerEvents: pointerEvents
            )
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
        mediaSession.mediaPlan?.timelineMap
    }

    var timelineDuration: TimeInterval {
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
    var showsProgressTimeline: Bool { visibleTracks.contains(.progress) }

    var showsSystemWaveform: Bool {
        mediaSession.inventories.source.hasAudio
            && !editorStore.project.audio.isSystemMuted
    }

    var showsMicrophoneWaveform: Bool {
        mediaSession.inventories.microphone.hasAudio
            && !editorStore.project.audio.isMicrophoneMuted
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
            Divider().overlay(dividerColor)
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
            .background(Color.black.opacity(0.10))
            Divider().overlay(dividerColor)
            GeometryReader { geometry in
                let viewportWidth = max(geometry.size.width - timelineLabelWidth, 1)
                let contentWidth = viewportWidth * CGFloat(timelineZoom)

                HStack(spacing: 0) {
                    timelineLabels
                        .frame(width: timelineLabelWidth)

                    ScrollView(.horizontal, showsIndicators: timelineZoom > 1.01) {
                        timelineCanvas(width: contentWidth, duration: duration)
                            .background {
                                TimelineScrollViewBridge { resolved in
                                    guard timelineScrollView !== resolved else { return }
                                    timelineScrollView = resolved
                                    installTimelineBoundsObservation(on: resolved)
                                }
                                .frame(width: 0, height: 0)
                            }
                    }
                    // PRE-005: keep hover in viewport coordinates. Attaching
                    // it to the moving document made a stationary pointer
                    // publish new SwiftUI state on every horizontal scroll
                    // tick, rebuilding all clips and waveform canvases.
                    // EDT-030: 具体位置由窗口级 mouseMoved 监视器提供（子视图的
                    // tracking area 会吞掉容器 onContinuousHover 的移动事件）；
                    // 这里只保留离开回调，兜底指针直接移出窗口时的清理。
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .ended = phase {
                            clearTimelineHoverLocation()
                        }
                    }
                }
                .onAppear { timelineContentWidth = contentWidth }
                .onChange(of: contentWidth) { _, newValue in
                    timelineContentWidth = newValue
                }
            }
            .frame(height: timelineCanvasHeight)
        }
        .frame(height: timelineHeight)
        .background(Color(red: 0.045, green: 0.047, blue: 0.055))
        // 运动/同步轨随选择显隐时，用短高度过渡代替瞬间跳动；分栏拖动改的
        // 是 primaryLaneHeight，不经过这些布尔值，拖高手感保持直连。
        .animation(.easeOut(duration: 0.16), value: showsScreenMotionTimeline)
        .animation(.easeOut(duration: 0.16), value: showsCameraMotionTimeline)
        .animation(.easeOut(duration: 0.16), value: showsOverlayTimeline)
        .animation(.easeOut(duration: 0.16), value: showsProgressTimeline)
        .animation(.easeOut(duration: 0.16), value: showsCameraSyncTimeline)
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
            case .progress where editorStore.project.timeline.progressOverlay == nil:
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
        .onChange(of: playbackController.lifecycle) { _, lifecycle in
            startPendingCameraSyncAuditionIfReady(lifecycle)
        }
        .onChange(of: playbackController.cameraTimingRevision) { _, _ in
            startPendingCameraSyncAuditionIfReady(playbackController.lifecycle)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .editorWillTogglePlaybackFromSpace)
        ) { notification in
            guard let controller = notification.object as? EditorPlaybackController,
                  controller === playbackController,
                  selectedCameraSyncAnchorID != nil
                    || pendingCameraSyncAudition != nil
                    || activeCameraSyncAuditionID != nil else { return }
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
        .onDisappear {
            cancelActiveTimelineGesture()
            endPrimarySegmentDrag()
            cancelCameraSyncAudition()
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
