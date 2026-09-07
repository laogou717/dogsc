import Foundation

public enum AutoZoomPlanner {
    public static func makeAnimations(
        for pointerEvents: [PointerEventRecord],
        zoomScale: Double = 1.6,
        easing: ZoomEasingPreset = .spring,
        transitionDuration: TimeInterval = 0.7
    ) -> [ZoomAnimationClip] {
        let clicks = pointerEvents.compactMap { event -> PointerClick? in
            guard event.kind == .leftClick || event.kind == .rightClick else { return nil }
            return PointerClick(time: event.time, location: event.location)
        }
        let duration = min(max(transitionDuration, 0), 5)
        let planned = makeAnimations(
            for: clicks,
            zoomScale: zoomScale,
            enterDuration: duration,
            exitDuration: duration,
            easing: easing
        )
        let extended = extendingAutomaticHoldsThroughPointerActivity(
            planned,
            clicks: clicks,
            pointerEvents: pointerEvents
        )
        return mergingConnectedAutomaticEnvelopes(extended)
    }

    /// Repairs the exact fully-automatic track emitted by the previous planner
    /// without touching a track the user has edited or supplemented manually.
    /// Existing recordings then keep the automatic camera alive for pointer
    /// activity after the click, just like newly recorded projects.
    public static func repairingLegacyAutomaticAnimations(
        _ animations: [ZoomAnimationClip],
        for pointerEvents: [PointerEventRecord],
        easing: ZoomEasingPreset = .cubic,
        transitionDuration: TimeInterval = 0.7
    ) -> [ZoomAnimationClip] {
        guard !animations.isEmpty,
              animations.allSatisfy({ $0.origin == .automatic }) else {
            return animations
        }
        let clicks = pointerEvents.compactMap { event -> PointerClick? in
            guard event.kind == .leftClick || event.kind == .rightClick else { return nil }
            return PointerClick(time: event.time, location: event.location)
        }
        // A previous launch may already have upgraded the project's global
        // motion default to spring while the old automatic clips stayed cubic.
        // Match both the current project default and the known legacy default,
        // then regenerate with the current default below.
        var legacyEasings = [easing]
        if easing != .cubic {
            legacyEasings.append(.cubic)
        }
        let currentDuration = min(max(transitionDuration, 0), 5)
        let matchesExpectedPlan: ([ZoomAnimationClip]) -> Bool = { expected in
            expected.count == animations.count
                && (
                    zip(animations, expected).allSatisfy({ matchesLegacyPlan($0.0, $0.1) })
                        || matchesSourceClampedAutomaticPlan(animations, expected)
                )
        }
        // The immediately preceding planner already used the current spring
        // and duration, but persisted every spatial focus group as another
        // touching clip. Fold the stored clips themselves so a source-clamped
        // final range keeps its real recording boundary.
        let currentSegmentedPlans = legacyEasings.flatMap { legacyEasing -> [[ZoomAnimationClip]] in
            let currentSegmented = makeAnimations(
                for: clicks,
                enterDuration: currentDuration,
                exitDuration: currentDuration,
                easing: legacyEasing
            )
            let activityExtendedCurrentSegmented = extendingAutomaticHoldsThroughPointerActivity(
                currentSegmented,
                clicks: clicks,
                pointerEvents: pointerEvents
            )
            return [currentSegmented, activityExtendedCurrentSegmented]
        }
        if currentSegmentedPlans.contains(where: matchesExpectedPlan) {
            return mergingConnectedAutomaticEnvelopes(animations).map { clip in
                var upgraded = clip
                upgraded.easing = easing
                return upgraded
            }
        }

        let knownLegacyPlans = legacyEasings.flatMap { legacyEasing -> [[ZoomAnimationClip]] in
            let currentLegacy = makeAnimations(
                for: clicks,
                enterDuration: 0.42,
                exitDuration: 0.44,
                easing: legacyEasing
            )
            let perClickLegacy = makePerClickLegacyAnimations(
                for: clicks,
                easing: legacyEasing
            )
            // The recorder also prolonged legacy holds through continuous
            // pointer activity before saving. Those clips can end exactly
            // where the next automatic region starts (with a zero-length
            // exit), so comparing only with click-only output misses real
            // untouched projects.
            let activityExtendedCurrentLegacy = extendingAutomaticHoldsThroughPointerActivity(
                currentLegacy,
                clicks: clicks,
                pointerEvents: pointerEvents
            )
            let activityExtendedPerClickLegacy = extendingAutomaticHoldsThroughPointerActivity(
                perClickLegacy,
                clicks: clicks,
                pointerEvents: pointerEvents
            )
            return [
                currentLegacy,
                activityExtendedCurrentLegacy,
                perClickLegacy,
                activityExtendedPerClickLegacy,
            ]
        }
        let matchesKnownAutomaticPlanner = knownLegacyPlans.contains(where: matchesExpectedPlan)
        guard matchesKnownAutomaticPlanner else { return animations }

        // Regenerate only a recognisable untouched automatic track. This
        // upgrades the old one-clip-per-click output to stable spatial click
        // groups while preserving every manual or edited track verbatim.
        let regrouped = makeAnimations(
            for: clicks,
            enterDuration: currentDuration,
            exitDuration: currentDuration,
            easing: easing
        )
        let extended = extendingAutomaticHoldsThroughPointerActivity(
            regrouped,
            clicks: clicks,
            pointerEvents: pointerEvents
        )
        return mergingConnectedAutomaticEnvelopes(extended)
    }

    /// The planner used by existing v5 projects before nearby clicks were
    /// grouped into one stable camera region. It emitted one automatic clip per
    /// click, with directly adjacent clips inside the temporal group.
    private static func makePerClickLegacyAnimations(
        for clicks: [PointerClick],
        zoomScale: Double = 1.6,
        enterDuration: TimeInterval = 0.42,
        holdDuration: TimeInterval = 0.9,
        exitDuration: TimeInterval = 0.44,
        clickGroupGap: TimeInterval = 1.4,
        safeInset: Double = 0.12,
        easing: ZoomEasingPreset
    ) -> [ZoomAnimationClip] {
        let ordered = orderedValidClicks(clicks)
        var groups: [[PointerClick]] = []
        for click in ordered {
            if let previous = groups.last?.last,
               click.time - previous.time <= clickGroupGap {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        var result: [ZoomAnimationClip] = []
        var earliestNextStart: TimeInterval = 0
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            var starts = [max(first.time - enterDuration * 0.18, earliestNextStart, 0)]
            for click in group.dropFirst() {
                starts.append(max(click.time - enterDuration, (starts.last ?? 0) + 0.16))
            }
            for index in group.indices {
                let isLast = index == group.index(before: group.endIndex)
                let end = isLast
                    ? max(last.time + holdDuration, starts[index] + enterDuration)
                    : starts[index + 1]
                result.append(ZoomAnimationClip(
                    startTime: starts[index],
                    endTime: end,
                    scale: zoomScale,
                    focus: group[index].location.constrained(to: safeInset),
                    origin: .automatic,
                    easing: easing,
                    enterDuration: enterDuration,
                    exitDuration: isLast ? exitDuration : 0
                ))
            }
            earliestNextStart = result.last?.effectEndTime ?? last.time
        }
        return result
    }

    private static func matchesLegacyPlan(
        _ candidate: ZoomAnimationClip,
        _ expected: ZoomAnimationClip
    ) -> Bool {
        let tolerance = 0.000_001
        return abs(candidate.startTime - expected.startTime) <= tolerance
            && abs(candidate.endTime - expected.endTime) <= tolerance
            && abs(candidate.scale - expected.scale) <= tolerance
            && abs(candidate.focus.x - expected.focus.x) <= tolerance
            && abs(candidate.focus.y - expected.focus.y) <= tolerance
            && candidate.easing == expected.easing
            && candidate.customCurve == expected.customCurve
            && abs(candidate.enterDuration - expected.enterDuration) <= tolerance
            && abs(candidate.exitDuration - expected.exitDuration) <= tolerance
    }

    /// A recording can stop while the final automatic envelope is still
    /// holding or returning. Project finalisation clamps that last clip to the
    /// source duration and removes the now-out-of-range exit transition. All
    /// earlier clips still match the planner byte-for-byte, so recognise only
    /// that narrowly defined final-clip difference as untouched output.
    private static func matchesSourceClampedAutomaticPlan(
        _ candidates: [ZoomAnimationClip],
        _ expected: [ZoomAnimationClip]
    ) -> Bool {
        guard candidates.count == expected.count,
              let candidateLast = candidates.last,
              let expectedLast = expected.last else { return false }
        let tolerance = 0.000_001
        guard zip(candidates.dropLast(), expected.dropLast()).allSatisfy({
            matchesLegacyPlan($0.0, $0.1)
        }) else { return false }

        return abs(candidateLast.startTime - expectedLast.startTime) <= tolerance
            && candidateLast.endTime > candidateLast.startTime
            && candidateLast.endTime < expectedLast.effectEndTime - tolerance
            && abs(candidateLast.scale - expectedLast.scale) <= tolerance
            && abs(candidateLast.focus.x - expectedLast.focus.x) <= tolerance
            && abs(candidateLast.focus.y - expectedLast.focus.y) <= tolerance
            && candidateLast.easing == expectedLast.easing
            && candidateLast.customCurve == expectedLast.customCurve
            && abs(candidateLast.enterDuration - expectedLast.enterDuration) <= tolerance
            && candidateLast.exitDuration <= tolerance
    }

    /// CAM-001/CAM-003: a click starts the automatic camera, but pointer
    /// activity determines when it is safe to leave. Keep the final stable
    /// region of each click group alive while pointer events remain continuous,
    /// then allow a short settle before the authored return transition.
    private static func extendingAutomaticHoldsThroughPointerActivity(
        _ planned: [ZoomAnimationClip],
        clicks: [PointerClick],
        pointerEvents: [PointerEventRecord],
        activityIdleGap: TimeInterval = 1.4,
        settleHold: TimeInterval = 0.55
    ) -> [ZoomAnimationClip] {
        guard !planned.isEmpty, !clicks.isEmpty else { return planned }
        let normalizedEvents = PointerEventTimelineOrdering.normalized(pointerEvents)
        let orderedEvents = normalizedEvents.allSatisfy { $0.time >= 0 }
            ? normalizedEvents
            : normalizedEvents.filter { $0.time >= 0 }
        let orderedClicks = orderedValidClicks(clicks)
        var result = planned

        for index in result.indices where result[index].exitDuration > 0.001 {
            let clip = result[index]
            guard let lastClickIndex = lastIndex(
                atOrBefore: clip.endTime + 0.000_1,
                in: orderedClicks
            ) else { continue }
            let lastClick = orderedClicks[lastClickIndex]
            guard lastClick.time >= clip.startTime - 0.000_1 else { continue }

            let nextStart = result.indices.contains(index + 1)
                ? result[index + 1].startTime
                : .infinity
            var previousActivityTime = lastClick.time
            var activityEndTime = lastClick.time
            var eventIndex = firstIndex(after: lastClick.time, in: orderedEvents)
            while eventIndex < orderedEvents.endIndex {
                let event = orderedEvents[eventIndex]
                guard event.time < nextStart - 0.000_1 else { break }
                guard event.time - previousActivityTime <= activityIdleGap else { break }
                previousActivityTime = event.time
                activityEndTime = event.time
                eventIndex = orderedEvents.index(after: eventIndex)
            }

            guard activityEndTime > lastClick.time + 0.000_1 else { continue }
            let extendedEnd = min(
                max(clip.endTime, activityEndTime + settleHold),
                nextStart
            )
            guard extendedEnd > clip.endTime + 0.000_1 else { continue }
            result[index].endTime = extendedEnd
            if nextStart.isFinite {
                // `endTime` is the end of the hold, not the end of the clip's
                // visual effect. Extending the hold without shortening its
                // return transition can make `effectEndTime` cross the next
                // clip's start and produce an invalid project. Preserve as
                // much of the authored return as fits, or hand off directly
                // when activity reaches the next region.
                result[index].exitDuration = min(
                    result[index].exitDuration,
                    max(nextStart - extendedEnd, 0)
                )
            }
        }
        return result
    }

    private static func orderedValidClicks(_ clicks: [PointerClick]) -> [PointerClick] {
        var previousTime: TimeInterval?
        var isAlreadyOrdered = true
        for click in clicks {
            guard click.time.isFinite, click.time >= 0 else {
                isAlreadyOrdered = false
                break
            }
            if let previousTime, click.time < previousTime {
                isAlreadyOrdered = false
                break
            }
            previousTime = click.time
        }
        guard !isAlreadyOrdered else { return clicks }
        return clicks
            .filter { $0.time.isFinite && $0.time >= 0 }
            .sorted { $0.time < $1.time }
    }

    private static func lastIndex(
        atOrBefore time: TimeInterval,
        in clicks: [PointerClick]
    ) -> Int? {
        var lower = clicks.startIndex
        var upper = clicks.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if clicks[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == clicks.startIndex ? nil : lower - 1
    }

    private static func firstIndex(
        after time: TimeInterval,
        in events: [PointerEventRecord]
    ) -> Int {
        var lower = events.startIndex
        var upper = events.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// CAM-001...CAM-005: one short, continuous interaction burst owns one zoom
    /// envelope and one persistent camera controller. The preceding planner
    /// represented every spatial click group inside that burst as another
    /// touching clip. Even though scale stayed continuous, each clip restarted
    /// its local easing and automatic-focus cache from zero velocity, producing
    /// visible stop/start motion during click-heavy recordings.
    ///
    /// Only exact planner-shaped automatic neighbours are folded. A longer
    /// recording still produces multiple editable envelopes: a time gap,
    /// return transition, different visual policy, or any manual clip starts a
    /// separate animation.
    private static func mergingConnectedAutomaticEnvelopes(
        _ animations: [ZoomAnimationClip]
    ) -> [ZoomAnimationClip] {
        let ordered = animations.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.startTime < rhs.startTime
        }
        var result: [ZoomAnimationClip] = []
        let tolerance = 0.000_001

        for animation in ordered {
            guard var previous = result.last,
                  previous.origin == .automatic,
                  animation.origin == .automatic,
                  previous.exitDuration <= ZoomInterpolator.adjacencyTolerance,
                  abs(previous.endTime - animation.startTime)
                    <= ZoomInterpolator.adjacencyTolerance,
                  abs(previous.scale - animation.scale) <= tolerance,
                  previous.easing == animation.easing,
                  previous.customCurve == animation.customCurve else {
                result.append(animation)
                continue
            }

            previous.endTime = max(previous.endTime, animation.endTime)
            previous.exitDuration = animation.exitDuration
            result[result.index(before: result.endIndex)] = previous
        }
        return result
    }

    /// Builds the current editable animation model directly. The legacy
    /// keyframe migration path intentionally remains separate: routing new
    /// recordings through it collapsed multiple click focuses and counted the
    /// return transition twice.
    public static func makeAnimations(
        for clicks: [PointerClick],
        zoomScale: Double = 1.6,
        enterDuration: TimeInterval = 0.7,
        holdDuration: TimeInterval = 0.9,
        exitDuration: TimeInterval = 0.7,
        clickGroupGap: TimeInterval = 1.4,
        safeInset: Double = 0.12,
        easing: ZoomEasingPreset = .spring
    ) -> [ZoomAnimationClip] {
        let ordered = orderedValidClicks(clicks)
        var temporalGroups: [[PointerClick]] = []
        for click in ordered {
            if let previous = temporalGroups.last?.last,
               click.time - previous.time <= clickGroupGap {
                temporalGroups[temporalGroups.count - 1].append(click)
            } else {
                temporalGroups.append([click])
            }
        }

        var animations: [ZoomAnimationClip] = []
        var earliestNextStart: TimeInterval = 0
        for temporalGroup in temporalGroups {
            guard let first = temporalGroup.first,
                  let last = temporalGroup.last else { continue }

            // Nearby clicks form one camera region. Keeping that region stable
            // is more important than centring every individual click: buttons,
            // fields and list items in the same visible area should move only
            // the cursor, not the whole screen. A new region is created only
            // when the accumulated click bounds no longer fit comfortably in
            // the zoomed viewport.
            let visibleExtent = 1 / max(zoomScale, 1)
            let focusGroups = spatialFocusGroups(
                temporalGroup,
                maximumSpanX: visibleExtent * 0.50,
                maximumSpanY: visibleExtent * 0.70
            )
            guard !focusGroups.isEmpty else { continue }
            var starts: [TimeInterval] = []
            starts.reserveCapacity(focusGroups.count)
            starts.append(max(first.time - enterDuration * 0.18, earliestNextStart, 0))
            for focusGroup in focusGroups.dropFirst() {
                let minimumStart = (starts.last ?? 0) + 0.16
                starts.append(max(focusGroup.firstTime - enterDuration, minimumStart))
            }

            for index in focusGroups.indices {
                let start = starts[index]
                let isLast = index == focusGroups.index(before: focusGroups.endIndex)
                let end = isLast
                    ? max(last.time + holdDuration, start + enterDuration)
                    : starts[index + 1]
                guard end - start > 0.01 else { continue }
                animations.append(
                    ZoomAnimationClip(
                        startTime: start,
                        endTime: end,
                        scale: zoomScale,
                        focus: focusGroups[index].focus.constrained(to: safeInset),
                        origin: .automatic,
                        easing: easing,
                        enterDuration: enterDuration,
                        exitDuration: isLast ? exitDuration : 0
                    )
                )
            }
            earliestNextStart = (animations.last?.effectEndTime ?? last.time)
        }
        return animations
    }

    private struct SpatialFocusGroup {
        let firstTime: TimeInterval
        private(set) var minimumX: Double
        private(set) var maximumX: Double
        private(set) var minimumY: Double
        private(set) var maximumY: Double

        init(_ click: PointerClick) {
            firstTime = click.time
            minimumX = click.location.x
            maximumX = click.location.x
            minimumY = click.location.y
            maximumY = click.location.y
        }

        var focus: NormalizedPoint {
            return NormalizedPoint(
                x: (minimumX + maximumX) / 2,
                y: (minimumY + maximumY) / 2
            )
        }

        func canInclude(
            _ click: PointerClick,
            maximumSpanX: Double,
            maximumSpanY: Double
        ) -> Bool {
            max(maximumX, click.location.x) - min(minimumX, click.location.x)
                <= maximumSpanX
                && max(maximumY, click.location.y) - min(minimumY, click.location.y)
                    <= maximumSpanY
        }

        mutating func append(_ click: PointerClick) {
            minimumX = min(minimumX, click.location.x)
            maximumX = max(maximumX, click.location.x)
            minimumY = min(minimumY, click.location.y)
            maximumY = max(maximumY, click.location.y)
        }
    }

    private static func spatialFocusGroups(
        _ clicks: [PointerClick],
        maximumSpanX: Double,
        maximumSpanY: Double
    ) -> [SpatialFocusGroup] {
        var groups: [SpatialFocusGroup] = []
        for click in clicks {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].canInclude(
                   click,
                   maximumSpanX: maximumSpanX,
                   maximumSpanY: maximumSpanY
               ) {
                groups[lastIndex].append(click)
            } else {
                groups.append(SpatialFocusGroup(click))
            }
        }
        return groups
    }

    public static func clipped(
        _ animations: [ZoomAnimationClip],
        to duration: TimeInterval
    ) -> [ZoomAnimationClip] {
        guard duration.isFinite, duration > 0 else { return [] }
        return animations.compactMap { animation in
            guard animation.startTime < duration else { return nil }
            var clipped = animation
            clipped.endTime = min(animation.endTime, duration)
            clipped.exitDuration = min(
                animation.exitDuration,
                max(duration - clipped.endTime, 0)
            )
            return clipped.endTime - clipped.startTime > 0.01 ? clipped : nil
        }
    }

    public static func clipped(
        _ keyframes: [ZoomKeyframe],
        to duration: TimeInterval,
        motion: MotionStyle = MotionStyle()
    ) -> [ZoomKeyframe] {
        guard duration.isFinite, duration > 0 else { return [] }
        let endSample = ZoomInterpolator.sample(
            keyframes: keyframes,
            at: duration,
            motion: motion
        )
        var clipped = keyframes.filter { $0.time >= 0 && $0.time < duration }
        clipped.append(
            ZoomKeyframe(
                time: duration,
                scale: endSample.scale,
                focus: endSample.focus
            )
        )
        return clipped.sorted { $0.time < $1.time }
    }

    public static func makeKeyframes(
        for pointerEvents: [PointerEventRecord],
        baseScale: Double = 1,
        zoomScale: Double = 1.6
    ) -> [ZoomKeyframe] {
        let clicks = pointerEvents.compactMap { event -> PointerClick? in
            guard event.kind == .leftClick || event.kind == .rightClick else { return nil }
            return PointerClick(time: event.time, location: event.location)
        }
        return makeKeyframes(for: clicks, baseScale: baseScale, zoomScale: zoomScale)
    }

    public static func makeKeyframes(
        for clicks: [PointerClick],
        baseScale: Double = 1,
        zoomScale: Double = 1.6,
        enterDuration: TimeInterval = 0.42,
        holdDuration: TimeInterval = 0.9,
        exitDuration: TimeInterval = 0.44,
        clickGroupGap: TimeInterval = 1.4,
        safeInset: Double = 0.12
    ) -> [ZoomKeyframe] {
        let center = NormalizedPoint(x: 0.5, y: 0.5)
        var keyframes = [ZoomKeyframe(time: 0, scale: baseScale, focus: center)]

        let orderedClicks = clicks.sorted(by: { $0.time < $1.time })
        var groups: [[PointerClick]] = []
        for click in orderedClicks {
            if let previous = groups.last?.last,
               click.time - previous.time <= clickGroupGap {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let firstFocus = first.location.constrained(to: safeInset)
            let start = max(first.time - enterDuration * 0.18, 0)
            let zoomed = start + enterDuration
            let release = max(last.time + holdDuration, zoomed + holdDuration)

            keyframes.append(ZoomKeyframe(time: start, scale: baseScale, focus: firstFocus))
            keyframes.append(ZoomKeyframe(time: zoomed, scale: zoomScale, focus: firstFocus))
            for click in group.dropFirst() {
                keyframes.append(
                    ZoomKeyframe(
                        time: max(click.time, zoomed),
                        scale: zoomScale,
                        focus: click.location.constrained(to: safeInset)
                    )
                )
            }
            keyframes.append(
                ZoomKeyframe(
                    time: release,
                    scale: zoomScale,
                    focus: last.location.constrained(to: safeInset)
                )
            )
            keyframes.append(ZoomKeyframe(time: release + exitDuration, scale: baseScale, focus: center))
        }

        return keyframes.sorted { $0.time < $1.time }
    }
}

/// Lock-protected exact-match cache for the sorted zoom track used by the
/// fallback sampling path (callers that do not supply a prebuilt track).
