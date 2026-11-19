import AppKit
import SwiftUI

// MARK: - Design Tokens (Soft Silver / Graphite)

public enum EditorTheme {
    // Warm neutral palette (DogSC redesign, 2026-10-31). The ground the
    // canvas stands on is the deepest layer, panels sit one step above it and
    // raised things (popovers, segmented thumbs) are lightest. One accent:
    // export, the playhead and keyboard focus.
    public static let backgroundDeep = adaptive(
        light: NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.941, alpha: 1),
        dark: NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.102, alpha: 1)
    )
    public static let panelSurface = adaptive(
        light: NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.137, green: 0.137, blue: 0.133, alpha: 1)
    )
    public static let panelRaised = adaptive(
        light: NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(calibratedRed: 0.176, green: 0.176, blue: 0.169, alpha: 1)
    )
    public static let cardElevated = adaptive(
        light: NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(calibratedRed: 0.176, green: 0.176, blue: 0.169, alpha: 1)
    )
    static let cardTop = adaptive(
        light: NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.137, green: 0.137, blue: 0.133, alpha: 1)
    )
    static let cardBottom = adaptive(
        light: NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.137, green: 0.137, blue: 0.133, alpha: 1)
    )
    static let chromeBar = adaptive(
        light: NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.137, green: 0.137, blue: 0.133, alpha: 1)
    )
    /// The stage the canvas stands on.
    static let stage = adaptive(
        light: NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.941, alpha: 1),
        dark: NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.102, alpha: 1)
    )
    static var cardGradient: LinearGradient {
        LinearGradient(colors: [cardTop, cardBottom], startPoint: .top, endPoint: .bottom)
    }
    static let stageLight = Color.clear
    static let stageVignette = Color.clear
    static let accentGlow = Color.clear
    /// The one accent: export, the playhead, keyboard focus.
    public static let accent = adaptive(
        light: NSColor(calibratedRed: 0.769, green: 0.388, blue: 0.247, alpha: 1),
        dark: NSColor(calibratedRed: 0.855, green: 0.478, blue: 0.322, alpha: 1)
    )
    /// Text on the accent.
    public static let onAccentFill = adaptive(
        light: NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.102, alpha: 1)
    )
    /// Ink used for solid controls (play, switches on, slider fill).
    public static let platinumAccent = adaptive(
        light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 1),
        dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 1)
    )
    static let platinumAccentDeep = platinumAccent
    static var platinumGradient: LinearGradient {
        LinearGradient(colors: [platinumAccent, platinumAccent], startPoint: .top, endPoint: .bottom)
    }
    static let timelineZoomAccent = EditorConsole.Track.zoom.stroke
    public static let mediaAccent = Color(red: 0.945, green: 0.945, blue: 0.937)
    public static let platinumMuted = adaptive(
        light: NSColor(calibratedRed: 0.408, green: 0.404, blue: 0.392, alpha: 1),
        dark: NSColor(calibratedRed: 0.639, green: 0.635, blue: 0.620, alpha: 1)
    )
    /// Foreground on ink-filled controls.
    public static let onAccent = adaptive(
        light: NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.102, alpha: 1)
    )
    public static let controlWell = adaptive(
        light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 0.05),
        dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 0.055)
    )
    /// The raised plate of the current choice in a segmented track.
    public static let segmentThumb = adaptive(
        light: NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(calibratedRed: 0.227, green: 0.227, blue: 0.220, alpha: 1)
    )
    public static let amberAccent = Color(red: 0.85, green: 0.58, blue: 0.24)
    public static let success = Color(red: 0.31, green: 0.54, blue: 0.36)
    public static let recording = Color(red: 0.85, green: 0.28, blue: 0.23)

    /// Selection outlines use the same terracotta throughout the editor.
    /// Ink-filled controls and the unselected timeline retain their neutral palette.
    public static let selectionTint = accent
    public static let selectionWash = adaptive(
        light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 0.08),
        dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 0.1)
    )
    public static let hairline = chrome(0.08)
    static let groupSurface = chrome(0.035)
    static let cardFill = chrome(0.04)
    static let popoverSecondaryText = adaptive(
        light: NSColor(calibratedRed: 0.408, green: 0.404, blue: 0.392, alpha: 1),
        dark: NSColor(calibratedRed: 0.639, green: 0.635, blue: 0.620, alpha: 1)
    )
    public static let topHighlight = Color.clear
    static let sliderRail = chrome(0.08)
    static let sliderInk = adaptive(
        light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 1),
        dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 1)
    )
    static let sliderThumb = adaptive(
        light: NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(calibratedRed: 0.953, green: 0.953, blue: 0.945, alpha: 1)
    )
    static let islandOutline = adaptive(
        light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 0.08),
        dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 0.08)
    )
    static let contactShadow = adaptive(
        light: NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.06),
        dark: NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.5)
    )
    public static let softShadow = adaptive(
        light: NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.1),
        dark: NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.45)
    )
    static let ambientShadow = adaptive(
        light: NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.06),
        dark: NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.3)
    )
    static let primaryText = adaptive(
        light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 1),
        dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(calibratedRed: 0.408, green: 0.404, blue: 0.392, alpha: 1),
        dark: NSColor(calibratedRed: 0.639, green: 0.635, blue: 0.620, alpha: 1)
    )
    static let tertiaryText = adaptive(
        light: NSColor(calibratedRed: 0.600, green: 0.596, blue: 0.580, alpha: 1),
        dark: NSColor(calibratedRed: 0.459, green: 0.455, blue: 0.443, alpha: 1)
    )
    static let destructiveText = adaptive(
        light: NSColor(calibratedRed: 0.706, green: 0.251, blue: 0.173, alpha: 1),
        dark: NSColor(calibratedRed: 0.878, green: 0.439, blue: 0.357, alpha: 1)
    )

    /// Ink for chrome at an opacity: warm, never pure black or white.
    public static func chrome(_ opacity: Double = 1) -> Color {
        adaptive(
            light: NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.106, alpha: 1),
            dark: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.914, alpha: 1)
        ).opacity(opacity)
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
/// One set of state washes for every flat control: hover lifts the same
/// amount everywhere, press a little more, an open menu trigger in between.
enum EditorStateWash {
    static let hover: Double = 0.07
    static let open: Double = 0.1
    static let pressed: Double = 0.12
}

/// Editor text uses five sizes: 10 micro (badges, axes), 11 caption,
/// 12 label, 13 body, and headings from 14 up. Values use monospaced digits.
enum EditorTypography {
    /// Inspector page titles: the largest type in the panels.
    static var display: Font { .appUI(size: 20, weight: .semibold) }
    static var pageTitle: Font { .appUI(size: 15, weight: .semibold) }
    static var sectionTitle: Font { .appUI(size: 13, weight: .semibold) }
    static var controlLabel: Font { .appUI(size: 12) }
    static var controlValue: Font { .appUI(size: 12, weight: .medium).monospacedDigit() }
    static var helper: Font { .appUI(size: 11) }
    static var caption: Font { .appUI(size: 11, weight: .medium) }
    /// Small section captions: quiet, never competing with values.
    static var eyebrow: Font { .appUI(size: 11, weight: .medium) }
}

enum EditorInterfaceSpacing {
    static let inspectorInset: CGFloat = 16
    static let sectionGap: CGFloat = 16
    static let controlGap: CGFloat = 8
    /// Content inset inside a settings-style tile.
    static let tileInset: CGFloat = 12
}

/// Radii describe nesting roles rather than individual screens. Small controls
/// sit inside groups; only detached workspace surfaces carry the largest curve.
enum EditorInterfaceRadius {
    static let mark: CGFloat = 4
    static let compact: CGFloat = 6
    static let control: CGFloat = 6
    static let group: CGFloat = 10
    static let card: CGFloat = 10
    static let floating: CGFloat = 10
    /// Settings-style tiles holding a group of controls.
    static let tile: CGFloat = 10
}

enum EditorInterfaceHeight {
    static let inline: CGFloat = 24
    static let compact: CGFloat = 28
    static let selection: CGFloat = 28
    static let toolbar: CGFloat = 32
}

// MARK: - Product Motion

/// The editor has four motions. Everything else is instant: drags, hover
/// follow, the playhead, timeline zoom and canvas resizing never animate.
/// The legacy names below all resolve to one of the four so every call site
/// shares the same feel.
public enum SpringMotion {
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Hover and press colour: 0.12 s.
    public static var micro: Animation {
        reducesMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
    }
    /// Selection thumbs, position and size changes, disclosure.
    public static var standard: Animation? {
        reducesMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.24)
    }
    /// Panels and popovers arriving.
    public static var emphasis: Animation? {
        reducesMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.28)
    }
    /// A page pushed onto or popped from the inspector stack: 240 ms, one
    /// decelerating curve, no spring.
    public static var panel: Animation? {
        reducesMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.24)
    }
    /// The canvas changing shape (ratio, orientation): one decelerating
    /// 320 ms curve with no overshoot. The stage samples `canvasMorphCurve`
    /// itself, frame by frame; SwiftUI chrome that moves with it (the
    /// orientation thumb, the preset list) uses `canvasMorph` so both land
    /// together.
    static let canvasMorphDuration: TimeInterval = 0.32
    static let canvasMorphCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.2, y: 0),
        endControlPoint: UnitPoint(x: 0, y: 1)
    )
    public static var canvasMorph: Animation? {
        reducesMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: canvasMorphDuration)
    }
    /// Content and notices fading in.
    public static var fade: Animation? {
        reducesMotion ? nil : .easeOut(duration: 0.16)
    }

    public static var interactive: Animation? { standard }
    public static var fluid: Animation? { standard }
    public static var crossfade: Animation? { fade }
    public static var snappy: Animation? { standard }
    public static var gentle: Animation? { emphasis }
    public static var settle: Animation? { standard }
    public static var hover: Animation { micro }
    public static var lift: Animation? { standard }
}

// MARK: - Shared finishes

/// The raised slab used for every current choice: segmented thumbs, tool
/// rail selection, tiles and toggles in a toolbar. Paper on Aqua, a lit
/// graphite slab on Dark Aqua, with a top bevel and a two-step shadow.
struct EditorRaisedThumb<S: InsettableShape>: View {
    let shape: S
    var fill: Color = EditorTheme.segmentThumb
    var elevated = true
    var usesAccent = true

    var body: some View {
        // One raised plate for every current choice: segmented thumbs, tile
        // selectors and toolbar toggles share it. No task tint, no glow.
        shape
            .fill(fill)
            .shadow(color: .black.opacity(elevated ? 0.12 : 0), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
    }
}

/// A short fading rule: strong in the middle, gone at both ends.
struct EditorFadingHairline: View {
    var axis: Axis = .horizontal
    var opacity: Double = 0.08

    var body: some View {
        let gradient = LinearGradient(
            stops: [
                .init(color: EditorTheme.chrome(0), location: 0),
                .init(color: EditorTheme.chrome(opacity), location: 0.18),
                .init(color: EditorTheme.chrome(opacity), location: 0.82),
                .init(color: EditorTheme.chrome(0), location: 1)
            ],
            startPoint: axis == .horizontal ? .leading : .top,
            endPoint: axis == .horizontal ? .trailing : .bottom
        )
        Rectangle()
            .fill(gradient)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
