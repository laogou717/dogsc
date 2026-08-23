import Foundation

/// System or editor-shell actions that must not observe a transient gesture
/// preview as if it were persisted project state.
enum EditorExternalAction: Equatable, Sendable {
    case export
    case windowDeactivation
    case windowClosing
    case projectReplacement

    var interactionPolicy: EditorInteractionEndPolicy {
        // Auto-committing before mouse-up would turn an accidental interruption
        // into a persisted edit. The first lifecycle contract is intentionally
        // conservative and can be expanded per action later.
        .cancel
    }
}

enum EditorInteractionEndPolicy: Equatable, Sendable {
    case cancel
}

/// Describes what the store did before allowing an external action to proceed.
/// The first lifecycle pass intentionally cancels drafts instead of committing
/// them: committing a gesture before mouse-up would change existing behavior.
enum EditorExternalActionPreparation: Equatable, Sendable {
    case ready
    case cancelledDraft
}
