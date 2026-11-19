import AppKit
import RecorderCore
import SwiftUI

// MARK: - Tools: 选择 (A) / 切割 (B)

extension EditorTimelineView {
    func setTimelineTool(_ tool: EditorTimelineTool) {
        guard timelineTool != tool else { return }
        if gestureOwnership.activeIntent != nil || editorStore.interaction != nil {
            cancelActiveTimelineGesture()
        }
        timelineTool = tool
        isOptionHeld = false
        hoveredTimelineCutPoint = nil
    }

    var isCutToolActive: Bool { timelineTool == .cut }

    /// `A` selects the Select tool and `B` the Cut tool, like Final Cut.
    func installTimelineToolKeyMonitor() {
        guard toolKeyMonitor == nil else { return }
        toolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue == "cn.laogou.dogsc.editor-window",
                  !event.targetsPresentedContent, !event.isARepeat,
                  !editorStore.mediaLibraryHasKeyboardFocus,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return event }
            if let textView = event.window?.firstResponder as? NSTextView, textView.isEditable {
                return event
            }
            if event.window?.firstResponder is NSTextField { return event }
            switch event.keyCode {
            case 0: // A
                setTimelineTool(.select)
                return nil
            case 11: // B
                setTimelineTool(.cut)
                return nil
            case 53 where timelineTool == .cut: // Esc leaves the Cut tool
                setTimelineTool(.select)
                return nil
            default:
                return event
            }
        }
    }

    func removeTimelineToolKeyMonitor() {
        guard let toolKeyMonitor else { return }
        NSEvent.removeMonitor(toolKeyMonitor)
        self.toolKeyMonitor = nil
    }

    /// Cut: "点哪切哪". Splits whatever clip lies under the click at that
    /// time. The blade stays in hand for the next cut until A or Esc.
    /// Returns false when nothing was cut.
    @discardableResult
    func cutTimeline(atDocumentPoint point: CGPoint, width: CGFloat, duration: TimeInterval) -> Bool {
        guard width > 0, duration > 0 else { return false }
        let rawTime = EditorTimelineMath.clampedTime(atX: Double(point.x), width: Double(width), duration: duration)
        let time = snappedTimelineTime(magneticTime(rawTime, width: width, duration: duration))
        timelineSnap.reset()
        let y = point.y

        // Main track.
        if y >= primaryLaneTop, y < primaryLaneTop + primaryTimelineHeight {
            guard let segment = primaryDisplaySegments.first(where: {
                time > $0.outputStart && time < $0.outputEnd
            }) else { return false }
            let outputTime = snappedEditableTime(time, lowerBound: segment.outputStart, upperBound: segment.outputEnd)
            guard outputTime > segment.outputStart + minimumPrimarySegmentDuration,
                  outputTime < segment.outputEnd - minimumPrimarySegmentDuration else { return false }
            splitPrimarySegment(atCutTime: outputTime)
            return true
        }

        // Added-material lanes.
        for lane in upperLanes + lowerLanes where lane.holdsClips {
            let top = laneTop(lane)
            guard y >= top, y < top + laneHeight(lane) else { continue }
            let rows = laneRows(lane)
            let row = min(max(Int((y - top - clipRowInset) / max(clipRowHeight + clipRowSpacing, 1)), 0), max(rows.count - 1, 0))
            guard rows.indices.contains(row),
                  let clip = rows[row].last(where: { $0.timing.startTime < time && $0.timing.endTime > time })
            else { return false }
            return splitOverlayClip(clip, at: time)
        }

        // Lens lanes below the recording.
        var top = primaryLaneTop + primaryTimelineHeight + (showsCameraSyncTimeline ? cameraSyncTimelineHeight : 0)
        if showsZoomTimeline {
            if y >= top, y < top + zoomTimelineHeight {
                guard let clip = editorStore.project.zoomAnimations.first(where: {
                    $0.startTime < time && $0.endTime > time
                }) else { return false }
                splitZoomAnimation(id: clip.id, at: time)
                return true
            }
            top += zoomTimelineHeight
        }
        if showsScreenMotionTimeline {
            if y >= top, y < top + motionTimelineHeight {
                guard let clip = editorStore.project.timeline.screenMotionClips.first(where: {
                    $0.timing.startTime < time && $0.timing.endTime > time
                }) else { return false }
                splitMotionClip(track: .screen, id: clip.id, atTime: time)
                return true
            }
            top += motionTimelineHeight
        }
        if showsCameraMotionTimeline, y >= top, y < top + motionTimelineHeight {
            guard let clip = editorStore.project.timeline.cameraMotionClips.first(where: {
                $0.timing.startTime < time && $0.timing.endTime > time
            }) else { return false }
            splitMotionClip(track: .camera, id: clip.id, atTime: time)
            return true
        }
        return false
    }

    @discardableResult
    private func splitOverlayClip(_ clip: TimelineOverlayClip, at time: TimeInterval) -> Bool {
        switch clip.kind {
        case .mosaic: splitMosaicClip(id: clip.id, atTime: time)
        case .sticker: splitStickerClip(id: clip.id, atTime: time)
        case .animation: splitPostProductionClip(.animation(clip.id), at: time)
        case .audio: splitPostProductionClip(.audioClip(clip.id), at: time)
        case .subtitle: splitPostProductionClip(.subtitle(clip.id), at: time)
        case .video: splitPostProductionClip(.videoClip(clip.id), at: time)
        }
        return true
    }

    /// A transparent layer over every lane while the Cut tool is active: it
    /// owns the click (so nothing is moved by accident), shows scissors and
    /// a hairline at the cut position.
    @ViewBuilder
    func timelineCutToolOverlay(width: CGFloat, duration: TimeInterval) -> some View {
        if isCutToolActive {
            EditorTimelineCutToolLayer(
                rulerHeight: timelineRulerHeight,
                height: timelineCanvasHeight,
                onCut: { point in cutTimeline(atDocumentPoint: point, width: width, duration: duration) }
            )
            .frame(width: width, height: timelineCanvasHeight)
            .zIndex(35)
        }
    }
}

/// Owns pointer input while cutting; draws the cut guide under the pointer.
private struct EditorTimelineCutToolLayer: View {
    let rulerHeight: CGFloat
    let height: CGFloat
    let onCut: (CGPoint) -> Void
    @State private var hoverPoint: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .padding(.top, rulerHeight)
            if let hoverPoint {
                Rectangle()
                    .fill(EditorTheme.accent)
                    .frame(width: 1, height: max(height - rulerHeight, 0))
                    .offset(x: hoverPoint.x - 0.5, y: rulerHeight)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(point):
                hoverPoint = point.y >= rulerHeight ? point : nil
                if hoverPoint != nil { EditorTimelineScissorsCursor.cursor.set() }
                else { NSCursor.arrow.set() }
            case .ended:
                hoverPoint = nil
                NSCursor.arrow.set()
            }
        }
        .gesture(
            SpatialTapGesture(coordinateSpace: .local).onEnded { event in
                guard event.location.y >= rulerHeight else { return }
                onCut(event.location)
            }
        )
        .editorCursor(EditorTimelineScissorsCursor.cursor)
        .accessibilityHidden(true)
    }
}

// MARK: - Lane groups (画面叠加 / 柔化与突出)

extension EditorTimelineView {
    /// Group header in the label column: chevron, name and count.
    func laneGroupLabel(_ group: TimelinePostLane) -> some View {
        let collapsed = isLaneGroupCollapsed(group)
        let title = group == .effects ? "柔化与突出" : "画面叠加"
        let count = laneGroupClips(group).count
        return Button {
            toggleLaneGroup(group)
        } label: {
            EditorTimelineGroupLabel(
                title: title,
                icon: group == .effects ? .regionBlur : .overlayStack,
                count: count,
                isCollapsed: collapsed,
                labelsCollapsed: timelineLabelsCollapsed
            )
        }
        .buttonStyle(.plain)
        .frame(height: laneHeight(.groupHeader(group)))
        .help(appLocalized(collapsed ? "展开这一组" : "折叠这一组"))
        .accessibilityLabel(appLocalized(title))
        .accessibilityValue(appLocalized(collapsed ? "已折叠" : "已展开"))
        .contextMenu {
            if group == .effects { clearLaneMenu(.effects) }
        }
    }

    /// Group header row on the canvas: empty when open; folded, each clip is
    /// a light band, so overlaps read darker.
    func laneGroupTimeline(_ group: TimelinePostLane, width: CGFloat, duration: TimeInterval) -> some View {
        let collapsed = isLaneGroupCollapsed(group)
        let hue: EditorTimelineHue = group == .effects ? .region : .overlay
        let height = laneHeight(.groupHeader(group))
        let range = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width, duration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        return ZStack(alignment: .topLeading) {
            if collapsed {
                ForEach(laneGroupClips(group).filter {
                    $0.timing.endTime >= range.lowerBound && $0.timing.startTime <= range.upperBound
                }) { clip in
                    let x = CGFloat(clip.timing.startTime / max(duration, 0.001)) * width
                    let w = max(CGFloat(clip.timing.duration / max(duration, 0.001)) * width, 3)
                    Capsule()
                        .fill(hue.occupancy)
                        .frame(width: w, height: 6)
                        .offset(x: x, y: height / 2 - 3)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(timelineMarqueeGesture(width: width, duration: duration) { _ in
            clearTimelineSelection()
            toggleLaneGroup(group)
        })
        .allowsHitTesting(collapsed)
    }

    /// Label column side of the "还有 N 层 · 展开" row (left empty).
    func moreLayersLabel(_ lane: TimelineLane) -> some View {
        Color.clear.frame(height: laneHeight(lane))
    }

    func moreLayersTimeline(_ hidden: Int, width: CGFloat) -> some View {
        Button {
            withAnimation(SpringMotion.settle) { showsAllOverlayLayers = true }
        } label: {
            EditorTimelineMoreLayersLabel(text: String(format: appLocalized("还有 %lld 层 · 展开"), Int64(hidden)))
        }
        .buttonStyle(.plain)
        .frame(width: width, height: laneHeight(.moreLayers(hidden)), alignment: .leading)
        .accessibilityLabel(String(format: appLocalized("还有 %lld 层 · 展开"), Int64(hidden)))
    }

    /// Rows inside 柔化与突出: one number per 32-pt row, on the name column,
    /// matching 画面叠加's layer numbers.
    func effectsRowNumbersLabel(_ lane: TimelineLane) -> some View {
        let count = max(laneRows(lane).count, 1)
        return VStack(spacing: 0) {
            ForEach(1...count, id: \.self) { number in
                Text("\(number)")
                    .font(.appUI(size: 11.5, design: .monospaced))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .padding(.leading, timelineLabelsCollapsed
                        ? EditorTimelineLabelMetrics.collapsedInset + 4
                        : EditorTimelineLabelMetrics.nameColumn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32 * trackScale)
            }
        }
        .frame(height: laneHeight(lane), alignment: .top)
    }

    /// Sub-layer label inside a group: just its number, indented.
    func overlayLayerNumberLabel(_ lane: TimelineLane) -> some View {
        let number = (upperLanes.filter { if case .layer = $0 { true } else { false } }.firstIndex(of: lane) ?? 0) + 1
        return Text("\(number)")
            .font(.appUI(size: 11.5, design: .monospaced))
            .foregroundStyle(EditorTheme.tertiaryText)
            .padding(.leading, timelineLabelsCollapsed
                ? EditorTimelineLabelMetrics.collapsedInset + 4
                : EditorTimelineLabelMetrics.nameColumn)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: laneHeight(lane))
    }
}

/// Group header row: the same grammar as a lane header, with a chevron in
/// the icon slot that turns when the group folds.
private struct EditorTimelineGroupLabel: View {
    let title: String
    let icon: AppLineIcon.Kind
    let count: Int
    let isCollapsed: Bool
    let labelsCollapsed: Bool
    @State private var hovered = false

    /// timeline-lanes.html: the group's own icon in the icon slot, the
    /// name, then a small fold mark beside the count (never in the icon
    /// slot). Folding turns the mark −90° over 200 ms.
    var body: some View {
        HStack(spacing: EditorTimelineLabelMetrics.spacing) {
            AppLineIcon(kind: icon, size: EditorTimelineLabelMetrics.icon)
                .foregroundStyle(hovered ? EditorTheme.secondaryText : EditorTheme.tertiaryText)
                .frame(width: EditorTimelineLabelMetrics.icon, height: EditorTimelineLabelMetrics.icon)
            if !labelsCollapsed {
                Text(appLocalized(title))
                    .font(.appUI(size: 12.5))
                    .foregroundStyle(hovered ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppLineIcon(kind: .chevronDown, size: 10)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.2), value: isCollapsed)
                if count > 0 {
                    EditorTimelineLabelCount(count: count)
                }
            }
        }
        .padding(.leading, labelsCollapsed ? EditorTimelineLabelMetrics.collapsedInset : EditorTimelineLabelMetrics.inset)
        .padding(.trailing, labelsCollapsed ? 0 : EditorTimelineLabelMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct EditorTimelineMoreLayersLabel: View {
    let text: String
    @State private var hovered = false

    var body: some View {
        Text(text)
            .font(.appUI(size: 12))
            .foregroundStyle(hovered ? EditorTheme.primaryText : EditorTheme.tertiaryText)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

// MARK: - Cut seams on the main track

extension EditorTimelineView {
    /// Seams are paint only. A full-height merge hit target used to cover
    /// both trim edges; raising a handle inside its clip cannot outrank it.
    @ViewBuilder
    func primarySeams(width: CGFloat, duration: TimeInterval) -> some View {
        if primaryTrimDraft == nil, primaryReorderDraft == nil, draggedPrimarySegmentID == nil {
            let visible = EditorTimelineViewportPresentation.bufferedTimeRange(
                documentWidth: width, duration: duration,
                visibleRange: clampedTimelineVisibleDocumentRange(width: width)
            )
            ForEach(primarySegmentJunctions.filter { visible.contains($0.outputTime) }) { junction in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(EditorTheme.panelSurface)
                    .frame(width: 2, height: primaryVideoHeight)
                    .offset(x: CGFloat(junction.outputTime / max(duration, 0.001)) * width - 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The tip and a stationary seam click both merge. Neither creates a
    /// hit layer over the clip edges used by the pointer gesture.
    @ViewBuilder
    func primarySeamMergeTip(width: CGFloat, duration: TimeInterval) -> some View {
        if !isCutToolActive, !isOptionHeld, gestureOwnership.activeIntent == nil,
           let id = hoveredSeamID, let junction = primarySegmentJunctions.first(where: { $0.id == id }) {
            let rect = primarySeamTipFrame(junction, width: width, duration: duration)
            Button {
                hoveredSeamID = nil
                if junction.hasRemovedSourceGap { restorePrimaryGap(junction) }
                else { mergePrimarySegments(at: junction) }
            } label: {
                Text(seamTip(junction))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.panelSurface)
                    .lineLimit(1)
                    .frame(width: rect.width, height: rect.height)
                    .background(EditorTheme.primaryText, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .offset(x: rect.minX, y: rect.minY)
            .accessibilityLabel(seamTip(junction))
            .accessibilityIdentifier("editor.timeline.seam.\(junction.id.uuidString)")
        }
    }

    private func primarySeamTipFrame(_ junction: EditorTimelineSegmentJunction,
                                     width: CGFloat, duration: TimeInterval) -> CGRect {
        let tipWidth = ceil(AppTypography.regularTextWidth(seamTip(junction), size: 12)) + 16
        let seamX = CGFloat(junction.outputTime / max(duration, 0.001)) * width
        let visible = clampedTimelineVisibleDocumentRange(width: width)
        let x = min(max(seamX - tipWidth / 2, visible.lowerBound), max(visible.upperBound - tipWidth, visible.lowerBound))
        return CGRect(x: x, y: primaryLaneTop + 6 - 30, width: tipWidth, height: 24)
    }

    func updatePrimarySeamHover(at viewportPoint: CGPoint?) {
        guard let viewportPoint, !isCutToolActive, !isOptionHeld, gestureOwnership.activeIntent == nil else {
            hoveredSeamID = nil
            return
        }
        let point = CGPoint(x: viewportPoint.x + (timelineScrollView?.documentVisibleRect.minX ?? 0),
                            y: viewportPoint.y)
        let width = max(timelineContentWidth, 1), duration = max(timelineDuration, 0.001)
        let junctions = primarySegmentJunctions
        if let id = hoveredSeamID, let junction = junctions.first(where: { $0.id == id }) {
            let tip = primarySeamTipFrame(junction, width: width, duration: duration)
            let seamX = CGFloat(junction.outputTime / duration) * width
            // Keep the tip available as the pointer crosses the small gap
            // above the trim edge and moves onto the actual merge button.
            let bridge = CGRect(x: seamX - 6, y: tip.maxY, width: 12,
                                height: max(primaryLaneTop + 6 - tip.maxY, 0))
            if tip.contains(point) || bridge.contains(point) { return }
        }
        let clipTop = primaryLaneTop + 6
        let next = (clipTop...(clipTop + primaryVideoHeight)).contains(point.y)
            ? junctions.first { abs(CGFloat($0.outputTime / duration) * width - point.x) <= 6 }?.id
            : nil
        if hoveredSeamID != next { hoveredSeamID = next }
    }

    func seamTip(_ junction: EditorTimelineSegmentJunction) -> String {
        guard junction.hasRemovedSourceGap else { return appLocalized("点击合并") }
        let seconds = junction.removedDuration
        let text = seconds < 10
            ? String(format: "%.1f", seconds)
            : String(format: "%.0f", seconds)
        return String(format: appLocalized("剪掉 %@ 秒 · 点击合并"), text)
    }
}

// MARK: - Added-material rows and quiet hairlines

extension EditorTimelineView {
    /// One row above or below the recording: a clip lane, a group header or
    /// the "还有 N 层" row.
    @ViewBuilder
    func addedLaneTimeline(_ lane: TimelineLane, width: CGFloat, duration: TimeInterval) -> some View {
        switch lane {
        case let .groupHeader(group):
            laneGroupTimeline(group, width: width, duration: duration)
                .overlay { laneDropHighlight(lane) }
                .transition(.timelineLane)
        case let .moreLayers(hidden):
            moreLayersTimeline(hidden, width: width)
                .overlay { laneDropHighlight(lane) }
                .transition(.timelineLane)
        default:
            postLaneTimeline(lane, width: width, duration: duration)
        }
    }
}

extension View {
    /// Mockup: no grid lines between lanes; only the main track carries a
    /// hairline above and below so it reads as the spine.
    func mainTrackHairlines() -> some View {
        overlay {
            VStack(spacing: 0) {
                Rectangle().fill(EditorTheme.chrome(0.075)).frame(height: 0.5)
                Spacer(minLength: 0)
                Rectangle().fill(EditorTheme.chrome(0.075)).frame(height: 0.5)
            }
            .allowsHitTesting(false)
        }
    }
}
