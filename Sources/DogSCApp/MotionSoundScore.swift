import CryptoKit
import Foundation

/// A score lives on the motion's source clock. Both players use the same
/// mastered PCM samples; the timeline applies the instance gain and trim.
struct MotionSoundScore: Equatable {
    enum Voice: String, Codable, CaseIterable {
        case air, tap, step, settle, mark

        /// Duration, body pitch, pitch glide, filtered noise and peak amplitude.
        var settings: (length: Double, hz: Double, glide: Double, air: Double, peak: Double) {
            switch self {
            case .air:    (0.23, 235, 80, 1.1, 0.145)
            case .tap:    (0.095, 425, 90, 0.24, 0.16)
            case .step:   (0.105, 550, 65, 0.12, 0.14)
            case .settle: (0.18, 220, 155, 0.16, 0.175)
            case .mark:   (0.20, 590, -34, 0.06, 0.15)
            }
        }
    }

    struct Cue: Codable, Equatable {
        let at: Double
        let type: String
        let volume: Double
    }

    let cues: [Cue]
    /// Interleaved stereo PCM, decoded from the page's own named WAV samples.
    let customSamples: [String: [Int16]]
    static let rate = 24_000
    // Leave headroom on the existing 0–100% placement fader.
    static let defaultVolume = 0.65

    static func jsonRange(id: String, in html: String) throws -> Range<String.Index>? {
        let pattern = #"<script\b[^>]*\bid\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: id) + #"["'][^>]*>([\s\S]*?)</script\s*>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        return Range(match.range(at: 1), in: html)
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "DogSC.Sound", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func read(in html: String) throws -> Self? {
        guard let range = try jsonRange(id: "dogsc-sound", in: html) else { return nil }
        let cues = try JSONDecoder().decode([Cue].self, from: Data(html[range].utf8))
        guard !cues.isEmpty else { return nil }
        guard cues.count <= 1024, cues.allSatisfy({ $0.at.isFinite && (0...3600).contains($0.at)
            && $0.volume.isFinite && (0...1.5).contains($0.volume) }) else {
            throw NSError(domain: "DogSC.Sound", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Invalid dogsc-sound score. Use local seconds within one hour and cue volume from 0 to 1.5."])
        }
        var custom: [String: [Int16]] = [:]
        if let range = try jsonRange(id: "dogsc-samples", in: html) {
            let bank = try JSONDecoder().decode([String: String].self, from: Data(html[range].utf8))
            for name in Set(cues.map(\.type)) {
                if let uri = bank[name] { custom[name] = try decodeWAV(uri) }
            }
        }
        guard cues.allSatisfy({ custom[$0.type] != nil || Voice(rawValue: $0.type) != nil }) else {
            throw invalid("The score refers to an unknown sample. Supply its WAV in dogsc-samples.")
        }
        return Self(cues: cues, customSamples: custom)
    }

    /// Accept PCM WAV chunks in any order, including optional metadata.
    private static func decodeWAV(_ uri: String) throws -> [Int16] {
        let prefix = "data:audio/wav;base64,"
        let error = invalid("Embedded samples must be mono or stereo, 24 kHz 16-bit PCM WAV.")
        guard uri.hasPrefix(prefix), let data = Data(base64Encoded: String(uri.dropFirst(prefix.count))),
              data.count >= 44 else { throw error }
        func label(_ i: Int) -> String { String(decoding: data[i..<(i + 4)], as: UTF8.self) }
        func u16(_ i: Int) -> Int { Int(data[i]) | (Int(data[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
        guard label(0) == "RIFF", label(8) == "WAVE" else { throw error }
        var channels = 0, i = 12
        var payload: Range<Int>?
        while i + 8 <= data.count {
            let length = u32(i + 4), start = i + 8, end = start + length
            guard end <= data.count else { throw error }
            switch label(i) {
            case "fmt ":
                guard length >= 16, u16(start) == 1, u32(start + 4) == rate, u16(start + 14) == 16 else { throw error }
                channels = u16(start + 2)
            case "data": payload = start..<end
            default: break
            }
            i = end + length % 2
        }
        guard (1...2).contains(channels), let payload, !payload.isEmpty,
              payload.count.isMultiple(of: channels * 2) else { throw error }
        var stereo: [Int16] = []
        stereo.reserveCapacity(payload.count / channels)
        for i in stride(from: payload.lowerBound, to: payload.upperBound, by: 2) {
            let sample = Int16(bitPattern: UInt16(u16(i)))
            stereo.append(sample)
            if channels == 1 { stereo.append(sample) }
        }
        return stereo
    }

    private static let samples: [Voice: [Int16]] = Dictionary(uniqueKeysWithValues: Voice.allCases.map { voice in
        let s = voice.settings
        let count = Int(s.length * Double(rate))
        var samples = [Double](repeating: 0, count: count)
        var phase = 0.0, noise = 0.0
        var seed: UInt32 = 1977
        for i in samples.indices {
            let t = Double(i) / Double(rate), u = t / s.length
            seed = seed &* 1_664_525 &+ 1_013_904_223
            noise += 0.13 * (Double(seed) / Double(UInt32.max) * 2 - 1 - noise)
            phase += 2 * .pi * (s.hz + s.glide * exp(-t / 0.025)) / Double(rate)
            let attack = min(t / (voice == .air ? 0.055 : 0.006), 1)
            let tail = min((s.length - t) / 0.015, 1)
            let env = sin(attack * .pi / 2) * tail * exp(-u * (voice == .air ? 2.4 : 5.5))
            let body = sin(phase) + 0.21 * sin(phase * 1.51) + 0.07 * sin(phase * 2.03)
            samples[i] = env * (body * (voice == .air ? 0.14 : 0.78) + noise * s.air)
        }
        let scale = (s.peak / defaultVolume) * Double(Int16.max) / max(samples.map(abs).max() ?? 1, 0.001)
        return (voice, samples.map { Int16(($0 * scale).rounded()) })
    })

    /// Short dry voices embedded only in the browser player, outside authored HTML.
    static let browserBank: String = {
        let bank = samples.reduce(into: [String: String]()) { bank, item in
            bank[item.key.rawValue] = item.value.withUnsafeBytes { Data($0).base64EncodedString() }
        }
        let data = try! JSONEncoder().encode(bank)
        return String(decoding: data, as: UTF8.self)
    }()

    func file(in package: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var digest = SHA256()
        digest.update(data: try encoder.encode(cues))
        for name in customSamples.keys.sorted() {
            digest.update(data: Data(name.utf8))
            customSamples[name]!.withUnsafeBytes { digest.update(bufferPointer: $0) }
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let folder = package.appendingPathComponent("Inserted/TemplateSounds", isDirectory: true)
        let url = folder.appendingPathComponent("v1-" + hash + ".wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let channels = customSamples.isEmpty ? 1 : 2
        var bank = customSamples
        for name in Set(cues.map(\.type)) where bank[name] == nil {
            guard let voice = Voice(rawValue: name), let mono = Self.samples[voice] else { throw Self.invalid("Missing sample: " + name) }
            bank[name] = channels == 1 ? mono : mono.flatMap { [$0, $0] }
        }
        let events = cues.map { (Int(($0.at * Double(Self.rate)).rounded()) * channels, bank[$0.type]!, $0.volume) }
        let length = events.map { $0.0 + $0.1.count }.max() ?? 0
        var data = Data()
        func label(_ s: String) { data.append(contentsOf: s.utf8) }
        func write<T: FixedWidthInteger>(_ n: T) { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
        label("RIFF"); write(UInt32(36 + length * 2)); label("WAVEfmt "); write(UInt32(16))
        write(UInt16(1)); write(UInt16(channels)); write(UInt32(Self.rate)); write(UInt32(2 * channels * Self.rate))
        write(UInt16(2 * channels)); write(UInt16(16)); label("data"); write(UInt32(length * 2))
        // Mix bounded blocks so a late cue does not allocate a second long Float buffer.
        for start in stride(from: 0, to: length, by: 8192) {
            let end = min(start + 8192, length)
            var block = [Float](repeating: 0, count: end - start)
            for (at, sample, gain) in events where at < end && at + sample.count > start {
                for i in max(start, at)..<min(end, at + sample.count) {
                    block[i - start] += Float(sample[i - at]) * Float(gain)
                }
            }
            let pcm = block.map { Int16(clamping: Int($0.rounded())).littleEndian }
            pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
