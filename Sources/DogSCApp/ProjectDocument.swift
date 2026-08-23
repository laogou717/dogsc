import Combine
import RecorderCore

/// The single mutable owner of the project currently open in the application.
///
/// ProjectWorkspace owns the document lifetime. EditorStore owns editor commands and
/// transient gestures, but it never keeps a second persisted project snapshot.
@MainActor
final class ProjectDocument: ObservableObject {
    @Published private(set) var project: RecorderProject

    init(project: RecorderProject) {
        self.project = project
    }

    /// Publishes one immutable project snapshot. Returning `false` lets command
    /// callers distinguish a real commit from a no-op without a second diff.
    @discardableResult
    func replace(with replacement: RecorderProject) -> Bool {
        guard replacement != project else { return false }
        project = replacement
        return true
    }
}
