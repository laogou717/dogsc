import AVFoundation
import Foundation

/// EDT-068: sound effects DogSC makes itself, so the AI can score a motion
/// (whoosh in, hit on the title, shimmer, click) without fetching anything.
/// A sound is a list of short layered events; each event is a few
/// oscillators or filtered noise with an envelope and a pitch glide.
enum SoundSynth {
    struct Event: Decodable {
        /// whoosh, riser, hit, boom, click, pop, ding, chime, shimmer, swoosh_down, tick, glitch, tone
        var type: String
        var at: Double = 0
        var duration: Double?
        var volume: Double = 0.8
        /// Overrides the preset's pitch (Hz) where it has one.
        var pitch: Double?
        var pan: Double = 0

        private enum CodingKeys: String, CodingKey { case type, at, duration, volume, pitch, pan }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
            duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
            pitch = try c.decodeIfPresent(Double.self, forKey: .pitch)
            pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        }
    }

    struct SpecError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let sampleRate = 48_000.0

    /// Renders events into a stereo 48 kHz M4A at `url`. Returns its length.
    @discardableResult
    static func render(_ events: [Event], length: Double? = nil, to url: URL) throws -> Double {
        guard !events.isEmpty else { throw SpecError(message: "sound needs at least one event") }
        let known = ["whoosh", "riser", "hit", "boom", "click", "pop", "ding", "chime", "shimmer",
                     "swoosh_down", "tick", "glitch", "tone"]
        if let bad = events.first(where: { !known.contains($0.type) }) {
            throw SpecError(message: "unknown sound type \(bad.type); use one of \(known.joined(separator: ", "))")
        }
        let end = events.map { $0.at + ($0.duration ?? defaultDuration($0.type)) }.max() ?? 1
        let total = max(length ?? end + 0.05, 0.05)
        let frames = Int(total * sampleRate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for event in events {
            let duration = max(event.duration ?? defaultDuration(event.type), 0.01)
            let start = Int(max(event.at, 0) * sampleRate)
            let count = min(Int(duration * sampleRate), frames - start)
            guard count > 0 else { continue }
            let mono = voice(event, duration: duration, count: count)
            let pan = min(max(event.pan, -1), 1)
            let gl = Float(cos((pan + 1) * .pi / 4)), gr = Float(sin((pan + 1) * .pi / 4))
            let gain = Float(min(max(event.volume, 0), 1.5))
            for i in 0..<count {
                left[start + i] += mono[i] * gain * gl
                right[start + i] += mono[i] * gain * gr
            }
        }
        // Soft limiter so layered events never clip.
        for i in 0..<frames {
            left[i] = tanhf(left[i] * 0.9)
            right[i] = tanhf(right[i] * 0.9)
        }
        try write(left: left, right: right, to: url)
        return total
    }

    static func defaultDuration(_ type: String) -> Double {
        switch type {
        case "whoosh", "swoosh_down": 0.6
        case "riser": 1.5
        case "hit": 0.5
        case "boom": 1.6
        case "click", "tick": 0.05
        case "pop": 0.12
        case "ding": 1.2
        case "chime": 1.8
        case "shimmer": 1.4
        case "glitch": 0.3
        default: 0.5
        }
    }

    // MARK: Voices

    private static func voice(_ e: Event, duration: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var rng = SystemRandomNumberGenerator()
        func noise() -> Float { Float.random(in: -1...1, using: &rng) }
        func t(_ i: Int) -> Double { Double(i) / sampleRate }
        func p(_ i: Int) -> Double { Double(i) / Double(max(count - 1, 1)) }
        switch e.type {
        case "whoosh", "swoosh_down":
            // Band-passed noise whose centre sweeps up (or down), bell-shaped.
            var low: Float = 0, band: Float = 0
            let up = e.type == "whoosh"
            for i in 0..<count {
                let x = p(i)
                let centre = up ? 300 + 4200 * x * x : 4500 - 4100 * x
                let f = Float(2 * sin(.pi * min(centre, 12_000) / sampleRate))
                let input = noise()
                low += f * band
                let high = input - low - 0.5 * band
                band += f * high
                let env = Float(sin(.pi * pow(x, up ? 0.7 : 0.4)))
                out[i] = band * env * 0.9
            }
        case "riser":
            for i in 0..<count {
                let x = p(i)
                let freq = (e.pitch ?? 180) * pow(2, 2.5 * x)
                let phase = 2 * .pi * freq * t(i)
                let tone = sin(phase) * 0.5 + sin(phase * 1.5) * 0.2
                out[i] = Float(tone) * Float(pow(x, 2)) * 0.6 + noise() * Float(pow(x, 3)) * 0.25
            }
        case "hit", "boom":
            // Pitch-dropping sine thump plus a noise transient.
            let base = e.pitch ?? (e.type == "boom" ? 55 : 90)
            var phase = 0.0
            for i in 0..<count {
                let time = t(i)
                let freq = base * (1 + 2.5 * exp(-time * 30))
                phase += 2 * .pi * freq / sampleRate
                let body = sin(phase) * exp(-time * (e.type == "boom" ? 2.2 : 7))
                let snap = Double(noise()) * exp(-time * 60) * 0.5
                out[i] = Float(body + snap)
            }
        case "click", "tick":
            let freq = e.pitch ?? (e.type == "click" ? 2200 : 3500)
            for i in 0..<count {
                let time = t(i)
                out[i] = Float(sin(2 * .pi * freq * time) * exp(-time * 180)) * 0.8 + noise() * Float(exp(-time * 400)) * 0.3
            }
        case "pop":
            let base = e.pitch ?? 500
            for i in 0..<count {
                let time = t(i)
                let freq = base * (1 + 1.8 * exp(-time * 60))
                out[i] = Float(sin(2 * .pi * freq * time) * exp(-time * 35))
            }
        case "ding", "chime", "shimmer", "tone":
            // Bell partials (or a plain tone) with a soft attack.
            let base = e.pitch ?? (e.type == "shimmer" ? 1320 : e.type == "chime" ? 660 : 880)
            let partials: [(Double, Double, Double)] = e.type == "tone"
                ? [(1, 1, 3)]
                : [(1, 1, 3), (2.76, 0.45, 5), (5.4, 0.25, 8), (8.93, 0.12, 12)]
            let notes: [Double] = e.type == "chime" ? [0, 0.12, 0.24] : e.type == "shimmer" ? [0, 0.07, 0.14, 0.21, 0.28] : [0]
            let ratios: [Double] = e.type == "chime" ? [1, 1.25, 1.5] : e.type == "shimmer" ? [1, 1.5, 2, 2.5, 3] : [1]
            for (n, offset) in notes.enumerated() {
                let startFrame = Int(offset * sampleRate)
                for i in startFrame..<count {
                    let time = t(i - startFrame)
                    let attack = min(time / 0.004, 1)
                    var v = 0.0
                    for (ratio, amp, decay) in partials {
                        v += sin(2 * .pi * base * ratios[n] * ratio * time) * amp * exp(-time * decay / max(duration, 0.2) * 1.5)
                    }
                    out[i] += Float(v * attack * 0.35 / Double(notes.count).squareRoot())
                }
            }
        case "glitch":
            var hold: Float = 0
            for i in 0..<count {
                if i % Int(sampleRate / 900) == 0 { hold = noise() }
                let gate: Float = (i / Int(sampleRate * 0.03)) % 2 == 0 ? 1 : 0.15
                out[i] = hold * gate * Float(1 - p(i)) * 0.6
            }
        default:
            break
        }
        // 3 ms fades at both ends to avoid clicks.
        let fade = min(Int(0.003 * sampleRate), count / 2)
        for i in 0..<fade {
            let g = Float(i) / Float(max(fade, 1))
            out[i] *= g
            out[count - 1 - i] *= g
        }
        return out
    }

    // MARK: File

    private static func write(left: [Float], right: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        let chunk = 48_000
        var offset = 0
        while offset < left.count {
            let n = min(chunk, left.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let channels = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                channels[0][i] = left[offset + i]
                channels[1][i] = right[offset + i]
            }
            try file.write(from: buffer)
            offset += n
        }
    }
}
