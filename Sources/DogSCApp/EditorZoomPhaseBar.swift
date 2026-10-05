import RecorderCore
import SwiftUI

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
            .overlay { if width > 38 { Text(appLocalized(title)).font(.appUI(size: 10)).foregroundStyle(.secondary) } }
    }
}
