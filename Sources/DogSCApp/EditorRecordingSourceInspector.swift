import RecorderCore
import SwiftUI

extension EditorInspectorView {
    /// 这一段来自哪份录制：缩略图、名字和它的尺寸时长，点进去在素材箱里
    /// 定位到它。尺寸和时长是认人用的，留在卡片上；源区间这类读数归「详情」。
    @ViewBuilder
    func recordingSourceCard(_ segment: ResolvedRecordingSegment) -> some View {
        if let source = editorStore.project.source(segment.sourceID) {
            Button { editorStore.revealRecording(source.id) } label: {
                HStack(spacing: 10) {
                    RecordingSourceThumbnail(url: RecordingSourcePresentation.url(source))
                        .frame(width: 54, height: 33.75).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if let color = RecordingSourcePresentation.color(source.id, in: editorStore.project) {
                                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
                            }
                            Text(RecordingSourcePresentation.name(source.id, in: editorStore.project))
                                .font(.appUI(size: 13, weight: .medium)).lineLimit(1)
                        }.foregroundStyle(RecordingDesign.ink)
                        let size = mediaSession.sourceDisplaySize(for: source.id) ?? .zero
                        Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) · \(RecordingSourcePresentation.duration(mediaSession.sourceDurations[source.id] ?? 0))")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(RecordingDesign.tertiary)
                    }
                    Spacer(minLength: 0)
                    AppLineIcon(kind: .chevron, size: 15).foregroundStyle(RecordingDesign.tertiary)
                }.padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RecordingDesign.fill, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
        }
    }

    /// 声音这一块只放能调的东西。「有没有录到麦克风/摄像头」是诊断，
    /// 它们和其他读数一起收在「详情」里。
    @ViewBuilder
    func recordingSourceSoundSection(_ segment: ResolvedRecordingSegment) -> some View {
        if sourceHasAudio || microphoneHasAudio {
            EditorInspectorSection("声音", icon: "speaker.wave.2") {
                if sourceHasAudio {
                    audioVolumeRow("系统声音", icon: .speaker, detail: "",
                        value: primarySegmentSystemVolumeBinding(segmentID: segment.id),
                        isMuted: primarySegmentSystemMuteBinding(segmentID: segment.id), commandScope: .selection,
                        accessibilityStem: "editor.recording.source.system")
                }
                if microphoneHasAudio {
                    audioVolumeRow("麦克风", icon: .microphone, detail: "",
                        value: primarySegmentMicrophoneVolumeBinding(segmentID: segment.id),
                        isMuted: primarySegmentMicrophoneMuteBinding(segmentID: segment.id), commandScope: .selection,
                        accessibilityStem: "editor.recording.source.microphone")
                }
            }
        }
    }

    /// 录了什么、没录什么，一行一项。
    func recordingAvailabilityRow(_ title: String, recorded: Bool) -> some View {
        HStack {
            Text(appLocalized(title)).foregroundStyle(RecordingDesign.secondary)
            Spacer()
            Text(appLocalized(recorded ? "已录制" : "未录制")).foregroundStyle(RecordingDesign.tertiary)
        }.font(.appUI(size: 11)).frame(minHeight: 22)
    }
}

/// Isolated from the large canvas view: only this small label polls the live
/// output clock while playing. It never invalidates the rendered monitor.
struct RecordingSourceCanvasBadge: View {
    static let visibilityKey = "editor.preview.showsRecordingName"
    @AppStorage(Self.visibilityKey) private var showsName = false
    let project: RecorderProject
    let mediaSession: EditorMediaSession
    @ObservedObject var playback: EditorPlaybackController
    let isCropping: Bool
    let rename: (UUID) -> Void
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying)) { _ in
            let time = playback.hoverPreviewTime ?? playback.latestOutputTime
            if let sourceID = mediaSession.sourceID(at: time), isCropping || (showsName && sourceID != RecordingSource.primaryID) {
                HStack(spacing: 6) {
                    if let color = RecordingSourcePresentation.color(sourceID, in: project) {
                        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
                    }
                    let name = RecordingSourcePresentation.name(sourceID, in: project)
                    Text(isCropping ? String(format: appLocalized("裁切 · %@"), name) : name)
                        .font(.appUI(size: 11.5, weight: .medium)).lineLimit(1)
                }.foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 1)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .contextMenu {
                        if sourceID != RecordingSource.primaryID {
                            Button(appLocalized("重命名录制…")) { rename(sourceID) }
                        }
                        if !isCropping {
                            Button(appLocalized("隐藏录制名称")) { showsName = false }
                        }
                    }
            }
        }
    }
}
