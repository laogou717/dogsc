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
            Text("屏幕样式")
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
                    .buttonStyle(.editorThumbnail)
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
            let outer = miniatureOuterRect(in: size)
            let isDevice = style.isDevice
            let toolbarHeight = style == .none
                ? 0
                : (isDevice ? max(min(outer.width, outer.height) * 0.055, 1.8)
                    : max(size.height * 0.24, 7))
            let sideBezel: CGFloat = isDevice
                ? max(min(outer.width, outer.height) * (style.isPhone ? 0.055 : 0.043), 1.6)
                : 0
            let leadingBezel = isDevice && !style.isPortraitDevice && style.isPhone
                ? max(sideBezel * 1.45, 2.2) : sideBezel
            let trailingBezel = isDevice && !style.isPortraitDevice && style.isPhone
                ? max(sideBezel * 1.45, 2.2) : sideBezel
            let topBezel = isDevice ? toolbarHeight : (style == .none ? 0 : toolbarHeight)
            let bottomBezel = isDevice ? toolbarHeight : (style == .none ? 0 : 2)
            let content = CGRect(
                x: outer.minX + (isDevice ? leadingBezel : (style == .none ? 0 : 2)),
                y: outer.minY + topBezel,
                width: max(
                    outer.width - (isDevice ? leadingBezel + trailingBezel
                        : (style == .none ? 0 : 4)),
                    1
                ),
                height: max(outer.height - topBezel - bottomBezel, 1)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.26))
                    .frame(width: outer.width, height: outer.height)
                    .position(x: outer.midX, y: outer.midY)

                if style != .none {
                    RoundedRectangle(
                        cornerRadius: isDevice
                            ? min(outer.width, outer.height) * (style.isPhone ? 0.12 : 0.075)
                            : 5,
                        style: .continuous
                    )
                    .fill(frameSurface)
                    .frame(width: outer.width, height: outer.height)
                    .position(x: outer.midX, y: outer.midY)

                    if isDevice {
                        deviceSensor(outer: outer, bezel: toolbarHeight)
                    } else {
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
                }

                RoundedRectangle(cornerRadius: style == .none ? 6 : 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.28, green: 0.25, blue: 0.21),
                                Color(red: 0.82, green: 0.68, blue: 0.49),
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

    @ViewBuilder
    private func deviceSensor(outer: CGRect, bezel: CGFloat) -> some View {
        if style.isPhone {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.42))
                .frame(
                    width: style.isPortraitDevice
                        ? max(outer.width * 0.22, 3.5)
                        : max(bezel * 0.20, 1),
                    height: style.isPortraitDevice
                        ? max(bezel * 0.20, 1)
                        : max(outer.height * 0.22, 3.5)
                )
                .position(
                    x: style.isPortraitDevice
                        ? outer.midX : outer.minX + bezel * 0.62,
                    y: style.isPortraitDevice
                        ? outer.minY + bezel * 0.52 : outer.midY
                )
        } else {
            Circle()
                .fill(Color.white.opacity(0.42))
                .frame(width: max(bezel * 0.28, 1.2), height: max(bezel * 0.28, 1.2))
                .position(x: outer.midX, y: outer.minY + bezel * 0.52)
        }
    }

    private func miniatureOuterRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(x: 1, y: 1, width: max(size.width - 2, 1), height: max(size.height - 2, 1))
        guard let aspect = style.devicePreviewAspectRatio else { return bounds }
        let width = min(bounds.width, bounds.height * aspect)
        let height = min(bounds.height, width / aspect)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    private var isDark: Bool {
        style == .windowDark || style == .browserDark || style.isDevice
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
        case .devicePhone: "通用手机样机"
        case .deviceTablet: "通用平板样机"
        case .devicePhonePortrait: "手机·竖屏"
        case .devicePhoneLandscape: "手机·横屏"
        case .deviceTabletPortrait: "平板·竖屏"
        case .deviceTabletLandscape: "平板·横屏"
        }
    }

    var editorShortName: String {
        switch self {
        case .none: "无"
        case .windowLight: "窗口浅色"
        case .windowDark: "窗口深色"
        case .browserLight: "浏览器浅色"
        case .browserDark: "浏览器深色"
        case .devicePhone: "通用手机"
        case .deviceTablet: "通用平板"
        case .devicePhonePortrait: "手机竖屏"
        case .devicePhoneLandscape: "手机横屏"
        case .deviceTabletPortrait: "平板竖屏"
        case .deviceTabletLandscape: "平板横屏"
        }
    }

    var isBrowser: Bool {
        self == .browserLight || self == .browserDark
    }

    var isDevice: Bool {
        switch self {
        case .devicePhone, .deviceTablet, .devicePhonePortrait,
             .devicePhoneLandscape, .deviceTabletPortrait,
             .deviceTabletLandscape: true
        default: false
        }
    }

    var isPhone: Bool {
        self == .devicePhone || self == .devicePhonePortrait
            || self == .devicePhoneLandscape
    }

    var isPortraitDevice: Bool {
        self == .devicePhonePortrait || self == .deviceTabletPortrait
    }

    var devicePreviewAspectRatio: CGFloat? {
        switch self {
        case .devicePhonePortrait: 9.0 / 19.5
        case .devicePhoneLandscape: 19.5 / 9.0
        case .deviceTabletPortrait: 3.0 / 4.0
        case .deviceTabletLandscape: 4.0 / 3.0
        case .devicePhone: 19.5 / 9.0
        case .deviceTablet: 4.0 / 3.0
        default: nil
        }
    }
}
