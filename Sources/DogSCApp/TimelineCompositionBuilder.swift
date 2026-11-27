import AVFoundation
import Foundation
import OSLog
import RecorderCore

enum TimelineCompositionError: LocalizedError, Equatable {
    case emptyPrimaryPlan
    case cannotCreateTrack(String)
    case invalidSlice(role: String, segmentID: UUID)
    case sliceOutsideSource(role: String, segmentID: UUID)
    case insertionFailed(role: String, segmentID: UUID, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyPrimaryPlan:
            return appLocalized("剪辑后的主录屏时间线为空，无法预览或导出。")
        case let .cannotCreateTrack(role):
            return String(format: appLocalized("无法为%@创建剪辑合成轨。"), appLocalized(role))
        case let .invalidSlice(role, _):
            return String(format: appLocalized("%@片段的时间范围无效，无法准备预览。"), appLocalized(role))
        case let .sliceOutsideSource(role, _):
            return String(format: appLocalized("%@片段超出素材可用范围，请重新调整或还原该片段。"), appLocalized(role))
        case let .insertionFailed(role, _, _):
            return String(format: appLocalized("无法合成%@片段。请确认项目素材仍然可读，然后重新打开项目。"), appLocalized(role))
        }
    }
}

/// Immutable AVFoundation media prepared from `ProjectTimelineMediaPlan`.
/// Both preview and export read these same output-clock compositions.
struct TimelineCompositionBundle {
    let plan: ProjectTimelineMediaPlan
    let primaryComposition: AVMutableComposition
    let primaryVideoTrack: AVMutableCompositionTrack
    let primaryVideoTracks: [AVMutableCompositionTrack]
    let primaryVideoComposition: AVVideoComposition?
    let systemAudioTrack: AVMutableCompositionTrack?
    let microphoneAudioTrack: AVMutableCompositionTrack?
    let cameraComposition: AVMutableComposition?
    let cameraVideoTrack: AVMutableCompositionTrack?
    /// EDT-054: music and sound effects mixed into the primary composition.
    var externalAudio: [TimelineExternalAudioTrack] = []
    var recordingSources: [UUID: TimelineRecordingSourceTracks] = [:]
    var insertedSources: [String: LoadedTimelineTrack] = [:]

    var recordingAudioTracks: [AVMutableCompositionTrack] {
        [systemAudioTrack, microphoneAudioTrack].compactMap { $0 }
    }

    var speechAudioTracks: [AVMutableCompositionTrack] {
        recordingAudioTracks + externalAudio.filter { $0.clip.videoOrigin?.isRecordingSound == true }.map(\.track)
    }

    /// The reader must receive every mix input. Audio-mix parameters alone
    /// cannot include music, motion sounds or imported video audio in its output.
    var mixedAudioTracks: [AVMutableCompositionTrack] {
        recordingAudioTracks + externalAudio.map(\.track)
    }

    /// Main-track inserts use the same per-segment volume/undo data as a
    /// recording, and external audio/video overlay clips can also update their
    /// gain/mute/fades/ducking at mix time without rebuilding compositions.
    func externalAudioWithSegmentVolumes(
        _ overrides: [UUID: PrimarySegmentAudioOverrides],
        externalClips: [AudioClip]? = nil,
        speech: [OverlayTiming]? = nil
    ) -> [TimelineExternalAudioTrack] {
        let insertedIDs = Set(plan.primary.slices.filter { $0.media != nil }.map(\.segmentID))
        let liveClipsByID: [UUID: AudioClip]? = externalClips.map { clips in
            clips.reduce(into: [:]) { $0[$1.id] = $1 }
        }
        return externalAudio.map { external in
            if insertedIDs.contains(external.clip.id) {
                guard let value = overrides[external.clip.id] else { return external }
                var clip = external.clip
                clip.volume = value.isSystemMuted == true ? 0 : (value.systemVolume ?? clip.volume)
                clip.isMuted = value.videoAudio != nil || value.isSystemMuted == true
                return TimelineExternalAudioTrack(track: external.track, clip: clip, speech: external.speech)
            }
            guard let liveClipsByID else { return external }
            var clip = external.clip
            if let live = liveClipsByID[clip.id] {
                clip.volume = live.volume
                clip.isMuted = live.isMuted
                clip.fadeIn = live.fadeIn
                clip.fadeOut = live.fadeOut
                clip.ducksUnderSpeech = live.ducksUnderSpeech
                clip.kind = live.kind
            }
            return TimelineExternalAudioTrack(
                track: external.track,
                clip: clip,
                speech: speech ?? external.speech
            )
        }
    }

    /// Cut-only edits at 1× must remain sample-accurate joins. Running those
    /// joins through a time-pitch processor can soften audio around segment
    /// boundaries even though the user never authored a fade. Only enable the
    /// processor when at least one primary slice is genuinely retimed.
    var requiresAudioTimePitchProcessing: Bool {
        plan.primary.slices.contains {
            abs($0.sourceTimeScale - 1) > 0.000_001
        }
    }

    func primarySegmentAudioMixRanges(
        audio: AudioStyle,
        overrides: [UUID: PrimarySegmentAudioOverrides]
    ) -> [TimelineSegmentAudioMixRange] {
        plan.timelineMap.segments.map { segment in
            let segmentOverrides = overrides[segment.id]
                ?? PrimarySegmentAudioOverrides()
            let systemIsMuted = segmentOverrides.isSystemMuted
                ?? audio.isSystemMuted
            let microphoneIsMuted = segmentOverrides.isMicrophoneMuted
                ?? audio.isMicrophoneMuted
            let systemVolume = systemIsMuted || segmentOverrides.videoAudio != nil
                ? 0
                : min(max(segmentOverrides.systemVolume ?? audio.systemVolume, 0), 1)
            let microphoneVolume = microphoneIsMuted || segmentOverrides.videoAudio != nil
                ? 0
                : min(max(segmentOverrides.microphoneVolume ?? audio.microphoneVolume, 0), 1)
            return TimelineSegmentAudioMixRange(
                range: CMTimeRange(
                    start: Self.audioBoundary(segment.outputStart),
                    end: Self.audioBoundary(segment.outputEnd)
                ),
                systemTrackVolume: Float(systemVolume),
                microphoneTrackVolume: Float(microphoneVolume)
            )
        }
    }

    func resolvedAudioMix(
        audio: AudioStyle,
        overrides: [UUID: PrimarySegmentAudioOverrides],
        externalClips: [AudioClip]? = nil,
        speech: [OverlayTiming]? = nil,
        includeExternalAudio: Bool = true,
        timePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral,
        masterGain: Float = 1
    ) -> AVAudioMix? {
        let baseMicVolume = audio.isMicrophoneMuted
            ? 0
            : Float(min(max(audio.microphoneVolume, 0), 1))
        let baseSysVolume = audio.isSystemMuted
            ? 0
            : Float(min(max(audio.systemVolume, 0), 1))
        let ranges = zip(plan.timelineMap.segments, primarySegmentAudioMixRanges(audio: audio, overrides: overrides)).map {
            TimelineSegmentAudioMixRange(range: $0.1.range,
                systemTrackVolume: $0.1.systemTrackVolume * masterGain,
                microphoneTrackVolume: $0.1.microphoneTrackVolume * masterGain)
        }
        return TimelineCompositionBuilder.audioMix(
            systemTrack: systemAudioTrack,
            systemVolume: baseSysVolume * masterGain,
            primarySegmentRanges: ranges,
            externalAudio: externalAudioWithSegmentVolumes(overrides, externalClips: externalClips, speech: speech)
                .filter { includeExternalAudio || $0.clip.videoOrigin?.isRecordingSound == true },
            microphoneTrack: microphoneAudioTrack,
            microphoneVolume: baseMicVolume * masterGain,
            requiresTimePitchProcessing: requiresAudioTimePitchProcessing,
            timePitchAlgorithm: timePitchAlgorithm, masterGain: masterGain
        )
    }

    private static func audioBoundary(_ seconds: Double) -> CMTime {
        CMTime(value: Int64((seconds * 1_000_000_000).rounded()), timescale: 1_000_000_000)
    }
}

struct TimelineSegmentAudioMixRange: Equatable, Sendable {
    let range: CMTimeRange
    let systemTrackVolume: Float
    let microphoneTrackVolume: Float
}

struct TimelineCameraComposition {
    let composition: AVMutableComposition
    let track: AVMutableCompositionTrack
}

enum TimelineCompositionBuilder {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "timeline-composition"
    )

    static func build(
        plan: ProjectTimelineMediaPlan,
        sources: [UUID: TimelineRecordingSourceTracks],
        audioClips: [AudioClip] = [],
        speech: [OverlayTiming] = [],
        insertedVideo: [String: LoadedTimelineTrack] = [:]
    ) throws -> TimelineCompositionBundle {
        guard plan.outputDuration.isFinite, plan.outputDuration > 0, !plan.primary.slices.isEmpty else {
            throw TimelineCompositionError.emptyPrimaryPlan
        }
        let primaryComposition = AVMutableComposition()
        let primaryVideoTrack = try insert(
            plan: plan.primary, sources: sources.mapValues(\.screen),
            sourceTimeOffsets: plan.sourceTimeOffsets, mediaType: .video, role: "主轨画面",
            into: primaryComposition, inserted: insertedVideo)
        func audioTrack(_ plan: TimelineMediaPlan?, sources: [UUID: LoadedTimelineTrack], role: String) throws -> AVMutableCompositionTrack? {
            guard let plan, !plan.slices.isEmpty, !sources.isEmpty else { return nil }
            return try insert(plan: plan, sources: sources, sourceTimeOffsets: [:], mediaType: .audio,
                              role: role, into: primaryComposition, allowsMissingSources: true)
        }
        let systemAudioTrack = try audioTrack(plan.systemAudio, sources: sources.compactMapValues(\.systemAudio), role: "系统声音")
        let microphoneTrack = try audioTrack(plan.microphone, sources: sources.compactMapValues(\.microphone), role: "麦克风")
        let camera = try buildCamera(plan: plan.camera, sources: sources.compactMapValues(\.camera))
        let clips = audioClips + insertedAudioClips(plan.primary)
        let externalAudio = insertExternalAudio(clips, into: primaryComposition, outputDuration: plan.outputDuration)
            .map { track -> TimelineExternalAudioTrack in var track = track; track.speech = speech; return track }
        var bundle = TimelineCompositionBundle(
            plan: plan, primaryComposition: primaryComposition, primaryVideoTrack: primaryVideoTrack,
            primaryVideoTracks: [primaryVideoTrack], primaryVideoComposition: nil,
            systemAudioTrack: systemAudioTrack, microphoneAudioTrack: microphoneTrack,
            cameraComposition: camera?.composition, cameraVideoTrack: camera?.track)
        bundle.externalAudio = externalAudio
        bundle.recordingSources = sources
        bundle.insertedSources = insertedVideo
        return bundle
    }

    /// Inserts each music/effect clip as its own audio track at its output
    /// time. Missing or unreadable files are skipped, never fatal.
    /// The sound of main-track inserted videos, placed like audio clips.
    static func insertedAudioClips(_ plan: TimelineMediaPlan) -> [AudioClip] {
        plan.slices.compactMap { slice in
            guard let media = slice.media else { return nil }
            guard media.hasEmbeddedAudio else { return nil }
            // A live HTML motion's sound is its own file beside the stand-in.
            var clip = AudioClip(
                id: slice.segmentID,
                timing: OverlayTiming(startTime: slice.outputStart, duration: slice.duration),
                sourcePath: media.transferSound?.path ?? media.soundPath ?? media.path,
                sourceStart: slice.sourceStart,
                volume: media.transferSound?.volume ?? 1, fadeIn: media.transferSound?.fadeIn ?? 0,
                fadeOut: media.transferSound?.fadeOut ?? 0, kind: .effect, playbackRate: slice.sourceTimeScale)
            clip.ducksUnderSpeech = false
            return clip
        }
    }

    /// Loads the video track of every file inserted on the main track.
    static func loadInsertedVideo(for plan: TimelineMediaPlan) async -> [String: LoadedTimelineTrack] {
        var result: [String: LoadedTimelineTrack] = [:]
        for path in Set(plan.slices.compactMap { $0.media?.path }) {
            let url = ProjectFiles.url(path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let loaded = try? await TimelinePreviewCompositionLoader.loadTrack(at: url, mediaType: .video, role: "插入视频") else { continue }
            result[path] = loaded
        }
        return result
    }

    static func insertExternalAudio(
        _ clips: [AudioClip],
        into composition: AVMutableComposition,
        outputDuration: TimeInterval
    ) -> [TimelineExternalAudioTrack] {
        clips.compactMap { clip in
            let url = ProjectFiles.url(clip.sourcePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let asset = AVURLAsset(url: url)
            guard let source = asset.tracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            let available = source.timeRange
            guard clip.playbackRate.isFinite, clip.playbackRate > 0 else { return nil }
            let start = CMTime(seconds: clip.sourceStart, preferredTimescale: 48_000) + available.start
            let length = min(clip.timing.duration, max(outputDuration - clip.timing.startTime, 0),
                             max(available.end.seconds - start.seconds, 0) / clip.playbackRate)
            guard length >= 1 / 48_000.0 else { return nil }
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: start, duration: CMTime(seconds: length * clip.playbackRate, preferredTimescale: 48_000)),
                    of: source,
                    at: CMTime(seconds: clip.timing.startTime, preferredTimescale: 48_000)
                )
                if abs(clip.playbackRate - 1) > 0.000_001 {
                    track.scaleTimeRange(CMTimeRange(start: CMTime(seconds: clip.timing.startTime, preferredTimescale: 48_000),
                        duration: CMTime(seconds: length * clip.playbackRate, preferredTimescale: 48_000)),
                        toDuration: CMTime(seconds: length, preferredTimescale: 48_000))
                }
            } catch { return nil }
            return TimelineExternalAudioTrack(track: track, clip: clip)
        }
    }

    /// Camera-only timing rebuild used by the interactive sync editor. It
    /// reuses the already loaded source track and leaves the audio-bearing
    /// primary composition untouched.
    @available(*, deprecated, message: "Use buildCamera(plan:sources:) with source-scoped camera tracks.")
    static func buildCamera(plan: TimelineMediaPlan?, source: EditorPreparedCameraSource?) throws -> TimelineCameraComposition? {
        let sources = source.map { [RecordingSource.primaryID: LoadedTimelineTrack(asset: $0.asset,
            track: $0.track, timeRange: $0.timeRange, preferredTransform: $0.preferredTransform, displaySize: nil)] } ?? [:]
        return try buildCamera(plan: plan, sources: sources)
    }

    static func buildCamera(plan: TimelineMediaPlan?, sources: [UUID: LoadedTimelineTrack]) throws -> TimelineCameraComposition? {
        guard let plan, !plan.slices.isEmpty, !sources.isEmpty else { return nil }
        let composition = AVMutableComposition()
        let track = try insert(plan: plan, sources: sources, sourceTimeOffsets: [:], mediaType: .video,
            role: "摄像头", into: composition, allowsMissingSources: true)
        return TimelineCameraComposition(composition: composition, track: track)
    }

    static func audioMix(
        systemTrack: AVCompositionTrack?,
        systemVolume: Float,
        primarySegmentRanges: [TimelineSegmentAudioMixRange] = [],
        externalAudio: [TimelineExternalAudioTrack] = [],
        microphoneTrack: AVCompositionTrack?,
        microphoneVolume: Float,
        requiresTimePitchProcessing: Bool = false,
        timePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral,
        masterGain: Float = 1
    ) -> AVAudioMix? {
        var parameters: [AVAudioMixInputParameters] = externalAudio.map { $0.mixParameters(masterGain: masterGain, timePitchAlgorithm: timePitchAlgorithm) }
        if let systemTrack {
            let spans: [TimelineAudioEnvelope.Span] = primarySegmentRanges.map {
                .init(start: $0.range.start.seconds, end: $0.range.end.seconds,
                      gain: $0.systemTrackVolume)
            }
            let input = TimelineAudioEnvelope.parameters(track: systemTrack,
                defaultGain: systemVolume, spans: spans)
            if requiresTimePitchProcessing {
                input.audioTimePitchAlgorithm = timePitchAlgorithm
            }
            parameters.append(input)
        }
        if let microphoneTrack {
            let spans: [TimelineAudioEnvelope.Span] = primarySegmentRanges.map {
                .init(start: $0.range.start.seconds, end: $0.range.end.seconds,
                      gain: $0.microphoneTrackVolume)
            }
            let input = TimelineAudioEnvelope.parameters(track: microphoneTrack,
                defaultGain: microphoneVolume, spans: spans)
            if requiresTimePitchProcessing {
                input.audioTimePitchAlgorithm = timePitchAlgorithm
            }
            parameters.append(input)
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func insert(
        plan: TimelineMediaPlan,
        sources: [UUID: LoadedTimelineTrack],
        sourceTimeOffsets: [UUID: TimeInterval],
        mediaType: AVMediaType,
        role: String,
        into composition: AVMutableComposition,
        inserted: [String: LoadedTimelineTrack] = [:],
        allowsMissingSources: Bool = false
    ) throws -> AVMutableCompositionTrack {
        guard let destination = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TimelineCompositionError.cannotCreateTrack(role)
        }
        // Preserve the legacy one-source transform for native preview clients.
        // Multi-source consumers orient each decoded frame with its own slice.
        if mediaType == .video, sources.count == 1, inserted.isEmpty {
            destination.preferredTransform = sources.values.first?.preferredTransform ?? .identity
        }
        let epsilon = 1.0 / 120_000.0
        for slice in plan.slices {
            let loaded: LoadedTimelineTrack?
            let offset: TimeInterval
            if let media = slice.media {
                loaded = inserted[media.path]
                offset = loaded?.timeRange.start.seconds ?? 0
            } else {
                loaded = sources[slice.sourceID]
                offset = sourceTimeOffsets[slice.sourceID] ?? 0
            }
            guard let loaded else {
                if slice.media != nil {
                    destination.insertEmptyTimeRange(CMTimeRange(
                        start: CMTime(seconds: slice.outputStart, preferredTimescale: 60_000),
                        duration: CMTime(seconds: slice.duration, preferredTimescale: 60_000)))
                    continue
                }
                if allowsMissingSources { continue }
                throw TimelineCompositionError.invalidSlice(role: role, segmentID: slice.segmentID)
            }
            let actualSourceStart = offset + slice.sourceStart
            let sourceDuration = slice.media == nil ? slice.duration * slice.sourceTimeScale
                : min(slice.duration * slice.sourceTimeScale, max(loaded.timeRange.end.seconds - actualSourceStart, 0))
            if sourceDuration <= 0, slice.media != nil {
                destination.insertEmptyTimeRange(CMTimeRange(
                    start: CMTime(seconds: slice.outputStart, preferredTimescale: 60_000),
                    duration: CMTime(seconds: slice.duration, preferredTimescale: 60_000)))
                continue
            }
            let actualSourceEnd = actualSourceStart + sourceDuration
            guard slice.outputStart.isFinite, actualSourceStart.isFinite, slice.duration.isFinite,
                  slice.outputStart >= 0, slice.duration > 0 else {
                throw TimelineCompositionError.invalidSlice(role: role, segmentID: slice.segmentID)
            }
            guard actualSourceStart >= loaded.timeRange.start.seconds - epsilon,
                  actualSourceEnd <= loaded.timeRange.end.seconds + epsilon else {
                throw TimelineCompositionError.sliceOutsideSource(role: role, segmentID: slice.segmentID)
            }
            let sourceRange = CMTimeRange(start: CMTime(seconds: actualSourceStart, preferredTimescale: 60_000),
                                          duration: CMTime(seconds: sourceDuration, preferredTimescale: 60_000))
            let outputStart = CMTime(seconds: slice.outputStart, preferredTimescale: 60_000)
            do {
                try destination.insertTimeRange(sourceRange, of: loaded.track, at: outputStart)
                if abs(sourceDuration - slice.duration) > 0.000_001 {
                    destination.scaleTimeRange(CMTimeRange(start: outputStart, duration: sourceRange.duration),
                        toDuration: CMTime(seconds: slice.duration, preferredTimescale: 60_000))
                }
            } catch {
                throw TimelineCompositionError.insertionFailed(role: role, segmentID: slice.segmentID, reason: error.localizedDescription)
            }
        }
        return destination
    }

}

enum TimelinePreviewMediaError: LocalizedError {
    case missingPrimaryRecording
    /// An imported recording must name itself: blaming the primary recording
    /// sends the user to a file that is perfectly healthy.
    case missingImportedRecording(name: String)
    case missingDeclaredMedia(String)
    case missingImportedDeclaredMedia(name: String, role: String)
    case missingTrack(String)
    case invalidTrackRange(String)

    var errorDescription: String? {
        switch self {
        case .missingPrimaryRecording:
            return appLocalized("找不到主录屏素材，无法构建剪辑预览。")
        case let .missingImportedRecording(name):
            return String(format: appLocalized("找不到录制「%@」的屏幕素材，无法构建剪辑预览。"), name)
        case let .missingDeclaredMedia(role):
            return String(format: appLocalized("项目声明包含%@，但素材文件不可用。"), appLocalized(role))
        case let .missingImportedDeclaredMedia(name, role):
            return String(format: appLocalized("录制「%@」声明包含%@，但素材文件不可用。"), name, appLocalized(role))
        case let .missingTrack(role):
            return String(format: appLocalized("%@素材中没有可用轨道。"), appLocalized(role))
        case let .invalidTrackRange(role):
            return String(format: appLocalized("%@素材的时间范围无效。"), appLocalized(role))
        }
    }

    /// Re-attributes a failure raised while loading an imported recording,
    /// which the shared loader can only report as the primary recording.
    func attributed(to name: String) -> TimelinePreviewMediaError {
        switch self {
        case .missingPrimaryRecording:
            return .missingImportedRecording(name: name)
        case let .missingDeclaredMedia(role):
            return .missingImportedDeclaredMedia(name: name, role: role)
        default:
            return self
        }
    }
}

struct LoadedTimelineTrack {
    /// Keep the source alive for as long as its track is used. Returning only
    /// the track from an async loader can make later composition insertion
    /// fail with AVFoundation -11800 / OSStatus -12780.
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let preferredTransform: CGAffineTransform
    let displaySize: CGSize?
}

/// Original assets and tracks stay alive across cut-only composition rebuilds.
/// This cache belongs to the editor payload, never to a global URL-only cache.
struct TimelineRecordingSourceTracks {
    let screen: LoadedTimelineTrack
    let systemAudio: LoadedTimelineTrack?
    let camera: LoadedTimelineTrack?
    let microphone: LoadedTimelineTrack?
    let cameraContentCrop: NormalizedCrop?
    let pointerEvents: [PointerEventRecord]

    var usesCameraAsPrimary: Bool { camera?.track === screen.track }
}

extension TimelineMediaSlice {
    func sharesCameraFrame(with camera: TimelineMediaSlice?, at time: TimeInterval, sourceOffset: TimeInterval) -> Bool {
        guard media == nil, let camera, sourceID == camera.sourceID,
              let primaryTime = sourceTime(atOutputTime: time),
              let cameraTime = camera.sourceTime(atOutputTime: time) else { return false }
        return abs(primaryTime + sourceOffset - cameraTime) < 0.000_001
    }
}

struct TimelinePreparedSourceTracks {
    let recordings: [UUID: TimelineRecordingSourceTracks]
    var inserted: [String: LoadedTimelineTrack] = [:]
}

let performanceLog = Logger(subsystem: "cn.laogou.dogsc", category: "performance")

enum TimelinePreviewCompositionLoader {
    static func rebuild(request: EditorMediaRequest, reusing previous: EditorPreparedMediaPayload) throws -> EditorPreparedMediaPayload? {
        guard let tracks = previous.sourceTracks else { return nil }
        let referenced = referencedSourceIDs(request.sourceSequence)
        guard referenced.isSubset(of: Set(tracks.recordings.keys)) else { return nil }
        let plan = try mediaPlan(request: request, recordings: tracks.recordings)
        guard Set(plan.primary.slices.compactMap { $0.media?.path }).isSubset(of: Set(tracks.inserted.keys)) else { return nil }
        return try payload(request: request, plan: plan, tracks: tracks)
    }

    static func prepare(request: EditorMediaRequest) async throws -> EditorPreparedMediaPayload {
        let started = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - started
            performanceLog.notice("prepare media: \(elapsed.components.seconds, privacy: .public)s, sources \(request.additionalSources.count + 1, privacy: .public)")
        }
        var recordings: [UUID: TimelineRecordingSourceTracks] = [:]
        recordings[RecordingSource.primaryID] = try await loadRecording(
            screenURL: request.source?.url, cameraURL: request.camera?.url,
            microphoneURL: request.microphone?.url, manifest: request.mediaManifest,
            pointerEvents: request.pointerEvents)
        for id in referencedSourceIDs(request.sourceSequence) where id != RecordingSource.primaryID {
            try Task.checkCancellation()
            guard let input = request.additionalSources[id] else {
                throw TimelinePreviewMediaError.missingImportedRecording(name: sourceLabel(id, nil))
            }
            let events: [PointerEventRecord]
            if input.manifest.pointerEvents != nil {
                guard let pointer = input.pointer else { throw CocoaError(.fileNoSuchFile) }
                events = try ProjectStore.decodePointerEvents(at: pointer.url)
            } else { events = [] }
            do {
                recordings[id] = try await loadRecording(screenURL: input.screen?.url, cameraURL: input.camera?.url,
                    microphoneURL: input.microphone?.url, manifest: input.manifest,
                    pointerEvents: events, cameraContentCrop: input.cameraContentCrop)
            } catch let error as TimelinePreviewMediaError {
                // Naming the source costs a small read of the saved project,
                // so it stays on the failure path.
                throw error.attributed(to: sourceLabel(id, input))
            }
        }
        let plan = try mediaPlan(request: request, recordings: recordings)
        let inserted = await TimelineCompositionBuilder.loadInsertedVideo(for: plan.primary)
        return try payload(request: request, plan: plan, tracks: TimelinePreparedSourceTracks(recordings: recordings, inserted: inserted))
    }

    /// The recording's own name travels with its media inputs; an in-place
    /// reference can still fall back to the user's own file name.
    private static func sourceLabel(_ id: UUID, _ input: EditorRecordingSourceInput?) -> String {
        if let name = input?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let path = input?.manifest.screen.relativePath, path.hasPrefix("/") {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return appLocalized("被导入的录制")
    }

    static func referencedSourceIDs(_ sequence: SourceSequence) -> Set<UUID> {
        switch sequence {
        case .fullRecording: return [RecordingSource.primaryID]
        case let .edited(segments): return Set(segments.filter { $0.media == nil }.map(\.resolvedSourceID)).union([RecordingSource.primaryID])
        }
    }

    static func mediaPlan(request: EditorMediaRequest, recordings: [UUID: TimelineRecordingSourceTracks]) throws -> ProjectTimelineMediaPlan {
        var sources: [UUID: RecordingSourceMedia] = [:]
        for (id, tracks) in recordings {
            guard let range = mediaRange(tracks.screen.timeRange) else { throw TimelinePreviewMediaError.invalidTrackRange("主录屏") }
            sources[id] = RecordingSourceMedia(
                manifest: id == RecordingSource.primaryID ? request.mediaManifest : request.additionalSources[id]?.manifest,
                videoRange: range, systemAudioRange: tracks.systemAudio.flatMap { mediaRange($0.timeRange) },
                cameraRange: tracks.camera.flatMap { mediaRange($0.timeRange) },
                microphoneRange: tracks.microphone.flatMap { mediaRange($0.timeRange) }, pointerEvents: tracks.pointerEvents)
        }
        return try ProjectTimelineMediaPlan(sourceSequence: request.sourceSequence, sources: sources)
    }

    private static func payload(request: EditorMediaRequest, plan: ProjectTimelineMediaPlan,
                                tracks: TimelinePreparedSourceTracks) throws -> EditorPreparedMediaPayload {
        guard let primary = tracks.recordings[RecordingSource.primaryID] else { throw TimelinePreviewMediaError.missingPrimaryRecording }
        let composition = try TimelineCompositionBuilder.build(plan: plan, sources: tracks.recordings,
            audioClips: request.audioClips, speech: request.speech, insertedVideo: tracks.inserted)
        let inventories = tracks.recordings.mapValues {
            EditorMediaInventories(source: inventory(video: $0.screen, audio: $0.systemAudio),
                camera: inventory(video: $0.camera, audio: nil), microphone: inventory(video: nil, audio: $0.microphone))
        }
        var payload = EditorPreparedMediaPayload(composition: composition,
            inventories: inventories[RecordingSource.primaryID] ?? .empty,
            sourceDisplaySize: primary.screen.displaySize ?? CGSize(width: 1_920, height: 1_080),
            cameraDisplaySize: CameraLetterboxAnalysis.croppedDisplaySize(primary.camera?.displaySize, crop: primary.cameraContentCrop),
            cameraContentCrop: primary.cameraContentCrop,
            cameraSource: primary.camera.map { EditorPreparedCameraSource(asset: $0.asset, track: $0.track,
                timeRange: $0.timeRange, preferredTransform: $0.preferredTransform) }, sourceTracks: tracks)
        payload.inventoriesBySource = inventories
        return payload
    }

    static func loadRecording(screenURL: URL?, cameraURL: URL?, microphoneURL: URL?,
                              manifest: ProjectMediaManifest?, pointerEvents: [PointerEventRecord],
                              cameraContentCrop: NormalizedCrop? = nil,
                              needsCamera: Bool = true, needsMicrophone: Bool = true,
                              needsSystemAudio: Bool = true) async throws -> TimelineRecordingSourceTracks {
        guard let screenURL, FileManager.default.fileExists(atPath: screenURL.path) else {
            throw TimelinePreviewMediaError.missingPrimaryRecording
        }
        let screen = try await loadTrack(at: screenURL, mediaType: .video, role: "主录屏")
        func declared(_ url: URL?, reference: ProjectMediaReference?, needed: Bool, role: String) throws -> URL? {
            guard needed, reference != nil else { return nil }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { throw TimelinePreviewMediaError.missingDeclaredMedia(role) }
            return url
        }
        let cameraURL = try declared(cameraURL, reference: manifest?.camera, needed: needsCamera, role: "摄像头")
        let microphoneURL = try declared(microphoneURL, reference: manifest?.microphone, needed: needsMicrophone, role: "麦克风")
        async let systemAudioTask = needsSystemAudio ? loadOptionalTrack(at: screenURL, mediaType: .audio, role: "系统声音") : nil
        let cameraIsPrimary = cameraURL?.standardizedFileURL == screenURL.standardizedFileURL
        async let cameraTask = loadTrackIfPresent(at: cameraIsPrimary ? nil : cameraURL, mediaType: .video, role: "摄像头")
        async let microphoneTask = loadTrackIfPresent(at: microphoneURL, mediaType: .audio, role: "麦克风")
        async let detectedCropTask = cameraContentCrop == nil ? cameraContentCropIfPresent(at: cameraURL) : cameraContentCrop
        let systemAudio = try await systemAudioTask
        let camera = cameraIsPrimary ? screen : try await cameraTask
        let microphone = try await microphoneTask
        let detectedCrop = await detectedCropTask
        return TimelineRecordingSourceTracks(screen: screen, systemAudio: systemAudio,
            camera: camera, microphone: microphone, cameraContentCrop: detectedCrop, pointerEvents: pointerEvents)
    }

    static func loadTrack(
        at url: URL,
        mediaType: AVMediaType,
        role: String
    ) async throws -> LoadedTimelineTrack {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
            throw TimelinePreviewMediaError.missingTrack(role)
        }
        guard let timeRange = try? await track.load(.timeRange),
              mediaRange(timeRange) != nil else {
            throw TimelinePreviewMediaError.invalidTrackRange(role)
        }
        let preferredTransform = mediaType == .video
            ? ((try? await track.load(.preferredTransform)) ?? .identity)
            : .identity
        let displaySize = await displayedSize(
            for: track,
            mediaType: mediaType,
            preferredTransform: preferredTransform
        )
        return LoadedTimelineTrack(
            asset: asset,
            track: track,
            timeRange: timeRange,
            preferredTransform: preferredTransform,
            displaySize: displaySize
        )
    }

    private static func loadTrackIfPresent(
        at url: URL?,
        mediaType: AVMediaType,
        role: String
    ) async throws -> LoadedTimelineTrack? {
        guard let url else { return nil }
        return try await loadTrack(at: url, mediaType: mediaType, role: role)
    }

    private static func cameraContentCropIfPresent(
        at url: URL?
    ) async -> NormalizedCrop? {
        guard let url else { return nil }
        // 竖屏模式相机/手机可能输出带黑边的画框：检测内容区，几何与渲染
        // 统一按裁剪后的尺寸工作，否则 PIP 里几乎全是黑边。
        return await CameraLetterboxAnalysis.normalizedContentCrop(for: url)
    }

    private static func loadOptionalTrack(
        at url: URL,
        mediaType: AVMediaType,
        role: String
    ) async throws -> LoadedTimelineTrack? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
            return nil
        }
        guard let timeRange = try? await track.load(.timeRange),
              mediaRange(timeRange) != nil else {
            throw TimelinePreviewMediaError.invalidTrackRange(role)
        }
        let preferredTransform = mediaType == .video
            ? ((try? await track.load(.preferredTransform)) ?? .identity)
            : .identity
        let displaySize = await displayedSize(
            for: track,
            mediaType: mediaType,
            preferredTransform: preferredTransform
        )
        return LoadedTimelineTrack(
            asset: asset,
            track: track,
            timeRange: timeRange,
            preferredTransform: preferredTransform,
            displaySize: displaySize
        )
    }

    private static func inventory(
        video: LoadedTimelineTrack?,
        audio: LoadedTimelineTrack?
    ) -> MediaAssetInventory {
        let videoRange = video.flatMap { mediaRange($0.timeRange) }
        let audioRange = audio.flatMap { mediaRange($0.timeRange) }
        return MediaAssetInventory(
            videoTimeRange: videoRange,
            audioTimeRange: audioRange
        )
    }

    private static func displayedSize(
        for track: AVAssetTrack,
        mediaType: AVMediaType,
        preferredTransform: CGAffineTransform
    ) async -> CGSize? {
        guard mediaType == .video,
              let naturalSize = try? await track.load(.naturalSize) else { return nil }
        let displayed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
            .size
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        return displayed
    }

    private static func mediaRange(_ range: CMTimeRange) -> MediaTimeRange? {
        guard range.start.isNumeric,
              range.duration.isNumeric else { return nil }
        return MediaTimeRange(
            start: range.start.seconds,
            duration: range.duration.seconds
        )
    }
}

/// One music/effect clip inside the primary composition and its gain shape.
struct TimelineExternalAudioTrack {
    let track: AVMutableCompositionTrack
    let clip: AudioClip
    /// Output ranges where someone speaks; ducking clips dip under them.
    var speech: [OverlayTiming] = []

    func mixParameters(masterGain: Float = 1, timePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        if abs(clip.playbackRate - 1) > 0.000_001 { input.audioTimePitchAlgorithm = timePitchAlgorithm }
        let volume = clip.isMuted ? 0 : Float(min(max(clip.volume, 0), 1)) * masterGain
        let start = clip.timing.startTime, end = clip.timing.endTime
        let fadeIn = min(max(clip.fadeIn, 0), clip.timing.duration / 2)
        let fadeOut = min(max(clip.fadeOut, 0), clip.timing.duration / 2)
        func t(_ s: TimeInterval) -> CMTime { CMTime(seconds: s, preferredTimescale: 48_000) }
        input.setVolume(fadeIn > 0 ? 0 : volume, at: .zero)
        if fadeIn > 0 {
            input.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                timeRange: CMTimeRange(start: t(start), duration: t(fadeIn)))
        }
        if clip.ducksUnderSpeech {
            // Merge speech ranges inside the clip, then dip to 30% with short ramps.
            let ramp = 0.25, ducked = volume * 0.3
            var spans: [(Double, Double)] = []
            for range in speech.sorted(by: { $0.startTime < $1.startTime }) {
                let a = max(range.startTime - ramp, start + fadeIn), b = min(range.endTime + ramp, end - fadeOut)
                guard b - a > ramp * 2 else { continue }
                if let last = spans.last, a <= last.1 { spans[spans.count - 1].1 = max(last.1, b) } else { spans.append((a, b)) }
            }
            for (a, b) in spans {
                input.setVolumeRamp(fromStartVolume: volume, toEndVolume: ducked, timeRange: CMTimeRange(start: t(a), duration: t(ramp)))
                input.setVolumeRamp(fromStartVolume: ducked, toEndVolume: ducked, timeRange: CMTimeRange(start: t(a + ramp), duration: t(b - a - ramp * 2)))
                input.setVolumeRamp(fromStartVolume: ducked, toEndVolume: volume, timeRange: CMTimeRange(start: t(b - ramp), duration: t(ramp)))
            }
        }
        if fadeOut > 0 {
            input.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                timeRange: CMTimeRange(start: t(end - fadeOut), duration: t(fadeOut)))
        }
        return input
    }
}
