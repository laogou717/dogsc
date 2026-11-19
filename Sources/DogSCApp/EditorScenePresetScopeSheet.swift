import RecorderCore
import SwiftUI

struct EditorScenePresetScopeSheet: View {
    let preset: EditorStylePreset
    let project: RecorderProject
    let segments: [ResolvedRecordingSegment]
    @Binding var selectedIDs: Set<UUID>
    @Binding var appliesToAll: Bool
    let isApplying: Bool
    let onCancel: () -> Void
    let onApply: () -> Void

    private var targets: Set<UUID> { appliesToAll ? Set(segments.map(\.id)) : selectedIDs }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                AppLineIcon(kind: .layers, size: 18)
                    .foregroundStyle(EditorTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("应用场景预设").font(.appUI(size: 16, weight: .semibold))
                    Text(preset.name).font(.appUI(size: 12)).foregroundStyle(EditorTheme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: onCancel) { AppLineIcon(kind: .close, size: 15).frame(width: 26, height: 26).contentShape(Rectangle()) }
                    .buttonStyle(.editorGhost).accessibilityLabel("关闭应用范围").disabled(isApplying)
            }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
            VStack(alignment: .leading, spacing: 8) {
                Text("应用范围").font(.appUI(size: 12)).foregroundStyle(EditorTheme.secondaryText)
                EditorSegmentedControl(options: [false, true], title: { $0 ? "全部片段" : "选中片段" }, selection: $appliesToAll)
                    .disabled(isApplying)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            segmentRow(segment, index: index)
                        }
                    }.padding(.vertical, 1)
                }
                .scrollIndicators(.automatic)
                .frame(height: min(max(CGFloat(segments.count) * 62 - 6, 0), 304))
                .padding(.top, 7)
            }.padding(.horizontal, 20)
            HStack(spacing: 8) {
                Text(targets.isEmpty ? appLocalized("请选择片段") : String(format: appLocalized("已选 %lld 个片段"), Int64(targets.count)))
                    .font(.appUI(size: 11)).foregroundStyle(EditorTheme.secondaryText)
                Spacer(minLength: 8)
                if isApplying { ProgressView().controlSize(.small) }
                Button("取消", action: onCancel).buttonStyle(.editorGhost).keyboardShortcut(.cancelAction).disabled(isApplying)
                Button(action: onApply) {
                    Text(appliesToAll ? appLocalized("应用到全部片段") : String(format: appLocalized("应用到 %lld 个片段"), Int64(targets.count)))
                }
                .buttonStyle(.editorPrimary(minHeight: 30)).keyboardShortcut(.defaultAction)
                .disabled(targets.isEmpty || isApplying)
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
        }
        .foregroundStyle(EditorTheme.primaryText).frame(width: 436)
        .background(EditorTheme.panelRaised)
        .interactiveDismissDisabled(isApplying)
    }

    private func segmentRow(_ segment: ResolvedRecordingSegment, index: Int) -> some View {
        let selected = targets.contains(segment.id)
        let source = project.source(segment.sourceID)
        let device = source?.capture.source == .device
        let sourceName = segment.media?.name ?? (device ? appLocalized("设备录制") : RecordingSourcePresentation.name(segment.sourceID, in: project))
        return Button {
            if appliesToAll { selectedIDs = Set(segments.map(\.id)); appliesToAll = false }
            if selectedIDs.contains(segment.id) { selectedIDs.remove(segment.id) } else { selectedIDs.insert(segment.id) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(selected ? EditorTheme.accent : EditorTheme.panelRaised)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? EditorTheme.accent : EditorTheme.chrome(0.24), lineWidth: 1))
                    .overlay { if selected { EditorSymbol("checkmark", size: 10).foregroundStyle(.white) } }
                    .frame(width: 15, height: 15)
                EditorSymbol(device ? "iphone" : "display", size: 17)
                    .foregroundStyle(device ? RecordingDesign.sourceColors[0] : EditorTheme.secondaryText)
                    .frame(width: 31, height: 29).background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: appLocalized("第 %lld 段 · %@"), Int64(index + 1), sourceName))
                        .font(.appUI(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(RecordingSourcePresentation.duration(segment.outputStart)) – \(RecordingSourcePresentation.duration(segment.outputEnd))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(EditorTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Text(RecordingSourcePresentation.duration(segment.outputDuration))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(EditorTheme.secondaryText)
            }.padding(.horizontal, 10).frame(height: 54).contentShape(Rectangle())
                .background(selected ? EditorTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? EditorTheme.accent.opacity(0.52) : EditorTheme.hairline, lineWidth: 1))
        }.buttonStyle(.plain).disabled(isApplying)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
