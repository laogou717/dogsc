import SwiftUI

// 编辑器自建控件集（2026-08-15 组件级设计）。
// 系统默认滑块/开关/按钮/折叠栏在深色面板上读作"未设计的模板件"，
// 这里统一为一套与雾白极简 token 配套的组件：细轨滑块、胶囊开关、
// 静音/主动作按钮、卡片式折叠组。所有组件只负责呈现与手势；
// 项目写入与撤销仍由调用方的绑定与事务钩子完成。

// MARK: - Slider

/// 槽道滑块：深色槽道 + 槽内旋钮 + 柔光进度。旋钮两侧始终与槽道
/// 端点对齐（极值处贴边，不会露出平头进度残端）；进度是旋钮身后
/// 的柔光而非硬边长条，旋钮永远嵌在槽道中间。事务语义与旧系统滑块
/// 一致：按下幂等开始连续交互，松手提交一次命令；支持点击跳值与
/// 键盘/辅助功能步进。
struct EditorSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(proxy.size.width, 1)
            let trackHeight: CGFloat = isDragging ? 18.5 : 17
            let thumbDiameter = trackHeight - 4
            let inset = thumbDiameter / 2
            let travel = max(trackWidth - thumbDiameter, 1)
            let fraction = CGFloat(
                (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            )
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
            let thumbCenter = inset + clamped * travel

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovered || isDragging ? 0.11 : 0.08))
                    .frame(height: trackHeight)
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isDragging ? 0.38 : 0.30))
                    // 柔光高度与旋钮一致：极值处完全藏进旋钮后面，
                    // 槽道端头保持完整圆角，不再露出直边。
                    .frame(width: max(thumbCenter, 0), height: thumbDiameter)
                Circle()
                    .fill(Color(white: 0.97))
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5)
                    )
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: thumbCenter - thumbDiameter / 2)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let t = min(max(drag.location.x / trackWidth, 0), 1)
                        value = range.lowerBound
                            + Double(t) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let step = span / 100
            // 键盘/辅助功能步进同样是一次完整编辑：打开并立即提交，
            // 与拖动手势的命令边界一致。
            onEditingChanged(true)
            switch direction {
            case .increment:
                value = min(value + step, range.upperBound)
            case .decrement:
                value = max(value - step, range.lowerBound)
            @unknown default:
                break
            }
            onEditingChanged(false)
        }
    }
}

// MARK: - Toggle

/// 胶囊开关：32×19 轨道 + 15pt 手柄，开=米白轨道，关=白 0.12 轨道。
/// 手柄滑动 0.15s，替代系统开关的默认外观。
struct EditorToggle: View {
    @Binding var isOn: Bool
    var title: String? = nil

    @ViewBuilder
    var body: some View {
        if let title {
            Button {
                isOn.toggle()
            } label: {
                HStack {
                    Text(title).font(.caption)
                    Spacer(minLength: 8)
                    toggleIndicator
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "开启" : "关闭")
            .accessibilityAddTraits(.isToggle)
        } else {
            Button {
                isOn.toggle()
            } label: {
                toggleIndicator
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "开启" : "关闭")
        }
    }

    private var toggleIndicator: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? editorAccent : Color.white.opacity(0.13))
            Circle()
                .fill(Color(white: 0.96))
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: 32, height: 19)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

// MARK: - Buttons

/// 静音按钮：白 0.05 底 + 发丝描边，悬停微亮，按下下沉。
/// 对应旧 `.bordered` 在深色面板上的默认外观。
struct EditorQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    isEnabled
                        ? Color.primary.opacity(isHovered ? 1 : 0.88)
                        : Color.secondary
                )
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            Color.white.opacity(
                                !isEnabled ? 0.03
                                    : configuration.isPressed ? 0.11
                                    : isHovered ? 0.09 : 0.05
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// 主动作按钮：米白底 + 深字，一个视图区域至多一处。
struct EditorPrimaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 30

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, minHeight: minHeight)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let minHeight: CGFloat

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(
                    isEnabled
                        ? Color.black.opacity(0.85)
                        : Color.black.opacity(0.45)
                )
                .padding(.horizontal, 13)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isEnabled
                                ? Color(white: configuration.isPressed
                                    ? 0.82 : isHovered ? 0.98 : 0.92)
                                : Color(white: 0.55)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// 幽灵按钮：无底文字，悬停出浅底。对应旧 `.borderless`。
struct EditorGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    isEnabled ? Color.primary.opacity(0.85) : Color.secondary
                )
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            Color.white.opacity(
                                configuration.isPressed ? 0.10
                                    : isHovered && isEnabled ? 0.06 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

extension ButtonStyle where Self == EditorQuietButtonStyle {
    static var editorQuiet: EditorQuietButtonStyle { EditorQuietButtonStyle() }
}

extension ButtonStyle where Self == EditorPrimaryButtonStyle {
    static var editorPrimary: EditorPrimaryButtonStyle { EditorPrimaryButtonStyle() }
    static func editorPrimary(minHeight: CGFloat) -> EditorPrimaryButtonStyle {
        EditorPrimaryButtonStyle(minHeight: minHeight)
    }
}

extension ButtonStyle where Self == EditorGhostButtonStyle {
    static var editorGhost: EditorGhostButtonStyle { EditorGhostButtonStyle() }
}

// MARK: - Camera layout preset tile

/// 布局预设卡片按钮：图标 + 标题的大块可点面，悬停时底与描边同步提亮。
struct EditorCameraLayoutPresetButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(isHovered ? 1 : 0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.16 : 0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Disclosure

/// 卡片式折叠组：标题行（悬停有底）+ 旋转箭头，展开时内容位于同一
/// 安静卡片内。替代系统 DisclosureGroup 的默认小字外观。
struct EditorDisclosure<Content: View>: View {
    let title: String
    private let externalExpansion: Binding<Bool>?
    @State private var localExpanded = false
    @State private var isHovered = false
    let content: Content

    init(
        _ title: String,
        expanded externalExpansion: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.externalExpansion = externalExpansion
        self.content = content()
    }

    private var expansion: Binding<Bool> {
        externalExpansion ?? $localExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expansion.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.88))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expansion.wrappedValue ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.05 : 0))
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.15), value: expansion.wrappedValue)
            .accessibilityLabel(title)
            .accessibilityValue(expansion.wrappedValue ? "已展开" : "已折叠")
            .accessibilityAddTraits(.isButton)

            if expansion.wrappedValue {
                content
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
