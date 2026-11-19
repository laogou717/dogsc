import AppKit
import RecorderCore
import SwiftUI

private struct CanvasQuickEditorPlacement {
    let point: CGPoint
    let transitionAnchor: UnitPoint
}

// MARK: - Shared float bar (画面 · 浮条)

/// One float-bar look for everything selected on the canvas (柔化与突出,
/// 贴图, 动效里的元素, 屏幕 3D): a raised white plate, 10 corners, a hairline
/// edge and a light cast shadow, 3 pt around 28-high buttons.
enum EditorFloatBarMetrics {
    static let buttonHeight: CGFloat = 28
    static let inset: CGFloat = 3
    static let cornerRadius: CGFloat = 10
    static var height: CGFloat { buttonHeight + inset * 2 }
}

struct EditorFloatBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: EditorFloatBarMetrics.cornerRadius, style: .continuous)
        HStack(spacing: 1) { content() }
            .padding(EditorFloatBarMetrics.inset)
            .frame(height: EditorFloatBarMetrics.height)
            .fixedSize(horizontal: true, vertical: false)
            .background(EditorTheme.panelRaised, in: shape)
            .overlay { shape.strokeBorder(EditorTheme.chrome(0.075), lineWidth: 0.5).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.16), radius: 11, y: 6)
            .environment(\.consolePalette, EditorConsole.opening)
            .contentShape(shape)
    }
}

struct EditorFloatBarSeparator: View {
    var body: some View {
        Rectangle().fill(EditorTheme.hairline)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

/// `.bb`: transparent, 28 high, 12.5-pt label; hover a light wash, the
/// current choice a deeper wash (or, inside a segment, a raised thumb).
struct EditorFloatBarButtonSurface<Content: View>: View {
    enum OnStyle { case wash, thumb }
    var isOn = false
    var onStyle: OnStyle = .wash
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let lit = isOn || (hovered && isEnabled)
        content()
            .font(.appUI(size: 12.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(lit ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .padding(.horizontal, 7)
            .frame(minWidth: EditorFloatBarMetrics.buttonHeight)
            .frame(height: EditorFloatBarMetrics.buttonHeight)
            .background {
                if isOn, onStyle == .thumb {
                    shape.fill(EditorTheme.segmentThumb)
                        .overlay(shape.strokeBorder(EditorTheme.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                } else {
                    shape.fill(EditorTheme.chrome(isOn ? 0.08 : hovered && isEnabled ? 0.045 : 0))
                }
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(SpringMotion.micro, value: hovered)
            .animation(SpringMotion.micro, value: isOn)
    }
}

struct EditorFloatBarButton: View {
    var title: String? = nil
    var icon: AppLineIcon.Kind? = nil
    var symbol: String? = nil
    let help: String
    var isOn = false
    var onStyle: EditorFloatBarButtonSurface<AnyView>.OnStyle = .wash
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EditorFloatBarButtonSurface(isOn: isOn, onStyle: onStyle) {
                AnyView(HStack(spacing: 5) {
                    if let icon { AppLineIcon(kind: icon, size: title == nil ? 16 : 14) }
                    else if let symbol { EditorSymbol(symbol, size: title == nil ? 16 : 14) }
                    if let title { Text(appLocalized(title)) }
                })
            }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 7, showsHover: false))
        .help(appLocalized(help))
        .accessibilityLabel(appLocalized(title ?? help))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// `.mini`: a short label and a 72-wide track inside the bar.
struct EditorFloatBarSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatValue: (Double) -> String
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(appLocalized(title))
                .font(.appUI(size: 12))
                .foregroundStyle(EditorTheme.secondaryText)
                .fixedSize()
            EditorSlider(value: $value, range: range, formatValue: formatValue, onEditingChanged: onEditingChanged)
                .frame(width: 72)
        }
        .padding(.horizontal, 6)
        .frame(height: EditorFloatBarMetrics.buttonHeight)
    }
}

extension CanvasPreview {
    /// The float bar of whatever is selected, positioned in the workspace
    /// layer above the picture: never under the spotlight's dimming, never
    /// clipped by the monitor, always clickable. Placed above the object,
    /// below it when there is no room; hidden while dragging.
    @ViewBuilder
    func overlayQuickEditor(
        scene: FrameScene,
        canvasSize: CGSize,
        availableSize: CGSize,
        time: TimeInterval
    ) -> some View {
        Group {
            if let bar = floatBarTarget(scene: scene, canvasSize: canvasSize, time: time) {
                let width = min(
                    quickEditorMeasuredWidths[bar.key] ?? bar.estimatedWidth,
                    max(availableSize.width - 16, 1)
                )
                let placement = quickEditorPlacement(
                    bounds: bar.bounds, canvasSize: canvasSize,
                    availableSize: availableSize, width: width
                )
                floatBar(bar.kind)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                        guard measured.isFinite, measured > 0,
                              abs((quickEditorMeasuredWidths[bar.key] ?? 0) - measured) > 0.5 else { return }
                        quickEditorMeasuredWidths[bar.key] = ceil(measured)
                    }
                    .position(placement.point)
                    .transition(.opacity)
                    .id(bar.key)
            }
        }
        .animation(SpringMotion.fade, value: editorStore.selection)
    }

    fileprivate enum FloatBarKind {
        case mosaic(MosaicClip)
        case sticker(StickerClip)
        case element(MotionElementTarget, MotionElement, MotionElementEdit)
        case screenMotion(ScreenMotionClip)
    }

    fileprivate struct FloatBarTarget {
        let key: String
        let kind: FloatBarKind
        let bounds: CGRect
        let estimatedWidth: CGFloat
    }

    fileprivate func floatBarTarget(scene: FrameScene, canvasSize: CGSize, time: TimeInterval) -> FloatBarTarget? {
        switch editorStore.selection {
        case let .mosaic(id):
            guard let clip = editorStore.previewProject.timeline.mosaicClips.first(
                where: { $0.id == id && $0.timing.contains(time) }
            ), let quad = mosaicSelectionQuad(clip: clip, screen: scene.screen) else { return nil }
            return FloatBarTarget(
                key: Self.mosaicQuickEditorKey, kind: .mosaic(clip),
                bounds: CGRect(x: quad.bounds.x, y: quad.bounds.y, width: quad.bounds.width, height: quad.bounds.height),
                estimatedWidth: 300
            )
        case let .sticker(id):
            guard let clip = editorStore.previewProject.timeline.stickerClips.first(where: { $0.id == id }),
                  let sticker = scene.stickers.first(where: { $0.id == id }) else { return nil }
            let width = canvasSize.width * sticker.width * sticker.scale
            let sourceSize = resolvedStickerImages[sticker.relativePath]?.size ?? CGSize(width: 1, height: 1)
            let height = width * max(sourceSize.height, 1) / max(sourceSize.width, 1)
            let center = CGPoint(
                x: canvasSize.width * (sticker.position.x + sticker.offset.x),
                y: canvasSize.height * (sticker.position.y + sticker.offset.y)
            )
            let size = CGSize(width: width, height: height)
            let bounds = rotatedStickerBounds(center: center, size: size, rotation: sticker.rotationRadians)
            let handle = stickerRotationHandleGeometry(
                center: center, size: size, rotation: sticker.rotationRadians, canvasSize: canvasSize
            )
            return FloatBarTarget(
                key: Self.stickerQuickEditorKey, kind: .sticker(clip),
                bounds: bounds.union(CGRect(x: handle.handle.x - 9, y: handle.handle.y - 9, width: 18, height: 18)),
                estimatedWidth: 190
            )
        case .animation, .primarySegment:
            // 动效里的元素: one element picked inside the motion.
            guard let target = motionElementEditor.target,
                  target.selection == editorStore.selection,
                  motionElementEditor.selected.count == 1,
                  let id = motionElementEditor.selected.first,
                  let element = motionElementEditor.elements.first(where: { $0.id == id }),
                  let placement = MotionElementPlacement.resolve(target, scene: scene, canvasSize: canvasSize)
            else { return nil }
            let rect = placement.canvasRect(element, measured: motionElementEditor.measuredEdits)
            return FloatBarTarget(
                key: "element", kind: .element(target, element, placement.edits[id] ?? MotionElementEdit()),
                // Clear the element's name tag above the selection box.
                bounds: rect.insetBy(dx: -6, dy: -4).offsetBy(dx: 0, dy: -12).union(rect),
                estimatedWidth: element.text == nil ? 110 : 170
            )
        case let .screenMotion(id):
            guard let clip = editorStore.previewProject.timeline.screenMotionClips.first(where: { $0.id == id }),
                  clip.focusEffect == nil else { return nil }
            let quad = scene.screen.projectedQuad.bounds
            return FloatBarTarget(
                key: "screenMotion", kind: .screenMotion(clip),
                bounds: CGRect(x: quad.x, y: quad.y, width: quad.width, height: quad.height),
                estimatedWidth: 260
            )
        default:
            return nil
        }
    }

    @ViewBuilder
    fileprivate func floatBar(_ kind: FloatBarKind) -> some View {
        switch kind {
        case let .mosaic(clip): mosaicQuickEditor(clip)
        case let .sticker(clip): stickerQuickEditor(clip)
        case let .element(target, element, edit): elementQuickEditor(target: target, element: element, edit: edit)
        case let .screenMotion(clip): screenMotionQuickEditor(clip)
        }
    }

    static let mosaicQuickEditorKey = "mosaic"
    static let stickerQuickEditorKey = "sticker"

    // MARK: 柔化与突出

    func mosaicQuickEditor(_ clip: MosaicClip) -> some View {
        let editsSpotlight = clip.style == .spotlight
        return EditorFloatBar {
            // The two modes are one choice: a pair in a single groove.
            HStack(spacing: 0) {
                EditorFloatBarButton(title: "柔化", icon: .drop, help: "柔化",
                                     isOn: clip.style == .blur, onStyle: .thumb) {
                    replaceMosaic(id: clip.id, actionName: "切换区域效果") { $0.style = .blur }
                }
                EditorFloatBarButton(title: "突出", icon: .spotlight, help: "突出",
                                     isOn: editsSpotlight, onStyle: .thumb) {
                    replaceMosaic(id: clip.id, actionName: "切换区域效果") { $0.style = .spotlight }
                }
            }
            EditorFloatBarSeparator()
            EditorFloatBarSlider(
                title: editsSpotlight ? "暗度" : "强度",
                value: quickMosaicBinding(
                    id: clip.id,
                    keyPath: editsSpotlight ? \.spotlightDimming : \.intensity,
                    fallback: editsSpotlight ? clip.spotlightDimming : clip.intensity
                ),
                range: editsSpotlight ? 0...0.75 : 0...1,
                formatValue: { "\(Int(($0 * 100).rounded()))%" },
                onEditingChanged: { editing in
                    finishQuickOverlayInteraction(
                        editing: editing,
                        actionName: editsSpotlight ? "调整突出暗度" : "调整柔化强度"
                    )
                }
            )
            .accessibilityLabel(appLocalized(editsSpotlight ? "突出暗度" : "柔化强度"))
            EditorFloatBarSeparator()
            EditorFloatBarButton(icon: .duplicate, help: "复制") { duplicateMosaic(clip) }
            EditorFloatBarButton(icon: .trash, help: "删除") { removeSelectedFloatBarOverlay() }
        }
    }

    func duplicateMosaic(_ clip: MosaicClip) {
        var copy = clip
        copy.id = UUID()
        var rect = copy.sourceRect
        rect.x = min(rect.x + 0.03, max(1 - rect.width, 0))
        rect.y = min(rect.y + 0.03, max(1 - rect.height, 0))
        copy.sourceRect = rect
        var timeline = editorStore.project.timeline
        timeline.mosaicClips.append(copy)
        replaceOverlayTimeline(timeline, actionName: "复制柔化区域")
        editorStore.selection = .mosaic(copy.id)
    }

    func removeSelectedFloatBarOverlay() {
        do { try editorStore.removeSelectedOverlay() } catch { onError(error.localizedDescription) }
    }

    // MARK: 贴图

    /// The two things reached for most on a pasted picture: how it comes
    /// in, and whether the recording steps aside. Everything else lives in
    /// the inspector.
    func stickerQuickEditor(_ clip: StickerClip) -> some View {
        let motion = StickerMotionStyle(clip.animation)
        return EditorFloatBar {
            EditorActionMenu(title: "贴图动画", items: StickerMotionStyle.allCases.map { style in
                .action(style.entranceTitle, isOn: motion == style) {
                    guard style != motion else { return }
                    replaceSticker(id: clip.id, actionName: "选择贴图动画") {
                        $0.animation = style.preset(direction: StickerSlideDirection($0.animation) ?? .left)
                    }
                }
            }, showsHover: false) {
                EditorFloatBarButtonSurface {
                    HStack(spacing: 5) {
                        Text(appLocalized(motion.entranceTitle))
                        AppLineIcon(kind: .chevronDown, size: 9).foregroundStyle(EditorTheme.tertiaryText)
                    }
                }
            }
            .help("选择贴图动画")
            .accessibilityValue(appLocalized(motion.entranceTitle))
            EditorFloatBarSeparator()
            EditorFloatBarButton(
                title: "仅背景",
                help: clip.hidesScreen ? "恢复录屏画面" : "隐藏录屏画面，仅保留画布背景与贴图",
                isOn: clip.hidesScreen
            ) {
                replaceSticker(id: clip.id, actionName: clip.hidesScreen ? "关闭贴图仅背景" : "开启贴图仅背景") {
                    $0.hidesScreen.toggle()
                }
            }
            EditorFloatBarSeparator()
            EditorFloatBarButton(icon: .trash, help: "删除") { removeSelectedFloatBarOverlay() }
        }
    }

    // MARK: 动效里的元素

    func elementQuickEditor(target: MotionElementTarget, element: MotionElement, edit: MotionElementEdit) -> some View {
        EditorFloatBar {
            if element.text != nil {
                EditorFloatBarTextButton(
                    text: edit.text ?? element.text ?? "",
                    isPresented: Binding(
                        get: { motionElementEditor.target == target && motionElementEditor.textEditingElementID == element.id },
                        set: { motionElementEditor.textEditingElementID = $0 ? element.id : nil }
                    ),
                    onCommit: { value in
                        changeMotionElement(target, id: element.id, actionName: "修改动效文字") {
                            $0.text = value
                        }
                    }
                )
                EditorMotionTypographyControls(element: element, edit: edit) { family in
                    changeMotionElement(target, id: element.id, actionName: "修改动效字体") { $0.fontFamily = family }
                } onWeight: { weight in
                    changeMotionElement(target, id: element.id, actionName: "切换动效粗体") { $0.fontWeight = weight }
                }
            }
            let colorKey = element.text != nil ? edit.color ?? element.color : edit.fill ?? element.fill
            if element.kind != "image" {
                EditorFloatBarColorButton(
                    title: element.text != nil ? "文字颜色" : "填充颜色",
                    value: colorKey.flatMap { HexColor($0) } ?? HexColor(rgb24: 0x161817)
                ) { color in
                    changeMotionElement(target, id: element.id, actionName: "修改动效颜色") {
                        if element.text != nil { $0.color = color.hexString } else { $0.fill = color.hexString }
                    }
                }
            }
            EditorFloatBarButton(icon: .eye, help: "隐藏") {
                changeMotionElement(target, id: element.id, actionName: "隐藏动效元素") { $0.hidden = true }
                motionElementEditor.selected.remove(element.id)
            }
        }
    }

    func changeMotionElement(
        _ target: MotionElementTarget, id: String, actionName: String,
        _ change: @escaping (inout MotionElementEdit) -> Void
    ) {
        editorStore.changeMotionElementEdits(target, actionName: actionName) { edits in
            var edit = edits[id] ?? MotionElementEdit()
            change(&edit)
            edits[id] = edit
        }
    }

    // MARK: 屏幕 3D

    func screenMotionQuickEditor(_ clip: ScreenMotionClip) -> some View {
        let current = EditorScreenTiltPreset.matching(rotationX: clip.target.rotationX, rotationY: clip.target.rotationY)
        return EditorFloatBar {
            ForEach(EditorScreenTiltPreset.allCases) { preset in
                EditorFloatBarButton(title: preset.title, help: preset.title, isOn: current == preset) {
                    applyScreenTilt(clipID: clip.id, x: preset.rotationX, y: preset.rotationY, actionName: "套用 3D 姿态")
                }
            }
            EditorFloatBarSeparator()
            EditorFloatBarButton(icon: .trash, help: "删除") {
                do {
                    try editorStore.removeScreenMotion(id: clip.id)
                    editorStore.selection = .screen
                } catch {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    func applyScreenTilt(clipID: UUID, x: Double, y: Double, actionName: String) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.screenMotionClips.firstIndex(where: { $0.id == clipID }) else { return }
        timeline.screenMotionClips[index].target.rotationX = x
        timeline.screenMotionClips[index].target.rotationY = y
        replaceOverlayTimeline(timeline, actionName: actionName)
        editorStore.selection = .screenMotion(clipID)
    }

    private func quickEditorPlacement(
        bounds: CGRect,
        canvasSize: CGSize,
        availableSize: CGSize,
        width: CGFloat
    ) -> CanvasQuickEditorPlacement {
        let editorHeight = EditorFloatBarMetrics.height
        let edgeMargin: CGFloat = 8
        let objectGap: CGFloat = 8
        let visibleBounds = bounds.intersection(CGRect(origin: .zero, size: canvasSize))
        let targetBounds = visibleBounds.isNull ? bounds : visibleBounds
        let availableBounds = CGRect(
            x: (canvasSize.width - availableSize.width) / 2,
            y: (canvasSize.height - availableSize.height) / 2,
            width: availableSize.width,
            height: availableSize.height
        ).insetBy(dx: edgeMargin, dy: edgeMargin)
        let half = width / 2
        let halfHeight = editorHeight / 2
        // The mockup aligns the bar to the object's leading edge.
        let x = min(
            max(targetBounds.minX + half, availableBounds.minX + half),
            availableBounds.maxX - half
        )
        let aboveY = targetBounds.minY - objectGap - halfHeight
        let belowY = targetBounds.maxY + objectGap + halfHeight
        if aboveY - halfHeight >= availableBounds.minY {
            return CanvasQuickEditorPlacement(point: CGPoint(x: x, y: aboveY), transitionAnchor: .bottom)
        }
        if belowY + halfHeight <= availableBounds.maxY {
            return CanvasQuickEditorPlacement(point: CGPoint(x: x, y: belowY), transitionAnchor: .top)
        }
        // No room either side: inside the object's top edge.
        let insideY = min(max(targetBounds.minY + objectGap + halfHeight, availableBounds.minY + halfHeight),
                          availableBounds.maxY - halfHeight)
        return CanvasQuickEditorPlacement(point: CGPoint(x: x, y: insideY), transitionAnchor: .top)
    }

    private func rotatedStickerBounds(
        center: CGPoint,
        size: CGSize,
        rotation: Double
    ) -> CGRect {
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        let width = size.width * cosine + size.height * sine
        let height = size.width * sine + size.height * cosine
        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    func quickMosaicBinding(
        id: UUID,
        keyPath: WritableKeyPath<MosaicClip, Double>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                editorStore.previewProject.timeline.mosaicClips.first {
                    $0.id == id
                }?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                _ = editorStore.beginContinuousInteraction(
                    commandScope: .selection,
                    selection: .mosaic(id)
                )
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.mosaicClips.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    project.timeline.mosaicClips[index][keyPath: keyPath] = value
                }
            }
        )
    }

    func quickStickerBinding(
        id: UUID,
        keyPath: WritableKeyPath<StickerClip, Double>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                editorStore.previewProject.timeline.stickerClips.first {
                    $0.id == id
                }?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                _ = editorStore.beginContinuousInteraction(
                    commandScope: .selection,
                    selection: .sticker(id)
                )
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.stickerClips.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    project.timeline.stickerClips[index][keyPath: keyPath] = value
                }
            }
        )
    }

    func finishQuickOverlayInteraction(editing: Bool, actionName: String) {
        guard !editing else { return }
        do {
            _ = try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    func replaceMosaic(
        id: UUID,
        actionName: String,
        update: (inout MosaicClip) -> Void
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&timeline.mosaicClips[index])
        replaceOverlayTimeline(timeline, actionName: actionName)
        editorStore.selection = .mosaic(id)
    }

    func replaceSticker(
        id: UUID,
        actionName: String,
        update: (inout StickerClip) -> Void
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&timeline.stickerClips[index])
        replaceOverlayTimeline(timeline, actionName: actionName)
        editorStore.selection = .sticker(id)
    }

    func replaceOverlayTimeline(_ timeline: ProjectTimeline, actionName: String) {
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
        }
    }

}

/// The float bar's "编辑文字" button: opens a small field for the element's
/// text; Return or clicking away commits.
private struct EditorFloatBarTextButton: View {
    let text: String
    @Binding var isPresented: Bool
    let onCommit: (String) -> Void

    var body: some View {
        EditorFloatBarButton(icon: .pencil, help: "编辑文字", isOn: isPresented) { isPresented = true }
            .editorPopover(isPresented: $isPresented, arrowEdge: .bottom, establishesKeyboardEntry: false) {
                EditorCommittingTextField(title: appLocalized("文字"), text: text, showsTitle: false,
                    focusesOnAppear: true, onSubmitAction: { isPresented = false }, onCommit: onCommit)
                    .frame(width: 240)
                    .padding(10)
            }
    }
}

/// The float bar's colour button: the swatch itself; click for the palette.
private struct EditorFloatBarColorButton: View {
    let title: String
    let value: HexColor
    let onPreview: (HexColor) -> Void
    @State private var isPresented = false
    @State private var commit: Task<Void, Never>?

    var body: some View {
        Button { isPresented = true } label: {
            EditorFloatBarButtonSurface(isOn: isPresented) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: value))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 7, showsHover: false))
        .help(appLocalized(title))
        .accessibilityLabel(appLocalized(title))
        .accessibilityValue(value.hexString)
        .editorPopover(isPresented: $isPresented, arrowEdge: .bottom, establishesKeyboardEntry: false) {
            EditorColorPalette(title: title, value: value) { color in
                // One undo step per settled colour, like the inspector row.
                commit?.cancel()
                commit = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    onPreview(color)
                }
            }
        }
    }
}
