import Foundation

/// Energy evidence is independent of recognizer token gaps. It describes
/// measured audio, not sentence completeness or permission to make an edit.
struct SpeechAcousticEvidence: Sendable {
    struct Quiet: Sendable {
        let start: Double
        let end: Double
        let region: Int
        let thresholdDB: Float
    }

    struct PauseGroup: Sendable {
        let start: Double
        var end: Double
        var quietSeconds: Double
        var regions: Set<Int>
        var briefActivitySeconds: Double { max(0, end - start - quietSeconds) }
    }

    let activity: SpeechActivity
    let quiet: [Quiet]
    let pauseGroups: [PauseGroup]

    init(activity: SpeechActivity, regions: [SpeechEditAnalysis.Region]) throws {
        self.activity = activity
        var result: [Quiet] = []
        let step = activity.frameDuration
        for (regionID, region) in regions.enumerated() where region.audible {
            try Task.checkCancellation()
            let lo = max(0, min(activity.levels.count, Int(ceil(region.start / step))))
            let hi = max(lo, min(activity.levels.count, Int(floor(region.end / step))))
            var first: Int?
            var quietThreshold: Float = -65
            var threshold: Float = -65
            let block = max(Int(2 / step), 1)
            for i in lo..<hi {
                if (i - lo).isMultiple(of: block) {
                    try Task.checkCancellation()
                    let window = activity.levels[max(lo, i - block)..<min(hi, i + 2 * block)].sorted()
                    let floor = window[Int(Double(window.count - 1) * 0.15)]
                    let peak = window[Int(Double(window.count - 1) * 0.9)]
                    // Without local contrast, energy alone cannot identify
                    // room tone as silence. Digital silence is still visible.
                    threshold = peak - floor >= 10 ? max(-65, min(floor + 6, peak - 14)) : -65
                }
                if activity.levels[i] <= threshold {
                    if first == nil { first = i; quietThreshold = threshold }
                } else if let a = first {
                    if Double(i - a) * step >= 0.04 {
                        result.append(Quiet(start: Double(a) * step, end: Double(i) * step,
                                            region: regionID, thresholdDB: quietThreshold))
                    }
                    first = nil
                }
            }
            if let a = first, Double(hi - a) * step >= 0.04 {
                result.append(Quiet(start: Double(a) * step, end: min(region.end, Double(hi) * step),
                                    region: regionID, thresholdDB: quietThreshold))
            }
        }
        quiet = result.sorted { $0.start < $1.start }
        var groups: [PauseGroup] = []
        for interval in quiet {
            if let last = groups.last, interval.start - last.end <= 0.020_001,
               (last.quietSeconds + interval.end - interval.start) / (interval.end - last.start) >= 0.85 {
                groups[groups.count - 1].end = interval.end
                groups[groups.count - 1].quietSeconds += interval.end - interval.start
                groups[groups.count - 1].regions.insert(interval.region)
            } else {
                groups.append(PauseGroup(start: interval.start, end: interval.end,
                    quietSeconds: interval.end - interval.start, regions: [interval.region]))
            }
        }
        pauseGroups = groups
    }

    func groups(from: Double, to: Double) -> [PauseGroup] {
        var lo = 0, hi = pauseGroups.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pauseGroups[mid].end < from { lo = mid + 1 } else { hi = mid }
        }
        var result: [PauseGroup] = []
        while lo < pauseGroups.count, pauseGroups[lo].start <= to {
            result.append(pauseGroups[lo]); lo += 1
        }
        return result
    }

    func intervals(from: Double, to: Double) -> [Quiet] {
        var lo = 0, hi = quiet.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if quiet[mid].end < from { lo = mid + 1 } else { hi = mid }
        }
        var result: [Quiet] = []
        while lo < quiet.count, quiet[lo].start <= to {
            result.append(quiet[lo]); lo += 1
        }
        return result
    }

    /// A suggested quiet point may fall inside an ASR run. Return it as
    /// evidence; the cut resolver never substitutes it for an explicit time.
    func candidate(from: Double, to: Double, anchor: Double, region: Int?) -> Quiet? {
        intervals(from: from, to: to).filter { region == nil || $0.region == region }.min {
            func distance(_ span: Quiet) -> Double {
                max(span.start - anchor, anchor - span.end, 0)
            }
            if abs(distance($0) - distance($1)) > 0.000_01 { return distance($0) < distance($1) }
            return $0.end - $0.start > $1.end - $1.start
        }
    }

    /// Always keep fine samples at an edit edge, independently of the optional
    /// broad waveform page. The window can include audio about to be removed.
    func edgeEvidence(at time: Double, from lower: Double, to upper: Double) -> [String: Any] {
        let from = max(lower, time - 0.15, 0)
        let to = min(upper, time + 0.15, activity.duration)
        guard to > from else { return ["time": time, "measured": false] }
        let step = activity.frameDuration
        // Whole measurement bins only, so a neighbouring recording cannot
        // leak into this edge's measurements.
        let lo = max(0, min(activity.levels.count, Int(ceil(from / step))))
        let hi = max(lo, min(activity.levels.count, Int(floor(to / step))))
        func peak(from a: Double, to b: Double) -> Double? {
            let first = max(lo, min(hi, Int(ceil(a / step))))
            let last = max(first, min(hi, Int(floor(b / step))))
            return activity.levels[first..<last].max().map { Double($0.rounded()) }
        }
        var result: [String: Any] = ["time": time, "measured": hi > lo,
            "waveform": ["start": Double(lo) * step, "step": step,
                "peakDBFS": activity.levels[lo..<hi].map { Double($0.rounded()) }] as [String: Any],
            "lowEnergy": intervals(from: from, to: to).compactMap { quiet -> [String: Any]? in
                let a = max(quiet.start, from), b = min(quiet.end, to)
                guard b > a else { return nil }
                return ["start": a, "end": b, "thresholdDB": quiet.thresholdDB]
            }]
        result["before30msPeakDBFS"] = peak(from: time - 0.03, to: time)
        result["after30msPeakDBFS"] = peak(from: time, to: time + 0.03)
        return result
    }

    func description(from: Double, to: Double, includeWaveform: Bool) -> [String: Any] {
        func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        var result: [String: Any] = [
            "measurementStep": activity.frameDuration,
            "lowEnergy": intervals(from: from, to: to).map {
                ["start": rounded($0.start), "end": rounded($0.end), "recording": $0.region,
                 "thresholdDB": $0.thresholdDB] as [String: Any]
            },
            "meaning": "Low energy is measured independently of ASR words; it can include breaths or weak speech. Absence of a quiet span does not prove continuous speech.",
        ]
        if includeWaveform {
            let step = activity.frameDuration
            let lo = max(0, min(activity.levels.count, Int(floor(from / step))))
            let hi = max(lo, min(activity.levels.count, Int(ceil(to / step))))
            // Peak bins retain short consonants. Detail increases naturally
            // when the caller requests a smaller window.
            let stride = max(Int(ceil(Double(hi - lo) / 1500)), 1)
            let bins = Swift.stride(from: lo, to: hi, by: stride).map { i in
                Double((activity.levels[i..<min(i + stride, hi)].max() ?? -120).rounded())
            }
            result["waveform"] = ["start": Double(lo) * step, "end": min(to, activity.duration),
                                  "step": Double(stride) * step, "peakDBFS": bins]
        }
        return result
    }
}
