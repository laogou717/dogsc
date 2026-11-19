import Foundation

/// Lexical candidates for comparing takes. No choice of which occurrence to
/// keep is made here; intentional repetitions and ASR errors remain possible.
struct SpeechRepeatEvidence: Sendable {
    struct Match: Sendable {
        let firstFrom: Int
        let firstTo: Int
        let secondFrom: Int
        let secondTo: Int
        let text: String
    }

    let matches: [Match]
    static let searchWindow: Double = 90

    init(words: [SystemTranscriber.Word]) throws {
        var characters: [Character] = []
        var owners: [Int] = []
        for (index, word) in words.enumerated() {
            for character in word.text.lowercased() where character.isLetter || character.isNumber {
                characters.append(character); owners.append(index)
            }
        }
        guard characters.count >= 8 else { matches = []; return }
        var seeds: [String: [Int]] = [:]
        var found: [Match] = []
        var seen = Set<String>()
        for b in 0...(characters.count - 4) {
            if b.isMultiple(of: 256) { try Task.checkCancellation() }
            let seed = String(characters[b..<(b + 4)])
            guard Set(seed).count >= 3 else { continue }
            let nearby = (seeds[seed] ?? []).filter {
                words[owners[b]].start - words[owners[$0]].start <= Self.searchWindow
            }
            for a in nearby where owners[a + 3] < owners[b] {
                // Only expand each maximal match once, from its first seed.
                if a > 0, b > 0, characters[a - 1] == characters[b - 1] { continue }
                var count = 4
                while b + count < characters.count, a + count < b,
                      characters[a + count] == characters[b + count] { count += 1 }
                let text = String(characters[a..<(a + count)])
                guard text.contains(where: { !$0.isASCII }) || count >= 12 else { continue }
                let key = "\(owners[a]):\(owners[a + count - 1]):\(owners[b]):\(owners[b + count - 1])"
                guard seen.insert(key).inserted else { continue }
                found.append(Match(firstFrom: owners[a], firstTo: owners[a + count - 1],
                                   secondFrom: owners[b], secondTo: owners[b + count - 1], text: text))
            }
            seeds[seed] = nearby + [b]
        }
        matches = found.sorted { $0.firstFrom < $1.firstFrom }
    }

    func description(words: [SystemTranscriber.Word], units: [SpeechEditAnalysis.Unit],
                     from: Double, to: Double) -> [[String: Any]] {
        func occurrence(_ a: Int, _ b: Int) -> [String: Any] {
            let first = units.firstIndex { $0.from <= a && $0.to >= a }
            let last = units.firstIndex { $0.from <= b && $0.to >= b }
            let contextStart = first.map { units[max(0, $0 - 1)].from } ?? a
            let contextEnd = last.map { units[min(units.count - 1, $0 + 1)].to } ?? b
            return ["from": a, "to": b, "start": words[a].start, "end": words[b].end,
                    "contextFrom": contextStart, "contextTo": contextEnd,
                    "context": SpeechEditAnalysis.text(words[contextStart...contextEnd])]
        }
        return matches.compactMap { match in
            let firstVisible = words[match.firstTo].end > from && words[match.firstFrom].start < to
            let secondVisible = words[match.secondTo].end > from && words[match.secondFrom].start < to
            guard firstVisible || secondVisible else { return nil }
            return ["text": match.text, "evidence": "lexical_match",
                    "occurrences": [occurrence(match.firstFrom, match.firstTo), occurrence(match.secondFrom, match.secondTo)]]
        }
    }
}
