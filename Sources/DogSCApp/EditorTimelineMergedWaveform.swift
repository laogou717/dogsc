import Foundation
import RecorderCore
import SwiftUI

/// Both committed and draft waveforms use the same immutable audio placement.
/// Pixel sampling reads cached PCM peaks; it never reloads the recording.
struct EditorTimelineMergedWaveform: View {
    let system: EditorTimelineWaveformData?
    let microphone: EditorTimelineWaveformData?
    let systemPlan: TimelineMediaPlan?
    let microphonePlan: TimelineMediaPlan?
    let systemGains: [EditorTimelineWaveformGainRange]
    let microphoneGains: [EditorTimelineWaveformGainRange]
    let width: CGFloat
    let height: CGFloat
    let outputStart: TimeInterval
    let outputDuration: TimeInterval
    let expanded: Bool

    private var request: WaveformEnvelopeRequest {
        var channels: [WaveformEnvelopeChannel] = []
        if let system, let systemPlan {
            channels.append(.init(data: system, plan: systemPlan, gains: systemGains))
        }
        if let microphone, let microphonePlan {
            channels.append(.init(data: microphone, plan: microphonePlan, gains: microphoneGains))
        }
        return .init(channels: channels, count: min(max(Int(ceil(width / 2)), 2), 4096),
                     start: outputStart, duration: outputDuration)
    }

    var body: some View {
        WaveformEnvelopeCanvas(request: request, expansion: expanded ? 1 : 0)
            .equatable()
            .frame(width: width, height: height)
            .animation(SpringMotion.fluid, value: expanded)
            .allowsHitTesting(false)
    }
}

/// Drawing consumes one immutable draft and the already-decoded peak buffers.
/// There is no detached sampling task whose stale result can trail a trim,
/// and no PCM decode or SwiftUI state publication inside the drawing pass.
private struct WaveformEnvelopeCanvas: View, @MainActor Animatable, @MainActor Equatable {
    @State private var envelopeCache = WaveformEnvelopeCache()

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
        let ink = EditorTheme.chrome(0.56)
        let cache = envelopeCache
        Canvas(rendersAsynchronously: true) { context, size in
            guard let samples = cache.samples(for: request) else { return }
            let shape = WaveformEnvelopeShape(samples: samples, expansion: expansion)
            context.fill(shape.path(in: CGRect(origin: .zero, size: size)), with: .color(ink))
        }
    }
}

/// One immutable envelope per visible window. Drawing can run asynchronously;
/// lock only protects this small, local cache and never holds media/decoder state.
private final class WaveformEnvelopeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var request: WaveformEnvelopeRequest?
    private var values: [Double]?

    func samples(for request: WaveformEnvelopeRequest) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        if self.request == request { return values }
        let sampled = request.sample()
        if let sampled { self.request = request; values = sampled }
        return sampled
    }
}

private struct WaveformEnvelopeChannel: Equatable, Sendable {
    let data: EditorTimelineWaveformData
    let plan: TimelineMediaPlan
    let gains: [EditorTimelineWaveformGainRange]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data.version == rhs.data.version && lhs.data.sourceRange == rhs.data.sourceRange
            && lhs.plan == rhs.plan && lhs.gains == rhs.gains
    }

    func amplitude(at time: TimeInterval) -> Double {
        let gain = EditorTimelineWaveformPresentation.volumeGain(at: time, ranges: gains)
        guard gain > 0 else { return 0 }
        let peak = EditorTimelineWaveformPresentation.peak(samples: data.samples,
            sourceRange: data.sourceRange, plan: plan, atOutputTime: time)
        guard peak.isFinite, peak > 0.001 else { return 0 }
        return min(peak * data.displayGain, 1) * gain
    }
}

private struct WaveformEnvelopeRequest: Equatable, Sendable {
    let channels: [WaveformEnvelopeChannel]
    let count: Int
    let start: TimeInterval
    let duration: TimeInterval

    func sample() -> [Double]? {
        guard !channels.isEmpty else { return [] }
        var values = [Double](repeating: 0, count: count)
        let step = duration / Double(count)
        for index in values.indices {
            if index.isMultiple(of: 128), Task.isCancelled { return nil }
            // Take the peak across each drawing cell, not just its midpoint.
            // Both sources contribute to one envelope; their own timing and
            // mute/volume settings are respected before the visual merge.
            for fraction in [0.2, 0.5, 0.8] {
                let time = start + (Double(index) + fraction) * step
                for channel in channels {
                    values[index] = max(values[index], channel.amplitude(at: time))
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
