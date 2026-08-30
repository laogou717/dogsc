import AppKit
import SwiftUI

// MARK: - Design Tokens (Graphite Hardware)

public enum EditorTheme {
    // DogSC uses warm graphite instead of blue/purple chrome. Colour belongs
    // to media and timeline identities; the workspace itself should feel like
    // a piece of dark hardware with platinum controls.
    public static let backgroundDeep = Color(red: 0.045, green: 0.047, blue: 0.051)
    public static let panelSurface = Color(red: 0.071, green: 0.074, blue: 0.079)
    public static let panelRaised = Color(red: 0.092, green: 0.095, blue: 0.101)
    public static let cardElevated = Color(red: 0.112, green: 0.115, blue: 0.122)
    public static let recorderSurface = Color(red: 0.052, green: 0.054, blue: 0.059)

    public static let platinumAccent = Color(red: 0.949, green: 0.941, blue: 0.918)
    public static let platinumMuted = Color(red: 0.72, green: 0.71, blue: 0.68)
    public static let amberAccent = Color(red: 0.93, green: 0.65, blue: 0.28)
    public static let success = Color(red: 0.37, green: 0.80, blue: 0.57)
    public static let recording = Color(red: 1.0, green: 0.31, blue: 0.29)

    public static let hairline = Color.white.opacity(0.085)
    public static let topHighlight = Color.white.opacity(0.16)
    public static let softShadow = Color.black.opacity(0.42)
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

    public static var snappy: Animation? {
        reducesMotion ? nil : .spring(response: 0.18, dampingFraction: 0.68)
    }

    public static var gentle: Animation? {
        reducesMotion ? nil : .spring(response: 0.52, dampingFraction: 0.88)
    }
}
