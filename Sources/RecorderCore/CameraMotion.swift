import Foundation

public enum CameraLayoutMode: Codable, Equatable, Sendable {
    case shape(CameraShape)
    case fullscreen

    private enum Kind: String, Codable {
        case shape
        case fullscreen
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case shape
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .shape:
            self = .shape(try container.decode(CameraShape.self, forKey: .shape))
        case .fullscreen:
            self = .fullscreen
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .shape(shape):
            try container.encode(Kind.shape, forKey: .kind)
            try container.encode(shape, forKey: .shape)
        case .fullscreen:
            try container.encode(Kind.fullscreen, forKey: .kind)
        }
    }
}

public struct CameraMotionState: Codable, Equatable, Sendable {
    public var layout: CameraLayoutMode
    public var position: NormalizedPoint
    public var size: Double
    public var roundness: Double
    public var opacity: Double

    public init(
        layout: CameraLayoutMode = .shape(.square),
        position: NormalizedPoint = NormalizedPoint(x: 0.86, y: 0.82),
        size: Double = 0.35,
        roundness: Double = 0.5,
        opacity: Double = 1
    ) {
        self.layout = layout
        self.position = position
        self.size = size
        self.roundness = roundness
        self.opacity = opacity
    }
}

public struct CameraMotionClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timing: TransitionTiming
    public var target: CameraMotionState
    /// 组合布局预设插入的跨轨道配对 ID；拖动/缩放一侧时另一侧跟随。
    public var groupID: UUID?

    public init(
        id: UUID = UUID(),
        timing: TransitionTiming,
        target: CameraMotionState,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.timing = timing
        self.target = target
        self.groupID = groupID
    }
}

/// Continuous camera values consumed by geometry evaluation. Discrete authored
/// layouts are resolved before interpolation, allowing circle -> rectangle ->
/// fullscreen transitions without switching an enum halfway through a frame.
public struct CameraMotionSample: Equatable, Sendable {
    public var position: NormalizedPoint
    public var size: Double
    public var aspectRatio: Double
    public var cornerFraction: Double
    public var fullscreenProgress: Double
    public var opacity: Double

    public init(
        position: NormalizedPoint,
        size: Double,
        aspectRatio: Double,
        cornerFraction: Double,
        fullscreenProgress: Double,
        opacity: Double
    ) {
        self.position = position
        self.size = size
        self.aspectRatio = aspectRatio
        self.cornerFraction = cornerFraction
        self.fullscreenProgress = fullscreenProgress
        self.opacity = opacity
    }
}

public struct CameraMotionTrack: Equatable, Sendable {
    public let clips: [CameraMotionClip]
    private let usesIndexedEvaluation: Bool

    public init(_ clips: [CameraMotionClip]) {
        if TimelineTrackOrdering.cameraMotionClipsNeedRepair(clips) {
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
        base: CameraMotionState,
        cameraAspectRatio: Double,
        canvasAspectRatio: Double,
        motion: MotionStyle = MotionStyle()
    ) -> CameraMotionSample {
        let resolvedBase = Self.resolve(
            base,
            cameraAspectRatio: cameraAspectRatio,
            canvasAspectRatio: canvasAspectRatio
        )
        guard usesIndexedEvaluation, time.isFinite else {
            return sampleByScanning(
                at: time,
                resolvedBase: resolvedBase,
                cameraAspectRatio: cameraAspectRatio,
                canvasAspectRatio: canvasAspectRatio,
                motion: motion
            )
        }
        guard let index = lastStartedClipIndex(at: time) else {
            return resolvedBase
        }
        let clip = clips[index]
        let target = Self.resolve(
            clip.target,
            cameraAspectRatio: cameraAspectRatio,
            canvasAspectRatio: canvasAspectRatio
        )
        if time < clip.timing.endTime {
            let inherited: CameraMotionSample
            if index > clips.startIndex {
                let previous = clips[index - 1]
                let touches = abs(previous.timing.endTime - clip.timing.startTime)
                    <= ZoomInterpolator.adjacencyTolerance
                inherited = !touches && previous.timing.returnDuration > 0.000_1
                    ? resolvedBase
                    : Self.resolve(
                        previous.target,
                        cameraAspectRatio: cameraAspectRatio,
                        canvasAspectRatio: canvasAspectRatio
                    )
            } else {
                inherited = resolvedBase
            }
            let leadIn = min(clip.timing.leadInDuration, clip.timing.duration)
            guard leadIn > 0.000_1 else { return target }
            let local = min((time - clip.timing.startTime) / leadIn, 1)
            let linear = clip.timing.leadInProgressOffset
                + (1 - clip.timing.leadInProgressOffset) * local
            let progress = ZoomInterpolator.easedProgress(
                linear,
                preset: clip.timing.easing,
                customCurve: clip.timing.customCurve,
                motion: motion
            )
            return Self.transitionSample(from: inherited, to: target, progress: progress)
        }
        if let falling = returnFalloff(
            index: index,
            base: resolvedBase,
            time: time,
            cameraAspectRatio: cameraAspectRatio,
            canvasAspectRatio: canvasAspectRatio,
            motion: motion
        ) {
            return falling
        }
        return clip.timing.returnDuration > 0.000_1 ? resolvedBase : target
    }

    /// Compatibility path for malformed caller-constructed tracks. Persisted
    /// projects are validated and always take the indexed path above.
    private func sampleByScanning(
        at time: TimeInterval,
        resolvedBase: CameraMotionSample,
        cameraAspectRatio: Double,
        canvasAspectRatio: Double,
        motion: MotionStyle
    ) -> CameraMotionSample {
        var inherited = resolvedBase
        var previousIndex: Int?
        for (index, clip) in clips.enumerated() {
            guard clip.timing.startTime.isFinite,
                  clip.timing.duration.isFinite,
                  clip.timing.duration > 0 else { continue }
            if time < clip.timing.startTime {
                if let previousIndex,
                   let falling = returnFalloff(
                       index: previousIndex,
                       base: resolvedBase,
                       time: time,
                       cameraAspectRatio: cameraAspectRatio,
                       canvasAspectRatio: canvasAspectRatio,
                       motion: motion
                   ) {
                    return falling
                }
                return inherited
            }
            let target = Self.resolve(
                clip.target,
                cameraAspectRatio: cameraAspectRatio,
                canvasAspectRatio: canvasAspectRatio
            )
            if time < clip.timing.endTime {
                // 进入过渡按 leadInDuration 插值，之后到 endTime 保持目标
                let leadIn = min(clip.timing.leadInDuration, clip.timing.duration)
                guard leadIn > 0.000_1 else { return target }
                let local = min((time - clip.timing.startTime) / leadIn, 1)
                let linear = clip.timing.leadInProgressOffset
                    + (1 - clip.timing.leadInProgressOffset) * local
                let progress = ZoomInterpolator.easedProgress(
                    linear,
                    preset: clip.timing.easing,
                    customCurve: clip.timing.customCurve,
                    motion: motion
                )
                return Self.transitionSample(from: inherited, to: target, progress: progress)
            }
            let touchesNext = clips.indices.contains(index + 1)
                && abs(clips[index + 1].timing.startTime - clip.timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            inherited = !touchesNext && clip.timing.returnDuration > 0.000_1
                ? resolvedBase
                : target
            previousIndex = index
        }
        if let previousIndex,
           let falling = returnFalloff(
               index: previousIndex,
               base: resolvedBase,
               time: time,
               cameraAspectRatio: cameraAspectRatio,
               canvasAspectRatio: canvasAspectRatio,
               motion: motion
           ) {
            return falling
        }
        guard let previousIndex else { return inherited }
        return clips[previousIndex].timing.returnDuration > 0.000_1 ? resolvedBase : inherited
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
        base: CameraMotionSample,
        time: TimeInterval,
        cameraAspectRatio: Double,
        canvasAspectRatio: Double,
        motion: MotionStyle
    ) -> CameraMotionSample? {
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
        let target = Self.resolve(
            clip.target,
            cameraAspectRatio: cameraAspectRatio,
            canvasAspectRatio: canvasAspectRatio
        )
        return Self.transitionSample(from: target, to: base, progress: progress)
    }

    /// 过渡采样：隐藏目标（opacity≈0）不做位移动画——原地淡出；
    /// 从隐藏进入可见目标——在目标位置/形状处淡入。
    /// 其余情况走完整几何插值。
    private static func transitionSample(
        from inherited: CameraMotionSample,
        to target: CameraMotionSample,
        progress: Double
    ) -> CameraMotionSample {
        let hiddenTarget = target.opacity < 0.01
        let hiddenSource = inherited.opacity < 0.01
        if hiddenTarget {
            var sample = inherited
            sample.opacity = mix(inherited.opacity, 0, min(max(progress, 0), 1))
            return sample
        }
        if hiddenSource {
            var sample = target
            sample.opacity = mix(0, target.opacity, min(max(progress, 0), 1))
            return sample
        }
        return Self.interpolate(from: inherited, to: target, progress: progress)
    }

    private static func resolve(
        _ state: CameraMotionState,
        cameraAspectRatio: Double,
        canvasAspectRatio: Double
    ) -> CameraMotionSample {
        let aspect: Double
        let cornerFraction: Double
        let fullscreen: Double
        switch state.layout {
        case let .shape(shape):
            fullscreen = 0
            switch shape {
            case .square:
                aspect = 1
                cornerFraction = 0.5 * state.roundness
            case .circle:
                aspect = 1
                cornerFraction = 0.5
            case .horizontal:
                aspect = 1.5
                cornerFraction = 0.5 * state.roundness
            case .vertical:
                aspect = 0.72
                cornerFraction = 0.5 * state.roundness
            case .original:
                aspect = max(cameraAspectRatio, 0.01)
                cornerFraction = 0.5 * state.roundness
            }
        case .fullscreen:
            aspect = max(canvasAspectRatio, 0.01)
            cornerFraction = 0
            fullscreen = 1
        }
        return CameraMotionSample(
            position: state.position,
            size: state.size,
            aspectRatio: aspect,
            cornerFraction: cornerFraction,
            fullscreenProgress: fullscreen,
            opacity: state.opacity
        )
    }

    private static func interpolate(
        from: CameraMotionSample,
        to: CameraMotionSample,
        progress: Double
    ) -> CameraMotionSample {
        let t = min(max(progress, 0), 1)
        return CameraMotionSample(
            position: NormalizedPoint(
                x: mix(from.position.x, to.position.x, t),
                y: mix(from.position.y, to.position.y, t)
            ),
            size: mix(from.size, to.size, t),
            aspectRatio: mix(from.aspectRatio, to.aspectRatio, t),
            cornerFraction: mix(from.cornerFraction, to.cornerFraction, t),
            fullscreenProgress: mix(from.fullscreenProgress, to.fullscreenProgress, t),
            opacity: mix(from.opacity, to.opacity, t)
        )
    }

    private static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }
}
