import Foundation

public struct TimelineZoomSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let scale: Double
    public let origin: ZoomKeyframeOrigin
    public let representativeKeyframeID: UUID
    public let easing: ZoomEasingPreset
    public let enterDuration: TimeInterval
    public let exitDuration: TimeInterval

    public init(
        id: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        scale: Double,
        origin: ZoomKeyframeOrigin,
        representativeKeyframeID: UUID,
        easing: ZoomEasingPreset = .cubic,
        enterDuration: TimeInterval = 0.7,
        exitDuration: TimeInterval = 0.7
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.scale = scale
        self.origin = origin
        self.representativeKeyframeID = representativeKeyframeID
        self.easing = easing
        self.enterDuration = enterDuration
        self.exitDuration = exitDuration
    }
}

public enum ZoomTrackHitZone: Equatable, Sendable {
    case empty
    case move(UUID)
    case resize(UUID, leading: Bool)
}

public enum EditorTimelineMath {
    /// 把一次拖动/点选的范围拟合进两段之间的空隙：落在回落窗口"洞口"里时
    /// 吸到相接，间隙再小也尽量放下（贴合两侧、缩短回落窗口、最短 0.08s），
    /// 只有完全没有空隙时才拒绝创建。
    public static func fitZoomAnimation(
        start: TimeInterval,
        end: TimeInterval,
        among animations: [ZoomAnimationClip],
        duration: TimeInterval,
        scale: Double = 1.6,
        focus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        origin: ZoomKeyframeOrigin = .automatic,
        easing: ZoomEasingPreset = .cubic,
        transitionDuration: TimeInterval = 0.7
    ) -> ZoomAnimationClip? {
        guard duration.isFinite, duration > 0 else { return nil }
        let rawStart = min(max(min(start, end), 0), duration)
        let (previous, next) = creationNeighbours(
            at: rawStart,
            in: animations,
            startTime: { $0.startTime },
            itemsAreOrdered: false
        )
        let lowerTouch = previous?.endTime ?? 0
        let lowerClear = previous.map {
            $0.endTime + effectiveExitDuration(of: $0, defaultExit: transitionDuration)
        } ?? 0
        let upper = next?.startTime ?? duration
        guard upper - lowerTouch > 0.001 else { return nil }

        let minimumDuration = 0.08
        var s = min(max(min(start, end), lowerTouch), upper)
        // 起点落入洞口：吸到与前一段相接。
        if s < lowerClear { s = lowerTouch }
        let isClick = abs(end - start) < 0.08
        let requestedLength: TimeInterval
        if isClick {
            requestedLength = min(1.5, max(duration * 0.2, 0.6))
        } else {
            requestedLength = max(abs(end - start), minimumDuration)
        }
        var e = s + requestedLength
        if e > upper {
            e = upper
            // 保持长度优先：整段左移进空隙；空隙连最短时长都放不下时，
            // 缩成刚好填满空隙（两端相接）。
            let shifted = max(e - requestedLength, lowerTouch)
            if upper - shifted >= minimumDuration {
                s = shifted
            } else {
                s = lowerTouch
            }
        }
        guard e - s >= minimumDuration - 0.000_1, e - s > 0.001 else { return nil }
        // 回落窗口适配剩余间隙（可短，不留就相接下一段）。
        let fittedExit = min(transitionDuration, max(upper - e, 0))
        return ZoomAnimationClip(
            startTime: s,
            endTime: e,
            scale: scale,
            focus: focus,
            origin: origin,
            easing: easing,
            enterDuration: transitionDuration,
            exitDuration: fittedExit,
            preferredEnterDuration: transitionDuration,
            preferredExitDuration: transitionDuration
        )
    }

    public static func manualZoomAnimation(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval,
        scale: Double = 1.6,
        focus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        easing: ZoomEasingPreset = .cubic,
        transitionDuration: TimeInterval = 0.7
    ) -> ZoomAnimationClip? {
        guard duration.isFinite, duration > 0 else { return nil }
        let rawStart = min(max(min(start, end), 0), duration)
        let draggedDuration = abs(end - start)
        let requestedEnd = draggedDuration < 0.08
            ? min(rawStart + min(1.5, max(duration * 0.2, 0.6)), duration)
            : min(max(max(start, end), 0), duration)
        let minimumDuration = min(0.24, max(duration - rawStart, 0))
        let rangeEnd = min(max(requestedEnd, rawStart + minimumDuration), duration)
        guard rangeEnd - rawStart > 0.01 else { return nil }
        return ZoomAnimationClip(
            startTime: rawStart,
            endTime: rangeEnd,
            scale: scale,
            focus: focus,
            origin: .manual,
            easing: easing,
            enterDuration: transitionDuration,
            exitDuration: transitionDuration
        )
    }

    public static func manualZoomRangeKeyframes(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval,
        scale: Double = 1.6,
        focus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5)
    ) -> [ZoomKeyframe] {
        guard duration.isFinite, duration > 0 else { return [] }
        let rawStart = min(max(min(start, end), 0), duration)
        let draggedDuration = abs(end - start)
        let requestedEnd = draggedDuration < 0.08
            ? min(rawStart + min(1.5, max(duration * 0.2, 0.6)), duration)
            : min(max(max(start, end), 0), duration)
        let minimumDuration = min(0.6, max(duration - rawStart, 0))
        let rangeEnd = min(max(requestedEnd, rawStart + minimumDuration), duration)
        guard rangeEnd - rawStart > 0.01 else { return [] }

        let transition = min(0.28, (rangeEnd - rawStart) * 0.3)
        let zoomInTime = rawStart + transition
        let zoomOutTime = max(rangeEnd - transition, zoomInTime + 0.001)
        return [
            ZoomKeyframe(time: rawStart, scale: 1, focus: focus, origin: .manual),
            ZoomKeyframe(time: zoomInTime, scale: max(scale, 1), focus: focus, origin: .manual),
            ZoomKeyframe(time: zoomOutTime, scale: max(scale, 1), focus: focus, origin: .manual),
            ZoomKeyframe(time: rangeEnd, scale: 1, focus: focus, origin: .manual),
        ]
    }

    public static func clampedTime(
        atX x: Double,
        width: Double,
        duration: TimeInterval
    ) -> TimeInterval {
        guard width.isFinite, width > 0, duration.isFinite, duration > 0 else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }

    public static func xPosition(
        for time: TimeInterval,
        width: Double,
        duration: TimeInterval
    ) -> Double {
        guard width.isFinite, width > 0, duration.isFinite, duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1) * width
    }

    public static func zoomSegments(
        from animations: [ZoomAnimationClip],
        duration: TimeInterval
    ) -> [TimelineZoomSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        return animations
            .filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }
            .map { clip in
                TimelineZoomSegment(
                    id: clip.id,
                    startTime: min(max(clip.startTime, 0), duration),
                    endTime: min(max(clip.endTime, 0), duration),
                    scale: clip.scale,
                    origin: clip.origin,
                    representativeKeyframeID: clip.id,
                    easing: clip.easing,
                    enterDuration: clip.enterDuration,
                    exitDuration: clip.exitDuration
                )
            }
            .filter { $0.endTime - $0.startTime > 0.001 }
            .sorted { $0.startTime < $1.startTime }
    }

    public static func split(
        animation: ZoomAnimationClip,
        at time: TimeInterval,
        minimumDuration: TimeInterval = 0.16
    ) -> (ZoomAnimationClip, ZoomAnimationClip)? {
        let splitTime = min(max(time, animation.startTime), animation.endTime)
        guard splitTime - animation.startTime >= minimumDuration,
              animation.endTime - splitTime >= minimumDuration else { return nil }
        var left = animation
        left.preserveTransitionIntent()
        left.endTime = splitTime
        left.exitDuration = 0
        var right = animation
        right.preserveTransitionIntent()
        right.id = UUID()
        right.startTime = splitTime
        // A split creates two touching camera states. Keep an actual hand-off
        // duration on the right clip so editing its focus produces a smooth
        // pan/zoom instead of an instantaneous jump at the cut.
        right.enterDuration = max(animation.enterDuration, 0.15)
        return (left, right)
    }

    /// 相邻两段缩放的合法关系：片段区间不重叠，且要么"相接"（间隙在容差内，
    /// 前一段的退出过渡休眠、后一段从前一段状态过渡），要么给前一段留足整个
    /// 退出回落窗口。落在窗口中段（没接上又没让开）会在视觉上把回落拦腰切断。
    public static func zoomSequenceIsValid(
        previous: ZoomAnimationClip,
        next: ZoomAnimationClip,
        previousExit: TimeInterval? = nil
    ) -> Bool {
        guard next.startTime >= previous.endTime - 0.000_1 else { return false }
        guard next.startTime - previous.endTime > ZoomInterpolator.adjacencyTolerance else {
            return true
        }
        let exit = previousExit ?? previous.exitDuration
        return next.startTime >= previous.endTime + exit - 0.000_1
    }

    /// 没有显式退出时长的片段在成为结尾时按默认过渡计（回落总是平滑的）。
    public static func effectiveExitDuration(
        of clip: ZoomAnimationClip,
        defaultExit: TimeInterval
    ) -> TimeInterval {
        clip.requestedExitDuration(defaultTransition: defaultExit)
    }

    /// 拖动/调整一段缩放后修复退出时长：被编辑片段及其前驱一旦不再与后一段
    /// 相接就成为"结尾"——退出时长为 0 时补上默认过渡，避免结尾瞬跳回 1×。
    /// 补上的时长按剩余间隙封顶：超出间隙会让 effectEndTime 越过邻居起点，
    /// 提交校验失败、整个拖动被回滚（用户看到的是"松手又缩回去了"）。
    /// 仍相接的片段保持不变（退出时长继续休眠）。
    public static func exitNormalizations(
        afterEditing id: UUID,
        among animations: [ZoomAnimationClip],
        defaultExit: TimeInterval
    ) -> [ZoomAnimationClip] {
        guard let edited = animations.first(where: { $0.id == id }) else { return [] }
        var predecessor: ZoomAnimationClip?
        var successor: ZoomAnimationClip?
        for candidate in animations where candidate.id != id {
            if zoomAnimationPrecedes(candidate, edited) {
                if predecessor == nil || zoomAnimationPrecedes(predecessor!, candidate) {
                    predecessor = candidate
                }
            } else if successor == nil || zoomAnimationPrecedes(candidate, successor!) {
                successor = candidate
            }
        }

        var patches: [ZoomAnimationClip] = []
        func appendPatch(
            for clip: ZoomAnimationClip,
            followedBy next: ZoomAnimationClip?
        ) {
            let touchesSuccessor = next.map {
                abs($0.startTime - clip.endTime) <= ZoomInterpolator.adjacencyTolerance
            } ?? false
            guard !touchesSuccessor else { return }
            let requested = clip.requestedExitDuration(defaultTransition: defaultExit)
            let available = next.map { $0.startTime - clip.endTime }
                ?? requested
            var patched = clip
            patched.preserveTransitionIntent(defaultTransition: defaultExit)
            patched.exitDuration = min(requested, max(available, 0))
            if patched != clip { patches.append(patched) }
        }
        if let predecessor { appendPatch(for: predecessor, followedBy: edited) }
        appendPatch(for: edited, followedBy: successor)
        return patches
    }

    public static func moving(
        animation: ZoomAnimationClip,
        to proposedStart: TimeInterval,
        among animations: [ZoomAnimationClip],
        duration: TimeInterval,
        defaultExit: TimeInterval = 0.7
    ) -> ZoomAnimationClip {
        let (previous, next) = zoomAnimationNeighbours(
            of: animation,
            among: animations
        )
        let previousEnd = previous?.endTime ?? 0
        let previousClear = previousEnd + (previous.map {
            effectiveExitDuration(of: $0, defaultExit: defaultExit)
        } ?? 0)
        let nextStart = next?.startTime ?? duration
        let ownExit = effectiveExitDuration(of: animation, defaultExit: defaultExit)
        let touchStart = nextStart - animation.duration
        // 间隙连片段区间本身都放不下（贴住两侧也不够长）：拒绝移动。
        guard touchStart >= previousEnd - 0.000_1 else { return animation }

        func isValid(_ start: TimeInterval) -> Bool {
            let touchesPrevious = start <= previousEnd + ZoomInterpolator.adjacencyTolerance
            let clearsPrevious = start >= previousClear - 0.000_1
            let end = start + animation.duration
            let touchesNext = nextStart - end <= ZoomInterpolator.adjacencyTolerance
            let clearsNext = end + ownExit <= nextStart + 0.000_1
            return (touchesPrevious || clearsPrevious) && (touchesNext || clearsNext)
        }

        // 自由夹取到绝对边界；落入"洞口"时吸附到最近的合法位置（磁吸相接）。
        var start = min(max(proposedStart, previousEnd), touchStart)
        if !isValid(start) {
            let candidates = [
                previousEnd, previousClear,
                touchStart, touchStart - ownExit,
            ].filter { isValid($0) && $0 >= previousEnd - 0.000_1 && $0 <= touchStart + 0.000_1 }
            guard let snapped = candidates.min(by: {
                abs($0 - proposedStart) < abs($1 - proposedStart)
            }) else { return animation }
            start = snapped
        }
        var moved = animation
        moved.startTime = start
        moved.endTime = start + animation.duration
        return moved
    }

    public static func resizing(
        animation: ZoomAnimationClip,
        proposedStart: TimeInterval? = nil,
        proposedEnd: TimeInterval? = nil,
        among animations: [ZoomAnimationClip],
        duration: TimeInterval,
        minimumDuration: TimeInterval = 0.16,
        defaultExit: TimeInterval = 0.7
    ) -> ZoomAnimationClip {
        let (previous, next) = zoomAnimationNeighbours(
            of: animation,
            among: animations
        )
        let previousEnd = previous?.endTime ?? 0
        let previousClear = previousEnd + (previous.map {
            effectiveExitDuration(of: $0, defaultExit: defaultExit)
        } ?? 0)
        let nextStart = next?.startTime ?? duration
        let ownExit = effectiveExitDuration(of: animation, defaultExit: defaultExit)
        var resized = animation
        if let proposedStart {
            let lowerBound = previousEnd
            let upperBound = animation.endTime - minimumDuration
            func isValid(_ start: TimeInterval) -> Bool {
                guard start <= upperBound + 0.000_1 else { return false }
                return start <= previousEnd + ZoomInterpolator.adjacencyTolerance
                    || start >= previousClear - 0.000_1
            }
            var start = min(max(proposedStart, lowerBound), max(upperBound, lowerBound))
            if !isValid(start) {
                let candidates = [previousEnd, previousClear, upperBound]
                    .filter { isValid($0) && $0 >= lowerBound - 0.000_1 }
                guard let snapped = candidates.min(by: {
                    abs($0 - proposedStart) < abs($1 - proposedStart)
                }) else { return animation }
                start = snapped
            }
            resized.startTime = start
        }
        if let proposedEnd {
            let lowerBound = animation.startTime + minimumDuration
            let upperBound = nextStart
            func isValid(_ end: TimeInterval) -> Bool {
                guard end >= lowerBound - 0.000_1 else { return false }
                return nextStart - end <= ZoomInterpolator.adjacencyTolerance
                    || end + ownExit <= nextStart + 0.000_1
            }
            var end = min(max(proposedEnd, lowerBound), max(upperBound, lowerBound))
            if !isValid(end) {
                let candidates = [nextStart, nextStart - ownExit, lowerBound]
                    .filter { isValid($0) && $0 <= upperBound + 0.000_1 }
                guard let snapped = candidates.min(by: {
                    abs($0 - proposedEnd) < abs($1 - proposedEnd)
                }) else { return animation }
                end = snapped
            }
            resized.endTime = end
        }
        return resized
    }

    /// 缩放轨道的指针命中测试。与 `zoomTimeline` 的布局公式保持一致：片段条
    /// 垂直居中、最短渲染宽度 14pt、手柄仅对选中/悬停的片段出现。命中的唯一
    /// 消费者是轨道级单一拖动手势——不再把创建/移动/调整拆成三个相互竞争的
    /// 手势（兄弟手势竞争曾让空白创建手势抢走片段上的每一次按下）。
    public static func zoomHitZone(
        x: Double,
        y: Double,
        segments: [TimelineZoomSegment],
        width: Double,
        duration: TimeInterval,
        selectedID: UUID?,
        hoveredID: UUID?,
        trackHeight: Double = 56,
        barHeight: Double = 42,
        minimumSegmentWidth: Double = 14,
        segmentsAreOrdered: Bool = false
    ) -> ZoomTrackHitZone {
        guard width.isFinite, width > 0, duration.isFinite, duration > 0,
              x.isFinite, y.isFinite else { return .empty }
        let barMinY = (trackHeight - barHeight) / 2
        let barMaxY = barMinY + barHeight
        guard y >= barMinY, y <= barMaxY else { return .empty }
        func zone(for segment: TimelineZoomSegment) -> ZoomTrackHitZone? {
            let startX = segment.startTime / duration * width
            let segmentWidth = max(
                (segment.endTime - segment.startTime) / duration * width,
                minimumSegmentWidth
            )
            guard x >= startX, x <= startX + segmentWidth else { return nil }
            if segment.id == selectedID || segment.id == hoveredID {
                let handleHalfWidth = min(9, segmentWidth * 0.35)
                if x - startX <= handleHalfWidth {
                    return .resize(segment.id, leading: true)
                }
                if startX + segmentWidth - x <= handleHalfWidth {
                    return .resize(segment.id, leading: false)
                }
            }
            return .move(segment.id)
        }

        if segmentsAreOrdered {
            guard let index = lastItemStartingAtOrBefore(
                x,
                in: segments,
                startX: { $0.startTime / duration * width }
            ) else { return .empty }
            return zone(for: segments[index]) ?? .empty
        }

        // 后声明的片段渲染在更上层；命中测试也从最上层开始。
        for segment in segments.reversed() {
            if let hit = zone(for: segment) { return hit }
        }
        return .empty
    }

    /// 运动轨道的指针命中测试：与缩放轨同一交互模型（片段条垂直居中、手柄
    /// 仅对选中/悬停片段出现），供轨道级单一拖动手势分发。
    public static func motionHitZone(
        x: Double,
        y: Double,
        timings: [(id: UUID, timing: TransitionTiming)],
        width: Double,
        duration: TimeInterval,
        selectedID: UUID?,
        hoveredID: UUID?,
        trackHeight: Double = 46,
        barHeight: Double = 36,
        minimumClipWidth: Double = 7,
        itemsAreOrdered: Bool = false
    ) -> ZoomTrackHitZone {
        motionHitZone(
            x: x,
            y: y,
            items: timings,
            id: { $0.id },
            timing: { $0.timing },
            width: width,
            duration: duration,
            selectedID: selectedID,
            hoveredID: hoveredID,
            trackHeight: trackHeight,
            barHeight: barHeight,
            minimumClipWidth: minimumClipWidth,
            itemsAreOrdered: itemsAreOrdered
        )
    }

    /// Generic fast path used by the editor's already ordered presentation
    /// clips. It avoids mapping the complete track to temporary tuples on every
    /// hover event. Legacy unordered inputs still receive deterministic z-order.
    public static func motionHitZone<Element>(
        x: Double,
        y: Double,
        items: [Element],
        id: (Element) -> UUID,
        timing: (Element) -> TransitionTiming,
        width: Double,
        duration: TimeInterval,
        selectedID: UUID?,
        hoveredID: UUID?,
        trackHeight: Double = 46,
        barHeight: Double = 36,
        minimumClipWidth: Double = 7,
        itemsAreOrdered: Bool = false
    ) -> ZoomTrackHitZone {
        guard width.isFinite, width > 0, duration.isFinite, duration > 0,
              x.isFinite, y.isFinite else { return .empty }
        let barMinY = (trackHeight - barHeight) / 2
        let barMaxY = barMinY + barHeight
        guard y >= barMinY, y <= barMaxY else { return .empty }

        func zone(for item: Element) -> ZoomTrackHitZone? {
            let clipID = id(item)
            let clipTiming = timing(item)
            let startX = clipTiming.startTime / duration * width
            let clipWidth = max(
                (clipTiming.endTime - clipTiming.startTime) / duration * width,
                minimumClipWidth
            )
            guard x >= startX, x <= startX + clipWidth else { return nil }
            if clipID == selectedID || clipID == hoveredID {
                let handleHalfWidth = min(8, clipWidth * 0.35)
                if x - startX <= handleHalfWidth {
                    return .resize(clipID, leading: true)
                }
                if startX + clipWidth - x <= handleHalfWidth {
                    return .resize(clipID, leading: false)
                }
            }
            return .move(clipID)
        }

        if itemsAreOrdered {
            guard let index = lastItemStartingAtOrBefore(
                x,
                in: items,
                startX: { timing($0).startTime / duration * width }
            ) else { return .empty }
            return zone(for: items[index]) ?? .empty
        }

        let isOrdered = items.indices.dropFirst().allSatisfy { index in
            !motionItemPrecedes(
                items[index],
                items[index - 1],
                id: id,
                timing: timing
            )
        }
        if isOrdered {
            for item in items.reversed() {
                if let hit = zone(for: item) { return hit }
            }
            return .empty
        }

        let orderedIndices = items.indices.sorted { lhs, rhs in
            motionItemPrecedes(items[lhs], items[rhs], id: id, timing: timing)
        }
        for index in orderedIndices.reversed() {
            if let hit = zone(for: items[index]) { return hit }
        }
        return .empty
    }

    /// 运动片段的创建拟合：与缩放创建同思路——起点落入前一段回落窗口"洞口"
    /// 时吸到相接，小间隙贴合两侧并适配回落窗口，完全没有空隙才返回 nil。
    public static func fitMotionTiming(
        start: TimeInterval,
        end: TimeInterval,
        among timings: [TransitionTiming],
        duration: TimeInterval,
        easing: ZoomEasingPreset = .cubic,
        returnDuration: TimeInterval,
        leadInDuration: TimeInterval? = nil,
        itemsAreOrdered: Bool = false
    ) -> TransitionTiming? {
        fitMotionTiming(
            start: start,
            end: end,
            among: timings,
            timing: { $0 },
            duration: duration,
            easing: easing,
            returnDuration: returnDuration,
            leadInDuration: leadInDuration,
            itemsAreOrdered: itemsAreOrdered
        )
    }

    /// Direct-item overload for editor presentation clips. The common hover
    /// path no longer builds a second full timing array before fitting a gap.
    public static func fitMotionTiming<Element>(
        start: TimeInterval,
        end: TimeInterval,
        among items: [Element],
        timing: (Element) -> TransitionTiming,
        duration: TimeInterval,
        easing: ZoomEasingPreset = .cubic,
        returnDuration: TimeInterval,
        leadInDuration: TimeInterval? = nil,
        itemsAreOrdered: Bool = false
    ) -> TransitionTiming? {
        guard duration.isFinite, duration > 0 else { return nil }
        let rawStart = min(max(min(start, end), 0), duration)
        let (previousItem, nextItem) = creationNeighbours(
            at: rawStart,
            in: items,
            startTime: { timing($0).startTime },
            itemsAreOrdered: itemsAreOrdered
        )
        let previous = previousItem.map(timing)
        let next = nextItem.map(timing)
        let lowerTouch = previous?.endTime ?? 0
        let lowerClear = previous.map {
            $0.endTime + ($0.returnDuration > 0.000_1 ? $0.returnDuration : returnDuration)
        } ?? 0
        let upper = next?.startTime ?? duration
        guard upper - lowerTouch > 0.001 else { return nil }

        let minimumDuration = 0.16
        var s = min(max(min(start, end), lowerTouch), upper)
        if s < lowerClear { s = lowerTouch }
        let isClick = abs(end - start) < 0.08
        let requestedLength: TimeInterval
        if isClick {
            requestedLength = min(1.2, max(duration * 0.15, 0.5))
        } else {
            requestedLength = max(abs(end - start), minimumDuration)
        }
        var e = s + requestedLength
        if e > upper {
            e = upper
            let shifted = max(e - requestedLength, lowerTouch)
            if upper - shifted >= minimumDuration {
                s = shifted
            } else {
                s = lowerTouch
            }
        }
        guard e - s >= minimumDuration - 0.000_1, e - s > 0.001 else { return nil }
        let fittedReturn = min(returnDuration, max(upper - e, 0))
        // 进入过渡按传入速度（默认整段），不超过整段时长，其余为保持
        let fittedLeadIn = min(max(leadInDuration ?? (e - s), 0), e - s)
        return TransitionTiming(
            startTime: s,
            duration: e - s,
            leadInDuration: fittedLeadIn,
            easing: easing,
            returnDuration: fittedReturn
        )
    }

    /// Finds the item immediately before/at the requested start and its direct
    /// successor without sorting or materializing another array. Canonical
    /// ordered tracks use binary search; two bounded scans preserve support for
    /// legacy unordered project inputs.
    private static func creationNeighbours<Element>(
        at rawStart: TimeInterval,
        in items: [Element],
        startTime: (Element) -> TimeInterval,
        itemsAreOrdered: Bool
    ) -> (previous: Element?, next: Element?) {
        if itemsAreOrdered {
            var lower = 0
            var upper = items.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if startTime(items[middle]) <= rawStart + 0.000_1 {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return (
                lower > 0 ? items[lower - 1] : nil,
                lower < items.count ? items[lower] : nil
            )
        }

        var previous: Element?
        var previousStart = -TimeInterval.infinity
        for item in items {
            let candidateStart = startTime(item)
            guard candidateStart <= rawStart + 0.000_1,
                  candidateStart >= previousStart else { continue }
            previous = item
            previousStart = candidateStart
        }

        let threshold = previous.map(startTime) ?? -1
        var next: Element?
        var nextStart = TimeInterval.infinity
        for item in items {
            let candidateStart = startTime(item)
            guard candidateStart > threshold + 0.000_1,
                  candidateStart < nextStart else { continue }
            next = item
            nextStart = candidateStart
        }
        return (previous, next)
    }

    private static func lastItemStartingAtOrBefore<Element>(
        _ x: Double,
        in items: [Element],
        startX: (Element) -> Double
    ) -> Int? {
        var lower = 0
        var upper = items.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if startX(items[middle]) <= x {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    private static func motionItemPrecedes<Element>(
        _ lhs: Element,
        _ rhs: Element,
        id: (Element) -> UUID,
        timing: (Element) -> TransitionTiming
    ) -> Bool {
        let lhsTiming = timing(lhs)
        let rhsTiming = timing(rhs)
        return lhsTiming.startTime == rhsTiming.startTime
            ? id(lhs).uuidString < id(rhs).uuidString
            : lhsTiming.startTime < rhsTiming.startTime
    }

    /// 运动片段的回落归一：被编辑片段及其前驱一旦不再与后一段相接就成为
    /// "结尾"——回落时长为 0 时补上默认回落（避免结尾永久保持目标状态）。
    /// 与缩放同一规则：补上的时长按剩余间隙封顶，否则提交校验失败、拖动被
    /// 整体回滚（用户看到的是"缩回去了"）。
    public static func motionReturnNormalizations(
        afterEditing id: UUID,
        among timings: [(id: UUID, timing: TransitionTiming)],
        defaultReturn: TimeInterval
    ) -> [(id: UUID, timing: TransitionTiming)] {
        motionReturnNormalizations(
            afterEditing: id,
            among: timings,
            id: { $0.id },
            timing: { $0.timing },
            defaultReturn: defaultReturn
        )
    }

    /// Direct-item overload for drag previews. Updating a motion clip occurs on
    /// every pointer event, so callers should not have to map the complete track
    /// to temporary timing tuples merely to repair one return transition.
    public static func motionReturnNormalizations<Element>(
        afterEditing editedID: UUID,
        among items: [Element],
        id: (Element) -> UUID,
        timing: (Element) -> TransitionTiming,
        defaultReturn: TimeInterval
    ) -> [(id: UUID, timing: TransitionTiming)] {
        guard let editedItem = items.first(where: { id($0) == editedID }) else { return [] }
        let edited = (id: id(editedItem), timing: timing(editedItem))
        var predecessor: (id: UUID, timing: TransitionTiming)?
        var successor: (id: UUID, timing: TransitionTiming)?
        for item in items where id(item) != editedID {
            let candidate = (id: id(item), timing: timing(item))
            if motionTimingPrecedes(candidate, edited) {
                if predecessor == nil || motionTimingPrecedes(predecessor!, candidate) {
                    predecessor = candidate
                }
            } else if successor == nil || motionTimingPrecedes(candidate, successor!) {
                successor = candidate
            }
        }

        var patches: [(id: UUID, timing: TransitionTiming)] = []
        func appendPatch(
            for clip: (id: UUID, timing: TransitionTiming),
            followedBy next: (id: UUID, timing: TransitionTiming)?
        ) {
            let touchesSuccessor = next.map {
                abs($0.timing.startTime - clip.timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            } ?? false
            guard !touchesSuccessor,
                  clip.timing.returnDuration <= 0.000_1 else { return }
            let available = next.map { $0.timing.startTime - clip.timing.endTime }
                ?? max(defaultReturn, 0)
            var patched = clip.timing
            patched.returnDuration = min(max(defaultReturn, 0), max(available, 0))
            patches.append((clip.id, patched))
        }
        if let predecessor { appendPatch(for: predecessor, followedBy: edited) }
        appendPatch(for: edited, followedBy: successor)
        return patches
    }

    private static func zoomAnimationNeighbours(
        of animation: ZoomAnimationClip,
        among animations: [ZoomAnimationClip]
    ) -> (previous: ZoomAnimationClip?, next: ZoomAnimationClip?) {
        var previous: ZoomAnimationClip?
        var next: ZoomAnimationClip?
        for candidate in animations where candidate.id != animation.id {
            if candidate.startTime < animation.startTime - 0.000_1 {
                if previous == nil || zoomAnimationPrecedes(previous!, candidate) {
                    previous = candidate
                }
            } else if candidate.startTime >= animation.endTime - 0.000_1,
                      next == nil || zoomAnimationPrecedes(candidate, next!) {
                next = candidate
            }
        }
        return (previous, next)
    }

    private static func zoomAnimationPrecedes(
        _ lhs: ZoomAnimationClip,
        _ rhs: ZoomAnimationClip
    ) -> Bool {
        lhs.startTime == rhs.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.startTime < rhs.startTime
    }

    private static func motionTimingPrecedes(
        _ lhs: (id: UUID, timing: TransitionTiming),
        _ rhs: (id: UUID, timing: TransitionTiming)
    ) -> Bool {
        lhs.timing.startTime == rhs.timing.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.timing.startTime < rhs.timing.startTime
    }

    public static func zoomSegments(
        from keyframes: [ZoomKeyframe],
        duration: TimeInterval,
        baseScale: Double = 1
    ) -> [TimelineZoomSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        let ordered = keyframes
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }
            .sorted { lhs, rhs in
                lhs.time == rhs.time ? lhs.id.uuidString < rhs.id.uuidString : lhs.time < rhs.time
            }
        guard !ordered.isEmpty else { return [] }

        let zoomThreshold = baseScale + 0.000_1
        var segments: [TimelineZoomSegment] = []
        var index = 0
        while index < ordered.count {
            guard ordered[index].scale > zoomThreshold else {
                index += 1
                continue
            }

            let firstZoomedIndex = index
            let startIndex = max(firstZoomedIndex - 1, 0)
            var endIndex = firstZoomedIndex
            while endIndex + 1 < ordered.count,
                  ordered[endIndex + 1].scale > zoomThreshold {
                endIndex += 1
            }

            let startTime = min(max(ordered[startIndex].time, 0), duration)
            let rawEndTime: TimeInterval
            if endIndex + 1 < ordered.count {
                rawEndTime = ordered[endIndex + 1].time
            } else {
                rawEndTime = duration
            }
            let endTime = min(max(rawEndTime, startTime), duration)
            let zoomedFrames = Array(ordered[firstZoomedIndex...endIndex])
            let representative = zoomedFrames.max { lhs, rhs in
                if lhs.scale == rhs.scale { return lhs.time < rhs.time }
                return lhs.scale < rhs.scale
            } ?? ordered[firstZoomedIndex]
            let origin: ZoomKeyframeOrigin = zoomedFrames.contains { $0.origin == .manual }
                ? .manual : .automatic

            if endTime - startTime > 0.001 {
                segments.append(
                    TimelineZoomSegment(
                        id: representative.id,
                        startTime: startTime,
                        endTime: endTime,
                        scale: representative.scale,
                        origin: origin,
                        representativeKeyframeID: representative.id,
                        easing: .cubic,
                        enterDuration: 0.55,
                        exitDuration: 0.55
                    )
                )
            }
            index = endIndex + 1
        }
        return segments
    }
}
