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

}

struct EditorAudioWaveformSourceKey: Equatable {
    let source: EditorMediaInput?
    let sourceRange: MediaTimeRange?
    let microphone: EditorMediaInput?
    let microphoneRange: MediaTimeRange?
}

struct EditorDeferredMenuContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
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
        clipClipboardMenu(for: .primarySegment(segment.id))
        Divider()
        Button {
            splitPrimarySegmentAtPlayhead()
        } label: {
            EditorSymbolLabel("在播放头处分割", systemImage: "scissors")
        }
        .disabled(!canSplitPrimarySegment(segment))

        Divider()

        Menu {
            ForEach([1.0, 1.5, 2.0, 4.0, 8.0, 12.0, 20.0, 50.0, 100.0], id: \.self) { rate in
                Button {
                    setPrimarySegmentPlaybackRate(segment.id, rate: rate)
                } label: {
                    if abs(segment.playbackRate - rate) < 0.000_1 {
                        EditorSymbolLabel(timelinePlaybackRateText(rate), systemImage: "checkmark")
                    } else {
                        Text(timelinePlaybackRateText(rate))
                    }
                }
            }
            Divider()
            Button {} label: {
                EditorSymbolLabel("按住 Control 拖右端自由变速", systemImage: "arrow.left.and.right")
            }
            .disabled(true)
        } label: {
            EditorSymbolLabel("片段速度", systemImage: "speedometer")
        }

        Divider()

        Button {
            rippleDeleteBeforePlayhead()
        } label: {
            EditorSymbolLabel("波纹删除播放头之前（Q）", systemImage: "delete.left")
        }
        .disabled(!canRippleDeleteBeforePlayhead(in: segment))

        Button {
            rippleDeleteAfterPlayhead()
        } label: {
            EditorSymbolLabel("波纹删除播放头之后（W）", systemImage: "delete.right")
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
                    restorePrimaryLeadingGap()
                } label: {
                    EditorSymbolLabel(String(format: appLocalized("还原开头剪辑（已剪 %@）"), timelineTimestamp(gap.removedDuration)), systemImage: "arrow.uturn.backward")
                }
            }

            if let junction = previousJunction {
                if junction.hasRemovedSourceGap {
                    Button {
                        restorePrimaryGap(junction)
                    } label: {
                        EditorSymbolLabel(String(format: appLocalized("还原前侧剪切缺口（已剪 %@）"), timelineTimestamp(junction.removedDuration)), systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        mergePrimarySegments(at: junction)
                    } label: {
                        EditorSymbolLabel("合并与前一片段", systemImage: "link")
                    }
                }
            }

            if let junction = nextJunction {
                if junction.hasRemovedSourceGap {
                    Button {
                        restorePrimaryGap(junction)
                    } label: {
                        EditorSymbolLabel(String(format: appLocalized("还原后侧剪切缺口（已剪 %@）"), timelineTimestamp(junction.removedDuration)), systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        mergePrimarySegments(at: junction)
                    } label: {
                        EditorSymbolLabel("合并与后一片段", systemImage: "link")
                    }
                }
            }

            if isLastSegment, let gap = primaryTrailingGap {
                Button {
                    restorePrimaryTrailingGap(gap)
                } label: {
                    EditorSymbolLabel(String(format: appLocalized("还原结尾剪辑（已剪 %@）"), timelineTimestamp(gap.removedDuration)), systemImage: "arrow.uturn.backward")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            selectPrimarySegment(segment.id)
            removePrimarySegment(id: segment.id)
        } label: {
            EditorSymbolLabel("删除主片段", systemImage: "trash")
        }
    }

    func setPrimarySegmentPlaybackRate(_ id: UUID, rate: Double) {
        do {
            try editorStore.setPrimarySegmentPlaybackRate(
                id: id,
                rate: rate,
                sourceDurations: sourceDurations,
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
        return EditorSliderValueFormat.compact(rate, unit: "×")
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
                    .fill(EditorConsole.Track.primary.fill)
                EditorSymbol(junction.hasRemovedSourceGap
                    ? "arrow.uturn.backward"
                    : "link", size: 10.5)
                    .font(.appUI(size: 10, weight: .bold))
                    .foregroundStyle(EditorConsole.Track.primary.ink)
            }
            .frame(width: 17, height: 17)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorInlineAction)
        .contentShape(Rectangle())
        .help(
            junction.hasRemovedSourceGap
                ? String(format: appLocalized("撤销这一处剪辑（已剪 %@）"), timelineTimestamp(junction.removedDuration))
                : appLocalized("合并这两个已剪开的片段")
        )
        .accessibilityLabel(
            appLocalized(junction.hasRemovedSourceGap ? "还原剪切缺口" : "合并相邻主片段")
        )
        .accessibilityValue(
            junction.hasRemovedSourceGap
                ? timelineTimestamp(junction.removedDuration)
                : appLocalized("未删除素材")
        )
        .accessibilityIdentifier(
            "editor.timeline.cut-junction.\(junction.nextSegmentID.uuidString)"
        )
    }

    func leadingGapAction(_ gap: EditorTimelineLeadingGap) -> some View {
        Button {
            restorePrimaryLeadingGap()
        } label: {
            ZStack {
                Circle().fill(EditorConsole.Track.primary.fill)
                EditorSymbol("arrow.uturn.backward", size: 10.5)
                    .font(.appUI(size: 10, weight: .bold))
                    .foregroundStyle(EditorConsole.Track.primary.ink)
            }
            .frame(width: 17, height: 17)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorInlineAction)
        .help(String(format: appLocalized("还原开头剪辑（已剪 %@）"), timelineTimestamp(gap.removedDuration)))
        .accessibilityLabel("还原开头剪辑")
        .accessibilityValue(timelineTimestamp(gap.removedDuration))
        .accessibilityIdentifier("editor.timeline.leading-gap")
    }

    func trailingGapAction(_ gap: EditorTimelineTrailingGap) -> some View {
        Button {
            restorePrimaryTrailingGap(gap)
        } label: {
            ZStack {
                Circle().fill(EditorConsole.Track.primary.fill)
                EditorSymbol("arrow.uturn.backward", size: 10.5)
                    .font(.appUI(size: 10, weight: .bold))
                    .foregroundStyle(EditorConsole.Track.primary.ink)
            }
            .frame(width: 17, height: 17)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorInlineAction)
        .help(String(format: appLocalized("还原结尾剪辑（已剪 %@）"), timelineTimestamp(gap.removedDuration)))
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
                sourceDurations: sourceDurations,
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

    func restorePrimaryLeadingGap() {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryLeadingGap(
                restoredSegmentID: restoredID,
                sourceDurations: sourceDurations,
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
                sourceDurations: sourceDurations,
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
                sourceDurations: sourceDurations,
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
            if let draft = primaryReorderDraft {
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
                        including: { !draft.segmentIDs.contains($0.id) },
                        excludingFloatingSegment: true
                    )
                }
                .offset(x: visibleWindow.documentOriginX)

                ForEach(primaryDisplaySegments.filter { draft.segmentIDs.contains($0.id) }, id: \.id) { floating in
                    let floatingWidth = max(CGFloat(floating.outputDuration / max(duration, 0.001)) * width, 1)
                    let floatingOrigin = CGFloat(floating.outputStart / max(duration, 0.001)) * width
                        + primaryFloatingTranslation(for: floating.id, width: width, duration: duration)
                    let drawStart = max(floatingOrigin, visibleWindow.documentOriginX)
                    let drawEnd = min(floatingOrigin + floatingWidth,
                        visibleWindow.documentOriginX + visibleWindow.width)
                    if drawEnd > drawStart {
                        let drawWidth = drawEnd - drawStart
                        let sourceFraction = Double((drawStart - floatingOrigin) / floatingWidth)
                        clipWaveforms(width: drawWidth,
                            outputStart: floating.outputStart + floating.outputDuration * sourceFraction,
                            outputDuration: floating.outputDuration * Double(drawWidth / floatingWidth))
                            .mask {
                                RoundedRectangle(cornerRadius: 4)
                                    .padding(.leading, drawStart <= floatingOrigin ? min(5, floatingWidth * 0.22) : 0)
                                    .padding(.trailing, drawEnd >= floatingOrigin + floatingWidth ? min(5, floatingWidth * 0.22) : 0)
                                    .padding(.top, 3).padding(.bottom, 2)
                            }
                            .offset(x: drawStart)
                    }
                }
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
        including: @escaping (ResolvedRecordingSegment) -> Bool,
        excludingFloatingSegment: Bool = false
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
            if excludingFloatingSegment, let draft = primaryReorderDraft {
                for floating in draft.movingSegments {
                    let start = CGFloat(floating.outputStart / safeDuration) * width
                        + primarySegmentDragTranslation - windowStart
                    let span = CGFloat(floating.outputDuration / safeDuration) * width
                    context.clip(to: Path(CGRect(x: start, y: 0, width: span, height: size.height)), options: .inverse)
                }
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
            system: showsSystemWaveform ? systemWaveforms : [:],
            microphone: showsMicrophoneWaveform ? microphoneWaveforms : [:],
            systemPlan: plan?.systemAudio,
            microphonePlan: plan?.microphone,
            systemGains: waveformGainRanges(for: .system),
            microphoneGains: waveformGainRanges(for: .microphone),
            inserted: insertedClipWaveforms(plan: plan?.primary),
            width: width, height: waveformContentHeight,
            outputStart: outputStart, outputDuration: outputDuration,
            expanded: usesWaveformClips)
    }

    var waveformMediaPlan: ProjectTimelineMediaPlan? {
        // A committed edit updates clip geometry immediately, while the media
        // session intentionally retains its previous plan until AVFoundation
        // is ready. Always map cached PCM through the displayed sequence,
        // including the first frame after the gesture draft is cleared.
        guard var sources = mediaSession.mediaPlan?.sources else { return nil }
        for id in sources.keys {
            sources[id]?.manifest = editorStore.project.source(id)?.media
            sources[id]?.pointerEvents = []
            sources[id]?.cameraRange = nil
        }
        return derivedPresentationCache.waveformPlan(segments: primaryDisplaySegments, sources: sources)
    }

    /// Inserted clips' own sound, drawn like the recording's: the same
    /// primary plan maps output time to file time (as preview/export do).
    func insertedClipWaveforms(plan: TimelineMediaPlan?) -> [EditorTimelineInsertedWaveform] {
        guard let plan, !insertedWaveforms.isEmpty else { return [] }
        let overrides = editorStore.previewProject.timeline.primarySegmentAudioOverrides
        let gains = plan.slices.filter { $0.media != nil }.map { slice in
            let value = overrides[slice.segmentID]
            let gain = value?.isSystemMuted == true ? 0 : (value?.systemVolume ?? 1)
            return EditorTimelineWaveformGainRange(startTime: slice.outputStart,
                endTime: slice.outputStart + slice.duration, gain: gain)
        }
        return insertedWaveforms.sorted { $0.key < $1.key }.map {
            EditorTimelineInsertedWaveform(audioPath: $0.key, data: $0.value, plan: plan, gains: gains)
        }
    }

    /// Distinct sound files of the clips inserted on the main track.
    var insertedAudioPaths: [String] {
        guard case let .edited(segments) = editorStore.project.timeline.sourceSequence else { return [] }
        return Array(Set(segments.compactMap { $0.media?.ownAudioPath })).sorted()
    }

    func loadInsertedWaveforms() async {
        let paths = insertedAudioPaths
        let loaded = await EditorTimelineInsertedWaveformLoader.load(paths: paths, cached: insertedWaveforms)
        guard !Task.isCancelled, insertedAudioPaths == paths else { return }
        insertedWaveforms = loaded
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
    var audioWaveformSourceKey: [UUID: EditorAudioWaveformSourceKey] {
        guard let prepared = mediaSession.prepared else { return [:] }
        return prepared.payload.inventoriesBySource.reduce(into: [:]) { result, entry in
                let id = entry.key
                let inventory = prepared.payload.inventoriesBySource[id] ?? .empty
                result[id] = EditorAudioWaveformSourceKey(source: prepared.request.screenInput(for: id),
                    sourceRange: inventory.source.audioTimeRange,
                    microphone: id == RecordingSource.primaryID ? prepared.request.microphone : prepared.request.additionalSources[id]?.microphone,
                    microphoneRange: inventory.microphone.audioTimeRange)
            }
    }

    func loadAudioWaveforms() async {
        let expected = audioWaveformSourceKey
        var systems: [UUID: EditorTimelineWaveformData] = [:]
        var microphones: [UUID: EditorTimelineWaveformData] = [:]
        for (id, key) in expected {
            let cachedSystem = systemWaveforms[id]
            let cachedMicrophone = microphoneWaveforms[id]
            async let system = EditorTimelineWaveformLoader.load(input: key.source,
                sourceRange: key.sourceRange, cached: cachedSystem)
            async let microphone = EditorTimelineWaveformLoader.load(input: key.microphone,
                sourceRange: key.microphoneRange, cached: cachedMicrophone)
            let loaded = await (system, microphone)
            guard !Task.isCancelled, audioWaveformSourceKey == expected else { return }
            systems[id] = loaded.0
            microphones[id] = loaded.1
        }
        systemWaveforms = systems
        microphoneWaveforms = microphones
    }

    /// Alt+悬停主片段轨时的裁剪落点：原始 hover x，或在 7pt 内磁吸到最近的
    /// 片段端点/播放头。
    func snappedCutX(width: CGFloat, duration: TimeInterval) -> CGFloat? {
        guard isOptionHeld,
              let point = hoveredTimelineCutPoint,
              point.y >= primaryLaneTop,
              point.y <= primaryLaneTop + primaryTimelineHeight else { return nil }
        let x = point.x + (timelineScrollView?.documentVisibleRect.origin.x ?? 0)
        return EditorPrimaryTimelinePresentation.snappedCutX(
            pointerX: x,
            width: width,
            duration: duration,
            segments: primaryDisplaySegments,
            playbackTime: playbackTime
        )
    }

    var displayedEffectTimeline: ProjectTimeline {
        primaryReorderPreviewTimeline ?? editorStore.previewProject.timeline
    }

    var primaryDisplaySegments: [ResolvedRecordingSegment] {
        if let primaryReorderDraft { return primaryReorderDraft.segments }
        guard let timelineMap else { return [] }
        return EditorPrimaryTimelinePresentation.displaySegments(
            from: timelineMap,
            trimDraft: primaryTrimDraft,
            retimeDraft: primaryRetimeDraft
        )
    }

    func primaryTrimEdge(at localX: CGFloat, segmentWidth: CGFloat) -> RecordingSegmentTrimEdge? {
        // Leave a usable body on short clips; only actual endpoints resize.
        let edgeWidth = min(12, segmentWidth / 3)
        if localX <= edgeWidth { return .left }
        if localX >= segmentWidth - edgeWidth { return .right }
        return nil
    }

    func primarySegmentPointerGesture(segment: ResolvedRecordingSegment,
                                      laneWidth: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(editorTimelineDocumentCoordinateSpace))
            .onChanged { value in
                if primaryPointerSession == nil {
                    guard gestureOwnership.activeIntent == nil else { return }
                    let originX = CGFloat(segment.outputStart / max(duration, 0.001)) * laneWidth
                    let segmentWidth = CGFloat(segment.outputDuration / max(duration, 0.001)) * laneWidth
                    let edge = primaryTrimEdge(at: value.startLocation.x - originX, segmentWidth: segmentWidth)
                    let junction = primarySegmentJunctions.first {
                        let bordersPressedEdge = (edge == .left && $0.nextSegmentID == segment.id)
                            || (edge == .right && $0.previousSegmentID == segment.id)
                        return bordersPressedEdge
                            && abs(CGFloat($0.outputTime / max(duration, 0.001)) * laneWidth - value.startLocation.x) <= 4
                    }
                    primaryPointerSession = PrimarySegmentPointerSession(
                        segment: segment,
                        edge: edge,
                        modifiers: NSEvent.modifierFlags, junction: junction,
                        laneWidth: laneWidth, duration: duration
                    )
                }
                guard var press = primaryPointerSession, press.segment.id == segment.id,
                      !press.modifiers.contains(.option) else { return }
                if !press.isDragging {
                    guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                    press.isDragging = true
                    primaryPointerSession = press
                    hoveredSeamID = nil
                }
                EditorDragFrameCoalescer.shared.submit {
                    guard primaryPointerSession?.id == press.id else { return }
                    if updatePrimaryVisualTransfer(press, location: value.location, translation: value.translation) { return }
                    updatePrimaryPointerDrag(press, translation: value.translation.width, documentX: value.location.x)
                }
            }
            .onEnded { value in
                EditorDragFrameCoalescer.shared.flush()
                guard let press = primaryPointerSession, press.segment.id == segment.id else { return }
                defer { primaryPointerSession = nil; NSCursor.arrow.set() }
                if press.isDragging {
                    if updatePrimaryVisualTransfer(press, location: value.location, translation: value.translation),
                       let target = primaryVisualTransferTarget {
                        let time = primaryVisualTransferTime
                        endPrimarySegmentDrag(); mediaDropLane = nil
                        endTimelineGesture(.primaryMove(segment.id))
                        moveVisualToOverlay(segment.id, at: time, target: target)
                        return
                    }
                    updatePrimaryPointerDrag(press, translation: value.translation.width, documentX: value.location.x)
                    if let edge = press.edge {
                        let intent = gestureOwnership.activeIntent
                        guard intent == .primaryTrim(segment.id, edge) || intent == .primaryRetime(segment.id) else { return }
                        playbackController.endScrubbing()
                        if intent == .primaryRetime(segment.id) { commitPrimaryRetimeDraft() }
                        else { commitPrimaryTrimDraft() }
                        if let intent { endTimelineGesture(intent) }
                    } else {
                        finishPrimarySegmentDrag(segmentID: segment.id, translation: value.translation.width,
                            documentX: value.location.x, laneWidth: press.laneWidth, duration: press.duration)
                        endTimelineGesture(.primaryMove(segment.id))
                    }
                } else if press.modifiers.contains(.option) {
                    let localX = value.startLocation.x - CGFloat(press.segment.outputStart / max(press.duration, 0.001)) * press.laneWidth
                    splitPrimarySegmentAtClick(segment: press.segment, location: CGPoint(x: localX, y: 0),
                        segmentWidth: CGFloat(press.segment.outputDuration / max(press.duration, 0.001)) * press.laneWidth)
                } else if !press.modifiers.contains(.shift), !press.modifiers.contains(.command),
                          let junction = press.junction {
                    hoveredSeamID = nil
                    if junction.hasRemovedSourceGap { restorePrimaryGap(junction) }
                    else { mergePrimarySegments(at: junction) }
                } else {
                    selectPrimarySegment(segment.id, extendingWith: press.modifiers)
                }
            }
    }

    private func updatePrimaryPointerDrag(_ press: PrimarySegmentPointerSession,
                                         translation: CGFloat, documentX: CGFloat) {
        if let edge = press.edge {
            updatePrimaryTrim(segment: press.segment, edge: edge, translation: translation,
                              laneWidth: press.laneWidth, duration: press.duration,
                              isRetime: edge == .right && press.modifiers.contains(.control))
        } else {
            guard beginTimelineGesture(.primaryMove(press.segment.id)) else { return }
            if draggedPrimarySegmentID == nil {
                if !selectedPrimarySegmentIDs.contains(press.segment.id) {
                    selectPrimarySegment(press.segment.id, extendingWith: press.modifiers)
                } else {
                    editorStore.selection = .primarySegment(press.segment.id)
                }
                playbackController.pause(revealingPlayhead: false)
            }
            updatePrimarySegmentDrag(segmentID: press.segment.id, translation: translation,
                documentX: documentX, laneWidth: press.laneWidth, duration: press.duration)
        }
    }

    private func updatePrimaryTrim(segment: ResolvedRecordingSegment, edge: RecordingSegmentTrimEdge,
                                   translation: CGFloat, laneWidth: CGFloat, duration: TimeInterval,
                                   isRetime: Bool) {
        let intent: EditorTimelineGestureIntent = isRetime ? .primaryRetime(segment.id) : .primaryTrim(segment.id, edge)
        guard beginTimelineGesture(intent) else { return }
        if primaryTrimDraft == nil && primaryRetimeDraft == nil { selectPrimarySegment(segment.id) }
        if isRetime {
            let original = primaryRetimeDraft?.original ?? segment
            let rawEndTime = original.outputEnd + TimeInterval(
                translation / max(laneWidth, 1)
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
                      sourceDurations: sourceDurations
                  ) else { return }
            origin = created
        }
        let rawOutputTime = EditorPrimaryTimelinePresentation.trimOutputTime(
            for: origin.original,
            edge: edge,
            translation: translation,
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
        multiSelection = []
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
            selectedPrimarySegmentIDs.formUnion(segments[lower...upper].map(\.id))
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
        multiSelection = []
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
        multiSelection = []
        editorStore.selection = nil
        playbackController.endHoverPreview()
    }

    func splitPrimarySegmentAtPlayhead() {
        guard primarySplitCandidate != nil else { return }
        performPrimarySplit(at: primarySplitTime)
    }

    /// The Cut tool's entry: the caller has already validated the time.
    func splitPrimarySegment(atCutTime time: TimeInterval) {
        performPrimarySplit(at: time)
    }

    /// A cut changes ownership, not the position of the retained pictures.
    /// Commit both pieces and the right-hand selection atomically, preventing
    /// lane membership/selection animations from shrinking and sliding them.
    /// Both retained pieces remain visible at their original hit areas.
    private func performPrimarySplit(at splitTime: TimeInterval) {
        let rightID = UUID()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        do {
            try withTransaction(transaction) {
                try editorStore.splitPrimarySegment(
                    atOutputTime: splitTime,
                    sourceDurations: sourceDurations,
                    newRightSegmentID: rightID,
                    actionName: "分割主片段"
                )
                hoveredPrimarySegmentID = nil
                selectPrimarySegment(rightID)
                seekTimeline(to: min(splitTime, timelineDuration))
            }
        } catch {
            onError(error.localizedDescription)
        }
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
        performPrimarySplit(at: outputTime)
    }

    func movePrimarySegment(_ draggedID: UUID, toIndex destination: Int) {
        guard let map = timelineMap,
              let oldIndex = map.segments.firstIndex(where: { $0.id == draggedID }),
              map.segments.indices.contains(destination), destination != oldIndex else { return }
        do {
            try editorStore.movePrimarySegment(
                id: draggedID,
                toIndex: destination,
                sourceDurations: sourceDurations,
                actionName: "调整主片段顺序"
            )
            primaryTrimDraft = nil
            primaryRetimeDraft = nil
            hoveredPrimarySegmentID = nil
            selectPrimarySegment(draggedID)
            if let updatedMap = try? EditorPrimaryTimelinePresentation.timelineMap(
                sourceDurations: sourceDurations,
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
            guard let map = timelineMap,
                  let draft = PrimarySegmentReorderDraft(segmentID: segmentID, selectedIDs: selectedPrimarySegmentIDs, segments: map.segments)
            else { return }
            timelineSnap.reset()
            primaryReorderDraft = draft
            draggedPrimarySegmentID = segmentID
        }
        guard draggedPrimarySegmentID == segmentID, var draft = primaryReorderDraft else { return }
        let segment = draft.original
        let rawDelta = Double(translation / max(laneWidth, 1)) * duration
        let delta = magneticDelta(rawDelta, start: segment.outputStart,
            end: segment.outputEnd, mode: .move, width: laneWidth, duration: duration)
        primarySegmentDragTranslation = CGFloat(delta / max(duration, 0.001)) * laneWidth
        primarySegmentDragDocumentX = documentX + primarySegmentDragTranslation - translation
        draft.update(translation: delta)
        if draft.segments != primaryReorderDraft?.segments {
            primaryReorderDraft = draft
            // Reuse the same pure remapping as the commit, only when crossing
            // a slot. Do not rebuild playback media or create undo steps while
            // the pointer is still moving.
            primaryReorderPreviewTimeline = try? ProjectTimelineEditing.movePrimarySegments(
                in: editorStore.previewProject.timeline, segmentIDs: draft.segmentIDs,
                toIndex: draft.destination, sourceDurations: sourceDurations)
        }
    }

    func primaryFloatingTranslation(for id: UUID, width: CGFloat, duration: TimeInterval) -> CGFloat {
        if primaryVisualTransferTarget != nil, draggedPrimarySegmentID == id { return primarySegmentDragTranslation }
        return primaryReorderDraft?.floatingTranslation(for: id, translation: primarySegmentDragTranslation,
            laneWidth: width, duration: duration) ?? 0
    }

    func finishPrimarySegmentDrag(
        segmentID: UUID,
        translation: CGFloat,
        documentX: CGFloat,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) {
        defer { endPrimarySegmentDrag() }
        guard draggedPrimarySegmentID == segmentID, laneWidth > 0, duration > 0 else { return }
        updatePrimarySegmentDrag(segmentID: segmentID, translation: translation,
            documentX: documentX, laneWidth: laneWidth, duration: duration)
        guard let draft = primaryReorderDraft,
              timelineMap?.segments == draft.originalSegments else { return }
        // Commit the exact order already displayed; never pick another target
        // from neighbour positions which have moved in the meantime.
        guard draft.segments.map(\.id) != draft.originalSegments.map(\.id) else { return }
        do {
            let timeline = try ProjectTimelineEditing.movePrimarySegments(in: editorStore.project.timeline,
                segmentIDs: draft.segmentIDs, toIndex: draft.destination, sourceDurations: sourceDurations)
            try editorStore.replaceTimeline(with: timeline, actionName: "调整主片段顺序")
            selectedPrimarySegmentIDs = draft.segmentIDs
            editorStore.selection = .primarySegment(segmentID)
            if let moved = draft.segments.first(where: { $0.id == segmentID }) { seekTimeline(to: moved.outputStart) }
        } catch { onError(error.localizedDescription) }
    }

    func removePrimarySegment(id: UUID) {
        let segmentIDs = EditorTimelineSelectionPresentation.primarySegmentIDs(
            in: editorStore.project.timeline.sourceSequence
        )
        guard let removedIndex = segmentIDs.firstIndex(of: id) else { return }
        do {
            try editorStore.removePrimarySegment(
                id: id,
                sourceDurations: sourceDurations,
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
                sourceDurations: sourceDurations,
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
                sourceDurations: sourceDurations,
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
