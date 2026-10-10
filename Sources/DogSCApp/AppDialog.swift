import AppKit
import SwiftUI

/// App-owned decisions and notices. File pickers and macOS permission prompts
/// retain their system UI; they are not application confirmation dialogs.
struct AppDialog {
    enum Layout {
        case standard, recordingDecision, projectDecision
        var isCompactDecision: Bool { self != .standard }
    }
    struct Action: Identifiable {
        enum Role { case cancel, secondary, primary, destructive }
        let id: String
        let title: String
        var role: Role = .secondary
        var requiresInput = false
        var handler: @MainActor (String) -> Void = { _ in }
    }

    struct Response {
        var actionID: String?
        var input = ""
    }

    let title: String
    let message: String
    var symbol = "info.circle"
    var showsAppIcon = false
    var itemTitle: String? = nil
    var input: String? = nil
    var inputPlaceholder = "预设名称"
    var layout: Layout = .standard
    let actions: [Action]

    var cancelActionID: String? {
        actions.first(where: { $0.role == .cancel })?.id
            ?? (actions.count == 1 && actions[0].role != .destructive ? actions[0].id : nil)
    }

    // Return never silently selects a destructive action.
    var defaultActionID: String? {
        actions.first(where: { $0.role == .primary })?.id ?? cancelActionID
    }

    func isEnabled(_ action: Action, input: String) -> Bool {
        !action.requiresInput || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Completion decisions use the existing card/window, while keeping the
/// same application-modal decision boundary as other project operations.
@MainActor
protocol RecordingDecisionHosting: AnyObject {
    func presentRecordingDecision(_ dialog: AppDialog,
                                  respond: @escaping @MainActor (AppDialog.Response) -> Void) -> Bool
    func cancelRecordingDecision()
    func finishRecordingDecision()
}

@MainActor
final class AppDialogInput: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

/// A compact, left-aligned card shared by project decisions, recorder notices
/// and preset naming. One contour owns its fill, clipping and border.
/// A decision, stated plainly: what is being asked, what it applies to, and
/// the answers. No pictogram tile, no boxed-in details; the answers are pills,
/// stacked when there are more than two so the important one leads.
struct AppDialogCard: View {
    let dialog: AppDialog
    @ObservedObject var input: AppDialogInput
    var width: CGFloat = 360
    var drawsSurface = true
    let respond: (AppDialog.Response) -> Void
    @FocusState private var inputFocused: Bool
    @State private var dismissHovered = false
    private var isCompactDecision: Bool { dialog.layout.isCompactDecision }
    private var isRecordingDecision: Bool { dialog.layout == .recordingDecision }
    private var contentInset: CGFloat { isCompactDecision ? 20 : 22 }
    private var actionInset: CGFloat { isRecordingDecision ? RecordingCompletionLayout.inset : contentInset }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            information
                .padding(.horizontal, contentInset)
                .padding(.top, contentInset)
            actions
                .padding(.top, isCompactDecision ? 18 : 22)
                .padding(.horizontal, actionInset)
                .padding(.bottom, actionInset)
        }
        .frame(width: width, alignment: .leading)
        .background {
            if drawsSurface {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(isRecordingDecision ? RecorderStyle.base : EditorTheme.panelSurface)
            }
        }
        .overlay {
            if drawsSurface {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(EditorTheme.chrome(0.1), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        }
        // Native window shadow extends beyond the hit frame. Presentation is
        // owned by the presenter, after fitting/layout and orderFront finish.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized(dialog.title))
        .accessibilityIdentifier("app.dialog.card")
        .appControlFocusAppearance()
        .onAppear {
            inputFocused = dialog.input != nil
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dialog.showsAppIcon {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                    .frame(width: 44, height: 44).padding(.bottom, 12)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .center, spacing: 12) {
                if isRecordingDecision, let cancelID = dialog.cancelActionID {
                    dismissButton(cancelID, icon: .arrowLeft, label: "返回录制结果")
                }
                Text(appLocalized(dialog.title))
                    .font(.appUI(size: isCompactDecision ? 16 : 17, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if dialog.layout == .projectDecision, let cancelID = dialog.cancelActionID {
                    Spacer(minLength: 0)
                    dismissButton(cancelID, icon: .close, label: "取消关闭项目")
                }
            }

            ViewThatFits(in: .vertical) {
                message
                ScrollView { message }.frame(height: 180)
            }
            .frame(maxHeight: 180)
            .padding(.top, 8)

            if let title = dialog.itemTitle {
                Text(title).font(.appUI(size: isCompactDecision ? 12 : 13, weight: .medium))
                    .lineLimit(isCompactDecision ? 1 : 2).truncationMode(.middle)
                    .foregroundStyle(isCompactDecision ? EditorTheme.secondaryText : EditorTheme.primaryText)
                    .padding(.top, isCompactDecision ? 10 : 12)
            }

            if dialog.input != nil {
                TextField(appLocalized(dialog.inputPlaceholder), text: $input.text)
                    .textFieldStyle(.plain).font(.appUI(size: 14))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(EditorTheme.chrome(inputFocused ? 0.09 : 0.06), in: Capsule())
                    .focused($inputFocused)
                    .onSubmit { choose(dialog.defaultActionID) }
                    .accessibilityIdentifier("app.dialog.input")
                    .padding(.top, 16)
                    .animation(.easeOut(duration: 0.14), value: inputFocused)
            }
        }
    }

    private var actions: some View {
        Group {
            if isCompactDecision {
                HStack(spacing: RecordingCompletionLayout.actionSpacing) {
                    ForEach(dialog.actions.filter { $0.role != .cancel }) { action in
                        actionButton(action)
                    }
                }
            } else if dialog.actions.count <= 2 {
                HStack(spacing: 8) {
                    ForEach(dialog.actions) { action in actionButton(action) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(stackedActions) { action in actionButton(action) }
                }
            }
        }
    }

    private func dismissButton(_ cancelID: String, icon: AppLineIcon.Kind, label: String) -> some View {
        Button { choose(cancelID) } label: {
            AppLineIcon(kind: icon, size: 16)
                .foregroundStyle(EditorTheme.primaryText)
                .frame(width: 26, height: 26)
                .background(EditorTheme.chrome(dismissHovered ? 0.18 : 0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(RecorderPlainPressButtonStyle(cornerRadius: 13))
        .onHover { dismissHovered = $0 }
        .animation(RecorderMotion.fade, value: dismissHovered)
        .accessibilityLabel(appLocalized(label))
        .accessibilityIdentifier("app.dialog.action.\(cancelID)")
        .help(appLocalized(label))
    }

    /// Top to bottom: the answer that moves forward, then the alternatives,
    /// then backing out.
    private var stackedActions: [AppDialog.Action] {
        func rank(_ role: AppDialog.Action.Role) -> Int {
            switch role { case .primary: 0; case .destructive: 1; case .secondary: 2; case .cancel: 3 }
        }
        return dialog.actions.enumerated().sorted {
            (rank($0.element.role), $0.offset) < (rank($1.element.role), $1.offset)
        }.map(\.element)
    }

    private var message: some View {
        Text(appLocalized(dialog.message))
            .font(.appUI(size: isCompactDecision ? 12 : 13)).foregroundStyle(EditorTheme.secondaryText)
            .lineSpacing(isCompactDecision ? 3 : 4).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func actionButton(_ action: AppDialog.Action) -> some View {
        Button { choose(action.id) } label: {
            Text(appLocalized(action.title)).font(.appUI(size: 13, weight: .semibold))
                .lineLimit(1).padding(.horizontal, 14)
                .frame(maxWidth: .infinity,
                       minHeight: isRecordingDecision ? RecordingCompletionLayout.actionHeight : 40)
        }
        .buttonStyle(AppDialogButtonStyle(role: action.role))
        .disabled(!dialog.isEnabled(action, input: input.text))
        .accessibilityIdentifier("app.dialog.action.\(action.id)")
    }

    private func choose(_ id: String?) {
        guard let action = dialog.actions.first(where: { $0.id == id }),
              dialog.isEnabled(action, input: input.text) else { return }
        respond(.init(actionID: action.id, input: input.text))
    }
}

private struct AppDialogButtonStyle: ButtonStyle {
    let role: AppDialog.Action.Role
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                Capsule()
                    .fill(EditorTheme.chrome(isEnabled && (hovered || configuration.isPressed) ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .appKeyboardFocus(in: Capsule(),
                              color: role == .primary ? EditorTheme.onAccent.opacity(0.65) : EditorTheme.chrome(0.40))
            .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(RecorderMotion.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: EditorTheme.onAccent
        case .destructive: RecorderStyle.destructiveInk
        default: EditorTheme.primaryText
        }
    }

    private var background: Color {
        switch role {
        case .primary: return EditorTheme.platinumAccent
        case .destructive: return Color(red: 1.0, green: 0.33, blue: 0.3).opacity(0.14)
        case .secondary: return EditorTheme.chrome(0.07)
        case .cancel: return EditorTheme.chrome(0.07)
        }
    }
}

/// Retains the existing application-modal decision boundary used by close and
/// delete. Actions run only AFTER the card is removed and focus is restored.
@MainActor
enum AppDialogPresenter {
    private static var activeID: UUID?
    private static var dismissActive: (() -> Void)?
    static var isPresenting: Bool { activeID != nil }

    static func cancel(id: UUID) {
        if activeID == id { dismissActive?() }
    }

    /// Leave both the triggering SwiftUI action and the Dispatch main queue
    /// before entering AppKit's modal loop. A main-queue work item cannot be
    /// reentered, so runModal inside one starves SwiftUI's button work until
    /// an AppKit-only action (such as Escape) unwinds it.
    static func present(_ dialog: AppDialog, relativeTo suppliedOwner: NSWindow? = nil,
                        id: UUID = UUID(),
                        completion: @escaping @MainActor (AppDialog.Response) -> Void = { _ in }) {
        guard activeID == nil, NSApp.modalWindow == nil else {
            completion(.init(actionID: nil))
            return
        }
        let owner = suppliedOwner ?? NSApp.keyWindow ?? NSApp.mainWindow
        let hadOwner = owner != nil
        activeID = id
        dismissActive = {
            activeID = nil
            dismissActive = nil
            completion(.init(actionID: nil))
        }
        RunLoop.main.perform(inModes: [.default]) { [weak owner] in
            MainActor.assumeIsolated {
                guard activeID == id else { return }
                guard !hadOwner || owner?.isVisible == true else { cancel(id: id); return }
                let response = runModal(dialog, relativeTo: owner, id: id)
                completion(response)
            }
        }
    }

    static func response(to dialog: AppDialog, relativeTo owner: NSWindow? = nil) async -> AppDialog.Response {
        await withCheckedContinuation { continuation in
            present(dialog, relativeTo: owner) { continuation.resume(returning: $0) }
        }
    }

    private static func runModal(_ dialog: AppDialog, relativeTo owner: NSWindow?,
                                 id: UUID) -> AppDialog.Response {
        if dialog.layout == .recordingDecision,
           let owner, let host = owner as? any RecordingDecisionHosting {
            return runRecordingDecision(dialog, in: owner, host: host, id: id)
        }
        let screen = owner?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let preferredWidth: CGFloat = dialog.layout.isCompactDecision ? 336 : 360
        let width = min(preferredWidth, visible.width - 32)
        let input = AppDialogInput(dialog.input ?? "")
        let panel = AppDialogPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        var response = AppDialog.Response(actionID: nil)
        var finished = false
        let finish: (AppDialog.Response) -> Void = { value in
            guard !finished else { return }
            finished = true
            response = value
            NSApp.stopModal()
        }
        panel.onCancel = { finish(.init(actionID: dialog.cancelActionID, input: input.text)) }
        panel.onReturn = {
            guard let action = dialog.actions.first(where: { $0.id == dialog.defaultActionID }),
                  dialog.isEnabled(action, input: input.text) else { return }
            finish(.init(actionID: action.id, input: input.text))
        }
        let host = NSHostingController(rootView: AppDialogCard(dialog: dialog, input: input, width: width, respond: finish))
        panel.contentViewController = host
        panel.appearance = nil
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The WindowServer draws beyond the content bounds without requiring
        // a large transparent, click-blocking rectangle around the card.
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, owner?.level.rawValue ?? 0) + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.identifier = NSUserInterfaceItemIdentifier("dogsc.app-dialog")
        appLocalizeWindowTitle(panel, dialog.title)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        // A decision appears over the thing it is about: centred on the
        // window that asked, wherever that window is, kept on screen.
        let anchor = owner.flatMap { $0.isVisible ? $0.frame : nil } ?? visible
        let proposedY = anchor.midY - size.height / 2
        panel.setFrame(NSRect(x: min(max(anchor.midX - size.width / 2, visible.minX + 16), visible.maxX - size.width - 16),
                              y: min(max(proposedY, visible.minY + 16), visible.maxY - size.height - 16),
                              width: size.width, height: size.height), display: false)
        dismissActive = { finish(.init(actionID: nil)) }
        FirstUseTourController.setAppDialogPresented(true)
        let closeObserver = owner.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { cancel(id: id) }
            }
        }
        // Fitting a hosting view can already run SwiftUI.onAppear offscreen.
        // Begin the actual entrance here so measurement cannot consume it.
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.displayIfNeeded()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion ? 0.1 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        NSApp.runModal(for: panel)
        panel.onCancel = nil
        panel.onReturn = nil
        // The answer is already in hand; the card only needs a moment to leave.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            panel.contentViewController = nil
            panel.close()
        } else {
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panel.contentViewController = nil
                    panel.close()
                }
            })
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        dismissActive = nil
        activeID = nil
        if owner?.isVisible == true, NSApp.isActive { owner?.makeKeyAndOrderFront(nil) }
        FirstUseTourController.setAppDialogPresented(false)
        return response
    }

    private static func runRecordingDecision(_ dialog: AppDialog, in window: NSWindow,
                                             host: any RecordingDecisionHosting,
                                             id: UUID) -> AppDialog.Response {
        var response = AppDialog.Response(actionID: nil)
        var finished = false
        let finish: @MainActor (AppDialog.Response) -> Void = { value in
            guard !finished else { return }
            finished = true
            response = value
            NSApp.stopModal()
        }
        guard host.presentRecordingDecision(dialog, respond: finish) else {
            activeID = nil
            dismissActive = nil
            return response
        }
        dismissActive = { host.cancelRecordingDecision() }
        FirstUseTourController.setAppDialogPresented(true)
        let closing = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { finish(.init(actionID: nil)) }
        }
        // The same visible panel is the modal window. Returning from another
        // app restores that panel, never a hidden completion owner behind it.
        let activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, NSApp.modalWindow === window else { return }
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        NotificationCenter.default.removeObserver(closing)
        NotificationCenter.default.removeObserver(activation)
        dismissActive = nil
        activeID = nil
        FirstUseTourController.setAppDialogPresented(false)
        // Back replies only after the card has returned. Save/trash keep the
        // decision visible until the model finishes its persistence barrier.
        return response
    }

}

private final class AppDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

extension View {
    func appDialog(isPresented: Binding<Bool>, makeDialog: @escaping @MainActor () -> AppDialog) -> some View {
        background(AppDialogAnchor(isPresented: isPresented, makeDialog: makeDialog).frame(width: 0, height: 0))
    }
}

private struct AppDialogAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let makeDialog: @MainActor () -> AppDialog
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(view: view, binding: $isPresented, makeDialog: makeDialog)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.cancel() }

    @MainActor final class Coordinator {
        private var requestID: UUID?
        func cancel() {
            if let requestID { AppDialogPresenter.cancel(id: requestID) }
            requestID = nil
        }
        func update(view: NSView, binding: Binding<Bool>, makeDialog: @escaping @MainActor () -> AppDialog) {
            guard binding.wrappedValue else { cancel(); return }
            guard requestID == nil else { return }
            let id = UUID()
            requestID = id
            // Leave SwiftUI's update pass and the triggering mouse-up before
            // entering AppKit's modal loop or giving an input field focus.
            DispatchQueue.main.async { [weak self, weak view] in
                self?.present(id: id, view: view, binding: binding, makeDialog: makeDialog)
            }
        }
        private func present(id: UUID, view: NSView?, binding: Binding<Bool>, makeDialog: @escaping @MainActor () -> AppDialog) {
            guard requestID == id else { return }
            guard binding.wrappedValue, let view else { cancel(); return }
            // An error can arrive while a confirmation or file picker is open.
            // Keep it pending, rather than nesting modals or losing the notice.
            if view.window == nil || AppDialogPresenter.isPresenting || NSApp.modalWindow != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak view] in
                    self?.present(id: id, view: view, binding: binding, makeDialog: makeDialog)
                }
                return
            }
            guard let owner = view.window else { return }
            let dialog = makeDialog()
            AppDialogPresenter.present(dialog, relativeTo: owner, id: id) { [weak self] response in
                guard let self, self.requestID == id else { return }
                self.requestID = nil
                binding.wrappedValue = false
                dialog.actions.first(where: { $0.id == response.actionID })?.handler(response.input)
            }
        }
    }
}
