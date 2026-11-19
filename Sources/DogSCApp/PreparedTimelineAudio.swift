import AVFoundation
import Foundation
import RecorderCore

/// A cheap edit-decision composition over reusable source PCM. No rendered
/// timeline file, loudness scan or DSP is invalidated by a cut or fader edit.
final class PreparedTimelineAudio {
    // Only immutable source assets cross preparation tasks; composition edits stay isolated.
    struct Source: @unchecked Sendable {
        let owner: PreparedAudioSource
        let loaded: LoadedTimelineTrack
    }
    let composition: AVMutableComposition
    let normalized: Bool
    let sources: [AudioSourceKey: Source]
    private let bundle: TimelineCompositionBundle
    private let peaks: [CMPersistentTrackID: Float]

    private init(bundle: TimelineCompositionBundle, composition: AVMutableComposition,
                 normalized: Bool, sources: [AudioSourceKey: Source], peaks: [CMPersistentTrackID: Float]) {
        self.bundle = bundle
        self.composition = composition
        self.normalized = normalized
        self.sources = sources
        self.peaks = peaks
    }

    static func prepare(_ bundle: TimelineCompositionBundle, normalized: Bool,
                        reusing previous: PreparedTimelineAudio? = nil, cache: AudioSourceCache = .shared,
                        isolation: isolated (any Actor)? = #isolation) async throws -> PreparedTimelineAudio {
        guard normalized else {
            return PreparedTimelineAudio(bundle: bundle, composition: bundle.primaryComposition,
                normalized: false, sources: [:], peaks: [:])
        }
        let composition = bundle.primaryComposition.mutableCopy() as! AVMutableComposition
        var sources: [AudioSourceKey: Source] = [:]
        var peaks: [CMPersistentTrackID: Float] = [:]
        var versions: [URL: EditorMediaFileVersion] = [:]
        let microphoneID = bundle.microphoneAudioTrack?.trackID
        let systemID = bundle.systemAudioTrack?.trackID
        let voiceSourceIDs = Set(bundle.plan.sources.compactMap { id, source in
            source.manifest?.microphone != nil || source.microphoneRange != nil ? id : nil
        })
        var trackKeys: [[AudioSourceKey?]] = []
        var missing: [AudioSourceKey] = []
        var seen = Set<AudioSourceKey>()
        for original in bundle.mixedAudioTracks {
            var keys: [AudioSourceKey?] = []
            for segment in original.segments {
                if segment.isEmpty { keys.append(nil); continue }
                guard let url = segment.sourceURL else { throw VideoExporterError.exportFailed("声音素材地址无效") }
                let version = versions[url] ?? EditorMediaFileVersion(url: url)
                versions[url] = version
                let recordingID = original.trackID == systemID ? bundle.recordingSources.first {
                    $0.value.systemAudio?.asset.url.standardizedFileURL.path == version.standardizedPath
                        && $0.value.systemAudio?.track.trackID == segment.sourceTrackID
                }?.key : nil
                let boosts = original.trackID == microphoneID
                    || (original.trackID == systemID && recordingID.map { !voiceSourceIDs.contains($0) } == true)
                let key = AudioSourceKey(file: version, trackID: segment.sourceTrackID, boostsLoudness: boosts)
                keys.append(key)
                if seen.insert(key).inserted {
                    if let existing = previous?.sources[key] { sources[key] = existing }
                    else { missing.append(key) }
                }
            }
            trackKeys.append(keys)
        }
        // Independent recordings prepare concurrently, bounded to two readers
        // so a large project cannot flood storage or starve video decoding.
        try await withThrowingTaskGroup(of: (AudioSourceKey, Source).self) { group in
            func enqueue(_ key: AudioSourceKey) {
                group.addTask {
                    guard let owner = try await cache.source(for: key) else {
                        throw VideoExporterError.exportFailed("声音素材准备失败")
                    }
                    return (key, Source(owner: owner, loaded: try await owner.loadSource()))
                }
            }
            var next = 0
            while next < min(2, missing.count) { enqueue(missing[next]); next += 1 }
            while let (key, source) = try await group.next() {
                sources[key] = source
                if next < missing.count { enqueue(missing[next]); next += 1 }
            }
        }
        for (original, keys) in zip(bundle.mixedAudioTracks, trackKeys) {
            try Task.checkCancellation()
            if let copy = composition.track(withTrackID: original.trackID) { composition.removeTrack(copy) }
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: original.trackID)
            else { throw VideoExporterError.exportFailed("无法准备声音合成轨") }
            for (segment, key) in zip(original.segments, keys) {
                guard let key, let source = sources[key] else {
                    track.insertEmptyTimeRange(segment.timeMapping.target)
                    continue
                }
                peaks[original.trackID] = max(peaks[original.trackID] ?? 0, source.owner.peak)
                try track.insertTimeRange(segment.timeMapping.source, of: source.loaded.track,
                    at: segment.timeMapping.target.start)
                if segment.timeMapping.source.duration != segment.timeMapping.target.duration {
                    track.scaleTimeRange(CMTimeRange(start: segment.timeMapping.target.start,
                        duration: segment.timeMapping.source.duration), toDuration: segment.timeMapping.target.duration)
                }
            }
        }
        return PreparedTimelineAudio(bundle: bundle, composition: composition, normalized: true,
            sources: sources, peaks: peaks)
    }

    func tracks(includeExternalAudio: Bool = true) -> [AVCompositionTrack] {
        (includeExternalAudio ? bundle.mixedAudioTracks : bundle.recordingAudioTracks)
            .compactMap { composition.track(withTrackID: $0.trackID) }
    }

    private func source(_ original: LoadedTimelineTrack?, boosts: Bool) -> PreparedAudioSource? {
        guard let original else { return nil }
        return sources.first { $0.key.file.standardizedPath == original.asset.url.standardizedFileURL.path
            && $0.key.trackID == original.track.trackID && $0.key.boostsLoudness == boosts }?.value.owner
    }

    func mix(audio: AudioStyle, overrides: [UUID: PrimarySegmentAudioOverrides],
             externalClips: [AudioClip]? = nil, speech: [OverlayTiming]? = nil,
             includeExternalAudio: Bool = true) -> AVAudioMix? {
        // A recording with a dedicated microphone keeps system/background
        // audio at its recorded level. The policy follows source metadata,
        // including when an export omits a fully muted microphone track.
        let voiceSourceIDs = Set(bundle.plan.sources.compactMap { id, source in
            source.manifest?.microphone != nil || source.microphoneRange != nil ? id : nil
        })
        var masterGain: Float = 1
        if normalized {
            var events: [(time: Double, gain: Float)] = []
            for (segment, range) in zip(bundle.plan.timelineMap.segments,
                bundle.primarySegmentAudioMixRanges(audio: audio, overrides: overrides)) {
                guard segment.media == nil else { continue }
                let tracks = bundle.recordingSources[segment.sourceID]
                let peak = (source(tracks?.systemAudio, boosts: !voiceSourceIDs.contains(segment.sourceID))?.peak ?? 0) * range.systemTrackVolume
                    + (source(tracks?.microphone, boosts: true)?.peak ?? 0) * range.microphoneTrackVolume
                events.append((range.range.start.seconds, peak))
                events.append((range.range.end.seconds, -peak))
            }
            if includeExternalAudio {
                for external in bundle.externalAudioWithSegmentVolumes(overrides, externalClips: externalClips, speech: speech) {
                    let peak = (peaks[external.track.trackID] ?? 0)
                        * (external.clip.isMuted ? 0 : Float(min(max(external.clip.volume, 0), 1)))
                    events.append((external.clip.timing.startTime, peak))
                    events.append((external.clip.timing.endTime, -peak))
                }
            }
            var sum: Float = 0
            var maximum: Float = 0
            for event in events.sorted(by: { $0.time == $1.time ? $0.gain < $1.gain : $0.time < $1.time }) {
                sum += event.gain
                maximum = max(maximum, sum)
            }
            // Shared linear headroom prevents summed sources from clipping;
            // it changes only native volume coefficients, never PCM files.
            if maximum > AudioSourceProcessor.ceiling { masterGain = AudioSourceProcessor.ceiling / maximum }
        }
        return bundle.resolvedAudioMix(audio: audio, overrides: overrides, externalClips: externalClips,
            speech: speech, includeExternalAudio: includeExternalAudio, timePitchAlgorithm: .spectral,
            masterGain: masterGain)
    }
}
