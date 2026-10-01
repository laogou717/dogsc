import AppKit
import SwiftUI

/// App-owned decisions and notices. File pickers and macOS permission prompts
/// retain their system UI; they are not application confirmation dialogs.
struct AppDialog {
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

@MainActor
final class AppDialogInput: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

/// A compact, left-aligned card shared by project decisions, recorder notices
/// and preset naming. One contour owns its fill, clipping and border.
struct AppDialogCard: View {
    let dialog: AppDialog
    @ObservedObject var input: AppDialogInput
    var width: CGFloat = 440
    let respond: (AppDialog.Response) -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 13) {
                Group {
                    if dialog.showsAppIcon { Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit() }
                    else { Image(systemName: dialog.symbol) }
                }
                    .font(.appUI(size: 21, weight: .medium))
                    .foregroundStyle(EditorTheme.platinumMuted)
                    .frame(width: 46, height: 46)
                    .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                Text(appLocalized(dialog.title))
                    .font(.appUI(size: 19, weight: .semibold))
                    .foregroundStyle(EditorTheme.platinumAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .vertical) {
                message
                ScrollView { message }.frame(height: 180)
            }
            .frame(maxHeight: 180)

            if let title = dialog.itemTitle {
                HStack(spacing: 11) {
                    Image(systemName: "folder").font(.appUI(size: 20))
                        .foregroundStyle(EditorTheme.platinumMuted)
                    Text(title).font(.appUI(size: 14, weight: .medium))
                        .lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(EditorTheme.platinumAccent)
                    Spacer(minLength: 0)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if dialog.input != nil {
                TextField(appLocalized(dialog.inputPlaceholder), text: $input.text)
                    .textFieldStyle(.plain).font(.appUI(size: 14))
                    .padding(.horizontal, 13).frame(height: 42)
                    .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(EditorTheme.chrome(inputFocused ? 0.24 : 0.09), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .focused($inputFocused)
                    .onSubmit { choose(dialog.defaultActionID) }
                    .accessibilityIdentifier("app.dialog.input")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(dialog.actions) { action in actionButton(action) }
                }
                VStack(spacing: 8) {
                    ForEach(dialog.actions) { action in actionButton(action, expanded: true) }
                }
            }
            .padding(.top, 2)
        }
        .padding(26).frame(width: width, alignment: .leading)
        .background(EditorTheme.panelSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(EditorTheme.chrome(0.08), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized(dialog.title))
        .accessibilityIdentifier("app.dialog.card")
        .appControlFocusAppearance()
        .onAppear { inputFocused = dialog.input != nil }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var message: some View {
        Text(appLocalized(dialog.message))
            .font(.appUI(size: 13)).foregroundStyle(EditorTheme.platinumMuted)
            .lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func actionButton(_ action: AppDialog.Action, expanded: Bool = false) -> some View {
        Button { choose(action.id) } label: {
            Text(appLocalized(action.title)).font(.appUI(size: 13, weight: .medium))
                .fixedSize().padding(.horizontal, 16)
                .frame(minWidth: 84, maxWidth: expanded ? .infinity : nil, minHeight: 38)
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
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EditorTheme.chrome(isEnabled && (hovered || configuration.isPressed) ? 0.06 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                              color: role == .primary ? EditorTheme.onAccent.opacity(0.65) : EditorTheme.chrome(0.40))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.38)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: EditorTheme.onAccent
        case .destructive: Color(nsColor: .systemRed)
        default: EditorTheme.platinumAccent
        }
    }

    private var background: Color {
        switch role {
        case .primary: EditorTheme.platinumAccent
        case .destructive: Color(nsColor: .systemRed).opacity(0.09)
        default: EditorTheme.chrome(0.055)
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
        let screen = owner?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(440, visible.width - 32)
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
        panel.appearance = owner?.effectiveAppearance ?? NSApp.effectiveAppearance
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, owner?.level.rawValue ?? 0) + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.identifier = NSUserInterfaceItemIdentifier("dogsc.app-dialog")
        panel.title = appLocalized(dialog.title)
        let size = host.view.fittingSize
        // Editor decisions align with their document. The short recording bar
        // uses its display centre, rather than squeezing a sheet below itself.
        let anchor = owner.flatMap { $0.frame.height >= 400 ? $0.frame : nil } ?? visible
        panel.setFrame(NSRect(x: min(max(anchor.midX - size.width / 2, visible.minX + 16), visible.maxX - size.width - 16),
                              y: min(max(anchor.midY - size.height / 2, visible.minY + 16), visible.maxY - size.height - 16),
                              width: size.width, height: size.height), display: false)
        dismissActive = { finish(.init(actionID: nil)) }
        FirstUseTourController.setAppDialogPresented(true)
        let closeObserver = owner.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { cancel(id: id) }
            }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.onCancel = nil
        panel.onReturn = nil
        panel.contentViewController = nil
        panel.close()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        dismissActive = nil
        activeID = nil
        if owner?.isVisible == true, NSApp.isActive { owner?.makeKeyAndOrderFront(nil) }
        FirstUseTourController.setAppDialogPresented(false)
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
