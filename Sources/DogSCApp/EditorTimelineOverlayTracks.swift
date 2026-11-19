import AVFoundation
import RecorderCore
import SwiftUI

enum EditorOverlayTimingEditing {
    static func adjustedTiming(
        original: OverlayTiming,
        mode: EditorMotionTimelineEditMode,
        delta: TimeInterval,
        timelineDuration: TimeInterval,
        minimumLeadingStartTime: TimeInterval = 0
    ) -> OverlayTiming {
        guard delta.isFinite, timelineDuration.isFinite, timelineDuration > 0 else {
            return original
        }
        let minimumDuration = min(0.08, max(original.duration, 0.001))
        var timing = original
        switch mode {
        case .move:
            timing.startTime = min(
                max(original.startTime + delta, 0),
                max(timelineDuration - original.duration, 0)
            )
        case .leading:
            let end = min(max(original.endTime, minimumDuration), timelineDuration)
            let lowerBound = min(
                max(minimumLeadingStartTime, 0),
                end - minimumDuration
            )
            timing.startTime = min(
                max(original.startTime + delta, lowerBound),
                end - minimumDuration
            )
            timing.duration = end - timing.startTime
        case .trailing:
            let end = min(
                max(original.endTime + delta, original.startTime + minimumDuration),
                timelineDuration
            )
            timing.duration = end - original.startTime
        }
        return timing
    }

}

extension EditorTimelineView {
    /// EDT-061: built once per change of the added-material clips and shared
    /// by every lane, label and height lookup in a render (previously each
    /// lookup rebuilt and re-sorted every clip, hundreds of times per frame).
    var overlayTimelineClips: [TimelineOverlayClip] {
        derivedPresentationCache.overlayClips(
            revision: primaryReorderPreviewTimeline == nil ? editorStore.previewRevision : nil,
            key: {
                let timeline = primaryReorderPreviewTimeline ?? editorStore.interactionBaseProject.timeline
                return .init(mosaics: timeline.mosaicClips, stickers: timeline.stickerClips, animations: timeline.animationClips,
                             animationAssets: timeline.mediaAssets.filter { $0.kind == .animation },
                             audio: timeline.audioClips, subtitles: timeline.subtitleCues, videos: timeline.videoClips)
            },
            build: { buildOverlayTimelineClips(from: primaryReorderPreviewTimeline ?? editorStore.interactionBaseProject.timeline) }
        )
    }

    private func buildOverlayTimelineClips(from timeline: ProjectTimeline) -> [TimelineOverlayClip] {
        let mosaics = timeline.mosaicClips.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: appLocalized($0.style == .spotlight ? "突出" : "柔化"),
                kind: .mosaic,
                layerIndex: -1
            )
        }
        let orderedStickers = timeline.stickerClips
            .sorted {
                $0.layerIndex == $1.layerIndex
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.layerIndex < $1.layerIndex
            }
        let stickers = orderedStickers.enumerated().map { rank, sticker in
            TimelineOverlayClip(
                id: sticker.id,
                timing: sticker.timing,
                title: orderedStickers.count > 1
                    ? String(format: appLocalized("贴图 · 层 %lld"), Int64(rank + 1))
                    : appLocalized("贴图"),
                kind: .sticker,
                layerIndex: sticker.layerIndex,
                layer: sticker.layerIndex
            )
        }
        let motionNames = HTMLMotionEditing.DisplayNames(assets: timeline.mediaAssets)
        let animations = timeline.animationClips.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: motionNames.name(for: $0.sourcePath),
                kind: .animation,
                layerIndex: 10_000 + $0.layerIndex,
                layer: $0.layerIndex
            )
        }
        let audio = timeline.audioClips.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: appLocalized($0.kind == .music ? "音乐" : "音效"),
                kind: .audio,
                layerIndex: 20_000,
                sourcePath: $0.sourcePath,
                sourceStart: $0.sourceStart,
                isEffect: $0.kind == .effect,
                audioLane: $0.lane
            )
        }
        let subtitles = timeline.subtitleCues.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: $0.text,
                kind: .subtitle,
                layerIndex: 30_000
            )
        }
        let videos = timeline.videoClips.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: URL(fileURLWithPath: $0.sourcePath).deletingPathExtension().lastPathComponent,
                kind: .video,
                layerIndex: -2,
                layer: $0.layerIndex
            )
        }
        return (videos + mosaics + stickers + animations + audio + subtitles).sorted {
            if $0.timing.startTime != $1.timing.startTime {
                return $0.timing.startTime < $1.timing.startTime
            }
            if $0.layerIndex != $1.layerIndex {
                return $0.layerIndex < $1.layerIndex
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Greedy interval packing gives every simultaneously visible overlay its
    /// own row while allowing non-overlapping clips to reuse space. No clip is
    /// hidden behind another merely because their authored times coincide.
    /// Greedy interval packing within one lane: simultaneous clips get their
    /// own row, non-overlapping clips share one.
    func laneRows(_ lane: TimelineLane) -> [[TimelineOverlayClip]] {
        let clips = overlayTimelineClips
        return derivedPresentationCache.laneRows(lane) { packLaneRows(lane, clips: clips) }
    }

    private func packLaneRows(_ lane: TimelineLane, clips: [TimelineOverlayClip]) -> [[TimelineOverlayClip]] {
        var rows: [[TimelineOverlayClip]] = []
        var rowEnds: [TimeInterval] = []
        for clip in clips where lane.contains(clip) {
            // Touching edges share a row; a few milliseconds of float drift
            // after snapping must not push a clip onto a second row.
            if let row = rowEnds.firstIndex(where: { $0 <= clip.timing.startTime + 0.005 }) {
                rows[row].append(clip)
                rowEnds[row] = clip.timing.endTime
            } else {
                rows.append([clip])
                rowEnds.append(clip.timing.endTime)
            }
        }
        return rows
    }

    var overlayTimelineRows: [[TimelineOverlayClip]] { laneRows(.effects) }

    /// Mockup rows: 24 pt clips 4 pt apart with 4 pt above and below, so a
    /// one-row lane is 32 pt. A group header is 26 pt, the "more" row 24 pt.
    /// All scale with the panel (`trackScale`).
    func baseLaneHeight(_ lane: TimelineLane) -> CGFloat {
        switch lane {
        // One 8-pt grid: every row (group headers included) is 32, clips sit
        // 4 in from each edge (timeline-lanes.html).
        case .groupHeader: 32
        case .moreLayers: 32
        default: CGFloat(max(laneRows(lane).count, 1) * 32)
        }
    }

    func laneHeight(_ lane: TimelineLane) -> CGFloat { baseLaneHeight(lane) * trackScale }
    var clipRowHeight: CGFloat { 24 * trackScale }
    var clipRowSpacing: CGFloat { 8 * trackScale }
    var clipRowInset: CGFloat { 4 * trackScale }

    // MARK: Groups (画面叠加 / 柔化与突出)

    /// Expanded, a group shows at most three layers; the rest fold into a
    /// "还有 N 层 · 展开" row.
    static var maximumVisibleOverlayLayers: Int { 3 }

    var collapsedLaneGroups: Set<String> {
        Set(collapsedTimelineGroupsRaw.split(separator: ",").map(String.init))
    }

    func isLaneGroupCollapsed(_ group: TimelinePostLane) -> Bool {
        collapsedLaneGroups.contains(group.rawValue)
    }

    func toggleLaneGroup(_ group: TimelinePostLane) {
        cancelActiveTimelineGesture()
        var groups = collapsedLaneGroups
        if groups.contains(group.rawValue) { groups.remove(group.rawValue) } else { groups.insert(group.rawValue) }
        withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.24)) {
            collapsedTimelineGroupsRaw = groups.sorted().joined(separator: ",")
            if group == .layers { showsAllOverlayLayers = false }
        }
    }

    /// Clips a group's collapsed row draws as occupancy bands.
    func laneGroupClips(_ group: TimelinePostLane) -> [TimelineOverlayClip] {
        overlayTimelineClips.filter { clip in
            switch group {
            case .layers: clip.kind == .video || clip.kind == .sticker || clip.kind == .animation
            case .effects: clip.kind == .mosaic
            default: false
            }
        }
    }

    /// Part of the timeline layout key: anything that changes lane rows.
    var laneGroupLayoutKey: String {
        collapsedTimelineGroupsRaw + (showsAllOverlayLayers ? "|all" : "")
    }

    func isPostLaneHidden(_ group: TimelinePostLane) -> Bool {
        group == .effects ? !showsOverlayTimeline
            : derivedPresentationCache.hiddenPostLanes(hiddenPostLanesRaw).contains(group.rawValue)
    }

    func setPostLane(_ group: TimelinePostLane, visible: Bool) {
        var hidden = Set(hiddenPostLanesRaw.split(separator: ",").map(String.init))
        if visible { hidden.remove(group.rawValue) } else { hidden.insert(group.rawValue) }
        withAnimation(SpringMotion.settle) { hiddenPostLanesRaw = hidden.sorted().joined(separator: ",") }
    }

    func postLaneClipCount(_ group: TimelinePostLane) -> Int {
        laneSummary.counts[group] ?? 0
    }

    private var laneSummary: EditorTimelineDerivedPresentationCache.LaneSummary {
        derivedPresentationCache.laneSummary(for: overlayTimelineClips)
    }

    /// Visual layers from top (front) to bottom (back).
    var visualLayers: [Int] { laneSummary.visualLayers }

    var audioLanes: [Int] { laneSummary.audioLanes }

    /// Above the recording: subtitles, then the 画面叠加 group (picture
    /// layers front to back, at most three unless expanded).
    var upperLanes: [TimelineLane] {
        var lanes: [TimelineLane] = []
        if !isPostLaneHidden(.subtitles) && postLaneClipCount(.subtitles) > 0 { lanes.append(.subtitles) }
        let layers = visualLayers.isEmpty && timelineMediaDragActive ? [0] : visualLayers
        if (!isPostLaneHidden(.layers) || timelineMediaDragActive), !layers.isEmpty {
            lanes.append(.groupHeader(.layers))
            if !isLaneGroupCollapsed(.layers) || timelineMediaDragActive {
                let limit = Self.maximumVisibleOverlayLayers
                if layers.count > limit, !showsAllOverlayLayers {
                    lanes += layers.prefix(limit).map(TimelineLane.layer)
                    lanes.append(.moreLayers(layers.count - limit))
                } else {
                    lanes += layers.map(TimelineLane.layer)
                }
            }
        }
        return lanes
    }

    /// Below the lens lanes: the 柔化与突出 group, then audio rows.
    var lowerLanes: [TimelineLane] {
        var lanes: [TimelineLane] = []
        if !isPostLaneHidden(.effects) && postLaneClipCount(.effects) > 0 {
            lanes.append(.groupHeader(.effects))
            if !isLaneGroupCollapsed(.effects) { lanes.append(.effects) }
        }
        if !isPostLaneHidden(.audio) { lanes += audioLanes.map(TimelineLane.audio) }
        return lanes
    }

    var postLanesHeight: CGFloat { (upperLanes + lowerLanes).reduce(0) { $0 + laneHeight($1) } }

    /// Where the recording lane begins (below the ruler and upper lanes).
    var primaryLaneTop: CGFloat {
        timelineRulerHeight + upperLanes.reduce(0) { $0 + laneHeight($1) }
    }

    /// The row name says what is on it.
    func laneTitle(_ lane: TimelineLane) -> String {
        let kinds = Set(overlayTimelineClips.filter(lane.contains).map(\.kind))
        switch lane {
        case .subtitles: return "字幕"
        case .effects: return "柔化与突出"
        case let .groupHeader(group): return group == .effects ? "柔化与突出" : "画面叠加"
        case .moreLayers: return "画面叠加"
        case .layer:
            if kinds == [.video] { return "视频" }
            if kinds == [.sticker] { return "图片" }
            if kinds == [.animation] { return "动效" }
            return "画面"
        case .audio:
            let clips = overlayTimelineClips.filter(lane.contains)
            if clips.allSatisfy({ !$0.isEffect }) { return "音乐" }
            if clips.allSatisfy(\.isEffect) { return "音效" }
            return "音频"
        }
    }

    /// A lane takes the colour of what is on it (mixed picture layers stay neutral teal).
    func lanePalette(_ lane: TimelineLane) -> EditorConsolePalette {
        let clips = overlayTimelineClips.filter(lane.contains)
        guard let first = clips.first else { return EditorConsole.Track.overlay }
        let same = clips.allSatisfy { $0.kind == first.kind && $0.isEffect == first.isEffect }
        return same ? EditorConsole.palette(for: first.kind, isEffect: first.isEffect) : EditorConsole.Track.overlay
    }

    func laneSymbol(_ lane: TimelineLane) -> String {
        switch laneTitle(lane) {
        case "视频": "film"
        case "图片": "photo"
        case "动效": "sparkles"
        case "字幕": "captions.bubble.fill"
        case "柔化与突出": "scope"
        case "音乐": "music.note"
        case "音效": "speaker.wave.2"
        case "音频": "waveform"
        default: "square.3.layers.3d"
        }
    }

    /// Document y of a lane's top edge.
    func laneTop(_ lane: TimelineLane) -> CGFloat {
        if let i = upperLanes.firstIndex(of: lane) {
            return timelineRulerHeight + upperLanes[..<i].reduce(0) { $0 + laneHeight($1) }
        }
        if let i = lowerLanes.firstIndex(of: lane) {
            let lowerStart = timelineCanvasHeight - lowerLanes.reduce(0) { $0 + laneHeight($1) }
            return lowerStart + lowerLanes[..<i].reduce(0) { $0 + laneHeight($1) }
        }
        return 0
    }

    func lane(of clip: TimelineOverlayClip) -> TimelineLane? {
        switch clip.kind {
        case .video, .sticker, .animation: .layer(clip.layer)
        case .audio: .audio(clip.audioLane)
        case .subtitle: .subtitles
        case .mosaic: .effects
        }
    }

    /// Where a clip moved vertically to document y would land: an existing
    /// compatible track, or a new one above/below the stack.
    func laneDropTarget(for clip: TimelineOverlayClip, atY y: CGFloat) -> EditorDropLane? {
        switch clip.kind {
        case .video, .sticker, .animation:
            if y >= primaryLaneTop, y < primaryLaneTop + primaryTimelineHeight {
                return canMoveVisualToMain(clip.id) && overlayGroupOriginals.isEmpty ? .mainTrack : nil
            }
            guard y < primaryLaneTop else { return nil }
            let layers = upperLanes.filter { if case .layer = $0 { true } else { false } }
            guard let first = layers.first else { return nil }
            if y < laneTop(first) { return .newLayer }
            for lane in layers where y >= laneTop(lane) && y < laneTop(lane) + laneHeight(lane) {
                if case let .layer(n) = lane { return .layer(n) }
            }
            return .newLayerBelow
        case .audio:
            let lanes = lowerLanes.filter { if case .audio = $0 { true } else { false } }
            guard let first = lanes.first, let last = lanes.last else { return nil }
            if y < laneTop(first) { if case let .audio(n) = first { return .audio(n) } }
            for lane in lanes where y >= laneTop(lane) && y < laneTop(lane) + laneHeight(lane) {
                if case let .audio(n) = lane { return .audio(n) }
            }
            return y >= laneTop(last) + laneHeight(last) ? .newAudio : nil
        default:
            return nil
        }
    }

    /// Row centre of a clip inside its lane, in document coordinates.
    func clipCenterY(_ clip: TimelineOverlayClip) -> CGFloat? {
        guard let lane = lane(of: clip),
              let row = laneRows(lane).firstIndex(where: { $0.contains { $0.id == clip.id && $0.kind == clip.kind } })
        else { return nil }
        return laneTop(lane) + clipRowInset + CGFloat(row) * (clipRowHeight + clipRowSpacing) + clipRowHeight / 2
    }

    /// The lane a library item dropped on this lane should go to.
    func dropLane(for lane: TimelineLane, assetID: UUID) -> EditorDropLane {
        let kind = editorStore.project.timeline.mediaAssets.first { $0.id == assetID }?.kind
        switch (lane, kind) {
        case let (.layer(n), .video?), let (.layer(n), .image?), let (.layer(n), .animation?): return .layer(n)
        case let (.audio(n), .audio?): return .audio(n)
        default: return .newLayer
        }
    }

    /// Swaps a whole layer with the next one above (+1) or below (-1).
    func moveLayer(_ layer: Int, toward direction: Int) {
        let order = visualLayers.sorted()
        guard let index = order.firstIndex(of: layer), order.indices.contains(index + direction) else { return }
        let other = order[index + direction]
        commitTimelineEdit(editorStore, action: "调整层级") { timeline in
            func swap(_ value: Int) -> Int { value == layer ? other : value == other ? layer : value }
            for i in timeline.stickerClips.indices { timeline.stickerClips[i].layerIndex = swap(timeline.stickerClips[i].layerIndex) }
            for i in timeline.animationClips.indices { timeline.animationClips[i].layerIndex = swap(timeline.animationClips[i].layerIndex) }
            for i in timeline.videoClips.indices { timeline.videoClips[i].layerIndex = swap(timeline.videoClips[i].layerIndex) }
        }
    }

    enum LayerMove { case front, forward, backward, back }

    /// Moves one clip onto its own layer in front of / behind its neighbours.
    func moveClip(_ clip: TimelineOverlayClip, _ move: LayerMove) {
        let order = visualLayers.sorted()
        let target: Int
        switch move {
        case .front: target = (order.last ?? 0) * 2 + 1
        case .back: target = (order.first ?? 0) * 2 - 1
        case .forward: target = (order.first { $0 > clip.layer } ?? clip.layer) * 2 + 1
        case .backward: target = (order.last { $0 < clip.layer } ?? clip.layer) * 2 - 1
        }
        commitTimelineEdit(editorStore, action: "调整层级") { timeline in
            for i in timeline.stickerClips.indices { timeline.stickerClips[i].layerIndex *= 2 }
            for i in timeline.animationClips.indices { timeline.animationClips[i].layerIndex *= 2 }
            for i in timeline.videoClips.indices { timeline.videoClips[i].layerIndex *= 2 }
            switch clip.kind {
            case .sticker: if let i = timeline.stickerClips.firstIndex(where: { $0.id == clip.id }) { timeline.stickerClips[i].layerIndex = target }
            case .animation: if let i = timeline.animationClips.firstIndex(where: { $0.id == clip.id }) { timeline.animationClips[i].layerIndex = target }
            case .video: if let i = timeline.videoClips.firstIndex(where: { $0.id == clip.id }) { timeline.videoClips[i].layerIndex = target }
            default: break
            }
            timeline.compactVisualLayers()
        }
    }

    /// Moves an audio clip to another audio row (a new row past the last one).
    func moveAudioClip(_ clip: TimelineOverlayClip, by delta: Int) {
        commitTimelineEdit(editorStore, action: "调整音轨") { timeline in
            guard let i = timeline.audioClips.firstIndex(where: { $0.id == clip.id }) else { return }
            timeline.audioClips[i].lane = max(timeline.audioClips[i].lane + delta, 0)
        }
    }

    func trimMosaicClip(
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        atTime time: TimeInterval
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        var clip = timeline.mosaicClips[index]
        guard trimOverlayTiming(&clip.timing, edge: edge, atTime: time) else {
            return
        }
        timeline.mosaicClips[index] = clip
        replaceOverlayTimeline(timeline, actionName: clip.style == .spotlight ? "修剪突出" : "修剪柔化")
    }

    func trimStickerClip(
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        atTime time: TimeInterval
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        var clip = timeline.stickerClips[index]
        let previousStart = clip.timing.startTime
        guard trimOverlayTiming(&clip.timing, edge: edge, atTime: time) else {
            return
        }
        clip.sourceStart += (clip.timing.startTime - previousStart) * clip.playbackRate
        timeline.stickerClips[index] = clip
        replaceOverlayTimeline(timeline, actionName: "修剪贴图")
    }

    private func trimOverlayTiming(
        _ timing: inout OverlayTiming,
        edge: RecordingSegmentTrimEdge,
        atTime time: TimeInterval
    ) -> Bool {
        guard time > timing.startTime + 0.01,
              time < timing.endTime - 0.01 else { return false }
        switch edge {
        case .left:
            let end = timing.endTime
            timing.startTime = time
            timing.duration = end - time
        case .right:
            timing.duration = time - timing.startTime
        }
        return true
    }

    private func replaceOverlayTimeline(
        _ timeline: ProjectTimeline,
        actionName: String
    ) {
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func splitMosaicClip(id: UUID, atTime time: TimeInterval) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        let original = timeline.mosaicClips[index]
        guard time > original.timing.startTime + 0.01,
              time < original.timing.endTime - 0.01 else { return }
        var left = original
        left.timing.duration = time - original.timing.startTime
        var right = original
        right.id = UUID()
        right.timing = OverlayTiming(
            startTime: time,
            duration: original.timing.endTime - time
        )
        timeline.mosaicClips.replaceSubrange(index...index, with: [left, right])
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: original.style == .spotlight ? "分割突出" : "分割柔化")
            editorStore.selection = .mosaic(right.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func splitStickerClip(id: UUID, atTime time: TimeInterval) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        let original = timeline.stickerClips[index]
        guard time > original.timing.startTime + 0.01,
              time < original.timing.endTime - 0.01 else { return }
        var left = original
        left.timing.duration = time - original.timing.startTime
        var right = original
        right.id = UUID()
        right.timing = OverlayTiming(
            startTime: time,
            duration: original.timing.endTime - time
        )
        right.sourceStart += left.timing.duration * original.playbackRate
        timeline.stickerClips.replaceSubrange(index...index, with: [left, right])
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "分割贴图")
            editorStore.selection = .sticker(right.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func combinedOverlayTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        postLaneTimeline(.effects, width: width, duration: duration)
    }

    func postLaneTimeline(_ lane: TimelineLane, width: CGFloat, duration: TimeInterval) -> some View {
        let rows = laneRows(lane)
        let createRange = lane == .subtitles ? subtitleCreateRange : lane == .effects ? overlayCreateRange : nil
        return ZStack(alignment: .topLeading) {
            timelineLaneSurface(isFocused: rows.contains { $0.contains { editorStore.selection == $0.kind.selection(id: $0.id) } })
            switch lane {
            case .effects:
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(overlayTrackGesture(clips: [], timelineWidth: width, duration: duration))
            case .subtitles:
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(subtitleCreateGesture(width: width, duration: duration))
            case .audio:
                Color.clear
                    .frame(width: width, height: laneHeight(lane))
                    .contentShape(Rectangle())
                    .gesture(timelineMarqueeGesture(width: width, duration: duration))
            default:
                // Empty space belongs to the timeline background, which
                // draws the selection marquee.
                EmptyView()
            }

            VStack(spacing: clipRowSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, clips in
                    overlayClipRow(clips: clips, width: width, duration: duration,
                                   createsOnEmptyDrag: lane == .effects,
                                   drawsMarqueeOnEmptyDrag: lane.group == .audio)
                }
            }
            .padding(.vertical, clipRowInset)
            // Like the zoom and 3D lanes: a "+" over empty space where a
            // click would create a subtitle (or an effect).
            if lane == .subtitles || lane == .effects {
                EditorTimelineCreateIndicator(
                    hover: laneHover,
                    x: { hover in
                        guard createRange == nil, let point = hover.post[lane] else { return nil }
                        let time = Double(point.x / max(width, 1)) * duration
                        let occupied = rows.joined().contains {
                            time >= $0.timing.startTime - 0.05 && time <= $0.timing.endTime + 0.05
                        }
                        return occupied ? nil : point.x
                    },
                    fill: EditorTimelineHue.forLane(lane).solid,
                    ink: .white,
                    size: 18
                )
                .frame(height: laneHeight(lane))
            }
            if let range = createRange, range.upperBound - range.lowerBound > 0.01 {
                RoundedRectangle(cornerRadius: 6)
                    .fill(EditorTimelineHue.forLane(lane).solid.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(EditorTimelineHue.forLane(lane).solid, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .frame(width: max(CGFloat((range.upperBound - range.lowerBound) / duration) * width, 3), height: clipRowHeight)
                    .offset(x: CGFloat(range.lowerBound / duration) * width, y: clipRowInset)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: laneHeight(lane), alignment: .topLeading)
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard lane == .subtitles || lane == .effects else { return }
            switch phase {
            case let .active(location): laneHover.post[lane] = location
            case .ended: laneHover.post[lane] = nil
            }
        }
        .overlay { laneDropHighlight(lane) }
        .zIndex(overlayTimelineDrag.map { drag in rows.contains { $0.contains { $0.id == drag.id } } } == true ? 5 : 0)

    }

    /// Shows where a dragged clip or library item will land.
    @ViewBuilder
    func laneDropHighlight(_ lane: TimelineLane) -> some View {
        let hue = EditorTimelineHue.forLane(lane)
        let layers = upperLanes.filter { if case .layer = $0 { true } else { false } }
        let audio = lowerLanes.filter { if case .audio = $0 { true } else { false } }
        ZStack(alignment: .top) {
            if mediaDropLane == lane || overlayDragTarget == .layer(layerNumber(lane) ?? .min)
                || overlayDragTarget == .audio(audioNumber(lane) ?? .min) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hue.solid.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(hue.solid, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .padding(1)
            }
            if overlayDragTarget == .newLayer, lane == layers.first {
                insertionLine(hue.solid, label: "新建轨道").frame(maxHeight: .infinity, alignment: .top)
            }
            if overlayDragTarget == .newLayerBelow, lane == layers.last {
                insertionLine(hue.solid, label: "新建轨道").frame(maxHeight: .infinity, alignment: .bottom)
            }
            if overlayDragTarget == .newAudio, lane == audio.last {
                insertionLine(hue.solid, label: "新建音轨").frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    private func layerNumber(_ lane: TimelineLane) -> Int? { if case let .layer(n) = lane { n } else { nil } }
    private func audioNumber(_ lane: TimelineLane) -> Int? { if case let .audio(n) = lane { n } else { nil } }

    private func insertionLine(_ color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Text(appLocalized(label))
                .font(.appUI(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(color))
            Rectangle().fill(color).frame(height: 2)
        }
        .padding(.leading, 4)
    }

    /// Drag across the subtitle lane to add a subtitle for that span (a click
    /// adds two seconds); it never overlaps an existing subtitle.
    func subtitleCreateGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        func time(_ x: CGFloat) -> TimeInterval { min(max(Double(x / max(width, 1)) * duration, 0), duration) }
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = time(value.startLocation.x), b = time(value.location.x)
                subtitleCreateRange = min(a, b)...max(a, b)
            }
            .onEnded { value in
                let range = subtitleCreateRange ?? time(value.startLocation.x)...time(value.startLocation.x)
                subtitleCreateRange = nil
                var start = range.lowerBound
                var end = range.upperBound - range.lowerBound < 0.3 ? start + 2 : range.upperBound
                let cues = editorStore.project.timeline.subtitleCues
                if let previous = cues.last(where: { $0.timing.startTime <= start && $0.timing.endTime > start }) {
                    start = previous.timing.endTime
                }
                if let next = cues.first(where: { $0.timing.startTime > start }) { end = min(end, next.timing.startTime) }
                end = min(end, duration)
                guard end - start > 0.1 else { return }
                let cue = SubtitleCue(timing: OverlayTiming(startTime: start, duration: end - start), text: appLocalized("新字幕"))
                var timeline = editorStore.project.timeline
                timeline.subtitleCues.append(cue)
                timeline.subtitleCues.sort { $0.timing.startTime < $1.timing.startTime }
                do {
                    try editorStore.replaceTimeline(with: timeline, actionName: "添加字幕")
                    editorStore.selection = .subtitle(cue.id)
                } catch {
                    onError(error.localizedDescription)
                }
            }
    }

    /// Right-click anywhere on the timeline: the everyday edits in one place.
    @ViewBuilder
    func timelineContextMenu() -> some View {
        if groupSelectionCount > 1 {
            Button(String(format: appLocalized("删除所选（%lld 项）"), Int64(groupSelectionCount)), role: .destructive) {
                removeGroupSelection()
            }
            Divider()
        }
        Button(appLocalized("粘贴")) { pasteTimelineClip(at: clipboardContextTime ?? clipboardInsertionTime) }
            .disabled(!EditorClipClipboard.shared.hasClip)
        Button(appLocalized("在播放头分割")) { splitCurrentTimelineSelectionAtPlayhead() }
            .disabled(!canSplitCurrentTimelineSelectionAtPlayhead)
        Divider()
        Button(appLocalized("在播放头添加字幕")) { editorStore.addSubtitleAtPlayhead() }
        Button(appLocalized("在播放头插入黑场")) { insertBlackAtPlayhead() }
        Button(appLocalized("整理轨道")) {
            commitTimelineEdit(editorStore, action: "整理轨道") { $0.organizeTracks() }
        }
        Divider()
        Button(appLocalized("显示全部轨道")) {
            withAnimation(SpringMotion.settle) {
                visibleTracks.formUnion([.zoom, .screenMotion, .cameraMotion, .overlays])
                hiddenPostLanesRaw = ""
            }
        }
    }

    /// Stacking and track moves for a clip, like an editor's arrange menu.
    @ViewBuilder
    func clipArrangeMenu(_ clip: TimelineOverlayClip) -> some View {
        if groupSelectionCount > 1, multiSelection.contains(clip.kind.selection(id: clip.id)) {
            Button(String(format: appLocalized("删除所选（%lld 项）"), Int64(groupSelectionCount)), role: .destructive) {
                removeGroupSelection()
            }
            Divider()
        }
        Button(appLocalized("在播放头分割")) {
            editorStore.selection = clip.kind.selection(id: clip.id)
            splitCurrentTimelineSelectionAtPlayhead()
        }
        Button(appLocalized("删除"), role: .destructive) {
            editorStore.selection = clip.kind.selection(id: clip.id)
            removeCurrentTimelineSelection()
        }
        Divider()
        switch clip.kind {
        case .video, .sticker, .animation:
            Button(appLocalized("置于顶层")) { moveClip(clip, .front) }
            Button(appLocalized("上移一层")) { moveClip(clip, .forward) }
            Button(appLocalized("下移一层")) { moveClip(clip, .backward) }
            Button(appLocalized("置于底层")) { moveClip(clip, .back) }
        case .audio:
            Button(appLocalized("移到上一条音轨")) { moveAudioClip(clip, by: -1) }.disabled(clip.audioLane == 0)
            Button(appLocalized("移到下一条音轨")) { moveAudioClip(clip, by: 1) }
        default:
            EmptyView()
        }
        Divider()
        Button(appLocalized("整理轨道")) {
            commitTimelineEdit(editorStore, action: "整理轨道") { $0.organizeTracks() }
        }
    }

    /// Only clips near the viewport become views. A long transcript can put
    /// hundreds of subtitles in one row; materializing all of them made every
    /// selection, hover and drag re-diff the whole document. The row gesture,
    /// hover and menu still read the complete `clips` array.
    private func viewportClips(
        _ clips: [TimelineOverlayClip],
        width: CGFloat,
        duration: TimeInterval
    ) -> [TimelineOverlayClip] {
        let range = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        let dragged = overlayTimelineDrag?.id
        let selected = editorStore.selection
        let live = editorStore.timelinePreview.project(for: editorStore.interaction?.id)?.timeline
        return clips.compactMap { source in
            var clip = source
            let selection = clip.kind.selection(id: clip.id)
            if let live, clip.id == dragged || selection == selected || overlayGroupOriginals[selection] != nil,
               let timing = persistedOverlayTiming(kind: clip.kind, id: clip.id, timeline: live) {
                clip.timing = timing
                if clip.kind == .subtitle, let cue = live.subtitleCues.first(where: { $0.id == clip.id }) { clip.title = cue.text }
                if let drag = overlayTimelineDrag, drag.id == clip.id, drag.mode == .leading {
                    clip.sourceStart = max(0, drag.sourceStart
                        + (timing.startTime - drag.original.startTime) * drag.playbackRate)
                }
            }
            guard (clip.timing.endTime >= range.lowerBound && clip.timing.startTime <= range.upperBound)
                || clip.id == dragged || selection == selected else { return nil }
            return clip
        }
    }

    private func overlayClipRow(
        clips: [TimelineOverlayClip],
        width: CGFloat,
        duration: TimeInterval,
        createsOnEmptyDrag: Bool,
        drawsMarqueeOnEmptyDrag: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Match the zoom lane's layout contract: the lane itself owns the
            // complete 0...duration coordinate space.  Offset clip views are
            // only visual occupants of that space; their intrinsic widths must
            // never determine the row origin or its gesture coordinates.
            Color.clear
                .frame(width: width, height: clipRowHeight)
                .allowsHitTesting(false)

            ForEach(viewportClips(clips, width: width, duration: duration)) { clip in
                let x = CGFloat(clip.timing.startTime / max(duration, 0.001)) * width
                let clipWidth = max(
                    CGFloat(clip.timing.duration / max(duration, 0.001)) * width,
                    3
                )
                let selection = clip.kind.selection(id: clip.id)
                let isSelected = editorStore.selection == selection || multiSelection.contains(selection)
                let isHovered = hoveredOverlaySelection == selection
                let emphasis = EditorTimelineClipEmphasis.resolve(
                    isEditing: overlayTimelineDrag?.id == clip.id
                        && overlayTimelineDrag?.kind == clip.kind,
                    isSelected: isSelected,
                    isHovered: isHovered
                )
                let hue = EditorTimelineHue.forKind(clip.kind)
                Color.clear
                    .overlay {
                        if clip.kind == .audio, let path = clip.sourcePath, clipWidth >= 24 {
                            TimelineAudioClipWaveform(path: path, sourceStart: clip.sourceStart, duration: clip.timing.duration, ink: hue.clipInk)
                                .padding(.horizontal, 4).padding(.vertical, 4)
                                .opacity(0.35)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .leading) {
                        // Mockup `.ck`: 12pt medium text in the deep hue,
                        // with the kind glyph when there is room.
                        if clipWidth >= 40 {
                            HStack(spacing: 6) {
                                if clipWidth >= 96, clip.kind != .subtitle {
                                    EditorSymbol(clip.kind.symbol, size: 12)
                                        .opacity(0.8)
                                }
                                Text(clip.title)
                                    .font(.appUI(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(hue.clipInk)
                            .padding(.horizontal, 8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .editorTimelineHueClip(hue, emphasis: emphasis, width: clipWidth)
                    .contentShape(Rectangle())
                .frame(width: clipWidth, height: clipRowHeight)
                .editorClipDragFeedback(overlayTimelineDrag?.id == clip.id && overlayTimelineDrag?.kind == clip.kind
                    && overlayTimelineDrag?.mode == .move)
                .offset(x: x, y: overlayTimelineDrag?.id == clip.id && overlayTimelineDrag?.mode == .move
                    && clip.kind.changesLaneByDrag ? overlayDragOffsetY : 0)
                .transition(.identity)
                .zIndex(emphasis == .editing ? 4 : isSelected ? 3 : isHovered ? 1 : 0)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: appLocalized("%@片段"), clip.title))
                .accessibilityValue(
                    String(
                        format: appLocalized("开始 %.2f 秒，时长 %.2f 秒"),
                        clip.timing.startTime,
                        clip.timing.duration
                    )
                )
                .accessibilityAddTraits(
                    isSelected ? [.isButton, .isSelected] : .isButton
                )
                .accessibilityAction {
                    activateTimelineSelection(selection)
                }
            }
        }
        .frame(width: width, height: clipRowHeight, alignment: .leading)
        // EDT-062: hover, menu and tooltip live on the row, not on each clip.
        // Hundreds of per-clip AppKit bridges (menus, tracking areas, tooltips)
        // made opening a project with many subtitles take seconds.
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                let time = Double(point.x / max(width, 1)) * duration
                let clip = clips.last { $0.timing.startTime <= time && $0.timing.endTime >= time }
                let selection = clip.map { $0.kind.selection(id: $0.id) }
                if hoveredOverlaySelection != selection { hoveredOverlaySelection = selection }
            case .ended:
                if let hovered = hoveredOverlaySelection, clips.contains(where: { $0.kind.selection(id: $0.id) == hovered }) {
                    hoveredOverlaySelection = nil
                }
            }
        }
        .contextMenu {
            if let clip = clips.first(where: { $0.kind.selection(id: $0.id) == hoveredOverlaySelection }) {
                clipArrangeMenu(clip)
                Divider()
                clipClipboardMenu(for: clip.kind.selection(id: clip.id))
            } else {
                timelineContextMenu()
            }
        }
        .help(appLocalized("拖动中部移动；拖动两端调整时长"))
        // Audio rows explicitly route blank presses to the marquee.
        .contentShape(createsOnEmptyDrag || drawsMarqueeOnEmptyDrag
            ? AnyShape(Rectangle())
            : AnyShape(TimelineClipsShape(ranges: clips.map {
                CGFloat($0.timing.startTime / max(duration, 0.001)) * width
                    ... CGFloat($0.timing.endTime / max(duration, 0.001)) * width
            })))
        // The lane owns the gesture. A clip must never be both the moving
        // visual and the coordinate system that interprets that movement.
        .gesture(overlayTrackGesture(
            clips: clips,
            timelineWidth: width,
            duration: duration,
            drawsMarqueeOnEmptyDrag: drawsMarqueeOnEmptyDrag
        ))
    }

    func overlayTrackGesture(
        clips: [TimelineOverlayClip],
        timelineWidth: CGFloat,
        duration: TimeInterval,
        drawsMarqueeOnEmptyDrag: Bool = false
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(editorTimelineDocumentCoordinateSpace))
            .onChanged { value in
                if overlayPointerPress == nil {
                    let hit = overlayClip(at: value.startLocation.x, clips: clips,
                                          timelineWidth: timelineWidth, duration: duration)
                    overlayPointerPress = EditorOverlayPointerPress(
                        selection: hit.map { $0.kind.selection(id: $0.id) }, modifiers: NSEvent.modifierFlags)
                }
                guard var press = overlayPointerPress else { return }
                if drawsMarqueeOnEmptyDrag, press.selection == nil {
                    updateTimelineMarquee(value, width: timelineWidth, duration: duration)
                    return
                }
                if press.selection != nil, !press.didDrag {
                    guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                    press.didDrag = true
                    overlayPointerPress = press
                }
                EditorDragFrameCoalescer.shared.submit {
                    guard overlayPointerPress?.id == press.id else { return }
                    if overlayTimelineDrag == nil, overlayCreateRange == nil {
                        beginOverlayTimelineDrag(
                            at: value.startLocation.x,
                            clips: clips,
                            timelineWidth: timelineWidth,
                            duration: duration
                        )
                    }
                    if gestureOwnership.activeIntent == .overlayCreate {
                        let start = overlayCreateStart ?? EditorTimelineMath.clampedTime(atX: Double(value.startLocation.x),
                            width: Double(timelineWidth), duration: duration)
                        let end = magneticTime(EditorTimelineMath.clampedTime(atX: Double(value.location.x),
                            width: Double(timelineWidth), duration: duration), width: timelineWidth, duration: duration)
                        overlayCreateRange = min(start, end)...max(start, end)
                        return
                    }
                    guard let drag = overlayTimelineDrag else { return }
                    let intent = EditorTimelineGestureIntent.overlay(
                        drag.kind,
                        drag.id,
                        drag.mode
                    )
                    guard gestureOwnership.activeIntent == intent else { return }
                    let rawDelta = TimeInterval(value.translation.width / max(timelineWidth, 1)) * duration
                    let delta = magneticDelta(rawDelta, start: drag.original.startTime,
                        end: drag.original.endTime, mode: drag.mode, width: timelineWidth, duration: duration)
                    var timing = adjustedOverlayTiming(
                        original: drag.original,
                        mode: drag.mode,
                        delta: delta,
                        timelineDuration: duration,
                        minimumLeadingStartTime: drag.minimumLeadingStartTime
                    )
                    if drag.kind == .subtitle, drag.mode == .move, !overlayGroupOriginals.isEmpty {
                        let originals = [drag.kind.selection(id: drag.id): drag.original].merging(overlayGroupOriginals) { a, _ in a }
                        let moved = EditorSubtitleTrackPlacement.groupDelta(
                            wanted: timing.startTime - drag.original.startTime, originals: Array(originals.values),
                            subtitles: originals.compactMap { selection, timing in
                                if case .subtitle = selection { return timing }
                                return nil
                            },
                            others: editorStore.project.timeline.subtitleCues
                                .filter { originals[.subtitle($0.id)] == nil }.map(\.timing), duration: duration)
                        timing.startTime = drag.original.startTime + moved
                    } else if drag.kind == .subtitle {
                        timing = EditorSubtitleTrackPlacement.resolve(
                            timing, original: drag.original, mode: drag.mode,
                            others: editorStore.project.timeline.subtitleCues
                                .filter { $0.id != drag.id }.map(\.timing),
                            duration: duration
                        )
                    }
                    timelineSnap.validate(edges: drag.mode == .move ? [timing.startTime, timing.endTime]
                        : [drag.mode == .leading ? timing.startTime : timing.endTime])
                    updateOverlayTimingDraft(drag: drag, timing: timing)
                    if drag.mode == .move,
                       let clip = overlayTimelineClips.first(where: { $0.id == drag.id && $0.kind == drag.kind }),
                       let origin = overlayDragOriginY ?? clipCenterY(clip) {
                        overlayDragOffsetY = value.translation.height
                        let target = abs(value.translation.height) > 8
                            ? laneDropTarget(for: clip, atY: origin + value.translation.height) : nil
                        overlayDragTarget = target.flatMap { target in
                            if case let .layer(n) = target, lane(of: clip) == .layer(n) { return nil }
                            if case let .audio(n) = target, lane(of: clip) == .audio(n) { return nil }
                            return target
                        }
                        if overlayDragTarget == .mainTrack {
                            let time = min(max(drag.original.startTime + delta, 0), duration)
                            mainTrackDropX = CGFloat(time / max(duration, 0.001)) * timelineWidth
                        } else { mainTrackDropX = nil }
                    }
                }
            }
            .onEnded { value in
                EditorDragFrameCoalescer.shared.flush()
                let press = overlayPointerPress
                defer { overlayPointerPress = nil; overlayGroupOriginals = [:]; overlayDragOriginY = nil; mainTrackDropX = nil }
                if drawsMarqueeOnEmptyDrag, let press, press.selection == nil {
                    finishTimelineBackgroundPress(value, width: timelineWidth, duration: duration)
                    return
                }
                if let press, let selection = press.selection, !press.didDrag {
                    activateTimelineSelection(selection, extendingWith: press.modifiers)
                    return
                }
                if gestureOwnership.activeIntent == .overlayCreate, let range = overlayCreateRange {
                    overlayCreateRange = nil
                    overlayCreateStart = nil
                    endTimelineGesture(.overlayCreate)
                    let isDrawnRange = EditorTimelineRangeCreationPolicy.shouldCommit(
                        horizontalTranslation: value.translation.width)
                    if !isDrawnRange && emptyClickClearsSelection { return }
                    let length = isDrawnRange ? max(range.upperBound - range.lowerBound, 0.08) : 3
                    let start = min(range.lowerBound, max(duration - length, 0))
                    let clip = MosaicClip(timing: OverlayTiming(startTime: start,
                        duration: min(length, duration - start)))
                    playbackController.pause()
                    var timeline = editorStore.project.timeline
                    timeline.mosaicClips.append(clip)
                    do {
                        try editorStore.replaceTimeline(with: timeline, actionName: "添加柔化")
                        activateTimelineSelection(.mosaic(clip.id))
                    } catch { onError(error.localizedDescription) }
                    return
                }
                guard let drag = overlayTimelineDrag else { return }
                let intent = EditorTimelineGestureIntent.overlay(
                    drag.kind,
                    drag.id,
                    drag.mode
                )
                var laneTarget = overlayDragTarget
                if drag.mode == .move, let origin = overlayDragOriginY,
                   let clip = overlayTimelineClips.first(where: { $0.id == drag.id && $0.kind == drag.kind }) {
                    laneTarget = abs(value.translation.height) > 8
                        ? laneDropTarget(for: clip, atY: origin + value.translation.height) : nil
                }
                if laneTarget == .mainTrack {
                    let released = drag.original.startTime + Double(value.translation.width / max(timelineWidth, 1)) * duration
                    let time = magneticTime(min(max(released, 0), duration), width: timelineWidth, duration: duration)
                    overlayTimelineDrag = nil; overlayDragTarget = nil; overlayDragOffsetY = 0; mainTrackDropX = nil
                    editorStore.cancelInteraction()
                    endTimelineGesture(intent)
                    moveVisualToMain(drag.id, at: time)
                    return
                }
                // Land exactly where released: no spring on the clip, its old
                // lane closing or the labels beside it.
                var instant = Transaction(animation: nil)
                instant.disablesAnimations = true
                withTransaction(instant) {
                    overlayTimelineDrag = nil
                    overlayDragTarget = nil
                    overlayDragOffsetY = 0
                    guard gestureOwnership.activeIntent == intent else { return }
                    if let laneTarget {
                        let selection = drag.kind.selection(id: drag.id)
                        editorStore.updateTimelineInteraction { editorStore.assign(selection, to: laneTarget, in: &$0.timeline) }
                    }
                    commitOverlayTimelineDrag(drag)
                    endTimelineGesture(intent)
                }
            }
    }

    private func overlayClip(at x: CGFloat, clips: [TimelineOverlayClip],
                             timelineWidth: CGFloat, duration: TimeInterval) -> TimelineOverlayClip? {
        let candidates = clips.filter { clip in
            let startX = CGFloat(clip.timing.startTime / max(duration, 0.001)) * timelineWidth
            let clipWidth = max(CGFloat(clip.timing.duration / max(duration, 0.001)) * timelineWidth, 3)
            return x >= startX && x <= startX + clipWidth
        }
        return candidates.first { editorStore.selection == $0.kind.selection(id: $0.id) } ?? candidates.last
    }

    func beginOverlayTimelineDrag(
        at x: CGFloat, clips: [TimelineOverlayClip], timelineWidth: CGFloat, duration: TimeInterval
    ) {
        guard gestureOwnership.activeIntent == nil else { return }
        guard let clip = overlayClip(at: x, clips: clips, timelineWidth: timelineWidth, duration: duration) else {
            prepareEmptyTimelineClick()
            guard beginTimelineGesture(.overlayCreate) else { return }
            let start = EditorTimelineMath.clampedTime(atX: Double(x), width: Double(timelineWidth), duration: duration)
            let snapped = magneticTime(start, width: timelineWidth, duration: duration)
            overlayCreateStart = snapped
            overlayCreateRange = snapped...snapped
            return
        }
        let startX = CGFloat(
            clip.timing.startTime / max(duration, 0.001)
        ) * timelineWidth
        let clipWidth = max(
            CGFloat(clip.timing.duration / max(duration, 0.001))
                * timelineWidth,
            3
        )
        let localX = x - startX
        let edgeWidth = min(max(clipWidth * 0.14, 5), 8)
        let mode: EditorMotionTimelineEditMode
        if clipWidth >= edgeWidth * 2 + 12, localX <= edgeWidth {
            mode = .leading
        } else if clipWidth >= edgeWidth * 2 + 12,
                  localX >= clipWidth - edgeWidth {
            mode = .trailing
        } else {
            mode = .move
        }
        let intent = EditorTimelineGestureIntent.overlay(clip.kind, clip.id, mode)
        guard beginTimelineGesture(intent),
              let timing = persistedOverlayTiming(kind: clip.kind, id: clip.id)
        else {
            endTimelineGesture(intent)
            return
        }
        playbackController.pause(revealingPlayhead: false)
        let selection = clip.kind.selection(id: clip.id)
        if !multiSelection.contains(selection) {
            let modifiers = overlayPointerPress?.modifiers ?? []
            if modifiers.contains(.shift) || modifiers.contains(.command) { toggleInMultiSelection(selection) }
            else { multiSelection = [] }
        }
        overlayGroupOriginals = mode == .move && multiSelection.contains(selection)
            ? groupOverlayTimings(excluding: selection) : [:]
        overlayDragOriginY = clipCenterY(clip)
        editorStore.beginInteraction(tool: .select, selection: selection)
        timelineInteractionID = editorStore.interaction?.id
        overlayTimelineDrag = EditorOverlayTimelineDrag(
            kind: clip.kind,
            id: clip.id,
            mode: mode,
            original: timing
        )
        let timeline = editorStore.project.timeline
        switch clip.kind {
        case .sticker:
            if let c = timeline.stickerClips.first(where: { $0.id == clip.id }) {
                overlayTimelineDrag?.sourceStart = c.sourceStart; overlayTimelineDrag?.playbackRate = c.playbackRate
            }
        case .animation:
            if let c = timeline.animationClips.first(where: { $0.id == clip.id }) {
                overlayTimelineDrag?.sourceStart = c.timeOffset; overlayTimelineDrag?.playbackRate = c.playbackRate
            }
        case .video:
            if let c = timeline.videoClips.first(where: { $0.id == clip.id }) {
                overlayTimelineDrag?.sourceStart = c.sourceStart; overlayTimelineDrag?.playbackRate = c.playbackRate
            }
        case .audio:
            if let c = timeline.audioClips.first(where: { $0.id == clip.id }) {
                overlayTimelineDrag?.sourceStart = c.sourceStart; overlayTimelineDrag?.playbackRate = c.playbackRate
            }
        default: break
        }
    }

    func persistedOverlayTiming(
        kind: EditorOverlayTimelineKind,
        id: UUID,
        timeline suppliedTimeline: ProjectTimeline? = nil
    ) -> OverlayTiming? {
        let timeline = suppliedTimeline ?? editorStore.project.timeline
        switch kind {
        case .mosaic:
            return timeline.mosaicClips
                .first(where: { $0.id == id })?.timing
        case .sticker:
            return timeline.stickerClips
                .first(where: { $0.id == id })?.timing
        case .animation:
            return timeline.animationClips
                .first(where: { $0.id == id })?.timing
        case .audio:
            return timeline.audioClips
                .first(where: { $0.id == id })?.timing
        case .subtitle:
            return timeline.subtitleCues
                .first(where: { $0.id == id })?.timing
        case .video:
            return timeline.videoClips
                .first(where: { $0.id == id })?.timing
        }
    }

    func adjustedOverlayTiming(
        original: OverlayTiming,
        mode: EditorMotionTimelineEditMode,
        delta: TimeInterval,
        timelineDuration: TimeInterval,
        minimumLeadingStartTime: TimeInterval = 0
    ) -> OverlayTiming {
        EditorOverlayTimingEditing.adjustedTiming(
            original: original,
            mode: mode,
            delta: delta,
            timelineDuration: timelineDuration,
            minimumLeadingStartTime: minimumLeadingStartTime
        )
    }

    func updateOverlayTimingDraft(
        drag: EditorOverlayTimelineDrag,
        timing: OverlayTiming
    ) {
        let groupDelta = timing.startTime - drag.original.startTime
        let groupOriginals = overlayGroupOriginals
        let outputDuration = timelineDuration
        editorStore.updateTimelineInteraction { project in
            // The rest of a group selection moves by the same amount.
            for (item, original) in groupOriginals {
                var moved = original
                moved.startTime = min(max(original.startTime + groupDelta, 0), max(outputDuration - original.duration, 0))
                Self.setOverlayTiming(moved, of: item, in: &project.timeline)
            }
            switch drag.kind {
            case .mosaic:
                guard let index = project.timeline.mosaicClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.mosaicClips[index].timing = timing
            case .sticker:
                guard let index = project.timeline.stickerClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.stickerClips[index].timing = timing
                if drag.mode == .leading {
                    project.timeline.stickerClips[index].sourceStart = max(0, drag.sourceStart
                        + (timing.startTime - drag.original.startTime) * drag.playbackRate)
                }
            case .animation:
                guard let index = project.timeline.animationClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.animationClips[index].timing = timing
                if drag.mode == .leading {
                    project.timeline.animationClips[index].timeOffset = max(0, drag.sourceStart
                        + (timing.startTime - drag.original.startTime) * drag.playbackRate)
                }
            case .audio:
                guard let index = project.timeline.audioClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.audioClips[index].timing = timing
                if drag.mode == .leading {
                    project.timeline.audioClips[index].sourceStart = max(0, drag.sourceStart
                        + (timing.startTime - drag.original.startTime) * drag.playbackRate)
                }
            case .subtitle:
                guard let index = project.timeline.subtitleCues.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.subtitleCues[index].timing = timing
            case .video:
                guard let index = project.timeline.videoClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.videoClips[index].timing = timing
                if drag.mode == .leading {
                    project.timeline.videoClips[index].sourceStart = max(0, drag.sourceStart
                        + (timing.startTime - drag.original.startTime) * drag.playbackRate)
                }
            }
        }
    }

    func commitOverlayTimelineDrag(_ drag: EditorOverlayTimelineDrag) {
        do {
            _ = try editorStore.commitInteraction(
                actionName: drag.mode == .move
                    ? drag.kind.moveActionName
                    : drag.kind.resizeActionName
            )
            // A move/resize is not an instruction to seek to this object.
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }
}

struct TimelineOverlayClip: Identifiable {
    let id: UUID
    var timing: OverlayTiming
    var title: String
    let kind: EditorOverlayTimelineKind
    let layerIndex: Int
    var sourcePath: String? = nil
    var sourceStart: TimeInterval = 0
    var isEffect = false
    /// Shared visual stacking layer (pictures, motion graphics, videos).
    var layer = 0
    /// Audio row for music and effects.
    var audioLane = 0
}

/// EDT-054: visibility groups of the added-material lanes (track menu).
enum TimelinePostLane: String, CaseIterable {
    case subtitles, layers, effects, audio

    var palette: EditorConsolePalette {
        switch self {
        case .subtitles: EditorConsole.Track.subtitle
        case .layers: EditorConsole.Track.overlay
        case .effects: EditorConsole.Track.region
        case .audio: EditorConsole.Track.music
        }
    }

    var title: String {
        switch self {
        case .subtitles: "字幕"
        case .layers: "画面层"
        case .effects: "柔化与突出"
        case .audio: "音频"
        }
    }

    var symbol: String {
        switch self {
        case .subtitles: "captions.bubble"
        case .layers: "square.3.layers.3d"
        case .effects: "circle.dotted"
        case .audio: "waveform"
        }
    }
}

/// One timeline row derived from content, like an editor track: rows appear
/// when something is on them and disappear when emptied.
enum TimelineLane: Hashable {
    case subtitles
    case layer(Int)
    case effects
    case audio(Int)
    /// A group's name row (画面叠加 / 柔化与突出); folded, it shows bands.
    case groupHeader(TimelinePostLane)
    /// "还有 N 层 · 展开" below the third visible picture layer.
    case moreLayers(Int)

    var group: TimelinePostLane {
        switch self {
        case .subtitles: .subtitles
        case .layer, .moreLayers: .layers
        case .effects: .effects
        case .audio: .audio
        case let .groupHeader(group): group
        }
    }

    /// Rows that carry clips (not a group header or the "more" row).
    var holdsClips: Bool {
        switch self {
        case .groupHeader, .moreLayers: false
        default: true
        }
    }

    func contains(_ clip: TimelineOverlayClip) -> Bool {
        switch self {
        case .groupHeader, .moreLayers: false
        case .subtitles: clip.kind == .subtitle
        case let .layer(layer): (clip.kind == .video || clip.kind == .sticker || clip.kind == .animation) && clip.layer == layer
        case .effects: clip.kind == .mosaic
        case let .audio(lane): clip.kind == .audio && clip.audioLane == lane
        }
    }
}

/// The audio file's own waveform for the part this clip plays.
struct TimelineAudioClipWaveform: View {
    let path: String
    let sourceStart: TimeInterval
    let duration: TimeInterval
    var ink: Color = EditorConsole.Track.music.softInk
    @State private var data: (samples: [Double], length: Double)?

    var body: some View {
        Canvas { context, size in
            guard let data, data.length > 0, !data.samples.isEmpty else { return }
            let count = data.samples.count
            let first = Int(Double(count) * sourceStart / data.length)
            let last = min(Int(Double(count) * (sourceStart + duration) / data.length), count)
            guard last > first else { return }
            let slice = Array(data.samples[max(first, 0)..<last])
            let bars = min(slice.count, max(Int(size.width / 3), 1))
            let step = size.width / CGFloat(bars)
            for bar in 0..<bars {
                let lower = bar * slice.count / bars, upper = max((bar + 1) * slice.count / bars, lower + 1)
                let peak = slice[lower..<min(upper, slice.count)].max() ?? 0
                let height = max(size.height * CGFloat(min(peak, 1)), 1)
                context.fill(Path(roundedRect: CGRect(x: CGFloat(bar) * step, y: (size.height - height) / 2,
                                                      width: max(step - 1, 1), height: height), cornerRadius: 0.5),
                             with: .color(ink))
            }
        }
        .task(id: path) { data = await TimelineAudioWaveformCache.shared.waveform(for: path) }
    }
}
/// Each audio file is decoded once for the timeline, however often its clip
/// views are rebuilt (scrolling, zooming, re-rendering).
actor TimelineAudioWaveformCache {
    static let shared = TimelineAudioWaveformCache()
    private var entries: [String: (samples: [Double], length: Double)] = [:]
    private var loading: [String: Task<(samples: [Double], length: Double), Never>] = [:]

    func waveform(for path: String) async -> (samples: [Double], length: Double) {
        if let cached = entries[path] { return cached }
        if let task = loading[path] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> (samples: [Double], length: Double) in
            let url = ProjectFiles.url(path)
            let samples = (try? await MediaAnalyzer.waveform(url, sampleCount: 1200)) ?? []
            let length = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            return (samples, length)
        }
        loading[path] = task
        let value = await task.value
        loading[path] = nil
        entries[path] = value
        return value
    }
}


extension EditorOverlayTimelineKind {
    /// Kinds whose vertical drag picks another lane (picture layers, audio
    /// rows). Subtitles and region effects live on a single track.
    var changesLaneByDrag: Bool {
        switch self {
        case .video, .sticker, .animation, .audio: true
        case .subtitle, .mosaic: false
        }
    }
}

/// The subtitle lane is one track: lines never overlap. A moved line lands
/// in the free gap nearest to where it was dropped; a trimmed edge stops at
/// its neighbour.
enum EditorSubtitleTrackPlacement {
    /// Translate the group together into the closest available position.
    /// Forbidden deltas are the collisions with unselected cues.
    static func groupDelta(wanted: Double, originals: [OverlayTiming], subtitles: [OverlayTiming],
                           others: [OverlayTiming], duration: Double) -> Double {
        guard let first = originals.map(\.startTime).min(), let last = originals.map(\.endTime).max() else { return 0 }
        let lower = -first, upper = max(duration - last, lower)
        let target = min(max(wanted, lower), upper)
        var blocked: [(Double, Double)] = []
        for moving in subtitles {
            for other in others {
                let a = other.startTime - moving.endTime + 0.000_5
                let b = other.endTime - moving.startTime - 0.000_5
                if a < b, b > lower, a < upper { blocked.append((a, b)) }
            }
        }
        blocked.sort { $0.0 < $1.0 }
        // Merge overlapping forbidden ranges once; avoid comparing every
        // candidate with every collision on each frame of a large selection.
        var merged: [(Double, Double)] = []
        for range in blocked {
            if let last = merged.last, range.0 < last.1 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else {
                merged.append(range)
            }
        }
        guard let collision = merged.first(where: { target > $0.0 && target < $0.1 }) else { return target }
        return [collision.0, collision.1].filter { $0 >= lower && $0 <= upper }
            .min { abs($0 - wanted) < abs($1 - wanted) } ?? 0
    }

    static func resolve(
        _ proposed: OverlayTiming,
        original: OverlayTiming,
        mode: EditorMotionTimelineEditMode,
        others: [OverlayTiming],
        duration: TimeInterval
    ) -> OverlayTiming {
        let sorted = others.sorted { $0.startTime < $1.startTime }
        switch mode {
        case .leading:
            let floor = sorted.last(where: { $0.endTime <= original.startTime + 0.005 })?.endTime ?? 0
            var timing = proposed
            if timing.startTime < floor {
                timing = OverlayTiming(startTime: floor, duration: max(proposed.endTime - floor, 0.1))
            }
            return timing
        case .trailing:
            let ceiling = sorted.first(where: { $0.startTime >= original.endTime - 0.005 })?.startTime ?? duration
            var timing = proposed
            if timing.endTime > ceiling {
                timing.duration = max(ceiling - timing.startTime, 0.1)
            }
            return timing
        case .move:
            let length = proposed.duration
            // Free gaps between the other lines, in output time.
            var gaps: [ClosedRange<TimeInterval>] = []
            var cursor: TimeInterval = 0
            for other in sorted {
                if other.startTime - cursor >= length - 0.000_5 { gaps.append(cursor...other.startTime) }
                cursor = max(cursor, other.endTime)
            }
            if duration - cursor >= length - 0.000_5 { gaps.append(cursor...duration) }
            guard !gaps.isEmpty else { return original }
            let wanted = proposed.startTime
            var best = original.startTime
            var bestDistance = TimeInterval.infinity
            for gap in gaps {
                let start = min(max(wanted, gap.lowerBound), gap.upperBound - length)
                let distance = abs(start - wanted)
                if distance < bestDistance { best = start; bestDistance = distance }
            }
            return OverlayTiming(startTime: best, duration: length)
        }
    }
}
