import AppKit
import SwiftUI

// MARK: - Design Tokens (Soft Silver / Graphite)

public enum EditorTheme {
    // The media remains colour-accurate while workspace chrome follows the
    // selected Aqua appearance. Dynamic NSColor providers also update panels
    // already on screen when the user changes appearance in Settings.
    public static let backgroundDeep = adaptive(
        light: NSColor(calibratedRed: 0.952, green: 0.960, blue: 0.963, alpha: 1),
        dark: NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.051, alpha: 1)
    )
    public static let panelSurface = adaptive(
        light: NSColor(calibratedRed: 0.980, green: 0.984, blue: 0.986, alpha: 1),
        dark: NSColor(calibratedRed: 0.071, green: 0.074, blue: 0.079, alpha: 1)
    )
    public static let sleepingMonitor = adaptive(
        light: NSColor(calibratedWhite: 0.79, alpha: 1),
        dark: NSColor(calibratedWhite: 0.24, alpha: 1)
    )
    public static let panelRaised = adaptive(
        light: NSColor(calibratedWhite: 0.953, alpha: 1),
        dark: NSColor(calibratedRed: 0.092, green: 0.095, blue: 0.101, alpha: 1)
    )
    public static let cardElevated = adaptive(
        light: NSColor(calibratedWhite: 0.998, alpha: 1),
        dark: NSColor(calibratedRed: 0.112, green: 0.115, blue: 0.122, alpha: 1)
    )
    public static let timelineClipTop = adaptive(
        light: NSColor(calibratedWhite: 0.88, alpha: 1),
        dark: NSColor(calibratedWhite: 0.22, alpha: 1)
    )
    public static let timelineClipBottom = adaptive(
        light: NSColor(calibratedWhite: 0.83, alpha: 1),
        dark: NSColor(calibratedWhite: 0.17, alpha: 1)
    )
    public static let timelineZoomSurface = adaptive(
        light: NSColor(calibratedRed: 0.87, green: 0.79, blue: 0.66, alpha: 1),
        dark: NSColor(calibratedRed: 0.47, green: 0.39, blue: 0.28, alpha: 1)
    )
    public static let recorderSurface = panelSurface
    public static let mediaAccent = Color(red: 0.949, green: 0.941, blue: 0.918)

    public static let platinumAccent = adaptive(
        light: NSColor(calibratedWhite: 0.16, alpha: 1),
        dark: NSColor(calibratedRed: 0.949, green: 0.941, blue: 0.918, alpha: 1)
    )
    public static let platinumMuted = adaptive(
        light: NSColor(calibratedWhite: 0.34, alpha: 1),
        dark: NSColor(calibratedRed: 0.72, green: 0.71, blue: 0.68, alpha: 1)
    )
    /// Foreground paired with solid accent fills in both workspace themes.
    public static let onAccent = adaptive(
        light: NSColor(calibratedWhite: 0.99, alpha: 1),
        dark: NSColor(calibratedWhite: 0.08, alpha: 1)
    )
    public static let controlWell = adaptive(
        light: NSColor(calibratedWhite: 0.90, alpha: 1),
        dark: NSColor(calibratedWhite: 0.055, alpha: 1)
    )
    public static let amberAccent = Color(red: 0.93, green: 0.65, blue: 0.28)
    public static let success = Color(red: 0.37, green: 0.80, blue: 0.57)
    public static let recording = Color(red: 1.0, green: 0.31, blue: 0.29)

    public static let selectionTint = platinumAccent
    public static let railSelectionWash = adaptive(
        light: NSColor(calibratedRed: 0.86, green: 0.95, blue: 0.90, alpha: 1),
        dark: NSColor(calibratedRed: 0.14, green: 0.24, blue: 0.19, alpha: 1)
    )
    public static let selectionWash = adaptive(
        light: NSColor(calibratedWhite: 0.92, alpha: 1),
        dark: NSColor(calibratedWhite: 0.20, alpha: 1)
    )
    public static let hairline = chrome(0.055)
    static let controlBorder = chrome(0.085)
    static let groupSurface = chrome(0.028)
    // Native popovers own their brighter backdrop, including the arrow. Keep
    // selection relative to that surface and small helper copy fully legible.
    static let popoverSelectionSurface = selectionWash.opacity(0.32)
    static let popoverSecondaryText = adaptive(
        light: NSColor(calibratedWhite: 0.32, alpha: 1),
        dark: NSColor(calibratedWhite: 0.86, alpha: 1)
    )
    public static let topHighlight = chrome(0.16)
    public static let softShadow = adaptive(
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.black.withAlphaComponent(0.22)
    )

    /// Text roles stay readable on the neutral control and panel surfaces.
    /// Opacity remains useful for decoration, but not for small helper copy.
    static let primaryText = adaptive(
        light: NSColor(calibratedWhite: 0.16, alpha: 1),
        dark: NSColor(calibratedWhite: 0.91, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(calibratedWhite: 0.38, alpha: 1),
        dark: NSColor(calibratedWhite: 0.69, alpha: 1)
    )

    /// Foreground/border ink for chrome. Media-overlay controls intentionally
    /// keep their explicit white/black colours and do not use this token.
    public static func chrome(_ opacity: Double = 1) -> Color {
        adaptive(light: .black, dark: .white).opacity(opacity)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
        })
    }
}

/// A close type scale keeps a tool dense without giving every label the
/// weight of a heading. PuHui remains the single interface font family.
enum EditorTypography {
    static var panelTitle: Font { .appUI(size: 16, weight: .semibold) }
    static var sectionTitle: Font { .appUI(size: 14, weight: .semibold) }
    static var controlLabel: Font { .appUI(size: 13, weight: .medium) }
    static var controlValue: Font { .appUI(size: 13, weight: .medium) }
    static var helper: Font { .appUI(size: 12) }
    static var caption: Font { .appUI(size: 11, weight: .medium) }
}

enum EditorInterfaceSpacing {
    static let inspectorInset: CGFloat = 20
    static let sectionGap: CGFloat = 20
    static let controlGap: CGFloat = 12
    static let headingGap: CGFloat = 8
}

/// Radii describe nesting roles rather than individual screens. Small controls
/// sit inside groups; only detached workspace surfaces carry the largest curve.
enum EditorInterfaceRadius {
    static let compact: CGFloat = 8
    static let control: CGFloat = 10
    static let group: CGFloat = 12
    static let card: CGFloat = 16
    static let floating: CGFloat = 20
}

enum EditorInterfaceHeight {
    static let compact: CGFloat = 32
    static let selection: CGFloat = 34
    static let action: CGFloat = 42
}

// MARK: - Product Motion

public enum SpringMotion {
    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Short, tactile springs are used for controls; larger panels use a more
    /// settled spring. Reduce Motion still removes spatial transitions.
    public static var interactive: Animation? {
        reducesMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72)
    }

    public static var fluid: Animation? {
        reducesMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)
    }

    /// Text changes fade briefly without scaling glyphs or moving their baseline.
    public static var crossfade: Animation? {
        reducesMotion ? nil : .easeOut(duration: 0.16)
    }

    public static var snappy: Animation? {
        reducesMotion ? nil : .spring(response: 0.18, dampingFraction: 0.68)
    }

    public static var gentle: Animation? {
        reducesMotion ? nil : .spring(response: 0.52, dampingFraction: 0.88)
    }
}
