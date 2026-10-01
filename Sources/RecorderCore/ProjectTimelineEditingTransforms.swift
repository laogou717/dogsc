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
        result.primarySegmentAudioOverrides = prunedPrimarySegmentAudioOverrides(
            timeline.primarySegmentAudioOverrides,
            sourceSequence: sourceSequence
        )
        result.zoomClips = try timeline.zoomClips.compactMap {
            try ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        result.screenMotionClips = try timeline.screenMotionClips.compactMap {
            try ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        result.cameraMotionClips = try timeline.cameraMotionClips.compactMap {
            try ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        result.mosaicClips = timeline.mosaicClips.compactMap {
            ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        result.stickerClips = timeline.stickerClips.compactMap {
            ripple($0, deleting: deletion, deletesOutputTail: deletesOutputTail)
        }
        sortZoom(&result.zoomClips)
        sortScreenMotion(&result.screenMotionClips)
        sortCameraMotion(&result.cameraMotionClips)
        if !deletesOutputTail {
            result.zoomClips = restoredZoomLeadInsAtRippleJunction(
                original: timeline.zoomClips,
                mapped: result.zoomClips,
                deletion: deletion
            )
            result.screenMotionClips = restoredScreenLeadInsAtRippleJunction(
                original: timeline.screenMotionClips,
                mapped: result.screenMotionClips,
                deletion: deletion
            )
            result.cameraMotionClips = restoredCameraLeadInsAtRippleJunction(
                original: timeline.cameraMotionClips,
                mapped: result.cameraMotionClips,
                deletion: deletion
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
            // Return restoration already resolves adjacency and available
            // space. Do not run a second default-duration pass: it would
            // overwrite explicitly authored zero returns after a successor cut.
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

    static func inserting(
        _ timing: OverlayTiming,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> OverlayTiming {
        var edited = timing
        if timing.startTime >= insertionTime - epsilon {
            edited.startTime += duration
        } else if timing.endTime > insertionTime + epsilon {
            edited.duration += duration
        }
        return edited
    }

    static func inserting(
        _ clip: MosaicClip,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> MosaicClip {
        var edited = clip
        edited.timing = inserting(clip.timing, at: insertionTime, duration: duration)
        return edited
    }

    static func inserting(
        _ clip: StickerClip,
        at insertionTime: TimeInterval,
        duration: TimeInterval
    ) -> StickerClip {
        var edited = clip
        edited.timing = inserting(clip.timing, at: insertionTime, duration: duration)
        return edited
    }

    static func ripple(
        _ timing: OverlayTiming,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) -> OverlayTiming? {
        if timing.endTime <= deletion.start + epsilon { return timing }
        if deletesOutputTail {
            guard timing.startTime < deletion.start - epsilon else { return nil }
            return OverlayTiming(
                startTime: timing.startTime,
                duration: max(deletion.start - timing.startTime, 0)
            )
        }
        if timing.startTime >= deletion.end - epsilon {
            return OverlayTiming(
                startTime: timing.startTime - deletion.duration,
                duration: timing.duration
            )
        }
        if timing.startTime >= deletion.start - epsilon,
           timing.endTime <= deletion.end + epsilon {
            return nil
        }
        let start = deletion.map(timing.startTime)
        let end = deletion.map(timing.endTime)
        guard end - start > epsilon else { return nil }
        return OverlayTiming(startTime: start, duration: end - start)
    }

    static func ripple(
        _ clip: MosaicClip,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) -> MosaicClip? {
        guard let timing = ripple(
            clip.timing,
            deleting: deletion,
            deletesOutputTail: deletesOutputTail
        ) else { return nil }
        var edited = clip
        edited.timing = timing
        return edited
    }

    static func ripple(
        _ clip: StickerClip,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) -> StickerClip? {
        guard let timing = ripple(
            clip.timing,
            deleting: deletion,
            deletesOutputTail: deletesOutputTail
        ) else { return nil }
        var edited = clip
        edited.timing = timing
        // Keep the authored entry/exit ratio. FrameScene fits both windows to
        // a short clip together; editing media must not overwrite that intent.
        return edited
    }

    static func ripple(
        _ clip: ZoomAnimationClip,
        deleting deletion: OutputDeletion,
        deletesOutputTail: Bool
    ) throws -> ZoomAnimationClip? {
        var clip = clip
        clip.preserveTransitionIntent()
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
        var timing = timing
        timing.preserveTransitionIntent()
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

    /// Preserve the near-side phase at the edit junction. A phase whose start
    /// was deleted is restored as a new entrance/return by the helpers below.
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
        deletion: OutputDeletion
    ) -> [ZoomAnimationClip] {
        var result = mapped
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }),
                  let entry = restoredEntryAfterRipple(
                    startTime: old.startTime,
                    entryDuration: min(old.enterDuration, old.duration),
                    requestedDuration: old.requestedEnterDuration,
                    progressOffset: old.enterProgressOffset,
                    retainedDuration: result[index].duration,
                    deletion: deletion
                  ) else { continue }
            result[index].enterDuration = entry.duration
            result[index].enterProgressOffset = entry.progressOffset
        }
        return result
    }

    static func restoredScreenLeadInsAtRippleJunction(
        original: [ScreenMotionClip],
        mapped: [ScreenMotionClip],
        deletion: OutputDeletion
    ) -> [ScreenMotionClip] {
        var result = mapped
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }) else { continue }
            result[index].timing = restoringEntryAfterRipple(
                original: old.timing, mapped: result[index].timing, deletion: deletion
            )
        }
        return result
    }

    static func restoredCameraLeadInsAtRippleJunction(
        original: [CameraMotionClip],
        mapped: [CameraMotionClip],
        deletion: OutputDeletion
    ) -> [CameraMotionClip] {
        var result = mapped
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }) else { continue }
            result[index].timing = restoringEntryAfterRipple(
                original: old.timing, mapped: result[index].timing, deletion: deletion
            )
        }
        return result
    }

    static func restoringEntryAfterRipple(
        original: TransitionTiming,
        mapped: TransitionTiming,
        deletion: OutputDeletion
    ) -> TransitionTiming {
        guard let entry = restoredEntryAfterRipple(
            startTime: original.startTime,
            entryDuration: min(original.leadInDuration, original.duration),
            requestedDuration: original.requestedLeadInDuration,
            progressOffset: original.leadInProgressOffset,
            retainedDuration: mapped.duration,
            deletion: deletion
        ) else { return mapped }
        var result = mapped
        result.leadInDuration = entry.duration
        result.leadInProgressOffset = entry.progressOffset
        return result
    }

    /// Zoom, screen 3D and camera motion use the same edit rule: restore an
    /// intersected entrance even if a few frames survived the cut. Preserve
    /// the authored speed and a retained start's phase; a deleted start makes
    /// a fresh entrance from the preceding target. Explicit zero stays zero.
    static func restoredEntryAfterRipple(
        startTime: TimeInterval,
        entryDuration: TimeInterval,
        requestedDuration: TimeInterval,
        progressOffset: Double,
        retainedDuration: TimeInterval,
        deletion: OutputDeletion
    ) -> (duration: TimeInterval, progressOffset: Double)? {
        guard entryDuration > epsilon,
              startTime < deletion.end - epsilon,
              startTime + entryDuration > deletion.start + epsilon else { return nil }
        return (
            min(requestedDuration, retainedDuration),
            startTime >= deletion.start - epsilon ? 0 : progressOffset
        )
    }

    static func restoredZoomReturnsAtRippleJunction(
        original: [ZoomAnimationClip],
        mapped: [ZoomAnimationClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [ZoomAnimationClip] {
        var result = mapped.sorted(by: zoomOrder)
        for index in result.indices {
            guard let old = original.first(where: { $0.id == result[index].id }) else { continue }
            let requested = old.requestedExitDuration(defaultTransition: defaultTransition)
            let next = result.indices.contains(index + 1) ? result[index + 1] : nil
            let gap = next.map { max($0.startTime - result[index].endTime, 0) }
            let touchesNext = gap.map { $0 <= ZoomInterpolator.adjacencyTolerance } ?? false
            result[index].preferredExitDuration = requested
            if touchesNext { continue }
            result[index].exitDuration = min(requested, gap ?? requested)
            // Deleting the middle of an outgoing transition must not speed up
            // its original phase clock. A removed return start gets a fresh
            // return at the new junction, from the still-zoomed near side.
            result[index].exitProgressOffset = old.endTime >= deletion.start - epsilon
                && old.endTime < deletion.end - epsilon ? 0 : old.exitProgressOffset
            if old.exitDuration <= epsilon { result[index].exitProgressOffset = 0 }
        }
        return result
    }

    static func restoredScreenReturnsAtRippleJunction(
        original: [ScreenMotionClip],
        mapped: [ScreenMotionClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [ScreenMotionClip] {
        let originals = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldOrdered = original.sorted(by: screenMotionOrder)
        var result = mapped.sorted(by: screenMotionOrder)
        for index in result.indices {
            guard let old = originals[result[index].id] else { continue }
            // Legacy zero-return clips intentionally hold their target. Only
            // revive one when this edit breaks its former adjacent successor.
            let oldIndex = oldOrdered.firstIndex { $0.id == old.id }!
            let touchedOldSuccessor = oldOrdered.indices.contains(oldIndex + 1)
                && abs(oldOrdered[oldIndex + 1].timing.startTime - old.timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            if old.timing.returnDuration <= epsilon,
               old.timing.preferredReturnDuration == nil, !touchedOldSuccessor {
                result[index].timing.preferredReturnDuration = 0
                continue
            }
            let requested = old.timing.requestedReturnDuration(defaultTransition: defaultTransition)
            result[index].timing.preferredReturnDuration = requested
            let gap: TimeInterval? = result.indices.contains(index + 1)
                ? max(result[index + 1].timing.startTime - result[index].timing.endTime, 0)
                : nil
            if let gap, gap <= ZoomInterpolator.adjacencyTolerance { continue }
            result[index].timing.returnDuration = min(requested, gap ?? requested)
            result[index].timing.returnProgressOffset = old.timing.endTime >= deletion.start - epsilon
                && old.timing.endTime < deletion.end - epsilon ? 0 : old.timing.returnProgressOffset
            if old.timing.returnDuration <= epsilon { result[index].timing.returnProgressOffset = 0 }
        }
        return result
    }

    static func restoredCameraReturnsAtRippleJunction(
        original: [CameraMotionClip],
        mapped: [CameraMotionClip],
        deletion: OutputDeletion,
        defaultTransition: TimeInterval
    ) -> [CameraMotionClip] {
        let originals = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldOrdered = original.sorted(by: cameraMotionOrder)
        var result = mapped.sorted(by: cameraMotionOrder)
        for index in result.indices {
            guard let old = originals[result[index].id] else { continue }
            // Legacy zero-return clips intentionally hold their target. Only
            // revive one when this edit breaks its former adjacent successor.
            let oldIndex = oldOrdered.firstIndex { $0.id == old.id }!
            let touchedOldSuccessor = oldOrdered.indices.contains(oldIndex + 1)
                && abs(oldOrdered[oldIndex + 1].timing.startTime - old.timing.endTime)
                    <= ZoomInterpolator.adjacencyTolerance
            if old.timing.returnDuration <= epsilon,
               old.timing.preferredReturnDuration == nil, !touchedOldSuccessor {
                result[index].timing.preferredReturnDuration = 0
                continue
            }
            let requested = old.timing.requestedReturnDuration(defaultTransition: defaultTransition)
            result[index].timing.preferredReturnDuration = requested
            let gap: TimeInterval? = result.indices.contains(index + 1)
                ? max(result[index + 1].timing.startTime - result[index].timing.endTime, 0)
                : nil
            if let gap, gap <= ZoomInterpolator.adjacencyTolerance { continue }
            result[index].timing.returnDuration = min(requested, gap ?? requested)
            result[index].timing.returnProgressOffset = old.timing.endTime >= deletion.start - epsilon
                && old.timing.endTime < deletion.end - epsilon ? 0 : old.timing.returnProgressOffset
            if old.timing.returnDuration <= epsilon { result[index].timing.returnProgressOffset = 0 }
        }
        return result
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
            moved.preserveTransitionIntent()
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

    static func remappedMosaicClips(
        _ clips: [MosaicClip],
        oldMap: TimelineMap,
        newStarts: [UUID: TimeInterval],
        outputDuration: TimeInterval
    ) -> [MosaicClip] {
        clips.compactMap { clip in
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
            return moved.timing.duration > epsilon ? moved : nil
        }.sorted {
            $0.timing.startTime == $1.timing.startTime
                ? $0.id.uuidString < $1.id.uuidString
                : $0.timing.startTime < $1.timing.startTime
        }
    }

    static func remappedStickerClips(
        _ clips: [StickerClip],
        oldMap: TimelineMap,
        newStarts: [UUID: TimeInterval],
        outputDuration: TimeInterval
    ) -> [StickerClip] {
        clips.compactMap { clip in
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
            // As with ripple cuts, only fit the playback windows in FrameScene.
            return moved.timing.duration > epsilon ? moved : nil
        }.sorted {
            if $0.layerIndex != $1.layerIndex { return $0.layerIndex < $1.layerIndex }
            return $0.id.uuidString < $1.id.uuidString
        }
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
                  segment.playbackRate.isFinite,
                  segment.sourceStart >= 0,
                  segment.sourceDuration > 0,
                  segment.playbackRate > 0,
                  segment.sourceEnd.isFinite else {
                throw ProjectTimelineEditingError.invalidSourceSequence
            }
        }
        for current in segments {
            if segments.contains(where: {
                $0.id != current.id
                    && current.sourceStart < $0.sourceEnd - epsilon
                    && current.sourceEnd > $0.sourceStart + epsilon
            }) {
                throw ProjectTimelineEditingError.invalidSourceSequence
            }
        }
    }

    static func primarySegmentIDs(in sequence: SourceSequence) -> Set<UUID> {
        switch sequence {
        case .fullRecording:
            return [TimelineMap.fullRecordingSegmentID]
        case let .edited(segments):
            return Set(segments.map(\.id))
        }
    }

    static func prunedPrimarySegmentAudioOverrides(
        _ overrides: [UUID: PrimarySegmentAudioOverrides],
        sourceSequence: SourceSequence
    ) -> [UUID: PrimarySegmentAudioOverrides] {
        let validIDs = primarySegmentIDs(in: sourceSequence)
        return overrides.filter { validIDs.contains($0.key) && !$0.value.isEmpty }
    }

    static func validatePrimarySegmentAudioOverrides(
        _ overrides: [UUID: PrimarySegmentAudioOverrides],
        sourceSequence: SourceSequence
    ) throws {
        let validIDs = primarySegmentIDs(in: sourceSequence)
        for (id, value) in overrides {
            let volumes = [value.systemVolume, value.microphoneVolume]
                .compactMap { $0 }
            guard validIDs.contains(id), !value.isEmpty,
                  volumes.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ProjectTimelineEditingError.invalidPrimarySegmentAudioOverrides(id)
            }
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
                  clip.preferredEnterDuration.map({ $0.isFinite && (0...5).contains($0) }) ?? true,
                  clip.preferredExitDuration.map({ $0.isFinite && (0...5).contains($0) }) ?? true,
                  (0...1).contains(clip.enterProgressOffset),
                  (0...1).contains(clip.exitProgressOffset),
                  valid(clip.customCurve),
                  clip.focusEffect?.isValid ?? true else {
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
                  target.perspective >= 0,
                  clip.focusEffect?.isValid ?? true else {
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

    static func validateMosaicClips(_ clips: [MosaicClip]) throws {
        var identifiers = Set<UUID>()
        for clip in clips {
            guard identifiers.insert(clip.id).inserted else {
                throw ProjectTimelineEditingError.duplicateClipID(track: .mosaic, id: clip.id)
            }
            let rect = clip.sourceRect
            guard valid(clip.timing),
                  rect == rect.clamped(),
                  clip.cornerRadius.isFinite,
                  (0...0.5).contains(clip.cornerRadius),
                  clip.intensity.isFinite,
                  (0...1).contains(clip.intensity),
                  clip.spotlightDimming.isFinite,
                  (0...0.75).contains(clip.spotlightDimming),
                  clip.transitionInDuration.isFinite,
                  clip.transitionOutDuration.isFinite,
                  (0...5).contains(clip.transitionInDuration),
                  (0...5).contains(clip.transitionOutDuration) else {
                throw ProjectTimelineEditingError.invalidClip(track: .mosaic, id: clip.id)
            }
        }
    }

    static func validateStickerClips(_ clips: [StickerClip]) throws {
        var identifiers = Set<UUID>()
        for clip in clips {
            guard identifiers.insert(clip.id).inserted else {
                throw ProjectTimelineEditingError.duplicateClipID(track: .sticker, id: clip.id)
            }
            let components = clip.relativePath.split(separator: "/")
            guard valid(clip.timing),
                  !clip.relativePath.isEmpty,
                  !clip.relativePath.hasPrefix("/"),
                  !components.contains(".."),
                  normalized(clip.position),
                  clip.width.isFinite,
                  (0.02...1.5).contains(clip.width),
                  clip.rotationDegrees.isFinite,
                  (-1_080...1_080).contains(clip.rotationDegrees),
                  clip.opacity.isFinite,
                  (0...1).contains(clip.opacity),
                  clip.cornerRadius.isFinite,
                  (0...500).contains(clip.cornerRadius),
                  clip.borderWidth.isFinite,
                  (0...60).contains(clip.borderWidth),
                  clip.shadowOpacity.isFinite,
                  (0...1).contains(clip.shadowOpacity),
                  clip.shadowRadius.isFinite,
                  (0...160).contains(clip.shadowRadius),
                  clip.shadowOffsetX.isFinite,
                  clip.shadowOffsetY.isFinite,
                  clip.enterDuration.isFinite,
                  clip.exitDuration.isFinite,
                  (0...5).contains(clip.enterDuration),
                  (0...5).contains(clip.exitDuration),
                  clip.backdropBlur.isFinite,
                  (0...96).contains(clip.backdropBlur) else {
                throw ProjectTimelineEditingError.invalidClip(track: .sticker, id: clip.id)
            }
        }
    }

    static func valid(_ timing: OverlayTiming) -> Bool {
        timing.startTime.isFinite
            && timing.startTime >= 0
            && timing.duration.isFinite
            && timing.duration > 0
            && timing.endTime.isFinite
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
            && timing.leadInDuration.isFinite && (0...5).contains(timing.leadInDuration)
            && timing.returnDuration.isFinite && (0...5).contains(timing.returnDuration)
            && (timing.preferredLeadInDuration.map { $0.isFinite && (0...5).contains($0) } ?? true)
            && (timing.preferredReturnDuration.map { $0.isFinite && (0...5).contains($0) } ?? true)
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
            sourceDuration: segment.sourceDuration,
            playbackRate: segment.playbackRate
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
