import AppKit
import Combine
import Foundation
import OSLog
import RecorderCore

let recorderEditorWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.editor-window"
)

/// Only the editor's owner may opt a DogSC window into screen capture. Keeping
/// the rest of the process excluded also covers helper windows opened mid-take.
@MainActor
final class CaptureEditorWindows {
    static let shared = CaptureEditorWindows()

    @Published private(set) var windowIDs: Set<UInt32> = []
    private weak var editorWindow: NSWindow?

    func register(_ window: NSWindow) {
        guard window.identifier == recorderEditorWindowIdentifier else { return }
        editorWindow = window
        let ids = UInt32(exactly: window.windowNumber).flatMap { $0 > 0 ? $0 : nil }
            .map { Set([$0]) } ?? []
        if windowIDs != ids { windowIDs = ids }
    }

    func unregister(_ window: NSWindow) {
        guard editorWindow === window else { return }
        editorWindow = nil
        if !windowIDs.isEmpty { windowIDs = [] }
    }

    func includes(_ windowID: UInt32) -> Bool { windowIDs.contains(windowID) }
}

/// Owns the run-scoped configuration and finite, coalesced refresh requests.
/// Changes never cancel a framework update already in progress; the recorder's
/// gate serializes that update with pause/resume/stop and explicit visibility.
@MainActor
final class CaptureEditorWindowRefresh {
    private let logger = Logger(subsystem: "cn.laogou.dogsc", category: "capture-editor")
    private var runID: RecordingRunID?
    private var configuration: CaptureConfiguration?
    private var appliedConfiguration: CaptureConfiguration?
    private var appliedWindowIDs: Set<UInt32> = []
    private var observation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var refresh: (@MainActor (RecordingRunID) async throws -> Void)?
    private(set) var failureMessage: String?

    func start(
        runID: RecordingRunID,
        configuration: CaptureConfiguration,
        appliedWindowIDs: Set<UInt32>,
        refresh: @escaping @MainActor (RecordingRunID) async throws -> Void
    ) {
        stop()
        self.runID = runID
        self.configuration = configuration
        appliedConfiguration = configuration
        self.appliedWindowIDs = appliedWindowIDs
        self.refresh = refresh
        failureMessage = nil
        guard configuration.source == .display || configuration.source == .area else { return }
        observation = CaptureEditorWindows.shared.$windowIDs
            .removeDuplicates()
            .sink { [weak self] ids in self?.scheduleRefresh(desiredWindowIDs: ids) }
    }

    func updateConfiguration(_ configuration: CaptureConfiguration, for runID: RecordingRunID) {
        guard self.runID == runID else { return }
        self.configuration = configuration
    }

    func configuration(for runID: RecordingRunID) -> CaptureConfiguration? {
        self.runID == runID ? configuration : nil
    }

    func needsUpdate(configuration: CaptureConfiguration, windowIDs: Set<UInt32>) -> Bool {
        appliedConfiguration != configuration || appliedWindowIDs != windowIDs
    }

    func didApply(
        _ windowIDs: Set<UInt32>,
        configuration: CaptureConfiguration,
        for runID: RecordingRunID
    ) {
        guard self.runID == runID else { return }
        appliedWindowIDs = windowIDs
        appliedConfiguration = configuration
        if windowIDs == CaptureEditorWindows.shared.windowIDs { failureMessage = nil }
        scheduleRefresh()
    }

    func stop(for runID: RecordingRunID? = nil) {
        if let runID, self.runID != runID { return }
        observation = nil
        task?.cancel()
        task = nil
        self.runID = nil
        configuration = nil
        appliedConfiguration = nil
        refresh = nil
    }

    private func scheduleRefresh(desiredWindowIDs: Set<UInt32>? = nil) {
        // @Published emits before storage changes; use its emitted set at this
        // boundary so opening the first editor cannot be mistaken for no change.
        guard task == nil, let runID, let refresh,
              (desiredWindowIDs ?? CaptureEditorWindows.shared.windowIDs) != appliedWindowIDs
        else { return }
        task = Task { [weak self] in
            var lastError: (any Error)?
            // WindowServer may publish a just-opened NSWindow before SCK's
            // catalog sees it. Retry that short discovery lag without polling
            // throughout the recording or creating repeated native segments.
            for delay in [100, 250, 500, 1_000, 1_500] {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
                guard let self, self.runID == runID, !Task.isCancelled else { return }
                if self.appliedWindowIDs == CaptureEditorWindows.shared.windowIDs { break }
                do { try await refresh(runID) }
                catch is CancellationError {
                    guard self.runID == runID, !Task.isCancelled else { return }
                } catch { lastError = error }
            }
            guard let self, self.runID == runID, !Task.isCancelled else { return }
            self.task = nil
            if self.appliedWindowIDs != CaptureEditorWindows.shared.windowIDs {
                let detail = lastError.map(appErrorDescription) ?? appLocalized("未取得编辑窗口的录制目录")
                self.failureMessage = String(format: appLocalized("编辑窗口录制过滤更新失败：%@"), detail)
                self.logger.error("\(self.failureMessage ?? detail, privacy: .public)")
            }
        }
    }
}
