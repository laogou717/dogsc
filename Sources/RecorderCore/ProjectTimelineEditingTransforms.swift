import Foundation

extension ProjectTimelineEditing {
    static func ripple(
        _ timeline: ProjectTimeline,
        replacingSourceSequenceWith sourceSequence: SourceSequence,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool,
        fullSourceDuration: TimeInterval,
        defaultTransitionDuration: TimeInterval
    ) throws -> ProjectTimeline {
        var result = timeline
        result.sourceSequence = sourceSequence
        result.zoomClips = try timeline.zoomClips.compactMap {
            try ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        result.screenMotionClips = try timeline.screenMotionClips.compactMap {
            try ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        result.cameraMotionClips = try timeline.cameraMotionClips.compactMap {
            try ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        if !deletesOutputTail {
            result.zoomClips = restoredZoomLeadInsAtRippleJunction(
                original: timeline.zoomClips,
                mapped: result.zoomClips,
                deletion: deletion,
                defaultTransition: defaultTransitionDuration
            )
            result.screenMotionClips = restoredScreenLeadInsAtRippleJunction(
                original: timeline.screenMotionClips,
                mapped: result.screenMotionClips,
                deletion: deletion,
                defaultTransition: defaultTransitionDuration
            )
            result.cameraMotionClips = restoredCameraLeadInsAtRippleJunction(
                original: timeline.cameraMotionClips,
                mapped: result.cameraMotionClips,
                deletion: deletion,
                defaultTransition: defaultTransitionDuration
            )
            result.zoomClips = restoredZoomReturnsAtRippleJunction(
                original: timeline.zoomClips,
                mapped: result.zoomClips,
                deletion: deletion,
                defaultTransition: defaultTransitionDuration
            )
            result.screenMotionClips = restoredScreenReturnsAtRippleJunction(
                original: timeline.screenMotionClips,
                mapped: result.screenMotionClips,
                deletion: deletion,
                defaultTransition: defaultTransitionDuration
            )
            result.cameraMotionClips = restoredCameraReturnsAtRippleJunction(
                original: timeline.cameraMotionClips,
                mapped: result.cameraMotionClips,
                deletion: deletion,
                defaultTransition: defaultTransitionDuration
            )
            result.zoomClips = normalizedZoomReturnsAfterRipple(
                original: timeline.zoomClips,
                mapped: result.zoomClips,
                defaultReturn: defaultTransitionDuration
            )
            result.screenMotionClips = normalizedScreenReturnsAfterRipple(
                original: timeline.screenMotionClips,
                mapped: result.screenMotionClips,
                defaultReturn: defaultTransitionDuration
            )
            result.cameraMotionClips = normalizedCameraReturnsAfterRipple(
                original: timeline.cameraMotionClips,
                mapped: result.cameraMotionClips,
                defaultReturn: defaultTransitionDuration
            )
        }
        try validate(result, fullSourceDuration: fullSourceDuration)
        return result
    }

    static func inserting(
        _ clip: ZoomAnimationClip,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> ZoomAnimationClip {
        var edited = clip
        if clip.startTime >= insertionTime - epsilon {
            edited.startTime += duration
            edited.endTime += duration
        } else if clip.endTime > insertionTime + epsilon {
            // The restored content lies inside an existing hold interval. Keep
            // the downstream edge attached to the same original material.
            edited.endTime += duration
        }
        return edited
    }

    static func inserting(
        _ clip: ScreenMotionClip,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> ScreenMotionClip {
        var edited = clip
        edited.timing = inserting(
            clip.timing,
            at: insertionTime,
            duration: duration
        )
        return edited
    }

    static func inserting(
        _ clip: CameraMotionClip,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> CameraMotionClip {
        var edited = clip
        edited.timing = inserting(
            clip.timing,
            at: insertionTime,
            duration: duration
        )
        return edited
    }

    static func inserting(
        _ timing: TransitionTiming,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> TransitionTiming {
        var edited = timing
        if timing.startTime >= insertionTime - epsilon {
            edited.startTime += duration
        } else if timing.endTime > insertionTime + epsilon {
            edited.duration += duration
        }
        return edited
    }

    static func ripple(
        _ clip: ZoomAnimationClip,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) throws -> ZoomAnimationClip? {
        if clip.effectEndTime <= deletion.start + epsilon {
            return clip
        }
        if deletesOutputTail {
            return clip.startTime >= deletion.start - epsilon ? nil : clip
        }
        if clip.startTime >= deletion.end - epsilon {
            var shifted = clip
            shifted.startTime -= deletion.duration
            shifted.endTime -= deletion.duration
            return shifted
        }
        if clip.startTime >= deletion.start - epsilon,
           clip.endTime <= deletion.end + epsilon {
            return nil
        }

        let oldEnterEnd = min(clip.startTime + clip.enterDuration, clip.endTime)
        let newStart = deletion.map(clip.startTime)
        let newEnd = deletion.map(clip.endTime)
        let newEnterEnd = deletion.map(oldEnterEnd)
        let newEffectEnd = deletion.map(clip.effectEndTime)
        guard newEnd - newStart > epsilon else { return nil }

        var edited = clip
        edited.startTime = newStart
        edited.endTime = newEnd
        let mappedEnter = max(0, min(newEnterEnd - newStart, newEnd - newStart))
        edited.enterDuration = mappedEnter
        edited.enterProgressOffset = continuedPhaseOffset(
            originalOffset: clip.enterProgressOffset,
            phaseStart: clip.startTime,
            phaseDuration: min(clip.enterDuration, clip.duration),
            deletion: deletion
        )
        let mappedExit = max(0, newEffectEnd - newEnd)
        edited.exitDuration = mappedExit
        edited.exitProgressOffset = continuedPhaseOffset(
            originalOffset: clip.exitProgressOffset,
            phaseStart: clip.endTime,
            phaseDuration: clip.exitDuration,
            deletion: deletion
        )
        return edited
    }

    static func ripple(
        _ clip: ScreenMotionClip,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) throws -> ScreenMotionClip? {
        guard let timing = try ripple(
            clip.timing,
            deleting: deletion,
            deletesOutputTail: deletesOutputTail
        ) else { return nil }
        var edited = clip
        edited.timing = timing
        return edited
    }

    static func ripple(
        _ clip: CameraMotionClip,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) throws -> CameraMotionClip? {
        guard let timing = try ripple(
            clip.timing,
            deleting: deletion,
            deletesOutputTail: deletesOutputTail
        ) else { return nil }
        var edited = clip
        edited.timing = timing
        return edited
    }

    static func ripple(
        _ timing: TransitionTiming,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) throws -> TransitionTiming? {
        if timing.effectEndTime <= deletion.start + epsilon {
            return timing
        }
        // 过渡完全落在删除区间内：与 zoom 轨一致地删除它，而不是抛错
        // 让整个编辑操作失败（同一次左裁剪对两条轨行为不同）。
        if timing.startTime >= deletion.start - epsilon,
           timing.endTime <= deletion.end + epsilon {
            return nil
        }
        if deletesOutputTail {
            return timing.startTime >= deletion.start - epsilon ? nil : timing
        }
        if timing.startTime >= deletion.end - epsilon {
            var shifted = timing
            shifted.startTime -= deletion.duration
            return shifted
        }

        let oldLeadInEnd = timing.leadInEndTime
        let newStart = deletion.map(timing.startTime)
        let newEnd = deletion.map(timing.endTime)
        guard newEnd - newStart > epsilon else { return nil }
        let newLeadInEnd = deletion.map(oldLeadInEnd)
        let newEffectEnd = deletion.map(timing.effectEndTime)

        var edited = timing
        edited.startTime = newStart
        edited.duration = newEnd - newStart
        let mappedLeadIn = max(0, min(newLeadInEnd - newStart, edited.duration))
        edited.leadInDuration = mappedLeadIn
        edited.leadInProgressOffset = continuedPhaseOffset(
            originalOffset: timing.leadInProgressOffset,
            phaseStart: timing.startTime,
            phaseDuration: min(timing.leadInDuration, timing.duration),
            deletion: deletion
        )
        let mappedReturn = max(0, newEffectEnd - newEnd)
        edited.returnDuration = mappedReturn
        edited.returnProgressOffset = continuedPhaseOffset(
            originalOffset: timing.returnProgressOffset,
            phaseStart: timing.endTime,
            phaseDuration: timing.returnDuration,
            deletion: deletion
        )
        return edited
    }

    /// If a phase begins in deleted material but continues after it, the first
    /// retained frame must resume at the progress already reached at the far
    /// side of the cut. Replaying from zero is the visible wait-then-move bug.
    static func continuedPhaseOffset(
        originalOffset: Double,
        phaseStart: TimeInterval,
        phaseDuration: TimeInterval,
        deletion: OutputDeletion
    ) -> Double {
        let safeOffset = min(max(originalOffset, 0), 1)
        guard phaseDuration > epsilon,
              phaseStart >= deletion.start - epsilon,
              phaseStart < deletion.end - epsilon else {
            return safeOffset
        }
        // The frame immediately before the ripple junction is the state at
        // deletion.start, not deletion.end. Catching the phase up to the far
        // side produces a visible jump. Resume from the near-side phase and
        // let the retained transition continue naturally after the cut.
        let elapsed = min(max((deletion.start - phaseStart) / phaseDuration, 0), 1)
        return safeOffset + (1 - safeOffset) * elapsed
    }

    static func restoredZoomLeadInsAtRippleJunction(
        original: [ZoomAnimationClip],
        mapped: [ZoomAnimationClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [ZoomAnimationClip] {
        var result = mapped
        for index in result.indices {
            guard result[index].enterDuration <= epsilon,
                  let old = original.first(where: { $0.id == result[index].id }),
                  old.startTime >= deletion.start - epsilon,
                  old.startTime < deletion.end - epsilon,
                  old.startTime + old.enterDuration <= deletion.end + epsilon,
                  old.endTime > deletion.end + epsilon else { continue }
            result[index].enterDuration = min(
                max(defaultTransition, 0),
                result[index].duration
            )
            result[index].enterProgressOffset = 0
        }
        return result
    }

    static func restoredScreenLeadInsAtRippleJunction(
        original: [ScreenMotionClip],
        mapped: [ScreenMotionClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [ScreenMotionClip] {
        var result = mapped
        for index in result.indices {
            guard result[index].timing.leadInDuration <= epsilon,
                  let old = original.first(where: { $0.id == result[index].id }),
                  old.timing.startTime >= deletion.start - epsilon,
                  old.timing.startTime < deletion.end - epsilon,
                  old.timing.leadInEndTime <= deletion.end + epsilon,
                  old.timing.endTime > deletion.end + epsilon else { continue }
            result[index].timing.leadInDuration = min(
                max(defaultTransition, 0),
                result[index].timing.duration
            )
            result[index].timing.leadInProgressOffset = 0
        }
        return result
    }

    static func restoredCameraLeadInsAtRippleJunction(
        original: [CameraMotionClip],
        mapped: [CameraMotionClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [CameraMotionClip] {
        var result = mapped
        for index in result.indices {
            guard result[index].timing.leadInDuration <= epsilon,
                  let old = original.first(where: { $0.id == result[index].id }),
                  old.timing.startTime >= deletion.start - epsilon,
                  old.timing.startTime < deletion.end - epsilon,
                  old.timing.leadInEndTime <= deletion.end + epsilon,
                  old.timing.endTime > deletion.end + epsilon else { continue }
            result[index].timing.leadInDuration = min(
                max(defaultTransition, 0),
                result[index].timing.duration
            )
            result[index].timing.leadInProgressOffset = 0
        }
        return result
    }

    static func restoredZoomReturnsAtRippleJunction(
        original: [ZoomAnimationClip],
        mapped: [ZoomAnimationClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [ZoomAnimationClip] {
        var result = mapped.sorted(by: zoomOrder)
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }),
                  old.exitDuration > epsilon else { continue }
            let touchesNext = result.indices.contains(index + 1)
                && abs(result[index + 1].startTime - result[index].endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            let available = result.indices.contains(index + 1)
                ? max(result[index + 1].startTime - result[index].endTime, 0)
                : old.exitDuration

            // The return had already started before the deleted range, but its
            // remaining part lived inside that range. Mapping effectEnd to the
            // near-side junction truncates the duration to elapsed time and
            // makes the junction itself jump straight to base. Restore the
            // original phase clock so the first retained frame continues from
            // exactly the pre-cut state at the same velocity.
            let deletionConsumesReturnTail = old.endTime < deletion.start - epsilon
                && old.effectEndTime > deletion.start + epsilon
                && old.effectEndTime <= deletion.end + epsilon
            if deletionConsumesReturnTail,
               !touchesNext,
               result[index].exitDuration < old.exitDuration - epsilon {
                result[index].exitDuration = min(old.exitDuration, available)
                result[index].exitProgressOffset = old.exitProgressOffset
                continue
            }

            guard result[index].exitDuration <= epsilon,
                  old.endTime > deletion.start + epsilon,
                  old.endTime <= deletion.end + epsilon,
                  old.effectEndTime <= deletion.end + epsilon else { continue }
            guard !touchesNext else { continue }
            let restoredAvailable = result.indices.contains(index + 1)
                ? available
                : max(defaultTransition, 0)
            result[index].exitDuration = min(max(defaultTransition, 0), restoredAvailable)
            result[index].exitProgressOffset = 0
        }
        return result
    }

    static func restoredScreenReturnsAtRippleJunction(
        original: [ScreenMotionClip],
        mapped: [ScreenMotionClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [ScreenMotionClip] {
        var result = mapped.sorted(by: screenMotionOrder)
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }),
                  old.timing.returnDuration > epsilon else { continue }
            let touchesNext = result.indices.contains(index + 1)
                && abs(result[index + 1].timing.startTime - result[index].timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            let available = result.indices.contains(index + 1)
                ? max(
                    result[index + 1].timing.startTime - result[index].timing.endTime,
                    0
                )
                : old.timing.returnDuration
            let deletionConsumesReturnTail = old.timing.endTime < deletion.start - epsilon
                && old.timing.effectEndTime > deletion.start + epsilon
                && old.timing.effectEndTime <= deletion.end + epsilon
            if deletionConsumesReturnTail,
               !touchesNext,
               result[index].timing.returnDuration
                    < old.timing.returnDuration - epsilon {
                result[index].timing.returnDuration = min(
                    old.timing.returnDuration,
                    available
                )
                result[index].timing.returnProgressOffset =
                    old.timing.returnProgressOffset
                continue
            }

            guard result[index].timing.returnDuration <= epsilon,
                  old.timing.endTime > deletion.start + epsilon,
                  old.timing.endTime <= deletion.end + epsilon,
                  old.timing.effectEndTime <= deletion.end + epsilon else { continue }
            guard !touchesNext else { continue }
            let restoredAvailable = result.indices.contains(index + 1)
                ? available
                : max(defaultTransition, 0)
            result[index].timing.returnDuration = min(
                max(defaultTransition, 0),
                restoredAvailable
            )
            result[index].timing.returnProgressOffset = 0
        }
        return result
    }

    static func restoredCameraReturnsAtRippleJunction(
        original: [CameraMotionClip],
        mapped: [CameraMotionClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [CameraMotionClip] {
        var result = mapped.sorted(by: cameraMotionOrder)
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }),
                  old.timing.returnDuration > epsilon else { continue }
            let touchesNext = result.indices.contains(index + 1)
                && abs(result[index + 1].timing.startTime - result[index].timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            let available = result.indices.contains(index + 1)
                ? max(
                    result[index + 1].timing.startTime - result[index].timing.endTime,
                    0
                )
                : old.timing.returnDuration
            let deletionConsumesReturnTail = old.timing.endTime < deletion.start - epsilon
                && old.timing.effectEndTime > deletion.start + epsilon
                && old.timing.effectEndTime <= deletion.end + epsilon
            if deletionConsumesReturnTail,
               !touchesNext,
               result[index].timing.returnDuration
                    < old.timing.returnDuration - epsilon {
                result[index].timing.returnDuration = min(
                    old.timing.returnDuration,
                    available
                )
                result[index].timing.returnProgressOffset =
                    old.timing.returnProgressOffset
                continue
            }

            guard result[index].timing.returnDuration <= epsilon,
                  old.timing.endTime > deletion.start + epsilon,
                  old.timing.endTime <= deletion.end + epsilon,
                  old.timing.effectEndTime <= deletion.end + epsilon else { continue }
            guard !touchesNext else { continue }
            let restoredAvailable = result.indices.contains(index + 1)
                ? available
                : max(defaultTransition, 0)
            result[index].timing.returnDuration = min(
                max(defaultTransition, 0),
                restoredAvailable
            )
            result[index].timing.returnProgressOffset = 0
        }
        return result
    }

    /// EDT-001/EDT-002: deleting content can remove the successor that previously kept a zero-
    /// return clip alive. Once that clip becomes a true endpoint, restore the
    /// project default return. Existing intentional persistent endpoints stay
    /// unchanged; only a relationship broken by this ripple is repaired.
    static func normalizedZoomReturnsAfterRipple(
        original: [ZoomAnimationClip],
        mapped: [ZoomAnimationClip],
        defaultReturn: TimeInterval
    ) -> [ZoomAnimationClip] {
        let old = original.sorted(by: zoomOrder)
        var result = mapped.sorted(by: zoomOrder)
        for index in result.indices {
            guard let oldIndex = old.firstIndex(where: { $0.id == result[index].id }) else {
                continue
            }
            let touchedOldSuccessor = old.indices.contains(oldIndex + 1)
                && abs(old[oldIndex + 1].startTime - old[oldIndex].endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            let touchesNewSuccessor = result.indices.contains(index + 1)
                && abs(result[index + 1].startTime - result[index].endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            let available = result.indices.contains(index + 1)
                ? max(result[index + 1].startTime - result[index].endTime, 0)
                : max(defaultReturn, 0)
            if result[index].exitDuration <= epsilon,
               touchedOldSuccessor,
               !touchesNewSuccessor {
                result[index].exitDuration = min(max(defaultReturn, 0), available)
                result[index].exitProgressOffset = 0
            } else if !touchesNewSuccessor, result.indices.contains(index + 1) {
                result[index].exitDuration = min(result[index].exitDuration, available)
            }
        }
        return result
    }

    static func normalizedScreenReturnsAfterRipple(
        original: [ScreenMotionClip],
        mapped: [ScreenMotionClip],
        defaultReturn: TimeInterval
    ) -> [ScreenMotionClip] {
        let old = original.sorted(by: screenMotionOrder)
        var result = mapped.sorted(by: screenMotionOrder)
        normalizeTransitionReturns(
            oldIDs: old.map(\.id),
            oldStarts: old.map { $0.timing.startTime },
            oldEnds: old.map { $0.timing.endTime },
            mappedIDs: result.map(\.id),
            starts: result.map { $0.timing.startTime },
            ends: result.map { $0.timing.endTime },
            returns: &result,
            defaultReturn: defaultReturn,
            getReturn: { $0.timing.returnDuration },
            setReturn: { $0.timing.returnDuration = $1 },
            resetReturnProgress: { $0.timing.returnProgressOffset = 0 }
        )
        return result
    }

    static func normalizedCameraReturnsAfterRipple(
        original: [CameraMotionClip],
        mapped: [CameraMotionClip],
        defaultReturn: TimeInterval
    ) -> [CameraMotionClip] {
        let old = original.sorted(by: cameraMotionOrder)
        var result = mapped.sorted(by: cameraMotionOrder)
        normalizeTransitionReturns(
            oldIDs: old.map(\.id),
            oldStarts: old.map { $0.timing.startTime },
            oldEnds: old.map { $0.timing.endTime },
            mappedIDs: result.map(\.id),
            starts: result.map { $0.timing.startTime },
            ends: result.map { $0.timing.endTime },
            returns: &result,
            defaultReturn: defaultReturn,
            getReturn: { $0.timing.returnDuration },
            setReturn: { $0.timing.returnDuration = $1 },
            resetReturnProgress: { $0.timing.returnProgressOffset = 0 }
        )
        return result
    }

    static func normalizeTransitionReturns<Clip>(
        oldIDs: [UUID],
        oldStarts: [TimeInterval],
        oldEnds: [TimeInterval],
        mappedIDs: [UUID],
        starts: [TimeInterval],
        ends: [TimeInterval],
        returns: inout [Clip],
        defaultReturn: TimeInterval,
        getReturn: (Clip) -> TimeInterval,
        setReturn: (inout Clip, TimeInterval) -> Void,
        resetReturnProgress: (inout Clip) -> Void
    ) {
        for index in returns.indices {
            guard let oldIndex = oldIDs.firstIndex(of: mappedIDs[index]) else { continue }
            let touchedOldSuccessor = oldIDs.indices.contains(oldIndex + 1)
                && abs(oldStarts[oldIndex + 1] - oldEnds[oldIndex])
                    <= ZoomInterpolator.adjacencyTolerance
            let touchesNewSuccessor = returns.indices.contains(index + 1)
                && abs(starts[index + 1] - ends[index])
                    <= ZoomInterpolator.adjacencyTolerance
            let available = returns.indices.contains(index + 1)
                ? max(starts[index + 1] - ends[index], 0)
                : max(defaultReturn, 0)
            if getReturn(returns[index]) <= epsilon,
               touchedOldSuccessor,
               !touchesNewSuccessor {
                setReturn(&returns[index], min(max(defaultReturn, 0), available))
                resetReturnProgress(&returns[index])
            } else if !touchesNewSuccessor, returns.indices.contains(index + 1) {
                setReturn(&returns[index], min(getReturn(returns[index]), available))
            }
        }
    }

    static func reorderedOutputOffset(
        at oldOutputTime: TimeInterval,
        oldMap: TimelineMap,
        newStarts: [UUID: TimeInterval]
    ) -> TimeInterval {
        let probe = min(
            max(oldOutputTime, 0),
            max(oldMap.outputDuration - epsilon, 0)
        )
        guard let owner = oldMap.segment(atOutputTime: probe),
              let newStart = newStarts[owner.id] else { return 0 }
        return newStart - owner.outputStart
    }

    static func remappedZoomClips(
        _ clips: [ZoomAnimationClip],
        oldMap: TimelineMap,
        newStarts: [UUID: TimeInterval],
        outputDuration: TimeInterval
    ) -> [ZoomAnimationClip] {
        var translated = clips.compactMap { clip -> ZoomAnimationClip? in
            let delta = reorderedOutputOffset(
                at: clip.startTime,
                oldMap: oldMap,
                newStarts: newStarts
            )
            var moved = clip
            moved.startTime = min(max(clip.startTime + delta, 0), outputDuration)
            moved.endTime = min(max(clip.endTime + delta, moved.startTime), outputDuration)
            moved.enterDuration = min(moved.enterDuration, moved.duration)
            moved.exitDuration = min(
                moved.exitDuration,
                max(outputDuration - moved.endTime, 0)
            )
            return moved.duration > epsilon ? moved : nil
        }
        sortZoom(&translated)

        var normalized: [ZoomAnimationClip] = []
        for clip in translated {
            if var previous = normalized.popLast() {
                if previous.endTime > clip.startTime {
                    previous.endTime = max(clip.startTime, previous.startTime)
                    previous.enterDuration = min(previous.enterDuration, previous.duration)
                }
                if previous.duration > epsilon {
                    let gap = max(clip.startTime - previous.endTime, 0)
                    if gap > ZoomInterpolator.adjacencyTolerance {
                        previous.exitDuration = min(previous.exitDuration, gap)
                    }
                    normalized.append(previous)
                }
            }
            normalized.append(clip)
        }
        return normalized
    }

    static func remappedScreenMotionClips(
        _ clips: [ScreenMotionClip],
        oldMap: TimelineMap,
        newStarts: [UUID: TimeInterval],
        outputDuration: TimeInterval
    ) -> [ScreenMotionClip] {
        var translated = clips.compactMap { clip -> ScreenMotionClip? in
            let delta = reorderedOutputOffset(
                at: clip.timing.startTime,
                oldMap: oldMap,
                newStarts: newStarts
            )
            var moved = clip
            moved.timing.startTime = min(
                max(clip.timing.startTime + delta, 0),
                outputDuration
            )
            moved.timing.duration = min(
                clip.timing.duration,
                max(outputDuration - moved.timing.startTime, 0)
            )
            moved.timing.leadInDuration = min(
                moved.timing.leadInDuration,
                moved.timing.duration
            )
            moved.timing.returnDuration = min(
                moved.timing.returnDuration,
                max(outputDuration - moved.timing.endTime, 0)
            )
            return moved.timing.duration > epsilon ? moved : nil
        }
        sortScreenMotion(&translated)
        return normalizedScreenMotionSequence(translated)
    }

    static func remappedCameraMotionClips(
        _ clips: [CameraMotionClip],
        oldMap: TimelineMap,
        newStarts: [UUID: TimeInterval],
        outputDuration: TimeInterval
    ) -> [CameraMotionClip] {
        var translated = clips.compactMap { clip -> CameraMotionClip? in
            let delta = reorderedOutputOffset(
                at: clip.timing.startTime,
                oldMap: oldMap,
                newStarts: newStarts
            )
            var moved = clip
            moved.timing.startTime = min(
                max(clip.timing.startTime + delta, 0),
                outputDuration
            )
            moved.timing.duration = min(
                clip.timing.duration,
                max(outputDuration - moved.timing.startTime, 0)
            )
            moved.timing.leadInDuration = min(
                moved.timing.leadInDuration,
                moved.timing.duration
            )
            moved.timing.returnDuration = min(
                moved.timing.returnDuration,
                max(outputDuration - moved.timing.endTime, 0)
            )
            return moved.timing.duration > epsilon ? moved : nil
        }
        sortCameraMotion(&translated)
        return normalizedCameraMotionSequence(translated)
    }

    static func normalizedScreenMotionSequence(
        _ clips: [ScreenMotionClip]
    ) -> [ScreenMotionClip] {
        var normalized: [ScreenMotionClip] = []
        for clip in clips {
            if var previous = normalized.popLast() {
                if previous.timing.endTime > clip.timing.startTime {
                    previous.timing.duration = max(
                        clip.timing.startTime - previous.timing.startTime,
                        0
                    )
                    previous.timing.leadInDuration = min(
                        previous.timing.leadInDuration,
                        previous.timing.duration
                    )
                }
                if previous.timing.duration > epsilon {
                    let gap = max(clip.timing.startTime - previous.timing.endTime, 0)
                    if gap > ZoomInterpolator.adjacencyTolerance {
                        previous.timing.returnDuration = min(
                            previous.timing.returnDuration,
                            gap
                        )
                    }
                    normalized.append(previous)
                }
            }
            normalized.append(clip)
        }
        return normalized
    }

    static func normalizedCameraMotionSequence(
        _ clips: [CameraMotionClip]
    ) -> [CameraMotionClip] {
        var normalized: [CameraMotionClip] = []
        for clip in clips {
            if var previous = normalized.popLast() {
                if previous.timing.endTime > clip.timing.startTime {
                    previous.timing.duration = max(
                        clip.timing.startTime - previous.timing.startTime,
                        0
                    )
                    previous.timing.leadInDuration = min(
                        previous.timing.leadInDuration,
                        previous.timing.duration
                    )
                }
                if previous.timing.duration > epsilon {
                    let gap = max(clip.timing.startTime - previous.timing.endTime, 0)
                    if gap > ZoomInterpolator.adjacencyTolerance {
                        previous.timing.returnDuration = min(
                            previous.timing.returnDuration,
                            gap
                        )
                    }
                    normalized.append(previous)
                }
            }
            normalized.append(clip)
        }
        return normalized
    }

    static func validateSourceSequence(_ sequence: SourceSequence) throws {
        guard case let .edited(segments) = sequence else { return }
        guard !segments.isEmpty else {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
        var identifiers = Set<UUID>()
        for segment in segments {
            guard identifiers.insert(segment.id).inserted else {
                throw ProjectTimelineEditingError.duplicateSegmentID(segment.id)
            }
            guard segment.sourceStart.isFinite,
                  segment.sourceDuration.isFinite,
                  segment.sourceStart >= 0,
                  segment.sourceDuration > 0,
                  segment.sourceEnd.isFinite else {
                throw ProjectTimelineEditingError.invalidSourceSequence
            }
        }
        let sourceOrdered = segments.sorted {
            if $0.sourceStart != $1.sourceStart { return $0.sourceStart < $1.sourceStart }
            return $0.id.uuidString < $1.id.uuidString
        }
        for (previous, current) in zip(sourceOrdered, sourceOrdered.dropFirst())
            where current.sourceStart < previous.sourceEnd - epsilon {
            throw ProjectTimelineEditingError.invalidSourceSequence
        }
    }

    static func validateZoomClips(_ clips: [ZoomAnimationClip]) throws {
        var identifiers = Set<UUID>()
        var previous: ZoomAnimationClip?
        for clip in clips.sorted(by: zoomOrder) {
            guard identifiers.insert(clip.id).inserted else {
                throw ProjectTimelineEditingError.duplicateClipID(track: .zoom, id: clip.id)
            }
            guard clip.startTime.isFinite,
                  clip.endTime.isFinite,
                  clip.startTime >= 0,
                  clip.endTime >= clip.startTime,
                  clip.scale.isFinite,
                  clip.scale >= 1,
                  normalized(clip.focus),
                  clip.enterDuration.isFinite,
                  clip.exitDuration.isFinite,
                  clip.enterProgressOffset.isFinite,
                  clip.exitProgressOffset.isFinite,
                  (0...5).contains(clip.enterDuration),
                  (0...5).contains(clip.exitDuration),
                  (0...1).contains(clip.enterProgressOffset),
                  (0...1).contains(clip.exitProgressOffset),
                  valid(clip.customCurve) else {
                throw ProjectTimelineEditingError.invalidClip(track: .zoom, id: clip.id)
            }
            if let previous, !EditorTimelineMath.zoomSequenceIsValid(
                previous: previous,
                next: clip
            ) {
                throw ProjectTimelineEditingError.overlappingClips(
                    track: .zoom,
                    first: previous.id,
                    second: clip.id
                )
            }
            previous = clip
        }
    }

    static func validateScreenMotionClips(_ clips: [ScreenMotionClip]) throws {
        var identifiers = Set<UUID>()
        var previous: ScreenMotionClip?
        for clip in clips.sorted(by: screenMotionOrder) {
            guard identifiers.insert(clip.id).inserted else {
                throw ProjectTimelineEditingError.duplicateClipID(track: .screenMotion, id: clip.id)
            }
            let target = clip.target
            guard valid(clip.timing),
                  normalized(target.position),
                  target.scale.isFinite,
                  target.scale > 0,
                  target.rotationX.isFinite,
                  target.rotationY.isFinite,
                  target.rotationZ.isFinite,
                  target.perspective.isFinite,
                  target.perspective >= 0 else {
                throw ProjectTimelineEditingError.invalidClip(track: .screenMotion, id: clip.id)
            }
            if let previous {
                let gap = clip.timing.startTime - previous.timing.endTime
                let touches = gap <= ZoomInterpolator.adjacencyTolerance
                let clears = clip.timing.startTime
                    >= previous.timing.effectEndTime - epsilon
                guard clip.timing.startTime >= previous.timing.endTime - epsilon,
                      touches || clears else {
                    throw ProjectTimelineEditingError.overlappingClips(
                        track: .screenMotion,
                        first: previous.id,
                        second: clip.id
                    )
                }
            }
            previous = clip
        }
    }

    static func validateCameraMotionClips(_ clips: [CameraMotionClip]) throws {
        var identifiers = Set<UUID>()
        var previous: CameraMotionClip?
        for clip in clips.sorted(by: cameraMotionOrder) {
            guard identifiers.insert(clip.id).inserted else {
                throw ProjectTimelineEditingError.duplicateClipID(track: .cameraMotion, id: clip.id)
            }
            let target = clip.target
            guard valid(clip.timing),
                  normalized(target.position),
                  target.size.isFinite,
                  target.size > 0,
                  target.roundness.isFinite,
                  (0...1).contains(target.roundness),
                  target.opacity.isFinite,
                  (0...1).contains(target.opacity) else {
                throw ProjectTimelineEditingError.invalidClip(track: .cameraMotion, id: clip.id)
            }
            if let previous {
                let gap = clip.timing.startTime - previous.timing.endTime
                let touches = gap <= ZoomInterpolator.adjacencyTolerance
                let clears = clip.timing.startTime
                    >= previous.timing.effectEndTime - epsilon
                guard clip.timing.startTime >= previous.timing.endTime - epsilon,
                      touches || clears else {
                    throw ProjectTimelineEditingError.overlappingClips(
                        track: .cameraMotion,
                        first: previous.id,
                        second: clip.id
                    )
                }
            }
            previous = clip
        }
    }

    static func valid(_ timing: TransitionTiming) -> Bool {
        timing.startTime.isFinite
            && timing.startTime >= 0
            && timing.duration.isFinite
            && timing.duration > 0
            && timing.endTime.isFinite
            && timing.leadInProgressOffset.isFinite
            && timing.returnProgressOffset.isFinite
            && (0...1).contains(timing.leadInProgressOffset)
            && (0...1).contains(timing.returnProgressOffset)
            && valid(timing.customCurve)
    }

    static func valid(_ curve: ZoomBezierCurve) -> Bool {
        curve.x1.isFinite
            && curve.y1.isFinite
            && curve.x2.isFinite
            && curve.y2.isFinite
    }

    static func normalized(_ point: NormalizedPoint) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && (0...1).contains(point.x)
            && (0...1).contains(point.y)
    }

    static func authoredSegment(_ segment: ResolvedRecordingSegment) -> RecordingSegment {
        RecordingSegment(
            id: segment.id,
            sourceStart: segment.sourceStart,
            sourceDuration: segment.sourceDuration
        )
    }

    static func sortZoom(_ clips: inout [ZoomAnimationClip]) {
        clips.sort(by: zoomOrder)
    }

    static func sortScreenMotion(_ clips: inout [ScreenMotionClip]) {
        clips.sort(by: screenMotionOrder)
    }

    static func sortCameraMotion(_ clips: inout [CameraMotionClip]) {
        clips.sort(by: cameraMotionOrder)
    }

    static func zoomOrder(_ lhs: ZoomAnimationClip, _ rhs: ZoomAnimationClip) -> Bool {
        lhs.startTime == rhs.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.startTime < rhs.startTime
    }

    static func screenMotionOrder(_ lhs: ScreenMotionClip, _ rhs: ScreenMotionClip) -> Bool {
        lhs.timing.startTime == rhs.timing.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.timing.startTime < rhs.timing.startTime
    }

    static func cameraMotionOrder(_ lhs: CameraMotionClip, _ rhs: CameraMotionClip) -> Bool {
        lhs.timing.startTime == rhs.timing.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.timing.startTime < rhs.timing.startTime
    }
}

struct OutputDeletion {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { end - start }

    func map(_ time: TimeInterval) -> TimeInterval {
        if time <= start { return time }
        if time >= end { return time - duration }
        return start
    }

    func overlapDuration(start otherStart: TimeInterval, end otherEnd: TimeInterval) -> TimeInterval {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }
}
