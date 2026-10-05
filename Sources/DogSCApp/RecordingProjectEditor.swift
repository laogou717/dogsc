import Combine
import Foundation

/// Owns the one saved-project workspace that can coexist with a live take.
/// The recorder retains its own document, run and device leases; the existing
/// single editor window presents this model without starting any live inputs.
@MainActor
final class RecordingProjectEditor {
    private(set) var model: AppModel?
    var onPresentationChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var phaseObservation: AnyCancellable?
    private var isCrossingSaveBarrier = false

    var presentedModel: AppModel? {
        guard model?.phase == .editor else { return nil }
        return model
    }

    func openProject(at url: URL) {
        guard !isCrossingSaveBarrier else { return }
        if let model {
            guard model.phase == .editor,
                  !model.exporter.isExporting,
                  !model.isMediaExchangeRunning else {
                onFailure?("请先完成当前项目的打开、保存或导出操作。")
                return
            }
            model.requestOpenProject(at: url)
            return
        }

        let editor = AppModel(workspace: ProjectWorkspace(), purpose: .editing)
        model = editor
        phaseObservation = editor.$phase
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak editor] _ in
                guard let self, let editor, self.model === editor else { return }
                if editor.phase == .setup {
                    if let message = editor.errorMessage { self.onFailure?(message) }
                    self.releaseModel()
                }
                self.onPresentationChange?()
            }
        editor.requestOpenProject(at: url)
    }

    /// Explicitly editing the newly completed take replaces the old editor
    /// only after its final snapshot is durable. Failure keeps both projects.
    func closeForReplacement() async -> Bool {
        guard let editor = model else { return true }
        guard canCrossSaveBarrier(editor) else { return false }
        isCrossingSaveBarrier = true
        defer { isCrossingSaveBarrier = false }
        let snapshot = editor.project
        editor.recorderTransitionStage = .savingProject
        editor.phase = .finishing
        do {
            guard try await editor.workspace.flushAndInvalidate(snapshot) != nil else {
                throw CocoaError(.fileWriteUnknown)
            }
            editor.closeProject(resumingLiveInputs: false)
            releaseModel()
            onPresentationChange?()
            return true
        } catch {
            restoreEditor(editor, error: error)
            return false
        }
    }

    /// Quit may still be cancelled by the pending take's completion decision.
    /// Flush without detaching this workspace so cancellation restores it.
    func flushForTermination() async -> Bool {
        guard let editor = model else { return true }
        guard canCrossSaveBarrier(editor) else { return false }
        isCrossingSaveBarrier = true
        defer { isCrossingSaveBarrier = false }
        let snapshot = editor.project
        editor.recorderTransitionStage = .savingProject
        editor.phase = .finishing
        do {
            guard try await editor.workspace.flush(snapshot) != nil else {
                throw CocoaError(.fileWriteUnknown)
            }
            editor.recorderTransitionStage = .idle
            editor.phase = .editor
            return true
        } catch {
            restoreEditor(editor, error: error)
            return false
        }
    }

    func shutdown() {
        releaseModel()
        onPresentationChange = nil
        onFailure = nil
    }

    private func canCrossSaveBarrier(_ editor: AppModel) -> Bool {
        guard !isCrossingSaveBarrier,
              editor.phase == .editor,
              editor.currentSession != nil,
              !editor.exporter.isExporting,
              !editor.isMediaExchangeRunning else {
            onFailure?("请先完成当前项目的打开、保存或导出操作。")
            return false
        }
        return true
    }

    private func restoreEditor(_ editor: AppModel, error: Error) {
        let message = String(format: appLocalized("保存项目失败：%@"), error.localizedDescription)
        editor.errorMessage = message
        editor.recorderTransitionStage = .idle
        editor.phase = .editor
        onFailure?(message)
    }

    private func releaseModel() {
        phaseObservation = nil
        model?.shutdownForApplicationTermination()
        model = nil
    }
}
