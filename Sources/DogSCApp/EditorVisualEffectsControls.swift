import AppKit
import RecorderCore
import SwiftUI

/// Original vector frame family. Device shells follow the actual recording
/// rectangle; legacy portrait/landscape projects retain their source plane.
private enum ScreenFrameFamily: CaseIterable, Hashable {
    case none, window, browser, phone, tablet

    var title: String {
        switch self {
        case .none: "无边框"
        case .window: "macOS 窗口"
        case .browser: "浏览器"
        case .phone: "iPhone"
        case .tablet: "iPad"
        }
    }

    var supportsAppearance: Bool { self == .window || self == .browser }

    func style(dark: Bool) -> ScreenFrameStyle {
        switch self {
        case .none: .none
        case .window: dark ? .windowDark : .windowLight
        case .browser: dark ? .browserDark : .browserLight
        case .phone: .devicePhone
        case .tablet: .deviceTablet
        }
    }

    init(_ style: ScreenFrameStyle) {
        switch style {
        case .none: self = .none
        case .windowLight, .windowDark: self = .window
        case .browserLight, .browserDark: self = .browser
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape: self = .phone
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape: self = .tablet
        }
    }
}

private enum ScreenFrameAppearance: Hashable, CaseIterable {
    case light, dark

    var title: String { self == .light ? "浅色" : "深色" }
    var icon: String { self == .light ? "sun.max" : "moon" }
}

struct EditorScreenFramePicker: View {
    @ObservedObject var editorStore: EditorStore
    var target: ScreenAppearanceTarget = .recording(RecordingSource.primaryID)
    var screenImage: NSImage? = nil
    let onError: (String) -> Void
    @State private var prefersDarkChrome = false

    private var currentStyle: ScreenFrameStyle { editorStore.previewProject.screenCanvas(for: target).screenFrame }
    private var currentFamily: ScreenFrameFamily { ScreenFrameFamily(currentStyle) }
    private var usesDarkChrome: Bool {
        currentFamily.supportsAppearance
            ? currentStyle == .windowDark || currentStyle == .browserDark
            : prefersDarkChrome
    }

    private func select(_ style: ScreenFrameStyle) {
        do {
            try ScreenFrameEditorCommand.select(style, store: editorStore, target: target)
        } catch {
            onError(error.localizedDescription)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3),
                spacing: 12
            ) {
                ForEach(ScreenFrameFamily.allCases, id: \.self) { family in
                    let isSelected = family == currentFamily
                    Button {
                        select(family.style(dark: usesDarkChrome))
                    } label: {
                        VStack(spacing: 6) {
                            EditorMockupCard(
                                style: family.style(dark: usesDarkChrome),
                                screenImage: screenImage,
                                isSelected: isSelected
                            )
                            Text(appLocalized(family.title))
                                .font(.appUI(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help("边框会和屏幕、光标一起缩放并进行 3D 变形")
                    .accessibilityLabel(appLocalized(family.title))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }

            if currentFamily.supportsAppearance {
                HStack(spacing: 10) {
                    Text("外观")
                        .font(.appUI(size: 12))
                        .foregroundStyle(EditorTheme.secondaryText)
                    Spacer(minLength: 0)
                    EditorSegmentedControl(
                        options: ScreenFrameAppearance.allCases,
                        title: { $0.title },
                        icon: { $0.icon },
                        selection: Binding(
                            get: { usesDarkChrome ? .dark : .light },
                            set: { appearance in
                                prefersDarkChrome = appearance == .dark
                                select(currentFamily.style(dark: appearance == .dark))
                            }
                        )
                    )
                    .frame(maxWidth: 190)
                }
                .transition(.opacity)
            }

            HStack {
                Spacer()
                Button {
                    do {
                        try ScreenFrameEditorCommand.select(editorStore.previewProject.screenCanvas(for: target).screenFrame,
                            store: editorStore, target: target, resetDefaults: true)
                    } catch { onError(error.localizedDescription) }
                } label: {
                    EditorSymbolLabel("还原样式", systemImage: "arrow.counterclockwise")
                        .font(.appUI(size: 12))
                }
                .buttonStyle(.editorGhost)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .help("恢复当前样机的默认外观，保留标题和网址")
            }

            if editorStore.previewProject.screenCanvas(for: target).screenFrame.isWindowFrame {
                ScreenFrameMetadataField(
                    editorStore: editorStore,
                    target: target,
                    kind: .windowTitle,
                    onError: onError
                )
            } else if editorStore.previewProject.screenCanvas(for: target).screenFrame.isBrowserFrame {
                ScreenFrameMetadataField(
                    editorStore: editorStore,
                    target: target,
                    kind: .browserAddress,
                    onError: onError
                )
            }
        }
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
        target: ScreenAppearanceTarget = .recording(RecordingSource.primaryID),
        resetDefaults: Bool = false
    ) throws {
        guard resetDefaults || store.previewProject.screenCanvas(for: target).screenFrame != style else { return }
        let apply: (inout RecorderProject) -> Void = { project in
            var canvas = project.screenCanvas(for: target)
            canvas.applyScreenFrameStyle(style)
            project.setScreenAppearance(ScreenCardAppearance(canvas: canvas), for: target)
        }
        if store.interaction?.commandScope == .project {
            store.updateInteraction(apply)
            _ = try store.commitInteraction(actionName: "更换屏幕边框")
            return
        }
        if store.interaction != nil { store.cancelInteraction() }
        var project = store.project
        apply(&project)
        try store.replaceProject(with: project, actionName: "更换屏幕边框")
    }

    static func beginMetadataEditing(
        _ kind: ScreenFrameMetadataKind,
        store: EditorStore
    ) {
        _ = store.beginContinuousInteraction(
            commandScope: .project,
            commitsWhenReplacedAs: kind.actionName
        )
    }

    static func previewMetadata(
        _ rawValue: String,
        kind: ScreenFrameMetadataKind,
        store: EditorStore,
        target: ScreenAppearanceTarget = .recording(RecordingSource.primaryID)
    ) {
        beginMetadataEditing(kind, store: store)
        let value = String(rawValue.prefix(kind.maximumLength))
        store.updateInteraction { project in
            var canvas = project.screenCanvas(for: target)
            kind.setValue(value, in: &canvas)
            project.setScreenAppearance(ScreenCardAppearance(canvas: canvas), for: target)
        }
    }

    static func commitMetadata(
        _ rawValue: String,
        kind: ScreenFrameMetadataKind,
        store: EditorStore,
        target: ScreenAppearanceTarget = .recording(RecordingSource.primaryID)
    ) throws {
        guard store.interaction?.commandScope == .project else { return }
        let value = String(
            rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(kind.maximumLength)
        )
        store.updateInteraction { project in
            var canvas = project.screenCanvas(for: target)
            kind.setValue(value, in: &canvas)
            project.setScreenAppearance(ScreenCardAppearance(canvas: canvas), for: target)
        }
        _ = try store.commitInteraction(actionName: kind.actionName)
    }

    static func cancelMetadataEditing(store: EditorStore) {
        guard store.interaction?.commandScope == .project else { return }
        store.cancelInteraction()
    }
}

private struct ScreenFrameMetadataField: View {

    @ObservedObject var editorStore: EditorStore
    let target: ScreenAppearanceTarget
    let kind: ScreenFrameMetadataKind
    let onError: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(appLocalized(kind.title))
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .accessibilityHidden(true)

            TextField(appLocalized(kind.placeholder), text: $draft)
                .textFieldStyle(.plain)
                .tint(nil)
                .accessibilityLabel(appLocalized(kind.title))
                .help(appLocalized(kind.actionName))
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
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isFocused
                                ? EditorTheme.platinumAccent.opacity(0.46)
                                : EditorTheme.chrome(0.07),
                            lineWidth: 0.75
                        )
                }
                .focusEffectDisabled()
                .appKeyboardFocusScrollTarget(isFocused: isFocused)
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
                store: editorStore,
                target: target
            )
        }
        .onChange(of: currentValue) { _, value in
            if !isFocused { draft = value }
        }
    }

    private var currentValue: String {
        kind.value(in: editorStore.previewProject.screenCanvas(for: target))
    }

    private var projectValue: String {
        kind.value(in: editorStore.project.screenCanvas(for: target))
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
                store: editorStore,
                target: target
            )
        } catch {
            ScreenFrameEditorCommand.cancelMetadataEditing(store: editorStore)
            onError(error.localizedDescription)
            draft = projectValue
        }
    }
}

// MARK: - Mockup cards

/// One mockup option shown the way it will look: the project's own paused
/// frame, dressed in that frame's chrome, standing on a soft studio plate.
/// The current choice is ringed in ink; everything else stays quiet.
struct EditorMockupCard: View {
    let style: ScreenFrameStyle
    let screenImage: NSImage?
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        let card = RoundedRectangle(cornerRadius: 10, style: .continuous)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [EditorStageBackdrop.top, EditorStageBackdrop.bottom],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [EditorStageBackdrop.glow, .clear],
                               center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: size.width * 0.7)
                mockup(in: size)
                    .scaleEffect(isHovered && !RecorderMotion.reduces ? 1.035 : 1)
            }
        }
        .aspectRatio(1.45, contentMode: .fit)
        .clipShape(card)
        .overlay {
            card.strokeBorder(isSelected ? EditorTheme.selectionTint : EditorTheme.chrome(0.06),
                              lineWidth: isSelected ? 2 : 0.5)
        }
        .animation(SpringMotion.settle, value: isSelected)
        .animation(SpringMotion.lift, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func mockup(in size: CGSize) -> some View {
        let isDark = style == .windowDark || style == .browserDark
        switch style {
        case .none:
            screen(radius: 5)
                .frame(width: size.width * 0.66, height: size.width * 0.66 / 1.6)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        case .windowLight, .windowDark, .browserLight, .browserDark:
            let width = size.width * 0.74
            let bar: CGFloat = max(width * 0.095, 7)
            let corner = max(width * 0.06, 4)
            VStack(spacing: 0) {
                desktopBar(width: width, height: bar, isDark: isDark, isBrowser: style.isBrowserFrame)
                screen(radius: 0)
            }
            .frame(width: width, height: width / 1.6 + bar)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.24), radius: 7, y: 3)
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape:
            let height = size.height * 0.84
            appleDevice(size: CGSize(width: height * 0.49, height: height), isPhone: true)
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape:
            let width = size.width * 0.70
            appleDevice(size: CGSize(width: width, height: width / 1.40), isPhone: false)
        }
    }

    private func desktopBar(width: CGFloat, height: CGFloat, isDark: Bool, isBrowser: Bool) -> some View {
        let glyph = isDark ? Color.white.opacity(0.42) : Color.black.opacity(0.32)
        let dot = height * 0.30
        return ZStack {
            (isDark ? Color(white: 0.175) : Color(white: 0.97))
            HStack(spacing: dot * 0.62) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: dot, height: dot)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, height * 0.42)
            if isBrowser {
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                    .frame(width: width * 0.40, height: height * 0.54)
                    .overlay {
                        HStack(spacing: height * 0.12) {
                            Circle().fill(glyph).frame(width: height * 0.16, height: height * 0.16)
                            Capsule().fill(glyph).frame(width: width * 0.16, height: height * 0.10)
                        }
                    }
            } else {
                Capsule().fill(glyph).frame(width: width * 0.18, height: height * 0.12)
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(isDark ? Color.black.opacity(0.5) : Color.black.opacity(0.09)).frame(height: 0.5)
        }
    }

    private func appleDevice(size: CGSize, isPhone: Bool) -> some View {
        let shortEdge = min(size.width, size.height)
        let bezel = max(shortEdge * (isPhone ? 0.05 : 0.055), 2)
        let rim = max(bezel * 0.32, 0.8)
        let screenSize = CGSize(width: size.width - bezel * 2, height: size.height - bezel * 2)
        let screenRadius = min(screenSize.width, screenSize.height) * (isPhone ? 0.15 : 0.04)
        let outer = RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
        return ZStack {
            outer.fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.25)],
                                      startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: screenRadius + bezel - rim, style: .continuous)
                .fill(Color(white: 0.02))
                .padding(rim)
            screen(radius: screenRadius)
                .frame(width: screenSize.width, height: screenSize.height)
                .overlay(alignment: .top) {
                    if isPhone {
                        Capsule(style: .continuous)
                            .fill(Color.black)
                            .frame(width: screenSize.width * 0.33, height: screenSize.width * 0.10)
                            .padding(.top, screenSize.width * 0.035)
                    }
                }
            if !isPhone {
                Circle()
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                    .frame(width: bezel * 0.32, height: bezel * 0.32)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, bezel / 2 - bezel * 0.16)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            outer.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.75), Color.white.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }

    private func screen(radius: CGFloat) -> some View {
        ZStack {
            Color(white: 0.9)
            if let screenImage {
                Color.clear.overlay { Image(nsImage: screenImage).resizable().scaledToFill() }
            } else {
                LinearGradient(colors: [Color(red: 0.95, green: 0.78, blue: 0.62), Color(red: 0.88, green: 0.84, blue: 0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
