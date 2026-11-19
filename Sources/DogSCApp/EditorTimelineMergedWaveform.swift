import AVFoundation
import Foundation
import RecorderCore
import SwiftUI

/// Both committed and draft waveforms use the same immutable audio placement.
/// Pixel sampling reads cached PCM peaks; it never reloads the recording.
struct EditorTimelineMergedWaveform: View {
    let system: [UUID: EditorTimelineWaveformData]
    let microphone: [UUID: EditorTimelineWaveformData]
    let systemPlan: TimelineMediaPlan?
    let microphonePlan: TimelineMediaPlan?
    let systemGains: [EditorTimelineWaveformGainRange]
    let microphoneGains: [EditorTimelineWaveformGainRange]
    /// Clips inserted on the main track that carry their own sound (an HTML
    /// motion's effects, an inserted video), mapped through the primary plan.
    var inserted: [EditorTimelineInsertedWaveform] = []
    let width: CGFloat
    let height: CGFloat
    let outputStart: TimeInterval
    let outputDuration: TimeInterval
    let expanded: Bool

    private var request: WaveformEnvelopeRequest {
        var channels: [WaveformEnvelopeChannel] = []
        if let systemPlan {
            for id in system.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let data = system[id] { channels.append(.init(data: data, plan: systemPlan, gains: systemGains, sourceID: id)) }
            }
        }
        if let microphonePlan {
            for id in microphone.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let data = microphone[id] { channels.append(.init(data: data, plan: microphonePlan, gains: microphoneGains, sourceID: id)) }
            }
        }
        for clip in inserted {
            channels.append(.init(data: clip.data, plan: clip.plan, gains: clip.gains, mediaAudioPath: clip.audioPath))
        }
        return .init(channels: channels, count: min(max(Int(ceil(width / 2)), 2), 4096),
                     start: outputStart, duration: outputDuration)
    }

    var body: some View {
        WaveformEnvelopeCanvas(request: request, expansion: expanded ? 1 : 0)
            .equatable()
            .frame(width: width, height: height)
            .animation(SpringMotion.fade, value: expanded)
            .allowsHitTesting(false)
    }
}

/// Drawing consumes a prepared envelope only. A compatible cached window is
/// projected by media time during zoom/scroll while the worker refines it.
private struct WaveformEnvelopeCanvas: View, @MainActor Animatable, @MainActor Equatable {
    @StateObject private var envelope = WaveformEnvelopeModel()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.request == rhs.request && lhs.expansion == rhs.expansion
    }

    let request: WaveformEnvelopeRequest
    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }
    var body: some View {
        // Sound lives inside the primary recording clip: a soft sage-lime of
        // the primary hue, quiet enough not to outweigh the effect lanes.
        let ink = EditorConsole.waveformInk
        let prepared = envelope.displayed
        Canvas(rendersAsynchronously: true) { context, size in
            guard let prepared, prepared.request.channels == request.channels, request.duration > 0 else { return }
            let origin = (prepared.request.start - request.start) / request.duration
            let span = prepared.request.duration / request.duration
            let shape = WaveformEnvelopeShape(samples: prepared.samples, expansion: expansion)
            let rect = CGRect(x: origin * size.width, y: 0, width: span * size.width, height: size.height)
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.fill(shape.path(in: CGRect(origin: .zero, size: rect.size)).offsetBy(dx: rect.minX, dy: 0), with: .color(ink))
        }
        .onChange(of: request, initial: true) { _, request in envelope.update(request) }
    }
}

struct WaveformEnvelopeChannel: Equatable, Sendable {
    let data: EditorTimelineWaveformData
    let plan: TimelineMediaPlan
    let gains: [EditorTimelineWaveformGainRange]
    /// Set for an inserted clip's own sound: only slices playing that file
    /// read these samples (the plan is the whole primary plan).
    var mediaAudioPath: String?
    var sourceID: UUID?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data.version == rhs.data.version && lhs.data.sourceRange == rhs.data.sourceRange
            && lhs.plan == rhs.plan && lhs.gains == rhs.gains && lhs.mediaAudioPath == rhs.mediaAudioPath
            && lhs.sourceID == rhs.sourceID
    }

    func amplitude(at time: TimeInterval, slice: TimelineMediaSlice) -> Double {
        guard sourceID == nil || slice.sourceID == sourceID else { return 0 }
        let gain = EditorTimelineWaveformPresentation.volumeGain(at: time, ranges: gains)
        guard gain > 0 else { return 0 }
        if let mediaAudioPath {
            guard slice.media?.ownAudioPath == mediaAudioPath else { return 0 }
        }
        let peak = EditorTimelineWaveformPresentation.peak(samples: data.samples,
            sourceRange: data.sourceRange, slice: slice, sourceID: sourceID, atOutputTime: time)
        guard peak.isFinite, peak > 0.001 else { return 0 }
        return min(peak * data.displayGain, 1) * gain
    }
}

struct WaveformEnvelopeRequest: Equatable, Sendable {
    let channels: [WaveformEnvelopeChannel]
    let count: Int
    let start: TimeInterval
    let duration: TimeInterval

    func sample(isCancelled: () -> Bool = { Task.isCancelled }) -> [Double]? {
        guard !channels.isEmpty else { return [] }
        // Sources in one lane share a media plan. Resolve each drawing time
        // once per plan instead of copying/searching the full slice placement
        // separately for every source and every inserted sound.
        var groups: [(plan: TimelineMediaPlan, channels: [WaveformEnvelopeChannel])] = []
        for channel in channels {
            if let index = groups.firstIndex(where: { $0.plan == channel.plan }) {
                groups[index].channels.append(channel)
            } else {
                groups.append((channel.plan, [channel]))
            }
        }
        var values = [Double](repeating: 0, count: count)
        let step = duration / Double(count)
        for index in values.indices {
            if index.isMultiple(of: 128), isCancelled() { return nil }
            // Take the peak across each drawing cell, not just its midpoint.
            // Both sources contribute to one envelope; their own timing and
            // mute/volume settings are respected before the visual merge.
            for fraction in [0.2, 0.5, 0.8] {
                let time = start + (Double(index) + fraction) * step
                for group in groups {
                    guard let slice = group.plan.slice(atOutputTime: time) else { continue }
                    for channel in group.channels {
                        values[index] = max(values[index], channel.amplitude(at: time, slice: slice))
                    }
                }
            }
        }
        return values
    }
}

private struct WaveformEnvelopeShape: Shape {
    let samples: [Double]
    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        let progress = min(max(expansion, 0), 1)
        let band = EditorTimelineClipGeometry.waveformBand(in: rect)
        let center = band.midY + (rect.height * 0.50 - band.midY) * progress
        let compactAmplitude = band.height * 0.38
        let amplitude = compactAmplitude + (rect.height * 0.30 - compactAmplitude) * progress
        let step = rect.width / CGFloat(samples.count - 1)
        func peakHeight(at index: Int) -> CGFloat {
            // Boosted audio must stay inside the compact band. The expanded
            // endpoint keeps its existing envelope and display gain unchanged.
            let compactPeak = min(samples[index], 1)
            let peak = compactPeak + (samples[index] - compactPeak) * Double(progress)
            return CGFloat(peak) * amplitude
        }
        var path = Path()
        var runStart: Int?
        func closeRun(at end: Int) {
            guard let start = runStart else { return }
            path.addLine(to: CGPoint(x: min((CGFloat(end) + 0.5) * step, rect.width), y: center))
            for index in stride(from: end, through: start, by: -1) {
                path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                        y: center + peakHeight(at: index)))
            }
            path.closeSubpath()
            runStart = nil
        }
        for index in samples.indices {
            guard samples[index] > 0.0001 else {
                if runStart != nil { closeRun(at: max(index - 1, 0)) }
                continue
            }
            let x = CGFloat(index) * step
            if runStart == nil {
                runStart = index
                path.move(to: CGPoint(x: max(x - step / 2, 0), y: center))
            }
            path.addLine(to: CGPoint(x: x, y: center - peakHeight(at: index)))
        }
        if runStart != nil { closeRun(at: samples.count - 1) }
        return path
    }
}

/// One inserted main-track file's decoded sound and where it plays.
struct EditorTimelineInsertedWaveform: Equatable, Sendable {
    let audioPath: String
    let data: EditorTimelineWaveformData
    let plan: TimelineMediaPlan
    let gains: [EditorTimelineWaveformGainRange]
}

extension InsertedMedia {
    /// The file whose sound plays for this clip — the same choice as
    /// `TimelineCompositionBuilder.insertedAudioClips`. A live HTML motion
    /// without sound effects has none (its stand-in is silent black).
    var ownAudioPath: String? {
        if let soundPath { return soundPath }
        return motionPath == nil && imagePath == nil ? path : nil
    }
}

enum EditorTimelineInsertedWaveformLoader {
    /// Decodes (or reads from the shared cache) each inserted file's sound.
    /// Files without an audio track are simply absent.
    static func load(paths: [String], cached: [String: EditorTimelineWaveformData]) async
        -> [String: EditorTimelineWaveformData] {
        var result: [String: EditorTimelineWaveformData] = [:]
        for path in paths {
            guard !Task.isCancelled else { break }
            let url = ProjectFiles.url(path)
            guard FileManager.default.fileExists(atPath: url.path), let input = EditorMediaInput(url),
                  let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
                  let range = try? await track.load(.timeRange), range.start.isNumeric, range.duration.isNumeric,
                  let sourceRange = MediaTimeRange(start: range.start.seconds, duration: range.duration.seconds)
            else { continue }
            if let data = await EditorTimelineWaveformLoader.load(input: input, sourceRange: sourceRange,
                                                                  cached: cached[path]) {
                result[path] = data
            }
        }
        return result
    }
}
