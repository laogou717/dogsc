import AppKit
import SwiftUI

/// Presents one reusable native settings window regardless of which DogSC
/// surface is active. The app does not own a SwiftUI WindowGroup, so relying on
/// the Settings scene's responder-chain action leaves the standard menu item
/// disabled while the editor's AppKit window is key.
@MainActor
final class AppSettingsWindowController {
    private static let contentWidth: CGFloat = 560
    private static let initialContentHeight: CGFloat = 600

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
            let height = min(Self.initialContentHeight, max(screen.visibleFrame.height - 100, 420))
            (window.contentViewController as? NSHostingController<AppSettingsView>)?.rootView = AppSettingsView(contentHeight: height, navigation: navigation)
            window.setContentSize(NSSize(width: Self.contentWidth, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            let bounds = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: bounds.midX - window.frame.width / 2,
                                          y: bounds.midY - window.frame.height / 2))
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
        let hostingController = NSHostingController(
            rootView: AppSettingsView(navigation: navigation)
        )
        window.identifier = Self.windowIdentifier
        window.title = "\(applicationName) \(appLocalized("设置"))"
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
        window.contentMinSize = NSSize(width: Self.contentWidth, height: 420)
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: Self.initialContentHeight)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        return NSWindowController(window: window)
    }

}
