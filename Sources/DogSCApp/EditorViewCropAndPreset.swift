import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorView {
    func canvasBinding<Value>(
        _ keyPath: WritableKeyPath<CanvasStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { editorStore.project.canvas[keyPath: keyPath] },
            set: { value in
                var style = editorStore.project.canvas
                style[keyPath: keyPath] = value
                performEditorCommand { try editorStore.replaceCanvas(with: style, actionName: actionName) }
            }
        )
    }

    func performEditorCommand(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    func beginCrop() {
        guard cropPresentation.permits(.beginCrop) else { return }
        playbackController.endHoverPreview()
        playbackController.pause()
        // 裁切期间检查器由裁切面板接管，完成/取消后选择回到屏幕初始状态，
        // 都落在合并后的"画面"页，无需在此预设页签。
        editorStore.beginInteraction(tool: .crop, selection: .crop)
    }

    func confirmCrop() {
        guard cropPresentation.permits(.confirmCrop) else { return }
        do {
            _ = try editorStore.commitInteraction(actionName: "裁切屏幕")
        } catch {
            editorStore.cancelInteraction()
            hostActions.reportError(error.localizedDescription)
        }
        editorStore.selection = .screen
    }

    func discardCrop() {
        guard cropPresentation.permits(.cancelCrop) else { return }
        editorStore.cancelInteraction()
        editorStore.selection = .screen
    }

    func resetCrop() {
        guard cropPresentation.permits(.resetCrop) else { return }
        cropDraftBinding.wrappedValue = .full
    }

    var cropDraft: NormalizedCrop {
        cropPresentation.draft ?? editorStore.project.canvas.crop.clamped()
    }

    var cropDraftBinding: Binding<NormalizedCrop> {
        Binding(
            get: { editorStore.previewProject.canvas.crop.clamped() },
            set: { crop in
                guard cropPresentation.isActive else { return }
                editorStore.updateInteraction { project in
                    project.canvas.crop = crop.clamped()
                }
            }
        )
    }

    func resolveExternalAction(_ action: EditorExternalAction) {
        let wasCropping = isCropping
        _ = editorStore.prepareForExternalAction(action)
        guard wasCropping else { return }
        if editorStore.selection == .crop {
            editorStore.selection = .screen
        }
    }

}
