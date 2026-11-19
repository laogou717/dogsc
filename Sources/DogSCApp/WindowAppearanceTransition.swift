import AppKit
import QuartzCore

/// Fade the composited window contents as one surface. Animating only SwiftUI
/// colours misses native scroll views and dynamic NSColor-backed controls.
@MainActor
enum WindowAppearanceTransition {
    static func apply(_ appearance: NSAppearance?, to window: NSWindow) {
        let names: [NSAppearance.Name] = [.darkAqua, .aqua]
        let previous = window.effectiveAppearance.bestMatch(from: names)
        let next = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: names)
        let shouldAnimate = previous != next
            && NSApp.isActive && !NSApp.isHidden
            && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard shouldAnimate else {
            window.appearance = appearance
            return
        }
        crossfade(window, duration: 0.34) {
            window.appearance = appearance
        }
    }

    /// Dissolves the window from its current pixels into whatever the next
    /// state change draws. A frozen snapshot covers the window while SwiftUI,
    /// AppKit layers and asynchronous canvases all redraw underneath; only
    /// once they have settled does the snapshot fade away, so nothing pops
    /// in late or flashes through a half-updated layout.
    static func crossfade(_ window: NSWindow?, duration: TimeInterval = 0.26, change: () -> Void) {
        crossfade(window, duration: duration, waitsForPreviewFrame: false, change: change)
    }

    /// Notified by the preview surface each time it presents a frame; a
    /// crossfade that waits for the preview fades only after that.
    static func previewFramePresented() {
        let waiting = pendingReveals
        pendingReveals.removeAll()
        waiting.forEach { $0() }
    }

    private static var pendingReveals: [() -> Void] = []

    /// `waitsForPreviewFrame`: hold the snapshot until the Metal preview
    /// has presented a frame of the new state (crop enter/exit rebuilds a
    /// 5K frame, which can take longer than the fixed beat), capped at
    /// 0.6 s so nothing can stay frozen.
    static func crossfade(_ window: NSWindow?, duration: TimeInterval = 0.26,
                          waitsForPreviewFrame: Bool, change: () -> Void) {
        guard let window, let frameView = window.contentView,
              window.isVisible, window.occlusionState.contains(.visible),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let snapshot = WindowSnapshotView(capturing: frameView) else {
            change()
            return
        }
        frameView.addSubview(snapshot, positioned: .above, relativeTo: nil)
        change()
        var revealed = false
        let reveal = {
            guard !revealed else { return }
            revealed = true
            // One more beat so SwiftUI overlays (veil, handles) commit too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                    snapshot.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { snapshot.removeFromSuperview() }
                }
            }
        }
        if waitsForPreviewFrame {
            // Skip frames already in flight for the old state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                guard !revealed else { return }
                pendingReveals.append(reveal)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reveal() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { reveal() }
        }
    }
}

/// A frozen picture of the window that never takes clicks. The window
/// server already holds the composited pixels (including Metal canvases), so
/// copying them is near-instant; redrawing the view tree into a bitmap on the
/// main thread is the slow path and only a fallback.
private final class WindowSnapshotView: NSImageView {
    init?(capturing view: NSView) {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let image: NSImage
        if let window = view.window, let cgImage = Self.windowServerImage(of: window) {
            image = NSImage(cgImage: cgImage, size: bounds.size)
        } else {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            view.cacheDisplay(in: bounds, to: rep)
            image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
        }
        super.init(frame: bounds)
        self.image = image
        imageScaling = .scaleAxesIndependently
        autoresizingMask = [.width, .height]
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private typealias WindowImageFunction = @convention(c) (
        CGRect, UInt32, UInt32, UInt32
    ) -> Unmanaged<CGImage>?

    /// Looked up at run time: the call is still the fastest way to copy one
    /// window's own pixels, and needs no capture session or async hop.
    private static let windowImageFunction: WindowImageFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImageFunction.self)
    }()

    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        guard let capture = windowImageFunction else { return nil }
        // .null bounds = the window's own frame; option 1<<3 = including
        // window; image option 1<<0 = ignore framing (no shadow).
        return capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }
}
