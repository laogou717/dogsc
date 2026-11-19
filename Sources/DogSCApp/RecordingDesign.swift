import AppKit
import SwiftUI

/// Tokens from .build/design/multi-recording.html, scoped to its new surfaces.
/// Existing editor surfaces retain their current palette.
enum RecordingDesign {
    static let ink = adaptive(0x1E1D1A, 0xEDEBE5)
    static let secondary = adaptive(0x6B6962, 0xA5A29A)
    static let tertiary = adaptive(0x9C9990, 0x76736C)
    static let panel = adaptive(0xFBFAF7, 0x22211F)
    static let raised = adaptive(0xFFFFFF, 0x2C2B28)
    static let accent = adaptive(0xC4633F, 0xDA7A52)
    static let accentSoft = adaptive(0xC4633F, 0xDA7A52, lightAlpha: 0.12, darkAlpha: 0.16)
    static let line = ink.opacity(0.075)
    static let fill = adaptive(0x1E1D1A, 0xEDEBE5, lightAlpha: 0.045, darkAlpha: 0.05)
    static let fill2 = adaptive(0x1E1D1A, 0xEDEBE5, lightAlpha: 0.08, darkAlpha: 0.09)
    static let sourceColors = [color(0x5F8FB4), color(0x7E9A63), color(0x9488B5)]
    static func color(_ hex: Int) -> Color { Color(nsColor: nsColor(hex)) }
    private static func nsColor(_ hex: Int, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: alpha)
    }
    private static func adaptive(_ light: Int, _ dark: Int, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(darkMode ? dark : light, alpha: darkMode ? darkAlpha : lightAlpha)
        })
    }
}
private struct RecordingDesignControlsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var recordingDesignControls: Bool {
        get { self[RecordingDesignControlsKey.self] }
        set { self[RecordingDesignControlsKey.self] = newValue }
    }
}
