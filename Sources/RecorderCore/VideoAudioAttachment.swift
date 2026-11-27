import CryptoKit
import Foundation

/// Maps the audio file clock back onto its original video's source clock,
/// including a microphone start delay or a calibrated clock-rate difference.
public struct VideoAudioOrigin: Codable, Equatable, Sendable {
    public var group: UUID
    public var isRecordingSound: Bool
    public var normalizesAsVoice: Bool
    public var microphone: Bool
    var videoTimeAtAudioZero: Double
    var videoSecondsPerAudioSecond: Double
    var videoRateAtDetach: Double
}

public enum VideoAudioAttachment: Codable, Equatable, Sendable {
    case detached(UUID, nativeParts: [AudioClip]?)
    /// Timing and playback rates here are relative to the video's source clock.
    case linked([AudioClip])

    public var detachedGroup: UUID? {
        if case let .detached(id, _) = self { return id }
        return nil
    }

    public mutating func relinkSource(from old: String, to new: String) {
        func updated(_ parts: [AudioClip]) -> [AudioClip] {
            parts.map { original in
                var part = original
                if part.sourcePath == old { part.sourcePath = new }
                return part
            }
        }
        switch self {
        case let .linked(parts): self = .linked(updated(parts))
        case let .detached(id, parts): self = .detached(id, nativeParts: parts.map(updated))
        }
    }

    public func clips(for owner: UUID, timing: OverlayTiming, sourceStart: Double, rate: Double,
               gain: (Bool) -> Double) -> [AudioClip] {
        guard case let .linked(parts) = self, rate > 0 else { return [] }
        return parts.compactMap { part -> AudioClip? in
            let start = max(sourceStart, part.timing.startTime)
            let end = min(sourceStart + timing.duration * rate, part.timing.endTime)
            guard end > start else { return nil }
            var clip = part
            // Splitting or copying a video also copies the local edit. Each
            // resulting composition track needs a stable, occurrence-specific ID.
            let bytes = Array(SHA256.hash(data: Data((owner.uuidString + part.id.uuidString).utf8)))
            clip.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                  bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            clip.sourceStart += (start - part.timing.startTime) * part.playbackRate
            clip.timing = OverlayTiming(startTime: timing.startTime + (start - sourceStart) / rate,
                                        duration: (end - start) / rate)
            clip.playbackRate *= rate
            clip.fadeIn = max(0, part.fadeIn - (start - part.timing.startTime)) / rate
            clip.fadeOut = max(0, part.fadeOut - (part.timing.endTime - end)) / rate
            clip.volume *= gain(part.videoOrigin?.microphone == true)
            return clip
        }
    }
}

private extension AudioClip {
    var videoLocalEdit: AudioClip? {
        guard let origin = videoOrigin else { return nil }
        var part = self
        part.timing = .init(startTime: origin.videoTimeAtAudioZero + sourceStart * origin.videoSecondsPerAudioSecond,
                            duration: timing.duration * origin.videoRateAtDetach)
        part.playbackRate /= origin.videoRateAtDetach
        part.fadeIn *= origin.videoRateAtDetach
        part.fadeOut *= origin.videoRateAtDetach
        part.lane = 0
        return part
    }
}

public extension ProjectTimeline {
    func linkedPrimaryAudioClips(audio: AudioStyle) -> [AudioClip] {
        guard case let .edited(segments) = sourceSequence,
              primarySegmentAudioOverrides.values.contains(where: { $0.videoAudio != nil }) else { return [] }
        var time = 0.0
        return segments.flatMap { segment -> [AudioClip] in
            defer { time += segment.outputDuration }
            return linkedPrimaryAudio(for: segment.id, timing: .init(startTime: time, duration: segment.outputDuration),
                                      sourceStart: segment.sourceStart, rate: segment.playbackRate, audio: audio)
        }
    }

    func linkedPrimaryAudio(for id: UUID, timing: OverlayTiming, sourceStart: Double, rate: Double, audio: AudioStyle) -> [AudioClip] {
        guard let settings = primarySegmentAudioOverrides[id], let attachment = settings.videoAudio else { return [] }
        return attachment.clips(for: id, timing: timing, sourceStart: sourceStart, rate: rate) { mic in
            if mic { return (settings.isMicrophoneMuted ?? audio.isMicrophoneMuted) ? 0 : settings.microphoneVolume ?? audio.microphoneVolume }
            return (settings.isSystemMuted ?? audio.isSystemMuted) ? 0 : settings.systemVolume ?? audio.systemVolume
        }
    }

    /// A paste creates new occurrences. Only sounds copied together with a
    /// detached owner should be able to reattach to that copy.
    mutating func isolateCopiedVideoAudio(ids: Set<UUID>) {
        var groups: [UUID: UUID] = [:]
        func copyGroup(_ old: UUID) -> UUID {
            if let existing = groups[old] { return existing }
            let new = UUID()
            groups[old] = new
            return new
        }
        for index in videoClips.indices where ids.contains(videoClips[index].id) {
            if let old = videoClips[index].videoAudio?.detachedGroup {
                videoClips[index].videoAudio = .detached(copyGroup(old), nativeParts: nil)
            }
        }
        for id in ids {
            if let old = primarySegmentAudioOverrides[id]?.videoAudio?.detachedGroup {
                primarySegmentAudioOverrides[id]?.videoAudio = .detached(copyGroup(old), nativeParts: nil)
            }
        }
        for index in audioClips.indices where ids.contains(audioClips[index].id) {
            if let old = audioClips[index].videoOrigin?.group {
                audioClips[index].videoOrigin?.group = copyGroup(old)
            }
        }
    }

    /// Each split descendant retains the same group while the sound is independent.
    func hasDetachedVideo(group: UUID) -> Bool {
        videoClips.contains { $0.videoAudio?.detachedGroup == group } ||
            primarySegmentAudioOverrides.values.contains { $0.videoAudio?.detachedGroup == group }
    }

    /// The caller supplies only sources present in the playback composition.
    /// Convert their real placements instead of assuming the mic starts at frame zero.
    @discardableResult
    mutating func detachVideoAudio(from id: UUID, map: TimelineMap, clips: [(audio: AudioClip, microphone: Bool)],
                                   normalizeSystemAsVoice: Bool = false) -> UUID? {
        guard !clips.isEmpty else { return nil }
        let group = UUID()
        let outputStart: Double, sourceStart: Double, rate: Double
        let isNative: Bool, recording: Bool
        let overlayIndex = videoClips.firstIndex { $0.id == id }
        if let index = overlayIndex {
            let video = videoClips[index]
            guard video.videoAudio?.detachedGroup == nil else { return nil }
            outputStart = video.timing.startTime
            sourceStart = video.sourceStart
            rate = video.playbackRate
            recording = false
            isNative = video.videoAudio == nil
        } else if let segment = map.segments.first(where: { $0.id == id }) {
            guard primarySegmentAudioOverrides[id]?.videoAudio?.detachedGroup == nil else { return nil }
            outputStart = segment.outputStart
            sourceStart = segment.sourceStart
            rate = segment.playbackRate
            if case .fullRecording = sourceSequence {
                sourceSequence = .edited([.init(id: id, sourceStart: sourceStart, sourceDuration: segment.sourceDuration)])
            }
            recording = segment.media == nil
            isNative = primarySegmentAudioOverrides[id]?.videoAudio == nil
        } else { return nil }

        var detached: [AudioClip] = []
        for (var clip, microphone) in clips {
            let ratio = rate / clip.playbackRate
            let videoTime = sourceStart + (clip.timing.startTime - outputStart) * rate
            clip.videoOrigin = VideoAudioOrigin(group: group, isRecordingSound: clip.videoOrigin?.isRecordingSound ?? recording,
                normalizesAsVoice: clip.videoOrigin?.normalizesAsVoice ?? (microphone || normalizeSystemAsVoice), microphone: microphone,
                videoTimeAtAudioZero: videoTime - clip.sourceStart * ratio,
                videoSecondsPerAudioSecond: ratio, videoRateAtDetach: rate)
            clip.id = UUID()
            let occupied = Set(audioClips.filter {
                $0.timing.startTime < clip.timing.endTime && clip.timing.startTime < $0.timing.endTime
            }.map(\.lane))
            clip.lane = (0...).first(where: { !occupied.contains($0) }) ?? 0
            audioClips.append(clip)
            detached.append(clip)
        }
        let attachment = VideoAudioAttachment.detached(group, nativeParts: isNative ? detached.compactMap(\.videoLocalEdit) : nil)
        if let overlayIndex { videoClips[overlayIndex].videoAudio = attachment }
        else { primarySegmentAudioOverrides[id, default: .init()].videoAudio = attachment }
        return detached.first?.id
    }

    /// Return the surviving edits to their video-source positions. The free
    /// timeline placement no longer owns sync. Trims, fades and gain survive.
    @discardableResult
    mutating func reattachVideoAudio(group: UUID) -> Bool {
        guard hasDetachedVideo(group: group) else { return false }
        let parts = audioClips.filter { $0.videoOrigin?.group == group }.compactMap(\.videoLocalEdit)
        func restoresNative(_ attachment: VideoAudioAttachment?) -> Bool {
            guard case let .detached(_, original?) = attachment else { return false }
            // Moving between lanes or in output time leaves the source edit untouched.
            return original.count == parts.count && original.allSatisfy(parts.contains)
        }
        guard !parts.isEmpty else { return false }
        for index in videoClips.indices where videoClips[index].videoAudio?.detachedGroup == group {
            if restoresNative(videoClips[index].videoAudio) {
                videoClips[index].videoAudio = nil
                continue
            }
            videoClips[index].videoAudio = .linked(parts)
            videoClips[index].volume = 1
        }
        for (id, var settings) in primarySegmentAudioOverrides where settings.videoAudio?.detachedGroup == group {
            if restoresNative(settings.videoAudio) {
                settings.videoAudio = nil
                primarySegmentAudioOverrides[id] = settings.isEmpty ? nil : settings
                continue
            }
            settings.videoAudio = .linked(parts)
            // Part gains already include the effective mix at detachment.
            settings.systemVolume = 1
            settings.isSystemMuted = false
            settings.microphoneVolume = 1
            settings.isMicrophoneMuted = false
            primarySegmentAudioOverrides[id] = settings
        }
        audioClips.removeAll { $0.videoOrigin?.group == group }
        return true
    }
}
