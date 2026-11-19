import AVFoundation
import Accelerate
import Foundation
import Speech

/// EDT-054/057: speech-to-text with the recognizer that ships with macOS
/// (SpeechAnalyzer, macOS 26+). No model is bundled with DogSC; the system
/// downloads its own language assets on first use.
///
/// Timing comes from the recognizer per word (not per phrase), so subtitle
/// lines are timed from the words they contain instead of being estimated.
enum SystemTranscriber {
    struct Word: Sendable {
        let start: Double
        let end: Double
        let text: String
        /// Original spacing for captions. Speech analysis uses the trimmed token.
        var displayText: String? = nil
    }

    struct Segment: Sendable {
        let start: Double
        let end: Double
        let text: String
        /// Index range into the transcript's word list.
        let firstWord: Int
        let lastWord: Int
    }

    struct Transcript: Sendable {
        let words: [Word]
        let segments: [Segment]
    }

    struct TranscriberError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func transcribe(url: URL, localeIdentifier: String?) async throws -> Transcript {
        guard #available(macOS 26, *) else {
            throw TranscriberError(message: "System transcription needs macOS 26 or later.")
        }
        return try await transcribeWithAnalyzer(url: url, localeIdentifier: localeIdentifier)
    }

    @available(macOS 26, *)
    private static func transcribeWithAnalyzer(url: URL, localeIdentifier: String?) async throws -> Transcript {
        let requested = Locale(identifier: localeIdentifier ?? Locale.preferredLanguages.first ?? "zh-CN")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError(message: "The system recognizer does not support \(requested.identifier).")
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> Transcript in
            var words: [Word] = []
            var segments: [Segment] = []
            for try await result in transcriber.results where result.isFinal {
                let first = words.count
                var separator = first == 0 ? "" : " "
                // Each attributed run carries the audio time of its token.
                for run in result.text.runs {
                    let literal = String(result.text[run.range].characters)
                    let text = literal.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let range = run.audioTimeRange, !text.isEmpty else {
                        if literal.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) {
                            separator += literal
                        }
                        continue
                    }
                    let start = range.start.seconds, end = range.end.seconds
                    guard start.isFinite, end.isFinite, end >= start else { continue }
                    words.append(Word(start: start, end: max(end, start + 0.02), text: text,
                                      displayText: separator + literal))
                    separator = ""
                }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if words.count > first {
                    segments.append(Segment(start: words[first].start, end: words[words.count - 1].end,
                                            text: text, firstWord: first, lastWord: words.count - 1))
                } else {
                    let start = result.range.start.seconds, end = result.range.end.seconds
                    guard start.isFinite, end.isFinite, end > start else { continue }
                    words.append(Word(start: start, end: end, text: text,
                                      displayText: (first == 0 ? "" : " ") + text))
                    segments.append(Segment(start: start, end: end, text: text,
                                            firstWord: words.count - 1, lastWord: words.count - 1))
                }
            }
            return Transcript(words: words, segments: segments)
        }
        defer { collector.cancel() }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    }
}

/// EDT-057: where speech actually starts and stops in the audio, measured
/// from its loudness (10 ms frames against the recording's own noise floor).
/// Used to put subtitle edges on real speech onsets/offsets.
///
/// Automatic subtitle generation keeps recognizer ranges. Energy is used
/// only for an explicitly requested, bounded trim of existing cue edges.
struct SpeechActivity: Sendable {
    /// Loudness per 10 ms frame (dBFS) and the speech threshold, for
    /// finding the exact moment a line's voice begins.
    var levels: [Float] = []
    var threshold: Float = -50
    var frameDuration: Double = 0.01
    var duration: Double = 0

    static func measure(url: URL) throws -> SpeechActivity {
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let hop = AVAudioFrameCount(max(reader.processingFormat.sampleRate / 100, 1))
        var levels: [Float] = []
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: hop * 200) else {
            return SpeechActivity()
        }
        while reader.framePosition < reader.length {
            try Task.checkCancellation()
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(hop) * 200, reader.length - reader.framePosition)))
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let channelCount = Int(buffer.format.channelCount)
            var frame = 0
            while frame < Int(buffer.frameLength) {
                let end = min(frame + Int(hop), Int(buffer.frameLength))
                var sum: Float = 0
                for c in 0..<channelCount {
                    var channelSum: Float = 0
                    vDSP_svesq(channels[c].advanced(by: frame), 1, &channelSum, vDSP_Length(end - frame))
                    sum += channelSum
                }
                let rms = sqrt(sum / Float(max((end - frame) * channelCount, 1)))
                levels.append(20 * log10(max(rms, 1e-6)))
                frame = end
            }
        }
        guard !levels.isEmpty else { return SpeechActivity() }
        let all = levels
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        // Well above room noise and breaths, well below the voice.
        let threshold = max(floor + 12, floor + (loud - floor) * 0.3, -50)
        return SpeechActivity(levels: all, threshold: threshold,
                              frameDuration: Double(hop) / reader.processingFormat.sampleRate,
                              duration: Double(reader.length) / reader.processingFormat.sampleRate)
    }

    /// A small, inward-only adjustment. Silence elsewhere in a sentence is
    /// not evidence that its first word should be moved to a later word.
    func trimmedBounds(start: Double, end: Double) -> (start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start, !levels.isEmpty else { return (start, end) }
        let lo = max(Int(ceil(start / frameDuration)), 0)
        let hi = min(Int(floor(end / frameDuration)), levels.count - 1)
        guard hi > lo, levels.indices.contains(lo) else { return (start, end) }
        let headEnd = min(lo + 12, hi), tailStart = max(hi - 12, lo)
        let first = (lo...headEnd).first { levels[$0] > threshold }
        let last = (tailStart...hi).last { levels[$0] > threshold }
        let a = first.map { max(start, Double($0) * frameDuration - 0.02) } ?? start
        let b = last.map { min(end, Double($0 + 1) * frameDuration + 0.02) } ?? end
        return b > a ? (a, b) : (start, end)
    }
}
