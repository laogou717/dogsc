import Foundation

extension SpeechEditAnalysis {
    /// Small acoustic breaks are grouped for review, not deleted. Brief
    /// activity remains explicit so a breath/click is not described as silence.
    func pauseGroupDescription(from: Double, to: Double, frameRate: Int? = nil) -> [[String: Any]] {
        acoustics.pauseGroups.compactMap { group in
            guard group.end > from, group.start < to, group.end - group.start >= 0.08 else { return nil }
            var row: [String: Any] = ["start": group.start, "end": group.end,
                "duration": group.end - group.start, "quietSeconds": group.quietSeconds,
                "briefActivitySeconds": group.briefActivitySeconds,
                "recordings": group.regions.sorted(), "context": pauseContext(from: group.start, to: group.end)]
            row["acousticInterior"] = ["start": group.start + 0.02, "end": group.end - 0.02]
            if let frameRate { row["durationFrames"] = (group.end - group.start) * Double(frameRate) }
            return row
        }
    }

    func pauseContext(from: Double, to: Double) -> [String: Any] {
        let words = transcript.words
        let indices = words.indices.filter { words[$0].end > from - 1 && words[$0].start < to + 1 }
        guard let first = indices.first, let last = indices.last else { return [:] }
        return ["from": first, "to": last, "text": Self.text(words[first...last]),
            "overlappingWords": indices.filter { words[$0].start < to && words[$0].end > from }]
    }

    /// Map ALL retained pause candidates into the new clock, including those
    /// inside kept sentences. A cut response can then expose what remains,
    /// rather than reviewing only the few boundaries the agent already chose.
    func remainingPauseReview(after cuts: [Span], frameRate: Int) -> [String: Any] {
        let cuts = cuts.sorted { $0.start < $1.start }
        var retained: [(range: Span, removedBefore: Double)] = []
        var previousEnd = 0.0, removed = 0.0
        for cut in cuts {
            if cut.start > previousEnd {
                retained.append((Span(start: previousEnd, end: cut.start), removed))
            }
            removed += cut.duration
            previousEnd = cut.end
        }
        if previousEnd < duration { retained.append((Span(start: previousEnd, end: duration), removed)) }
        struct Candidate {
            let start: Double
            var end: Double
            var originals: [Span]
            var briefActivity: Bool
        }
        var candidates: [Candidate] = []
        for group in acoustics.pauseGroups {
            for kept in retained {
                let a = max(group.start, kept.range.start), b = min(group.end, kept.range.end)
                guard b > a else { continue }
                let start = a - kept.removedBefore, end = b - kept.removedBefore
                if let last = candidates.last, abs(last.end - start) < 0.000_01 {
                    candidates[candidates.count - 1].end = end
                    candidates[candidates.count - 1].originals.append(.init(start: a, end: b))
                    candidates[candidates.count - 1].briefActivity = last.briefActivity || group.briefActivitySeconds > 0.000_01
                } else {
                    candidates.append(Candidate(start: start, end: end, originals: [.init(start: a, end: b)],
                        briefActivity: group.briefActivitySeconds > 0.000_01))
                }
            }
        }
        let visible = candidates.filter { $0.end - $0.start >= 0.08 }
        let rows = visible.map { candidate -> [String: Any] in
            let first = candidate.originals.first!, last = candidate.originals.last!
            var row: [String: Any] = ["start": candidate.start, "end": candidate.end,
                "duration": candidate.end - candidate.start,
                "durationFrames": (candidate.end - candidate.start) * Double(frameRate),
                "containsBriefActivity": candidate.briefActivity,
                "acousticInterior": ["start": candidate.start + 0.02, "end": candidate.end - 0.02],
                "before": pauseContext(from: first.start, to: first.start),
                "after": pauseContext(from: last.end, to: last.end)]
            row["originalPieces"] = candidate.originals.map { ["start": $0.start, "end": $0.end] }
            return row
        }
        return ["count": visible.count, "totalSeconds": visible.reduce(0) { $0 + $1.end - $1.start },
            "atLeastHalfSecond": visible.filter { $0.end - $0.start >= 0.5 }.count, "candidates": rows,
            "timeBasis": "start/end/acousticInterior use the edited timeline. originalPieces and context word IDs use the original analysis.",
            "meaning": "Retained low-energy candidates, including within sentences. Grouping bridges at most 20 ms of brief activity, reported separately. These are options for exact timeline_cut ranges, not required deletions; text and the surrounding action determine the desired pause."]
    }
}
