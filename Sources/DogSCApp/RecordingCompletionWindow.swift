import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// A finished take stays outside the editor until the user chooses its next step.
@MainActor
final class RecordingCompletionWindowController {
    private var panel: RecordingCompletionPanel?
    private var contentHost: RecordingCompletionHostingView?
    private var entranceSurface: NSView?
    private var sessionID: UUID?
    private var entranceTask: Task<Void, Never>?

    func show(model: AppModel, preferredScreen: NSScreen?) {
        guard sessionID != model.editorSessionID || panel == nil else { return }
        close()
        let visible = (preferredScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(380, visible.width - 40)
        // Reserve room for shadow margins and an inline failure notice too.
        let previewHeight = min((width - 44) * 9 / 16, max(48, visible.height - 350))
        let window = RecordingCompletionPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = appLocalized("录制完成")
        window.identifier = NSUserInterfaceItemIdentifier("dogsc.recording-completion")
        window.isOpaque = false
        window.backgroundColor = .clear
        // The card owns its shadow inside the clipped entrance surface.
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.appearance = AppPreferences.appearancePreference.appKitAppearance
        window.onCloseRequest = { [weak model, weak window] in
            guard let model else { return }
            // An explicit close may open a modal decision; automatic arrival
            // below never activates the application or steals typing focus.
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.requestCloseCompletedRecording(relativeTo: window) }
        }
        let card = RecordingCompletionCard(model: model, width: width,
            previewHeight: previewHeight, close: { [weak window] in window?.onCloseRequest?() },
            layoutChanged: { [weak self] in self?.resizeToFit(visible: visible) })
        let host = RecordingCompletionHostingView(rootView: card)
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.backgroundColor = NSColor.clear.cgColor
        clip.layer?.masksToBounds = true
        let motionSurface = NSView()
        motionSurface.wantsLayer = true
        motionSurface.layer?.backgroundColor = NSColor.clear.cgColor
        clip.addSubview(motionSurface)
        motionSurface.addSubview(host)
        motionSurface.autoresizingMask = [.width, .height]
        host.autoresizingMask = [.width, .height]
        window.contentView = clip
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
        let travel = window.frame.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reducesMotion {
            layer.opacity = 0
        } else {
            layer.transform = CATransform3DMakeTranslation(travel, 0, 0)
        }
        CATransaction.commit()
        // The visible layer moves while AppKit's hit rectangles stay at the
        // destination. Keep work clicks passing through until it settles.
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        entranceTask = Task { @MainActor [weak self, weak window, weak layer] in
            await Task.yield()
            guard let self, let window, let layer, !Task.isCancelled,
                  self.panel === window, window.isVisible else { return }
            let motion = CABasicAnimation(keyPath: reducesMotion ? "opacity" : "transform.translation.x")
            motion.fromValue = reducesMotion ? 0 : travel
            motion.toValue = reducesMotion ? 1 : 0
            motion.duration = reducesMotion ? 0.14 : 0.38
            motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self, weak window] in
                Task { @MainActor in
                    guard let self, let window, self.panel === window else { return }
                    window.ignoresMouseEvents = false
                }
            }
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            layer.add(motion, forKey: "recording-completion-entrance")
            CATransaction.commit()
            self.entranceTask = nil
        }
    }

    func bringToFront() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        entranceTask?.cancel()
        entranceTask = nil
        entranceSurface?.layer?.removeAllAnimations()
        panel?.onCloseRequest = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        contentHost = nil
        entranceSurface = nil
        panel?.close()
        panel = nil
        sessionID = nil
    }

    private func resizeToFit(visible: NSRect, anchorsToCorner: Bool = false) {
        guard let panel, let contentHost, let entranceSurface,
              let container = panel.contentView else { return }
        contentHost.layoutSubtreeIfNeeded()
        let size = contentHost.fittingSize
        let currentScreen = panel.screen?.visibleFrame ?? visible
        let anchor = anchorsToCorner ? visible : panel.frame
        let proposed = NSRect(x: anchor.maxX - size.width, y: anchor.minY,
                              width: size.width, height: size.height)
        let frame = RecorderPanelPolicy.frame(
            centeredOn: proposed, contentSize: size,
            visibleFrame: anchorsToCorner ? visible : currentScreen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        container.frame = NSRect(origin: .zero, size: size)
        entranceSurface.frame = container.bounds
        contentHost.frame = entranceSurface.bounds
        CATransaction.commit()
    }
}

/// The result is shown without activating the app. Its first click should
/// perform the chosen action, rather than being consumed as activation.
private final class RecordingCompletionHostingView: NSHostingView<RecordingCompletionCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class RecordingCompletionPanel: NSPanel {
    var onCloseRequest: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCloseRequest?() }
    override func performClose(_ sender: Any?) { onCloseRequest?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCloseRequest?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCloseRequest?() }
        else { super.keyDown(with: event) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.appUI(size: 22, weight: .medium))
                    .foregroundStyle(EditorTheme.platinumAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.green.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text("录制完成").font(.appUI(size: 20, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.editorDismissIcon)
                    .help("关闭录制结果")
                    .accessibilityLabel("关闭录制结果")
                    .disabled(model.isResolvingCompletedRecording)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(EditorTheme.panelRaised)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .padding(1)
                } else if loadingPreview {
                    ProgressView().controlSize(.small)
                } else {
                    Label("预览暂不可用", systemImage: "film")
                        .font(.appUI(size: 13)).foregroundStyle(EditorTheme.platinumMuted)
                }
            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(EditorTheme.chrome(0.06), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("录制画面预览")

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.project.title).font(.appUI(size: 15, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(metadata).font(.appUI(size: 12)).monospacedDigit()
                        .foregroundStyle(EditorTheme.platinumMuted)
                }
                Spacer(minLength: 0)
                Label(model.currentSession?.packageURL.deletingLastPathComponent().lastPathComponent
                    ?? appLocalized("项目"), systemImage: "folder")
                    .font(.appUI(size: 12)).foregroundStyle(EditorTheme.platinumMuted)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
                    .help(model.currentSession?.packageURL.deletingLastPathComponent().path ?? "")
            }
            .frame(minHeight: 40)

            if let error = model.errorMessage, !error.isEmpty {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.appUI(size: 12)).foregroundStyle(EditorTheme.platinumMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }.frame(height: 62)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await model.saveCompletedRecording() }
                } label: {
                    Label(model.isResolvingCompletedRecording
                        ? model.recorderTransitionStage.title : appLocalized("保存项目"), systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RecordingCompletionActionStyle(primary: false))
                .accessibilityIdentifier("recording.completion.save")
                Button { model.editCompletedRecording() } label: {
                    Label("进入编辑", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RecordingCompletionActionStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("recording.completion.edit")
            }
            .disabled(model.isResolvingCompletedRecording)
        }
        .foregroundStyle(EditorTheme.platinumAccent)
        .padding(22).frame(width: width)
        .background(EditorTheme.panelSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(EditorTheme.chrome(0.08), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 5)
        .padding(20)
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

private struct RecordingCompletionActionStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appUI(size: 14, weight: .medium))
            .foregroundStyle(primary ? EditorTheme.onAccent : EditorTheme.platinumAccent)
            .frame(height: 42)
            .background(primary ? EditorTheme.platinumAccent : EditorTheme.cardElevated,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(EditorTheme.chrome(primary ? 0 : 0.10), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill((primary ? EditorTheme.onAccent : EditorTheme.chrome())
                        .opacity(isEnabled ? (configuration.isPressed ? 0.12 : hovered ? 0.06 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onHover { hovered = $0 }
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 11, style: .continuous),
                color: primary ? EditorTheme.onAccent.opacity(0.65) : EditorTheme.platinumAccent.opacity(0.45))
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
