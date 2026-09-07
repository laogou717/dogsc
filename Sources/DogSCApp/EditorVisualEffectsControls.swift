import AppKit
import RecorderCore
import SwiftUI

/// Original vector frame family. Device shells follow the actual recording
/// rectangle; legacy portrait/landscape projects retain their source plane.
struct EditorScreenFramePicker: View {
    @ObservedObject var editorStore: EditorStore
    let onError: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 62), spacing: 10), count: 3)
    private let visibleStyles = ScreenFrameStyle.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(visibleStyles) { style in
                    let current = editorStore.previewProject.canvas.screenFrame
                    let isSelected = current == style || (style == .devicePhone && current.isDeviceFrame)
                    Button {
                        do {
                            try ScreenFrameEditorCommand.select(
                                style,
                                store: editorStore
                            )
                        } catch {
                            onError(error.localizedDescription)
                        }
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(EditorTheme.chrome(isSelected ? 0.065 : 0.028))
                                ScreenFrameMiniature(style: style).padding(10)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isSelected ? EditorTheme.selectionTint.opacity(0.8) : EditorTheme.hairline,
                                              lineWidth: isSelected ? 1.5 : 0.75))
                            Text(appLocalized(style.editorShortName))
                                .font(.appUI(size: 10.5, weight: isSelected ? .medium : .regular))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .lineLimit(1).minimumScaleFactor(0.9)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.editorThumbnail)
                    .accessibilityLabel(appLocalized(style.editorDisplayName))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            HStack {
                Spacer()
                Button {
                    do {
                        try ScreenFrameEditorCommand.select(editorStore.previewProject.canvas.screenFrame,
                            store: editorStore, resetDefaults: true)
                    } catch { onError(error.localizedDescription) }
                } label: {
                    Label("还原样式", systemImage: "arrow.counterclockwise")
                        .font(.appUI(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.editorQuiet)
                .help("恢复当前样机的默认外观，保留标题和网址")
            }

            if editorStore.previewProject.canvas.screenFrame.isWindowFrame {
                ScreenFrameMetadataField(
                    editorStore: editorStore,
                    kind: .windowTitle,
                    onError: onError
                )
            } else if editorStore.previewProject.canvas.screenFrame.isBrowserFrame {
                ScreenFrameMetadataField(
                    editorStore: editorStore,
                    kind: .browserAddress,
                    onError: onError
                )
            }
        }
        .help("边框会和屏幕、光标一起缩放并进行 3D 变形")
    }

}

enum ScreenFrameMetadataKind {
    case windowTitle
    case browserAddress

    var title: String {
        switch self {
        case .windowTitle: "窗口标题"
        case .browserAddress: "网址或文字"
        }
    }

    var placeholder: String {
        switch self {
        case .windowTitle: "可留空"
        case .browserAddress: "example.com"
        }
    }

    var actionName: String {
        switch self {
        case .windowTitle: "修改窗口标题"
        case .browserAddress: "修改浏览器地址"
        }
    }

    var maximumLength: Int {
        switch self {
        case .windowTitle: 120
        case .browserAddress: 240
        }
    }

    func value(in canvas: CanvasStyle) -> String {
        switch self {
        case .windowTitle: canvas.screenFrameTitle
        case .browserAddress: canvas.screenFrameBrowserAddress
        }
    }

    func setValue(_ value: String, in canvas: inout CanvasStyle) {
        switch self {
        case .windowTitle: canvas.screenFrameTitle = value
        case .browserAddress: canvas.screenFrameBrowserAddress = value
        }
    }
}

/// Screen-frame cards are discrete commands, while metadata fields are one
/// continuous edit per focus session. Keeping those semantics explicit avoids
/// a card click disappearing into an unrelated canvas-slider draft and lets
/// title/address text reach the shared preview renderer while it is typed.
@MainActor
enum ScreenFrameEditorCommand {
    static func select(
        _ style: ScreenFrameStyle,
        store: EditorStore,
        resetDefaults: Bool = false
    ) throws {
        guard resetDefaults || store.previewProject.canvas.screenFrame != style else { return }
        if store.interaction?.commandScope == .canvas {
            store.updateInteraction { project in
                project.canvas.applyScreenFrameStyle(style)
            }
            _ = try store.commitInteraction(actionName: "更换屏幕边框")
            return
        }

        if store.interaction != nil {
            store.cancelInteraction()
        }
        var canvas = store.project.canvas
        canvas.applyScreenFrameStyle(style)
        try store.replaceCanvas(with: canvas, actionName: "更换屏幕边框")
    }

    static func beginMetadataEditing(
        _ kind: ScreenFrameMetadataKind,
        store: EditorStore
    ) {
        _ = store.beginContinuousInteraction(
            commandScope: .canvas,
            commitsWhenReplacedAs: kind.actionName
        )
    }

    static func previewMetadata(
        _ rawValue: String,
        kind: ScreenFrameMetadataKind,
        store: EditorStore
    ) {
        beginMetadataEditing(kind, store: store)
        let value = String(rawValue.prefix(kind.maximumLength))
        store.updateInteraction { project in
            kind.setValue(value, in: &project.canvas)
        }
    }

    static func commitMetadata(
        _ rawValue: String,
        kind: ScreenFrameMetadataKind,
        store: EditorStore
    ) throws {
        guard store.interaction?.commandScope == .canvas else { return }
        let value = String(
            rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(kind.maximumLength)
        )
        store.updateInteraction { project in
            kind.setValue(value, in: &project.canvas)
        }
        _ = try store.commitInteraction(actionName: kind.actionName)
    }

    static func cancelMetadataEditing(store: EditorStore) {
        guard store.interaction?.commandScope == .canvas else { return }
        store.cancelInteraction()
    }
}

private struct ScreenFrameMetadataField: View {

    @ObservedObject var editorStore: EditorStore
    let kind: ScreenFrameMetadataKind
    let onError: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(kind.title)
                .font(.appUI(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            TextField(kind.placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.appUI(size: 11))
                .lineLimit(1)
                .focused($isFocused)
                .onSubmit(commitAndEndEditing)
                .onExitCommand {
                    ScreenFrameEditorCommand.cancelMetadataEditing(
                        store: editorStore
                    )
                    draft = projectValue
                    isFocused = false
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    EditorTheme.chrome(isFocused ? 0.09 : 0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isFocused
                                ? EditorTheme.platinumAccent.opacity(0.46)
                                : EditorTheme.chrome(0.07),
                            lineWidth: 0.75
                        )
                }
                .focusEffectDisabled()
        }
        .onAppear { draft = currentValue }
        .onChange(of: isFocused) { _, focused in
            if focused {
                draft = currentValue
                ScreenFrameEditorCommand.beginMetadataEditing(
                    kind,
                    store: editorStore
                )
            } else {
                commit()
            }
        }
        .onChange(of: draft) { _, value in
            guard isFocused else { return }
            ScreenFrameEditorCommand.previewMetadata(
                value,
                kind: kind,
                store: editorStore
            )
        }
        .onChange(of: currentValue) { _, value in
            if !isFocused { draft = value }
        }
    }

    private var currentValue: String {
        kind.value(in: editorStore.previewProject.canvas)
    }

    private var projectValue: String {
        kind.value(in: editorStore.project.canvas)
    }

    private func commitAndEndEditing() {
        commit()
        isFocused = false
    }

    private func commit() {
        let value = String(
            draft
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(kind.maximumLength)
        )
        draft = value
        do {
            try ScreenFrameEditorCommand.commitMetadata(
                value,
                kind: kind,
                store: editorStore
            )
        } catch {
            ScreenFrameEditorCommand.cancelMetadataEditing(store: editorStore)
            onError(error.localizedDescription)
            draft = projectValue
        }
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
                    : max(outer.height * 0.22, 5))
            let sideBezel: CGFloat = isDevice
                ? max(min(outer.width, outer.height) * (style.isPhone ? 0.055 : 0.043), 1.6)
                : 0
            let leadingBezel = isDevice && !style.isPortraitDevice && style.isPhone
                ? sideBezel : sideBezel
            let trailingBezel = isDevice && !style.isPortraitDevice && style.isPhone
                ? sideBezel : sideBezel
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
                        RoundedRectangle(cornerRadius: min(outer.width, outer.height) * (style.isPhone ? 0.12 : 0.075))
                            .strokeBorder(LinearGradient(colors: [Color(white: 0.65), Color(white: 0.18), Color(white: 0.47)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1)
                            .frame(width: outer.width, height: outer.height)
                            .position(x: outer.midX, y: outer.midY)
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
                                    width: max(outer.width * 0.44, 12),
                                    height: max(toolbarHeight * 0.38, 3)
                                )
                                .position(
                                    x: outer.midX + outer.width * 0.035,
                                    y: outer.minY + toolbarHeight / 2
                                )
                        }
                    }
                }

                RoundedRectangle(cornerRadius: isDevice ? min(content.width, content.height) * (style.isPhone ? 0.10 : 0.06) : 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.27, green: 0.33, blue: 0.38),
                                Color(red: 0.75, green: 0.80, blue: 0.81),
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

    private func miniatureOuterRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(x: 1, y: 1, width: max(size.width - 2, 1), height: max(size.height - 2, 1))
        let aspect = style.devicePreviewAspectRatio ?? (16.0 / 10.0)
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
        case .devicePhone: "自适应设备框"
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
        case .devicePhone: "设备框"
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
        case .devicePhone: 4.0 / 3.0
        case .deviceTablet: 4.0 / 3.0
        default: nil
        }
    }
}
