import AppKit
import SwiftUI

/// One colour identity per task. The same hue marks a task in the inspector
/// (its selected key, bars, knob arcs) and the things that belong to it on
/// the canvas and the timeline (selection outlines, handles, markers), so a
/// selection is never just "the default black".
///
/// Flat fills only: no gradients, glows or tinted backgrounds.
struct EditorConsolePalette: Equatable {
    /// Solid fill that always carries `ink` on top: selected thumbs, bars.
    let fill: Color
    /// Lines, arcs and outlines drawn directly on a surface. Deeper than
    /// `fill` in the light appearance so they keep their contrast.
    let stroke: Color
    /// Foreground for anything drawn on `fill`: a deep shade of the same
    /// hue, which sits on the colour far more calmly than black.
    let ink: Color
    /// A light wash of the hue for large areas (timeline clips), and the
    /// text that goes on it: the deep shade in light, the hue in dark.
    let soft: Color
    let softInk: Color
    /// The hue as small text on the panel: deep enough for 4.5:1 in the
    /// light appearance, the hue itself in dark.
    let text: Color

    fileprivate let fillNSColor: NSColor
}

private func paletteRGB(_ hex: UInt32) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

enum EditorConsole {
    static let scrollSpace = "inspector.scroll"

    fileprivate static func vivid(fill: UInt32, lightStroke: UInt32, ink: UInt32, lightText: UInt32) -> EditorConsolePalette {
        let fillColor = paletteRGB(fill)
        // In dark, text on the hue's wash is the hue lifted toward white so
        // a selected (stronger) wash still keeps 5.7:1 or more.
        let liftedFill = fillColor.blended(withFraction: 0.38, of: .white) ?? fillColor
        return EditorConsolePalette(
            fill: Color(nsColor: fillColor),
            stroke: Color(nsColor: RecorderStyle.adaptive(paletteRGB(lightStroke), fillColor)),
            ink: Color(nsColor: paletteRGB(ink)),
            soft: Color(nsColor: RecorderStyle.adaptive(
                fillColor.withAlphaComponent(0.24), fillColor.withAlphaComponent(0.20)
            )),
            softInk: Color(nsColor: RecorderStyle.adaptive(paletteRGB(ink), liftedFill)),
            text: Color(nsColor: RecorderStyle.adaptive(paletteRGB(lightText), fillColor)),
            fillNSColor: fillColor
        )
    }

    // MARK: 配色角色（UX-184 第六轮）
    //
    // 1. 全编辑页与侧边栏全部统一使用石墨黑（EditorTheme.platinumAccent）：
    //    顶层导航、子菜单分段选择、滑块、旋钮、开关、主按钮、缩略图选中框、主录屏轨与波形。
    // 2. 时间线效果轨道与「轨道显示」弹窗保持一轨一色、同行片段同色（避开蓝紫）：
    //    缩放（青柠绿）、屏幕 3D（暖琥珀黄）、摄像运动（暖珊瑚橙）、叠加（清透青绿）、摄像同步（暖玫红）。

    static let frame = Track.primary
    static let opening = Track.primary
    static let zoom = Track.primary
    static let cursor = Track.primary
    static let camera = Track.primary
    static let audio = Track.primary

    /// 时间线轨道色：五条效果轨色相拉开（绿 80°、琥珀 45°、珊瑚 18°、
    /// 青绿 172°、玫红 340°），亮度相近，避开蓝紫；主录屏轨保持黑。
    enum Track {
        /// 屏幕录制：黑色主色，不染色。
        static let primary = EditorConsolePalette(
            fill: EditorTheme.platinumAccent,
            stroke: EditorTheme.platinumAccent,
            ink: EditorTheme.onAccent,
            soft: EditorTheme.selectionWash,
            softInk: EditorTheme.primaryText,
            text: EditorTheme.primaryText,
            fillNSColor: NSColor(calibratedWhite: 0.12, alpha: 1)
        )
        /// 缩放：青柠绿（与「运镜」页点缀色一致）。
        static let zoom = vivid(fill: 0x99BB81, lightStroke: 0x658D49, ink: 0x2B3E1E, lightText: 0x486534)
        /// 屏幕 3D：琥珀黄。
        static let screenMotion = vivid(fill: 0xBBA881, lightStroke: 0x8D7749, ink: 0x3E331E, lightText: 0x655534)
        /// 摄像运动：珊瑚橙（与「摄像头」页点缀色一致）。
        static let cameraMotion = vivid(fill: 0xBB9281, lightStroke: 0x8D5D49, ink: 0x3E271E, lightText: 0x654334)
        /// 叠加（柔化／突出／贴图）：青绿。
        static let overlay = vivid(fill: 0x81BBB1, lightStroke: 0x498D82, ink: 0x1E3E39, lightText: 0x34655D)
        /// 摄像同步：玫红（只在校正同步时出现的曲线轨）。
        static let cameraSync = vivid(fill: 0xBB8194, lightStroke: 0x8D4960, ink: 0x3E1E29, lightText: 0x653444)
        /// EDT-054 后期素材：每类一色，一眼分清轨道里放的是什么。
        /// 视频：天蓝。
        static let video = vivid(fill: 0x81A3BB, lightStroke: 0x49718D, ink: 0x1E313E, lightText: 0x345165)
        /// 图片：青绿（沿用叠加色）。
        static let image = overlay
        /// 动效：丁香紫。
        static let animation = vivid(fill: 0x9981BB, lightStroke: 0x65498D, ink: 0x2B1E3E, lightText: 0x483465)
        /// 字幕：石板灰蓝（文字类，低饱和）。
        static let subtitle = vivid(fill: 0x9199AC, lightStroke: 0x5C657A, ink: 0x252A37, lightText: 0x404859)
        /// 音乐：靛蓝。
        static let music = vivid(fill: 0x8189BB, lightStroke: 0x49528D, ink: 0x1E223E, lightText: 0x343B65)
        /// 音效：洋红。
        static let soundEffect = vivid(fill: 0xBB81AD, lightStroke: 0x8D497C, ink: 0x3E1E36, lightText: 0x653459)
        /// 柔化与突出：暖沙色。
        static let region = vivid(fill: 0xB1A28B, lightStroke: 0x837054, ink: 0x3C3120, lightText: 0x5F503A)
    }

    /// The colour of an added-material clip and of its lane.
    static func palette(for kind: EditorOverlayTimelineKind, isEffect: Bool = false) -> EditorConsolePalette {
        switch kind {
        case .video: Track.video
        case .sticker: Track.image
        case .animation: Track.animation
        case .subtitle: Track.subtitle
        case .audio: isEffect ? Track.soundEffect : Track.music
        case .mosaic: Track.region
        }
    }

    /// 主片段波形：中性石墨灰，大面积内容不染色。
    static let waveformInk = Color(nsColor: RecorderStyle.adaptive(
        NSColor(calibratedWhite: 0, alpha: 0.34),
        NSColor(calibratedWhite: 1, alpha: 0.40)
    ))

    /// 侧栏页面点缀色（只给滑块与分段子选项使用）。
    static func palette(for tab: InspectorTab) -> EditorConsolePalette {
        switch tab {
        case .frame: frame
        case .opening: opening
        case .zoom: zoom
        case .cursor: cursor
        case .camera: camera
        case .audio: audio
        }
    }

    /// 画布／时间线上被选中对象的身份色 = 它所在轨道的颜色。
    static func palette(for selection: EditorSelection) -> EditorConsolePalette {
        switch selection {
        case .canvas, .screen, .primarySegment, .crop, .cursor, .audio: Track.primary
        case .zoomTrack, .zoom: Track.zoom
        case .screenMotionTrack, .screenMotion: Track.screenMotion
        case .camera, .cameraMotion: Track.cameraMotion
        case .mosaic: Track.region
        case .sticker: Track.image
        case .animation: Track.animation
        case .audioClip: Track.music
        case .subtitle: Track.subtitle
        case .videoClip: Track.video
        }
    }
}

extension EditorConsolePalette {
    func adaptiveWash(lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: RecorderStyle.adaptive(
            fillNSColor.withAlphaComponent(lightAlpha),
            fillNSColor.withAlphaComponent(darkAlpha)
        ))
    }
}

private struct ConsolePaletteKey: EnvironmentKey {
    static let defaultValue: EditorConsolePalette? = nil
}

extension EnvironmentValues {
    /// Nil outside the editor inspector and the canvas/timeline objects that
    /// opt in, where controls keep their quiet platinum look.
    var consolePalette: EditorConsolePalette? {
        get { self[ConsolePaletteKey.self] }
        set { self[ConsolePaletteKey.self] = newValue }
    }
}
