import AppKit
import RecorderCore
import SwiftUI

struct EditorRecordingMarker: Identifiable {
    let marker: RecordingMarker
    let outputTime: TimeInterval
    var id: UUID { marker.id }
    var label: String { String(format: appLocalized("标记 %d"), marker.number) }
    var timestamp: String {
        let value = max(Int((outputTime * 100).rounded(.down)), 0)
        return String(format: "%02d:%02d.%02d", value / 6000, (value / 100) % 60, value % 100)
    }
}

extension EditorTimelineView {
    var recordingMarkers: [EditorRecordingMarker] {
        guard let timelineMap else { return [] }
        return derivedPresentationCache.recordingMarkers(editorStore.project.recordingMarkers, map: timelineMap)
    }

    @ViewBuilder var recordingMarkerMenu: some View {
        if !editorStore.project.recordingMarkers.isEmpty {
            EditorMarkerListControl(markers: recordingMarkers, seek: seekRecordingMarker, remove: removeRecordingMarker)
        }
    }

    @ViewBuilder func recordingMarkerRuler(width: CGFloat, duration: TimeInterval,
                                           visibleRange: ClosedRange<TimeInterval>) -> some View {
        if !isRestoreCutMode && primaryTrimDraft == nil && primaryReorderDraft == nil {
            let markers = recordingMarkers
            let indices = EditorTimelineViewportPresentation.visiblePointIndices(
                in: markers, timeRange: visibleRange, time: \.outputTime)
            ForEach(indices, id: \.self) { index in
                let item = markers[index]
                Button { seekRecordingMarker(item) } label: {
                    TimelineRecordingBookmarkShape()
                        .fill(Color(red: 0.65, green: 0.47, blue: 0.22))
                        .frame(width: 8, height: 10)
                        .frame(width: 18, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TimelineRecordingBookmarkButtonStyle())
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 4))
                .help(item.label + " · " + timelineTimestamp(item.outputTime))
                .accessibilityLabel(item.label)
                .accessibilityValue(timelineTimestamp(item.outputTime))
                .contextMenu {
                    Button("跳转到标记") { seekRecordingMarker(item) }
                    Button("删除录制标记", role: .destructive) { removeRecordingMarker(item.id) }
                }
                .offset(x: CGFloat(item.outputTime / max(duration, 0.001)) * width - 9,
                        y: timelineRulerHeight - 21)
            }
        }
    }

    func seekRecordingMarker(_ item: EditorRecordingMarker) {
        seekTimeline(to: item.outputTime)
        guard let scrollView = timelineScrollView else { return }
        let viewport = scrollView.documentVisibleRect
        let width = max(scrollView.documentView?.bounds.width ?? timelineContentWidth, viewport.width)
        let x = CGFloat(item.outputTime / max(timelineDuration, 0.001)) * timelineContentWidth
        guard x < viewport.minX + 24 || x > viewport.maxX - 24 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: min(max(x - viewport.width * 0.4, 0), max(width - viewport.width, 0)),
                                                  y: viewport.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func removeRecordingMarker(_ id: UUID) {
        do {
            try editorStore.commitInteraction()
            var project = editorStore.project
            project.recordingMarkers.removeAll { $0.id == id }
            try editorStore.replaceProject(with: project, actionName: "删除录制标记")
        } catch { onError(error.localizedDescription) }
    }
}

/// A small ruler notch, not a toolbar button. The wider transparent hit area
/// remains easy to click; its colour and shape leave the time labels readable.
private struct TimelineRecordingBookmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 1), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 3))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 1))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 1, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

private struct TimelineRecordingBookmarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}
