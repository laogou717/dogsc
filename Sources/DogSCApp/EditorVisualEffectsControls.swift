import RecorderCore
import SwiftUI

/// Compact visual frame picker. Five built-in styles fit in two rows at the
/// default inspector width; future collections can move behind a dedicated
/// library without turning the high-frequency inspector into a long menu.
struct EditorScreenFramePicker: View {
    @ObservedObject var editorStore: EditorStore
    let onError: (String) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 68), spacing: 7),
        count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("边框样式")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(ScreenFrameStyle.allCases) { style in
                    let isSelected = editorStore.project.canvas.screenFrame == style
                    Button {
                        selection.wrappedValue = style
                    } label: {
                        VStack(spacing: 4) {
                            ScreenFrameMiniature(style: style)
                                .frame(height: 38)
                            Text(style.editorShortName)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(
                                    isSelected ? Color.primary : Color.secondary
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    isSelected
                                        ? Color.white.opacity(0.13)
                                        : Color.white.opacity(0.035)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? editorAccent.opacity(0.9)
                                        : Color.white.opacity(0.07),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.editorDisplayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .help("边框会和屏幕、光标一起缩放并进行 3D 变形")
    }

    private var selection: Binding<ScreenFrameStyle> {
        editorCanvasBinding(
            store: editorStore,
            keyPath: \.screenFrame,
            actionName: "更换屏幕边框",
            onError: onError
        )
    }
}

private struct ScreenFrameMiniature: View {
    let style: ScreenFrameStyle

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let outer = CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            let toolbarHeight = style == .none ? 0 : max(size.height * 0.24, 7)
            let bezel: CGFloat = style == .none ? 0 : 2
            let content = CGRect(
                x: outer.minX + bezel,
                y: outer.minY + toolbarHeight,
                width: max(outer.width - bezel * 2, 1),
                height: max(outer.height - toolbarHeight - bezel, 1)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.26))

                if style != .none {
                    UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: 5,
                            bottomLeading: 7,
                            bottomTrailing: 7,
                            topTrailing: 5
                        ),
                        style: .continuous
                    )
                    .fill(frameSurface)
                    .frame(width: outer.width, height: outer.height)
                    .position(x: outer.midX, y: outer.midY)

                    Rectangle()
                        .fill(frameToolbar)
                        .frame(width: outer.width, height: toolbarHeight)
                        .position(
                            x: outer.midX,
                            y: outer.minY + toolbarHeight / 2
                        )
                        .mask(
                            UnevenRoundedRectangle(
                                cornerRadii: RectangleCornerRadii(
                                    topLeading: 5,
                                    bottomLeading: 0,
                                    bottomTrailing: 0,
                                    topTrailing: 5
                                ),
                                style: .continuous
                            )
                            .frame(width: outer.width, height: toolbarHeight)
                            .position(
                                x: outer.midX,
                                y: outer.minY + toolbarHeight / 2
                            )
                        )

                    HStack(spacing: 2) {
                        Circle().fill(Color.red.opacity(0.86))
                        Circle().fill(Color.yellow.opacity(0.86))
                        Circle().fill(Color.green.opacity(0.86))
                    }
                    .frame(width: 13, height: 3)
                    .position(
                        x: outer.minX + 9,
                        y: outer.minY + toolbarHeight / 2
                    )

                    if style.isBrowser {
                        Capsule(style: .continuous)
                            .fill(frameField)
                            .frame(
                                width: max(outer.width * 0.48, 12),
                                height: max(toolbarHeight * 0.42, 3)
                            )
                            .position(
                                x: outer.maxX - outer.width * 0.29,
                                y: outer.minY + toolbarHeight / 2
                            )
                    }
                }

                RoundedRectangle(cornerRadius: style == .none ? 6 : 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.34, green: 0.52, blue: 0.76),
                                Color(red: 0.82, green: 0.54, blue: 0.43),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: content.width, height: content.height)
                    .position(x: content.midX, y: content.midY)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var isDark: Bool {
        style == .windowDark || style == .browserDark
    }

    private var frameSurface: Color {
        isDark ? Color(white: 0.14) : Color(white: 0.86)
    }

    private var frameToolbar: Color {
        isDark ? Color(white: 0.20) : Color(white: 0.95)
    }

    private var frameField: Color {
        isDark ? Color(white: 0.09) : Color.white
    }
}

private extension ScreenFrameStyle {
    var editorDisplayName: String {
        switch self {
        case .none: "无边框"
        case .windowLight: "macOS 窗口·浅色"
        case .windowDark: "macOS 窗口·深色"
        case .browserLight: "浏览器·浅色"
        case .browserDark: "浏览器·深色"
        }
    }

    var editorShortName: String {
        switch self {
        case .none: "无"
        case .windowLight: "窗口浅色"
        case .windowDark: "窗口深色"
        case .browserLight: "浏览器浅色"
        case .browserDark: "浏览器深色"
        }
    }

    var isBrowser: Bool {
        self == .browserLight || self == .browserDark
    }
}
