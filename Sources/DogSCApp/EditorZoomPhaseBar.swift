import RecorderCore
import SwiftUI

/// The selected animation's real entrance, hold and return fit the same
/// windows used by the frame evaluator. This annotation never changes hit
/// targets or the authored range restored when trimmed media returns.
struct EditorZoomPhaseBar: View {
    let clip: ZoomAnimationClip
    let pointsPerSecond: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            phase(duration: clip.enterDuration, opacity: 0.45)
            phase(duration: max(clip.duration - clip.enterDuration, 0), opacity: 0.9)
            phase(duration: clip.exitDuration, opacity: 0.3)
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }

    private func phase(duration: TimeInterval, opacity: Double) -> some View {
        Rectangle()
            .fill(EditorTheme.platinumAccent.opacity(opacity))
            .frame(width: max(duration * pointsPerSecond, 0))
            .overlay(alignment: .leading) {
                if duration > 0 {
                    Rectangle().fill(EditorTheme.chrome(0.75)).frame(width: 1)
                }
            }
    }
}

/// Overview of the authored phases; the same duration bindings below perform
/// the actual edit, including the existing short-clip transition resolution.
struct EditorInspectorZoomPhases: View {
    let animation: ZoomAnimationClip

    var body: some View {
        GeometryReader { geometry in
            let total = max(animation.duration + animation.exitDuration, 0.001)
            HStack(spacing: 2) {
                phase("进入", width: geometry.size.width * min(animation.enterDuration / total, 1), tint: EditorTheme.selectionWash)
                phase("保持", width: geometry.size.width * max(animation.duration - animation.enterDuration, 0) / total, tint: EditorTheme.amberAccent.opacity(0.18))
                phase("退出", width: geometry.size.width * animation.exitDuration / total, tint: EditorTheme.selectionWash)
            }
        }
        .frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func phase(_ title: String, width: CGFloat, tint: Color) -> some View {
        tint.frame(width: max(width - 1.5, 0))
            .overlay { if width > 38 { Text(title).font(.appUI(size: 10)).foregroundStyle(.secondary) } }
    }
}
