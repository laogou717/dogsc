import Accelerate
import AVFoundation
import Foundation

/// Offline source peak protection, performed once before any timeline cuts.
final class AudioSourceProcessor {
    static let knee: Float = 0.668_34
    static let ceiling: Float = 0.841_40 // -1.5 dBFS sample ceiling; AAC headroom.
    private let gain: Float
    private var envelope: Float = 1
    private let attack = Float(exp(-1 / (0.0008 * 48_000)))
    private let release = Float(exp(-1 / (0.065 * 48_000)))

    init(gain: Float) { self.gain = gain.isFinite ? min(max(gain, 0), 8) : 1 }

    func process(_ buffer: AVAudioPCMBuffer) {
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        let channels = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength) * channels
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        if envelope >= 0.9999, peak.isFinite, peak * gain <= Self.knee {
            var multiplier = gain
            vDSP_vsmul(samples, 1, &multiplier, samples, 1, vDSP_Length(count))
            envelope = 1
            return
        }
        let span = Self.ceiling - Self.knee
        for frame in 0..<Int(buffer.frameLength) {
            let base = frame * channels
            var peak: Float = 0
            for channel in 0..<channels {
                let scaled = samples[base + channel] * gain
                samples[base + channel] = scaled.isFinite ? scaled : 0
                peak = max(peak, abs(samples[base + channel]))
            }
            let target: Float = peak > Self.knee ? min(1, (Self.knee + span * 0.5) / peak) : 1
            let coefficient = target < envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * target
            for channel in 0..<channels {
                let value = samples[base + channel] * envelope
                let magnitude = abs(value)
                samples[base + channel] = magnitude > Self.knee
                    ? copysign(Self.knee + span * tanh((magnitude - Self.knee) / span), value) : value
            }
        }
    }
}
