import Foundation

/// Immutable filesystem snapshot for recorder/Dock/status-menu presentation.
/// Directory enumeration and recovery-manifest reads can touch slow external
/// volumes, so callers load this away from MainActor and publish it atomically.
struct ProjectCatalogSnapshot: Equatable, Sendable {
    let recent: [URL]
    let recoverable: [URL]

    nonisolated static func load() -> ProjectCatalogSnapshot {
        let recentCandidates = ProjectStore.recentProjectURLs(limit: 50)
        return ProjectCatalogSnapshot(
            recent: Array(recentCandidates.prefix(8)),
            recoverable: ProjectStore.recoverableProjectURLs(
                recentCandidates: recentCandidates
            )
        )
    }
}
