import RecorderCore

/// Authored timeline arrays are kept in deterministic start-time order. Drag
/// constraints prevent a clip from crossing either neighbour, so the common
/// pointer-move path only needs a linear inversion check. A real legacy or
/// malformed inversion still receives the former stable sort repair.
enum EditorTimelineAuthoredOrder {
    @discardableResult
    static func normalize(_ clips: inout [ZoomAnimationClip]) -> Bool {
        normalize(&clips) { lhs, rhs in
            lhs.startTime == rhs.startTime
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.startTime < rhs.startTime
        }
    }

    @discardableResult
    static func normalize(_ clips: inout [ScreenMotionClip]) -> Bool {
        normalize(&clips) { lhs, rhs in
            lhs.timing.startTime == rhs.timing.startTime
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.timing.startTime < rhs.timing.startTime
        }
    }

    @discardableResult
    static func normalize(_ clips: inout [CameraMotionClip]) -> Bool {
        normalize(&clips) { lhs, rhs in
            lhs.timing.startTime == rhs.timing.startTime
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.timing.startTime < rhs.timing.startTime
        }
    }

    private static func normalize<Element>(
        _ values: inout [Element],
        by precedes: (Element, Element) -> Bool
    ) -> Bool {
        guard values.count > 1 else { return false }
        for index in values.indices.dropFirst() where precedes(values[index], values[index - 1]) {
            values.sort(by: precedes)
            return true
        }
        return false
    }
}
