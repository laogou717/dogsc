import RecorderCore

/// The three editor surfaces that change while a crop draft is active.
/// Keeping these as distinct values makes presentation drift testable while
/// resolving all of them atomically from the same `EditorStore.interaction`.
enum EditorCropToolbarMode: Equatable, Sendable {
    case standardControls
    case cropControls
}

enum EditorCropInspectorMode: Equatable, Sendable {
    case selectedInspector
    case cropInspector
}

enum EditorCropCanvasMode: Equatable, Sendable {
    case composition
    case cropEditor
}

enum EditorCropToolbarAction: CaseIterable, Equatable, Sendable {
    case changeCanvasAspectRatio
    case beginCrop
    case openScreenAppearance
    case resetCrop
    case cancelCrop
    case confirmCrop
}

/// Pure presentation adapter for crop mode. It owns no independent Boolean or
/// draft: `EditorInteractionDraft` remains the only source of truth.
struct EditorCropPresentation: Equatable, Sendable {
    let toolbarMode: EditorCropToolbarMode
    let inspectorMode: EditorCropInspectorMode
    let canvasMode: EditorCropCanvasMode
    let draft: NormalizedCrop?

    init(interaction: EditorInteractionDraft?) {
        guard interaction?.tool == .crop,
              interaction?.selection == .crop,
              let interaction
        else {
            toolbarMode = .standardControls
            inspectorMode = .selectedInspector
            canvasMode = .composition
            draft = nil
            return
        }

        toolbarMode = .cropControls
        inspectorMode = .cropInspector
        canvasMode = .cropEditor
        draft = interaction.previewProject.canvas.crop.clamped()
    }

    var isActive: Bool {
        toolbarMode == .cropControls
    }

    /// A synchronous gate used both by visible controls and their actions. It
    /// prevents a queued standard action from mutating state after crop mode
    /// has already begun, without introducing focus state, debounce, or delay.
    func permits(_ action: EditorCropToolbarAction) -> Bool {
        switch toolbarMode {
        case .standardControls:
            switch action {
            case .changeCanvasAspectRatio, .beginCrop, .openScreenAppearance:
                return true
            case .resetCrop, .cancelCrop, .confirmCrop:
                return false
            }
        case .cropControls:
            switch action {
            case .resetCrop, .cancelCrop, .confirmCrop:
                return true
            case .changeCanvasAspectRatio, .beginCrop, .openScreenAppearance:
                return false
            }
        }
    }
}

extension EditorStore {
    var cropPresentation: EditorCropPresentation {
        EditorCropPresentation(interaction: interaction)
    }
}
