import AppKit
import SwiftUI

/// Presents one reusable native settings window regardless of which DogSC
/// surface is active. The app does not own a SwiftUI WindowGroup, so relying on
/// the Settings scene's responder-chain action leaves the standard menu item
/// disabled while the editor's AppKit window is key.
@MainActor
final class AppSettingsWindowController {
    private static let contentWidth: CGFloat = 780
    private static let initialContentHeight: CGFloat = 640

    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.settings-window"
    )

    static let shared = AppSettingsWindowController()

    private var controller: NSWindowController?

    func show() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let controller = controller ?? makeController()
        let isOpening = controller.window?.isVisible != true
        if let window = controller.window, !window.isVisible, let screen {
            let height = min(Self.initialContentHeight, max(screen.visibleFrame.height - 100, 400))
            (window.contentViewController as? NSHostingController<AppSettingsView>)?.rootView = AppSettingsView(contentHeight: height)
            window.setContentSize(NSSize(width: Self.contentWidth, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            let bounds = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: bounds.midX - window.frame.width / 2,
                                          y: bounds.midY - window.frame.height / 2))
        }
        self.controller = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        if isOpening { controller.window?.makeFirstResponder(nil) }
        // A menu command closes its NSMenu after the action returns, and that
        // dismissal can immediately hand key status back to the recorder bar.
        // Promote settings on the next main-loop turn so the requested window,
        // not the tiny source panel, is ready for typing and keyboard control.
        DispatchQueue.main.async { [weak controller] in
            guard let window = controller?.window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            // Clear only the opening-time automatic first button proposal.
            // Reopening an already visible window must preserve text/Tab focus.
            if isOpening { window.makeFirstResponder(nil) }
        }
    }

    func hideForFirstLaunchGuide() {
        controller?.window?.orderOut(nil)
    }

    private func makeController() -> NSWindowController {
        let applicationName = AppIdentity.displayName
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: Self.initialContentHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(
            rootView: AppSettingsView()
        )
        window.identifier = Self.windowIdentifier
        window.title = "\(applicationName) \(appLocalized("设置"))"
        window.contentViewController = hostingController
        window.appearance = AppPreferences.appearancePreference.appKitAppearance
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        // Settings is an explicit user action, not a launch-restorable surface.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        // The setup recorder is intentionally a floating HUD. A normal-level
        // settings window therefore opens behind it and the HUD covers the
        // lower storage controls. Keep settings in the same app-local band;
        // the deferred order-front in show() then places the requested window
        // above the idle recorder without outranking active recording controls.
        window.level = .floating
        window.contentMinSize = NSSize(width: Self.contentWidth, height: 400)
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: 640)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        return NSWindowController(window: window)
    }

}
