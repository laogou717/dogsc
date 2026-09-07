import SwiftUI

/// A small, neutral surface keeps the rotation glyph readable over the video.
/// Only the glyph rotates; the circular surface and existing hit area stay put.
struct EditorLinearFocusRotationHandle: View {
    let rotation: Double
    let isActive: Bool

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 13, weight: .semibold))
            .rotationEffect(.degrees(rotation))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background {
                Circle()
                    .fill(Color(white: isActive ? 0.13 : 0.19).opacity(0.94))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(isActive ? 0.85 : 0.6), lineWidth: 0.75)
                    }
            }
            .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
    }
}
