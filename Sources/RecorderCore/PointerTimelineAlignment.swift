import Foundation

/// Bakes the pointer recorder's independent host-clock placement into the
/// saved event times. A pointer tap may start just before the first video
/// frame; in that case the last pre-roll position becomes a non-clicking seed
/// at t=0 instead of shifting the whole path late or creating a phantom click.
public enum PointerTimelineAlignment {
    public static func align(
        _ events: [PointerEventRecord],
        startOffset: TimeInterval,
        sourceStartTime: TimeInterval
    ) -> [PointerEventRecord] {
        let shift = max(startOffset, 0) - max(sourceStartTime, 0)
        if shift == 0 { return PointerEventTimelineOrdering.normalized(events) }
        var lastPreRoll: PointerEventRecord?
        var aligned: [PointerEventRecord] = []

        // The live recorder and project loader already preserve monotonic
        // order. Share that storage in the normal case; only imported or
        // damaged tracks pay for a repair sort.
        for event in PointerEventTimelineOrdering.normalized(events) {
            let time = event.time + shift
            guard time >= 0 else {
                lastPreRoll = event
                continue
            }
            if aligned.isEmpty, let lastPreRoll, time > 0.000_001 {
                aligned.append(PointerEventRecord(
                    time: 0,
                    location: lastPreRoll.location,
                    kind: .move,
                    modifiers: lastPreRoll.modifiers,
                    cursorAssetID: lastPreRoll.cursorAssetID
                ))
            }
            aligned.append(PointerEventRecord(
                time: max(time, 0),
                location: event.location,
                kind: event.kind,
                modifiers: event.modifiers,
                cursorAssetID: event.cursorAssetID
            ))
        }

        if aligned.isEmpty, let lastPreRoll {
            aligned.append(PointerEventRecord(
                time: 0,
                location: lastPreRoll.location,
                kind: .move,
                modifiers: lastPreRoll.modifiers,
                cursorAssetID: lastPreRoll.cursorAssetID
            ))
        }
        return aligned
    }
}
