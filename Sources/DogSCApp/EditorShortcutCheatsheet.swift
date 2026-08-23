import SwiftUI

/// Compact reference for every editor keyboard/gesture shortcut. The entries
/// were previously scattered across tooltips and context menus, so discovery
/// depended on hovering the right control. One static table now owns them;
/// when a shortcut changes, this table changes in the same commit.
struct EditorShortcutCheatsheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }

    private struct Group {
        let title: String
        let entries: [Entry]
    }

    private let groups: [Group] = [
        Group(title: "播放与浏览", entries: [
            Entry(keys: "空格", action: "播放 / 暂停"),
            Entry(keys: "悬停时间线", action: "预览所指帧，不移动播放头"),
            Entry(keys: "拖动总览条", action: "快速定位播放头与可视范围"),
            Entry(keys: "滚轮 / 捏合", action: "以指针为锚缩放时间线"),
        ]),
        Group(title: "剪辑", entries: [
            Entry(keys: "S", action: "在播放头处分割选中项"),
            Entry(keys: "Q", action: "波纹删除播放头之前"),
            Entry(keys: "W", action: "波纹删除播放头之后"),
            Entry(keys: "D / Delete", action: "删除当前选中项"),
            Entry(keys: "⌥ 点击片段", action: "在点击处直接切分"),
            Entry(keys: "悬停剪切缝", action: "合并或还原该处剪切"),
        ]),
        Group(title: "运镜与轨道", entries: [
            Entry(keys: "拖动缩放轨空白", action: "创建缩放片段"),
            Entry(keys: "拖动运动轨空白", action: "创建屏幕 / 摄像头动画"),
            Entry(keys: "双击同步轨空白", action: "添加摄像头同步点"),
            Entry(keys: "双击分栏柄", action: "恢复时间线默认高度"),
        ]),
        Group(title: "通用", entries: [
            Entry(keys: "⌘Z", action: "撤销"),
            Entry(keys: "⌘⇧Z", action: "重做"),
            Entry(keys: "⌘O", action: "打开项目"),
            Entry(keys: "⌘E", action: "导出成片"),
            Entry(keys: "⌥⌘I", action: "显示 / 隐藏检查器"),
            Entry(keys: "Esc", action: "取消裁切 / 取消当前操作"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快捷键速查")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭")
                .accessibilityLabel("关闭快捷键速查")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(dividerColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.title) { group in
                        EditorInspectorSection(group.title) {
                            ForEach(group.entries) { entry in
                                HStack(spacing: 10) {
                                    Text(entry.keys)
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                        }
                                        .frame(minWidth: 92, alignment: .leading)
                                    Text(entry.action)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 420, height: 460)
        .background(panelBackground)
    }
}
