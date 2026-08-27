import Foundation

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func constrained(to safeInset: Double) -> NormalizedPoint {
        let inset = min(max(safeInset, 0), 0.5)
        return NormalizedPoint(
            x: min(max(x, inset), 1 - inset),
            y: min(max(y, inset), 1 - inset)
        )
    }
}

public struct PointerClick: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var location: NormalizedPoint

    public init(time: TimeInterval, location: NormalizedPoint) {
        self.time = time
        self.location = location
    }
}

public enum PointerEventKind: String, Codable, Sendable {
    case move
    case leftClick
    case rightClick
}

public enum PointerModifier: String, Codable, CaseIterable, Sendable {
    case command
    case option
    case control
    case shift
    case capsLock
    case function
}

public struct PointerEventRecord: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var location: NormalizedPoint
    public var kind: PointerEventKind
    public var modifiers: [PointerModifier]

    public init(
        time: TimeInterval,
        location: NormalizedPoint,
        kind: PointerEventKind,
        modifiers: [PointerModifier] = []
    ) {
        self.time = time
        self.location = location
        self.kind = kind
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey {
        case time, location, kind, modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(TimeInterval.self, forKey: .time)
        location = try container.decode(NormalizedPoint.self, forKey: .location)
        kind = try container.decode(PointerEventKind.self, forKey: .kind)
        modifiers = try container.decodeIfPresent([PointerModifier].self, forKey: .modifiers) ?? []
    }
}

public enum ZoomKeyframeOrigin: String, Codable, Equatable, Sendable {
    case automatic
    case manual
}

public enum ZoomEasingPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case linear = "线性"
    case quadratic = "二次方缓动"
    case cubic = "三次方缓动"
    case quintic = "五次平滑"
    case spring = "弹簧"
    case custom = "自定义曲线"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .linear: return "线性"
        case .quadratic: return "二次"
        case .cubic: return "三次"
        case .quintic: return "五次"
        case .spring: return "弹簧"
        case .custom: return "自定义"
        }
    }

    public var curve: ZoomBezierCurve {
        switch self {
        case .linear:
            return .linear
        case .quadratic:
            return .quadratic
        case .cubic:
            return .cubic
        case .quintic:
            return .quintic
        case .spring, .custom:
            return .cubic
        }
    }
}

public struct ZoomBezierCurve: Codable, Equatable, Sendable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = min(max(x1, 0), 1)
        self.y1 = min(max(y1, 0), 1)
        self.x2 = min(max(x2, 0), 1)
        self.y2 = min(max(y2, 0), 1)
    }

    public static let linear = ZoomBezierCurve(x1: 0, y1: 0, x2: 1, y2: 1)
    public static let quadratic = ZoomBezierCurve(x1: 0.45, y1: 0, x2: 0.55, y2: 1)
    public static let cubic = ZoomBezierCurve(x1: 0.65, y1: 0, x2: 0.35, y2: 1)
    public static let quintic = ZoomBezierCurve(x1: 0.82, y1: 0, x2: 0.18, y2: 1)

    public func point(at parameter: Double) -> NormalizedPoint {
        let t = min(max(parameter, 0), 1)
        let inverse = 1 - t
        let x = 3 * inverse * inverse * t * x1
            + 3 * inverse * t * t * x2
            + t * t * t
        let y = 3 * inverse * inverse * t * y1
            + 3 * inverse * t * t * y2
            + t * t * t
        return NormalizedPoint(x: x, y: y)
    }

    /// Returns the curve's Y value for a normalized time (X). Newton-Raphson
    /// handles the common case; bisection guarantees a stable answer for very
    /// flat user-authored handles.
    public func value(at normalizedTime: Double) -> Double {
        let targetX = min(max(normalizedTime, 0), 1)
        guard targetX > 0, targetX < 1 else { return targetX }
        var parameter = targetX

        for _ in 0..<7 {
            let point = point(at: parameter)
            let error = point.x - targetX
            if abs(error) < 0.000_01 { return point.y }
            let derivative = xDerivative(at: parameter)
            if abs(derivative) < 0.000_01 { break }
            let next = parameter - error / derivative
            if next < 0 || next > 1 { break }
            parameter = next
        }

        var lower = 0.0
        var upper = 1.0
        parameter = targetX
        for _ in 0..<18 {
            let point = point(at: parameter)
            if abs(point.x - targetX) < 0.000_01 { return point.y }
            if point.x < targetX {
                lower = parameter
            } else {
                upper = parameter
            }
            parameter = (lower + upper) / 2
        }
        return point(at: parameter).y
    }

    private func xDerivative(at parameter: Double) -> Double {
        let t = min(max(parameter, 0), 1)
        let inverse = 1 - t
        return 3 * inverse * inverse * x1
            + 6 * inverse * t * (x2 - x1)
            + 3 * t * t * (1 - x2)
    }
}

public struct ZoomAnimationClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var scale: Double
    public var focus: NormalizedPoint
    public var origin: ZoomKeyframeOrigin
    public var easing: ZoomEasingPreset
    public var customCurve: ZoomBezierCurve
    public var enterDuration: TimeInterval
    public var exitDuration: TimeInterval
    /// Ripple-cut continuation phase. Zero is an ordinary authored clip.
    public var enterProgressOffset: Double
    public var exitProgressOffset: Double

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        scale: Double = 1.6,
        focus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        origin: ZoomKeyframeOrigin = .manual,
        easing: ZoomEasingPreset = .cubic,
        customCurve: ZoomBezierCurve = .cubic,
        enterDuration: TimeInterval = 0.7,
        exitDuration: TimeInterval = 0.7,
        enterProgressOffset: Double = 0,
        exitProgressOffset: Double = 0
    ) {
        self.id = id
        self.startTime = max(startTime, 0)
        self.endTime = max(endTime, self.startTime)
        self.scale = max(scale, 1)
        self.focus = focus.constrained(to: ZoomViewportTransform.focusEdgeInset)
        self.origin = origin
        self.easing = easing
        self.customCurve = customCurve
        self.enterDuration = min(max(enterDuration, 0), 5)
        self.exitDuration = min(max(exitDuration, 0), 5)
        self.enterProgressOffset = min(max(enterProgressOffset, 0), 1)
        self.exitProgressOffset = min(max(exitProgressOffset, 0), 1)
    }

    public var duration: TimeInterval {
        max(endTime - startTime, 0)
    }

    public var effectEndTime: TimeInterval {
        endTime + exitDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, scale, focus, origin, easing
        case customCurve, enterDuration, exitDuration
        case enterProgressOffset, exitProgressOffset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            startTime: try container.decode(TimeInterval.self, forKey: .startTime),
            endTime: try container.decode(TimeInterval.self, forKey: .endTime),
            scale: try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.6,
            focus: try container.decodeIfPresent(NormalizedPoint.self, forKey: .focus)
                ?? NormalizedPoint(x: 0.5, y: 0.5),
            origin: try container.decodeIfPresent(ZoomKeyframeOrigin.self, forKey: .origin) ?? .manual,
            easing: try container.decodeIfPresent(ZoomEasingPreset.self, forKey: .easing) ?? .cubic,
            customCurve: try container.decodeIfPresent(ZoomBezierCurve.self, forKey: .customCurve) ?? .cubic,
            enterDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .enterDuration) ?? 0.55,
            exitDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .exitDuration) ?? 0.55,
            enterProgressOffset: try container.decodeIfPresent(Double.self, forKey: .enterProgressOffset) ?? 0,
            exitProgressOffset: try container.decodeIfPresent(Double.self, forKey: .exitProgressOffset) ?? 0
        )
    }

    public static func migrating(
        keyframes: [ZoomKeyframe],
        defaultEasing: ZoomEasingPreset = .cubic,
        baseScale: Double = 1
    ) -> [ZoomAnimationClip] {
        let ordered = keyframes
            .filter { $0.time.isFinite && $0.time >= 0 }
            .sorted { lhs, rhs in
                lhs.time == rhs.time ? lhs.id.uuidString < rhs.id.uuidString : lhs.time < rhs.time
            }
        guard !ordered.isEmpty else { return [] }

        let threshold = baseScale + 0.000_1
        var result: [ZoomAnimationClip] = []
        var index = 0
        while index < ordered.count {
            guard ordered[index].scale > threshold else {
                index += 1
                continue
            }
            let firstZoomedIndex = index
            var lastZoomedIndex = index
            while lastZoomedIndex + 1 < ordered.count,
                  ordered[lastZoomedIndex + 1].scale > threshold {
                lastZoomedIndex += 1
            }
            let startIndex = max(firstZoomedIndex - 1, 0)
            let start = ordered[startIndex].time
            let end = lastZoomedIndex + 1 < ordered.count
                ? ordered[lastZoomedIndex + 1].time
                : max(ordered[lastZoomedIndex].time + 0.6, start + 0.6)
            let frames = Array(ordered[firstZoomedIndex...lastZoomedIndex])
            let representative = frames.max { lhs, rhs in
                lhs.scale == rhs.scale ? lhs.time < rhs.time : lhs.scale < rhs.scale
            } ?? ordered[firstZoomedIndex]
            let origin: ZoomKeyframeOrigin = frames.contains { $0.origin == .manual }
                ? .manual : .automatic
            if end - start > 0.01 {
                result.append(
                    ZoomAnimationClip(
                        startTime: start,
                        endTime: end,
                        scale: representative.scale,
                        focus: representative.focus,
                        origin: origin,
                        easing: defaultEasing
                    )
                )
            }
            index = lastZoomedIndex + 1
        }
        return result
    }
}

public struct ZoomKeyframe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: TimeInterval
    public var scale: Double
    public var focus: NormalizedPoint
    public var origin: ZoomKeyframeOrigin

    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        scale: Double,
        focus: NormalizedPoint,
        origin: ZoomKeyframeOrigin = .automatic
    ) {
        self.id = id
        self.time = time
        self.scale = scale
        self.focus = focus
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case id, time, scale, focus, origin
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try container.decode(TimeInterval.self, forKey: .time)
        scale = try container.decode(Double.self, forKey: .scale)
        focus = try container.decode(NormalizedPoint.self, forKey: .focus)
        origin = try container.decodeIfPresent(ZoomKeyframeOrigin.self, forKey: .origin)
            ?? .automatic
    }
}

public struct ZoomSample: Equatable, Sendable {
    public var scale: Double
    public var focus: NormalizedPoint
    public var framingProgress: Double
    public var targetScale: Double

    public init(
        scale: Double,
        focus: NormalizedPoint,
        framingProgress: Double? = nil,
        targetScale: Double? = nil
    ) {
        self.scale = scale
        self.focus = focus
        self.framingProgress = min(
            max(framingProgress ?? (scale > 1.0001 ? 1 : 0), 0),
            1
        )
        self.targetScale = max(targetScale ?? scale, 1)
    }
}

public struct ZoomViewportTransform: Equatable, Sendable {
    /// Manual anchors describe the source image, so they may reach every true
    /// edge and corner. The picker keeps its handle visible with visual padding
    /// instead of mutating the stored coordinate.
    public static let focusEdgeInset = 0.0

    /// Advisory guide used by the focus picker. It is deliberately separate
    /// from `focusEdgeInset`: users can drag beyond this guide to any corner.
    public static let compositionGuideInset = 0.12

    /// At full zoom, edge targets are composed inside this destination area.
    /// The source point remains the zoom anchor, but no longer hugs the canvas
    /// edge where it becomes difficult to read.
    public static let framingTargetInset = 0.30

    public var scale: Double
    public var translation: NormalizedPoint

    public init(scale: Double, translation: NormalizedPoint) {
        self.scale = scale
        self.translation = translation
    }

    /// Applies the same normalized, top-left-origin viewport transform used by
    /// preview and export. Keeping point mapping here prevents cursor and other
    /// overlays from drifting when the render backends use different axes.
    public func applying(to point: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: 0.5 + scale * (point.x - 0.5) + translation.x,
            y: 0.5 + scale * (point.y - 0.5) + translation.y
        )
    }

    public static func make(
        from sample: ZoomSample,
        crop: NormalizedCrop = .full
    ) -> ZoomViewportTransform {
        let scale = min(max(sample.scale, 1), 6)
        let safeCrop = crop.clamped()
        // focus 是源图归一化坐标，crop 编辑（正式功能）可能把裁切区移到焦点之外：
        // 不夹取会让 localFocus 越出 [0,1]²，缩放画面被推出画布数倍宽度。
        // 夹取后源空间锚点自动吸附到 crop 边缘，行为安全。
        let localFocus = NormalizedPoint(
            x: min(max((sample.focus.x - safeCrop.x) / safeCrop.width, 0), 1),
            y: min(max((sample.focus.y - safeCrop.y) / safeCrop.height, 0), 1)
        ).constrained(to: focusEdgeInset)
        let destination = localFocus.constrained(to: framingTargetInset)
        let progress = min(max(sample.framingProgress, 0), 1)
        let desiredPoint = NormalizedPoint(
            x: localFocus.x + (destination.x - localFocus.x) * progress,
            y: localFocus.y + (destination.y - localFocus.y) * progress
        )
        let scaledPoint = NormalizedPoint(
            x: 0.5 + scale * (localFocus.x - 0.5),
            y: 0.5 + scale * (localFocus.y - 0.5)
        )

        // Scale and camera travel share one progress value. This starts from
        // the manually selected anchor, finishes on a readable safe framing,
        // and remains continuous when two clips touch.
        return ZoomViewportTransform(
            scale: scale,
            translation: NormalizedPoint(
                x: desiredPoint.x - scaledPoint.x,
                y: desiredPoint.y - scaledPoint.y
            )
        )
    }
}

public struct ZoomAnimationTrack: Equatable, Sendable {
    public let animations: [ZoomAnimationClip]
    private let animationIndicesByID: [UUID: Int]
    /// Prefix maxima retain the former last-active-wins behaviour even if a
    /// caller constructs an unvalidated overlapping track. Valid project
    /// timelines normally inspect only the one binary-searched candidate.
    private let prefixMaximumEffectEnd: [TimeInterval]

    public init(_ animations: [ZoomAnimationClip]) {
        if TimelineTrackOrdering.zoomAnimationsNeedRepair(animations) {
            self.animations = animations
                .filter { $0.duration > 0.001 }
                .sorted { lhs, rhs in
                    lhs.startTime == rhs.startTime
                        ? lhs.id.uuidString < rhs.id.uuidString
                        : lhs.startTime < rhs.startTime
                }
        } else {
            self.animations = animations
        }
        var indicesByID: [UUID: Int] = [:]
        for (index, animation) in self.animations.enumerated()
        where indicesByID[animation.id] == nil {
            // Preserve the former `firstIndex` behaviour for unvalidated input
            // with duplicate IDs instead of trapping in Dictionary.init.
            indicesByID[animation.id] = index
        }
        animationIndicesByID = indicesByID
        var maximumEffectEnd = -TimeInterval.infinity
        prefixMaximumEffectEnd = self.animations.map { animation in
            maximumEffectEnd = max(maximumEffectEnd, animation.effectEndTime)
            return maximumEffectEnd
        }
    }

    public func sample(
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle(),
        automaticFocus: NormalizedPoint? = nil,
        inheritedAutomaticFocus: NormalizedPoint? = nil
    ) -> ZoomSample {
        ZoomInterpolator.sample(
            orderedAnimations: animations,
            activeClipIndex: activeClipIndex(at: time),
            at: time,
            motion: motion,
            automaticFocus: automaticFocus,
            inheritedAutomaticFocus: inheritedAutomaticFocus
        )
    }

    /// The clip whose focus policy is active at this output time. This shares
    /// the exact last-active-wins rule used by `sample`.
    public func activeClip(at time: TimeInterval) -> ZoomAnimationClip? {
        activeClipIndex(at: time).map { animations[$0] }
    }

    public func activeAutomaticClip(at time: TimeInterval) -> ZoomAnimationClip? {
        guard let clip = activeClip(at: time), clip.origin == .automatic else {
            return nil
        }
        return clip
    }

    /// Returns the clip whose held camera state must be inherited by `clip`.
    /// Keeping this lookup on the sorted track lets preview and export resolve
    /// the same boundary state without rebuilding or re-sorting animations.
    public func adjacentPreviousClip(to clip: ZoomAnimationClip) -> ZoomAnimationClip? {
        guard let index = animationIndicesByID[clip.id],
              index > animations.startIndex else { return nil }
        let previous = animations[index - 1]
        guard abs(previous.endTime - clip.startTime)
                <= ZoomInterpolator.adjacencyTolerance else { return nil }
        return previous
    }

    private func activeClipIndex(at time: TimeInterval) -> Int? {
        guard time.isFinite, !animations.isEmpty else { return nil }
        var lower = animations.startIndex
        var upper = animations.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if animations[middle].startTime <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > animations.startIndex else { return nil }
        var index = lower - 1
        while true {
            let clip = animations[index]
            if time >= clip.startTime, time <= clip.effectEndTime {
                return index
            }
            guard index > animations.startIndex,
                  prefixMaximumEffectEnd[index - 1] >= time else { return nil }
            index -= 1
        }
    }
}

public enum ZoomInterpolator {
    /// 两段缩放动画视为"相接"的最大间隙：相接时后一段从前一段的状态过渡，
    /// 前一段的退出过渡被休眠（不回落）。
    public static let adjacencyTolerance: TimeInterval = 1.0 / 120.0

    /// The no-track fallback path rebuilds and re-sorts the animation array
    /// for every sample; motion blur asks for many samples per output frame.
    /// Exact-match cache, same policy as CompositionSceneEvaluator.
    private static let trackCache = ZoomTrackCacheStore()

    public static func sample(
        animations: [ZoomAnimationClip],
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle(),
        automaticFocus: NormalizedPoint? = nil,
        inheritedAutomaticFocus: NormalizedPoint? = nil
    ) -> ZoomSample {
        trackCache.track(for: animations).sample(
            at: time,
            motion: motion,
            automaticFocus: automaticFocus,
            inheritedAutomaticFocus: inheritedAutomaticFocus
        )
    }

    static func sample(
        orderedAnimations: [ZoomAnimationClip],
        activeClipIndex: Int?,
        at time: TimeInterval,
        motion: MotionStyle,
        automaticFocus: NormalizedPoint?,
        inheritedAutomaticFocus: NormalizedPoint?
    ) -> ZoomSample {
        let center = NormalizedPoint(x: 0.5, y: 0.5)
        let ordered = orderedAnimations
        guard let clipIndex = activeClipIndex,
              ordered.indices.contains(clipIndex) else {
            return ZoomSample(scale: 1, focus: center, framingProgress: 0, targetScale: 1)
        }
        let clip = ordered[clipIndex]
        let targetFocus = automaticTargetFocus(for: clip, automaticFocus: automaticFocus)

        // Touching clips form one continuous camera move. At their shared
        // boundary the next clip starts from the previous clip's held state,
        // then eases scale and focus together toward its own target.
        let previous = clipIndex > ordered.startIndex ? ordered[clipIndex - 1] : nil
        let adjacentPrevious = previous.flatMap { candidate in
            abs(candidate.endTime - clip.startTime) <= Self.adjacencyTolerance
                ? candidate
                : nil
        }
        let inheritedStart = adjacentPrevious.map { previousClip in
            // Re-evaluate the previous automatic clip with the same camera
            // signal. This keeps the shared boundary continuous even when its
            // safe-zone follower had moved away from the original click area.
            ZoomSample(
                scale: previousClip.scale,
                focus: automaticTargetFocus(
                    for: previousClip,
                    automaticFocus: inheritedAutomaticFocus
                ),
                framingProgress: 1,
                targetScale: previousClip.scale
            )
        }

        let zoomProgress: Double
        let requestedEnterDuration: TimeInterval
        if inheritedStart != nil, clip.enterDuration <= 0.001 {
            // Older split clips were persisted with a zero enter duration.
            // Preserve those projects but render the hand-off with the current
            // project default instead of producing a one-frame jump.
            requestedEnterDuration = motion.defaultZoomTransitionDuration
        } else {
            requestedEnterDuration = clip.enterDuration
        }
        let effectiveEnterDuration = min(requestedEnterDuration, clip.duration)
        if effectiveEnterDuration > 0.001, time < clip.startTime + effectiveEnterDuration {
            let local = (time - clip.startTime) / effectiveEnterDuration
            let linear = clip.enterProgressOffset
                + (1 - clip.enterProgressOffset) * local
            zoomProgress = easedProgress(
                linear,
                preset: clip.easing,
                customCurve: clip.customCurve,
                motion: motion
            )
        } else if time <= clip.endTime {
            // The purple timeline clip represents the focus/hold interval.
            // Returning begins only after its trailing edge.
            zoomProgress = 1
        } else if clip.exitDuration > 0.001 {
            let local = (time - clip.endTime) / clip.exitDuration
            let linear = clip.exitProgressOffset
                + (1 - clip.exitProgressOffset) * local
            zoomProgress = 1 - easedProgress(
                linear,
                preset: clip.easing,
                customCurve: clip.customCurve,
                motion: motion
            )
        } else {
            zoomProgress = 0
        }
        if let inheritedStart, time <= clip.endTime {
            return ZoomSample(
                scale: interpolate(inheritedStart.scale, clip.scale, zoomProgress),
                focus: NormalizedPoint(
                    x: interpolate(inheritedStart.focus.x, targetFocus.x, zoomProgress),
                    y: interpolate(inheritedStart.focus.y, targetFocus.y, zoomProgress)
                ),
                framingProgress: 1,
                targetScale: interpolate(inheritedStart.scale, clip.scale, zoomProgress)
            )
        }
        return ZoomSample(
            scale: interpolate(1, clip.scale, zoomProgress),
            // Keep the same anchor throughout enter, hold and exit. Moving the
            // focus from the centre created the old centre-first zoom-and-slide.
            focus: targetFocus,
            framingProgress: zoomProgress,
            targetScale: clip.scale
        )
    }

    /// The caller supplies the stable focus authored by the click-group
    /// planner. Pointer reconstruction is deliberately independent: moving the
    /// cursor inside an interaction region must not re-lock or shake the camera.
    public static func automaticTargetFocus(
        for clip: ZoomAnimationClip,
        automaticFocus: NormalizedPoint?
    ) -> NormalizedPoint {
        let base = clip.focus.constrained(to: ZoomViewportTransform.focusEdgeInset)
        guard clip.origin == .automatic, let automaticFocus else { return base }
        return automaticFocus.constrained(to: ZoomViewportTransform.focusEdgeInset)
    }

    public static func easedProgress(
        _ value: Double,
        preset: ZoomEasingPreset,
        customCurve: ZoomBezierCurve = .cubic,
        motion: MotionStyle = MotionStyle()
    ) -> Double {
        let t = min(max(value, 0), 1)
        switch preset {
        case .linear:
            return ZoomBezierCurve.linear.value(at: t)
        case .quadratic:
            return ZoomBezierCurve.quadratic.value(at: t)
        case .cubic:
            return ZoomBezierCurve.cubic.value(at: t)
        case .quintic:
            return ZoomBezierCurve.quintic.value(at: t)
        case .spring:
            return springProgress(
                t,
                mass: motion.screenSpringMass,
                stiffness: motion.screenSpringStiffness,
                damping: motion.screenSpringDamping
            )
        case .custom:
            return customCurve.value(at: t)
        }
    }

    public static func sample(
        keyframes: [ZoomKeyframe],
        at time: TimeInterval,
        motion: MotionStyle = MotionStyle()
    ) -> ZoomSample {
        let ordered = keyframes.sorted { $0.time < $1.time }
        guard let first = ordered.first else {
            return ZoomSample(
                scale: 1,
                focus: NormalizedPoint(x: 0.5, y: 0.5),
                framingProgress: 0,
                targetScale: 1
            )
        }
        guard time > first.time else {
            return ZoomSample(
                scale: first.scale,
                focus: first.focus,
                framingProgress: first.scale > 1.0001 ? 1 : 0,
                targetScale: first.scale
            )
        }
        guard let last = ordered.last, time < last.time else {
            let finalScale = ordered.last?.scale ?? 1
            return ZoomSample(
                scale: finalScale,
                focus: ordered.last?.focus ?? first.focus,
                framingProgress: finalScale > 1.0001 ? 1 : 0,
                targetScale: finalScale
            )
        }

        guard let upperIndex = ordered.firstIndex(where: { $0.time >= time }), upperIndex > 0 else {
            return ZoomSample(
                scale: first.scale,
                focus: first.focus,
                framingProgress: first.scale > 1.0001 ? 1 : 0,
                targetScale: first.scale
            )
        }

        let lower = ordered[upperIndex - 1]
        let upper = ordered[upperIndex]
        let duration = max(upper.time - lower.time, .leastNonzeroMagnitude)
        let linearProgress = min(max((time - lower.time) / duration, 0), 1)
        let progress: Double
        switch motion.screen {
        case .focused:
            progress = springProgress(
                linearProgress,
                mass: motion.screenSpringMass,
                stiffness: motion.screenSpringStiffness,
                damping: motion.screenSpringDamping
            )
        case .smooth:
            let t = linearProgress
            progress = t * t * t * (t * (t * 6 - 15) + 10)
        }

        let sampledScale = interpolate(lower.scale, upper.scale, progress)
        let segmentTargetScale = max(lower.scale, upper.scale)
        let framingProgress = segmentTargetScale > 1.0001
            ? min(max((sampledScale - 1) / (segmentTargetScale - 1), 0), 1)
            : 0
        return ZoomSample(
            scale: sampledScale,
            focus: NormalizedPoint(
                x: interpolate(lower.focus.x, upper.focus.x, progress),
                y: interpolate(lower.focus.y, upper.focus.y, progress)
            ),
            framingProgress: framingProgress,
            targetScale: segmentTargetScale
        )
    }

    private static func interpolate(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    /// A normalized under-damped spring tuned for this editor. Normalizing the
    /// response keeps every keyframe segment on its exact endpoint.
    static func springProgress(
        _ value: Double,
        mass: Double,
        stiffness: Double,
        damping: Double
    ) -> Double {
        let t = min(max(value, 0), 1)
        guard t > 0, t < 1 else { return t }
        let safeMass = max(mass, 0.01)
        let safeStiffness = max(stiffness, 0.01)
        let safeDamping = max(damping, 0.01)
        let omega0 = sqrt(safeStiffness / safeMass)
        let zeta = min(safeDamping / (2 * sqrt(safeStiffness * safeMass)), 0.9999)
        let omegaD = omega0 * sqrt(max(1 - zeta * zeta, .leastNonzeroMagnitude))
        let duration = 0.72

        func response(at seconds: Double) -> Double {
            let envelope = exp(-zeta * omega0 * seconds)
            let oscillation = cos(omegaD * seconds)
                + (zeta * omega0 / omegaD) * sin(omegaD * seconds)
            return 1 - envelope * oscillation
        }

        return min(max(response(at: t * duration) / response(at: duration), 0), 1)
    }
}

private final class ZoomTrackCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: [ZoomAnimationClip], track: ZoomAnimationTrack)] = []

    func track(for animations: [ZoomAnimationClip]) -> ZoomAnimationTrack {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries.first(where: { $0.key == animations }) {
            return entry.track
        }
        let track = ZoomAnimationTrack(animations)
        entries.insert((animations, track), at: 0)
        if entries.count > 4 { entries.removeLast() }
        return track
    }
}
