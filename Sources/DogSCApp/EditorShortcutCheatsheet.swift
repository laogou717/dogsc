import AppKit
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
            Entry(keys: "← / →", action: "向前 / 向后移动 1 帧"),
            Entry(keys: "Shift + ← / →", action: "向前 / 向后移动 5 帧"),
            Entry(keys: "悬停时间线", action: "预览所指帧，不移动播放头"),
            Entry(keys: "拖动总览条", action: "快速定位播放头与可视范围"),
            Entry(keys: "滚轮 / 捏合", action: "以指针为锚缩放时间线"),
        ]),
        Group(title: "剪辑", entries: [
            Entry(keys: "S", action: "在播放头分割选中动画；未选动画时分割主片段"),
            Entry(keys: "Q", action: "修剪动画起点；未选动画时波纹删除前段"),
            Entry(keys: "W", action: "修剪动画终点；未选动画时波纹删除后段"),
            Entry(keys: "D / Delete", action: "删除当前选中项"),
            Entry(keys: "⇧ / ⌘ 点击主片段", action: "连续选择 / 增减选择主片段"),
            Entry(keys: "⌥ 点击主片段", action: "在点击处直接切分"),
            Entry(keys: "悬停剪切缝", action: "合并或还原该处剪切"),
        ]),
        Group(title: "运镜与轨道", entries: [
            Entry(keys: "⌘C / ⌘V", action: "复制效果片段 / 在鼠标所指位置粘贴副本"),
            Entry(keys: "⌘⇧V", action: "向选中的同类组件粘贴属性，保留位置与时长"),
            Entry(keys: "拖动缩放轨空白", action: "创建缩放片段"),
            Entry(keys: "拖动运动轨空白", action: "创建屏幕 3D / 摄像运动"),
            Entry(keys: "双击同步轨空白", action: "添加摄像头同步点"),
        ]),
        Group(title: "通用", entries: [
            Entry(keys: "⌘Z", action: "撤销"),
            Entry(keys: "⌘⇧Z", action: "重做"),
            Entry(keys: "⌘O", action: "打开项目"),
            Entry(keys: "⌘E", action: "导出成片"),
            Entry(keys: "⌥X", action: "导出选中的主片段范围"),
            Entry(keys: "⌥⌘L", action: "显示 / 隐藏素材面板"),
            Entry(keys: "⌥⌘I", action: "导入录屏项目"),
            Entry(keys: "⌘/", action: "快捷键速查"),
            Entry(keys: "⌘K", action: "让 AI 修改…"),
            Entry(keys: "⌘[", action: "返回全片设置"),
            Entry(keys: "⌘V（画布）", action: "粘贴剪贴板图片为贴图"),
            Entry(keys: "双击分栏柄", action: "恢复面板默认尺寸"),
            Entry(keys: "Esc", action: "取消裁切 / 中止时间线拖动"),
        ]),
    ]

    private var keyColumnWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let widestKey = groups.flatMap(\.entries).map {
            (appLocalized($0.keys) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(max(96, widestKey + 16))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快捷键速查")
                    .font(.appUI(size: 15, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    EditorSymbol("xmark", size: 14.5)
                        .font(.appUI(size: 11, weight: .bold))
                }
                .buttonStyle(.editorDismissIcon)
                .keyboardShortcut(.cancelAction)
                .help("关闭")
                .accessibilityLabel("关闭快捷键速查")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.title) { group in
                        EditorInspectorSection(group.title) {
                            ForEach(group.entries) { entry in
                                HStack(spacing: 10) {
                                    Text(appLocalized(entry.keys))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        // A flat keycap cut out of the tile, with a
                                        // slightly deeper lower edge for the key.
                                        .background(EditorTheme.panelSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(alignment: .bottom) {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(EditorTheme.chrome(0.12), lineWidth: 0.75)
                                        }
                                        .frame(width: keyColumnWidth, alignment: .leading)
                                    Text(appLocalized(entry.action))
                                        .font(.appUI(size: 12))
                                        .foregroundStyle(EditorTheme.primaryText)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        // Longer translated gestures share one aligned column while the
        // explanation column retains the original reading width.
        .frame(width: 344 + keyColumnWidth, height: 480)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
        .onExitCommand { dismiss() }
    }
}
