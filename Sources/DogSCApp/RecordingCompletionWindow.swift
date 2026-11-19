import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// One card: the take, Save / Edit, and a trash button. Closing keeps the
/// take; deleting happens at once and can be undone for a few seconds. After
/// Save or Delete the card shrinks to a strip that says what happened.
enum RecordingCompletionLayout {
    static let width: CGFloat = 320
    static let stripWidth: CGFloat = 288
    static let inset: CGFloat = 8
    static let radius: CGFloat = 14
    static let saveLinger: TimeInterval = 3
    static let undoWindow: TimeInterval = 5
}

/// What the card shows: the take, or the strip after the user chose.
enum RecordingCompletionState: Equatable {
    case take
    case saved(name: String, folder: String, url: URL)
    case trashed(name: String)
}

@MainActor
final class RecordingCompletionCardModel: ObservableObject {
    @Published var state: RecordingCompletionState = .take
    @Published var thumbnail: CGImage?
}

/// A finished take stays outside the editor until the user chooses its next step.
@MainActor
final class RecordingCompletionWindowController {
    private var panel: RecordingCompletionPanel?
    private var host: NSHostingView<RecordingCompletionCard>?
    private var sessionID: UUID?
    private weak var model: AppModel?
    private let card = RecordingCompletionCardModel()
    private var undoTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    /// A delete waiting out its undo window; the files move only after it.
    private var pendingTrash = false

    func show(model: AppModel, preferredScreen: NSScreen?) {
        guard sessionID != model.editorSessionID || panel == nil else { return }
        dismissNow()
        self.model = model
        card.state = .take
        card.thumbnail = nil
        let visible = (preferredScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(RecordingCompletionLayout.width, visible.width - 40)
        let window = RecordingCompletionPanel(contentRect: .zero,
            styleMask: [.borderless], backing: .buffered, defer: false)
        appLocalizeWindowTitle(window, "录制完成")
        window.identifier = NSUserInterfaceItemIdentifier("dogsc.recording-completion")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.onEscape = { [weak self] in self?.escape() }
        window.onReturn = { [weak self] in self?.edit() }
        window.onUndo = { [weak self] in self?.undoTrash() }
        let view = RecordingCompletionCard(
            model: model, card: card, width: width,
            save: { [weak self] in self?.save() },
            edit: { [weak self] in self?.edit() },
            trash: { [weak self] in self?.trash() },
            undo: { [weak self] in self?.undoTrash() },
            open: { [weak self] in self?.openSaved() },
            layoutChanged: { [weak self] in self?.fit(animated: true) })
        let host = RecordingCompletionHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        self.host = host
        panel = window
        sessionID = model.editorSessionID
        fit(animated: false, anchor: visible)
        FirstUseTourController.controller(for: .recorder).suspend()
        FirstUseTourController.controller(for: .editor).suspend()
        slideIn(window)
    }

    func bringToFront() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The app leaves the completion phase (saved, opened, deleted). A saved
    /// or deleted take keeps its strip up briefly; anything else closes now.
    func close() {
        switch card.state {
        case .saved, .trashed: return
        case .take: dismissNow()
        }
    }

    // MARK: Actions

    private func save() {
        guard let model, card.state == .take else { return }
        Task { @MainActor [weak self] in
            guard await model.saveCompletedRecording(), let self, let url = model.lastSavedRecordingURL else { return }
            self.showStrip(.saved(name: url.deletingPathExtension().lastPathComponent,
                                  folder: url.deletingLastPathComponent().lastPathComponent, url: url),
                           for: RecordingCompletionLayout.saveLinger)
        }
    }

    private func edit() {
        guard let model, card.state == .take else { return }
        model.editCompletedRecording()
    }

    private func escape() {
        switch card.state {
        case .take: save()
        case .trashed: undoTrash()
        case .saved: dismissAnimated()
        }
    }

    /// Takes the card down to the undo strip at once; the package moves to
    /// the Trash only when the undo window ends.
    private func trash() {
        guard let model, card.state == .take, !model.isResolvingCompletedRecording else { return }
        pendingTrash = true
        showStrip(.trashed(name: model.project.title), for: nil)
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RecordingCompletionLayout.undoWindow))
            guard let self, !Task.isCancelled, self.pendingTrash else { return }
            self.pendingTrash = false
            if await model.discardCompletedRecording(resumingLiveInputs: true) {
                self.dismissAnimated()
            } else {
                // Could not move it: the take comes back with the reason.
                self.card.state = .take
                self.fit(animated: true)
            }
        }
    }

    private func undoTrash() {
        guard pendingTrash, case .trashed = card.state else { return }
        pendingTrash = false
        undoTask?.cancel()
        undoTask = nil
        card.state = .take
        fit(animated: true)
    }

    private func openSaved() {
        guard case let .saved(_, _, url) = card.state, let model else { return }
        lingerTask?.cancel()
        dismissAnimated()
        WindowCoordinator.prepareExternalProjectPresentation()
        model.requestOpenProject(at: url)
    }

    private func showStrip(_ state: RecordingCompletionState, for linger: TimeInterval?) {
        card.state = state
        fit(animated: true)
        lingerTask?.cancel()
        guard let linger else { return }
        lingerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(linger))
            guard let self, !Task.isCancelled else { return }
            self.dismissAnimated()
        }
    }

    // MARK: Window

    private func fit(animated: Bool, anchor visibleFrame: NSRect? = nil) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = visibleFrame ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        // The card keeps its bottom-right corner where it is.
        let corner = visibleFrame != nil
            ? NSPoint(x: visible.maxX - 28, y: visible.minY + 28)
            : NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        let proposed = NSRect(x: corner.x - size.width, y: corner.y, width: size.width, height: size.height)
        let frame = RecorderPanelPolicy.frame(centeredOn: proposed, contentSize: size, visibleFrame: visible)
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, !reduces, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    /// Slides in from the screen edge it sits against.
    private func slideIn(_ window: RecordingCompletionPanel) {
        let target = window.frame
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduces else {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.14; window.animator().alphaValue = 1 }
            return
        }
        window.alphaValue = 0
        window.setFrame(target.offsetBy(dx: 36, dy: 0), display: false)
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func dismissAnimated() {
        guard let panel else { return }
        undoTask?.cancel()
        lingerTask?.cancel()
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduces ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduces { panel.animator().setFrame(panel.frame.offsetBy(dx: 24, dy: 0), display: true) }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, self.panel === panel else { return }
                self.dismissNow()
            }
        })
    }

    private func dismissNow() {
        undoTask?.cancel()
        lingerTask?.cancel()
        undoTask = nil
        lingerTask = nil
        pendingTrash = false
        card.state = .take
        panel?.onEscape = nil
        panel?.onReturn = nil
        panel?.onUndo = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        host = nil
        sessionID = nil
        model = nil
    }
}

/// The result is shown without activating the app. Its first click should
/// perform the chosen action, rather than being consumed as activation.
private final class RecordingCompletionHostingView: NSHostingView<RecordingCompletionCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

private final class RecordingCompletionPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    var onUndo: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func performClose(_ sender: Any?) { onEscape?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, event.charactersIgnoringModifiers == "z" { onUndo?(); return true }
        if mods == .command, event.charactersIgnoringModifiers == "w" { onEscape?(); return true }
        if mods.isEmpty, event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

private struct RecordingCompletionCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var card: RecordingCompletionCardModel
    let width: CGFloat
    let save: () -> Void
    let edit: () -> Void
    let trash: () -> Void
    let undo: () -> Void
    let open: () -> Void
    let layoutChanged: () -> Void
    @State private var duration: TimeInterval?
    @State private var dimensions: CGSize?
    @State private var loadingPreview = true

    var body: some View {
        Group {
            switch card.state {
            case .take: take
            case let .saved(name, folder, _):
                strip(title: appLocalized("已保存"), detail: String(format: appLocalized("%@ · %@"), name, folder),
                      dimmed: false, action: appLocalized("打开"), perform: open,
                      seconds: RecordingCompletionLayout.saveLinger)
            case let .trashed(name):
                strip(title: appLocalized("已移到废纸篓"), detail: name, dimmed: true,
                      action: appLocalized("撤销"), perform: undo,
                      seconds: RecordingCompletionLayout.undoWindow)
            }
        }
        .background(RoundedRectangle(cornerRadius: RecordingCompletionLayout.radius, style: .continuous)
            .fill(EditorTheme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: RecordingCompletionLayout.radius, style: .continuous)
            .strokeBorder(EditorTheme.hairline, lineWidth: 1).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: RecordingCompletionLayout.radius, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(EditorTheme.primaryText)
        .appControlFocusAppearance()
        .accessibilityIdentifier("recording.completion.card")
        .task(id: model.recordingURL) { await loadPreview() }
        .onChange(of: model.errorMessage) { _, _ in DispatchQueue.main.async { layoutChanged() } }
    }

    // MARK: The take

    private var take: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EditorTheme.controlWell)
                if let image = card.thumbnail {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity)
                } else if loadingPreview {
                    ProgressView().controlSize(.small)
                } else {
                    AppLineIcon(kind: .film, size: 20).foregroundStyle(EditorTheme.tertiaryText)
                }
            }
            .frame(width: width - RecordingCompletionLayout.inset * 2,
                   height: (width - RecordingCompletionLayout.inset * 2) * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(EditorTheme.hairline, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLocalized("录制画面预览"))
            .animation(.easeOut(duration: 0.2), value: card.thumbnail != nil)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.project.title)
                        .font(.appUI(size: 15, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.appUI(size: 13).monospacedDigit())
                            .foregroundStyle(EditorTheme.tertiaryText)
                    }
                }
                Spacer(minLength: 4)
                Button(action: trash) {
                    AppLineIcon(kind: .trash, size: 15)
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CompletionIconButtonStyle())
                .help(appLocalized("移到废纸篓"))
                .accessibilityLabel(appLocalized("移到废纸篓"))
                .disabled(model.isResolvingCompletedRecording)
            }
            .padding(.horizontal, 6).padding(.top, 12)

            if let error = model.errorMessage, !error.isEmpty {
                ScrollView {
                    Text(error)
                        .font(.appUI(size: 12)).foregroundStyle(EditorTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(height: 56).padding(.horizontal, 6).padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button(action: save) {
                    Text(model.recorderTransitionStage == .savingProject
                        ? model.recorderTransitionStage.title : appLocalized("保存项目"))
                        .lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(CompletionButtonStyle(primary: false))
                .accessibilityIdentifier("recording.completion.save")
                Button(action: edit) {
                    HStack(spacing: 6) {
                        Text(appLocalized("进入编辑"))
                        AppLineIcon(kind: .arrowRight, size: 12)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(CompletionButtonStyle(primary: true))
                .accessibilityIdentifier("recording.completion.edit")
            }
            .disabled(model.isResolvingCompletedRecording)
            .padding(.top, 14)
        }
        .padding(RecordingCompletionLayout.inset)
        .frame(width: width)
    }

    // MARK: The strip after a choice

    private func strip(title: String, detail: String, dimmed: Bool, action: String,
                       perform: @escaping () -> Void, seconds: TimeInterval) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(EditorTheme.controlWell)
                if let image = card.thumbnail {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .frame(width: 52, height: 29)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
            .opacity(dimmed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.appUI(size: 14, weight: .semibold))
                Text(detail).font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(action: perform) { Text(action).padding(.horizontal, 12) }
                .buttonStyle(CompletionButtonStyle(primary: false, height: 30))
                .fixedSize()
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 8)
        .frame(width: RecordingCompletionLayout.stripWidth)
        .overlay(alignment: .bottomLeading) { CompletionCountdown(seconds: seconds) }
        .transition(.opacity)
    }

    private var metadata: String {
        var values: [String] = []
        if let duration, duration.isFinite {
            let seconds = Int(max(duration, 0))
            values.append(String(format: "%02d:%02d", seconds / 60, seconds % 60))
        }
        if let dimensions {
            values.append("\(Int(dimensions.width.rounded())) × \(Int(dimensions.height.rounded()))")
        }
        return values.joined(separator: " · ")
    }

    @MainActor
    private func loadPreview() async {
        card.thumbnail = nil
        duration = nil
        dimensions = nil
        loadingPreview = true
        guard let url = model.recordingURL else { loadingPreview = false; return }
        let asset = AVURLAsset(url: url)
        do {
            let loadedDuration = try await asset.load(.duration).seconds
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                try Task.checkCancellation()
                dimensions = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            duration = loadedDuration
            let frame = try await RecordingCompletionPreviewRequest(asset: asset).load()
            try Task.checkCancellation()
            card.thumbnail = frame
        } catch is CancellationError { return }
        catch { /* A missing thumbnail must never block saving or editing. */ }
        guard !Task.isCancelled else { return }
        loadingPreview = false
        layoutChanged()
    }
}

/// A hairline that drains while the strip waits.
private struct CompletionCountdown: View {
    let seconds: TimeInterval
    @State private var remaining: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            Rectangle().fill(EditorTheme.tertiaryText.opacity(0.5))
                .frame(width: proxy.size.width * remaining, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .onAppear {
            remaining = 1
            withAnimation(.linear(duration: seconds)) { remaining = 0 }
        }
    }
}

/// Editor-sized buttons: 36 high, 8 corners; one filled accent action.
private struct CompletionButtonStyle: ButtonStyle {
    let primary: Bool
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appUI(size: primary || height >= 36 ? 14 : 13, weight: .semibold))
            .foregroundStyle(primary ? Color.white : EditorTheme.primaryText)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(primary ? EditorTheme.accent : EditorTheme.controlWell))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

private struct CompletionIconButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(EditorTheme.controlWell.opacity(hovered || configuration.isPressed ? 1 : 0)))
            .onHover { hovered = $0 }
    }
}

/// One bounded still-frame decode; the generator is isolated to this request.
private final class RecordingCompletionPreviewRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
    }

    func load() async throws -> CGImage {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await generator.image(at: .zero).image
        } onCancel: {
            self.generator.cancelAllCGImageGeneration()
        }
    }
}
