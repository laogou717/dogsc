import SwiftUI

/// Tiny interface geometry, not a screenshot or a runtime preview.
struct SettingsAppearanceMiniature: View {
    let preference: AppAppearancePreference
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                miniature(dark: preference == .dark)
                if preference == .system {
                    miniature(dark: true)
                        .mask(alignment: .trailing) { Rectangle().frame(width: geometry.size.width / 2) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.07), radius: 4, y: 2)
        }
        .accessibilityHidden(true)
    }
    private func miniature(dark: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Circle().fill(Color.gray.opacity(0.3)).frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3)).frame(height: 7)
                Spacer(minLength: 0)
            }.padding(7).frame(width: 30).background(dark ? Color(white: 0.15) : Color(white: 0.94))
            VStack(spacing: 5) {
                ForEach(0..<3) { _ in
                    Capsule().fill(dark ? Color(white: 0.23) : Color(white: 0.92)).frame(height: 5)
                }
            }.padding(.trailing, 8)
        }.background(dark ? Color(white: 0.10) : .white)
    }
}
