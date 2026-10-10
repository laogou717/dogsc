import AppKit
import SwiftUI

enum FirstUseTourKind: String, CaseIterable {
    case permissions, recorder, editor

    var steps: [FirstUseTourStep] {
        switch self {
        case .permissions:
            [
                .init("permission.screen", "先允许录制屏幕", "打开系统设置，允许 DogSC 录制屏幕。返回后会自动检查。", "display"),
                .init("permission.pointer", "让鼠标动作被记录", "辅助功能用于记录鼠标移动与点击。设置列表里没有 DogSC 时，把下方悬浮条中的图标拖进去，再打开开关。", "cursorarrow"),
                .init("permission.finish", "授权已完成", "屏幕录制与辅助功能已就绪。进入后即可选择录制范围；摄像头和麦克风仍在启用时授权。", "checkmark.circle")
            ]
        case .recorder:
            [
                .init("recorder.source", "选择录制范围", "录整个屏幕、一个窗口，或自己框选区域。连接的设备也可以作为录制来源。", "viewfinder"),
                .init("recorder.inputs", "按需开启声音与摄像头", "在这里选择麦克风、摄像头和系统声音。只开启这次录制需要的输入。", "mic"),
                .init("recorder.save", "设置保存位置", "选择项目位置、格式和画质。已有项目也可以从这里打开，继续编辑。", "folder")
            ]
        case .editor:
            [
                .init("editor.tools", "从这里选择要调整的内容", "画面、运镜、光标、摄像头与声音，各自的设置都从左侧进入。", "slider.horizontal.3", side: .right),
                .init("editor.inspector", "调整画面外观", "右侧显示当前选项的详细设置。背景、布局与样机的变化会显示在预览中。", "macwindow", side: .left),
                .init("editor.timeline", "在时间线上剪辑", "移动播放指针定位内容，拖动片段边缘调整长度。吸附和预览可以在时间线上方开关。", "film", side: .above),
                .init("editor.export", "完成后导出", "从这里选择导出格式和画质，生成成片。项目会继续保留，方便回来修改。", "square.and.arrow.up")
            ]
        }
    }
}

struct FirstUseTourStep {
    enum Side { case below, above, left, right }
    let target: String
    let title: String
    let detail: String
    let symbol: String
    var side: Side

    init(_ target: String, _ title: String, _ detail: String, _ symbol: String, side: Side = .below) {
        self.target = target; self.title = title; self.detail = detail; self.symbol = symbol; self.side = side
    }
}

extension View {
    func firstUseTourTarget(_ target: String, in kind: FirstUseTourKind, highlight: FirstUseTourHighlight) -> some View {
        background(FirstUseTourBridge(kind: kind, target: target, enabled: true, highlight: highlight).allowsHitTesting(false))
    }

    func firstUseTour(_ kind: FirstUseTourKind, enabled: Bool = true) -> some View {
        background(FirstUseTourBridge(kind: kind, target: nil, enabled: enabled).allowsHitTesting(false))
    }
}

/// Anchors follow the live controls' layout, including resizing and display moves.
/// They do not publish into AppModel or the editor render/timeline state.
private struct FirstUseTourBridge: NSViewRepresentable {
    let kind: FirstUseTourKind
    let target: String?
    let enabled: Bool
    var highlight = FirstUseTourHighlight.rounded(0)

    func makeNSView(context: Context) -> FirstUseTourAnchorView {
        FirstUseTourAnchorView(kind: kind, target: target)
    }
    func updateNSView(_ view: FirstUseTourAnchorView, context: Context) {
        view.enabled = enabled
        view.highlight = highlight
        view.refresh()
    }
    static func dismantleNSView(_ view: FirstUseTourAnchorView, coordinator: Void) {
        FirstUseTourController.controller(for: view.kind).detach(view)
    }
}

private final class FirstUseTourAnchorView: NSView {
    let kind: FirstUseTourKind
    let target: String?
    var enabled = true
    var highlight = FirstUseTourHighlight.rounded(0)
    private var lastHighlight: FirstUseTourHighlight?
    private var lastWindowNumber: Int?
    private var lastRect = CGRect.null
    private var lastEnabled: Bool?
    init(kind: FirstUseTourKind, target: String?) {
        self.kind = kind; self.target = target
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func layout() { super.layout(); refresh() }
    func refresh() {
        let rect = convert(bounds, to: nil)
        guard lastWindowNumber != window?.windowNumber || lastRect != rect || lastEnabled != enabled || lastHighlight != highlight else { return }
        lastWindowNumber = window?.windowNumber
        lastRect = rect
        lastEnabled = enabled
        lastHighlight = highlight
        FirstUseTourController.controller(for: kind).attach(self)
    }
}

@MainActor
final class FirstUseTourController {
    private static var controllers: [FirstUseTourKind: FirstUseTourController] = [:]
    // Focus notifications may resume a temporarily suspended tour. A complete
    // permission-page visit needs a stronger gate, including its opening film
    // and System Settings round trip, even for an already-authorized install.
    private static var permissionPageIsPresented = false
    private static var permissionIntroIsActive = false
    private static var appDialogIsPresented = false
    static func setAppDialogPresented(_ presented: Bool) {
        appDialogIsPresented = presented
        for controller in controllers.values {
            if presented { controller.suspend() }
            else { controller.resume() }
        }
    }
    static func setPermissionIntroActive(_ active: Bool) {
        guard permissionIntroIsActive != active else { return }
        permissionIntroIsActive = active
        if active {
            controllers[.permissions]?.suspend()
        }
    }
    static func setPermissionPagePresented(_ presented: Bool) {
        guard permissionPageIsPresented != presented else { return }
        permissionPageIsPresented = presented
        for kind in [FirstUseTourKind.recorder, .editor] {
            guard let controller = controllers[kind] else { continue }
            if presented { controller.suspend() }
            else { controller.resume() }
        }
    }
    static func controller(for kind: FirstUseTourKind) -> FirstUseTourController {
        if let controller = controllers[kind] { return controller }
        let controller = FirstUseTourController(kind: kind)
        controllers[kind] = controller
        return controller
    }

    private final class WeakAnchor {
        weak var view: FirstUseTourAnchorView?
        init(_ view: FirstUseTourAnchorView) { self.view = view }
    }
    let kind: FirstUseTourKind
    private weak var host: FirstUseTourAnchorView?
    private weak var owner: NSWindow?
    private var targets: [String: WeakAnchor] = [:]
    private var index = 0
    private var completed: Bool
    private var updatePending = false
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var shadePanel: NSPanel?
    private var cardPanel: FirstUseTourPanel?
    private var startTask: Task<Void, Never>?
    private var isSuspended = false
    private var isDismissing = false
    private var permissionFlow: PermissionTourFlow?
    private var permissionOpenSettings: ((PermissionTourFlow.Step) -> Void)?
    private var permissionContinue: (() -> Void)?
    private var permissionRefresh: (() async -> PermissionTourFlow.Access)?
    private var permissionReturnTask: Task<Void, Never>?
    private var lastTarget = CGRect.null
    private var lastCardIndex = -1
    private var needsEntrance = false
    private var isHandedOffFromIntro = false
    /// The guide has not been finished or skipped, so it will present itself
    /// as soon as its page allows.
    var isPending: Bool { !completed }
    private var preferenceKey: String { "onboarding.tour.\(kind.rawValue).completed" }
    private var isBlockedByModalSurface: Bool {
        Self.appDialogIsPresented
            || (kind != .permissions && Self.permissionPageIsPresented)
            || (kind == .permissions && Self.permissionIntroIsActive)
    }

    private init(kind: FirstUseTourKind) {
        self.kind = kind
        completed = UserDefaults.standard.bool(forKey: "onboarding.tour.\(kind.rawValue).completed")
    }

    func configurePermissions(access: PermissionTourFlow.Access, isReview: Bool,
                              openSettings: @escaping (PermissionTourFlow.Step) -> Void,
                              onContinue: @escaping () -> Void,
                              refresh: @escaping () async -> PermissionTourFlow.Access) {
        guard kind == .permissions else { return }
        permissionReturnTask?.cancel()
        permissionReturnTask = nil
        permissionFlow = PermissionTourFlow(access: access, isReview: isReview)
        permissionOpenSettings = openSettings
        permissionContinue = onContinue
        permissionRefresh = refresh
        index = permissionFlow?.step.rawValue ?? 0
        lastCardIndex = -1
        requestUpdate()
    }

    func updatePermissions(_ access: PermissionTourFlow.Access) {
        guard var flow = permissionFlow, flow.access != access else { return }
        flow.update(access)
        permissionFlow = flow
        if index == flow.step.rawValue { lastCardIndex = -1 }
        index = flow.step.rawValue
        requestUpdate()
    }

    func beginPermissionSettings(_ step: PermissionTourFlow.Step) {
        permissionFlow?.openedSettings(for: step)
        index = permissionFlow?.step.rawValue ?? index
        suspend()
    }

    func completePermissions() {
        guard kind == .permissions else { return }
        finish()
    }

    private func refreshPermissionsOnReturn() {
        guard permissionReturnTask == nil, let refresh = permissionRefresh,
              NSApp.isActive, owner?.isVisible == true, host?.enabled == true,
              NSApp.keyWindow === owner || NSApp.keyWindow === cardPanel else { return }
        permissionReturnTask = Task { @MainActor [weak self] in
            let access = await refresh()
            guard let self, !Task.isCancelled else { return }
            self.permissionReturnTask = nil
            guard NSApp.isActive, self.owner?.isVisible == true,
                  NSApp.keyWindow === self.owner || NSApp.keyWindow === self.cardPanel else { return }
            self.permissionFlow?.returnedFromSettings(access: access)
            self.index = self.permissionFlow?.step.rawValue ?? self.index
            self.lastCardIndex = -1
            self.isSuspended = false
            self.requestUpdate()
        }
    }

    func prepareReplay() {
        completed = false
        index = 0
        suspend()
    }

    func replay() {
        prepareReplay()
        resume()
    }

    /// Called before opening System Settings or a modal App surface. Never keep
    /// a tutorial panel above an OS permission/password dialog.
    func suspend() { isSuspended = true; dismissPanels() }
    func resume() {
        guard !isDismissing, !completed, !isBlockedByModalSurface else { return }
        if kind == .permissions, permissionFlow?.settingsStep != nil {
            refreshPermissionsOnReturn()
            return
        }
        isSuspended = false
        requestUpdate()
    }
    func resumeImmediately(handedOffFromIntro: Bool = false) {
        guard !isDismissing, !completed, !isBlockedByModalSurface else { return }
        if kind == .permissions, permissionFlow?.settingsStep != nil {
            refreshPermissionsOnReturn()
            return
        }
        isSuspended = false
        updatePending = false
        isHandedOffFromIntro = handedOffFromIntro
        update()
    }

    fileprivate func attach(_ view: FirstUseTourAnchorView) {
        if let target = view.target {
            if targets[target]?.view !== view { targets[target] = WeakAnchor(view) }
        } else {
            host = view
            if owner !== view.window { observe(view.window) }
        }
        guard !completed else { return }
        requestUpdate()
    }

    fileprivate func detach(_ view: FirstUseTourAnchorView) {
        if host === view {
            host = nil
            observe(nil)
            dismissPanels()
        }
        if let target = view.target, targets[target]?.view === view { targets.removeValue(forKey: target) }
    }

    private func observe(_ window: NSWindow?) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        owner = window
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestUpdate() }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissPanels() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissPanels() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let next = NSApp.keyWindow,
                      next !== self.owner, next !== self.cardPanel else { return }
                self.suspend()
            }
        })
    }

    private func requestUpdate() {
        guard !completed, !isSuspended, !isBlockedByModalSurface, !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.update()
        }
    }

    private func update() {
        // A layout update queued before opening Settings must not cancel the
        // fresh permission check that is resuming this suspended tour.
        guard !isSuspended, !isBlockedByModalSurface else { return }
        guard !completed, let host, host.enabled, let owner, owner.isVisible,
              !owner.isMiniaturized, NSApp.isActive, !NSApp.isHidden,
              let screen = owner.screen else { dismissPanels(); return }
        guard NSApp.keyWindow == nil || NSApp.keyWindow === owner || NSApp.keyWindow === cardPanel else {
            dismissPanels(); return
        }
        var step = kind.steps[index]
        if let flow = permissionFlow, flow.step != .ready, flow.access.grants(flow.step) {
            step = FirstUseTourStep(step.target, step.title,
                flow.step == .screen ? "屏幕录制已授权，无需重复设置。可以继续查看下一步。"
                    : "辅助功能已授权，无需重复设置。可以继续查看下一步。", step.symbol, side: step.side)
        }
        guard let anchor = targets[step.target]?.view, anchor.window === owner,
              anchor.bounds.width > 0, anchor.bounds.height > 0 else { return }
        let target = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screenBounds = screen.frame
        let visible = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        if cardPanel == nil {
            if kind == .permissions {
                // The permission window has already settled into place during the introduction handoff.
                // Create panels immediately without the 350ms delay to eliminate the dimmer gap.
                makePanels()
            } else {
                guard startTask == nil else { return }
                startTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard let self else { return }
                    self.startTask = nil
                    guard !self.isSuspended, !self.isBlockedByModalSurface,
                          self.host?.enabled == true, self.owner?.isVisible == true, NSApp.isActive,
                          NSApp.keyWindow == nil || NSApp.keyWindow === self.owner else { return }
                    self.makePanels()
                    self.requestUpdate()
                }
                return
            }
        }
        guard let shadePanel, let cardPanel else { return }
        let cardWidth = min(320, visible.width)
        let changedStep = lastCardIndex >= 0 && index != lastCardIndex
        if index != lastCardIndex {
            let content = FirstUseTourCard(step: step, index: index, count: kind.steps.count,
                                          onPrevious: { [weak self] in self?.move(-1) },
                                          onNext: { [weak self] in self?.move(1) },
                                          onSkip: { [weak self] in self?.finish() },
                                          primaryTitle: permissionPrimaryTitle,
                                          showsPrevious: permissionFlow?.isReview ?? true)
            cardPanel.contentView = NSHostingView(rootView: content.frame(width: cardWidth).appControlFocusAppearance())
            lastCardIndex = index
        }
        let height = max(160, cardPanel.contentView?.fittingSize.height ?? 190)
        let cardFrame = Self.cardFrame(target: target, size: CGSize(width: cardWidth, height: height), visible: visible, side: step.side)
        let maskFrame = kind == .editor ? owner.frame : screenBounds
        shadePanel.setFrame(maskFrame, display: false)
        shadePanel.contentView?.layoutSubtreeIfNeeded()
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let shade = shadePanel.contentView as? FirstUseTourShadeView {
            // Between steps the spotlight glides to its next control; window
            // moves and layout changes still track the live target exactly.
            shade.show(target: target.offsetBy(dx: -maskFrame.minX, dy: -maskFrame.minY),
                       highlight: anchor.highlight, glides: changedStep && !reducesMotion)
        }
        // Keep the real target aligned during window movement. Only a step
        // change gives the compact callout a short opacity transition.
        cardPanel.setFrame(cardFrame, display: true)
        cardPanel.contentView?.layoutSubtreeIfNeeded()
        if changedStep, !reducesMotion {
            // The callout lets the spotlight lead, then settles beside it.
            cardPanel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.3, 1)
                cardPanel.animator().alphaValue = 1
            }
        }
        shadePanel.orderFront(nil)
        cardPanel.orderFront(nil)
        if isHandedOffFromIntro {
            isHandedOffFromIntro = false
            needsEntrance = false
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                cardPanel.alphaValue = 1
            } else {
                cardPanel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    cardPanel.animator().alphaValue = 1
                }
            }
        } else if needsEntrance {
            needsEntrance = false
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                shadePanel.alphaValue = 1
                cardPanel.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    shadePanel.animator().alphaValue = 1
                    cardPanel.animator().alphaValue = 1
                }
            }
        }
        if lastTarget != target {
            cardPanel.invalidateShadow()
            lastTarget = target
        }
    }

    private func makePanels() {
        guard let owner else { return }
        let screen = owner.screen ?? NSScreen.main
        let screenBounds = screen?.frame ?? owner.frame
        let maskFrame = kind == .editor ? owner.frame : screenBounds
        let shade = NSPanel(contentRect: maskFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        shade.ignoresMouseEvents = true
        shade.hasShadow = false
        shade.contentView = FirstUseTourShadeView(frame: NSRect(origin: .zero, size: maskFrame.size))
        let card = FirstUseTourPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        card.hasShadow = true
        for (offset, panel) in [(2, shade), (3, card)] {
            panel.sharingType = .readOnly
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.level = NSWindow.Level(rawValue: owner.level.rawValue + offset)
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            panel.animationBehavior = .none
            owner.addChildWindow(panel, ordered: .above)
        }
        if isHandedOffFromIntro {
            shade.alphaValue = 1
            card.alphaValue = 0
            needsEntrance = false
        } else {
            shade.alphaValue = 0
            card.alphaValue = 0
            needsEntrance = true
        }
        shadePanel = shade; cardPanel = card
        card.onSkip = { [weak self] in self?.finish() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  event.window === self.owner || event.window === self.cardPanel else { return event }
            self.finish()
            return nil
        }
    }

    private var permissionPrimaryTitle: String? {
        guard let flow = permissionFlow else { return nil }
        switch flow.primaryAction {
        case .openSettings: return appLocalized("打开设置")
        case .advance: return appLocalized("下一步")
        case .enter: return flow.isReview ? appLocalized("完成") : appLocalized("进入 DogSC")
        }
    }

    private func move(_ direction: Int) {
        if var flow = permissionFlow {
            if direction < 0 {
                flow.previous()
            } else {
                switch flow.primaryAction {
                case let .openSettings(step):
                    permissionOpenSettings?(step)
                    return
                case .advance:
                    flow.advance()
                case .enter:
                    permissionContinue?()
                    return
                }
            }
            permissionFlow = flow
            index = flow.step.rawValue
            requestUpdate()
            return
        }
        let next = index + direction
        if next >= kind.steps.count { finish(); return }
        index = max(0, next)
        requestUpdate()
    }

    private func finish() {
        completed = true
        isSuspended = false
        UserDefaults.standard.set(true, forKey: preferenceKey)
        let restoresKey = cardPanel?.isKeyWindow == true
        dismissPanels()
        if restoresKey, NSApp.isActive, owner?.isVisible == true { owner?.makeKeyAndOrderFront(nil) }
    }

    private func dismissPanels() {
        guard !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        startTask?.cancel(); startTask = nil
        permissionReturnTask?.cancel(); permissionReturnTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let panels: [NSPanel?] = [cardPanel, shadePanel]
        for case let panel? in panels {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        cardPanel = nil; shadePanel = nil
        lastCardIndex = -1; lastTarget = .null
        isHandedOffFromIntro = false
    }

    static func cardFrame(target: CGRect, size: CGSize, visible: CGRect, side: FirstUseTourStep.Side) -> CGRect {
        let gap: CGFloat = 24
        let below = CGRect(x: target.midX - size.width / 2, y: target.minY - gap - size.height, width: size.width, height: size.height)
        let above = CGRect(x: target.midX - size.width / 2, y: target.maxY + gap, width: size.width, height: size.height)
        let left = CGRect(x: target.minX - gap - size.width, y: target.midY - size.height / 2, width: size.width, height: size.height)
        let right = CGRect(x: target.maxX + gap, y: target.midY - size.height / 2, width: size.width, height: size.height)
        let candidates: [CGRect] = switch side {
        case .below: [below, above, left, right]
        case .above: [above, below, left, right]
        case .left: [left, right, above, below]
        case .right: [right, left, above, below]
        }
        for candidate in candidates {
            let result = CGRect(x: min(max(candidate.minX, visible.minX), visible.maxX - size.width),
                                y: min(max(candidate.minY, visible.minY), visible.maxY - size.height),
                                width: size.width, height: size.height)
            if !result.intersects(target) { return result.integral }
        }
        return CGRect(x: visible.midX - size.width / 2, y: visible.minY, width: size.width, height: size.height).integral
    }
}

private final class FirstUseTourPanel: NSPanel {
    var onSkip: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onSkip?() }
}

/// The dimmer never receives input, even inside its opaque region. The live
/// permission button remains clickable; there is no synthetic forwarded click.
/// Two shape layers draw the shade and the spotlight's edge, so moving between
/// steps is a compositor animation rather than a full-screen redraw.
final class FirstUseTourShadeView: NSView {
    private let shade = CAShapeLayer()
    private let edge = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shade.fillRule = .evenOdd
        shade.fillColor = NSColor(white: 0.04, alpha: 0.48).cgColor
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.86).cgColor
        edge.lineWidth = 1.5
        layer?.addSublayer(shade)
        layer?.addSublayer(edge)
        shade.frame = bounds
        edge.frame = bounds
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        shade.frame = bounds
        edge.frame = bounds
    }

    func show(target: CGRect, highlight: FirstUseTourHighlight, glides: Bool) {
        let viewBounds = bounds.isEmpty ? CGRect(origin: .zero, size: window?.frame.size ?? .zero) : bounds
        guard !viewBounds.isEmpty else { return }
        let outline = highlight.path(in: target)
        let cover = CGMutablePath()
        cover.addRect(viewBounds)
        cover.addPath(outline)
        if glides, let previousCover = shade.path, let previousOutline = edge.path {
            for (layer, from, to) in [(shade, previousCover, cover as CGPath), (edge, previousOutline, outline)] {
                let glide = CABasicAnimation(keyPath: "path")
                glide.fromValue = layer.presentation()?.path ?? from
                glide.toValue = to
                glide.duration = 0.36
                glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1)
                layer.add(glide, forKey: "glide")
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = viewBounds
        edge.frame = viewBounds
        shade.path = cover
        edge.path = outline
        CATransaction.commit()
    }
}

struct FirstUseTourCard: View {
    let step: FirstUseTourStep
    let index: Int
    let count: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void
    var primaryTitle: String? = nil
    var showsPrevious = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: step.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(RecorderStyle.chrome.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Text(appLocalized(step.title)).font(.appUI(size: 15, weight: .semibold))
            }
            Text(appLocalized(step.detail))
                .font(.appUI(size: 13)).foregroundStyle(RecorderStyle.chrome.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                .padding(.top, 12)
            HStack(spacing: 8) {
                progress
                Spacer(minLength: 0)
                Button(action: onSkip) { Text("跳过引导").font(.appUI(size: 11)).padding(.horizontal, 6).frame(height: 30) }
                    .buttonStyle(FirstUseTourButtonStyle())
                if showsPrevious, index > 0 {
                    Button(action: onPrevious) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 30) }
                        .buttonStyle(FirstUseTourButtonStyle()).accessibilityLabel("上一步")
                }
                Button(action: onNext) {
                    HStack(spacing: 6) {
                        Text(primaryTitle ?? (index == count - 1 ? appLocalized("知道了") : appLocalized("下一步")))
                        Image(systemName: index == count - 1 ? "checkmark" : "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.appUI(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                }
                .buttonStyle(FirstUseTourButtonStyle(primary: true))
            }
            .padding(.top, 18)
        }
        .padding(18)
        .foregroundStyle(RecorderStyle.chrome.opacity(0.96))
        // The guide card follows the same appearance as its owning controls.
        .recorderSurface(radius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("首次使用引导")
    }

    /// The current step is the long mark; the count stays readable to VoiceOver.
    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(RecorderStyle.chrome.opacity(position == index ? 0.95 : 0.24))
                    .frame(width: position == index ? 16 : 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(format: appLocalized("第 %d 步，共 %d 步"), index + 1, count))
    }
}

private struct FirstUseTourButtonStyle: ButtonStyle {
    var primary = false
    @State private var hovered = false
    @FocusState private var focused: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? RecorderStyle.onPrimary : RecorderStyle.chrome.opacity(0.72))
            .background(primary ? RecorderStyle.primaryFill.opacity(configuration.isPressed ? 0.8 : hovered ? 1 : 0.94)
                        : RecorderStyle.chrome.opacity(configuration.isPressed ? 0.16 : hovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(RecorderStyle.chrome.opacity(focused ? 0.7 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .focused($focused).focusEffectDisabled()
    }
}
