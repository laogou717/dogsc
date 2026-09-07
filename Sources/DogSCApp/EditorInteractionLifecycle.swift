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
        // into a persisted edit. The store first resolves controls with an
        // explicit autosave policy; this fallback applies to transient drags.
        .cancel
    }
}

enum EditorInteractionEndPolicy: Equatable, Sendable {
    case cancel
}

/// Describes what the store did before allowing an external action to proceed.
/// Autosaving inputs and transient gesture drafts have distinct outcomes.
enum EditorExternalActionPreparation: Equatable, Sendable {
    case ready
    case committedDraft
    case cancelledDraft
}
