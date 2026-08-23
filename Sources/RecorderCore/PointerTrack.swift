import Foundation

public struct PointerClickPhase: Equatable, Sendable {
    public var progress: Double
    public var elapsed: Double
    public var duration: Double
    public var kind: PointerEventKind

    public init(
        progress: Double,
        elapsed: Double,
        duration: Double,
        kind: PointerEventKind
    ) {
        self.progress = min(max(progress, 0), 1)
        self.elapsed = elapsed
        self.duration = duration
        self.kind = kind
    }
}

public struct PointerSample: Equatable, Sendable {
    public var location: NormalizedPoint
    public var isClicking: Bool
    public var clickPhase: PointerClickPhase?

    public init(
        location: NormalizedPoint,
        isClicking: Bool,
        clickPhase: PointerClickPhase? = nil
    ) {
        self.location = location
        self.isClicking = isClicking
        self.clickPhase = clickPhase
    }
}

public struct PointerTrackEvaluation: Equatable, Sendable {
    public var position: NormalizedPoint?
    public var cursor: PointerSample?

    public init(position: NormalizedPoint?, cursor: PointerSample?) {
        self.position = position
        self.cursor = cursor
    }
}

private struct PointerSpringCacheKey: Hashable {
    let mass: Double
    let stiffness: Double
    let damping: Double
}

private struct PointerSpringSample: Sendable {
    let time: TimeInterval
    let location: NormalizedPoint
}

public struct PointerTrack: Equatable, Sendable {
    /// A longer gap means the pointer was idle and the next event starts a new
    /// movement. Interpolating across that silence makes the synthetic cursor
    /// (and any camera driven from it) move before the user actually moved.
    private static let maximumContinuousInputGap: TimeInterval = 0.12
    /// macOS reports pointer changes instead of sampling at a fixed cadence.
    /// A genuinely slow physical move can therefore contain sparse events.
    /// Permit a longer interval only for a small travelled distance; a large
    /// move after real silence must remain causal and must not start early.
    private static let maximumSlowMoveGap: TimeInterval = 0.50
    private static let maximumSlowMoveDistance: Double = 0.03
    /// Post-production has the complete pointer track, so it can distribute a
    /// click correction over a short neighbourhood instead of snapping the
    /// cursor on the click frame. The compact, C2-continuous envelope reaches
    /// every recorded click exactly while retaining the spring's velocity.
    private static let clickAnchorLeadDuration: TimeInterval = 0.18
    private static let clickAnchorTrailDuration: TimeInterval = 0.18
    private static let clickEffectDuration: TimeInterval = 0.18

    public let events: [PointerEventRecord]
    /// A 40-minute 240 Hz spring path contains roughly 576,000 samples. Keep
    /// the current and previous inspector variants, not every transient value
    /// produced while mass/stiffness/damping sliders move.
    private let springCache: BoundedMemoizationCache<
        PointerSpringCacheKey,
        [PointerSpringSample]
    >

    public init(_ events: [PointerEventRecord]) {
        self.events = PointerEventTimelineOrdering.normalized(events)
        springCache = BoundedMemoizationCache(capacity: 2)
    }

    public static func == (lhs: PointerTrack, rhs: PointerTrack) -> Bool {
        lhs.events == rhs.events
    }

    /// Builds the current cursor spring away from the playback/display-link
    /// call site. Cancellation is checked throughout long recordings, and an
    /// interrupted path is not inserted into the shared cache.
    public func prewarmCursorSpring(motion: MotionStyle) {
        guard motion.cursor == .smooth, !events.isEmpty else { return }
        let key = springCacheKey(for: motion)
        _ = springCache.valueIfBuilt(for: key) {
            makeSpringSamples(
                motion: motion,
                cancellationCheck: { Task<Never, Never>.isCancelled }
            )
        }
    }

    var cachedSpringVariantCount: Int { springCache.count }

    public func sample(
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle(),
        style: CursorStyle = CursorStyle()
    ) -> PointerSample? {
        evaluation(at: time, motion: motion, style: style).cursor
    }

    public func samplePosition(
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle()
    ) -> NormalizedPoint? {
        evaluation(at: time, motion: motion, style: CursorStyle()).position
    }

    /// Computes the physical pointer position independently from whether the
    /// cursor is visible. Hiding an exported cursor must never disable an
    /// automatic camera move that follows the same pointer track.
    public func evaluation(
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle(),
        style: CursorStyle = CursorStyle()
    ) -> PointerTrackEvaluation {
        guard let first = events.first else {
            return PointerTrackEvaluation(position: nil, cursor: nil)
        }
        // Never reveal a future sample before the pointer track begins. New
        // recordings include a t=0 seed, while imported/legacy tracks may not.
        guard time >= first.time else {
            return PointerTrackEvaluation(position: nil, cursor: nil)
        }

        let upperIndex = firstIndex(after: time)
        let lowerIndex = upperIndex > events.startIndex ? upperIndex - 1 : events.startIndex
        let lower = events[lowerIndex]
        let upper = upperIndex < events.endIndex ? events[upperIndex] : nil
        let rawLocation: NormalizedPoint
        if motion.cursor == .smooth {
            rawLocation = springLocation(at: time, motion: motion) ?? lower.location
        } else if let upper, upper.time > lower.time {
            rawLocation = interpolatedLocation(
                lowerIndex: lowerIndex,
                upperIndex: upperIndex,
                time: time,
                motion: motion
            )
        } else {
            rawLocation = lower.location
        }
        let cursorIsVisible = style.assetID != .hidden
            && (!style.hideWhenIdle || time - lower.time <= style.idleDelay)
        let clickPhase: PointerClickPhase?
        if cursorIsVisible, style.clickEffectStyle != .none, style.clickEffectStyle.duration > 0 {
            if let click = mostRecentClick(
                from: time - style.clickEffectStyle.duration,
                through: time
            ) {
                let elapsed = max(time - click.time, 0)
                let progress = min(max(elapsed / style.clickEffectStyle.duration, 0), 1)
                clickPhase = PointerClickPhase(
                    progress: progress,
                    elapsed: elapsed,
                    duration: style.clickEffectStyle.duration,
                    kind: click.kind
                )
            } else {
                clickPhase = nil
            }
        } else {
            clickPhase = nil
        }
        let clicking = clickPhase != nil
        return PointerTrackEvaluation(
            position: rawLocation,
            cursor: cursorIsVisible
                ? PointerSample(location: rawLocation, isClicking: clicking, clickPhase: clickPhase)
                : nil
        )
    }

    /// A real second-order spring for the reconstructed cursor. Unlike easing
    /// each 8-16 ms input interval independently, this keeps velocity and lag
    /// continuous across event boundaries and suppresses sub-pixel device
    /// jitter without quantising the 60 Hz rendered cursor.
    private func springLocation(
        at time: TimeInterval,
        motion: MotionStyle
    ) -> NormalizedPoint? {
        let key = springCacheKey(for: motion)
        let samples = springCache.value(for: key) {
            makeSpringSamples(
                motion: motion,
                cancellationCheck: { false }
            ) ?? []
        }
        guard let first = samples.first else { return nil }
        guard time > first.time else { return first.location }
        guard let last = samples.last, time < last.time else {
            return samples.last?.location
        }

        var lower = samples.startIndex
        var upper = samples.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let upperIndex = min(lower, samples.index(before: samples.endIndex))
        let lowerIndex = max(upperIndex - 1, samples.startIndex)
        let a = samples[lowerIndex]
        let b = samples[upperIndex]
        let duration = max(b.time - a.time, .leastNonzeroMagnitude)
        let progress = min(max((time - a.time) / duration, 0), 1)
        return NormalizedPoint(
            x: a.location.x + (b.location.x - a.location.x) * progress,
            y: a.location.y + (b.location.y - a.location.y) * progress
        )
    }

    private func springCacheKey(for motion: MotionStyle) -> PointerSpringCacheKey {
        PointerSpringCacheKey(
            mass: motion.cursorSpringMass,
            stiffness: motion.cursorSpringStiffness,
            damping: motion.cursorSpringDamping
        )
    }

    private func makeSpringSamples(
        motion: MotionStyle,
        cancellationCheck: () -> Bool
    ) -> [PointerSpringSample]? {
        guard let first = events.first, let last = events.last else { return [] }
        let interval = 1.0 / 240.0
        let mass = max(motion.cursorSpringMass, 0.01)
        let stiffness = max(motion.cursorSpringStiffness, 0.01)
        let damping = max(motion.cursorSpringDamping, 0.01)
        let settleDuration = max(0.65, 6 * sqrt(mass / stiffness))
        let endTime = max(last.time, first.time) + settleDuration
        let jitterThreshold = 0.000_35
        let jitterThresholdSquared = jitterThreshold * jitterThreshold

        var position = first.location
        var velocityX = 0.0
        var velocityY = 0.0
        var stableTarget = first.location
        var eventIndex = events.index(after: events.startIndex)
        var sampleTime = first.time
        var result = [PointerSpringSample(time: sampleTime, location: position)]
        result.reserveCapacity(max(Int((endTime - first.time) / interval) + 2, 1))
        var iteration = 0

        while sampleTime < endTime {
            if iteration & 1_023 == 0, cancellationCheck() { return nil }
            let nextTime = min(sampleTime + interval, endTime)
            while eventIndex < events.endIndex,
                  events[eventIndex].time <= nextTime {
                eventIndex += 1
            }
            let lowerIndex = max(eventIndex - 1, events.startIndex)
            let target: NormalizedPoint
            if eventIndex < events.endIndex {
                let lowerEvent = events[lowerIndex]
                let upperEvent = events[eventIndex]
                let duration = max(upperEvent.time - lowerEvent.time, .leastNonzeroMagnitude)
                if Self.isContinuousMovement(from: lowerEvent, to: upperEvent) {
                    let progress = min(max((nextTime - lowerEvent.time) / duration, 0), 1)
                    target = NormalizedPoint(
                        x: lowerEvent.location.x
                            + (upperEvent.location.x - lowerEvent.location.x) * progress,
                        y: lowerEvent.location.y
                            + (upperEvent.location.y - lowerEvent.location.y) * progress
                    )
                } else {
                    target = lowerEvent.location
                }
            } else {
                target = last.location
            }
            let targetDeltaX = target.x - stableTarget.x
            let targetDeltaY = target.y - stableTarget.y
            if targetDeltaX * targetDeltaX + targetDeltaY * targetDeltaY
                >= jitterThresholdSquared {
                stableTarget = target
            }

            let deltaTime = max(nextTime - sampleTime, 0)
            let accelerationX = (
                stiffness * (stableTarget.x - position.x) - damping * velocityX
            ) / mass
            let accelerationY = (
                stiffness * (stableTarget.y - position.y) - damping * velocityY
            ) / mass
            velocityX += accelerationX * deltaTime
            velocityY += accelerationY * deltaTime
            position = NormalizedPoint(
                x: min(max(position.x + velocityX * deltaTime, 0), 1),
                y: min(max(position.y + velocityY * deltaTime, 0), 1)
            )
            sampleTime = nextTime
            result.append(PointerSpringSample(time: sampleTime, location: position))
            iteration &+= 1
        }
        return anchoringClicks(
            in: result,
            cancellationCheck: cancellationCheck
        )
    }

    /// Applies a compact correction around each click to the already-smoothed
    /// spring path. Supports stop at the midpoint between neighbouring clicks,
    /// so one anchor cannot pull another away from its recorded point. A
    /// quintic smoother-step has zero first and second derivatives at both
    /// ends; unlike assigning the click sample directly, it creates no
    /// one-frame position or velocity discontinuity.
    private func anchoringClicks(
        in baseSamples: [PointerSpringSample],
        cancellationCheck: () -> Bool
    ) -> [PointerSpringSample]? {
        let clicks = events.filter {
            $0.kind == .leftClick || $0.kind == .rightClick
        }
        guard !baseSamples.isEmpty, !clicks.isEmpty else { return baseSamples }

        // Merge semantic click timestamps into the 240 Hz grid in one pass.
        // Repeated Array insertion would make long recordings O(clicks ×
        // samples) before preview could even display its first frame.
        guard var samples = insertingClickSamples(
            in: baseSamples,
            clicks: clicks,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        for (clickIndex, click) in clicks.enumerated() {
            if cancellationCheck() { return nil }
            guard let anchorIndex = exactSampleIndex(at: click.time, in: samples) else {
                continue
            }
            let previousClickTime = clickIndex > clicks.startIndex
                ? clicks[clickIndex - 1].time
                : nil
            let nextClickTime = clicks.indices.contains(clickIndex + 1)
                ? clicks[clickIndex + 1].time
                : nil
            let supportStart = max(
                samples[0].time,
                max(
                    click.time - Self.clickAnchorLeadDuration,
                    previousClickTime.map { ($0 + click.time) * 0.5 } ?? -.infinity
                )
            )
            let supportEnd = min(
                samples[samples.index(before: samples.endIndex)].time,
                min(
                    click.time + Self.clickAnchorTrailDuration,
                    nextClickTime.map { (click.time + $0) * 0.5 } ?? .infinity
                )
            )
            let current = samples[anchorIndex].location
            let correctionX = click.location.x - current.x
            let correctionY = click.location.y - current.y

            let supportStartIndex = firstSampleIndex(
                atOrAfter: supportStart,
                in: samples
            )
            let supportEndIndex = firstSampleIndex(
                after: supportEnd,
                in: samples
            )
            for index in supportStartIndex..<supportEndIndex {
                let sampleTime = samples[index].time
                let weight: Double
                if sampleTime <= click.time {
                    let duration = click.time - supportStart
                    let progress = duration > 0
                        ? (sampleTime - supportStart) / duration
                        : 1
                    weight = Self.smootherStep(progress)
                } else {
                    let duration = supportEnd - click.time
                    let progress = duration > 0
                        ? (sampleTime - click.time) / duration
                        : 1
                    weight = 1 - Self.smootherStep(progress)
                }
                samples[index] = PointerSpringSample(
                    time: sampleTime,
                    location: NormalizedPoint(
                        x: min(max(samples[index].location.x + correctionX * weight, 0), 1),
                        y: min(max(samples[index].location.y + correctionY * weight, 0), 1)
                    )
                )
            }
            // Avoid accumulating floating-point interpolation error at the
            // semantic anchor itself.
            samples[anchorIndex] = PointerSpringSample(
                time: click.time,
                location: click.location
            )
        }
        return samples
    }

    private func insertingClickSamples(
        in baseSamples: [PointerSpringSample],
        clicks: [PointerEventRecord],
        cancellationCheck: () -> Bool
    ) -> [PointerSpringSample]? {
        guard baseSamples.count > 1 else { return baseSamples }
        var result: [PointerSpringSample] = []
        result.reserveCapacity(baseSamples.count + clicks.count)
        var baseIndex = baseSamples.startIndex

        for (clickIndex, click) in clicks.enumerated() {
            if clickIndex & 255 == 0, cancellationCheck() { return nil }
            guard click.time >= baseSamples[0].time,
                  click.time <= baseSamples[baseSamples.index(before: baseSamples.endIndex)].time
            else { continue }
            while baseIndex < baseSamples.endIndex,
                  baseSamples[baseIndex].time < click.time - 0.000_000_1 {
                result.append(baseSamples[baseIndex])
                baseIndex += 1
            }
            if baseIndex < baseSamples.endIndex,
               abs(baseSamples[baseIndex].time - click.time) <= 0.000_000_1 {
                if result.last?.time != baseSamples[baseIndex].time {
                    result.append(baseSamples[baseIndex])
                }
                baseIndex += 1
                continue
            }
            guard let before = result.last,
                  baseIndex < baseSamples.endIndex else { continue }
            if abs(before.time - click.time) <= 0.000_000_1 {
                continue
            }
            let after = baseSamples[baseIndex]
            let duration = max(after.time - before.time, .leastNonzeroMagnitude)
            let progress = min(max((click.time - before.time) / duration, 0), 1)
            result.append(PointerSpringSample(
                time: click.time,
                location: NormalizedPoint(
                    x: before.location.x
                        + (after.location.x - before.location.x) * progress,
                    y: before.location.y
                        + (after.location.y - before.location.y) * progress
                )
            ))
        }
        result.append(contentsOf: baseSamples[baseIndex...])
        return result
    }

    private func exactSampleIndex(
        at time: TimeInterval,
        in samples: [PointerSpringSample]
    ) -> Int? {
        var lower = samples.startIndex
        var upper = samples.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].time < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < samples.endIndex,
              abs(samples[lower].time - time) <= 0.000_000_1 else { return nil }
        return lower
    }

    private func firstSampleIndex(
        atOrAfter time: TimeInterval,
        in samples: [PointerSpringSample]
    ) -> Int {
        var lower = samples.startIndex
        var upper = samples.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].time < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func firstSampleIndex(
        after time: TimeInterval,
        in samples: [PointerSpringSample]
    ) -> Int {
        var lower = samples.startIndex
        var upper = samples.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func smootherStep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Time-aware cubic Hermite interpolation. The old implementation reset a
    /// spring easing curve inside every 8-16 ms event interval, forcing cursor
    /// velocity back to zero at every sample, then added an event-count-based
    /// low pass whose lag increased with mouse polling rate. Here each knot has
    /// one shared velocity, so adjacent intervals are C1-continuous and every
    /// recorded position is reached at its real timestamp without density lag.
    private func interpolatedLocation(
        lowerIndex: Int,
        upperIndex: Int,
        time: TimeInterval,
        motion: MotionStyle
    ) -> NormalizedPoint {
        let lower = events[lowerIndex]
        let upper = events[upperIndex]
        let duration = upper.time - lower.time
        guard duration > 0 else { return lower.location }
        guard Self.isContinuousMovement(from: lower, to: upper) else {
            return lower.location
        }
        let progress = min(max((time - lower.time) / duration, 0), 1)
        if motion.cursor == .none {
            return NormalizedPoint(
                x: lower.location.x + (upper.location.x - lower.location.x) * progress,
                y: lower.location.y + (upper.location.y - lower.location.y) * progress
            )
        }
        let tangentScale: Double
        switch motion.cursor {
        case .smooth:
            let mass = max(motion.cursorSpringMass, 0.01)
            let stiffness = max(motion.cursorSpringStiffness, 0.01)
            let damping = max(motion.cursorSpringDamping, 0.01)
            let naturalFrequency = sqrt(stiffness / mass)
            let decayRate = damping / (2 * mass)
            let responsiveness = naturalFrequency / (naturalFrequency + decayRate)
            tangentScale = min(max(0.25 + 1.1 * responsiveness, 0.25), 1.2)
        case .medium:
            tangentScale = 0.78
        case .rapid:
            tangentScale = 1
        case .none:
            tangentScale = 1
        }
        let lowerTangent = tangent(at: lowerIndex)
        let upperTangent = tangent(at: upperIndex)
        let t2 = progress * progress
        let t3 = t2 * progress
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + progress
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return NormalizedPoint(
            x: min(max(
                h00 * lower.location.x
                    + h10 * duration * lowerTangent.x * tangentScale
                    + h01 * upper.location.x
                    + h11 * duration * upperTangent.x * tangentScale,
                0
            ), 1),
            y: min(max(
                h00 * lower.location.y
                    + h10 * duration * lowerTangent.y * tangentScale
                    + h01 * upper.location.y
                    + h11 * duration * upperTangent.y * tangentScale,
                0
            ), 1)
        )
    }

    private func tangent(at index: Int) -> NormalizedPoint {
        let current = events[index]
        var previous = index - 1
        while previous >= events.startIndex,
              events[previous].time >= current.time {
            previous -= 1
        }
        var next = index + 1
        while next < events.endIndex,
              events[next].time <= current.time {
            next += 1
        }
        if previous >= events.startIndex, next < events.endIndex {
            return monotoneTangent(
                previous: events[previous],
                current: current,
                next: events[next]
            )
        }
        if next < events.endIndex {
            let duration = events[next].time - current.time
            guard duration > 0 else { return NormalizedPoint(x: 0, y: 0) }
            return NormalizedPoint(
                x: (events[next].location.x - current.location.x) / duration,
                y: (events[next].location.y - current.location.y) / duration
            )
        }
        if previous >= events.startIndex {
            let duration = current.time - events[previous].time
            guard duration > 0 else { return NormalizedPoint(x: 0, y: 0) }
            return NormalizedPoint(
                x: (current.location.x - events[previous].location.x) / duration,
                y: (current.location.y - events[previous].location.y) / duration
            )
        }
        return NormalizedPoint(x: 0, y: 0)
    }

    private static func isContinuousMovement(
        from lower: PointerEventRecord,
        to upper: PointerEventRecord
    ) -> Bool {
        let duration = upper.time - lower.time
        guard duration > 0 else { return false }
        if duration <= maximumContinuousInputGap { return true }
        guard duration <= maximumSlowMoveGap else { return false }
        let deltaX = upper.location.x - lower.location.x
        let deltaY = upper.location.y - lower.location.y
        return deltaX * deltaX + deltaY * deltaY
            <= maximumSlowMoveDistance * maximumSlowMoveDistance
    }

    /// Non-uniform monotone cubic tangent (PCHIP/Fritsch-Carlson). A plain
    /// centred secant is C1-continuous but can overshoot a short interval when
    /// neighbouring pointer events have very different time gaps. That creates
    /// a visible one-frame reversal even though every recorded knot is valid.
    /// Computing each axis monotonically keeps stops and direction changes from
    /// ringing while preserving shared velocity at adjacent intervals.
    private func monotoneTangent(
        previous: PointerEventRecord,
        current: PointerEventRecord,
        next: PointerEventRecord
    ) -> NormalizedPoint {
        let previousDuration = current.time - previous.time
        let nextDuration = next.time - current.time
        guard previousDuration > 0, nextDuration > 0 else {
            return NormalizedPoint(x: 0, y: 0)
        }

        func axis(_ previousValue: Double, _ value: Double, _ nextValue: Double) -> Double {
            let previousSlope = (value - previousValue) / previousDuration
            let nextSlope = (nextValue - value) / nextDuration
            guard previousSlope.isFinite,
                  nextSlope.isFinite,
                  previousSlope * nextSlope > 0 else { return 0 }
            let firstWeight = 2 * nextDuration + previousDuration
            let secondWeight = nextDuration + 2 * previousDuration
            let denominator = firstWeight / previousSlope + secondWeight / nextSlope
            guard denominator.isFinite, abs(denominator) > .leastNonzeroMagnitude else {
                return 0
            }
            return (firstWeight + secondWeight) / denominator
        }

        return NormalizedPoint(
            x: axis(previous.location.x, current.location.x, next.location.x),
            y: axis(previous.location.y, current.location.y, next.location.y)
        )
    }

    private func firstIndex(after time: TimeInterval) -> Int {
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

    private func firstIndex(atOrAfter time: TimeInterval) -> Int {
        var lower = events.startIndex
        var upper = events.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].time < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// Returns only events inside one output-time window using two binary
    /// searches. The slice keeps automatic-camera planning from copying and
    /// filtering an entire long recording for every short zoom clip.
    func events(
        from start: TimeInterval,
        through end: TimeInterval
    ) -> ArraySlice<PointerEventRecord> {
        guard start.isFinite, end.isFinite, end >= start else {
            return events[events.startIndex..<events.startIndex]
        }
        let lower = firstIndex(atOrAfter: start)
        let upper = firstIndex(after: end)
        return events[lower..<upper]
    }

    private func containsClick(from start: TimeInterval, through end: TimeInterval) -> Bool {
        mostRecentClick(from: start, through: end) != nil
    }

    private func mostRecentClick(
        from start: TimeInterval,
        through end: TimeInterval
    ) -> PointerEventRecord? {
        var index = firstIndex(atOrAfter: start)
        var latest: PointerEventRecord?
        while index < events.endIndex, events[index].time <= end {
            if events[index].kind == .leftClick || events[index].kind == .rightClick {
                latest = events[index]
            }
            index += 1
        }
        return latest
    }
}

public enum PointerInterpolator {
    public static func sample(
        events: [PointerEventRecord],
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle(),
        style: CursorStyle = CursorStyle()
    ) -> PointerSample? {
        PointerTrack(events).sample(at: time, motion: motion, style: style)
    }
}
