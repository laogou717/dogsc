import RecorderCore
import SwiftUI

/// EDT-079: two or more clips picked together. The title counts them
/// ("3 个柔化"); only the properties they share are shown, a value that
/// differs reads "—", and one change applies to all of them.
struct EditorGroupInspector: View {
    @ObservedObject var editorStore: EditorStore
    let items: Set<EditorSelection>

    static func title(for items: Set<EditorSelection>, timeline: ProjectTimeline) -> String {
        let names = Set(items.map { name(of: $0, timeline: timeline) })
        let noun = names.count == 1 ? names.first! : appLocalized("片段")
        return String(format: appLocalized("%d 个%@"), items.count, noun)
    }

    private static func name(of item: EditorSelection, timeline: ProjectTimeline) -> String {
        switch item {
        case .mosaic(let id):
            return timeline.mosaicClips.first { $0.id == id }?.style == .spotlight ? appLocalized("突出") : appLocalized("柔化")
        case .zoom: return appLocalized("缩放")
        case .screenMotion: return appLocalized("3D 运镜")
        case .cameraMotion: return appLocalized("摄像头运动")
        case .sticker: return appLocalized("贴图")
        case .animation: return appLocalized("动效")
        case .audioClip: return appLocalized("音频")
        case .subtitle: return appLocalized("字幕")
        case .videoClip: return appLocalized("视频")
        case .primarySegment: return appLocalized("片段")
        default: return appLocalized("片段")
        }
    }

    private var mosaicIDs: [UUID] {
        items.compactMap { if case .mosaic(let id) = $0 { id } else { nil } }
    }

    private var mosaics: [MosaicClip] {
        let ids = Set(mosaicIDs)
        return editorStore.previewProject.timeline.mosaicClips.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !mosaics.isEmpty, mosaics.count == items.count {
                EditorInspectorSection("外观") {
                    GroupSliderRow(title: "强度", values: mosaics.map(\.intensity), range: 0...1, percent: true) { v in
                        changeMosaics("调整强度") { $0.intensity = v }
                    }
                    GroupSliderRow(title: "圆角", values: mosaics.map(\.cornerRadius), range: 0...0.5, percent: true) { v in
                        changeMosaics("调整圆角") { $0.cornerRadius = v }
                    }
                    if mosaics.allSatisfy({ $0.style == .spotlight }) {
                        GroupSliderRow(title: "四周暗度", values: mosaics.map(\.spotlightDimming), range: 0...1, percent: true) { v in
                            changeMosaics("调整暗度") { $0.spotlightDimming = v }
                        }
                    }
                }
                EditorInspectorSection("时间") {
                    HStack(spacing: EditorPropertyRowMetrics.gap) {
                        Text(appLocalized("淡入淡出"))
                            .font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
                            .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
                        let styles = Set(mosaics.map(\.transitionStyle))
                        EditorSegmentedControl(
                            options: MosaicTransitionStyle.allCases,
                            title: { style in
                                switch style {
                                case .none: "无"
                                case .linear: "线性"
                                case .smooth: "平滑"
                                }
                            },
                            selection: Binding(
                                get: { styles.count == 1 ? styles.first! : .none },
                                set: { style in changeMosaics("调整淡入淡出") { $0.transitionStyle = style } }
                            )
                        )
                        .opacity(styles.count == 1 ? 1 : 0.6)
                    }
                }
            } else {
                Text(appLocalized("这些片段类型不同，没有共有的属性。可以一起移动或删除。"))
                    .font(.appUI(size: 12.5))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .padding(.vertical, 12)
            }

            HStack {
                Spacer()
                Button(String(format: appLocalized("删除 %d 个"), items.count), role: .destructive) {
                    removeAll()
                }
                .buttonStyle(.editorDestructive)
            }
            .padding(.top, 12)
        }
    }

    private func changeMosaics(_ action: String, _ body: @escaping (inout MosaicClip) -> Void) {
        let ids = Set(mosaicIDs)
        commitTimelineEdit(editorStore, action: action) { timeline in
            for index in timeline.mosaicClips.indices where ids.contains(timeline.mosaicClips[index].id) {
                body(&timeline.mosaicClips[index])
            }
        }
    }

    private func removeAll() {
        let picked = items
        commitTimelineEdit(editorStore, action: String(format: appLocalized("删除 %d 个"), picked.count)) { timeline in
            func has(_ make: (UUID) -> EditorSelection, _ id: UUID) -> Bool { picked.contains(make(id)) }
            timeline.mosaicClips.removeAll { has(EditorSelection.mosaic, $0.id) }
            timeline.stickerClips.removeAll { has(EditorSelection.sticker, $0.id) }
            timeline.animationClips.removeAll { has(EditorSelection.animation, $0.id) }
            timeline.audioClips.removeAll { has(EditorSelection.audioClip, $0.id) }
            timeline.subtitleCues.removeAll { has(EditorSelection.subtitle, $0.id) }
            timeline.videoClips.removeAll { has(EditorSelection.videoClip, $0.id) }
        }
        editorStore.groupSelection = []
        editorStore.selection = nil
    }
}

/// A slider row over several values: the shared value, or "—" with the
/// thumb at the start when they differ. Written once on release.
private struct GroupSliderRow: View {
    let title: String
    let values: [Double]
    let range: ClosedRange<Double>
    var percent = false
    let onCommit: (Double) -> Void
    @State private var draft: Double?

    private var shared: Double? {
        guard let first = values.first, values.allSatisfy({ abs($0 - first) < 0.0005 }) else { return nil }
        return first
    }

    var body: some View {
        EditorSliderRowLayout {
            Text(appLocalized(title))
                .font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: (draft ?? shared).map { percent ? "\(Int(($0 * 100).rounded()))%" : String(format: "%.1f", $0) } ?? "—")
                .font(.appUI(size: 12.5, design: .monospaced))
                .foregroundStyle((draft ?? shared) == nil ? EditorTheme.tertiaryText : EditorTheme.primaryText)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            EditorSlider(
                value: Binding(get: { draft ?? shared ?? range.lowerBound }, set: { draft = $0 }),
                range: range,
                showsFloatingValue: false,
                onEditingChanged: { editing in
                    if !editing, let draft { onCommit(draft); self.draft = nil }
                }
            )
        }
    }
}
