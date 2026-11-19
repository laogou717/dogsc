import Foundation
import RecorderCore

/// Evidence for an agent's editing decisions, not a sentence classifier.
/// Text preserves the recognizer's wording; energy supplies conservative
/// quiet boundaries. Neither a pause nor recognizer punctuation proves that
/// a take is complete. That decision needs the surrounding attempts.
struct SpeechEditAnalysis: Sendable {
    struct Span: Sendable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    struct Region: Sendable {
        let segmentID: UUID
        let sourceID: UUID
        let start: Double
        let end: Double
        let audible: Bool
    }

    struct Boundary: Sendable {
        let beforeWord: Int
        let start: Double
        let end: Double
        let evidence: String
        /// Quiet interval with a small guard against weak consonants/tails.
        let quiet: Span?
        /// End of the retained left side / start of the retained right side.
        let cutAfterLeft: Double?
        let cutBeforeRight: Double?
        /// A low-energy candidate, not proof that a spoken word ends here.
        let tokenCut: Double?
    }

    struct Unit: Sendable {
        let from: Int
        let to: Int
        let text: String
        let sentencePunctuation: Bool
    }

    struct AnalysisError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Resolution {
        let ranges: [Span]
        let evidence: [[String: Any]]
    }

    let id: String
    let transcript: SystemTranscriber.Transcript
    let duration: Double
    let measuredDuration: Double
    let regions: [Region]
    let boundaries: [Boundary]
    let units: [Unit]
    let acoustics: SpeechAcousticEvidence
    let subtitleAlignment: SpeechSubtitleAlignment
    let repetitions: SpeechRepeatEvidence
    let utterances: SpeechUtteranceEvidence

    static func analyze(url: URL, language: String, duration: Double, regions: [Region]) async throws -> Self {
        let measurement = Task.detached(priority: .utility) { try SpeechActivity.measure(url: url) }
        defer { measurement.cancel() }
        return try await withTaskCancellationHandler {
            let transcript = try await SystemTranscriber.transcribe(url: url, localeIdentifier: language)
            let activity = try await measurement.value
            try Task.checkCancellation()
            let builder = Task.detached(priority: .userInitiated) {
                try Self(transcript: transcript, activity: activity, duration: duration, regions: regions)
            }
            return try await withTaskCancellationHandler { try await builder.value } onCancel: { builder.cancel() }
        } onCancel: { measurement.cancel() }
    }

    init(transcript: SystemTranscriber.Transcript, activity: SpeechActivity,
         duration: Double, regions: [Region]) throws {
        guard duration.isFinite, duration > 0, !activity.levels.isEmpty,
              activity.frameDuration.isFinite, activity.frameDuration > 0 else {
            throw AnalysisError(message: "The voice waveform is incomplete; no speech edits can be planned from it.")
        }
        try Task.checkCancellation()
        let acoustics = try SpeechAcousticEvidence(activity: activity, regions: regions)
        let words = transcript.words
        for (i, word) in words.enumerated() {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0,
                  word.end > word.start, word.end <= duration + 0.05,
                  i == 0 || word.start >= words[i - 1].start else {
                throw AnalysisError(message: "Recognizer token times are not ordered within this program. Transcribe again before editing.")
            }
        }
        // One owner per word. A recognizer run spanning an existing edit is
        // deliberately not split into guessed per-character times.
        let owners: [Int?] = words.map { word in
            regions.firstIndex { $0.audible && word.start >= $0.start - 0.000_01 && word.end <= $0.end + 0.000_01 }
        }
        var boundaries: [Boundary] = []
        var precedingEnd = 0.0
        for i in 0...words.count {
            if i.isMultiple(of: 256) { try Task.checkCancellation() }
            let left = i > 0 ? words[i - 1] : nil
            let right = i < words.count ? words[i] : nil
            precedingEnd = max(precedingEnd, left?.end ?? 0)
            let a = precedingEnd, b = right?.start ?? duration
            let leftOwner = i > 0 ? owners[i - 1] : nil
            let rightOwner = i < words.count ? owners[i] : nil
            let sameRegion = leftOwner != nil && leftOwner == rightOwner
            // Existing source/clip boundaries can be retained exactly. They
            // are labelled separately from evidence of a natural pause.
            if !sameRegion, (left == nil || leftOwner != nil), (right == nil || rightOwner != nil),
               leftOwner != rightOwner {
                boundaries.append(Boundary(beforeWord: i, start: a, end: b, evidence: "existing_edit",
                    quiet: nil,
                    cutAfterLeft: leftOwner.map { regions[$0].end } ?? rightOwner.map { regions[$0].start },
                    cutBeforeRight: rightOwner.map { regions[$0].start } ?? leftOwner.map { regions[$0].end }, tokenCut: nil))
                continue
            }
            let searchStart = max(leftOwner.map { regions[$0].start } ?? 0,
                                  left.map { Self.isSpoken($0.text) ? a - 0.25 : $0.start } ?? 0)
            let searchEnd = min(rightOwner.map { regions[$0].end } ?? duration,
                                right.map { Self.isSpoken($0.text) ? b + 0.25 : $0.end } ?? duration)
            let best = acoustics.candidate(from: searchStart, to: searchEnd, anchor: (a + b) / 2,
                                           region: sameRegion ? leftOwner : nil)
            let quiet = best.map { Span(start: max(searchStart, $0.start), end: min(searchEnd, $0.end)) }
                .flatMap { $0.duration >= 0.04 ? $0 : nil }
            let evidence = quiet != nil ? "low_energy" : (b < a ? "overlapping_tokens" :
                (sameRegion ? "no_quiet_detected" : "unresolved_recording_boundary"))
            boundaries.append(Boundary(beforeWord: i, start: a, end: b, evidence: evidence, quiet: quiet,
                cutAfterLeft: quiet.map { $0.start + min(0.02, $0.duration / 4) },
                cutBeforeRight: quiet.map { $0.end - min(0.02, $0.duration / 4) },
                tokenCut: Self.tokenCut(activity: activity, start: max(searchStart, 0),
                                        end: min(searchEnd, activity.duration))))
        }
        var units: [Unit] = []
        var first = 0
        for i in words.indices {
            let punctuation = Self.endsSentence(words[i].text, next: i + 1 < words.count ? words[i + 1].text : nil)
            let after = boundaries[i + 1]
            let pause = after.quiet.map {
                $0.duration >= 0.22 && $0.start <= max(after.start, after.end)
                    && $0.end >= min(after.start, after.end)
            } ?? false
            let contextLimit = words[i].end - words[first].start >= 12
            if punctuation || pause || after.evidence == "existing_edit" || contextLimit || i == words.count - 1 {
                units.append(Unit(from: first, to: i, text: Self.text(words[first...i]), sentencePunctuation: punctuation))
                first = i + 1
            }
        }
        self.id = UUID().uuidString
        self.transcript = transcript
        self.duration = duration
        self.measuredDuration = activity.duration
        self.regions = regions
        self.boundaries = boundaries
        self.units = units
        self.acoustics = acoustics
        self.repetitions = try SpeechRepeatEvidence(words: words)
        self.utterances = SpeechUtteranceEvidence(words: words, regions: regions)
        self.subtitleAlignment = SpeechSubtitleAlignment(transcript: transcript, acoustics: acoustics, regions: regions)
    }

    private static func tokenCut(activity: SpeechActivity, start: Double, end: Double) -> Double? {
        guard start >= 0, end >= start, end <= activity.duration else { return nil }
        let step = activity.frameDuration
        let lo = max(Int(ceil(start / step)), 0)
        let hi = min(Int(floor(end / step)), activity.levels.count)
        guard lo < hi else { return (start + end) / 2 }
        // A local energy minimum; it may be voiced and is labelled accordingly.
        let best = (lo..<hi).min { activity.levels[$0] < activity.levels[$1] } ?? lo
        return min(max((Double(best) + 0.5) * step, start), end)
    }

    /// Bounded pages keep raw waveform samples and the full word list out of
    /// the model context. Adjacent units are included for semantic continuity.
    func description(from: Double, to: Double, includeWords: Bool, includeWaveform: Bool = false,
                     frameRate: Int) -> [String: Any] {
        let words = transcript.words
        let matching = units.indices.filter { words[units[$0].to].end > from && words[units[$0].from].start < to }
        let visible: ArraySlice<Unit>
        if let first = matching.first, let last = matching.last {
            visible = units[max(first - 1, 0)...min(last + 1, units.count - 1)]
        } else { visible = [] }
        func edge(_ boundary: Boundary) -> [String: Any] {
            var result: [String: Any] = ["evidence": boundary.evidence, "gap": Self.round(max(0, boundary.end - boundary.start))]
            result["beforeWord"] = boundary.beforeWord
            result["recognizerGap"] = [Self.round(boundary.start), Self.round(boundary.end)]
            if let quiet = boundary.quiet { result["quiet"] = [Self.round(quiet.start), Self.round(quiet.end)] }
            if let cut = boundary.cutAfterLeft { result["suggestedAfterLeft"] = Self.round(cut) }
            if let cut = boundary.cutBeforeRight { result["suggestedBeforeRight"] = Self.round(cut) }
            if let cut = boundary.tokenCut { result["energyMinimum"] = Self.round(cut) }
            return result
        }
        var result: [String: Any] = [
            "analysisId": id, "outputDuration": duration, "window": ["start": from, "end": to],
            "videoFrameRate": frameRate, "videoFrameDuration": 1 / Double(frameRate),
            "frameBasis": "Frame counts use the current export frame rate; waveform measurementStep is an independent audio sampling interval. Frame counts may be fractional and do not snap requested cut times.",
            "units": visible.map { unit -> [String: Any] in
                var row: [String: Any] = ["from": unit.from, "to": unit.to,
                    "start": Self.round(words[unit.from].start), "end": Self.round(words[unit.to].end),
                    "text": unit.text, "head": edge(boundaries[unit.from]), "tail": edge(boundaries[unit.to + 1]),
                    "sentencePunctuation": unit.sentencePunctuation]
                if let region = regions.firstIndex(where: { words[unit.from].start >= $0.start && words[unit.from].start < $0.end }) {
                    row["recording"] = region
                }
                return row
            },
            "pauses": acoustics.quiet.enumerated().compactMap { i, quiet -> [String: Any]? in
                guard quiet.end > from, quiet.start < to else { return nil }
                return ["id": i, "start": Self.round(quiet.start), "end": Self.round(quiet.end),
                        "quiet": [Self.round(quiet.start), Self.round(quiet.end)],
                        "maxRemoval": Self.round(quiet.end - quiet.start),
                        "durationFrames": (quiet.end - quiet.start) * Double(frameRate), "recording": quiet.region]
            },
            "acoustic": acoustics.description(from: from, to: to, includeWaveform: includeWaveform),
            "basis": "Raw recognizer text and independent local 10 ms energy. Low energy can include weak speech; a unit, punctuation, or existing edit does not prove sentence completeness. Timing suggestions are optional, not applied automatically.",
            "next": "includeWords returns detailed boundaries. timeline_cut accepts wordRanges [{from,to,start?,end?}], pauses [{id,keep}], and exact ranges [{start,end}]. Word defaults use recognizer endpoints; explicit times take priority. keep is remaining gap seconds (default 0.25)."
        ]
        let contextRegions = Set(visible.compactMap { unit in
            regions.firstIndex { words[unit.from].start >= $0.start && words[unit.from].start < $0.end }
        })
        result["recordings"] = regions.indices.filter {
            contextRegions.contains($0) || (regions[$0].end > from && regions[$0].start < to)
        }.map { i -> [String: Any] in
            let region = regions[i]
            return ["i": i, "sourceId": region.sourceID.uuidString, "segmentId": region.segmentID.uuidString,
                    "start": region.start, "end": region.end, "analysed": region.audible]
        }
        if to < duration { result["nextStart"] = to }
        result["utterances"] = utterances.description(words: words, from: from, to: to)
        result["pauseGroups"] = pauseGroupDescription(from: from, to: to, frameRate: frameRate)
        result["pauseGroupBasis"] = "Nearby low-energy intervals grouped across at most 20 ms of brief activity. acousticInterior is an optional exact removal range with 20 ms edge margins; context and overlap with ASR words remain visible. Existing pauses IDs still address individual measured intervals."
        result["repeatedPhrases"] = repetitions.description(words: words, units: utterances.contexts.map(\.words), from: from, to: to).map { pair in
            var pair = pair
            if let occurrences = pair["occurrences"] as? [[String: Any]] {
                pair["occurrences"] = occurrences.map { occurrence in
                    var row = occurrence
                    if let a = row["from"] as? Int, let b = row["to"] as? Int {
                        row["head"] = edge(boundaries[a]); row["tail"] = edge(boundaries[b + 1])
                    }
                    return row
                }
            }
            return pair
        }
        result["repeatEvidence"] = ["nearbyWindowSeconds": SpeechRepeatEvidence.searchWindow,
            "meaning": "Matching wording with context, not a deletion decision. Partial repetitions, intentional emphasis, and recognition errors can all appear here."]
        result["joins"] = joinDescription(from: from, to: to, frameRate: frameRate)
        result["subtitleAlignment"] = subtitleAlignment.description(raw: words)
        if includeWords, let first = visible.first, let last = visible.last {
            result["words"] = (first.from...last.to).map { i -> [String: Any] in
                ["i": i, "s": Self.round(words[i].start), "e": Self.round(words[i].end), "t": words[i].text,
                 "before": edge(boundaries[i]), "after": edge(boundaries[i + 1])]
            }
        }
        return result
    }

    /// Inspect the resulting program as well as the original one. Caption
    /// cleanup cannot conceal an audible repeated phrase in this raw evidence.
    private func joinDescription(from: Double, to: Double, frameRate: Int) -> [[String: Any]] {
        let words = transcript.words
        var result: [[String: Any]] = []
        for (index, region) in regions.enumerated() where index > 0 {
            let previous = regions[index - 1]
            let time = region.start
            guard time >= from, time <= to else { continue }
            let leftQuiet = acoustics.intervals(from: max(previous.start, time - 1), to: time)
                .last { $0.region == index - 1 && $0.start < time && abs($0.end - time) <= acoustics.activity.frameDuration * 1.1 }
            let rightQuiet = acoustics.intervals(from: time, to: min(region.end, time + 1))
                .first { $0.region == index && $0.end > time && abs($0.start - time) <= acoustics.activity.frameDuration * 1.1 }
            let near = words.indices.filter { words[$0].end > time - 1 && words[$0].start < time + 1 }
            var row: [String: Any] = ["time": time, "rightSegmentId": region.segmentID.uuidString,
                "leftSegmentId": previous.segmentID.uuidString, "rightSourceId": region.sourceID.uuidString]
            let leftSeconds = leftQuiet.map { time - max($0.start, previous.start) } ?? 0
            let rightSeconds = rightQuiet.map { min($0.end, region.end) - time } ?? 0
            row["leftQuietTail"] = leftSeconds
            row["rightQuietLead"] = rightSeconds
            row["leftQuietFrames"] = leftSeconds * Double(frameRate)
            row["rightQuietFrames"] = rightSeconds * Double(frameRate)
            row["leftAcoustic"] = previous.audible
                ? acoustics.edgeEvidence(at: time, from: previous.start, to: previous.end) : ["measured": false]
            row["rightAcoustic"] = region.audible
                ? acoustics.edgeEvidence(at: time, from: region.start, to: region.end) : ["measured": false]
            let context = utterances.description(words: words, from: max(0, time - 0.25), to: min(duration, time + 0.25))
            row["contextIds"] = context.compactMap { $0["id"] as? Int }
            row["crossingWords"] = near.filter { words[$0].start < time && words[$0].end > time }
            row["words"] = near.map { ["i": $0, "s": words[$0].start, "e": words[$0].end, "t": words[$0].text] as [String: Any] }
            result.append(row)
        }
        return result
    }

    /// Resolve the agent's decision without imposing an acoustic veto. Word
    /// ranges use recognizer times unless the caller supplies precise start/end
    /// overrides. Evidence never silently expands a requested deletion.
    func resolve(wordRanges rawWords: [[String: Any]], pauses rawPauses: [[String: Any]]) throws -> Resolution {
        let words = transcript.words
        var cuts: [Span] = []
        var evidence: [[String: Any]] = []
        for raw in rawWords {
            guard let from = Self.index(raw["from"], count: words.count), let to = Self.index(raw["to"], count: words.count), to >= from else {
                throw AnalysisError(message: "wordRanges require valid inclusive from/to token IDs from this analysis; nothing was changed.")
            }
            for key in ["start", "end"] where raw[key] != nil && !(raw[key] is NSNumber) {
                throw AnalysisError(message: "\(key) must be an output time in seconds; nothing was changed.")
            }
            let start = (raw["start"] as? NSNumber)?.doubleValue ?? words[from].start
            let end = (raw["end"] as? NSNumber)?.doubleValue ?? min(duration, words[from...to].map(\.end).max() ?? words[to].end)
            guard start.isFinite, end.isFinite, start >= 0, end <= duration, end > start else {
                throw AnalysisError(message: "The resolved word range must be a positive finite interval within the program; nothing was changed.")
            }
            let head = boundaries[from], tail = boundaries[to + 1]
            evidence.append(["from": from, "to": to, "start": start, "end": end,
                             "timing": raw["start"] != nil || raw["end"] != nil ? "explicit" : "recognizer",
                             "head": head.evidence, "tail": tail.evidence,
                             "withinAnalysedRecordings": coveredByRecordings(start: start, end: end)])
            // Older clients may send continuousReason. It is accepted for
            // compatibility but grants no extra permission and changes no time.
            cuts.append(Span(start: start, end: end))
        }
        var seenPauses = Set<Int>()
        for raw in rawPauses {
            guard let index = Self.index(raw["id"], count: acoustics.quiet.count), seenPauses.insert(index).inserted else {
                throw AnalysisError(message: "Unknown or duplicate pause ID; use pauses from the same analysis. Nothing was changed.")
            }
            let quiet = acoustics.quiet[index]
            if let value = raw["keep"], !(value is NSNumber) {
                throw AnalysisError(message: "Pause keep must be a number of seconds; nothing was changed.")
            }
            let keep = (raw["keep"] as? NSNumber)?.doubleValue ?? 0.25
            guard keep.isFinite, keep >= 0 else {
                throw AnalysisError(message: "Pause keep must be a finite nonnegative number of seconds; nothing was changed.")
            }
            let removal = max(0, quiet.end - quiet.start - keep)
            guard removal > 1.0 / 120_000 else { continue }
            let middle = (quiet.start + quiet.end) / 2
            cuts.append(Span(start: middle - removal / 2, end: middle + removal / 2))
            evidence.append(["pause": index, "keep": keep, "start": middle - removal / 2,
                             "end": middle + removal / 2, "evidence": "low_energy"])
        }
        return Resolution(ranges: cuts, evidence: evidence)
    }

    private func coveredByRecordings(start: Double, end: Double) -> Bool {
        guard start >= 0, end <= measuredDuration + 0.02 else { return false }
        let covered = regions.filter(\.audible).reduce(0.0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
        return abs(covered - (end - start)) < 0.000_01
    }

    static func isSpoken(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }

    private static func index(_ value: Any?, count: Int) -> Int? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite, n.doubleValue >= 0,
              n.doubleValue < Double(count), n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }

    static func endsSentence(_ text: String, next: String?) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’」』)）")))
        if stripped.hasSuffix("."), stripped.dropLast().last?.isNumber == true, next?.first?.isNumber == true { return false }
        return stripped.last.map { "。！？!?；;".contains($0) || $0 == "." } ?? false
    }

    static func text(_ words: ArraySlice<SystemTranscriber.Word>) -> String {
        var result = ""
        for word in words {
            if let left = result.last, let right = word.text.first, left.isASCII, right.isASCII,
               (left.isLetter || left.isNumber), (right.isLetter || right.isNumber) { result += " " }
            result += word.text
        }
        return result
    }

    private static func round(_ time: Double) -> Double { (time * 1000).rounded() / 1000 }
}
