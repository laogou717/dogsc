import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// Both completion pages keep the same bottom action geometry while their
/// content crossfades. The shared native window is anchored at that bottom edge.
enum RecordingCompletionLayout {
    static let inset: CGFloat = 8
    static let actionSpacing: CGFloat = 8
    static let actionHeight: CGFloat = 44
}

/// A finished take stays outside the editor until the user chooses its next step.
@MainActor
final class RecordingCompletionWindowController {
    private var panel: RecordingCompletionPanel?
    private var contentHost: RecordingCompletionHostingView?
    private var entranceSurface: RecordingCompletionSurfaceView?
    private var sessionID: UUID?
    private var entranceID: UUID?
    private let pageTransition = RecordingCompletionTransition()
    private var decision: AppDialog?
    private var decisionHost: RecordingDecisionHostingView?
    private var decisionReply: (@MainActor (AppDialog.Response) -> Void)?
    private weak var model: AppModel?

    func show(model: AppModel, preferredScreen: NSScreen?) {
        guard sessionID != model.editorSessionID || panel == nil else { return }
        close()
        self.model = model
        let visible = (preferredScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(336, visible.width - 40)
        // Reserve room for shadow margins and an inline failure notice too.
        let previewHeight = min((width - 16) * 9 / 16, max(48, visible.height - 350))
        let window = RecordingCompletionPanel(contentRect: .zero,
            styleMask: [.borderless], backing: .buffered, defer: false)
        appLocalizeWindowTitle(window, "录制完成")
        window.identifier = NSUserInterfaceItemIdentifier("dogsc.recording-completion")
        window.isOpaque = false
        window.backgroundColor = .clear
        // Shadow follows the single native contour outside its hit bounds.
        window.hasShadow = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.completionController = self
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // Part of the recording workflow, so it shares the recorder's glass.
        window.appearance = nil
        window.onCloseRequest = { [weak self, weak model, weak window] in
            guard let self, let model else { return }
            if self.decision != nil {
                self.cancelDecision()
                return
            }
            // An explicit close may open a modal decision; automatic arrival
            // below never activates the application or steals typing focus.
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.requestCloseCompletedRecording(relativeTo: window) }
        }
        window.onDecisionReturn = { [weak self] in self?.chooseDefaultDecision() }
        let card = RecordingCompletionCard(model: model, width: width,
            previewHeight: previewHeight, close: { [weak window] in window?.onCloseRequest?() },
            layoutChanged: { [weak self] in self?.resizeToFit(visible: visible) })
        let host = RecordingCompletionHostingView(rootView: card)
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        host.frame.size = host.fittingSize
        let motionSurface = RecordingCompletionSurfaceView(resultView: host)
        // AppKit owns the contentView's backing layer. Animate a child so
        // ordering the window cannot reset the entrance transform.
        let root = NSView()
        root.wantsLayer = true
        motionSurface.autoresizingMask = [.width, .height]
        root.addSubview(motionSurface)
        window.contentView = root
        contentHost = host
        entranceSurface = motionSurface
        panel = window
        sessionID = model.editorSessionID
        resizeToFit(visible: visible, anchorsToCorner: true)
        FirstUseTourController.controller(for: .recorder).suspend()
        FirstUseTourController.controller(for: .editor).suspend()
        presentFromScreenEdge(window)
    }

    /// Keep the native window on its destination display. Translating its
    /// clipped contents gives a real edge entrance without briefly showing the
    /// card on the neighbouring monitor or letting AppKit clamp an offscreen
    /// window back into place.
    private func presentFromScreenEdge(_ window: RecordingCompletionPanel) {
        guard let layer = entranceSurface?.layer else {
            window.orderFrontRegardless()
            return
        }
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let travel = window.frame.width + 28
        // Resolve both hosting views while hidden, before the first visible
        // commit. Never order a resting card and attach its motion next turn.
        window.contentView?.layoutSubtreeIfNeeded()
        entranceSurface?.layoutCards()
        window.contentView?.displayIfNeeded()
        let id = UUID()
        entranceID = id
        let motion = CABasicAnimation(keyPath: reducesMotion ? "opacity" : "transform.translation.x")
        motion.fromValue = reducesMotion ? 0 : travel
        motion.toValue = reducesMotion ? 1 : 0
        motion.duration = reducesMotion ? 0.14 : 0.38
        motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1)
        // The visible layer moves while AppKit's hit rectangles stay at the
        // destination. Keep work clicks passing through until it settles.
        window.ignoresMouseEvents = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, self.panel === window,
                      self.entranceID == id else { return }
                self.entranceID = nil
                window.ignoresMouseEvents = false
                window.invalidateShadow()
            }
        }
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.add(motion, forKey: "recording-completion-entrance")
        window.orderFrontRegardless()
        CATransaction.commit()
    }

    func bringToFront() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        pageTransition.stop()
        decisionReply = nil
        decision = nil
        decisionHost = nil
        panel?.completionController = nil
        panel?.onDecisionReturn = nil
        entranceID = nil
        entranceSurface?.layer?.removeAllAnimations()
        panel?.onCloseRequest = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        contentHost = nil
        entranceSurface = nil
        panel?.close()
        panel = nil
        sessionID = nil
        model = nil
    }

    private func resizeToFit(visible: NSRect, anchorsToCorner: Bool = false) {
        guard let panel, let contentHost, let entranceSurface else { return }
        contentHost.layoutSubtreeIfNeeded()
        let size = contentHost.fittingSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentHost.setFrameSize(size)
        if decision == nil {
            let currentScreen = panel.screen?.visibleFrame ?? visible
            let anchor = anchorsToCorner ? visible.insetBy(dx: 28, dy: 28) : panel.frame
            let proposed = NSRect(x: anchor.maxX - size.width, y: anchor.minY,
                                  width: size.width, height: size.height)
            panel.setFrame(RecorderPanelPolicy.frame(centeredOn: proposed, contentSize: size,
                                                     visibleFrame: currentScreen), display: false)
        }
        entranceSurface.layoutCards()
        CATransaction.commit()
        panel.invalidateShadow()
    }

    fileprivate func presentDecision(_ dialog: AppDialog,
                                     respond: @escaping @MainActor (AppDialog.Response) -> Void) -> Bool {
        guard let panel, let contentHost, let entranceSurface, decision == nil else { return false }
        // Explicit interaction can finish an automatic edge entrance, but
        // never lets its delayed callback reset a later transition's state.
        entranceID = nil
        entranceSurface.layer?.removeAllAnimations()
        entranceSurface.layer?.transform = CATransform3DIdentity
        entranceSurface.layer?.opacity = 1
        panel.ignoresMouseEvents = false
        panel.blocksPointerActions = true
        decision = dialog
        decisionReply = respond
        let host = RecordingDecisionHostingView(rootView: AppDialogCard(
            dialog: dialog, input: AppDialogInput(dialog.input ?? ""), width: panel.frame.width,
            drawsSurface: false, respond: { [weak self] response in self?.chooseDecision(response) }))
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        host.isHidden = true
        host.alphaValue = 0
        host.frame.size = host.fittingSize
        decisionHost = host
        entranceSurface.setDecisionView(host)
        pageTransition.start(window: panel, surface: entranceSurface, from: contentHost, to: host,
                             targetFrame: frame(for: host.fittingSize)) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.contentHost?.isHidden = true
            panel.blocksPointerActions = false
            panel.makeFirstResponder(nil)
        }
        return true
    }

    fileprivate func cancelDecision() {
        guard let decision else { return }
        chooseDecision(.init(actionID: decision.cancelActionID))
    }

    private func chooseDefaultDecision() {
        guard let decision, let action = decision.actions.first(where: { $0.id == decision.defaultActionID }),
              decision.isEnabled(action, input: "") else { return }
        chooseDecision(.init(actionID: action.id))
    }

    private func chooseDecision(_ response: AppDialog.Response) {
        guard let decision, let reply = decisionReply, panel?.blocksPointerActions == false else { return }
        decisionReply = nil
        if response.actionID == nil || response.actionID == decision.cancelActionID {
            returnToResult { reply(response) }
        } else {
            // Keep the same decision card while save/trash crosses its I/O
            // barrier. The model's defer returns here on failure; success
            // closes the completion window through the normal phase change.
            panel?.blocksPointerActions = true
            reply(response)
        }
    }

    fileprivate func finishDecision() {
        guard model?.phase == .recordingComplete, decision != nil, decisionReply == nil else { return }
        returnToResult()
    }

    private func returnToResult(completion: @escaping () -> Void = {}) {
        guard let panel, let contentHost, let entranceSurface, let decisionHost else {
            completion()
            return
        }
        panel.blocksPointerActions = true
        contentHost.alphaValue = 0
        contentHost.isHidden = false
        contentHost.layoutSubtreeIfNeeded()
        contentHost.setFrameSize(contentHost.fittingSize)
        pageTransition.start(window: panel, surface: entranceSurface, from: decisionHost, to: contentHost,
                             targetFrame: frame(for: contentHost.fittingSize)) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { completion(); return }
            self.entranceSurface?.setDecisionView(nil)
            self.decisionHost = nil
            self.decision = nil
            panel.blocksPointerActions = false
            panel.makeFirstResponder(nil)
            completion()
        }
    }

    private func frame(for size: NSSize) -> NSRect {
        guard let panel else { return .zero }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let proposed = NSRect(x: panel.frame.maxX - size.width, y: panel.frame.minY,
                              width: size.width, height: size.height)
        return RecorderPanelPolicy.frame(centeredOn: proposed, contentSize: size, visibleFrame: visible)
    }

}

/// The result is shown without activating the app. Its first click should
/// perform the chosen action, rather than being consumed as activation.
private final class RecordingCompletionHostingView: NSHostingView<RecordingCompletionCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

private final class RecordingDecisionHostingView: NSHostingView<AppDialogCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

private final class RecordingCompletionPanel: NSPanel, RecordingDecisionHosting {
    var onCloseRequest: (() -> Void)?
    var onDecisionReturn: (() -> Void)?
    weak var completionController: RecordingCompletionWindowController?
    var blocksPointerActions = false

    func presentRecordingDecision(_ dialog: AppDialog,
                                  respond: @escaping @MainActor (AppDialog.Response) -> Void) -> Bool {
        completionController?.presentDecision(dialog, respond: respond) ?? false
    }
    func cancelRecordingDecision() { completionController?.cancelDecision() }
    func finishRecordingDecision() { completionController?.finishDecision() }

    override func sendEvent(_ event: NSEvent) {
        if blocksPointerActions && [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(event.type) { return }
        if event.type == .leftMouseDown {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCloseRequest?() }
    override func performClose(_ sender: Any?) { onCloseRequest?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if blocksPointerActions { return true }
        if (event.keyCode == 36 || event.keyCode == 76), NSApp.modalWindow === self {
            onDecisionReturn?()
            return true
        }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCloseRequest?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCloseRequest?() }
        else if (event.keyCode == 36 || event.keyCode == 76), NSApp.modalWindow === self {
            onDecisionReturn?()
        } else { super.keyDown(with: event) }
    }
}

private struct RecordingCompletionCard: View {
    @ObservedObject var model: AppModel
    let width: CGFloat
    let previewHeight: CGFloat
    let close: () -> Void
    let layoutChanged: () -> Void
    @State private var image: CGImage?
    @State private var duration: TimeInterval?
    @State private var dimensions: CGSize?
    @State private var loadingPreview = true

    @State private var arrived = false

    /// The take itself is the card: its first frame, what it is called, and
    /// the two things that can be done with it.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(RecorderStyle.silver)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                } else if loadingPreview {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "film").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(RecorderStyle.faint)
                        .accessibilityLabel("预览暂不可用")
                }
            }
            .frame(height: previewHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("录制画面预览")
            .overlay(alignment: .bottomLeading) {
                if !metadata.isEmpty {
                    Text(metadata).font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(RecorderStyle.mediaInk)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RecorderStyle.mediaOverlay, in: Capsule())
                        .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(RecorderStyle.mediaInk)
                        .frame(width: 26, height: 26)
                        .background(RecorderStyle.mediaOverlay, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 13))
                .help("关闭录制结果")
                .accessibilityLabel("关闭录制结果")
                .disabled(model.isResolvingCompletedRecording)
                .padding(10)
            }
            .animation(RecorderMotion.settle, value: image != nil)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RecorderStyle.mint)
                    .scaleEffect(arrived || RecorderMotion.reduces ? 1 : 0.3)
                    .opacity(arrived ? 1 : 0)
                    .accessibilityLabel("录制完成")
                Text(model.project.title).font(.appUI(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.currentSession?.packageURL.deletingLastPathComponent().path ?? "")
            }
            .padding(.horizontal, 10).padding(.top, 14)

            if let error = model.errorMessage, !error.isEmpty {
                ScrollView {
                    Text(error)
                        .font(.appUI(size: 12)).foregroundStyle(RecorderStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(height: 56).padding(.horizontal, 10).padding(.top, 8)
            }

            HStack(spacing: RecordingCompletionLayout.actionSpacing) {
                Button {
                    Task { await model.saveCompletedRecording() }
                } label: {
                    Text(model.isResolvingCompletedRecording
                        ? model.recorderTransitionStage.title : appLocalized("保存项目"))
                        .lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(RecorderPillButtonStyle(kind: .soft))
                .accessibilityIdentifier("recording.completion.save")
                Button { model.editCompletedRecording() } label: {
                    HStack(spacing: 6) {
                        Text("进入编辑")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(RecorderPillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("recording.completion.edit")
            }
            .frame(height: RecordingCompletionLayout.actionHeight)
            .disabled(model.isResolvingCompletedRecording)
            .padding(.top, 14)
        }
        .foregroundStyle(RecorderStyle.ink)
        .padding(RecordingCompletionLayout.inset).frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            withAnimation(RecorderMotion.reduces ? nil : .spring(response: 0.42, dampingFraction: 0.6).delay(0.25)) { arrived = true }
        }
        .appControlFocusAppearance()
        .accessibilityIdentifier("recording.completion.card")
        .task(id: model.recordingURL) { await loadPreview() }
        .onChange(of: model.errorMessage) { _, _ in
            DispatchQueue.main.async { layoutChanged() }
        }
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
        return values.isEmpty ? appLocalized("屏幕录制") : values.joined(separator: " · ")
    }

    @MainActor
    private func loadPreview() async {
        image = nil
        duration = nil
        dimensions = nil
        loadingPreview = true
        guard let url = model.recordingURL else { loadingPreview = false; return }
        let asset = AVURLAsset(url: url)
        do {
            let loadedDuration = try await asset.load(.duration).seconds
            let track = try await asset.loadTracks(withMediaType: .video).first
            if let track {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                try Task.checkCancellation()
                dimensions = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            duration = loadedDuration
            let request = RecordingCompletionPreviewRequest(asset: asset)
            let frame = try await request.load()
            try Task.checkCancellation()
            image = frame
        } catch is CancellationError { return }
        catch { /* A missing thumbnail must never block saving or editing. */ }
        guard !Task.isCancelled else { return }
        loadingPreview = false
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
