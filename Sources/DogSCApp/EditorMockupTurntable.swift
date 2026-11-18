import RecorderCore
import SwiftUI

/// The mockups on a revolving ring. Drag to spin it (it carries on a little
/// and settles on the nearest card), click a card or an arrow to bring it
/// round, or use the arrow keys. The card in front is the current mockup.
struct EditorMockupTurntable: View {
    let styles: [ScreenFrameStyle]
    let selected: ScreenFrameStyle
    let screenImage: NSImage?
    let onSelect: (ScreenFrameStyle) -> Void

    @Environment(\.consolePalette) private var palette
    @State private var rotation: Double = 0
    @State private var dragStart: Double?
    @State private var hasPlacedInitial = false
    @FocusState private var isFocused: Bool

    private let cardWidth: CGFloat = 142
    private let pointsPerCard: CGFloat = 78

    private var count: Double { Double(max(styles.count, 1)) }

    private var selectedIndex: Int {
        styles.firstIndex(of: selected)
            ?? (selected.isDeviceFrame ? styles.firstIndex(of: .devicePhone) ?? 0 : 0)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(Array(styles.enumerated()), id: \.element) { index, style in
                    card(index: index, style: style)
                }
                HStack {
                    arrow(systemName: "chevron.left") { settle(at: (rotation - 1).rounded()) }
                    Spacer()
                    arrow(systemName: "chevron.right") { settle(at: (rotation + 1).rounded()) }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 118)
            .contentShape(Rectangle())
            .gesture(spin)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous), isFocused: isFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                settle(at: (rotation + (press.key == .leftArrow ? -1 : 1)).rounded())
                return .handled
            }

            VStack(spacing: 8) {
                ZStack {
                    Text(appLocalized(styles[safe: selectedIndex]?.turntableName ?? ""))
                        .id(selectedIndex)
                        .transition(.asymmetric(
                            insertion: .offset(y: 12).combined(with: .opacity),
                            removal: .offset(y: -12).combined(with: .opacity)
                        ))
                }
                .font(.appUI(size: 14.5, weight: .semibold))
                .foregroundStyle(EditorTheme.primaryText)
                .frame(height: 20)
                .clipped()
                .animation(SpringMotion.settle, value: selectedIndex)
                HStack(spacing: 6) {
                    ForEach(styles.indices, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index == selectedIndex ? EditorTheme.platinumAccent : EditorTheme.chrome(0.16))
                            .frame(width: index == selectedIndex ? 18 : 5, height: 5)
                    }
                }
                .animation(SpringMotion.settle, value: selectedIndex)
            }
        }
        .onAppear {
            guard !hasPlacedInitial else { return }
            hasPlacedInitial = true
            rotation = Double(selectedIndex)
        }
        .onChange(of: selectedIndex) { _, index in
            // Undo, redo or another control changed the mockup.
            guard dragStart == nil else { return }
            let delta = wrapped(Double(index) - rotation)
            if abs(delta) > 0.01 {
                withAnimation(settleSpring) { rotation += delta }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var settleSpring: Animation? {
        RecorderMotion.reduces ? nil : .spring(response: 0.62, dampingFraction: 0.74)
    }

    private func wrapped(_ value: Double) -> Double {
        value - count * (value / count).rounded()
    }

    private func settle(at target: Double) {
        withAnimation(settleSpring) { rotation = target }
        let index = ((Int(target.rounded()) % styles.count) + styles.count) % styles.count
        if index != selectedIndex { onSelect(styles[index]) }
    }

    private var spin: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                if dragStart == nil { dragStart = rotation }
                rotation = (dragStart ?? 0) - Double(drag.translation.width / pointsPerCard)
            }
            .onEnded { drag in
                let base = dragStart ?? rotation
                dragStart = nil
                let projected = base - Double(drag.predictedEndTranslation.width / pointsPerCard) * 0.55
                settle(at: projected.rounded())
            }
    }

    private func card(index: Int, style: ScreenFrameStyle) -> some View {
        let offset = wrapped(Double(index) - rotation)
        let angle = offset * 360 / count
        let radians = angle * .pi / 180
        let facing = cos(radians)
        let isFront = abs(offset) < 0.5
        let radius = cardWidth * 0.98
        return EditorMockupCard(
            style: style, screenImage: screenImage,
            isSelected: isFront && (style == selected || (style == .devicePhone && selected.isDeviceFrame))
        )
        .frame(width: cardWidth)
        .scaleEffect(0.72 + 0.28 * max(facing, 0))
        .rotation3DEffect(.degrees(-angle * 0.8), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .offset(x: CGFloat(sin(radians)) * radius * 0.78)
        .opacity(max(0, min(1, facing * 1.25 + 0.05)))
        .brightness(-0.25 * (1 - max(facing, 0)))
        .zIndex(facing)
        .allowsHitTesting(facing > 0.2)
        .onTapGesture {
            guard !isFront else { return }
            settle(at: rotation + wrapped(Double(index) - rotation))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized(style.turntableName))
        .accessibilityAddTraits(isFront ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { settle(at: rotation + wrapped(Double(index) - rotation)) }
        .help("边框会和屏幕、光标一起缩放并进行 3D 变形")
    }

    private func arrow(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            EditorSymbol(systemName, size: 14.5)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(EditorTheme.chrome(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 15, cornerStyle: .circular))
        .appKeyboardFocus(in: Circle())
        .accessibilityLabel(appLocalized(systemName.hasSuffix("left") ? "上一个样机" : "下一个样机"))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension ScreenFrameStyle {
    var turntableName: String {
        switch self {
        case .none: return "无边框"
        case .windowLight: return "macOS 窗口·浅色"
        case .windowDark: return "macOS 窗口·深色"
        case .browserLight: return "浏览器·浅色"
        case .browserDark: return "浏览器·深色"
        case .devicePhone: return "自适应设备框"
        case .deviceTablet: return "通用平板样机"
        case .devicePhonePortrait: return "手机·竖屏"
        case .devicePhoneLandscape: return "手机·横屏"
        case .deviceTabletPortrait: return "平板·竖屏"
        case .deviceTabletLandscape: return "平板·横屏"
        }
    }
}
