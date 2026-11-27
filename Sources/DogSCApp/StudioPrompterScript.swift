import AppKit
import CoreText

struct StudioPrompterScript {
    struct Line {
        let offset: Int
        let text: String
        let spoken: [Character]
    }

    let source: String
    let lines: [Line]

    init(text: String, width: CGFloat, fontSize: CGFloat) {
        self.source = text
        let source = text as NSString
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let layout = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let breaks = ReadingBreaks(source)
        var offset = 0
        var lines: [Line] = []
        while offset < source.length && !Task.isCancelled {
            let width = max(1, min(width - 2, fontSize * 20))
            let fit = CTTypesetterSuggestLineBreak(layout, offset, width)
            let end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: min(source.length - 1, offset + max(1, fit) - 1)))
            let limit = breaks.end(from: offset, fitting: end)
            let literal = source.substring(with: NSRange(location: offset, length: limit - offset))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !literal.isEmpty {
                lines.append(Line(offset: offset, text: literal, spoken: Self.normalize(literal)))
            }
            offset = limit
        }
        self.lines = lines
    }

    static func normalize(_ text: String) -> [Character] {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    func line(at offset: Int) -> Int {
        lines.lastIndex(where: { $0.offset <= offset }) ?? 0
    }
}

/// All boundaries use the editor's UTF-16 offsets. Layout never rewrites the draft.
private struct ReadingBreaks {
    private var sentences = IndexSet()
    private var clauses = IndexSet()
    private let words: IndexSet

    init(_ text: NSString) {
        let range = NSRange(location: 0, length: text.length)
        var words = IndexSet()
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, enclosing, _ in
            words.insert(NSMaxRange(enclosing))
        }
        let source = text as String
        for match in Self.punctuation.matches(in: source, range: range) {
            let end = NSMaxRange(match.range)
            if match.range(at: 1).location != NSNotFound { sentences.insert(end) }
            else { clauses.insert(end) }
        }
        sentences.insert(text.length)
        // Keep a quantity, its magnitude and a following unit together if they fit on a fresh line.
        for match in Self.quantity.matches(in: source, range: range) {
            words.remove(integersIn: (match.range.location + 1)..<NSMaxRange(match.range))
            words.insert(match.range.location)
        }
        self.words = words
    }

    private static let punctuation = try! NSRegularExpression(
        pattern: #"([。！？!?；;\r\n]+|[.]+(?=\s|$)|…+)[”’」』）)"]*|[，：:]|(?<!\d),|,(?!\d)"#)
    private static let quantity = try! NSRegularExpression(
        pattern: #"[0-9０-９]+(?:[.,][0-9０-９]+)*(?:[ \t]*[十百千万亿萬億]+)?(?:[ \t]*[%％]|[ \t]+[A-Za-z]+)?"#)

    func end(from start: Int, fitting limit: Int) -> Int {
        if let sentence = sentences.integerGreaterThan(start), sentence <= limit { return sentence }
        if let clause = clauses.integerLessThanOrEqualTo(limit), clause > start { return clause }
        if let word = words.integerLessThanOrEqualTo(limit), word > start { return word }
        return limit
    }
}

struct StudioPrompterCursor {
    private(set) var index = 0
    private(set) var offScript = false
    private var consumed = 0
    private var lastHypothesis: [Character] = []

    func visibleLineIndices(rowCount: Int) -> Range<Int> {
        // Leave the missing neighbour blank at the start and end of the script.
        let first = index - (rowCount >= 3 ? 1 : 0)
        return first..<(first + rowCount)
    }

    mutating func newUtterance() {
        consumed = 0
        lastHypothesis.removeAll()
        offScript = false
    }

    mutating func seek(_ index: Int) {
        self.index = index
        consumed = lastHypothesis.count
        offScript = false
    }

    mutating func hear(_ text: String, in script: StudioPrompterScript) {
        let heard = StudioPrompterScript.normalize(text)
        guard !heard.isEmpty, heard != lastHypothesis, script.lines.indices.contains(index) else { return }
        // Speech can shorten a partial result. Clamp the consumed prefix after a revision;
        // if the recognizer has started a different, shorter hypothesis, listen from its start.
        if heard.count < lastHypothesis.count {
            if heard.prefix(4) != lastHypothesis.prefix(min(4, heard.count)) { consumed = 0 }
            consumed = min(consumed, heard.count)
        }
        lastHypothesis = heard
        let start = max(consumed, heard.count - 64)
        guard start < heard.count else { return }
        let recent = heard[start...]
        var best: SpeechAlignment?
        var bestLine = index
        // Only search the local reading position. Equal evidence favors the nearest line.
        for line in index..<min(index + 5, script.lines.count) {
            let cue = script.lines[line].spoken
            if let match = SpeechAlignment.best(in: cue, heard: recent, distance: line - index),
               match.rank > (best?.rank ?? 0) {
                best = match
                bestLine = line
            }
        }
        // Fresh speech can also be a retake of the line still visible above.
        // On equal evidence keep reading forwards (consecutive cues may repeat).
        if index > 0,
           let previous = SpeechAlignment.best(in: script.lines[index - 1].spoken, heard: recent, distance: 1),
           previous.rank > (best?.rank ?? 0) {
            best = previous
            bestLine = index - 1
        }
        guard let best else {
            offScript = index + 1 < script.lines.count && heard.count - consumed > script.lines[index].spoken.count + 8
            return
        }
        offScript = false
        index = bestLine
        if best.completed {
            index = min(index + 1, script.lines.count - 1)
            consumed = best.heardEnd
        } else {
            consumed = max(consumed, best.heardStart)
        }
        while index + 1 < script.lines.count && script.lines[index].spoken.isEmpty { index += 1 }
    }
}

/// Local alignment lets a speaker pick up in the middle of a cue. Score only
/// paths ending near the newest speech, so a long aside can't replay an old cue.
private struct SpeechAlignment {
    let rank: Int
    let heardStart: Int
    let heardEnd: Int
    let completed: Bool

    private struct Cell {
        var score = 0
        var matches = 0
        var start = 0
    }

    static func best(in cue: [Character], heard: ArraySlice<Character>, distance: Int) -> Self? {
        guard !cue.isEmpty else { return nil }
        let chineseLength = cue.contains { !$0.isASCII }
        let required = distance == 0 ? min(cue.count, chineseLength ? 4 : 7)
            : (chineseLength ? (distance == 1 ? 4 : 5) : 8)
        guard cue.count >= required, heard.count >= required else { return nil }
        var previous = Array(repeating: Cell(), count: cue.count + 1)
        var row = previous
        var best: Self?
        for i in heard.indices {
            for j in cue.indices {
                let equal = heard[i] == cue[j]
                var aligned = previous[j]
                if aligned.score == 0 { aligned.start = i }
                aligned.score += equal ? 3 : -2
                if equal { aligned.matches += 1 }
                // Only a diagonal step consumes a spoken and a written character.
                // A gap at the last written character cannot finish a cue early.
                let lag = heard.endIndex - i - 1
                if lag <= 2, aligned.matches >= required, aligned.score >= required * 2,
                   aligned.matches * 3 >= (i + 1 - aligned.start) * 2 {
                    let completed = j == cue.count - 1
                    let rank = aligned.score - lag * 3 + (completed ? 1 : 0)
                    if rank > (best?.rank ?? 0) {
                        best = Self(rank: rank, heardStart: aligned.start, heardEnd: i + 1, completed: completed)
                    }
                }
                let gap = previous[j + 1].score > row[j].score ? previous[j + 1] : row[j]
                if gap.score - 2 > aligned.score {
                    aligned = gap
                    aligned.score -= 2
                }
                row[j + 1] = aligned.score > 0 ? aligned : Cell()
            }
            swap(&previous, &row)
        }
        return best
    }
}
