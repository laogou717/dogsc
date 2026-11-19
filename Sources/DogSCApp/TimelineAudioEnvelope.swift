import AVFoundation
import Foundation

/// Native output-clock volume events. Playback never owns a processing tap
/// or infers segment positions from decoder callback timestamps.
enum TimelineAudioEnvelope {
    struct Span {
        let start: Double
        let end: Double
        let gain: Float
    }

    static func parameters(
        track: AVCompositionTrack,
        defaultGain: Float,
        spans: [Span]
    ) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        let fallback = min(max(defaultGain.isFinite ? defaultGain : 0, 0), 1)
        let valid = spans.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var ordered: [Span] = []
        for span in valid {
            if let last = ordered.last, last.gain == span.gain, abs(last.end - span.start) < 0.000000001 {
                ordered[ordered.count - 1] = Span(start: last.start, end: span.end, gain: span.gain)
            } else { ordered.append(span) }
        }
        guard !ordered.isEmpty else {
            input.setVolume(fallback, at: .zero)
            return input
        }
        var previousEnd = CMTime.zero
        for span in ordered {
            let gain = min(max(span.gain.isFinite ? span.gain : 0, 0), 1)
            let start = CMTime(seconds: max(span.start, 0), preferredTimescale: 1_000_000_000)
            let end = CMTime(seconds: span.end, preferredTimescale: 1_000_000_000)
            if start > previousEnd {
                input.setVolumeRamp(fromStartVolume: fallback, toEndVolume: fallback,
                    timeRange: CMTimeRange(start: previousEnd, end: start))
            }
            // Explicit constant ranges prevent AVFoundation from treating
            // adjacent setVolume events as a ramp through the previous cut.
            input.setVolumeRamp(fromStartVolume: gain, toEndVolume: gain,
                timeRange: CMTimeRange(start: start, end: end))
            previousEnd = end
        }
        return input
    }

}
