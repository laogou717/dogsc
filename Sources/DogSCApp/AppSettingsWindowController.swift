import AppKit
import SwiftUI

/// Presents one reusable native settings window regardless of which DogSC
/// surface is active. The app does not own a SwiftUI WindowGroup, so relying on
/// the Settings scene's responder-chain action leaves the standard menu item
/// disabled while the editor's AppKit window is key.
@MainActor
final class AppSettingsWindowController {
    static let contentWidth: CGFloat = 820
    static let contentHeight: CGFloat = 560
    private static let maximumContentHeight: CGFloat = 560
    private static let initialContentHeight: CGFloat = 560

    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.settings-window"
    )

    static let shared = AppSettingsWindowController()

    private var controller: NSWindowController?
    private let navigation = AppSettingsNavigation()
    private var activationObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var clearsInitialFocus = false
    private var presentationRequest = 0
    private var pendingPresentation: Int?
    private var lastPreferredHeight: CGFloat?
    private var heightAnimation: WindowHeightSpring?

    private init() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let closedWindowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.controller?.window,
                      closedWindowID == ObjectIdentifier(window) else { return }
                self.pendingPresentation = nil
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let request = self.pendingPresentation else { return }
                self.finishPresentation(request: request)
            }
        }
    }

    private func finishPresentation(request: Int) {
        // Activation and the menu's dismissal are separate AppKit events.
        // Finish after both, without a guessed delay or a floating window level.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPresentation == request, NSApp.isActive,
                  let window = self.controller?.window else { return }
            self.pendingPresentation = nil
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            if self.clearsInitialFocus { window.makeFirstResponder(nil) }
            self.clearsInitialFocus = false
        }
    }

    func show(section: AppSettingsSection? = nil) {
        if let section { navigation.selectedSection = section }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let controller = controller ?? makeController()
        let isOpening = controller.window?.isVisible != true
        if let window = controller.window, !window.isVisible, let screen {
            heightAnimation?.stop()
            let limit = min(Self.maximumContentHeight, max(screen.visibleFrame.height - 100, 420))
            let height = min(lastPreferredHeight ?? Self.initialContentHeight, limit)
            (window.contentViewController as? NSHostingController<AppSettingsView>)?.rootView = makeRootView(maximumHeight: limit)
            window.setContentSize(NSSize(width: Self.contentWidth, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            let bounds = screen.visibleFrame
            // Centre a typical page; later pages grow and shrink from the top edge.
            let typical = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 560)).height
            window.setFrameOrigin(NSPoint(x: bounds.midX - window.frame.width / 2,
                                          y: bounds.midY + typical / 2 - window.frame.height))
        }
        self.controller = controller
        presentationRequest += 1
        let request = presentationRequest
        pendingPresentation = request
        clearsInitialFocus = isOpening
        controller.showWindow(nil)
        if isOpening { controller.window?.makeFirstResponder(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        finishPresentation(request: request)

    }

    func hideForFirstLaunchGuide() {
        pendingPresentation = nil
        controller?.window?.orderOut(nil)
    }

    private func makeController() -> NSWindowController {
        let applicationName = AppIdentity.displayName
        let window = EscapeDismissibleWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: Self.initialContentHeight
            ),
            // The floating navigation leaves the native window buttons above it.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(rootView: makeRootView(maximumHeight: Self.maximumContentHeight))
        // The window height follows the page island, driven below; the
        // hosting controller must not impose its own size limits.
        hostingController.sizingOptions = []
        window.identifier = Self.windowIdentifier
        appLocalizeWindowTitle(window, "设置", prefix: applicationName)
        window.contentViewController = hostingController
        window.appearance = nil
        window.backgroundColor = RecorderStyle.canvasNSColor
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        // Settings is an explicit user action, not a launch-restorable surface.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        // Settings follows ordinary app-window ordering. It must not pin
        // itself above the desktop or other apps when the user switches away.
        window.level = .normal
        window.hidesOnDeactivate = true
        window.contentMinSize = NSSize(width: Self.contentWidth, height: 240)
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: Self.maximumContentHeight)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        return NSWindowController(window: window)
    }

    private func makeRootView(maximumHeight: CGFloat) -> AppSettingsView {
        AppSettingsView(contentHeight: maximumHeight, navigation: navigation) { [weak self] height in
            self?.followContentHeight(height)
        }
    }

    /// Keeps the window exactly as tall as the page needs. Visible changes
    /// travel on the island's morph spring with the top edge held in place.
    private func followContentHeight(_ height: CGFloat) {
        guard let window = controller?.window else { return }
        let target = min(max(height, 240), Self.maximumContentHeight).rounded()
        lastPreferredHeight = target
        guard window.isVisible, !RecorderMotion.reduces else {
            heightAnimation?.stop()
            WindowHeightSpring.apply(target, to: window, width: Self.contentWidth)
            return
        }
        if let heightAnimation, heightAnimation.isRunning {
            heightAnimation.retarget(target)
        } else {
            let current = window.contentRect(forFrameRect: window.frame).height
            guard abs(current - target) > 0.5 else { return }
            let spring = WindowHeightSpring(window: window, width: Self.contentWidth, from: current, to: target)
            heightAnimation = spring
            spring.start()
        }
    }
}

/// Samples RecorderMotion's morph spring on a frame timer and applies it to
/// the window's content height, anchored to the top edge. A new target
/// continues from the current height and velocity, so interruptions stay smooth.
@MainActor
private final class WindowHeightSpring {
    private weak var window: NSWindow?
    private let width: CGFloat
    private let spring = RecorderMotion.morphSpring
    private var from: CGFloat
    private var to: CGFloat
    private var initialVelocity: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?
    var isRunning: Bool { timer != nil }

    init(window: NSWindow, width: CGFloat, from: CGFloat, to: CGFloat) {
        self.window = window
        self.width = width
        self.from = from
        self.to = to
    }

    func start() {
        startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func retarget(_ target: CGFloat) {
        guard abs(target - to) > 0.5 else { return }
        let elapsed = CACurrentMediaTime() - startTime
        let current = from + spring.value(target: to - from, initialVelocity: initialVelocity, time: elapsed)
        initialVelocity = spring.velocity(target: to - from, initialVelocity: initialVelocity, time: elapsed)
        from = current
        to = target
        startTime = CACurrentMediaTime()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let window else { stop(); return }
        let elapsed = CACurrentMediaTime() - startTime
        if elapsed >= spring.settlingDuration {
            Self.apply(to, to: window, width: width)
            stop()
            return
        }
        let height = from + spring.value(target: to - from, initialVelocity: initialVelocity, time: elapsed)
        Self.apply(height, to: window, width: width)
    }

    static func apply(_ height: CGFloat, to window: NSWindow, width: CGFloat) {
        let top = window.frame.maxY
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.origin.x = window.frame.minX
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }
}
