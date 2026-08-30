import AppKit
import SwiftUI

/// Presents one reusable native settings window regardless of which DogSC
/// surface is active. The app does not own a SwiftUI WindowGroup, so relying on
/// the Settings scene's responder-chain action leaves the standard menu item
/// disabled while the editor's AppKit window is key.
@MainActor
final class AppSettingsWindowController {
    private static let contentWidth: CGFloat = 620
    private static let initialContentHeight: CGFloat = 370

    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.settings-window"
    )

    private var controller: NSWindowController?

    func show() {
        let controller = controller ?? makeController()
        self.controller = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        // A menu command closes its NSMenu after the action returns, and that
        // dismissal can immediately hand key status back to the recorder bar.
        // Promote settings on the next main-loop turn so the requested window,
        // not the tiny source panel, is ready for typing and keyboard control.
        DispatchQueue.main.async { [weak controller] in
            controller?.window?.makeKeyAndOrderFront(nil)
        }
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
            rootView: AppSettingsView { [weak window] preferredHeight in
                Self.resize(window, toContentHeight: preferredHeight)
            }
        )
        window.identifier = Self.windowIdentifier
        window.title = "\(applicationName) 设置"
        window.contentViewController = hostingController
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            calibratedRed: 0.071,
            green: 0.074,
            blue: 0.079,
            alpha: 1
        )
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        // The setup recorder is intentionally a floating HUD. A normal-level
        // settings window therefore opens behind it and the HUD covers the
        // lower storage controls. Keep settings in the same app-local band;
        // the deferred order-front in show() then places the requested window
        // above the idle recorder without outranking active recording controls.
        window.level = .floating
        window.contentMinSize = NSSize(width: Self.contentWidth, height: 330)
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: 440)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        return NSWindowController(window: window)
    }

    private static func resize(_ window: NSWindow?, toContentHeight height: CGFloat) {
        guard let window else { return }
        let clampedHeight = min(max(height, 330), 440)
        let currentFrame = window.frame
        var contentRect = window.contentRect(forFrameRect: currentFrame)
        contentRect.size = NSSize(width: contentWidth, height: clampedHeight)

        var targetFrame = window.frameRect(forContentRect: contentRect)
        targetFrame.origin.x = currentFrame.origin.x
        targetFrame.origin.y = currentFrame.maxY - targetFrame.height
        guard targetFrame != currentFrame else { return }
        window.setFrame(targetFrame, display: true, animate: window.isVisible)
    }
}
