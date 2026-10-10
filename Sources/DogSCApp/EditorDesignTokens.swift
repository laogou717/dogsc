import AppKit
import SwiftUI

// MARK: - Design Tokens (Soft Silver / Graphite)

public enum EditorTheme {
    // The media remains colour-accurate while workspace chrome follows the
    // selected Aqua appearance. Dynamic NSColor providers also update panels
    // already on screen when the user changes appearance in Settings.
    public static let backgroundDeep = adaptive(
        light: NSColor(calibratedRed: 0.925, green: 0.929, blue: 0.937, alpha: 1),
        dark: NSColor(calibratedRed: 0.028, green: 0.029, blue: 0.033, alpha: 1)
    )
    public static let panelSurface = adaptive(
        light: NSColor(calibratedRed: 0.992, green: 0.992, blue: 0.996, alpha: 1),
        dark: NSColor(calibratedRed: 0.063, green: 0.065, blue: 0.072, alpha: 1)
    )
    public static let sleepingMonitor = adaptive(
        light: NSColor(calibratedWhite: 0.79, alpha: 1),
        dark: NSColor(calibratedWhite: 0.24, alpha: 1)
    )
    public static let panelRaised = adaptive(
        light: NSColor(calibratedRed: 0.952, green: 0.954, blue: 0.960, alpha: 1),
        dark: NSColor(calibratedRed: 0.096, green: 0.098, blue: 0.106, alpha: 1)
    )
    /// The island: every floating tool surface shares the recorder's base.
    public static let cardElevated = adaptive(
        light: NSColor(calibratedRed: 0.992, green: 0.992, blue: 0.996, alpha: 1),
        dark: NSColor(calibratedRed: 0.063, green: 0.065, blue: 0.072, alpha: 1)
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
        light: NSColor(calibratedWhite: 0.10, alpha: 1),
        dark: NSColor(calibratedWhite: 0.96, alpha: 1)
    )
    public static let platinumMuted = adaptive(
        light: NSColor(calibratedWhite: 0.40, alpha: 1),
        dark: NSColor(calibratedWhite: 0.56, alpha: 1)
    )
    /// Foreground paired with solid accent fills in both workspace themes.
    public static let onAccent = adaptive(
        light: NSColor(calibratedWhite: 0.99, alpha: 1),
        dark: NSColor(calibratedWhite: 0.08, alpha: 1)
    )
    public static let controlWell = adaptive(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.05),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06)
    )
    public static let amberAccent = Color(red: 0.95, green: 0.68, blue: 0.28)
    /// Same mint as the recorder: something is live or on.
    public static let success = Color(red: 0.30, green: 0.85, blue: 0.55)
    public static let recording = Color(red: 1.0, green: 0.27, blue: 0.23)

    public static let selectionTint = platinumAccent
    /// Current choice in a navigation group: the recorder's neutral 14% lift.
    public static let railSelectionWash = adaptive(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.075),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.14)
    )
    public static let selectionWash = adaptive(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.075),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.14)
    )
    public static let hairline = chrome(0.06)
    static let controlBorder = chrome(0.085)
    static let groupSurface = chrome(0.035)
    // Native popovers own their brighter backdrop, including the arrow. Keep
    // selection relative to that surface and small helper copy fully legible.
    static let popoverSelectionSurface = selectionWash.opacity(0.6)
    static let popoverSecondaryText = adaptive(
        light: NSColor(calibratedWhite: 0.32, alpha: 1),
        dark: NSColor(calibratedWhite: 0.86, alpha: 1)
    )
    /// The machined top edge of an island, fading toward the bottom.
    public static let topHighlight = adaptive(
        light: NSColor(calibratedWhite: 1.0, alpha: 1.0),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.17)
    )
    static let islandEdgeLow = adaptive(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.07),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.04)
    )
    public static let softShadow = adaptive(
        light: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 0.12),
        dark: NSColor.black.withAlphaComponent(0.42)
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

    /// Controls settle quickly with almost no overshoot; a visible bounce on
    /// every hover and press reads as a toy. Larger panels take a slower,
    /// fully settled spring. Reduce Motion still removes spatial transitions.
    public static var interactive: Animation? {
        reducesMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86)
    }

    public static var fluid: Animation? {
        reducesMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)
    }

    /// Text changes fade briefly without scaling glyphs or moving their baseline.
    public static var crossfade: Animation? {
        reducesMotion ? nil : .easeOut(duration: 0.16)
    }

    public static var snappy: Animation? {
        reducesMotion ? nil : .spring(response: 0.2, dampingFraction: 0.84)
    }

    public static var gentle: Animation? {
        reducesMotion ? nil : .spring(response: 0.54, dampingFraction: 0.92)
    }
}
