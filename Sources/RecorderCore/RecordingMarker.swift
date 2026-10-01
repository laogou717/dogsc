import Foundation

/// An editorial note anchored to the original recording, never a rendered track.
/// Keeping the source anchor lets ripple edits, retiming and undo share one truth.
public struct RecordingMarker: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceTime: TimeInterval
    public let number: Int

    public init(id: UUID = UUID(), sourceTime: TimeInterval, number: Int) {
        self.id = id
        self.sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        self.number = max(number, 1)
    }
}
