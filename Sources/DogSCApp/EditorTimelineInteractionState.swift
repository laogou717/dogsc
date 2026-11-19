import Combine
import Foundation
import RecorderCore

/// Continuous timeline edits notify the monitor, timeline and inspector only.
/// The document, media bin and chat keep their committed snapshot until release.
@MainActor
final class EditorTimelineInteractionState: ObservableObject {
    @Published private(set) var generation: UInt64 = 0
    private var interactionID: UUID?
    private var project: RecorderProject?

    func project(for id: UUID?) -> RecorderProject? {
        guard let id, id == interactionID else { return nil }
        return project
    }

    func update(id: UUID, base: RecorderProject, _ mutation: (inout RecorderProject) -> Void) {
        var next = project(for: id) ?? base
        mutation(&next)
        interactionID = id
        project = next
        generation &+= 1
    }

    func clear() {
        guard interactionID != nil else { return }
        interactionID = nil
        project = nil
        generation &+= 1
    }
}
