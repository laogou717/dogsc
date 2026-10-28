import Accelerate
import AVFoundation
import Foundation
import MediaToolbox
import OSLog

/// Apply authored gains to PCM samples, rather than asking AVFoundation to
/// interpolate volume events across composition cuts. Preview and both export
/// paths use this same immutable envelope; editing a slider only replaces the
/// audio mix, without reopening assets or adding a track per clip.
enum TimelineAudioGainProcessor {
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
        let validSpans = spans.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }.sorted { $0.start < $1.start }
        let fallback = clamped(defaultGain)
        guard validSpans.contains(where: { clamped($0.gain) != fallback }) else {
            input.setVolume(fallback, at: .zero)
            return input
        }

        let state = State(defaultGain: fallback, spans: validSpans)
        let storage = Unmanaged.passRetained(state).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().format = format.pointee
            },
            unprepare: nil,
            process: { tap, requestedFrames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, requestedFrames, buffers, flagsOut, &range, framesOut
                )
                guard status == noErr else {
                    framesOut.pointee = 0
                    return
                }
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().apply(
                        buffers: buffers, frameCount: framesOut.pointee, range: range
                    )
            }
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tapRef = tap?.takeRetainedValue() else {
            Unmanaged<State>.fromOpaque(storage).release()
            Logger(subsystem: "cn.laogou.dogsc", category: "timeline-audio")
                .error("Cannot create segmented gain processor: \(status); silencing track")
            // Never play an explicitly muted segment at the global gain if
            // the system cannot allocate its processor.
            input.setVolume(0, at: .zero)
            return input
        }
        input.setVolume(1, at: .zero)
        input.audioTapProcessor = tapRef
        return input
    }

    private static func clamped(_ gain: Float) -> Float {
        gain.isFinite ? min(max(gain, 0), 1) : 0
    }

    /// Each tap owns its state. Only prepare/process callbacks access `format`;
    /// the gain table is immutable and processing takes no locks or allocations.
    private final class State {
        let defaultGain: Float
        let spans: [Span]
        var format = AudioStreamBasicDescription()

        init(defaultGain: Float, spans: [Span]) {
            self.defaultGain = defaultGain
            self.spans = spans.map {
                Span(start: $0.start, end: $0.end, gain: clamped($0.gain))
            }
        }

        func apply(
            buffers: UnsafeMutablePointer<AudioBufferList>,
            frameCount: Int,
            range: CMTimeRange
        ) {
            guard frameCount > 0 else { return }
            let start = range.start.seconds
            let sampleRate = format.mSampleRate
            guard start.isFinite, sampleRate.isFinite, sampleRate > 0 else {
                scale(buffers, frames: 0..<frameCount, gain: 0)
                return
            }
            // A retimed composition can report a source-scaled range duration
            // even though this post-effects buffer is already on the output
            // clock. Anchor to its asset start, then advance by the negotiated
            // PCM sample rate; duration/frameCount moves cuts on fast clips.
            let step = 1 / sampleRate
            let duration = Double(frameCount) * step
            var lower = 0
            var upper = spans.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if spans[middle].end <= start { lower = middle + 1 }
                else { upper = middle }
            }
            var index = lower
            var frame = 0
            while frame < frameCount {
                let time = start + Double(frame) * step
                while index < spans.count, spans[index].end <= time { index += 1 }
                let gain: Float
                let boundary: Double
                if index < spans.count {
                    let span = spans[index]
                    if time < span.start {
                        gain = defaultGain
                        boundary = span.start
                    } else {
                        gain = span.gain
                        boundary = span.end
                    }
                } else {
                    gain = defaultGain
                    boundary = start + duration
                }
                // Half-open intervals: the first sample on a cut belongs to
                // the next segment. Only remove arithmetic noise, not a frame.
                let nextFrame = min(frameCount, max(
                    frame + 1, Int(ceil((boundary - start) / step - 0.000_000_1))
                ))
                scale(buffers, frames: frame..<nextFrame, gain: gain)
                frame = nextFrame
            }
        }

        private func scale(
            _ buffers: UnsafeMutablePointer<AudioBufferList>,
            frames: Range<Int>,
            gain: Float
        ) {
            guard gain != 1 else { return }
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let isSigned = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            let bytesPerSample = Int(format.mBitsPerChannel / 8)
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let data = buffer.mData, bytesPerSample > 0 else { continue }
                let channels = Int(buffer.mNumberChannels)
                let first = min(frames.lowerBound * channels, Int(buffer.mDataByteSize) / bytesPerSample)
                let end = min(frames.upperBound * channels, Int(buffer.mDataByteSize) / bytesPerSample)
                let count = end - first
                guard count > 0 else { continue }
                let pointer = data.advanced(by: first * bytesPerSample)
                if gain == 0 {
                    memset(pointer, 0, count * bytesPerSample)
                } else if isFloat, bytesPerSample == 4 {
                    let samples = pointer.assumingMemoryBound(to: Float.self)
                    var multiplier = gain
                    vDSP_vsmul(samples, 1, &multiplier, samples, 1, vDSP_Length(count))
                } else if isFloat, bytesPerSample == 8 {
                    let samples = pointer.assumingMemoryBound(to: Double.self)
                    var multiplier = Double(gain)
                    vDSP_vsmulD(samples, 1, &multiplier, samples, 1, vDSP_Length(count))
                } else if isSigned, bytesPerSample == 2 {
                    let samples = pointer.assumingMemoryBound(to: Int16.self)
                    for i in 0..<count { samples[i] = Int16(Float(samples[i]) * gain) }
                } else if isSigned, bytesPerSample == 4 {
                    let samples = pointer.assumingMemoryBound(to: Int32.self)
                    for i in 0..<count { samples[i] = Int32(Double(samples[i]) * Double(gain)) }
                } else {
                    // The mixer normally supplies native Float32 PCM. Keep
                    // explicit mute safe if an unsupported format is negotiated.
                    memset(pointer, 0, count * bytesPerSample)
                }
            }
        }
    }
}
