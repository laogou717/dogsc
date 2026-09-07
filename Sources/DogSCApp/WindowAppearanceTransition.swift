import AppKit
import QuartzCore

/// Fade the composited window contents as one surface. Animating only SwiftUI
/// colours misses native scroll views and dynamic NSColor-backed controls.
@MainActor
enum WindowAppearanceTransition {
    private static let animationKey = "dogsc.appearance.crossfade"

    static func apply(_ appearance: NSAppearance?, to window: NSWindow) {
        let names: [NSAppearance.Name] = [.darkAqua, .aqua]
        let previous = window.effectiveAppearance.bestMatch(from: names)
        let next = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: names)
        let shouldAnimate = previous != next
            && NSApp.isActive && !NSApp.isHidden
            && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard shouldAnimate, let content = window.contentView else {
            window.appearance = appearance
            return
        }

        content.wantsLayer = true
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()

        CATransaction.begin()
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.32
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Reusing the key replaces an in-flight fade on a rapid second click.
        // No hit-testing overlay, screenshot permission or rendering timer.
        content.layer?.add(fade, forKey: animationKey)
        window.appearance = appearance
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        CATransaction.commit()
    }
}
