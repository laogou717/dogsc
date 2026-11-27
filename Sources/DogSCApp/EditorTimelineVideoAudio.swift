import AVFoundation
import RecorderCore
import SwiftUI

extension EditorTimelineView {
    @ViewBuilder
    func videoAudioMenu(for selection: EditorSelection) -> some View {
        let timeline = editorStore.project.timeline
        switch selection {
        case let .audioClip(id):
            if let origin = timeline.audioClips.first(where: { $0.id == id })?.videoOrigin {
                reattachAudioButton(group: origin.group)
            }
        case let .primarySegment(id), let .videoClip(id):
            let attachment = timeline.primarySegmentAudioOverrides[id]?.videoAudio ??
                timeline.videoClips.first(where: { $0.id == id })?.videoAudio
            if let group = attachment?.detachedGroup {
                reattachAudioButton(group: group)
            } else {
                Button {
                    detachVideoAudio(id)
                } label: {
                    EditorSymbolLabel("分离音频", systemImage: "waveform")
                }
                .disabled(detachableAudio(for: id).isEmpty)
            }
        default:
            EmptyView()
        }
    }

    private func reattachAudioButton(group: UUID) -> some View {
        let timeline = editorStore.project.timeline
        return Button {
            var current = editorStore.project.timeline
            let primary = timelineMap?.segments.first { current.primarySegmentAudioOverrides[$0.id]?.videoAudio?.detachedGroup == group }
            let overlay = current.videoClips.first { $0.videoAudio?.detachedGroup == group }
            guard current.reattachVideoAudio(group: group) else { return }
            do {
                try editorStore.replaceTimeline(with: current, actionName: "重新关联到原视频")
                if let primary { editorStore.selection = .primarySegment(primary.id) }
                else if let overlay { editorStore.selection = .videoClip(overlay.id) }
            } catch { onError(error.localizedDescription) }
        } label: {
            EditorSymbolLabel("重新关联到原视频", systemImage: "link")
        }
        .disabled(!timeline.hasDetachedVideo(group: group) || !timeline.audioClips.contains { $0.videoOrigin?.group == group })
    }

    private func detachVideoAudio(_ id: UUID) {
        let clips = detachableAudio(for: id)
        var timeline = editorStore.project.timeline
        guard let map = timelineMap else { return }
        let recording = map.segments.first { $0.id == id && $0.media == nil }
            .flatMap { mediaSession.mediaPlan?.sources[$0.sourceID] }
        let normalizeSystem = recording.map { $0.microphoneRange == nil && $0.manifest?.microphone == nil } ?? false
        guard let first = timeline.detachVideoAudio(from: id, map: map, clips: clips, normalizeSystemAsVoice: normalizeSystem) else { return }
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "分离音频")
            setPostLane(.audio, visible: true)
            if isLaneGroupCollapsed(.audio) { toggleLaneGroup(.audio) }
            editorStore.selection = .audioClip(first)
        } catch { onError(error.localizedDescription) }
    }

    private func detachableAudio(for id: UUID) -> [(audio: AudioClip, microphone: Bool)] {
        guard let prepared = mediaSession.prepared else { return [] }
        return Self.detachableAudio(for: id, project: editorStore.project, prepared: prepared)
    }

    static func detachableAudio(for id: UUID, project: RecorderProject, prepared: EditorPreparedMedia) -> [(audio: AudioClip, microphone: Bool)] {
        let timeline = project.timeline
        guard prepared.request.sourceSequence.withoutSceneStyles == timeline.sourceSequence.withoutSceneStyles else { return [] }
        let bundle = prepared.composition
        let overrides = timeline.primarySegmentAudioOverrides[id]
        if let segment = prepared.plan.timelineMap.segments.first(where: { $0.id == id }),
           segment.media == nil, overrides?.videoAudio == nil {
            guard let tracks = bundle.recordingSources[segment.sourceID] else { return [] }
            func clips(_ plan: TimelineMediaPlan?, _ track: LoadedTimelineTrack?, microphone: Bool) -> [(AudioClip, Bool)] {
                guard let track, let plan else { return [] }
                let volume = microphone ? overrides?.microphoneVolume ?? project.audio.microphoneVolume
                                        : overrides?.systemVolume ?? project.audio.systemVolume
                let muted = microphone ? overrides?.isMicrophoneMuted ?? project.audio.isMicrophoneMuted
                                       : overrides?.isSystemMuted ?? project.audio.isSystemMuted
                return plan.slices.filter { $0.segmentID == id }.map { slice in
                    (AudioClip(timing: .init(startTime: slice.outputStart, duration: slice.duration),
                        sourcePath: ProjectFiles.portable(track.asset.url.path),
                        sourceStart: max(0, slice.sourceStart - track.timeRange.start.seconds),
                        volume: volume, isMuted: muted, fadeIn: 0, fadeOut: 0,
                        kind: .effect, playbackRate: slice.sourceTimeScale), microphone)
                }
            }
            return clips(prepared.plan.systemAudio, tracks.systemAudio, microphone: false) +
                   clips(prepared.plan.microphone, tracks.microphone, microphone: true)
        }

        let overlay = timeline.videoClips.first { $0.id == id }
        let attachment = overlay?.videoAudio ?? overrides?.videoAudio
        if let attachment, case .linked = attachment {
            let clips: [AudioClip]
            if let overlay {
                clips = attachment.clips(for: id, timing: overlay.timing, sourceStart: overlay.sourceStart,
                                         rate: overlay.playbackRate, gain: { _ in overlay.volume })
            } else if let segment = prepared.plan.timelineMap.segments.first(where: { $0.id == id }) {
                clips = timeline.linkedPrimaryAudio(for: id, timing: .init(startTime: segment.outputStart, duration: segment.outputDuration),
                    sourceStart: segment.sourceStart, rate: segment.playbackRate, audio: project.audio)
            } else { return [] }
            return clips.map { ($0, $0.videoOrigin?.microphone == true) }
        }
        guard attachment == nil, let external = bundle.externalAudio.first(where: { $0.clip.id == id }) else { return [] }
        if let overlay {
            guard let current = timeline.programAudioClips(audio: project.audio).first(where: { $0.id == overlay.id }),
                  current.matchesCompositionStructure(of: external.clip) else { return [] }
            return [(current, false)]
        }
        guard let segment = prepared.plan.timelineMap.segments.first(where: { $0.id == id }),
              let media = segment.media, media.motionPath == nil, media.imagePath == nil else { return [] }
        var clip = external.clip
        clip.volume = overrides?.systemVolume ?? clip.volume
        clip.isMuted = overrides?.isSystemMuted == true
        return [(clip, false)]
    }
}
