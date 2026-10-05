import AppKit
import SwiftUI

/// Both support entry points display the author's supplied image unchanged.
struct AppSupportSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let appreciationImage: NSImage? = Bundle.main.url(
        forResource: "AppreciationCode", withExtension: "jpg", subdirectory: "Support"
    ).flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("请我喝杯咖啡")
                    .font(.appUI(size: 16, weight: .medium))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.editorGhost)
                .accessibilityLabel("关闭赞赏码")
            }

            if let image = Self.appreciationImage {
                Image(nsImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 400, height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(EditorTheme.hairline, lineWidth: 0.75)
                    }
                    .accessibilityLabel("赞赏码")
                    .accessibilityHint("使用手机扫描图片中的赞赏码")
            } else {
                Text("赞赏码暂时无法显示")
                    .foregroundStyle(EditorTheme.secondaryText)
                    .frame(width: 400, height: 400)
            }

            Text("免费开源 · 自愿支持")
                .font(.appUI(size: 12))
                .foregroundStyle(EditorTheme.secondaryText)
        }
        .padding(24)
        .frame(width: 448)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
        .onExitCommand { dismiss() }
    }
}
