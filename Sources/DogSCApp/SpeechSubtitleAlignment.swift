import Foundation

/// Inward corrections supported by measured quiet audio. An edit boundary
/// alone never assigns a token to a different clip.
struct SpeechSubtitleAlignment: Sendable {
    struct Bounds {
        var start: Double
        var end: Double
        var basis: [String]
    }
    struct Adjustment: Sendable {
        let index: Int
        let start: Double
        let end: Double
        let basis: String
    }

    let words: [SystemTranscriber.Word]
    let adjustments: [Adjustment]
    let unresolvedWords: [Int]
    let lowEnergyWords: [Int]
    private let rawWords: [SystemTranscriber.Word]
    private let acoustics: SpeechAcousticEvidence

    init(transcript: SystemTranscriber.Transcript, acoustics: SpeechAcousticEvidence,
         regions: [SpeechEditAnalysis.Region]) {
        var result = transcript.words
        var changes: [Adjustment] = []
        var unresolved: [Int] = []
        var lowEnergy: [Int] = []
        let tolerance = acoustics.activity.frameDuration * 1.1
        func quietCoverage(_ start: Double, _ end: Double) -> Double {
            acoustics.intervals(from: start, to: end).reduce(0) {
                $0 + max(0, min(end, $1.end) - max(start, $1.start))
            }
        }
        for (index, word) in transcript.words.enumerated() where SpeechEditAnalysis.isSpoken(word.text) {
            var start = word.start, end = word.end
            var basis: [String] = []
            let pieces = regions.filter { $0.start < end && $0.end > start }
            if pieces.count > 1 {
                let nonQuiet = pieces.filter { region in
                    let a = max(start, region.start), b = min(end, region.end)
                    return region.audible && quietCoverage(a, b) < b - a - tolerance
                }
                if nonQuiet.count == 1, let owner = nonQuiet.first,
                   pieces.filter({ $0.segmentID != owner.segmentID }).allSatisfy({ region in
                       let a = max(start, region.start), b = min(end, region.end)
                       return !region.audible || quietCoverage(a, b) >= b - a - tolerance
                   }) {
                    start = max(start, owner.start); end = min(end, owner.end)
                    basis.append("quiet_across_edit")
                } else {
                    unresolved.append(index)
                }
            }
            let bounds = Self.refined(start: start, end: end, first: word, acoustics: acoustics)
            start = bounds.start; end = bounds.end; basis += bounds.basis
            if quietCoverage(word.start, word.end) >= (word.end - word.start) * 0.8 {
                lowEnergy.append(index)
            }
            if end > start, start != word.start || end != word.end {
                result[index] = .init(start: start, end: end, text: word.text, displayText: word.displayText)
                changes.append(Adjustment(index: index, start: start, end: end, basis: basis.joined(separator: "+")))
            }
        }
        words = result
        adjustments = changes
        unresolvedWords = unresolved
        lowEnergyWords = lowEnergy
        rawWords = transcript.words
        self.acoustics = acoustics
    }

    /// Work inside this caption's actual token span. Removing leading silence
    /// can cross silent ASR tokens, but never borrows a later caption's words.
    func bounds(from: Int, to: Int) -> Bounds {
        let ids = (from...to).filter { SpeechEditAnalysis.isSpoken(rawWords[$0].text) }
        let first = ids.first ?? from, last = ids.last ?? to
        return Self.refined(start: words[first].start, end: words[last].end,
                            first: rawWords[first], acoustics: acoustics)
    }

    static func refined(start: Double, end: Double, first: SystemTranscriber.Word,
                        acoustics: SpeechAcousticEvidence) -> Bounds {
        var result = Bounds(start: start, end: end, basis: [])
        let groups = acoustics.groups(from: start, to: end)
        let tolerance = acoustics.activity.frameDuration * 1.1
        // A first ASR token often owns the whole pause before its syllable.
        // Keep the full measured pause, including isolated 10 ms noise bins,
        // instead of abandoning any correction longer than 120 ms.
        if let leading = groups.first(where: {
            $0.start <= start + tolerance && $0.end > start + 0.03 && $0.end < end - 0.03
        }) {
            result.start = max(start, leading.end - 0.02)
            result.basis.append("measured_leading_pause")
        }
        // Some Chinese character ranges also include the preceding syllable's
        // tail. A substantial quiet gap inside a single-character token
        // separates that tail from the current syllable. Multiword runs do
        // not use this rule: their internal pause may be real wording.
        let letters = first.text.filter { $0.isLetter || $0.isNumber }
        if letters.count == 1, letters.first?.isASCII == false, first.end - first.start >= 0.3,
           let gap = groups.last(where: {
               $0.start >= start && $0.start - first.start <= 0.18 && $0.end - $0.start >= 0.08
                   && $0.end <= first.end - 0.03
           }), gap.end - 0.02 > result.start {
            result.start = gap.end - 0.02
            result.basis.append("onset_after_preceding_tail")
        }
        if let trailing = groups.last(where: {
            $0.end >= end - tolerance && $0.start < end - 0.03 && $0.start > result.start + 0.03
        }) {
            result.end = min(end, trailing.start + 0.02)
            result.basis.append("measured_trailing_pause")
        }
        return result
    }

    func description(raw: [SystemTranscriber.Word]) -> [String: Any] {
        ["adjustments": adjustments.map {
            ["i": $0.index, "recognizerStart": raw[$0.index].start, "recognizerEnd": raw[$0.index].end,
             "start": $0.start, "end": $0.end, "basis": $0.basis] as [String: Any]
        }, "unresolvedCrossingWords": unresolvedWords, "mostlyLowEnergyWords": lowEnergyWords]
    }
}
