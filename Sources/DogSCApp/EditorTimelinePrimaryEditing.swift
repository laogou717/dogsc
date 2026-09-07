import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

/// Output-lane geometry for one primary segment. A segment's source duration
/// is media time; every pointer and pixel decision on the edited timeline must
/// instead use its rate-adjusted output duration.
enum EditorPrimarySegmentGeometry {
    static func outputTime(
        in segment: ResolvedRecordingSegment,
        atFraction fraction: TimeInterval
    ) -> TimeInterval {
        let clampedFraction = min(max(fraction, 0), 1)
        return segment.outputStart + clampedFraction * segment.outputDuration
    }

    static func centerX(
        of segment: ResolvedRecordingSegment,
        laneWidth: CGFloat,
        timelineDuration: TimeInterval
    ) -> CGFloat {
        let centerTime = segment.outputStart + segment.outputDuration / 2
        return CGFloat(centerTime / timelineDuration) * laneWidth
    }
}

extension EditorTimelineView {
var primarySegmentJunctions: [EditorTimelineSegmentJunction] {
        guard let timelineMap else { return [] }
        return derivedPresentationCache.segmentJunctions(for: timelineMap)
    }

    var primaryLeadingGap: EditorTimelineLeadingGap? {
        guard let timelineMap else { return nil }
        return derivedPresentationCache.leadingGap(for: timelineMap)
    }

    var primaryTrailingGap: EditorTimelineTrailingGap? {
        guard let timelineMap else { return nil }
        return derivedPresentationCache.trailingGap(for: timelineMap)
    }

    @ViewBuilder
    func primarySegmentContextMenu(segment: ResolvedRecordingSegment) -> some View {
        Button {
            splitPrimarySegmentAtPlayhead()
        } label: {
            Label("在播放头处分割", systemImage: "scissors")
        }
        .disabled(!canSplitPrimarySegment(segment))

        Divider()

        Menu {
            ForEach([1.0, 1.5, 2.0, 4.0, 8.0, 12.0, 20.0, 50.0, 100.0], id: \.self) { rate in
                Button {
                    setPrimarySegmentPlaybackRate(segment.id, rate: rate)
                } label: {
                    if abs(segment.playbackRate - rate) < 0.000_1 {
                        Label(timelinePlaybackRateText(rate), systemImage: "checkmark")
                    } else {
                        Text(timelinePlaybackRateText(rate))
                    }
                }
            }
            Divider()
            Button {} label: {
                Label("按住 Control 拖右端自由变速", systemImage: "arrow.left.and.right")
            }
            .disabled(true)
        } label: {
            Label("片段速度", systemImage: "speedometer")
        }

        Divider()

        Button {
            rippleDeleteBeforePlayhead()
        } label: {
            Label("波纹删除播放头之前（Q）", systemImage: "delete.left")
        }
        .disabled(!canRippleDeleteBeforePlayhead(in: segment))

        Button {
            rippleDeleteAfterPlayhead()
        } label: {
            Label("波纹删除播放头之后（W）", systemImage: "delete.right")
        }
        .disabled(!canRippleDeleteAfterPlayhead(in: segment))

        let previousJunction = primarySegmentJunctions.first(where: { $0.nextSegmentID == segment.id })
        let nextJunction = primarySegmentJunctions.first(where: { $0.previousSegmentID == segment.id })
        let isFirstSegment = segment.id == primaryDisplaySegments.first?.id
        let isLastSegment = segment.id == primaryDisplaySegments.last?.id

        if previousJunction != nil || nextJunction != nil || (isFirstSegment && primaryLeadingGap != nil) || (isLastSegment && primaryTrailingGap != nil) {
            Divider()

            if isFirstSegment, let gap = primaryLeadingGap {
                Button {
                    restorePrimaryLeadingGap(gap)
                } label: {
                    Label("还原开头剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）", systemImage: "arrow.uturn.backward")
                }
            }

            if let junction = previousJunction {
                if junction.hasRemovedSourceGap {
                    Button {
                        restorePrimaryGap(junction)
                    } label: {
                        Label("还原前侧剪切缺口（已剪 \(timelineTimestamp(junction.removedDuration))）", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        mergePrimarySegments(at: junction)
                    } label: {
                        Label("合并与前一片段", systemImage: "link")
                    }
                }
            }

            if let junction = nextJunction {
                if junction.hasRemovedSourceGap {
                    Button {
                        restorePrimaryGap(junction)
                    } label: {
                        Label("还原后侧剪切缺口（已剪 \(timelineTimestamp(junction.removedDuration))）", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        mergePrimarySegments(at: junction)
                    } label: {
                        Label("合并与后一片段", systemImage: "link")
                    }
                }
            }

            if isLastSegment, let gap = primaryTrailingGap {
                Button {
                    restorePrimaryTrailingGap(gap)
                } label: {
                    Label("还原结尾剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）", systemImage: "arrow.uturn.backward")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            selectPrimarySegment(segment.id)
            removePrimarySegment(id: segment.id)
        } label: {
            Label("删除主片段", systemImage: "trash")
        }
    }

    func setPrimarySegmentPlaybackRate(_ id: UUID, rate: Double) {
        do {
            try editorStore.setPrimarySegmentPlaybackRate(
                id: id,
                rate: rate,
                fullSourceDuration: fullSourceDuration,
                actionName: "调整片段速度"
            )
            selectPrimarySegment(id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func timelinePlaybackRateText(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.000_1 {
            return "\(Int(rate.rounded()))×"
        }
        return String(format: "%.1f×", rate)
    }

    func segmentJunctionAction(
        _ junction: EditorTimelineSegmentJunction
    ) -> some View {
        return Button {
            if junction.hasRemovedSourceGap {
                restorePrimaryGap(junction)
            } else {
                mergePrimarySegments(at: junction)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.9))
                Circle()
                    .stroke(EditorTheme.mediaAccent.opacity(0.95), lineWidth: 1)
                Image(systemName: junction.hasRemovedSourceGap
                    ? "arrow.uturn.backward"
                    : "link")
                    .font(.appUI(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorInlineAction)
        .contentShape(Rectangle())
        .help(
            junction.hasRemovedSourceGap
                ? "撤销这一处剪辑（已剪 \(timelineTimestamp(junction.removedDuration))）"
                : "合并这两个已剪开的片段"
        )
        .accessibilityLabel(
            junction.hasRemovedSourceGap ? "还原剪切缺口" : "合并相邻主片段"
        )
        .accessibilityValue(
            junction.hasRemovedSourceGap
                ? timelineTimestamp(junction.removedDuration)
                : "未删除素材"
        )
        .accessibilityIdentifier(
            "editor.timeline.cut-junction.\(junction.nextSegmentID.uuidString)"
        )
    }

    func leadingGapAction(_ gap: EditorTimelineLeadingGap) -> some View {
        Button {
            restorePrimaryLeadingGap(gap)
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.9))
                Circle().stroke(EditorTheme.mediaAccent.opacity(0.95), lineWidth: 1)
                Image(systemName: "arrow.uturn.backward")
                    .font(.appUI(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorInlineAction)
        .help("还原开头剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）")
        .accessibilityLabel("还原开头剪辑")
        .accessibilityValue(timelineTimestamp(gap.removedDuration))
        .accessibilityIdentifier("editor.timeline.leading-gap")
    }

    func trailingGapAction(_ gap: EditorTimelineTrailingGap) -> some View {
        Button {
            restorePrimaryTrailingGap(gap)
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.9))
                Circle().stroke(EditorTheme.mediaAccent.opacity(0.95), lineWidth: 1)
                Image(systemName: "arrow.uturn.backward")
                    .font(.appUI(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorInlineAction)
        .help("还原结尾剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）")
        .accessibilityLabel("还原结尾剪辑")
        .accessibilityValue(timelineTimestamp(gap.removedDuration))
        .accessibilityIdentifier("editor.timeline.trailing-gap")
    }

    func restorePrimaryGap(_ junction: EditorTimelineSegmentJunction) {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryGap(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                restoredSegmentID: restoredID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原该处剪切"
            )
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
            selectPrimarySegment(restoredID)
            seekTimeline(to: junction.outputTime)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func restorePrimaryLeadingGap(_ gap: EditorTimelineLeadingGap) {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryLeadingGap(
                restoredSegmentID: restoredID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原开头剪辑"
            )
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
            selectPrimarySegment(restoredID)
            seekTimeline(to: 0)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func restorePrimaryTrailingGap(_ gap: EditorTimelineTrailingGap) {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryTrailingGap(
                restoredSegmentID: restoredID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原结尾剪辑"
            )
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
            selectPrimarySegment(restoredID)
            seekTimeline(to: gap.outputTime)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func mergePrimarySegments(at junction: EditorTimelineSegmentJunction) {
        do {
            try editorStore.mergeAdjacentPrimarySegments(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                fullSourceDuration: fullSourceDuration,
                actionName: "合并相邻主片段"
            )
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
            selectPrimarySegment(junction.previousSegmentID)
            seekTimeline(to: junction.outputTime)
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// AUD-003/AUD-004: waveform pixels belong to each retained video clip.
    /// Rendering one clipped overlay per segment keeps cut gaps and segment
    /// borders visible, and uses the same output-to-source media map as
    /// preview/export instead of inventing a second audio timeline lane.
    func clipAudioWaveformOverlay(
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let visibleWindow = EditorTimelineWaveformPresentation.visibleWindow(
            documentWidth: width,
            outputDuration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        return ZStack(alignment: .leading) {
            if let draggedPrimarySegmentID,
               abs(primarySegmentDragTranslation) > 0.01 {
                clipWaveforms(
                    width: visibleWindow.width,
                    outputStart: visibleWindow.outputStart,
                    outputDuration: visibleWindow.outputDuration
                )
                .mask {
                    clipWaveformMask(
                        width: width,
                        duration: duration,
                        visibleWindow: visibleWindow,
                        including: { $0.id != draggedPrimarySegmentID }
                    )
                }
                .offset(x: visibleWindow.documentOriginX)

                // The dragged clip owns its waveform pixels. Move the source
                // and its mask together so the audio preview never appears to
                // stay behind and then snap back when the drop commits.
                clipWaveforms(
                    width: visibleWindow.width,
                    outputStart: visibleWindow.outputStart,
                    outputDuration: visibleWindow.outputDuration
                )
                .mask {
                    clipWaveformMask(
                        width: width,
                        duration: duration,
                        visibleWindow: visibleWindow,
                        including: { $0.id == draggedPrimarySegmentID }
                    )
                }
                .offset(
                    x: visibleWindow.documentOriginX + primarySegmentDragTranslation
                )
            } else {
                clipWaveforms(
                    width: visibleWindow.width,
                    outputStart: visibleWindow.outputStart,
                    outputDuration: visibleWindow.outputDuration
                )
                .mask {
                    clipWaveformMask(
                        width: width,
                        duration: duration,
                        visibleWindow: visibleWindow,
                        including: { _ in true }
                    )
                }
                .offset(x: visibleWindow.documentOriginX)
            }
        }
        .frame(width: width, height: waveformContentHeight, alignment: .leading)
        .clipped()
        // The waveform is a non-interactive visual preview inside the primary
        // clips. Exposing its container and two canvases creates three dead
        // VoiceOver stops between the clip and its animation tracks.
        .accessibilityHidden(true)
    }

    func clipWaveformMask(
        width: CGFloat,
        duration: TimeInterval,
        visibleWindow: EditorTimelineWaveformPresentation.VisibleWindow,
        including: @escaping (ResolvedRecordingSegment) -> Bool
    ) -> some View {
        Canvas { context, size in
            var retainedSegments = Path()
            let safeDuration = max(duration, 0.001)
            let windowStart = visibleWindow.documentOriginX
            let windowEnd = windowStart + visibleWindow.width
            for segment in primaryDisplaySegments where including(segment) {
                let segmentStart = CGFloat(segment.outputStart / safeDuration) * width
                let segmentEnd = segmentStart
                    + max(CGFloat(segment.outputDuration / safeDuration) * width, 1)
                guard segmentEnd >= windowStart, segmentStart <= windowEnd else {
                    continue
                }
                let localStart = max(segmentStart - windowStart, 0)
                let localEnd = min(segmentEnd - windowStart, size.width)
                // Keep the trim boundary and the compact title badge visually
                // clear. The waveform previously painted over both, making a
                // highly zoomed edit paradoxically harder to read at the exact
                // frame edge the user was trying to trim.
                let localWidth = max(localEnd - localStart, 1)
                let edgeInset = min(CGFloat(5), localWidth * 0.22)
                let waveformTopInset: CGFloat = 3
                retainedSegments.addRoundedRect(
                    in: CGRect(
                        x: localStart + edgeInset,
                        y: waveformTopInset,
                        width: max(localWidth - edgeInset * 2, 1),
                        height: max(size.height - waveformTopInset - 2, 1)
                    ),
                    cornerSize: CGSize(width: 4, height: 4)
                )
            }
            context.fill(retainedSegments, with: .color(.white))
        }
    }

    func clipWaveforms(
        width: CGFloat,
        outputStart: TimeInterval,
        outputDuration: TimeInterval
    ) -> some View {
        let plan = waveformMediaPlan
        return EditorTimelineMergedWaveform(
            system: showsSystemWaveform ? systemWaveform : nil,
            microphone: showsMicrophoneWaveform ? microphoneWaveform : nil,
            systemPlan: plan?.systemAudio,
            microphonePlan: plan?.microphone,
            systemGains: waveformGainRanges(for: .system),
            microphoneGains: waveformGainRanges(for: .microphone),
            width: width, height: waveformContentHeight,
            outputStart: outputStart, outputDuration: outputDuration,
            expanded: usesWaveformClips)
    }

    var waveformMediaPlan: ProjectTimelineMediaPlan? {
        guard primaryTrimDraft != nil || primaryRetimeDraft != nil,
              let video = mediaSession.inventories.source.videoTimeRange else {
            return mediaSession.mediaPlan
        }
        return derivedPresentationCache.waveformPlan(segments: primaryDisplaySegments,
            manifest: editorStore.project.media, video: video,
            system: mediaSession.inventories.source.audioTimeRange,
            microphone: mediaSession.inventories.microphone.audioTimeRange)
    }

    func waveformGainRanges(
        for lane: EditorTimelineWaveformLane
    ) -> [EditorTimelineWaveformGainRange] {
        let project = editorStore.previewProject
        return primaryDisplaySegments.compactMap { segment in
            let overrides = project.timeline.primarySegmentAudioOverrides[segment.id]
                ?? PrimarySegmentAudioOverrides()
            let gain: Double
            switch lane {
            case .system:
                gain = (overrides.isSystemMuted ?? project.audio.isSystemMuted)
                    ? 0
                    : overrides.systemVolume ?? project.audio.systemVolume
            case .microphone:
                gain = (overrides.isMicrophoneMuted ?? project.audio.isMicrophoneMuted)
                    ? 0
                    : overrides.microphoneVolume ?? project.audio.microphoneVolume
            }
            return EditorTimelineWaveformGainRange(
                startTime: segment.outputStart,
                endTime: segment.outputEnd,
                gain: gain
            )
        }
    }

    @MainActor
    func loadAudioWaveforms() async {
        guard let prepared = mediaSession.prepared else {
            systemWaveform = nil
            microphoneWaveform = nil
            return
        }
        let expectedGeneration = prepared.generation
        // Copy the immutable, Sendable inputs before creating child tasks.
        // The prepared media container also owns AVFoundation composition
        // objects, so sending the whole main-actor value would overstate the
        // concurrency boundary even though waveform decoding needs only URLs
        // and time ranges.
        let sourceInput = prepared.request.source
        let sourceRange = prepared.inventories.source.audioTimeRange
        let microphoneInput = prepared.request.microphone
        let microphoneRange = prepared.inventories.microphone.audioTimeRange
        let cachedSystem = systemWaveform
        let cachedMicrophone = microphoneWaveform
        async let loadedSystem = EditorTimelineWaveformLoader.load(
            input: sourceInput,
            sourceRange: sourceRange,
            cached: cachedSystem
        )
        async let loadedMicrophone = EditorTimelineWaveformLoader.load(
            input: microphoneInput,
            sourceRange: microphoneRange,
            cached: cachedMicrophone
        )
        let results = await (loadedSystem, loadedMicrophone)
        guard !Task.isCancelled,
              mediaSession.prepared?.generation == expectedGeneration else { return }
        systemWaveform = results.0
        microphoneWaveform = results.1
    }

    /// Alt+悬停主片段轨时的裁剪落点：原始 hover x，或在 7pt 内磁吸到最近的
    /// 片段端点/播放头。
    func snappedCutX(width: CGFloat, duration: TimeInterval) -> CGFloat? {
        guard isOptionHeld,
              let x = hoveredTimelineContentX,
              let y = hoveredTimelineContentY,
              y >= timelineRulerHeight,
              y <= timelineRulerHeight + primaryTimelineHeight else { return nil }
        return EditorPrimaryTimelinePresentation.snappedCutX(
            pointerX: x,
            width: width,
            duration: duration,
            segments: primaryDisplaySegments,
            playbackTime: playbackTime
        )
    }

    var primaryDisplaySegments: [ResolvedRecordingSegment] {
        guard let timelineMap else { return [] }
        return EditorPrimaryTimelinePresentation.displaySegments(
            from: timelineMap,
            trimDraft: primaryTrimDraft,
            retimeDraft: primaryRetimeDraft
        )
    }

    func primaryTrimHandle(
        edge: RecordingSegmentTrimEdge,
        segment: ResolvedRecordingSegment,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let intent = EditorTimelineGestureIntent.primaryTrim(segment.id, edge)
        return Capsule(style: .continuous)
            .fill(EditorTheme.chrome(0.95))
            .frame(
                width: 3,
                height: min(max(primaryVideoHeight - 20, 24), 44)
            )
            .frame(width: 12, height: primaryVideoHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
                    )
                    .onChanged { value in
                        let isRetime = edge == .right && (
                            primaryRetimeDraft?.segmentID == segment.id
                                || (primaryTrimDraft == nil
                                    && NSEvent.modifierFlags.contains(.control))
                        )
                        let activeIntent: EditorTimelineGestureIntent = isRetime
                            ? .primaryRetime(segment.id)
                            : intent
                        guard beginTimelineGesture(activeIntent) else { return }
                        if primaryTrimDraft == nil && primaryRetimeDraft == nil {
                            selectPrimarySegment(segment.id)
                        }
                        if isRetime {
                            let original = primaryRetimeDraft?.original ?? segment
                            let rawEndTime = original.outputEnd + TimeInterval(
                                value.translation.width / max(laneWidth, 1)
                            ) * duration
                            let minimumDuration = original.sourceDuration
                                / RecordingSegment.maximumPlaybackRate
                            let proposedDuration = min(
                                max(magneticTime(rawEndTime, width: laneWidth, duration: duration) - segment.outputStart, minimumDuration),
                                segment.sourceDuration
                            )
                            timelineSnap.validate(edges: [segment.outputStart + proposedDuration])
                            let proposedRate = min(max(
                                segment.sourceDuration / max(proposedDuration, 0.000_1),
                                1
                            ), RecordingSegment.maximumPlaybackRate)
                            let retimeDraft = PrimarySegmentRetimeDraft(
                                segmentID: segment.id,
                                original: original,
                                proposedRate: proposedRate
                            )
                            guard primaryRetimeDraft != retimeDraft else { return }
                            primaryRetimeDraft = retimeDraft
                            playbackController.beginScrubbing()
                            playbackController.updateScrubbing(
                                to: segment.outputStart + proposedDuration
                            )
                            return
                        }
                        let origin: PrimarySegmentTrimDraft
                        if let current = primaryTrimDraft,
                           current.segmentID == segment.id,
                           current.edge == edge {
                            origin = current
                        } else {
                            guard let map = timelineMap,
                                  let created = EditorPrimaryTimelinePresentation.trimDraftOrigin(
                                      segmentID: segment.id,
                                      edge: edge,
                                      map: map,
                                      fullSourceDuration: fullSourceDuration
                                  ) else { return }
                            origin = created
                        }
                        let rawOutputTime = EditorPrimaryTimelinePresentation.trimOutputTime(
                            for: origin.original,
                            edge: edge,
                            translation: value.translation.width,
                            laneWidth: laneWidth,
                            outputDuration: duration,
                            minimumSegmentDuration: minimumPrimarySegmentDuration,
                            minimumOutputTime: origin.minimumOutputTime,
                            maximumOutputTime: origin.maximumOutputTime
                        )
                        let frameTime = snappedEditableTime(
                            rawOutputTime,
                            lowerBound: origin.minimumOutputTime,
                            upperBound: origin.maximumOutputTime
                        )
                        let outputTime = min(max(magneticTime(frameTime, width: laneWidth, duration: duration,
                            initial: [edge == .left ? origin.original.outputStart : origin.original.outputEnd]),
                            origin.minimumOutputTime), origin.maximumOutputTime)
                        timelineSnap.validate(edges: [outputTime])
                        let draft = PrimarySegmentTrimDraft(
                            segmentID: segment.id,
                            edge: edge,
                            original: origin.original,
                            minimumOutputTime: origin.minimumOutputTime,
                            maximumOutputTime: origin.maximumOutputTime,
                            proposedOutputTime: outputTime
                        )
                        guard primaryTrimDraft != draft else { return }
                        primaryTrimDraft = draft
                        playbackController.beginScrubbing()
                        playbackController.updateScrubbing(
                            to: EditorPrimaryTimelinePresentation.trimPreviewTime(
                                for: draft,
                                frameDuration: timelineFrameDuration
                            )
                        )
                    }
                    .onEnded { _ in
                        let activeIntent = gestureOwnership.activeIntent
                        guard activeIntent == intent
                            || activeIntent == .primaryRetime(segment.id) else { return }
                        playbackController.endScrubbing()
                        if activeIntent == .primaryRetime(segment.id) {
                            commitPrimaryRetimeDraft()
                            endTimelineGesture(.primaryRetime(segment.id))
                        } else {
                            commitPrimaryTrimDraft()
                            endTimelineGesture(intent)
                        }
                    }
            )
            .help(edge == .left
                ? "拖动裁切或恢复左端"
                : "拖动裁切或恢复右端；按住 Control 拖动可自由变速")
            .accessibilityLabel(edge == .left ? "裁切主片段左端" : "裁切主片段右端")
            .accessibilityIdentifier(
                "editor.timeline.primary.trim.\(segment.id.uuidString).\(edge.rawValue)"
            )
    }

    var minimumPrimarySegmentDuration: TimeInterval {
        timelineFrameDuration
    }

    var primarySplitTime: TimeInterval {
        effectiveTimelineEditTime
    }

    var primarySplitCandidate: ResolvedRecordingSegment? {
        let splitTime = primarySplitTime
        guard let segment = timelineMap?.segment(atOutputTime: splitTime),
              splitTime - segment.outputStart >= minimumPrimarySegmentDuration,
              segment.outputEnd - splitTime >= minimumPrimarySegmentDuration
        else { return nil }
        return segment
    }

    func canSplitPrimarySegment(_ segment: ResolvedRecordingSegment) -> Bool {
        primarySplitCandidate?.id == segment.id
    }

    func canRippleDeleteBeforePlayhead(
        in segment: ResolvedRecordingSegment
    ) -> Bool {
        let editTime = effectiveTimelineEditTime
        guard timelineMap?.segment(atOutputTime: editTime)?.id == segment.id else {
            return false
        }
        return editTime > segment.outputStart + timelineFrameDuration / 2
            && segment.outputEnd - editTime >= minimumPrimarySegmentDuration
    }

    func canRippleDeleteAfterPlayhead(
        in segment: ResolvedRecordingSegment
    ) -> Bool {
        let editTime = effectiveTimelineEditTime
        guard timelineMap?.segment(atOutputTime: editTime)?.id == segment.id else {
            return false
        }
        return editTime - segment.outputStart >= minimumPrimarySegmentDuration
            && segment.outputEnd - editTime > timelineFrameDuration / 2
    }

    func selectPrimarySegment(_ id: UUID) {
        selectedPrimarySegmentIDs = [id]
        editorStore.selection = .primarySegment(id)
    }

    func selectPrimarySegment(
        _ id: UUID,
        extendingWith modifiers: NSEvent.ModifierFlags
    ) {
        if modifiers.contains(.shift),
           let anchorID = selectedPrimarySegmentID,
           let segments = timelineMap?.segments,
           let anchorIndex = segments.firstIndex(where: { $0.id == anchorID }),
           let targetIndex = segments.firstIndex(where: { $0.id == id }) {
            let lower = min(anchorIndex, targetIndex)
            let upper = max(anchorIndex, targetIndex)
            selectedPrimarySegmentIDs = Set(segments[lower...upper].map(\.id))
            editorStore.selection = .primarySegment(id)
            return
        }
        if modifiers.contains(.command) {
            if selectedPrimarySegmentIDs.contains(id) {
                selectedPrimarySegmentIDs.remove(id)
                if selectedPrimarySegmentIDs.isEmpty {
                    editorStore.selection = .canvas
                } else if selectedPrimarySegmentID == id {
                    let nextID = timelineMap?.segments.first(where: {
                        selectedPrimarySegmentIDs.contains($0.id)
                    })?.id
                    editorStore.selection = nextID.map(EditorSelection.primarySegment)
                        ?? .canvas
                }
            } else {
                selectedPrimarySegmentIDs.insert(id)
                editorStore.selection = .primarySegment(id)
            }
            return
        }
        selectedPrimarySegmentIDs = [id]
        editorStore.selection = .primarySegment(id)
    }

    func prepareEmptyTimelineClick() {
        switch editorStore.selection {
        case .primarySegment, .zoom, .screenMotion, .cameraMotion, .mosaic, .sticker:
            emptyClickClearsSelection = true
        default:
            emptyClickClearsSelection = !selectedPrimarySegmentIDs.isEmpty || selectedCameraSyncAnchorID != nil
        }
        clearTimelineSelection()
    }

    func clearTimelineSelection() {
        primaryTrimDraft = nil
        primaryRetimeDraft = nil
        hoveredPrimarySegmentID = nil
        hoveredZoomID = nil
        hoveredMotionClip = nil
        hoveredOverlaySelection = nil
        selectedCameraSyncAnchorID = nil
        selectedPrimarySegmentIDs.removeAll()
        editorStore.selection = nil
        playbackController.endHoverPreview()
    }

    func splitPrimarySegmentAtPlayhead() {
        guard primarySplitCandidate != nil else { return }
        let splitTime = primarySplitTime
        let rightID = UUID()
        do {
            try editorStore.splitPrimarySegment(
                atOutputTime: splitTime,
                fullSourceDuration: fullSourceDuration,
                newRightSegmentID: rightID,
                actionName: "分割主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        hoveredPrimarySegmentID = nil
        selectPrimarySegment(rightID)
        seekTimeline(to: min(splitTime, timelineDuration))
    }

    /// Option+单击快捷切分：按点击位置的比例换算输出时间，与剪刀按钮同一条
    /// 领域路径（不可分割的位置——太靠近端点——直接忽略，不打扰正常点选）。
    func splitPrimarySegmentAtClick(
        segment: ResolvedRecordingSegment,
        location: CGPoint,
        segmentWidth: CGFloat
    ) {
        guard NSEvent.modifierFlags.contains(.option) else { return }
        let fraction = TimeInterval(min(max(location.x / max(segmentWidth, 1), 0), 1))
        var outputTime = EditorPrimarySegmentGeometry.outputTime(
            in: segment,
            atFraction: fraction
        )
        // 磁吸：落点在片段端点或播放头附近（与剪刀提示同一 7pt 容差）时对齐。
        let laneWidth = max(timelineContentWidth, 1)
        let outputX = CGFloat(outputTime / max(timelineDuration, 0.001)) * laneWidth
        let snappedX = EditorPrimaryTimelinePresentation.snappedCutX(
            pointerX: outputX,
            width: laneWidth,
            duration: timelineDuration,
            segments: primaryDisplaySegments,
            playbackTime: playbackTime
        )
        outputTime = EditorTimelineMath.clampedTime(
            atX: Double(snappedX),
            width: Double(laneWidth),
            duration: timelineDuration
        )
        outputTime = snappedEditableTime(
            outputTime,
            lowerBound: segment.outputStart,
            upperBound: segment.outputEnd
        )
        guard outputTime > segment.outputStart + minimumPrimarySegmentDuration,
              outputTime < segment.outputEnd - minimumPrimarySegmentDuration else { return }
        let rightID = UUID()
        do {
            try editorStore.splitPrimarySegment(
                atOutputTime: outputTime,
                fullSourceDuration: fullSourceDuration,
                newRightSegmentID: rightID,
                actionName: "分割主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        hoveredPrimarySegmentID = nil
        selectPrimarySegment(rightID)
        seekTimeline(to: outputTime)
    }

    func removeSelectedPrimarySegment() {
        guard let selectedPrimarySegmentID else { return }
        removePrimarySegment(id: selectedPrimarySegmentID)
    }

    func movePrimarySegment(
        _ draggedID: UUID,
        relativeTo targetID: UUID,
        placeAfterTarget: Bool
    ) {
        guard let map = timelineMap,
              let oldIndex = map.segments.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = map.segments.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        var destination = targetIndex + (placeAfterTarget ? 1 : 0)
        if oldIndex < destination { destination -= 1 }
        destination = min(max(destination, 0), map.segments.count - 1)
        guard destination != oldIndex else { return }
        do {
            try editorStore.movePrimarySegment(
                id: draggedID,
                toIndex: destination,
                fullSourceDuration: fullSourceDuration,
                actionName: "调整主片段顺序"
            )
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
            hoveredPrimarySegmentID = nil
            selectPrimarySegment(draggedID)
            if let updatedMap = try? EditorPrimaryTimelinePresentation.timelineMap(
                fullSourceDuration: fullSourceDuration,
                project: editorStore.project
            ), let moved = updatedMap.segments.first(where: { $0.id == draggedID }) {
                seekTimeline(to: moved.outputStart)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// EDT-016: reordering stays inside the timeline's own gesture lifecycle.
    /// SwiftUI/AppKit drag-and-drop can outlive its source view when the window
    /// deactivates, leaving the source segment permanently dimmed. A direct
    /// drag has a deterministic end/cancel path and never creates an external
    /// pasteboard session.
    func updatePrimarySegmentDrag(
        segmentID: UUID,
        translation: CGFloat,
        documentX: CGFloat,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) {
        if draggedPrimarySegmentID == nil {
            timelineSnap.reset()
            draggedPrimarySegmentID = segmentID
        }
        guard draggedPrimarySegmentID == segmentID else { return }
        guard let segment = primaryDisplaySegments.first(where: { $0.id == segmentID }) else { return }
        let rawDelta = Double(translation / max(laneWidth, 1)) * duration
        let delta = magneticDelta(rawDelta, start: segment.outputStart,
            end: segment.outputStart + segment.outputDuration, mode: .move,
            width: laneWidth, duration: duration)
        primarySegmentDragTranslation = CGFloat(delta / max(duration, 0.001)) * laneWidth
        primarySegmentDragDocumentX = documentX + primarySegmentDragTranslation - translation
    }

    func finishPrimarySegmentDrag(
        segmentID: UUID,
        documentX: CGFloat,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) {
        defer { endPrimarySegmentDrag() }
        guard draggedPrimarySegmentID == segmentID,
              laneWidth > 0,
              duration > 0 else { return }

        let x = min(max(primarySegmentDragDocumentX ?? documentX, 0), laneWidth)
        let segments = primaryDisplaySegments
        guard let target = segments.min(by: { lhs, rhs in
            let lhsCenter = EditorPrimarySegmentGeometry.centerX(
                of: lhs,
                laneWidth: laneWidth,
                timelineDuration: duration
            )
            let rhsCenter = EditorPrimarySegmentGeometry.centerX(
                of: rhs,
                laneWidth: laneWidth,
                timelineDuration: duration
            )
            return abs(lhsCenter - x) < abs(rhsCenter - x)
        }), target.id != segmentID else { return }

        let targetCenter = EditorPrimarySegmentGeometry.centerX(
            of: target,
            laneWidth: laneWidth,
            timelineDuration: duration
        )
        movePrimarySegment(
            segmentID,
            relativeTo: target.id,
            placeAfterTarget: x >= targetCenter
        )
    }

    func removePrimarySegment(id: UUID) {
        let segmentIDs = EditorTimelineSelectionPresentation.primarySegmentIDs(
            in: editorStore.project.timeline.sourceSequence
        )
        guard let removedIndex = segmentIDs.firstIndex(of: id) else { return }
        do {
            try editorStore.removePrimarySegment(
                id: id,
                fullSourceDuration: fullSourceDuration,
                actionName: "删除主片段"
            )
        } catch {
            // The final primary segment remains the only intentional removal
            // restriction. Timed effects are reauthored by the ripple model.
            onError(error.localizedDescription)
            return
        }

        primaryTrimDraft = nil
        primaryRetimeDraft = nil
        hoveredPrimarySegmentID = nil
        let updatedIDs = EditorTimelineSelectionPresentation.primarySegmentIDs(
            in: editorStore.project.timeline.sourceSequence
        )
        if !updatedIDs.isEmpty {
            let nextIndex = min(removedIndex, updatedIDs.count - 1)
            selectPrimarySegment(updatedIDs[nextIndex])
            let updatedMap = try? EditorPrimaryTimelinePresentation.timelineMap(
                fullSourceDuration: fullSourceDuration,
                project: editorStore.project
            )
            seekTimeline(to: min(playbackTime, updatedMap?.outputDuration ?? playbackTime))
        } else {
            editorStore.selection = .screen
        }
    }

    func commitPrimaryTrimDraft() {
        guard let draft = primaryTrimDraft else { return }
        defer {
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
        }
        let finalPlayheadTime: TimeInterval = switch draft.edge {
        case .left: draft.original.outputStart
        case .right: draft.proposedOutputTime
        }
        do {
            try editorStore.trimPrimarySegment(
                id: draft.segmentID,
                edge: draft.edge,
                toOutputTime: draft.proposedOutputTime,
                fullSourceDuration: fullSourceDuration,
                actionName: "裁切主片段"
            )
        } catch {
            // Timed effects follow the same ripple edit. Only genuinely invalid
            // segment bounds should now reach this error path.
            onError(error.localizedDescription)
            return
        }
        selectPrimarySegment(draft.segmentID)
        // The drag sampled the old composition clock. Re-anchor once at the
        // resulting edit point so the replacement generation preserves the
        // intended frame instead of an unrelated pre-ripple position.
        seekTimeline(to: finalPlayheadTime)
    }

    func commitPrimaryRetimeDraft() {
        guard let draft = primaryRetimeDraft else { return }
        defer { primaryRetimeDraft = nil }
        setPrimarySegmentPlaybackRate(
            draft.segmentID,
            rate: draft.proposedRate
        )
        seekTimeline(
            to: draft.original.outputStart
                + draft.original.sourceDuration / draft.proposedRate
        )
    }
}
