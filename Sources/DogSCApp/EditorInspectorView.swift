import AppKit
import Foundation
import RecorderCore
import SwiftUI

enum EditorMotionInspectorMode: String, CaseIterable, Identifiable {
    case zoom
    case screen3D

    var id: String { rawValue }
}

/// Owns inspector navigation, controls, and interactive undo grouping. The
/// parent editor coordinates crop completion and provides system-facing work.
struct EditorInspectorView: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController

    let pointerEvents: [PointerEventRecord]
    let cursorAssets: [ResolvedCursorAsset]
    @Binding var selectedInspector: InspectorTab
    @Binding var isCameraSyncEditing: Bool
    @Binding var visibleTimelineTracks: EditorTimelineTrackVisibility
    let isCropping: Bool
    @Binding var cropDraft: NormalizedCrop
    /// 内容面板宽度（不含 66pt 图标轨），由编辑器分栏条实时解析。
    let contentWidth: CGFloat
    let onChooseWallpaper: () -> String?
    let onChooseDesktopWallpaper: () -> String?
    let onError: (String) -> Void

    @State var savedLayoutPresets: [SavedLayoutPreset] = []
    @State var isNamingLayoutPreset = false
    @State var layoutPresetName = ""
    @State var motionInspectorMode = EditorMotionInspectorMode.zoom
    @State var hoveredInspectorTab: InspectorTab?


    init(
        editorStore: EditorStore,
        mediaSession: EditorMediaSession,
        playbackController: EditorPlaybackController,
        pointerEvents: [PointerEventRecord],
        selectedInspector: Binding<InspectorTab>,
        isCameraSyncEditing: Binding<Bool>,
        visibleTimelineTracks: Binding<EditorTimelineTrackVisibility>,
        isCropping: Bool,
        cropDraft: Binding<NormalizedCrop>,
        contentWidth: CGFloat = EditorInspectorSizing.defaultContentWidth,
        onChooseWallpaper: @escaping () -> String?,
        onChooseDesktopWallpaper: @escaping () -> String?,
        onError: @escaping (String) -> Void
    ) {
        _editorStore = ObservedObject(wrappedValue: editorStore)
        _mediaSession = ObservedObject(wrappedValue: mediaSession)
        _playbackController = ObservedObject(wrappedValue: playbackController)
        self.pointerEvents = pointerEvents
        cursorAssets = CursorAssetLibrary.availableAssets
        _selectedInspector = selectedInspector
        _isCameraSyncEditing = isCameraSyncEditing
        _visibleTimelineTracks = visibleTimelineTracks
        self.isCropping = isCropping
        _cropDraft = cropDraft
        self.contentWidth = EditorInspectorSizing.clampedContentWidth(contentWidth)
        self.onChooseWallpaper = onChooseWallpaper
        self.onChooseDesktopWallpaper = onChooseDesktopWallpaper
        self.onError = onError
    }

    var playbackTime: TimeInterval { playbackController.outputTime }

    var sourceInventory: MediaAssetInventory { mediaSession.inventories.source }
    var cameraInventory: MediaAssetInventory { mediaSession.inventories.camera }
    var microphoneInventory: MediaAssetInventory { mediaSession.inventories.microphone }
    var sourcePixelSize: CGSize { mediaSession.sourceDisplaySize }
    var timelineDuration: TimeInterval { mediaSession.outputDuration }
    var sourceHasAudio: Bool { sourceInventory.hasAudio }
    var cameraHasVideo: Bool { cameraInventory.hasVideo }
    var microphoneHasAudio: Bool { microphoneInventory.hasAudio }

    var selectedZoomID: UUID? {
        get {
            guard case let .zoom(id) = editorStore.selection else { return nil }
            return id
        }
        nonmutating set {
            editorStore.selection = newValue.map(EditorSelection.zoom) ?? .zoomTrack
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            inspectorRail
                .disabled(isCropping)
                .opacity(isCropping ? 0.45 : 1)
            Divider().overlay(dividerColor)
            inspector
        }
        .onChange(of: editorStore.selection) { _, selection in
            switch selection {
            case .screenMotionTrack, .screenMotion:
                motionInspectorMode = .screen3D
            case .zoom, .zoomTrack:
                motionInspectorMode = .zoom
            default:
                break
            }
        }
    }

    var inspectorRail: some View {
        VStack(spacing: 6) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    selectedInspector = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(height: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: selectedInspector == tab ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(width: 52, height: 48)
                    .background(
                        inspectorRailBackground(for: tab),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .leading) {
                        if selectedInspector == tab {
                            Capsule()
                                .fill(editorAccent)
                                .frame(width: 2.5, height: 21)
                                .offset(x: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(inspectorRailForeground(for: tab))
                .disabled(!inspectorTabIsAvailable(tab))
                .opacity(inspectorTabIsAvailable(tab) ? 1 : 0.32)
                .accessibilityAddTraits(selectedInspector == tab ? .isSelected : [])
                .help(inspectorTabHelp(tab))
                .onHover { isHovering in
                    guard inspectorTabIsAvailable(tab) else { return }
                    if isHovering {
                        hoveredInspectorTab = tab
                    } else if hoveredInspectorTab == tab {
                        hoveredInspectorTab = nil
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 66)
        .background(Color.black.opacity(0.16))
        .animation(.easeOut(duration: 0.13), value: hoveredInspectorTab)
        .animation(.easeOut(duration: 0.13), value: selectedInspector)
    }

    func inspectorRailBackground(for tab: InspectorTab) -> Color {
        if selectedInspector == tab {
            return Color.white.opacity(0.12)
        }
        if hoveredInspectorTab == tab, inspectorTabIsAvailable(tab) {
            return Color.white.opacity(0.07)
        }
        return .clear
    }

    func inspectorRailForeground(for tab: InspectorTab) -> Color {
        if selectedInspector == tab {
            return .white
        }
        if hoveredInspectorTab == tab, inspectorTabIsAvailable(tab) {
            return Color.white.opacity(0.88)
        }
        return .secondary
    }

    func inspectorTabIsAvailable(_ tab: InspectorTab) -> Bool {
        switch tab {
        case .camera:
            return cameraHasVideo
        case .audio:
            return sourceHasAudio || microphoneHasAudio
        case .cursor:
            return !pointerEvents.isEmpty
        case .frame, .zoom:
            return true
        }
    }

    func inspectorTabHelp(_ tab: InspectorTab) -> String {
        guard !inspectorTabIsAvailable(tab) else { return tab.rawValue }
        switch tab {
        case .camera: return "当前项目没有摄像头素材"
        case .audio: return "当前项目没有系统声音或麦克风素材"
        case .cursor: return "当前项目没有记录鼠标事件"
        case .frame, .zoom: return tab.rawValue
        }
    }

    var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text(inspectorTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(panelBackground)
            .overlay(alignment: .bottom) {
                Divider().overlay(dividerColor)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inspectorContent
                }
                .padding(16)
            }
        }
        .frame(width: contentWidth)
        .background(panelBackground)
    }

    var inspectorTitle: String {
        if isCropping { return "裁切 · 屏幕素材" }
        switch editorStore.selection {
        case .canvas:
            return "画面 · 全片"
        case .screen:
            return "画面 · 初始状态"
        case .primarySegment:
            return "片段 · 当前片段"
        case .zoomTrack:
            return "运镜 · 全局设置"
        case .zoom:
            return "运镜 · 缩放片段"
        case .screenMotionTrack:
            return "运镜 · 屏幕 3D"
        case .screenMotion:
            return "运镜 · 屏幕 3D 片段"
        case .cursor:
            return "光标 · 全片"
        case .camera:
            return "摄像头 · 初始状态"
        case .cameraMotion:
            return "摄像头 · 动画目标"
        case .audio:
            return "音频 · 全片"
        case .crop:
            return "裁切 · 屏幕素材"
        case .mosaic:
            return "打码 · 选中区域"
        case .sticker:
            return "贴图 · 选中图片"
        case .progress:
            return "进度条 · 全片"
        case nil:
            return selectedInspector.rawValue
        }
    }

    @ViewBuilder
    var inspectorContent: some View {
        if isCropping {
            cropInspector
        } else if case .mosaic = editorStore.selection {
            overlayInspector
        } else if case .sticker = editorStore.selection {
            overlayInspector
        } else if editorStore.selection == .progress {
            overlayInspector
        } else if case let .primarySegment(id) = editorStore.selection {
            // 选中主片段给真正的片段面板：此前标题写着"当前片段"，内容却是
            // 全片初始状态控件，名实不符。
            primarySegmentInspector(id: id)
        } else {
            switch selectedInspector {
        case .frame:
            frameInspector
        case .zoom:
            motionInspector
        case .cursor:
            cursorInspector
        case .camera:
            cameraInspector
        case .audio:
            audioInspector
            }
        }
    }

    /// 合并后的"画面"页：背景、画布布局、屏幕素材位置与屏幕外观都是同一
    /// 个 CanvasStyle，按"美化画面"的任务顺序排在一页里，不再让用户在
    /// 两个页签之间猜参数归属。
    var frameInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorBackgroundInspector(
                editorStore: editorStore,
                onChooseWallpaper: onChooseWallpaper,
                onChooseDesktopWallpaper: onChooseDesktopWallpaper,
                onError: onError
            )

            EditorInspectorSection("画布布局") {
                sliderRow(
                    "背景模糊",
                    value: canvasBinding(\.backgroundBlur, actionName: "调整背景模糊"),
                    range: 0...80,
                    format: .points
                )
                .disabled(!editorStore.previewProject.canvas.backgroundSource.isImage)
                .opacity(editorStore.previewProject.canvas.backgroundSource.isImage ? 1 : 0.45)
                sliderRow(
                    "边距",
                    value: canvasBinding(\.padding, actionName: "调整画布边距"),
                    range: 0...360,
                    format: .points
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("屏幕素材 · 初始状态")
                    .font(.caption.weight(.semibold))
                Text("设置屏幕素材出现时的位置和外观；动画在“运镜”中添加。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            Label("直接在画布中拖动素材；拖右下角圆点缩放", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)

            EditorInspectorSection("快速对齐") {
                screenPositionGrid

                Button("居中并恢复大小") {
                    var canvas = editorStore.project.canvas
                    canvas.contentScale = 1
                    canvas.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
                    performEditorCommand {
                        try editorStore.replaceCanvas(with: canvas, actionName: "居中屏幕素材")
                    }
                }
                .buttonStyle(.editorQuiet)

                EditorDisclosure("精确数值") {
                    VStack(spacing: 10) {
                        sliderRow(
                            "素材缩放",
                            value: canvasBinding(\.contentScale, actionName: "缩放屏幕素材"),
                            range: 0.25...4,
                            format: .multiplier
                        )
                        sliderRow(
                            "水平位置",
                            value: canvasBinding(\.contentPosition.x, actionName: "移动屏幕素材"),
                            range: 0...1,
                            format: .percent
                        )
                        sliderRow(
                            "垂直位置",
                            value: canvasBinding(\.contentPosition.y, actionName: "移动屏幕素材"),
                            range: 0...1,
                            format: .percent
                        )
                    }
                }
            }

            EditorInspectorSection("屏幕外观") {
                EditorScreenFramePicker(editorStore: editorStore, onError: onError)
                if editorStore.project.canvas.screenFrame != .none {
                    sliderRow(
                        "样式大小",
                        value: canvasBinding(
                            \.screenFrameScale,
                            actionName: "调整屏幕样式大小"
                        ),
                        range: 0.6...1.6,
                        format: .multiplier
                    )
                } else {
                    sliderRow(
                        "画面圆角",
                        value: canvasBinding(\.cornerRadius, actionName: "调整画面圆角"),
                        range: 0...160,
                        format: .points
                    )
                }
                sliderRow(
                    "外描边",
                    value: canvasBinding(\.borderWidth, actionName: "调整屏幕描边"),
                    range: 0...40,
                    format: .points
                )
                if editorStore.project.canvas.borderWidth > 0 {
                    EditorTransactionalColorInput(
                        editorStore: editorStore,
                        title: "描边颜色",
                        value: canvasBinding(
                            \.borderColor,
                            actionName: "调整描边颜色"
                        ),
                        commandScope: .canvas,
                        actionName: "调整描边颜色",
                        onError: onError
                    )
                    sliderRow(
                        "描边透明度",
                        value: canvasBinding(\.insetOpacity, actionName: "调整描边透明度"),
                        range: 0...1,
                        format: .percent
                    )
                }
                sliderRow(
                    "阴影强度",
                    value: canvasBinding(\.shadowStrength, actionName: "调整屏幕阴影"),
                    range: 0...1,
                    format: .percent
                )
            }
        }
    }


    var cropInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("在画面上拖动边缘或四角，拖动框内可整体移动。", systemImage: "crop")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                cropEdgeStepper("左", edge: .left, pixels: sourcePixelSize.width)
                cropEdgeStepper("右", edge: .right, pixels: sourcePixelSize.width)
            }
            HStack(spacing: 8) {
                cropEdgeStepper("上", edge: .top, pixels: sourcePixelSize.height)
                cropEdgeStepper("下", edge: .bottom, pixels: sourcePixelSize.height)
            }

            Divider().overlay(dividerColor)

            LabeledContent("裁切后尺寸") {
                Text(cropSizeText).monospacedDigit()
            }
            .font(.caption)

            Button("恢复全部画面") { cropDraft = .full }
                .buttonStyle(.editorQuiet)
        }
    }

    func cropEdgeStepper(_ title: String, edge: CropEdge, pixels: CGFloat) -> some View {
        let pixelBinding = cropPixelBinding(edge, pixels: pixels)
        let maximumPixels = max(Int(pixels.rounded()) - 2, 0)
        return Stepper(
            value: pixelBinding,
            in: 0...maximumPixels,
            step: 1
        ) {
            HStack(spacing: 5) {
                Text(title)
                Spacer(minLength: 2)
                Text("\(cropPixelValue(edge, pixels: pixels)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)侧裁切")
        .accessibilityValue("\(pixelBinding.wrappedValue) 像素")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                pixelBinding.wrappedValue = min(pixelBinding.wrappedValue + 1, maximumPixels)
            case .decrement:
                pixelBinding.wrappedValue = max(pixelBinding.wrappedValue - 1, 0)
            @unknown default:
                break
            }
        }
    }

    func cropPixelBinding(_ edge: CropEdge, pixels: CGFloat) -> Binding<Int> {
        Binding(
            get: { cropPixelValue(edge, pixels: pixels) },
            set: { newValue in
                let dimension = max(Double(pixels), 1)
                let normalized = min(max(Double(newValue) / dimension, 0), 1)
                let current = cropDraft.clamped()
                var left = current.left
                var right = current.right
                var top = current.top
                var bottom = current.bottom
                let minimum = min(max(24 / dimension, 0.001), 0.5)
                switch edge {
                case .left:
                    left = min(normalized, max(1 - right - minimum, 0))
                case .right:
                    right = min(normalized, max(1 - left - minimum, 0))
                case .top:
                    top = min(normalized, max(1 - bottom - minimum, 0))
                case .bottom:
                    bottom = min(normalized, max(1 - top - minimum, 0))
                }
                cropDraft = .fromEdges(left: left, right: right, top: top, bottom: bottom)
            }
        )
    }

    func cropPixelValue(_ edge: CropEdge, pixels: CGFloat) -> Int {
        let crop = cropDraft.clamped()
        let value: Double
        switch edge {
        case .left: value = crop.left
        case .right: value = crop.right
        case .top: value = crop.top
        case .bottom: value = crop.bottom
        }
        return max(Int((value * Double(max(pixels, 1))).rounded()), 0)
    }


    func positionName(for index: Int) -> String {
        let names = [
            "左上", "上方居中", "右上",
            "左侧居中", "正中", "右侧居中",
            "左下", "下方居中", "右下",
        ]
        return names.indices.contains(index) ? names[index] : "位置"
    }

    // MARK: - Primary segment panel

    struct PrimarySegmentPanelContext {
        let segment: ResolvedRecordingSegment
        let index: Int
        let total: Int
        let junctionBefore: EditorTimelineSegmentJunction?
        let junctionAfter: EditorTimelineSegmentJunction?
        let leadingGap: EditorTimelineLeadingGap?
        let trailingGap: EditorTimelineTrailingGap?
        let fullSourceDuration: TimeInterval
        let frameDuration: TimeInterval
    }

    func primarySegmentContext(id: UUID) -> PrimarySegmentPanelContext? {
        guard let map = mediaSession.mediaPlan?.timelineMap,
              let index = map.segments.firstIndex(where: { $0.id == id }) else { return nil }
        let junctions = EditorPrimaryTimelinePresentation.segmentJunctions(from: map)
        let frameRate = max(editorStore.project.capture.captureFrameRate.rawValue, 1)
        return PrimarySegmentPanelContext(
            segment: map.segments[index],
            index: index,
            total: map.segments.count,
            junctionBefore: junctions.first { $0.nextSegmentID == id },
            junctionAfter: junctions.first { $0.previousSegmentID == id },
            leadingGap: EditorPrimaryTimelinePresentation.leadingGap(from: map),
            trailingGap: EditorPrimaryTimelinePresentation.trailingGap(from: map),
            fullSourceDuration: map.fullSourceDuration,
            frameDuration: 1 / Double(frameRate)
        )
    }

    /// 选中主片段时的专属面板。此前这里显示的是全片初始状态控件，标题却
    /// 写着"当前片段"，名实不符；现在给片段自己的信息与操作，与时间线
    /// 手势/快捷键共享同一组 EditorStore 命令。
    @ViewBuilder
    func primarySegmentInspector(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context = primarySegmentContext(id: id) {
                EditorInspectorSection("片段信息") {
                    LabeledContent("片段") {
                        Text("第 \(context.index + 1) 段，共 \(context.total) 段")
                    }
                    LabeledContent("输出时长") {
                        Text(segmentTimestamp(context.segment.outputDuration))
                            .monospacedDigit()
                    }
                    LabeledContent("速度") {
                        Text(playbackRateText(context.segment.playbackRate))
                            .monospacedDigit()
                    }
                    LabeledContent("输出区间") {
                        Text(
                            "\(segmentTimestamp(context.segment.outputStart)) – "
                                + segmentTimestamp(context.segment.outputEnd)
                        )
                        .monospacedDigit()
                    }
                    LabeledContent("源区间") {
                        Text(
                            "\(segmentTimestamp(context.segment.sourceStart)) – "
                                + segmentTimestamp(context.segment.sourceEnd)
                        )
                        .monospacedDigit()
                    }
                }
                .font(.caption)

                EditorInspectorSection("片段操作") {
                    Button {
                        splitPrimarySegmentFromInspector(context: context)
                    } label: {
                        Label("在播放头处分割", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.editorQuiet)
                    .disabled(!canSplitPrimarySegmentFromInspector(context: context))
                    .help(
                        canSplitPrimarySegmentFromInspector(context: context)
                            ? "在播放头处分割（S）"
                            : "把播放头移进这个片段内部后才能分割"
                    )

                    if let junctionBefore = context.junctionBefore,
                       junctionBefore.hasRemovedSourceGap {
                        Button {
                            restorePrimaryGapFromInspector(
                                junction: junctionBefore,
                                fullSourceDuration: context.fullSourceDuration
                            )
                        } label: {
                            Label(
                                "还原之前的剪切（已剪 \(segmentTimestamp(junctionBefore.removedDuration))）",
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }

                    if let junctionAfter = context.junctionAfter {
                        if junctionAfter.hasRemovedSourceGap {
                            Button {
                                restorePrimaryGapFromInspector(
                                    junction: junctionAfter,
                                    fullSourceDuration: context.fullSourceDuration
                                )
                            } label: {
                                Label(
                                    "还原之后的剪切（已剪 \(segmentTimestamp(junctionAfter.removedDuration))）",
                                    systemImage: "arrow.uturn.backward"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.editorQuiet)
                        } else {
                            Button {
                                mergeWithNextSegmentFromInspector(context: context)
                            } label: {
                                Label("合并与下一片段", systemImage: "link")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.editorQuiet)
                        }
                    }

                    if let leadingGap = context.leadingGap,
                       leadingGap.nextSegmentID == id {
                        Button {
                            do {
                                try editorStore.restorePrimaryLeadingGap(
                                    fullSourceDuration: context.fullSourceDuration,
                                    actionName: "还原开头剪切"
                                )
                            } catch {
                                onError(error.localizedDescription)
                            }
                        } label: {
                            Label(
                                "还原开头剪切（已剪 \(segmentTimestamp(leadingGap.removedDuration))）",
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }

                    if let trailingGap = context.trailingGap,
                       trailingGap.previousSegmentID == id {
                        Button {
                            do {
                                try editorStore.restorePrimaryTrailingGap(
                                    fullSourceDuration: context.fullSourceDuration,
                                    actionName: "还原结尾剪切"
                                )
                            } catch {
                                onError(error.localizedDescription)
                            }
                        } label: {
                            Label(
                                "还原结尾剪切（已剪 \(segmentTimestamp(trailingGap.removedDuration))）",
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.editorQuiet)
                    }

                    Button("删除这个片段", role: .destructive) {
                        deletePrimarySegmentFromInspector(context: context)
                    }
                    .buttonStyle(.borderless)
                }

                Text("也可以直接在时间线中拖动片段调整顺序、拖两端修剪；快捷键 S 分割、D 删除。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView(
                    "片段已不存在",
                    systemImage: "film",
                    description: Text("可能已在时间线中删除或被撤销。")
                )
                Button("返回画面设置") { editorStore.selection = .canvas }
                    .buttonStyle(.editorQuiet)
            }
        }
    }

    func playbackRateText(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.000_1 {
            return "\(Int(rate.rounded()))×"
        }
        return String(format: "%.1f×", rate)
    }

    func canSplitPrimarySegmentFromInspector(context: PrimarySegmentPanelContext) -> Bool {
        playbackTime - context.segment.outputStart >= context.frameDuration
            && context.segment.outputEnd - playbackTime >= context.frameDuration
    }

    func splitPrimarySegmentFromInspector(context: PrimarySegmentPanelContext) {
        let rightID = UUID()
        do {
            try editorStore.splitPrimarySegment(
                atOutputTime: playbackTime,
                fullSourceDuration: context.fullSourceDuration,
                newRightSegmentID: rightID,
                actionName: "分割主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        // 与时间线 S 键同一习惯：分割后选中右侧新片段。
        editorStore.selection = .primarySegment(rightID)
    }

    func deletePrimarySegmentFromInspector(context: PrimarySegmentPanelContext) {
        do {
            try editorStore.removePrimarySegment(
                id: context.segment.id,
                fullSourceDuration: context.fullSourceDuration,
                actionName: "删除主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        editorStore.selection = .canvas
    }

    func restorePrimaryGapFromInspector(
        junction: EditorTimelineSegmentJunction,
        fullSourceDuration: TimeInterval
    ) {
        do {
            try editorStore.restorePrimaryGap(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原该处剪切"
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    func mergeWithNextSegmentFromInspector(context: PrimarySegmentPanelContext) {
        guard let junctionAfter = context.junctionAfter else { return }
        do {
            try editorStore.mergeAdjacentPrimarySegments(
                previousSegmentID: junctionAfter.previousSegmentID,
                nextSegmentID: junctionAfter.nextSegmentID,
                fullSourceDuration: context.fullSourceDuration,
                actionName: "合并相邻主片段"
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    func segmentTimestamp(_ time: TimeInterval) -> String {
        let centiseconds = max(Int((time * 100).rounded(.down)), 0)
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        return String(format: "%d:%02d.%02d", minutes, seconds, fraction)
    }

    @ViewBuilder
    var motionInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorInspectorSection("运镜类型") {
                EditorSegmentedControl(
                    options: EditorMotionInspectorMode.allCases,
                    title: { $0 == .screen3D ? "屏幕 3D" : "自动缩放" },
                    icon: { $0 == .screen3D ? "cube.transparent" : "scope" },
                    selection: Binding(
                        get: { motionInspectorMode },
                        set: { mode in
                            motionInspectorMode = mode
                            switch mode {
                            case .zoom:
                                if case .zoom = editorStore.selection { return }
                                if editorStore.selection != .zoomTrack {
                                    editorStore.selection = .zoomTrack
                                }
                            case .screen3D:
                                if case .screenMotion = editorStore.selection { return }
                                if editorStore.selection != .screenMotionTrack {
                                    editorStore.selection = .screenMotionTrack
                                }
                            }
                        }
                    )
                )

            }

            if motionInspectorMode == .zoom {
                zoomInspector
            } else if case let .screenMotion(id) = editorStore.selection {
                ScreenMotionTargetInspector(
                    editorStore: editorStore,
                    clipID: id,
                    onError: onError
                )
            } else {
                MotionInspectorScopeHeader(
                    title: "屏幕 3D",
                    detail: "在播放头创建位置、大小和透视动画；可与缩放重叠。",
                    statusTitle: "未选中片段",
                    addTitle: "在播放头添加屏幕 3D",
                    onAdd: addScreenMotionAtPlayhead
                )

                if !editorStore.project.timeline.screenMotionClips.isEmpty,
                   !visibleTimelineTracks.contains(.screenMotion) {
                    Button {
                        visibleTimelineTracks.insert(.screenMotion)
                    } label: {
                        Label("显示屏幕 3D 轨道", systemImage: "eye")
                    }
                    .buttonStyle(.editorQuiet)
                }

                motionGlobalDefaults
            }
        }
    }

    var screenPositionGrid: some View {
        positionPickerGrid(
            selected: editorStore.project.canvas.contentPosition,
            onSelect: { position in
                var canvas = editorStore.project.canvas
                canvas.contentPosition = position
                performEditorCommand {
                    try editorStore.replaceCanvas(with: canvas, actionName: "快速对齐屏幕素材")
                }
            }
        )
    }

    var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let index = selectedZoomAnimationIndex {
                EditorInspectorSection("缩放片段") {
                    EditorSegmentedControl(
                        options: [ZoomKeyframeOrigin.automatic, .manual],
                        title: { $0 == .automatic ? "自动跟随" : "手动定位" },
                        selection: zoomAnimationOriginBinding(index)
                    )

                    sliderRow(
                        "缩放级别",
                        value: zoomAnimationDoubleBinding(index, keyPath: \.scale),
                        range: 1...6,
                        format: .multiplier
                    )
                    if editorStore.previewProject.zoomAnimations[index].origin == .manual {
                        ZoomFocusMap(
                            mediaSession: mediaSession,
                            outputTime: editorStore.project.zoomAnimations[index].startTime,
                            sourcePixelSize: sourcePixelSize,
                            focus: zoomAnimationFocusBinding(index),
                            onEditingChanged: {
                                updateEditorContinuousInteraction(
                                    store: editorStore, isEditing: $0,
                                    commandScope: .selection,
                                    actionName: "调整缩放焦点",
                                    onError: onError
                                )
                            }
                        )
                        Text("整张源画面会完整显示；圆圈可到真实四角，成片会自动留出舒适观看距离。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("自动跟随会优先让鼠标保持在画面内", systemImage: "cursorarrow.motionlines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                EditorInspectorSection("动画手感") {
                    sliderRow(
                        "过渡时长",
                        value: zoomAnimationTransitionDurationBinding(index),
                        range: 0.08...3,
                        format: .seconds
                    )
                    Text("进入和退出保持一致；数值越小越干脆，越大越柔和。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    EditorDisclosure("时间与精确数值") {
                        VStack(spacing: 9) {
                            zoomTimeStepper(
                                "开始位置",
                                value: zoomAnimationStartBinding(index),
                                range: 0...max(timelineDuration - 0.16, 0)
                            )
                            zoomTimeStepper(
                                "保持时长",
                                value: zoomAnimationDurationBinding(index),
                                range: 0.16...max(timelineDuration, 0.16)
                            )
                            sliderRow(
                                "焦点 X",
                                value: zoomAnimationFocusComponentBinding(index, keyPath: \.x),
                                range: 0...1,
                                format: .percent
                            )
                            sliderRow(
                                "焦点 Y",
                                value: zoomAnimationFocusComponentBinding(index, keyPath: \.y),
                                range: 0...1,
                                format: .percent
                            )
                        }
                    }
                }

                Button("删除这个动画片段", role: .destructive) {
                    if let selectedZoomID {
                        do {
                            try editorStore.removeZoom(id: selectedZoomID, actionName: "删除缩放")
                        } catch {
                            onError(error.localizedDescription)
                        }
                    }
                    selectedZoomID = nil
                }
                .buttonStyle(.borderless)
            } else {
                // 片段选择交还时间线：这里只保留创建与选中的引导，
                // 不再用间接的文字下拉列表代替时间线。
                Label(
                    "在“缩放”轨道拖动创建；选中片段后在这里调整",
                    systemImage: "timeline.selection"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

                motionGlobalDefaults
            }
        }
    }

    @ViewBuilder
    var motionGlobalDefaults: some View {
        EditorDisclosure("新动画过渡") {
            sliderRow(
                "过渡时长",
                value: motionBinding(
                    \.defaultZoomTransitionDuration,
                    actionName: "调整默认过渡时长"
                ),
                range: 0.08...3,
                interactionScope: .motion,
                format: .seconds
            )
        }

    }
}
