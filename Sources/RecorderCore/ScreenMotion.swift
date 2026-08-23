import Foundation

/// Time-varying presentation of the recorded screen card. Crop, frame chrome,
/// border and shadow remain base appearance; this state owns spatial motion.
public struct ScreenMotionState: Codable, Equatable, Sendable {
    public var position: NormalizedPoint
    public var scale: Double
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double
    public var perspective: Double

    public init(
        position: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        scale: Double = 1,
        rotationX: Double = 0,
        rotationY: Double = 0,
        rotationZ: Double = 0,
        perspective: Double = 0.65
    ) {
        self.position = position
        self.scale = scale
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.perspective = perspective
    }
}

public struct ScreenMotionClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timing: TransitionTiming
    public var target: ScreenMotionState
    /// 组合布局预设插入的跨轨道配对 ID；拖动/缩放一侧时另一侧跟随。
    public var groupID: UUID?

    public init(
        id: UUID = UUID(),
        timing: TransitionTiming,
        target: ScreenMotionState,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.timing = timing
        self.target = target
        self.groupID = groupID
    }
}

/// 锚点空间：rect 线性过渡需要的画布与适配尺寸。
/// 提供后，位置/大小按“内容的几分之几对齐画布的几分之几”在 rect 空间线性
/// 插值（缩放锚点从动画开始就钉在目标区域），而不是分别独立插值
/// （pos×(W−scaledW) 的双线性路径会先居中放大、后漂移）。
public struct ScreenAnchorViewport: Equatable, Sendable {
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var fittedWidth: Double
    public var fittedHeight: Double
    /// Outer border at screen-motion scale 1. The border scales with the card,
    /// so it participates in the same direct pixel-offset interpolation.
    public var borderWidthAtScaleOne: Double

    public init(
        canvasWidth: Double,
        canvasHeight: Double,
        fittedWidth: Double,
        fittedHeight: Double,
        borderWidthAtScaleOne: Double = 0
    ) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fittedWidth = fittedWidth
        self.fittedHeight = fittedHeight
        self.borderWidthAtScaleOne = borderWidthAtScaleOne
    }
}

/// Evaluated screen motion plus a non-singular pixel-space translation.
/// `ScreenMotionState.position` remains the persisted editing representation;
/// render geometry consumes `manualOffset` when an anchor viewport is known.
public struct ScreenMotionSample: Equatable, Sendable {
    public var state: ScreenMotionState
    public var manualOffset: CompositionPoint?

    public init(state: ScreenMotionState, manualOffset: CompositionPoint?) {
        self.state = state
        self.manualOffset = manualOffset
    }
}

/// Immutable, pre-sorted screen motion evaluator. A clip starts from the last
/// completed target and reaches its target exactly at `endTime`. 片段不再与
/// 后一段相接且带回落时长时，先平滑回到基础状态再继续；相接的片段永远直接
/// 串联（关键帧效果），过渡全部走非线性缓动。
public struct ScreenMotionTrack: Equatable, Sendable {
    public let clips: [ScreenMotionClip]
    private let usesIndexedEvaluation: Bool

    public init(_ clips: [ScreenMotionClip]) {
        if TimelineTrackOrdering.screenMotionClipsNeedRepair(clips) {
            self.clips = clips.sorted { lhs, rhs in
                lhs.timing.startTime == rhs.timing.startTime
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.timing.startTime < rhs.timing.startTime
            }
        } else {
            self.clips = clips
        }
        let timingsAreValid = self.clips.allSatisfy {
            $0.timing.startTime.isFinite
                && $0.timing.duration.isFinite
                && $0.timing.duration > 0
        }
        let sequenceIsNonoverlapping = zip(self.clips, self.clips.dropFirst()).allSatisfy {
            previous, next in
            let gap = next.timing.startTime - previous.timing.endTime
            let touches = gap <= ZoomInterpolator.adjacencyTolerance
            let clears = next.timing.startTime >= previous.timing.effectEndTime - 0.000_1
            return next.timing.startTime >= previous.timing.endTime - 0.000_1
                && (touches || clears)
        }
        usesIndexedEvaluation = timingsAreValid && sequenceIsNonoverlapping
    }

    public func sample(
        at time: TimeInterval,
        base: ScreenMotionState,
        motion: MotionStyle = MotionStyle(),
        anchorViewport: ScreenAnchorViewport? = nil
    ) -> ScreenMotionState {
        sampleLayout(
            at: time,
            base: base,
            motion: motion,
            anchorViewport: anchorViewport
        ).state
    }

    /// Render-facing sampling keeps translation in pixels. Converting a moving,
    /// scaled card back into normalized position divides by
    /// `canvas - scaledCard`; that denominator crosses zero when the card grows
    /// through canvas size and caused the project-01 one-frame jump.
    public func sampleLayout(
        at time: TimeInterval,
        base: ScreenMotionState,
        motion: MotionStyle = MotionStyle(),
        anchorViewport: ScreenAnchorViewport? = nil
    ) -> ScreenMotionSample {
        guard usesIndexedEvaluation, time.isFinite else {
            return sampleLayoutByScanning(
                at: time,
                base: base,
                motion: motion,
                anchorViewport: anchorViewport
            )
        }
        guard let index = lastStartedClipIndex(at: time) else {
            return Self.layoutSample(for: base, viewport: anchorViewport)
        }
        let clip = clips[index]
        if time < clip.timing.endTime {
            let inherited: ScreenMotionState
            if index > clips.startIndex {
                let previous = clips[index - 1]
                let touches = abs(previous.timing.endTime - clip.timing.startTime)
                    <= ZoomInterpolator.adjacencyTolerance
                inherited = !touches && previous.timing.returnDuration > 0.000_1
                    ? base
                    : previous.target
            } else {
                inherited = base
            }
            let leadIn = min(clip.timing.leadInDuration, clip.timing.duration)
            guard leadIn > 0.000_1 else {
                return Self.layoutSample(for: clip.target, viewport: anchorViewport)
            }
            let local = min((time - clip.timing.startTime) / leadIn, 1)
            let linear = clip.timing.leadInProgressOffset
                + (1 - clip.timing.leadInProgressOffset) * local
            let progress = ZoomInterpolator.easedProgress(
                linear,
                preset: clip.timing.easing,
                customCurve: clip.timing.customCurve,
                motion: motion
            )
            return Self.interpolateLayout(
                from: inherited,
                to: clip.target,
                progress: progress,
                anchorViewport: anchorViewport
            )
        }
        if let falling = returnFalloff(
            index: index,
            base: base,
            time: time,
            motion: motion,
            anchorViewport: anchorViewport
        ) {
            return falling
        }
        return Self.layoutSample(
            for: clip.timing.returnDuration > 0.000_1 ? base : clip.target,
            viewport: anchorViewport
        )
    }

    /// Compatibility path for malformed caller-constructed tracks. Persisted
    /// projects are validated and always take the indexed path above.
    private func sampleLayoutByScanning(
        at time: TimeInterval,
        base: ScreenMotionState,
        motion: MotionStyle,
        anchorViewport: ScreenAnchorViewport?
    ) -> ScreenMotionSample {
        var inherited = base
        var previousIndex: Int?
        for (index, clip) in clips.enumerated() {
            guard clip.timing.startTime.isFinite,
                  clip.timing.duration.isFinite,
                  clip.timing.duration > 0 else { continue }
            if time < clip.timing.startTime {
                if let previousIndex,
                   let falling = returnFalloff(
                       index: previousIndex,
                       base: base,
                       time: time,
                       motion: motion,
                       anchorViewport: anchorViewport
                   ) {
                    return falling
                }
                return Self.layoutSample(for: inherited, viewport: anchorViewport)
            }
            if time < clip.timing.endTime {
                // 进入过渡按 leadInDuration 插值，之后到 endTime 保持目标
                let leadIn = min(clip.timing.leadInDuration, clip.timing.duration)
                guard leadIn > 0.000_1 else {
                    return Self.layoutSample(for: clip.target, viewport: anchorViewport)
                }
                let local = min((time - clip.timing.startTime) / leadIn, 1)
                let linear = clip.timing.leadInProgressOffset
                    + (1 - clip.timing.leadInProgressOffset) * local
                let progress = ZoomInterpolator.easedProgress(
                    linear,
                    preset: clip.timing.easing,
                    customCurve: clip.timing.customCurve,
                    motion: motion
                )
                return Self.interpolateLayout(
                    from: inherited,
                    to: clip.target,
                    progress: progress,
                    anchorViewport: anchorViewport
                )
            }
            let touchesNext = clips.indices.contains(index + 1)
                && abs(clips[index + 1].timing.startTime - clip.timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            inherited = !touchesNext && clip.timing.returnDuration > 0.000_1
                ? base
                : clip.target
            previousIndex = index
        }
        if let previousIndex,
           let falling = returnFalloff(
               index: previousIndex,
               base: base,
               time: time,
               motion: motion,
               anchorViewport: anchorViewport
           ) {
            return falling
        }
        guard let previousIndex else {
            return Self.layoutSample(for: inherited, viewport: anchorViewport)
        }
        return Self.layoutSample(
            for: clips[previousIndex].timing.returnDuration > 0.000_1 ? base : inherited,
            viewport: anchorViewport
        )
    }

    private func lastStartedClipIndex(at time: TimeInterval) -> Int? {
        var lower = clips.startIndex
        var upper = clips.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if clips[middle].timing.startTime <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > clips.startIndex ? lower - 1 : nil
    }

    /// 结尾回落窗口：从片段自身目标平滑回到基础状态，仅在片段没有相接的
    /// 后继时生效；窗口结束后保持基础状态。
    private func returnFalloff(
        index: Int,
        base: ScreenMotionState,
        time: TimeInterval,
        motion: MotionStyle,
        anchorViewport: ScreenAnchorViewport? = nil
    ) -> ScreenMotionSample? {
        let clip = clips[index]
        guard clip.timing.returnDuration > 0.000_1 else { return nil }
        if clips.indices.contains(index + 1),
           abs(clips[index + 1].timing.startTime - clip.timing.endTime)
               <= ZoomInterpolator.adjacencyTolerance {
            return nil
        }
        guard time <= clip.timing.endTime + clip.timing.returnDuration else { return nil }
        let local = min(max((time - clip.timing.endTime) / clip.timing.returnDuration, 0), 1)
        let linear = clip.timing.returnProgressOffset
            + (1 - clip.timing.returnProgressOffset) * local
        let progress = ZoomInterpolator.easedProgress(
            linear,
            preset: clip.timing.easing,
            customCurve: clip.timing.customCurve,
            motion: motion
        )
        return Self.interpolateLayout(
            from: clip.target,
            to: base,
            progress: progress,
            anchorViewport: anchorViewport
        )
    }

    private static func interpolateLayout(
        from: ScreenMotionState,
        to: ScreenMotionState,
        progress: Double,
        anchorViewport: ScreenAnchorViewport? = nil
    ) -> ScreenMotionSample {
        let t = min(max(progress, 0), 1)
        let position: NormalizedPoint
        if let viewport = anchorViewport {
            // rect 空间线性插值：缩放锚点全程钉在两端 rect 连线上，
            // 不会先居中放大再漂移。
            let scaledW0 = from.scale * viewport.fittedWidth
            let scaledW1 = to.scale * viewport.fittedWidth
            let scaledW = mix(scaledW0, scaledW1, t)
            let ux = mix(
                from.position.x * (viewport.canvasWidth - scaledW0),
                to.position.x * (viewport.canvasWidth - scaledW1),
                t
            )
            let scaledH0 = from.scale * viewport.fittedHeight
            let scaledH1 = to.scale * viewport.fittedHeight
            let scaledH = mix(scaledH0, scaledH1, t)
            let uy = mix(
                from.position.y * (viewport.canvasHeight - scaledH0),
                to.position.y * (viewport.canvasHeight - scaledH1),
                t
            )
            let denomX = viewport.canvasWidth - scaledW
            let denomY = viewport.canvasHeight - scaledH
            // 中间态 pos 允许超出 0...1（rect 线性路径在放大过渡中需要）；
            // 只有持久化的目标值要求 0...1，采样插值不受此限。
            position = NormalizedPoint(
                x: abs(denomX) > 0.001
                    ? ux / denomX
                    : mix(from.position.x, to.position.x, t),
                y: abs(denomY) > 0.001
                    ? uy / denomY
                    : mix(from.position.y, to.position.y, t)
            )
        } else {
            position = NormalizedPoint(
                x: mix(from.position.x, to.position.x, t),
                y: mix(from.position.y, to.position.y, t)
            )
        }
        let state = ScreenMotionState(
            position: position,
            scale: mix(from.scale, to.scale, t),
            rotationX: mixAngle(from.rotationX, to.rotationX, t),
            rotationY: mixAngle(from.rotationY, to.rotationY, t),
            rotationZ: mixAngle(from.rotationZ, to.rotationZ, t),
            perspective: mix(from.perspective, to.perspective, t)
        )
        let manualOffset: CompositionPoint? = anchorViewport.map { viewport in
            let fromOffset = directOffset(for: from, viewport: viewport)
            let toOffset = directOffset(for: to, viewport: viewport)
            return CompositionPoint(
                x: mix(fromOffset.x, toOffset.x, t),
                y: mix(fromOffset.y, toOffset.y, t)
            )
        }
        return ScreenMotionSample(state: state, manualOffset: manualOffset)
    }

    private static func layoutSample(
        for state: ScreenMotionState,
        viewport: ScreenAnchorViewport?
    ) -> ScreenMotionSample {
        ScreenMotionSample(
            state: state,
            manualOffset: viewport.map { directOffset(for: state, viewport: $0) }
        )
    }

    private static func directOffset(
        for state: ScreenMotionState,
        viewport: ScreenAnchorViewport
    ) -> CompositionPoint {
        let border = viewport.borderWidthAtScaleOne * state.scale
        let decoratedWidth = viewport.fittedWidth * state.scale + border * 2
        let decoratedHeight = viewport.fittedHeight * state.scale + border * 2
        return CompositionPoint(
            x: (state.position.x - 0.5) * (viewport.canvasWidth - decoratedWidth),
            y: (state.position.y - 0.5) * (viewport.canvasHeight - decoratedHeight)
        )
    }

    private static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    private static func mixAngle(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return from + delta * progress
    }
}
