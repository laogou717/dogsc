import SwiftUI

// MARK: - Slider

/// 编辑器统一滑块：扩大命中槽道，并在悬停或拖动时显示实时数值。
/// 事务语义与旧系统滑块一致：按下幂等开始连续交互，松手提交一次命令；
/// 支持点击跳值与键盘/辅助功能步进。
struct EditorSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var formatValue: ((Double) -> String)? = nil
    /// Inspector rows already carry a persistent live readout. Compact canvas
    /// and timeline controls do not, so they keep the floating value bubble.
    var showsFloatingValue = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(proxy.size.width, 1)
            let trackHeight: CGFloat = isDragging ? 20 : 18
            let thumbDiameter: CGFloat = isDragging ? 18 : (isHovered ? 17 : 16)
            let inset = thumbDiameter / 2
            let travel = max(trackWidth - thumbDiameter, 1)
            let fraction = CGFloat(
                (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            )
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
            let thumbCenter = inset + clamped * travel

            ZStack(alignment: .leading) {
                // 内凹底槽
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.35),
                                Color.black.opacity(0.20)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(isHovered || isDragging ? 0.12 : 0.06), lineWidth: 0.75)
                    )
                    .frame(height: trackHeight)

                // 已填充区
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDragging ? 0.45 : 0.32),
                                Color.white.opacity(isDragging ? 0.32 : 0.22)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbCenter, 0), height: trackHeight - 2)
                    .padding(.horizontal, 1)

                // 旋钮
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white,
                                Color(white: 0.92)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 0.5)
                    )
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(isDragging ? 0.45 : 0.30), radius: isDragging ? 4 : 2, y: 1.5)
                    .offset(x: thumbCenter - thumbDiameter / 2)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                // 悬停或拖拽时显示实时数值
                if showsFloatingValue && (isDragging || isHovered) {
                    let displayString = formatValue?(value) ?? String(format: "%.0f", value)
                    Text(displayString)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.95))
                                .shadow(color: Color.black.opacity(0.25), radius: 3, y: 1)
                        )
                        .offset(x: min(max(thumbCenter - 18, 0), trackWidth - 36), y: -22)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            withAnimation(SpringMotion.interactive) { isDragging = true }
                            onEditingChanged(true)
                        }
                        // The visible thumb travels between its two edge
                        // insets. Mapping against the full control width made
                        // the value jump as soon as a user grabbed the thumb,
                        // and compressed both endpoints.
                        let t = min(max((drag.location.x - inset) / travel, 0), 1)
                        value = range.lowerBound
                            + Double(t) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        withAnimation(SpringMotion.interactive) { isDragging = false }
                        onEditingChanged(false)
                    }
            )
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isHovered = hovering
                }
            }
            .animation(SpringMotion.interactive, value: isHovered)
            .animation(SpringMotion.interactive, value: isDragging)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let step = span / 100
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

/// Optional direct-entry lifecycle for a parameter readout. Parsing belongs
/// to the semantic value format while this small configuration keeps the
/// visual control independent from any particular editor command domain.
struct EditorInspectorParameterEditConfiguration {
    let draftText: String
    let onBegin: () -> Void
    let onPreview: (String) -> Bool
    let onCommit: () -> Void
    let onCancel: () -> Void
}

/// A single visual header for inspector parameters. The value stays visible
/// before, during, and after a drag, while the active surface and numeric
/// transition make continuous edits readable without a second tooltip.
/// When an edit configuration is supplied, the readout itself becomes the
/// exact-value input instead of adding a second text field beside the slider.
struct EditorInspectorParameterReadout: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let valueText: String
    var isEditing = false
    var editConfiguration: EditorInspectorParameterEditConfiguration? = nil
    var showsTitle = true

    @State private var isValueHovered = false
    @State private var isTextEditing = false
    @State private var draftText = ""
    @State private var draftIsValid = true
    @State private var validationFailed = false
    @FocusState private var valueFieldFocused: Bool

    var body: some View {
        let isActive = isEditing || isTextEditing

        HStack(spacing: 10) {
            if showsTitle {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(
                        Color.white.opacity(
                            isEnabled ? (isActive ? 0.94 : 0.72) : 0.34
                        )
                    )

                Spacer(minLength: 8)
            }

            if let editConfiguration {
                editableValue(editConfiguration, isActive: isActive)
            } else {
                valueLabel(isActive: isActive)
            }
        }
        .animation(SpringMotion.interactive, value: isActive)
        .animation(SpringMotion.interactive, value: valueText)
        .accessibilityHidden(editConfiguration == nil)
        .onDisappear {
            guard isTextEditing, let editConfiguration else { return }
            cancelTextEditing(editConfiguration)
        }
    }

    private func valueLabel(isActive: Bool) -> some View {
        Text(valueText)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(
                isActive
                    ? EditorTheme.platinumAccent
                    : Color.white.opacity(isEnabled ? 0.78 : 0.34)
            )
            .contentTransition(.numericText())
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 22)
            .background(valueBackground(isActive: isActive))
            .overlay(valueBorder(isActive: isActive))
            .shadow(
                color: EditorTheme.platinumAccent.opacity(isActive ? 0.10 : 0),
                radius: 5
            )
    }

    @ViewBuilder
    private func editableValue(
        _ configuration: EditorInspectorParameterEditConfiguration,
        isActive: Bool
    ) -> some View {
        if isTextEditing {
            TextField("", text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(
                    validationFailed
                        ? Color.red.opacity(0.92)
                        : EditorTheme.platinumAccent
                )
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 8)
                .frame(minWidth: 58, maxWidth: 92, minHeight: 22)
                .background(valueBackground(isActive: true))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(
                            validationFailed
                                ? Color.red.opacity(0.58)
                                : EditorTheme.platinumAccent.opacity(0.44),
                            lineWidth: validationFailed ? 1 : 0.75
                        )
                }
                .shadow(
                    color: validationFailed
                        ? Color.red.opacity(0.12)
                        : EditorTheme.platinumAccent.opacity(0.12),
                    radius: 5
                )
                .focused($valueFieldFocused)
                .onSubmit { commitTextEditing(configuration) }
                .onExitCommand { cancelTextEditing(configuration) }
                .onChange(of: draftText) { _, newValue in
                    draftIsValid = configuration.onPreview(newValue)
                    validationFailed = false
                }
                .onChange(of: valueFieldFocused) { _, focused in
                    guard !focused, isTextEditing else { return }
                    if draftIsValid {
                        commitTextEditing(configuration)
                    } else {
                        cancelTextEditing(configuration)
                    }
                }
                .accessibilityLabel("输入\(title)")
                .accessibilityValue(draftText)
        } else {
            Button {
                beginTextEditing(configuration)
            } label: {
                valueLabel(isActive: isActive || isValueHovered)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(EditorTheme.platinumAccent.opacity(0.78))
                            .padding(.trailing, 5)
                            .opacity(isValueHovered ? 1 : 0)
                            .scaleEffect(isValueHovered ? 1 : 0.8)
                    }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isValueHovered = hovering
                }
            }
            .help("点击输入\(title)")
            .accessibilityLabel("编辑\(title)")
            .accessibilityValue(valueText)
            .disabled(!isEnabled)
        }
    }

    private func valueBackground(isActive: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(
                isActive
                    ? EditorTheme.platinumAccent.opacity(0.13)
                    : Color.black.opacity(0.22)
            )
    }

    private func valueBorder(isActive: Bool) -> some View {
        Capsule(style: .continuous)
            .stroke(
                isActive
                    ? EditorTheme.platinumAccent.opacity(0.34)
                    : Color.white.opacity(0.065),
                lineWidth: 0.75
            )
    }

    private func beginTextEditing(_ configuration: EditorInspectorParameterEditConfiguration) {
        draftText = configuration.draftText
        draftIsValid = true
        validationFailed = false
        isTextEditing = true
        configuration.onBegin()
        DispatchQueue.main.async {
            valueFieldFocused = true
        }
    }

    private func commitTextEditing(_ configuration: EditorInspectorParameterEditConfiguration) {
        guard isTextEditing else { return }
        guard draftIsValid else {
            validationFailed = true
            valueFieldFocused = true
            return
        }
        isTextEditing = false
        valueFieldFocused = false
        configuration.onCommit()
    }

    private func cancelTextEditing(_ configuration: EditorInspectorParameterEditConfiguration) {
        guard isTextEditing else { return }
        isTextEditing = false
        valueFieldFocused = false
        validationFailed = false
        configuration.onCancel()
    }
}

/// Two related scalar values presented as one compact row. Spatial controls
/// use this for X/Y coordinates and X/Y tilt so exact entry, validation,
/// preview, commit and cancellation stay identical without duplicating focus
/// state in every graphical pad.
struct EditorPairedParameterValue {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let displayText: String
    let inputFormat: EditorSliderValueFormat
}

struct EditorPairedParameterReadouts: View {
    private enum Slot: Hashable {
        case first
        case second
    }

    let first: EditorPairedParameterValue
    let second: EditorPairedParameterValue
    let onChanged: (Double, Double) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var activeSlot: Slot?
    @State private var hasPreview = false

    var body: some View {
        HStack(spacing: 10) {
            readout(first, slot: .first)
            readout(second, slot: .second)
        }
    }

    private func readout(
        _ parameter: EditorPairedParameterValue,
        slot: Slot
    ) -> some View {
        EditorInspectorParameterReadout(
            title: parameter.title,
            valueText: parameter.displayText,
            isEditing: activeSlot == slot,
            editConfiguration: EditorInspectorParameterEditConfiguration(
                draftText: parameter.inputFormat.editingText(for: parameter.value),
                onBegin: { begin(slot) },
                onPreview: { preview($0, slot: slot) },
                onCommit: { finish(slot, commits: true) },
                onCancel: { finish(slot, commits: false) }
            )
        )
        .frame(maxWidth: .infinity)
    }

    private func begin(_ slot: Slot) {
        activeSlot = slot
        hasPreview = false
        onEditingChanged(true)
    }

    private func preview(_ text: String, slot: Slot) -> Bool {
        let parameter = slot == .first ? first : second
        guard let parsed = parameter.inputFormat.value(from: text) else {
            return false
        }
        let clamped = min(max(parsed, parameter.range.lowerBound), parameter.range.upperBound)
        hasPreview = true
        switch slot {
        case .first:
            onChanged(clamped, second.value)
        case .second:
            onChanged(first.value, clamped)
        }
        return true
    }

    private func finish(_ slot: Slot, commits: Bool) {
        guard activeSlot == slot else { return }
        activeSlot = nil
        onEditingChanged(false)
        if hasPreview {
            commits ? onEnded() : onCancelled()
        }
        hasPreview = false
    }
}

// MARK: - Toggle

/// 编辑器统一胶囊开关，使用铂金开启态和清晰的弹性位移反馈。
struct EditorToggle: View {
    @Binding var isOn: Bool
    var title: String? = nil
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if let title {
            Button {
                withAnimation(SpringMotion.interactive) {
                    isOn.toggle()
                }
            } label: {
                HStack {
                    Text(title).font(.caption)
                    Spacer(minLength: 8)
                    toggleIndicator
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.editorToolbarPress)
            .scaleEffect(isHovered ? 1.012 : 1)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isHovered = hovering
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "开启" : "关闭")
            .accessibilityAddTraits(.isToggle)
        } else {
            Button {
                withAnimation(SpringMotion.interactive) {
                    isOn.toggle()
                }
            } label: {
                toggleIndicator
                    .contentShape(Rectangle())
            }
            .buttonStyle(.editorToolbarPress)
            .scaleEffect(isHovered ? 1.035 : 1)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isHovered = hovering
                }
            }
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "开启" : "关闭")
        }
    }

    private var toggleIndicator: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(
                    isOn
                        ? LinearGradient(
                            colors: [EditorTheme.platinumAccent, Color(white: 0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            Color.white.opacity(
                                isOn ? (isHovered ? 0.55 : 0.35)
                                    : (isHovered ? 0.18 : 0.08)
                            ),
                            lineWidth: 0.75
                        )
                )
            Circle()
                .fill(
                    isOn
                        ? LinearGradient(
                            colors: [Color(white: 0.15), Color(white: 0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [Color.white, Color(white: 0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                )
                .shadow(color: Color.black.opacity(0.35), radius: 1.5, y: 0.75)
                .padding(2)
        }
        .frame(width: 40, height: 22)
        .shadow(
            color: Color.white.opacity(isHovered && isOn ? 0.14 : 0),
            radius: 4
        )
        .animation(SpringMotion.interactive, value: isOn)
        .animation(SpringMotion.interactive, value: isHovered)
    }
}

// MARK: - Numeric step control

struct EditorNumericStepEditConfiguration {
    let draftText: String
    var onBegin: () -> Void = {}
    let onPreview: (String) -> Bool
    var onCommit: () -> Void = {}
    /// Receives the exact draft text captured when editing began, so a local
    /// draft can restore only this value without cancelling its parent tool.
    let onCancel: (String) -> Void
}

/// Compact precision control used where dragging a timeline or canvas handle
/// is the primary interaction but exact increments still matter. It keeps the
/// current value visible, gives both directions a stable pointer target and
/// supports optional press-and-hold repetition plus a single adjustable AX
/// element. Persistent document values can keep repetition disabled when a
/// direct-entry surface is the safer fast path.
struct EditorNumericStepControl: View {
    let title: String
    let valueText: String
    let accessibilityTitle: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void
    let editConfiguration: EditorNumericStepEditConfiguration?
    let repeatsSteps: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDirectEditing = false
    @State private var directEditOriginText: String?

    init(
        _ title: String,
        valueText: String,
        accessibilityTitle: String? = nil,
        canDecrease: Bool,
        canIncrease: Bool,
        onDecrease: @escaping () -> Void,
        onIncrease: @escaping () -> Void,
        editConfiguration: EditorNumericStepEditConfiguration? = nil,
        repeatsSteps: Bool = true
    ) {
        self.title = title
        self.valueText = valueText
        self.accessibilityTitle = accessibilityTitle ?? title
        self.canDecrease = canDecrease
        self.canIncrease = canIncrease
        self.onDecrease = onDecrease
        self.onIncrease = onIncrease
        self.editConfiguration = editConfiguration
        self.repeatsSteps = repeatsSteps
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 0)

            numericValue

            HStack(spacing: 3) {
                stepButton(
                    systemImage: "minus",
                    help: "减少\(title)",
                    isAvailable: canDecrease && !isDirectEditing,
                    action: onDecrease
                )
                stepButton(
                    systemImage: "plus",
                    help: "增加\(title)",
                    isAvailable: canIncrease && !isDirectEditing,
                    action: onIncrease
                )
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: 36)
        .background(
            Color.white.opacity(isHovered && isEnabled ? 0.060 : 0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color.white.opacity(isHovered && isEnabled ? 0.12 : 0.065),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: editConfiguration == nil ? .ignore : .contain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment where canIncrease:
                onIncrease()
            case .decrement where canDecrease:
                onDecrease()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var numericValue: some View {
        if let editConfiguration {
            EditorInspectorParameterReadout(
                title: accessibilityTitle,
                valueText: valueText,
                isEditing: isDirectEditing,
                editConfiguration: EditorInspectorParameterEditConfiguration(
                    draftText: editConfiguration.draftText,
                    onBegin: {
                        directEditOriginText = editConfiguration.draftText
                        isDirectEditing = true
                        editConfiguration.onBegin()
                    },
                    onPreview: editConfiguration.onPreview,
                    onCommit: {
                        isDirectEditing = false
                        directEditOriginText = nil
                        editConfiguration.onCommit()
                    },
                    onCancel: {
                        let origin = directEditOriginText
                            ?? editConfiguration.draftText
                        isDirectEditing = false
                        directEditOriginText = nil
                        editConfiguration.onCancel(origin)
                    }
                ),
                showsTitle: false
            )
            .frame(width: 58)
        } else {
            Text(valueText)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 40, alignment: .trailing)
                .padding(.horizontal, 4)
                .frame(height: 24)
                .background(
                    Color.black.opacity(isHovered && isEnabled ? 0.30 : 0.24),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }

    private func stepButton(
        systemImage: String,
        help: String,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(EditorStepButtonStyle())
        .buttonRepeatBehavior(repeatsSteps ? .enabled : .disabled)
        .disabled(!isAvailable)
        .help(help)
        .accessibilityHidden(true)
    }
}

private struct EditorStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(
                    isEnabled
                        ? Color.primary.opacity(isHovered ? 1 : 0.82)
                        : Color.secondary.opacity(0.45)
                )
                .frame(width: 28, height: 28)
                .background(
                    Color.white.opacity(
                        !isEnabled ? 0.018
                            : configuration.isPressed ? 0.14
                            : isHovered ? 0.09 : 0.045
                    ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color.white.opacity(isHovered && isEnabled ? 0.16 : 0.06),
                            lineWidth: 0.75
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.90 : 1)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

// MARK: - Button Styles

/// 次级按钮：轻描边、悬停提亮和按压反馈。
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
                .frame(minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            Color.white.opacity(
                                !isEnabled ? 0.025
                                    : configuration.isPressed ? 0.12
                                    : isHovered ? 0.085 : 0.045
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.16 : 0.08),
                                    Color.white.opacity(isHovered ? 0.08 : 0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : (isHovered && isEnabled ? 1.01 : 1.0))
                .opacity(isEnabled ? 1 : 0.46)
                .onHover { isHovered = $0 }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// 主动作按钮：铂金表面和明确的悬停、按压反馈。
struct EditorPrimaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 34

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
                        ? Color.black.opacity(0.88)
                        : Color.black.opacity(0.40)
                )
                .padding(.horizontal, 13)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isEnabled
                                ? LinearGradient(
                                    colors: [
                                        Color(white: configuration.isPressed ? 0.85 : isHovered ? 1.0 : 0.96),
                                        Color(white: configuration.isPressed ? 0.78 : isHovered ? 0.94 : 0.88)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                : LinearGradient(
                                    colors: [Color(white: 0.55), Color(white: 0.45)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isEnabled ? 0.9 : 0.3),
                                    Color.white.opacity(isEnabled ? 0.4 : 0.1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(isEnabled ? 0.25 : 0.05), radius: 3, y: 1.5)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : (isHovered && isEnabled ? 1.02 : 1.0))
                .onHover { isHovered = $0 }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// 低优先级按钮：默认透明，只在悬停或按压时出现表面。
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
                    isEnabled ? Color.primary.opacity(isHovered ? 1.0 : 0.85) : Color.secondary
                )
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            Color.white.opacity(
                                configuration.isPressed ? 0.11
                                    : isHovered && isEnabled ? 0.07 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { isHovered = $0 }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// Toolbar labels already draw their own hover and active surfaces. This
/// style adds only the missing physical press response, so applying it cannot
/// create another card, border or colour layer around the existing chrome.
struct EditorToolbarPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
                .offset(y: configuration.isPressed && isEnabled ? 0.5 : 0)
                .brightness(configuration.isPressed && isEnabled ? -0.035 : 0)
                .opacity(isEnabled ? 1 : 0.38)
                .animation(SpringMotion.snappy, value: configuration.isPressed)
                .animation(SpringMotion.interactive, value: isEnabled)
        }
    }
}

/// Icon-only dismiss controls use one neutral surface across sheets, banners
/// and lightweight reference panels. The style deliberately stays separate
/// from cancellation and destructive actions: it only removes the visible UI.
struct EditorDismissIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, size: size)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let size: CGFloat

        var body: some View {
            configuration.label
                .foregroundStyle(
                    isEnabled
                        ? Color.primary.opacity(isHovered ? 0.96 : 0.68)
                        : Color.secondary.opacity(0.38)
                )
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(
                            Color.white.opacity(
                                !isEnabled ? 0.02
                                    : configuration.isPressed ? 0.14
                                    : isHovered ? 0.10 : 0.05
                            )
                        )
                )
                .overlay {
                    Circle()
                        .stroke(
                            Color.white.opacity(isHovered && isEnabled ? 0.18 : 0.07),
                            lineWidth: 0.75
                        )
                }
                .contentShape(Circle())
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.88
                        : isHovered ? 1.04 : 1
                )
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// Warning actions remain compact in editor chrome but must read as real
/// controls instead of coloured status text. This is intentionally not the
/// destructive style: activating it reveals recovery detail and changes no data.
struct EditorWarningButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    EditorTheme.amberAccent.opacity(
                        !isEnabled ? 0.38 : isHovered ? 1 : 0.88
                    )
                )
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            EditorTheme.amberAccent.opacity(
                                configuration.isPressed ? 0.18
                                    : isHovered && isEnabled ? 0.11 : 0.055
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            EditorTheme.amberAccent.opacity(
                                isHovered && isEnabled ? 0.34 : 0.16
                            ),
                            lineWidth: 0.75
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.95
                        : isHovered ? 1.02 : 1
                )
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// Timeline junction controls already draw their own compact identity. This
/// style adds tactile hover/press feedback without adding another visible card
/// or changing the existing 28pt hit target.
struct EditorInlineActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .brightness(isHovered && isEnabled ? 0.08 : 0)
                .shadow(
                    color: Color.black.opacity(isHovered && isEnabled ? 0.46 : 0),
                    radius: 4,
                    y: 2
                )
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.88
                        : isHovered ? 1.08 : 1
                )
                .onHover { hovering in
                    withAnimation(SpringMotion.snappy) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
        }
    }
}

/// Destructive inspector actions stay visually quiet until the pointer is
/// nearby, but keep a full-height target instead of falling back to tiny
/// borderless macOS text.
struct EditorDestructiveButtonStyle: ButtonStyle {
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
                    Color.red.opacity(
                        !isEnabled ? 0.35
                            : isHovered ? 0.96 : 0.78
                    )
                )
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            Color.red.opacity(
                                configuration.isPressed ? 0.16
                                    : isHovered && isEnabled ? 0.09 : 0
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color.red.opacity(isHovered && isEnabled ? 0.20 : 0),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// Compact destructive icons used inside inspector rows. The glyph remains
/// small, while the pointer target and hover surface match nearby controls.
struct EditorDestructiveIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, size: size)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let size: CGFloat

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    Color.red.opacity(
                        !isEnabled ? 0.32
                            : isHovered ? 0.98 : 0.76
                    )
                )
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            Color.red.opacity(
                                configuration.isPressed ? 0.16
                                    : isHovered && isEnabled ? 0.10 : 0
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color.red.opacity(isHovered && isEnabled ? 0.22 : 0),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.93 : 1)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// Visual preset cards lift on hover and settle under the pointer on press.
/// The card itself continues to own its selected border and preview artwork.
struct EditorThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.975
                        : isHovered ? 1.025 : 1
                )
                .brightness(isHovered && isEnabled ? 0.025 : 0)
                .shadow(
                    color: Color.black.opacity(isHovered && isEnabled ? 0.34 : 0.12),
                    radius: isHovered && isEnabled ? 8 : 2,
                    y: isHovered && isEnabled ? 4 : 1
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }
    }
}

/// Small colour and material swatches get a crisp hover lift without gaining
/// another card surface around their own shape.
struct EditorSwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.90
                        : isHovered ? 1.12 : 1
                )
                .shadow(
                    color: Color.black.opacity(isHovered && isEnabled ? 0.42 : 0),
                    radius: 4,
                    y: 2
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { hovering in
                    withAnimation(SpringMotion.snappy) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
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

extension ButtonStyle where Self == EditorToolbarPressButtonStyle {
    static var editorToolbarPress: EditorToolbarPressButtonStyle {
        EditorToolbarPressButtonStyle()
    }
}

extension ButtonStyle where Self == EditorDismissIconButtonStyle {
    static var editorDismissIcon: EditorDismissIconButtonStyle {
        EditorDismissIconButtonStyle()
    }

    static func editorDismissIcon(size: CGFloat) -> EditorDismissIconButtonStyle {
        EditorDismissIconButtonStyle(size: size)
    }
}

extension ButtonStyle where Self == EditorWarningButtonStyle {
    static var editorWarning: EditorWarningButtonStyle {
        EditorWarningButtonStyle()
    }
}

extension ButtonStyle where Self == EditorInlineActionButtonStyle {
    static var editorInlineAction: EditorInlineActionButtonStyle {
        EditorInlineActionButtonStyle()
    }
}

extension ButtonStyle where Self == EditorDestructiveButtonStyle {
    static var editorDestructive: EditorDestructiveButtonStyle {
        EditorDestructiveButtonStyle()
    }
}

extension ButtonStyle where Self == EditorDestructiveIconButtonStyle {
    static var editorDestructiveIcon: EditorDestructiveIconButtonStyle {
        EditorDestructiveIconButtonStyle()
    }
}

extension ButtonStyle where Self == EditorThumbnailButtonStyle {
    static var editorThumbnail: EditorThumbnailButtonStyle { EditorThumbnailButtonStyle() }
}

extension ButtonStyle where Self == EditorSwatchButtonStyle {
    static var editorSwatch: EditorSwatchButtonStyle { EditorSwatchButtonStyle() }
}

// MARK: - Camera layout preset tile

/// 布局预设卡片按钮：图标 + 标题的大块可点面，悬停时底与描边同步提亮并微浮起。
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
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.20 : 0.09),
                                Color.white.opacity(isHovered ? 0.10 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.editorToolbarPress)
        .onHover { isHovered = $0 }
        .animation(SpringMotion.interactive, value: isHovered)
    }
}

// MARK: - Disclosure (平滑展开折叠卡片)

/// 卡片式折叠组：标题行 + 弹簧旋转箭头，展开时内容平滑淡入。
struct EditorDisclosure<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let detail: String?
    let icon: String?
    let iconTint: Color?
    private let externalExpansion: Binding<Bool>?
    @State private var localExpanded = false
    @State private var isHovered = false
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil,
        expanded externalExpansion: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.iconTint = iconTint
        self.externalExpansion = externalExpansion
        self.content = content()
    }

    private var expansion: Binding<Bool> {
        externalExpansion ?? $localExpanded
    }

    var body: some View {
        let isExpanded = expansion.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(SpringMotion.fluid) {
                    expansion.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                iconTint ?? Color.white.opacity(0.65)
                            )
                            .frame(width: 26, height: 26)
                            .background(
                                (iconTint ?? EditorTheme.platinumAccent).opacity(
                                    isExpanded ? 0.13 : 0.075
                                ),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(
                                Color.primary.opacity(isExpanded ? 0.96 : 0.82)
                            )
                        if let detail {
                            Text(detail)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(
                                    Color.white.opacity(isExpanded ? 0.57 : 0.42)
                                )
                                .lineLimit(1)
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            Color.white.opacity(isExpanded ? 0.86 : 0.46)
                        )
                        .frame(width: 24, height: 24)
                        .background(
                            Color.white.opacity(isExpanded ? 0.10 : isHovered ? 0.07 : 0.035),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(SpringMotion.fluid, value: isExpanded)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: detail == nil ? 36 : 48)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            Color.white.opacity(
                                !isEnabled ? 0
                                    : isHovered ? 0.065
                                    : isExpanded ? 0.032 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.editorToolbarPress)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isHovered = hovering
                }
            }
            .animation(SpringMotion.interactive, value: isHovered)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(
                [detail, isExpanded ? "已展开" : "已折叠"]
                    .compactMap { $0 }
                    .joined(separator: "，")
            )
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                Divider()
                    .overlay(Color.white.opacity(0.065))
                    .padding(.horizontal, 10)

                content
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 11)
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.985, anchor: .top)
                        )
                    )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isExpanded
                            ? [Color.white.opacity(0.062), Color.white.opacity(0.032)]
                            : [Color.white.opacity(0.038), Color.white.opacity(0.024)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    isExpanded
                        ? EditorTheme.platinumAccent.opacity(0.16)
                        : Color.white.opacity(0.07),
                    lineWidth: 0.75
                )
        }
        .shadow(
            color: Color.black.opacity(isExpanded ? 0.20 : 0.08),
            radius: isExpanded ? 6 : 2,
            y: isExpanded ? 2 : 1
        )
        .animation(SpringMotion.fluid, value: isExpanded)
    }
}
