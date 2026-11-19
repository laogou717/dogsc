import Foundation

/// An editorial note anchored to the original recording, never a rendered track.
/// Keeping the source anchor lets ripple edits, retiming and undo share one truth.
public struct RecordingMarker: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceTime: TimeInterval
    public let number: Int
    /// Markers use the original recording clock; nil means the primary source.
    public let sourceID: UUID?

    public var resolvedSourceID: UUID { sourceID ?? RecordingSource.primaryID }

    public init(id: UUID = UUID(), sourceTime: TimeInterval, number: Int, sourceID: UUID? = nil) {
        self.id = id
        self.sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        self.number = max(number, 1)
        self.sourceID = sourceID
    }
}
