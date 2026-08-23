import Foundation

/// Large recording packages must never be moved or recursively removed on
/// MainActor. These operations can block on APFS metadata, external volumes or
/// Finder's Trash bookkeeping even when the apparent action is just a rename.
enum ProjectPackageDisposal {
    nonisolated static func moveToTrash(_ url: URL) async throws {
        try await perform(priority: .userInitiated) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    nonisolated static func removeIfPresent(_ url: URL) async {
        try? await perform(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Runs file-system work outside MainActor and preserves cancellation.
    nonisolated static func perform(
        priority: TaskPriority,
        operation: @escaping @Sendable () throws -> Void
    ) async throws {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            try operation()
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
