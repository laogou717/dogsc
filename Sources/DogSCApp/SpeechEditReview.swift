import Foundation
import RecorderCore

extension SpeechEditAnalysis {
    /// Reuses pre-edit evidence; no second transcription or media export is
    /// needed to inspect what every applied deletion actually joined.
    func cutReview(cuts: [Span], before: TimelineMap, after: TimelineMap, frameRate: Int) -> [String: Any] {
        let cuts = cuts.sorted { $0.start < $1.start }
        var removed = 0.0
        var contextRows: [Int: [String: Any]] = [:]
        func contextIDs(at time: Double) -> [Int] {
            utterances.description(words: transcript.words, from: max(0, time - 0.25), to: min(duration, time + 0.25)).compactMap {
                guard let id = $0["id"] as? Int else { return nil }
                contextRows[id] = $0
                return id
            }
        }
        func side(segment: ResolvedRecordingSegment, oldTime: Double, lower: Double, upper: Double,
                  isLeft: Bool) -> [String: Any] {
            let region = regions.first { isLeft ? (oldTime > $0.start && oldTime <= $0.end + 0.000_01) :
                (oldTime >= $0.start - 0.000_01 && oldTime < $0.end) }
            let a = max(lower, region?.start ?? 0), b = min(upper, region?.end ?? duration)
            let tolerance = acoustics.activity.frameDuration * 1.1
            let quiet = acoustics.intervals(from: max(a, oldTime - 2), to: min(b, oldTime + 2)).first {
                isLeft ? ($0.start < oldTime && $0.end >= oldTime - tolerance) :
                    ($0.start <= oldTime + tolerance && $0.end > oldTime)
            }
            let retainedQuiet = quiet.map {
                isLeft ? max(0, min(oldTime, $0.end) - max(a, $0.start)) :
                    max(0, min(b, $0.end) - max(oldTime, $0.start))
            } ?? 0
            var row: [String: Any] = ["segmentId": segment.id.uuidString,
                "source": ["start": segment.sourceStart, "end": segment.sourceEnd, "speed": segment.playbackRate],
                "output": ["start": segment.outputStart, "end": segment.outputEnd],
                "originalEdge": oldTime, "quietSeconds": retainedQuiet,
                "quietFrames": retainedQuiet * Double(frameRate),
                "contextIds": contextIDs(at: oldTime),
                "words": wordsNear(oldTime)]
            if let media = segment.media { row["mediaPath"] = media.path }
            else { row["sourceId"] = segment.sourceID.uuidString }
            if let region, region.audible {
                row["acoustic"] = acoustics.edgeEvidence(at: oldTime, from: region.start, to: region.end)
                // Give the source coordinate for a nearby measured quiet
                // interval. It is an option, never a substituted edit point.
                if let old = before.segments.first(where: {
                    isLeft ? (oldTime > $0.outputStart && oldTime <= $0.outputEnd + 0.000_01) :
                        (oldTime >= $0.outputStart - 0.000_01 && oldTime < $0.outputEnd)
                }), let candidate = acoustics.candidate(from: max(region.start, oldTime - 0.3),
                    to: min(region.end, oldTime + 0.3), anchor: oldTime, region: nil) {
                    let start = max(candidate.start, old.outputStart, oldTime - 0.3)
                    let end = min(candidate.end, old.outputEnd, oldTime + 0.3)
                    if end > start {
                        row["nearbyQuietSourceRange"] = [
                            "start": old.sourceStart + (start - old.outputStart) * old.playbackRate,
                            "end": old.sourceStart + (end - old.outputStart) * old.playbackRate]
                    }
                }
            } else { row["acoustic"] = ["measured": false] }
            return row
        }
        let joins = cuts.enumerated().map { index, cut -> [String: Any] in
            let seam = cut.start - removed
            removed += cut.duration
            let left = after.segments.last { abs($0.outputEnd - seam) <= 1.0 / 60_000 }
            let right = after.segments.first { abs($0.outputStart - seam) <= 1.0 / 60_000 }
            var row: [String: Any] = ["outputTime": seam, "removed": ["start": cut.start, "end": cut.end]]
            if let left {
                row["left"] = side(segment: left, oldTime: cut.start,
                    lower: index > 0 ? cuts[index - 1].end : 0, upper: cut.start, isLeft: true)
            }
            if let right {
                row["right"] = side(segment: right, oldTime: cut.end,
                    lower: cut.end, upper: index + 1 < cuts.count ? cuts[index + 1].start : duration, isLeft: false)
            }
            let leftQuiet = (row["left"] as? [String: Any])?["quietSeconds"] as? Double ?? 0
            let rightQuiet = (row["right"] as? [String: Any])?["quietSeconds"] as? Double ?? 0
            row["retainedQuietSeconds"] = leftQuiet + rightQuiet
            row["retainedQuietFrames"] = (leftQuiet + rightQuiet) * Double(frameRate)
            return row
        }
        return ["available": true, "originalAnalysisId": id, "joins": joins,
            "videoFrameRate": frameRate, "videoFrameDuration": 1 / Double(frameRate),
            "remainingPauses": remainingPauseReview(after: cuts, frameRate: frameRate),
            "contexts": contextRows.keys.sorted().compactMap { contextRows[$0] },
            "timeBasis": "outputTime/output use the edited timeline. removed/originalEdge/words/contexts/acoustic use the pre-cut analysis clock. source and nearbyQuietSourceRange use media source seconds.",
            "refine": "timeline_update accepts each current segmentId with patch.source {start?,end?}; following tracks ripple. Old analysis word/pause IDs belong to the pre-cut snapshot.",
            "evidence": "Measured low energy and recognizer text are advisory; quiet can include weak speech. Contexts can span pauses and edits; they do not prove a complete take."]
    }

    func wordsNear(_ time: Double) -> [[String: Any]] {
        let words = transcript.words
        return words.indices.filter { words[$0].end > time - 0.5 && words[$0].start < time + 0.5 }.map {
            ["i": $0, "s": words[$0].start, "e": words[$0].end, "t": words[$0].text,
             "crossesEdge": words[$0].start < time && words[$0].end > time]
        }
    }
}
