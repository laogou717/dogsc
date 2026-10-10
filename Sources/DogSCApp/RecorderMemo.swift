import AppKit
import SwiftUI

/// Local scratch text belongs to the recorder, not the recorded project.
/// Debounce typing, then flush on hide/termination so closing never loses a draft.
@MainActor
final class RecorderMemoStore: ObservableObject {
    private enum Key {
        static let text = "recorder.memo.text"
        static let fontSize = "recorder.memo.font-size"
        static let opacity = "recorder.memo.background-opacity"
    }

    @Published var text: String { didSet { scheduleSave() } }
    @Published var fontSize: Double { didSet { scheduleSave() } }
    @Published var opacity: Double { didSet { scheduleSave() } }
    @Published var isEditing: Bool
    private var pendingSave: Task<Void, Never>?
    private var hasChanges = false

    init() {
        let defaults = UserDefaults.standard
        let savedText = defaults.string(forKey: Key.text) ?? ""
        text = savedText
        let savedSize = defaults.object(forKey: Key.fontSize) as? Double ?? 22
        let savedOpacity = defaults.object(forKey: Key.opacity) as? Double ?? 0.92
        fontSize = savedSize.isFinite ? min(max(savedSize, 16), 40) : 22
        opacity = savedOpacity.isFinite ? min(max(savedOpacity, 0.55), 1) : 0.92
        isEditing = savedText.isEmpty
    }

    private func scheduleSave() {
        hasChanges = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.save()
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasChanges else { return }
        hasChanges = false
        let defaults = UserDefaults.standard
        defaults.set(text, forKey: Key.text)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(opacity, forKey: Key.opacity)
    }
}

@MainActor
final class RecorderMemoController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RecorderMemoController()
    @Published private(set) var isVisible = false
    let store = RecorderMemoStore()
    private var panel: RecorderMemoPanel?
    private var screenObserver: NSObjectProtocol?
    private var shouldResumeAfterSelection = false
    private let frameKey = "recorder.memo.frame"

    func toggle(relativeTo owner: NSWindow) {
        if isVisible { hide() } else { show(relativeTo: owner) }
    }

    private func show(relativeTo owner: NSWindow) {
        RecorderPopoverPresenter.shared.dismiss()
        let panel = panel ?? makePanel()
        let savedFrame = UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString)
        let screen = savedFrame.flatMap { frame in
            NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        } ?? owner.screen ?? NSScreen.main
        guard let screen else { return }
        let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let proposed: NSRect
        if let savedFrame, savedFrame.width.isFinite, savedFrame.height.isFinite,
           savedFrame.minX.isFinite, savedFrame.minY.isFinite,
           savedFrame.width >= 280, savedFrame.height >= 240 {
            proposed = savedFrame
        } else {
            let size = NSSize(width: 390, height: 420)
            let above = owner.frame.maxY + 14
            let y = above + size.height <= safe.maxY ? above : owner.frame.minY - size.height - 14
            proposed = NSRect(x: owner.frame.maxX - size.width, y: y, width: size.width, height: size.height)
        }
        fit(panel, proposed: proposed, safe: safe)
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderMemo)
        // Independent window: no child-window link, no outside-click dismissal,
        // and showing it does not activate the app or take the typing focus.
        panel.orderFrontRegardless()
        isVisible = true
        animateRecorderOverlayIn(panel)
    }

    private func makePanel() -> RecorderMemoPanel {
        let panel = RecorderMemoPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 420),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = nil
        appLocalizeWindowTitle(panel, "备忘录")
        panel.identifier = NSUserInterfaceItemIdentifier("recorder.memo.window")
        // CaptureSurfaceFilter excludes this process's helper windows, including
        // memos opened mid-recording. Other recorders may capture the memo.
        panel.sharingType = .readOnly
        panel.onClose = { [weak self] in self?.hide() }
        panel.onMoveEnded = { [weak self] in
            self?.constrainToScreen()
            self?.saveFrame()
        }
        panel.contentViewController = NSHostingController(rootView:
            RecorderMemoView(store: store, onClose: { [weak self] in self?.hide() })
                .appControlFocusAppearance())
        panel.delegate = self
        self.panel = panel
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainToScreen() }
        }
        return panel
    }

    func hide() {
        shouldResumeAfterSelection = false
        guard isVisible else { return }
        store.save()
        saveFrame()
        panel?.orderOut(nil)
        isVisible = false
    }

    func suspendForSelection() {
        let wasVisible = isVisible || shouldResumeAfterSelection
        hide()
        shouldResumeAfterSelection = wasVisible
    }

    func resumeAfterSelection(relativeTo owner: NSWindow) {
        guard shouldResumeAfterSelection else { return }
        shouldResumeAfterSelection = false
        show(relativeTo: owner)
    }

    func shutdown() {
        hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.delegate = nil
        panel?.contentViewController = nil
        panel?.close()
        panel = nil
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) {
        constrainToScreen()
        saveFrame()
    }
    func windowDidResignKey(_ notification: Notification) { store.save() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
    }

    private func constrainToScreen() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        fit(panel, proposed: panel.frame, safe: screen.visibleFrame.insetBy(dx: 12, dy: 12))
    }

    private func fit(_ panel: NSWindow, proposed: NSRect, safe: NSRect) {
        let minSize = NSSize(width: min(300, safe.width), height: min(280, safe.height))
        panel.contentMinSize = minSize
        panel.contentMaxSize = NSSize(width: min(760, safe.width), height: min(1000, safe.height))
        let width = min(max(proposed.width, minSize.width), panel.contentMaxSize.width)
        let height = min(max(proposed.height, minSize.height), panel.contentMaxSize.height)
        panel.setFrame(NSRect(x: min(max(proposed.minX, safe.minX), safe.maxX - width),
            y: min(max(proposed.minY, safe.minY), safe.maxY - height), width: width, height: height), display: true)
    }
}

private final class RecorderMemoPanel: NSPanel {
    var onClose: (() -> Void)?
    var onMoveEnded: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func performClose(_ sender: Any?) { onClose?() }
}

struct RecorderMemoButton: View {
    var size: CGFloat = 36
    @ObservedObject private var memo = RecorderMemoController.shared
    var body: some View {
        ZStack {
            if memo.isVisible {
                Circle().fill(RecorderStyle.selection).padding(3).transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Image(systemName: memo.isVisible ? "note.text" : "note.text").font(.system(size: 14, weight: .medium))
                .foregroundStyle(memo.isVisible ? RecorderStyle.ink : RecorderStyle.muted)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            RecorderActionTrigger(action: WindowCoordinator.toggleRecorderMemo,
                accessibilityLabel: appLocalized(memo.isVisible ? "收起备忘录" : "打开备忘录"),
                accessibilityIdentifier: "recorder.memo.toggle", cornerRadius: size / 2, highlightOpacity: 0.05)
        }
        .frame(width: size, height: size)
        .animation(RecorderMotion.quick, value: memo.isVisible)
        .help("备忘录")
    }
}

/// A sheet of notes and nothing else. The few controls it needs are glyphs
/// along the top edge; the words on it are the user's.
private struct RecorderMemoView: View {
    @ObservedObject var store: RecorderMemoStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The empty stretch of the bar is the handle the sheet moves by.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { RecorderMemoWindowHandle(resizes: false) }
                control(store.isEditing ? "pencil" : "eye", title: store.isEditing ? "切换到阅读，避免误改文稿" : "编辑备忘录") {
                    store.isEditing.toggle()
                    store.save()
                }
                .accessibilityIdentifier("recorder.memo.mode")
                control("textformat.size.smaller", title: "缩小备忘录字号", enabled: store.fontSize > 16) {
                    store.fontSize = max(16, store.fontSize - 2)
                }
                control("textformat.size.larger", title: "放大备忘录字号", enabled: store.fontSize < 40) {
                    store.fontSize = min(40, store.fontSize + 2)
                }
                Slider(value: $store.opacity, in: 0.55...1)
                    .tint(RecorderStyle.chrome.opacity(0.7)).controlSize(.mini)
                    .frame(width: 58).padding(.horizontal, 8)
                    .help("背景不透明度")
                    .accessibilityLabel("备忘录背景不透明度")
                control("xmark", title: "收起备忘录", action: onClose)
            }
            .frame(height: 40)
            .padding(.horizontal, 6)

            ZStack(alignment: .topLeading) {
                RecorderMemoTextView(text: $store.text, fontSize: store.fontSize, isEditing: store.isEditing)
                if store.text.isEmpty {
                    Text("写下或粘贴要讲的内容…")
                        .font(.system(size: store.fontSize)).foregroundStyle(RecorderStyle.faint)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 10)
        }
        .foregroundStyle(RecorderStyle.ink)
        // Only the sheet fades. Fading the entire NSWindow would also wash out text.
        .background(RecorderStyle.base.opacity(store.opacity), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [RecorderStyle.edgeTop, RecorderStyle.edgeBottom],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            // An invisible corner still resizes; nothing is drawn for it.
            Color.clear.frame(width: 18, height: 18)
                .overlay { RecorderMemoWindowHandle(resizes: true) }
        }
        .animation(RecorderMotion.quick, value: store.isEditing)
        .accessibilityIdentifier("recorder.memo.content")
    }

    private func control(_ symbol: String, title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: symbol.hasPrefix("textformat") ? 15 : 12, weight: .semibold))
                .foregroundStyle(RecorderStyle.muted)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(RecorderCirclePressStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .help(appLocalized(title))
        .accessibilityLabel(appLocalized(title))
    }
}

/// NSTextView supplies IME, plain-text paste, native undo and smooth scrolling.
/// Updating settings never replaces text or selection during marked-text input.
private struct RecorderMemoTextView: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Binding var text: String
    let fontSize: Double
    let isEditing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MemoScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = MemoTextView(frame: .zero)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textColor = RecorderStyle.inkNSColor
        view.insertionPointColor = RecorderStyle.inkNSColor
        view.focusRingType = .none
        view.setAccessibilityLabel(appLocalized("备忘录文稿"))
        view.string = text
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        _ = locale
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView else { return }
        view.setAccessibilityLabel(appLocalized("备忘录文稿"))
        view.isEditable = isEditing
        view.isSelectable = true
        if view.string != text, !view.hasMarkedText() { view.string = text }
        if view.font?.pointSize != CGFloat(fontSize) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.35
            paragraph.paragraphSpacing = fontSize * 0.5
            view.font = .systemFont(ofSize: fontSize)
            view.defaultParagraphStyle = paragraph
            view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: (view.string as NSString).length))
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }

    final class MemoTextView: NSTextView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            // Refresh glyph attributes and caret without replacing the text,
            // selection or IME marked range.
            textColor = RecorderStyle.inkNSColor
            insertionPointColor = RecorderStyle.inkNSColor
            needsDisplay = true
        }
    }

    final class MemoScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let view = documentView as? NSTextView else { return }
            let viewport = contentSize
            if view.frame.width != viewport.width || view.minSize.height != viewport.height {
                view.minSize = NSSize(width: 0, height: viewport.height)
                view.setFrameSize(NSSize(width: viewport.width, height: max(view.frame.height, viewport.height)))
            }
        }
    }
}

private struct RecorderMemoWindowHandle: NSViewRepresentable {
    let resizes: Bool
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.resizes = resizes }

    final class Handle: NSView {
        var resizes = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if !resizes {
                window.performDrag(with: event)
                (window as? RecorderMemoPanel)?.onMoveEnded?()
                return
            }
            let start = NSEvent.mouseLocation
            let frame = window.frame
            // Native event tracking ends on mouse-up; no display link or timer.
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let point = NSEvent.mouseLocation
                let width = min(max(frame.width + point.x - start.x, window.contentMinSize.width), window.contentMaxSize.width)
                let height = min(max(frame.height + start.y - point.y, window.contentMinSize.height), window.contentMaxSize.height)
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
            }
            window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        }
    }
}
