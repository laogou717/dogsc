import RecorderCore
import SwiftUI

/// A shared opening schedule, not independent clips: the first row adjusts
/// total duration, later rows adjust the common stagger, and any right grip
/// adjusts duration. Artwork can resize; the input coordinate system cannot.
struct EditorOpeningTimeline: View {
    @ObservedObject var editorStore: EditorStore
    let sequence: OpeningSequence
    let elements: [OpeningSequenceElement]
    let stagger: Binding<Double>
    let duration: Binding<Double>
    let title: (OpeningSequenceElement) -> String
    let icon: (OpeningSequenceElement) -> String
    let onError: (String) -> Void

    @Environment(\.consolePalette) private var palette
    @Environment(\.editorInsideTile) private var insideTile
    @Environment(\.consoleReveal) private var reveals
    @Environment(\.isEnabled) private var isEnabled
    @State private var frozenDomain: Double?
    @State private var activeIndex: Int?
    @State private var hoveredIndex: Int?
    @State private var hoveredEdge = false
    @State private var grown = true
    @State private var coordinateSpaceID = UUID()
    @State private var dragState: EditorOpeningTimingDrag?
    @State private var interactionID: UUID?

    private let labelWidth: CGFloat = 70
    private let rowHeight: CGFloat = 34
    private let railInset: CGFloat = 3
    private var domain: Double { max(sequence.duration, frozenDomain ?? 1, 1) }

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(proxy.size.width - labelWidth - 8, 40)
            let geometry = EditorOpeningTimingGeometry(
                duration: sequence.duration, stagger: sequence.stagger, count: elements.count,
                minimumDuration: OpeningSequence.minimumElementDuration,
                domain: domain, width: Double(trackWidth - railInset * 2)
            )
            VStack(alignment: .leading, spacing: 6) {
                axis(trackWidth: trackWidth)
                ForEach(Array(elements.enumerated()), id: \.element) { index, element in
                    row(index: index, element: element, trackWidth: trackWidth, geometry: geometry)
                }
            }
            .animation(activeIndex == nil && !RecorderMotion.reduces
                ? SpringMotion.standard : nil, value: domain)
        }
        .coordinateSpace(name: coordinateSpaceID)
        .frame(height: 20 + CGFloat(elements.count) * (rowHeight + 6))
        .onAppear {
            grown = true
        }
        .onChange(of: editorStore.interaction?.id) { _, id in
            if activeIndex != nil, id != interactionID { reset() }
        }
        .onDisappear { finish() }
    }

    private func axis(trackWidth: CGFloat) -> some View {
        let step = domain > 4 ? 2.0 : 1.0
        let ticks = Array(stride(from: 0.0, through: domain + 0.001, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                Text("\(Int(tick))s")
                    .font(.appUI(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .fixedSize()
                    .position(x: labelWidth + 8 + railInset
                        + CGFloat(tick / domain) * (trackWidth - railInset * 2), y: 7)
            }
        }
        .frame(height: 14)
    }

    private func row(index: Int, element: OpeningSequenceElement, trackWidth: CGFloat,
                     geometry: EditorOpeningTimingGeometry) -> some View {
        let frame = geometry.frame(index: index)
        let interval = geometry.interval(index: index)
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                EditorSymbol(icon(element), size: 14.5)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .frame(width: 14)
                Text(appLocalized(title(element)))
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: labelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(EditorWell.fill(insideTile: insideTile))
                bar(index: index, interval: interval, width: CGFloat(frame.width),
                    originX: labelWidth + 8 + railInset + CGFloat(frame.x),
                    inputWidth: trackWidth - railInset * 2)
                    .offset(x: CGFloat(frame.x) + railInset)
            }
            .frame(width: trackWidth, height: rowHeight - 4)
            .clipShape(Capsule())
        }
        .frame(height: rowHeight)
    }

    private func bar(index: Int, interval: ClosedRange<Double>, width: CGFloat,
                     originX: CGFloat, inputWidth: CGFloat) -> some View {
        let fill = palette?.fill ?? EditorTheme.platinumAccent
        let ink = palette?.ink ?? EditorTheme.onAccent
        let active = activeIndex == index
        let hovered = hoveredIndex == index
        return ZStack(alignment: .leading) {
            Capsule(style: .continuous).fill(fill)
                .opacity(active ? 1 : hovered ? 0.97 : 0.92)
            Text(rangeText(interval))
                .font(.appUI(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.leading, 10).padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(width > 84 ? 1 : 0)
            // The left edge is anchored by the schedule, not a resize handle.
            if width >= 18 {
                Capsule(style: .continuous).fill(ink.opacity(0.65))
                    .frame(width: 2.5, height: 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 7)
            }
        }
        .frame(width: width, height: rowHeight - 10)
        .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
        .contentShape(Rectangle())
        .editorCursor(index == 0 || (hovered && hoveredEdge) ? .resizeLeftRight : .openHand)
        .help(appLocalized(index == 0 ? "拖动调时长" : "拖动调间隔 · 右端调时长"))
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                hoveredIndex = index
                hoveredEdge = point.x >= width - 16
            case .ended:
                if hoveredIndex == index { hoveredIndex = nil; hoveredEdge = false }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceID))
                .onChanged { drag in
                    let adjustment: EditorOpeningTimingDrag.Adjustment =
                        index == 0 || drag.startLocation.x >= originX + width - 16
                        ? .duration : .stagger(index: index)
                    apply(index: index, adjustment: adjustment, translation: drag.translation.width,
                        inputWidth: inputWidth)
                }
                .onEnded { drag in
                    // Do not start a new draft if a late mouse-up follows an
                    // external replacement. Flush the final sample only.
                    if activeIndex == index, let state = dragState {
                        apply(index: index, adjustment: state.adjustment,
                            translation: drag.translation.width, inputWidth: inputWidth)
                    }
                    finish()
                }
        )
        .focusable(isEnabled)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard isEnabled else { return .ignored }
            step(index: index, increment: press.key == .rightArrow, coarse: press.modifiers.contains(.shift))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(appLocalized(title(elements[index])))
        .accessibilityValue(rangeText(interval))
        .accessibilityHint(appLocalized(index == 0 ? "调整开场总时长" : "调整开场元素间隔"))
        .accessibilityAdjustableAction { direction in
            step(index: index, increment: direction == .increment, coarse: false)
        }
    }

    private func rangeText(_ interval: ClosedRange<Double>) -> String {
        "\(EditorSliderValueFormat.compact(interval.lowerBound, digits: 2))–\(EditorSliderValueFormat.compact(interval.upperBound, digits: 2))s"
    }

    private func step(index: Int, increment: Bool, coarse: Bool) {
        guard isEnabled, activeIndex == nil else { return }
        _ = editorStore.beginContinuousInteraction(commandScope: .project)
        let sign: Double = increment ? 1 : -1
        if index == 0 {
            duration.wrappedValue = min(max(duration.wrappedValue + sign * (coarse ? 0.5 : 0.1), 0.4), 8)
        } else {
            let maximum = sequence.maximumStagger(for: sequence.includedElements.count)
            stagger.wrappedValue = min(max(stagger.wrappedValue + sign * (coarse ? 0.2 : 0.05), 0), maximum)
        }
        updateEditorContinuousInteraction(store: editorStore, isEditing: false, commandScope: .project,
            actionName: index == 0 ? "调整开场总时长" : "调整开场元素间隔", onError: onError)
    }

    private func apply(index: Int, adjustment: EditorOpeningTimingDrag.Adjustment,
                       translation: CGFloat, inputWidth: CGFloat) {
        guard isEnabled else { return }
        if activeIndex == nil {
            guard editorStore.beginContinuousInteraction(commandScope: .project,
                commitsWhenReplacedAs: "调整开场时序"), let id = editorStore.interaction?.id else { return }
            interactionID = id
            activeIndex = index
            frozenDomain = domain
            dragState = EditorOpeningTimingDrag(adjustment: adjustment,
                domain: domain, width: Double(inputWidth))
        }
        guard activeIndex == index, editorStore.interaction?.id == interactionID,
              var state = dragState, let delta = state.delta(translation: Double(translation)) else { return }
        dragState = state
        switch state.adjustment {
        case .duration:
            duration.wrappedValue = min(max(duration.wrappedValue + delta, 0.4), 8)
            EditorConsoleHUD.shared.show(label: "总时长", value: EditorSliderValueFormat.seconds.text(for: duration.wrappedValue))
        case .stagger:
            let maximum = sequence.maximumStagger(for: sequence.includedElements.count)
            stagger.wrappedValue = min(max(stagger.wrappedValue + delta, 0), maximum)
            EditorConsoleHUD.shared.show(label: "间隔", value: EditorSliderValueFormat.seconds.text(for: stagger.wrappedValue))
        }
    }

    private func finish() {
        guard activeIndex != nil else { return }
        if editorStore.interaction?.id == interactionID {
            updateEditorContinuousInteraction(store: editorStore, isEditing: false, commandScope: .project,
                actionName: "调整开场时序", onError: onError)
        }
        reset()
    }

    private func reset() {
        activeIndex = nil
        frozenDomain = nil
        dragState = nil
        interactionID = nil
        EditorConsoleHUD.shared.release()
    }
}
