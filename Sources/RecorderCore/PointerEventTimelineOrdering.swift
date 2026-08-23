import Foundation

/// Normalizes imported pointer events while making the normal recording path
/// allocation-free. The Quartz event tap and project JSONL preserve monotonic
/// order, so rebuilding an editor plan should not repeatedly copy and sort a
/// long track that already satisfies the evaluator's contract.
public enum PointerEventTimelineOrdering {
    public static func isNormalized(_ events: [PointerEventRecord]) -> Bool {
        var previousTime: TimeInterval?
        for event in events {
            guard event.time.isFinite else { return false }
            if let previousTime, event.time < previousTime { return false }
            previousTime = event.time
        }
        return true
    }

    public static func normalized(_ events: [PointerEventRecord]) -> [PointerEventRecord] {
        guard !isNormalized(events) else {
            // Array is copy-on-write: returning this value shares the existing
            // storage instead of materializing a second long pointer track.
            return events
        }
        var repaired = events.filter { $0.time.isFinite }
        repaired.sort { $0.time < $1.time }
        return repaired
    }
}
