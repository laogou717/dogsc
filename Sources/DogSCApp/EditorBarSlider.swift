import AppKit
import SwiftUI

/// A parameter drawn as an extent: a solid bar sitting in a recessed track,
/// with a grip at each end and the value written inside it, the same way the
/// opening schedule draws a duration. Press inside the bar and drag to move
/// its end; press in the empty track to jump there; double-click to type an
/// exact number. One drag is one undo step, like every other slider.
@MainActor
struct EditorBarSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var format: EditorSliderValueFormat = .decimal2
    var valueTextOverride: String? = nil
    var accessibilityTitle: String? = nil
    @Binding var isTextEditing: Bool
    let edit: EditorInspectorParameterEditConfiguration
    /// The first change of a gesture (idempotent), every new value, and the
    /// end of the gesture. The caller owns the transaction.
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @Environment(\.consolePalette) private var palette
    @Environment(\.editorInsideTile) private var insideTile
    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var isPressed = false
    @State private var isHovered = false
    @State private var dragStartFraction: Double?
    @State private var grabbedInsideBar = false
    @State private var draft = ""
    @State private var draftIsValid = true
    @FocusState private var isFocused: Bool
    /// Focus that came from a click shows no ring; only keyboard focus does.
    @State private var focusedByPointer = false
    /// The value before a click jumped, kept until the double-click interval
    /// has passed so a double-click can take the jump back.
    @State private var clickOrigin: Double?
    @FocusState private var fieldFocused: Bool

    private let trackHeight: CGFloat = 30
    private let barHeight: CGFloat = 24
    private let inset: CGFloat = 3
    private let minimumBar: CGFloat = 26

    private var scale: EditorSliderScale { format.sliderScale(in: range) }
    private var fraction: Double { scale.fraction(value, in: range) }
    private var barFill: Color { palette?.fill ?? EditorTheme.platinumAccent }
    private var barInk: Color { palette?.ink ?? EditorTheme.onAccent }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - inset * 2 - minimumBar, 1)
            let shown = min(max(fraction, 0), 1)
            let barWidth = minimumBar + CGFloat(shown) * travel
            let valueText = valueTextOverride ?? format.text(for: value)
            let fitsInside = barWidth >= CGFloat(valueText.count) * 7 + 36
            let engaged = isPressed || isDragging || (isHovered && isEnabled)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(insideTile ? EditorTheme.panelSurface : EditorTheme.chrome(0.06))
                    .overlay {
                        let keyboardFocused = isFocused && !focusedByPointer
                        Capsule(style: .continuous).strokeBorder(
                            keyboardFocused ? barFill : EditorTheme.chrome(0.05),
                            lineWidth: keyboardFocused ? 1.5 : 0.5
                        )
                    }

                Capsule(style: .continuous)
                    .fill(barFill)
                    .frame(width: barWidth, height: isDragging ? barHeight + 2 : barHeight)
                    .offset(x: inset)
                    .overlay(alignment: .leading) {
                        grip.offset(x: inset + 7)
                    }
                    .overlay(alignment: .leading) {
                        grip.offset(x: inset + barWidth - 9.5)
                    }
                    .opacity(isEnabled ? (engaged ? 1 : 0.94) : 0.4)

                if !isTextEditing {
                    Text(valueText)
                        .font(.appUI(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(fitsInside ? barInk : EditorTheme.primaryText)
                        .contentTransition(.numericText())
                        .fixedSize()
                        .position(
                            x: fitsInside
                                ? inset + barWidth / 2
                                : inset + barWidth + 10 + CGFloat(valueText.count) * 3.5,
                            y: trackHeight / 2
                        )
                        .allowsHitTesting(false)
                } else {
                    TextField("", text: $draft)
                        .accessibilityLabel(appLocalized(accessibilityTitle ?? title))
                        .accessibilityIdentifier("editor.parameter.exact-value.\(title)")
                        .textFieldStyle(.plain)
                        .font(.appUI(size: 12, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(draftIsValid ? EditorTheme.primaryText : EditorTheme.recording)
                        .frame(width: 92, height: 22)
                        .background(EditorTheme.panelRaised, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(draftIsValid ? barFill : EditorTheme.recording, lineWidth: 1.25)
                        }
                        .focused($fieldFocused)
                        .position(x: width / 2, y: trackHeight / 2)
                        .onSubmit { finishEditing(commit: true) }
                        .onExitCommand { finishEditing(commit: false) }
                        .onChange(of: draft) { _, text in draftIsValid = edit.onPreview(text) }
                        .onChange(of: fieldFocused) { _, focused in
                            if !focused, isTextEditing { finishEditing(commit: true) }
                        }
                        .task {
                            await Task.yield()
                            guard !Task.isCancelled, isTextEditing else { return }
                            fieldFocused = true
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .animation(SpringMotion.snappy, value: isDragging)
            .animation(SpringMotion.snappy, value: isTextEditing)
            .onHover { isHovered = $0 }
            .editorCursor(.resizeLeftRight)
            .overlay {
                if isEnabled, !isTextEditing {
                    EditorBarPointerInput(
                        onPress: { pressed in
                            isPressed = pressed
                            if pressed {
                                focusedByPointer = true
                                isFocused = true
                            }
                        },
                        onDragBegin: { start in
                            isDragging = true
                            dragStartFraction = fraction
                            grabbedInsideBar = start.x <= inset + minimumBar + CGFloat(fraction) * travel
                            onBegin()
                        },
                        onDragChange: { location, translation in
                            guard isDragging else { return }
                            let proposed: Double
                            if grabbedInsideBar {
                                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                                proposed = (dragStartFraction ?? fraction) + Double(translation.width / travel) * fine
                            } else {
                                proposed = Double((location.x - inset - minimumBar) / travel)
                            }
                            changeValue(to: proposed)
                        },
                        onDragEnd: { endDrag() },
                        onClickPreview: { location in
                            guard isEnabled, !isTextEditing else { return }
                            // Jump at once, wherever the click lands; the
                            // edit is only committed once it cannot become
                            // the first half of a double-click.
                            clickOrigin = value
                            onBegin()
                            changeValue(to: Double((location.x - inset - minimumBar) / travel))
                        },
                        onClickCommit: {
                            guard clickOrigin != nil else { return }
                            clickOrigin = nil
                            EditorConsoleHUD.shared.release()
                            onEnd()
                        },
                        onClickRevert: {
                            guard let origin = clickOrigin else { return }
                            clickOrigin = nil
                            onChange(origin)
                            EditorConsoleHUD.shared.release()
                            onEnd()
                        },
                        onDoubleClick: { beginEditing() }
                    )
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: trackHeight)
        .opacity(isEnabled ? 1 : 0.55)
        .focusable(isEnabled && !isTextEditing)
        .focused($isFocused)
        .focusEffectDisabled()
        .onChange(of: isFocused) { _, focused in
            if !focused { focusedByPointer = false }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow, .upArrow]) { press in
            guard !isTextEditing else { return .ignored }
            let up = press.key == .rightArrow || press.key == .upArrow
            step(up ? 1 : -1, coarse: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.return) {
            guard isEnabled, !isTextEditing else { return .ignored }
            beginEditing()
            return .handled
        }
        .help(appLocalized("拖动调节 · 双击输入"))
        .accessibilityElement(children: isTextEditing ? .contain : .ignore)
        .accessibilityLabel(appLocalized(accessibilityTitle ?? title))
        .accessibilityValue(valueTextOverride ?? format.text(for: value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, coarse: false)
            case .decrement: step(-1, coarse: false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(appLocalized("输入精确数值"))) { beginEditing() }
        .onDisappear {
            if isTextEditing { finishEditing(commit: false) }
            endDrag()
        }
    }

    private var grip: some View {
        Capsule(style: .continuous)
            .fill(barInk.opacity(0.42))
            .frame(width: 2.5, height: 10)
            .allowsHitTesting(false)
    }

    private func step(_ direction: Double, coarse: Bool) {
        guard isEnabled, !isTextEditing else { return }
        onBegin()
        let next = scale.value(min(max(fraction + direction * (coarse ? 0.1 : 0.02), 0), 1), in: range)
        onChange(next)
        EditorConsoleHUD.shared.show(title: title, text: format.text(for: next))
        EditorConsoleHUD.shared.release()
        onEnd()
    }

    private func beginEditing() {
        guard isEnabled, !isTextEditing else { return }
        isFocused = false
        draft = edit.draftText
        draftIsValid = true
        edit.onBegin()
        withAnimation(SpringMotion.snappy) { isTextEditing = true }
    }

    private func finishEditing(commit: Bool) {
        guard isTextEditing else { return }
        withAnimation(SpringMotion.snappy) { isTextEditing = false }
        if commit && draftIsValid { edit.onCommit() } else { edit.onCancel() }
    }

    private func changeValue(to proposed: Double) {
        let next = scale.value(min(max(proposed, 0), 1), in: range)
        onChange(next)
        EditorConsoleHUD.shared.show(title: title, text: format.text(for: next))
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        dragStartFraction = nil
        EditorConsoleHUD.shared.release()
        onEnd()
    }
}

/// Arbitrate clicks around one model transaction. A stationary click jumps at
/// once (preview), and commits after the system's double-click interval; if
/// that click turns out to be the first half of a double-click, the jump is
/// taken back before exact entry opens, so a double-click never leaves an
/// implicit change. Real drags begin as soon as the pointer moves.
private struct EditorBarPointerInput: NSViewRepresentable {
    let onPress: (Bool) -> Void
    let onDragBegin: (CGPoint) -> Void
    let onDragChange: (CGPoint, CGSize) -> Void
    let onDragEnd: () -> Void
    let onClickPreview: (CGPoint) -> Void
    let onClickCommit: () -> Void
    let onClickRevert: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        view.input = self
    }

    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        view.cancel()
    }

    final class PointerView: NSView {
        var input: EditorBarPointerInput?
        private var pendingClick: DispatchWorkItem?
        private var pendingLocation: CGPoint?
        private var start = CGPoint.zero
        private var dragging = false
        private var doubleClick = false
        private var generation = 0

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if pendingClick != nil {
                cancelPendingClick()
                // A second click of a double-click takes the jump back; a
                // separate new click keeps the first one.
                if event.clickCount > 1 { input?.onClickRevert() } else { input?.onClickCommit() }
            }
            start = convert(event.locationInWindow, from: nil)
            doubleClick = event.clickCount > 1
            dragging = false
            input?.onPress(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !doubleClick else { return }
            let point = convert(event.locationInWindow, from: nil)
            let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
            if !dragging {
                guard hypot(translation.width, translation.height) >= 3 else { return }
                dragging = true
                input?.onDragBegin(start)
            }
            input?.onDragChange(point, translation)
        }

        override func mouseUp(with event: NSEvent) {
            input?.onPress(false)
            if dragging {
                dragging = false
                input?.onDragEnd()
            } else if doubleClick {
                input?.onDoubleClick()
            } else {
                let location = convert(event.locationInWindow, from: nil)
                pendingLocation = location
                input?.onClickPreview(location)
                let currentGeneration = generation
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.pendingClick = nil
                    self.pendingLocation = nil
                    self.input?.onClickCommit()
                }
                pendingClick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }

        private func cancelPendingClick() {
            generation += 1
            pendingClick?.cancel()
            pendingClick = nil
            pendingLocation = nil
        }

        func cancel() {
            if pendingClick != nil { input?.onClickCommit() }
            cancelPendingClick()
            input?.onPress(false)
            if dragging {
                dragging = false
                input?.onDragEnd()
            }
            input = nil
        }
    }
}
