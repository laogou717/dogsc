import AppKit
import SwiftUI

// MARK: - Exact-entry readout

/// The value under a knob or a fader. Clicking it turns it into a text
/// field with the same one-gesture/one-command lifecycle as the slider rows.
struct EditorTransactionalReadout: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    var format: EditorSliderValueFormat = .decimal2
    var accessibilityTitle: String? = nil
    var isActive = false
    var centered = true
    @Binding var isTextEditing: Bool
    let onError: (String) -> Void
    @State private var hasTextPreview = false

    var body: some View {
        EditorInspectorParameterReadout(
            title: accessibilityTitle ?? title,
            valueText: format.text(for: value.wrappedValue),
            isEditing: isActive || isTextEditing,
            editConfiguration: EditorInspectorParameterEditConfiguration(
                draftText: format.editingText(for: value.wrappedValue),
                onBegin: begin,
                onPreview: preview,
                onCommit: commit,
                onCancel: cancel
            ),
            showsTitle: false,
            isEmbedded: false,
            centered: centered
        )
    }

    private func begin() {
        isTextEditing = true
        hasTextPreview = false
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope, commitsWhenReplacedAs: title
        )
    }

    private func preview(_ text: String) -> Bool {
        guard let parsed = format.value(from: text) else {
            editorStore.setContinuousInteractionReplacementPolicy(
                commandScope: commandScope, commitsWhenReplacedAs: nil
            )
            return false
        }
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope, commitsWhenReplacedAs: title
        )
        hasTextPreview = true
        value.wrappedValue = min(max(parsed, range.lowerBound), range.upperBound)
        return true
    }

    private func commit() {
        isTextEditing = false
        if hasTextPreview {
            updateEditorContinuousInteraction(
                store: editorStore, isEditing: false, commandScope: commandScope,
                actionName: title, onError: onError
            )
        } else if editorStore.interaction?.commandScope == commandScope {
            editorStore.cancelInteraction()
        }
        hasTextPreview = false
    }

    private func cancel() {
        isTextEditing = false
        hasTextPreview = false
        if editorStore.interaction?.commandScope == commandScope {
            editorStore.cancelInteraction()
        }
    }
}

// MARK: - Knob

/// Follow the pointer around the dial, or scroll while hovering it. Shift
/// refines either input; the separate readout still accepts an exact value.
/// One drag or wheel burst owns one continuous interaction and undo step.
struct EditorTransactionalKnob: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    var label: String? = nil
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    var format: EditorSliderValueFormat = .decimal2
    var accessibilityTitle: String? = nil
    let onError: (String) -> Void

    @Environment(\.consolePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var isScrolling = false
    @State private var isHovered = false
    @State private var isTextEditing = false
    @State private var dragState: EditorKnobDragState?
    @State private var parameterInteractionID: UUID?
    @FocusState private var isFocused: Bool

    private var scale: EditorSliderScale { format.sliderScale(in: range) }
    private var fraction: Double { scale.fraction(value.wrappedValue, in: range) }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let diameter = min(proxy.size.width * 0.78, 52)
                dial(diameter: diameter)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .overlay {
                        EditorKnobPointerInput(
                            isEnabled: isEnabled && !isTextEditing,
                            onHover: { isHovered = $0 },
                            onDragBegin: beginDrag,
                            onDragChange: updateDrag,
                            onDragEnd: finishInput,
                            onWheelBegin: beginWheel,
                            onWheelChange: updateWheel,
                            onWheelEnd: finishInput
                        )
                        .accessibilityHidden(true)
                    }
                    .help(appLocalized("旋转或滚动 · Shift 精调"))
            }
            .frame(height: 70)
            EditorTransactionalReadout(
                editorStore: editorStore, title: title, value: value, range: range,
                commandScope: commandScope, format: format,
                accessibilityTitle: accessibilityTitle, isActive: isDragging || isScrolling,
                isTextEditing: $isTextEditing, onError: onError
            )
            .frame(height: 24)
            // Longer English names ("Corner Radius") wrap to a second
            // centred line instead of being cut under a narrow knob.
            Text(appLocalized(label ?? title))
                .font(.appUI(size: 12))
                .foregroundStyle(EditorTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
        .onChange(of: editorStore.interaction?.id) { _, id in
            // A deactivation or another edit may retire this gesture's draft.
            // Its eventual mouse-up must not commit a replacement interaction.
            if isDragging || isScrolling, id != parameterInteractionID { resetInput() }
        }
    }

    private func dial(diameter: CGFloat) -> some View {
        // Parameter positions describe the real value even while the page
        // arrives. Page motion must not sweep a bounded value past its range.
        let shown = min(max(fraction, 0), 1)
        let arc = min(shown, 1)
        let active = isDragging || isScrolling
        let engaged = active || (isHovered && isEnabled)
        let ring = diameter + 12
        return ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(EditorTheme.chrome(0.10), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: ring, height: ring)
            Circle()
                .trim(from: 0, to: 0.75 * arc)
                .stroke(palette?.stroke ?? EditorTheme.primaryText, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: ring, height: ring)
                .opacity(arc > 0.004 ? 1 : 0)
            Circle()
                .fill(EditorTheme.panelRaised)
                .overlay { Circle().strokeBorder(EditorTheme.chrome(engaged ? 0.2 : 0.1), lineWidth: 0.75) }
                .frame(width: diameter, height: diameter)
                .shadow(color: EditorTheme.softShadow, radius: 3, y: 1.5)
                .overlay {
                    Capsule(style: .continuous)
                        .fill(palette?.stroke ?? EditorTheme.primaryText)
                        .frame(width: 3, height: diameter * 0.22)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 5)
                        .rotationEffect(.degrees(EditorKnobDragState.startAngle + EditorKnobDragState.sweepAngle * shown))
                }
        }
        .frame(width: diameter + 20, height: diameter + 20)
        .scaleEffect(RecorderMotion.reduces ? 1 : active ? 1.06 : isHovered && isEnabled ? 1.03 : 1)
        .animation(SpringMotion.snappy, value: active)
        .animation(SpringMotion.hover, value: isHovered)
        .contentShape(Circle())
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .appKeyboardFocus(in: Circle(), color: EditorTheme.chrome(0.4), isFocused: isFocused)
        .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
            let up = press.key == .upArrow || press.key == .rightArrow
            step(up ? 1 : -1, coarse: press.modifiers.contains(.shift))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(appLocalized(accessibilityTitle ?? title))
        .accessibilityValue(format.text(for: value.wrappedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, coarse: false)
            case .decrement: step(-1, coarse: false)
            @unknown default: break
            }
        }
        .onDisappear { finishInput() }
    }

    private func beginInput() -> Bool {
        guard isEnabled, !isTextEditing, !isDragging, !isScrolling else { return false }
        guard editorStore.beginContinuousInteraction(
            commandScope: commandScope, commitsWhenReplacedAs: title
        ), let id = editorStore.interaction?.id else { return false }
        parameterInteractionID = id
        isFocused = true
        return true
    }

    private func beginDrag(point: CGPoint, center: CGPoint) -> Bool {
        guard beginInput() else { return false }
        dragState = EditorKnobDragState(fraction: fraction, point: point, center: center)
        isDragging = true
        return true
    }

    private func updateDrag(point: CGPoint, fine: Bool) {
        guard isDragging, editorStore.interaction?.id == parameterInteractionID,
              var state = dragState else { return }
        let proposed = state.update(point: point, fine: fine)
        dragState = state
        applyFraction(proposed)
    }

    private func beginWheel() -> Bool {
        guard beginInput() else { return false }
        isScrolling = true
        return true
    }

    private func updateWheel(delta: Double) {
        guard isScrolling, editorStore.interaction?.id == parameterInteractionID else { return }
        applyFraction(EditorKnobDragState.clamp(fraction + delta))
    }

    private func applyFraction(_ proposed: Double) {
        value.wrappedValue = scale.value(proposed, in: range)
        EditorConsoleHUD.shared.show(label: label ?? title, value: format.text(for: value.wrappedValue))
    }

    private func finishInput() {
        guard isDragging || isScrolling else { return }
        if editorStore.interaction?.id == parameterInteractionID {
            updateEditorContinuousInteraction(
                store: editorStore, isEditing: false, commandScope: commandScope,
                actionName: title, onError: onError
            )
        }
        resetInput()
    }

    private func resetInput() {
        isDragging = false
        isScrolling = false
        dragState = nil
        parameterInteractionID = nil
        EditorConsoleHUD.shared.release()
    }

    private func step(_ direction: Double, coarse: Bool) {
        guard isEnabled else { return }
        _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
        let next = min(max(fraction + direction * (coarse ? 0.1 : 0.02), 0), 1)
        value.wrappedValue = scale.value(next, in: range)
        updateEditorContinuousInteraction(
            store: editorStore, isEditing: false, commandScope: commandScope,
            actionName: title, onError: onError
        )
    }
}

/// Equal-width cells for a handful of related knobs.
struct EditorKnobRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) { content() }
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Mixer strip

/// One channel of the desk: a gain scale, a fader and a mute key. The scale
/// shows the fader's setting; it is not a signal meter.
struct EditorMixerStrip: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let icon: AppLineIcon.Kind
    let detail: String
    let volume: Binding<Double>
    let isMuted: Binding<Bool>
    let commandScope: EditorInteractionCommandScope
    let accessibilityStem: String
    let onError: (String) -> Void

    @Environment(\.consolePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var isTextEditing = false
    @FocusState private var isFocused: Bool

    private let faderHeight: CGFloat = 150
    private let capHeight: CGFloat = 30
    private let segments = 14

    var body: some View {
        let muted = isMuted.wrappedValue
        let level = min(max(volume.wrappedValue, 0), 1)
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                AppLineIcon(kind: icon, size: 14)
                    .foregroundStyle(muted ? EditorTheme.tertiaryText : (palette?.stroke ?? EditorTheme.primaryText))
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(EditorTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                scale(level: muted ? 0 : level)
                fader(level: level, muted: muted)
            }
            .frame(height: faderHeight)
            EditorTransactionalReadout(
                editorStore: editorStore, title: "音量", value: volume, range: 0...1,
                commandScope: commandScope, format: .percent,
                accessibilityTitle: "\(title)音量", isActive: isDragging,
                isTextEditing: $isTextEditing, onError: onError
            )
            .disabled(muted)
            muteKey(muted: muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous)
                .fill(EditorTheme.panelSurface)
        )
        .opacity(muted ? 0.7 : 1)
        .animation(SpringMotion.settle, value: muted)
        .accessibilityElement(children: .contain)
    }

    private func scale(level: Double) -> some View {
        VStack(spacing: 3) {
            ForEach((0..<segments).reversed(), id: \.self) { index in
                let lit = Double(index + 1) / Double(segments) <= level + 0.0001
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(lit ? (palette?.stroke ?? EditorTheme.primaryText) : EditorTheme.chrome(0.10))
                    .frame(width: 7, height: 6)
            }
        }
        .animation(SpringMotion.hover, value: level)
    }

    private func fader(level: Double, muted: Bool) -> some View {
        let travel: CGFloat = faderHeight - capHeight
        let levelHeight: CGFloat = CGFloat(level) * travel
        let barHeight: CGFloat = max(levelHeight + capHeight / 2 - 6, 0)
        let thumbOffset: CGFloat = -levelHeight
        return ZStack(alignment: .bottom) {
            Capsule(style: .continuous)
                .fill(EditorTheme.chrome(0.10))
                .frame(width: 5, height: faderHeight - 12)
                .frame(maxHeight: .infinity)
            Capsule(style: .continuous)
                .fill((palette?.fill ?? EditorTheme.primaryText).opacity(muted ? 0.25 : 1))
                .frame(width: 5, height: barHeight)
                .padding(.bottom, 6)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(EditorChoiceStyle.thumb)
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(EditorTheme.chrome(0.08), lineWidth: 0.5) }
                .overlay {
                    Capsule(style: .continuous)
                        .fill(EditorTheme.sliderInk)
                        .frame(height: 2.5)
                        .padding(.horizontal, 8)
                }
                .shadow(color: EditorChoiceStyle.thumbShadow, radius: 3, y: 1.5)
                .frame(width: 38, height: capHeight)
                .scaleEffect(isDragging && !RecorderMotion.reduces ? 1.06 : 1)
                .offset(y: thumbOffset)
        }
        .frame(width: 42, height: faderHeight)
        .contentShape(Rectangle())
        .editorCursor(.resizeUpDown)
        .animation(SpringMotion.snappy, value: isDragging)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard isEnabled, !muted, !isTextEditing else { return }
                    if !isDragging { isDragging = true }
                    _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
                    let proposed = 1 - (Double(drag.location.y) - capHeight / 2) / Double(travel)
                    volume.wrappedValue = min(max(proposed, 0), 1)
                    EditorConsoleHUD.shared.show(
                        label: "\(title)音量",
                        value: EditorSliderValueFormat.percent.text(for: volume.wrappedValue)
                    )
                }
                .onEnded { _ in
                    guard isDragging else { return }
                    isDragging = false
                    EditorConsoleHUD.shared.release()
                    updateEditorContinuousInteraction(
                        store: editorStore, isEditing: false, commandScope: commandScope,
                        actionName: "\(title)音量", onError: onError
                    )
                }
        )
        .focusable(isEnabled && !muted)
        .focused($isFocused)
        .focusEffectDisabled()
        .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 12, style: .continuous), color: EditorTheme.chrome(0.4), isFocused: isFocused)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let up = press.key == .upArrow
            _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
            volume.wrappedValue = min(max(volume.wrappedValue + (up ? 1 : -1) * (press.modifiers.contains(.shift) ? 0.1 : 0.02), 0), 1)
            updateEditorContinuousInteraction(
                store: editorStore, isEditing: false, commandScope: commandScope,
                actionName: "\(title)音量", onError: onError
            )
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(appLocalized("\(title)音量"))
        .accessibilityValue(EditorSliderValueFormat.percent.text(for: volume.wrappedValue))
        .accessibilityAdjustableAction { direction in
            _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
            switch direction {
            case .increment: volume.wrappedValue = min(volume.wrappedValue + 0.02, 1)
            case .decrement: volume.wrappedValue = max(volume.wrappedValue - 0.02, 0)
            @unknown default: break
            }
            updateEditorContinuousInteraction(
                store: editorStore, isEditing: false, commandScope: commandScope,
                actionName: "\(title)音量", onError: onError
            )
        }
    }

    private func muteKey(muted: Bool) -> some View {
        Button {
            withAnimation(SpringMotion.snappy) { isMuted.wrappedValue.toggle() }
        } label: {
            Text(appLocalized(muted ? "已静音" : "静音"))
                .font(.appUI(size: 12, weight: muted ? .semibold : .medium))
                .foregroundStyle(muted ? EditorTheme.primaryText : EditorTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    Capsule(style: .continuous)
                        .fill(EditorTheme.chrome(muted ? 0.14 : 0.06))
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 15, showsHover: false))
        .appKeyboardFocus(in: Capsule(style: .continuous))
        .accessibilityLabel(String(format: appLocalized("%@启用"), appLocalized(title)))
        .accessibilityValue(appLocalized(muted ? "开关状态 · 关闭" : "开关状态 · 开启"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("\(accessibilityStem).enabled")
        .help(appLocalized(detail))
    }
}

/// A channel the recording did not capture: the same strip, unlit.
struct EditorMixerGhostStrip: View {
    let title: String
    let icon: AppLineIcon.Kind

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                AppLineIcon(kind: icon, size: 14)
                    .foregroundStyle(EditorTheme.tertiaryText)
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(appLocalized("未录制"))
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(EditorTheme.tertiaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 150 + 12 + 24 + 12 + 30 - 12)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous)
                .strokeBorder(EditorTheme.chrome(0.08), style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: appLocalized("%@未录制"), appLocalized(title)))
    }
}
