import AppKit
import SwiftUI

private struct RecorderUsesNotchStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var recorderUsesNotchStyle: Bool {
        get { self[RecorderUsesNotchStyleKey.self] }
        set { self[RecorderUsesNotchStyleKey.self] = newValue }
    }
}

enum RecorderNotchMotion {
    static var surface: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    }

    static func controls(appearing: Bool) -> Animation? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        return .easeOut(duration: appearing ? 0.14 : 0.08)
            .delay(appearing ? 0.06 : 0)
    }
}

/// One black surface belongs to the camera cutout. Controls stay at their
/// final position; only the outline grows and their opacity changes.
struct RecorderNotchSurface: View {
    let expandedSize: CGSize
    let collapsedSize: CGSize
    let isExpanded: Bool

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 0,
            bottomLeadingRadius: isExpanded ? 22 : 12,
            bottomTrailingRadius: isExpanded ? 22 : 12,
            topTrailingRadius: 0, style: .continuous)
            .fill(.black)
            .frame(width: isExpanded ? expandedSize.width : collapsedSize.width,
                height: isExpanded ? expandedSize.height : collapsedSize.height)
            .animation(RecorderNotchMotion.surface, value: isExpanded)
            .animation(RecorderNotchMotion.surface, value: expandedSize)
    }
}
