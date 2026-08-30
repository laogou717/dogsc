import Foundation
import SwiftUI

/// The editor's creation entry is a task palette rather than a flat command
/// menu. It makes the destination (the current playhead) and the difference
/// between local effects, overlay media, and whole-film information explicit.
struct EditorAddPalette: View {
    let insertionTime: TimeInterval
    let hasProgressOverlay: Bool
    let canPasteImage: Bool
    let onAddMosaic: () -> Void
    let onImportSticker: () -> Void
    let onPasteSticker: () -> Void
    let onSelectProgress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(EditorTheme.platinumAccent)
                    .frame(width: 30, height: 30)
                    .background(
                        EditorTheme.platinumAccent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("添加到播放头")
                        .font(.system(size: 13, weight: .semibold))
                    Text(Self.timecode(insertionTime))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("添加后直接调整")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .overlay(EditorTheme.hairline)

            VStack(alignment: .leading, spacing: 11) {
                paletteGroup("局部画面") {
                    EditorAddPaletteRow(
                        title: "柔化或突出",
                        detail: "为当前画面添加隐私遮挡或聚焦区域",
                        symbol: "viewfinder",
                        accent: EditorTheme.amberAccent,
                        action: onAddMosaic
                    )
                }

                paletteGroup("叠加内容") {
                    VStack(spacing: 6) {
                        EditorAddPaletteRow(
                            title: "导入贴图…",
                            detail: "从文件选择图片并放到当前播放头",
                            symbol: "photo.badge.plus",
                            accent: EditorTheme.platinumAccent,
                            action: onImportSticker
                        )

                        EditorAddPaletteRow(
                            title: "粘贴剪贴板图片",
                            detail: canPasteImage
                                ? "使用刚复制的图片创建贴图"
                                : "剪贴板中没有可用图片",
                            symbol: "doc.on.clipboard",
                            accent: EditorTheme.success,
                            action: onPasteSticker
                        )
                        .disabled(!canPasteImage)
                    }
                }

                paletteGroup("成片信息") {
                    EditorAddPaletteRow(
                        title: hasProgressOverlay ? "选中成片进度条" : "添加成片进度条",
                        detail: hasProgressOverlay
                            ? "进度条已存在，转到画布继续编辑"
                            : "显示播放进度与当前看点",
                        symbol: "chart.bar.fill",
                        accent: EditorTheme.amberAccent,
                        status: hasProgressOverlay ? "已添加" : nil,
                        action: onSelectProgress
                    )
                }
            }
            .padding(12)
        }
        .frame(width: 344)
        .background(EditorTheme.panelSurface)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }

    private func paletteGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.46))
                .padding(.horizontal, 4)
            content()
        }
    }

    private static func timecode(_ time: TimeInterval) -> String {
        let safeTime = max(time.isFinite ? time : 0, 0)
        let totalCentiseconds = Int((safeTime * 100).rounded(.down))
        let hours = totalCentiseconds / 360_000
        let minutes = (totalCentiseconds / 6_000) % 60
        let seconds = (totalCentiseconds / 100) % 60
        let centiseconds = totalCentiseconds % 100
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d.%02d",
                hours,
                minutes,
                seconds,
                centiseconds
            )
        }
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }
}

private struct EditorAddPaletteRow: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let title: String
    let detail: String
    let symbol: String
    let accent: Color
    var status: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isEnabled ? accent : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        accent.opacity(isEnabled ? (isHovered ? 0.17 : 0.10) : 0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isEnabled ? Color.white.opacity(0.94) : .secondary)
                    Text(detail)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(isEnabled ? 0.52 : 0.30))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let status {
                    Text(status)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(EditorTheme.success)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            EditorTheme.success.opacity(0.10),
                            in: Capsule(style: .continuous)
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isEnabled ? 0.30 : 0.14))
                    .offset(x: isHovered && isEnabled ? 1.5 : 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isHovered && isEnabled
                            ? Color.white.opacity(0.085)
                            : Color.white.opacity(0.035)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isHovered && isEnabled
                            ? accent.opacity(0.24)
                            : Color.white.opacity(0.065),
                        lineWidth: 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .scaleEffect(isHovered && isEnabled ? 1.008 : 1)
        .offset(y: isHovered && isEnabled ? -0.5 : 0)
        .onHover { hovering in
            withAnimation(SpringMotion.snappy) {
                isHovered = hovering
            }
        }
        .animation(SpringMotion.interactive, value: isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
