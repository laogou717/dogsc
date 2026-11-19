import Foundation

/// Larger language context alongside the small acoustic units. Silence does
/// not split this context: slowly spoken parts of one sentence stay together.
/// Punctuation remains recognizer evidence, not a completeness judgement.
struct SpeechUtteranceEvidence: Sendable {
    struct Context: Sendable {
        let words: SpeechEditAnalysis.Unit
        let ending: String
        let continuesBefore: Bool
    }

    let contexts: [Context]

    init(words: [SystemTranscriber.Word], regions: [SpeechEditAnalysis.Region]) {
        var result: [Context] = []
        var first = 0
        var continuation = false
        for i in words.indices {
            let punctuation = SpeechEditAnalysis.endsSentence(words[i].text, next: i + 1 < words.count ? words[i + 1].text : nil)
            let sourceChange: Bool
            if i + 1 < words.count,
               let left = regions.first(where: { words[i].start >= $0.start && words[i].start < $0.end }),
               let right = regions.first(where: { words[i + 1].start >= $0.start && words[i + 1].start < $0.end }) {
                sourceChange = left.sourceID != right.sourceID || left.audible != right.audible
            } else { sourceChange = false }
            // Bound unpunctuated recognizer runs without labelling the split
            // as a sentence boundary or restricting the agent's edit range.
            let windowEnd = words[i].end - words[first].start >= 30
            if punctuation || sourceChange || windowEnd || i == words.count - 1 {
                let ending = punctuation ? "recognizer_punctuation" : (sourceChange ? "recording_change" :
                    (i == words.count - 1 ? "transcript_end" : "context_window"))
                result.append(Context(words: .init(from: first, to: i,
                    text: SpeechEditAnalysis.text(words[first...i]), sentencePunctuation: punctuation),
                    ending: ending, continuesBefore: continuation))
                continuation = ending == "context_window"
                first = i + 1
            }
        }
        contexts = result
    }

    func description(words: [SystemTranscriber.Word], from: Double, to: Double) -> [[String: Any]] {
        let matching = contexts.indices.filter {
            words[contexts[$0].words.to].end > from && words[contexts[$0].words.from].start < to
        }
        guard let first = matching.first, let last = matching.last else { return [] }
        return (max(first - 1, 0)...min(last + 1, contexts.count - 1)).map { i in
            let context = contexts[i], unit = context.words
            return ["id": i, "from": unit.from, "to": unit.to, "text": unit.text,
                "start": words[unit.from].start, "end": words[unit.to].end,
                "ending": context.ending, "continuesBefore": context.continuesBefore,
                "continuesAfter": context.ending == "context_window"]
        }
    }
}
