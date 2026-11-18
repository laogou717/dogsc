import SwiftUI

/// 时间线片段只使用一套视觉强调层级。它不参与命中、时间换算或手势分发，
/// 只负责让默认、悬停、选中和正在编辑四种状态清楚且互不叠加。
enum EditorTimelineClipEmphasis: Equatable {
    case idle
    case hovered
    case selected
    case editing

    static func resolve(
        isEditing: Bool,
        isSelected: Bool,
        isHovered: Bool
    ) -> Self {
        if isEditing { return .editing }
        if isSelected { return .selected }
        if isHovered { return .hovered }
        return .idle
    }

    var strokeOpacity: Double {
        switch self {
        case .idle: return 0.08
        case .hovered: return 0.30
        case .selected: return 0.90
        case .editing: return 1
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .idle: return 0.65
        case .hovered: return 0.9
        case .selected: return 1.45
        case .editing: return 1.5
        }
    }

    var handleOpacity: Double {
        switch self {
        case .idle: return 0
        case .hovered, .selected, .editing: return 1
        }
    }

    /// Track-colour wash for effect clips (light appearance).
    var trackLightFillOpacity: Double {
        switch self {
        case .idle: return 0.26
        case .hovered: return 0.34
        case .selected: return 0.46
        case .editing: return 0.50
        }
    }

    /// Track-colour wash for effect clips (dark appearance).
    var trackDarkFillOpacity: Double {
        switch self {
        case .idle: return 0.22
        case .hovered: return 0.30
        case .selected: return 0.40
        case .editing: return 0.44
        }
    }

    /// The primary recording card stays neutral graphite.
    var primaryNeutralFillOpacity: Double {
        switch self {
        case .idle: return 0.035
        case .hovered: return 0.05
        case .selected: return 0.065
        case .editing: return 0.07
        }
    }

    var showsHandles: Bool { self != .idle }

}

extension EditorConsolePalette {
    /// Effect clips (`缩放`, `屏幕 3D`, `摄像运动`, `叠加`) wear their track's
    /// colour: the track icon, every clip in that row, its outline, handles
    /// and label share one hue, so a row reads as one track at a glance.
    func timelineSurface(_ emphasis: EditorTimelineClipEmphasis) -> Color {
        adaptiveWash(
            lightAlpha: emphasis.trackLightFillOpacity,
            darkAlpha: emphasis.trackDarkFillOpacity
        )
    }

    /// The primary recording card (`屏幕录制`) is neutral: the filmstrip and
    /// waveform are the content, and black is the editor's primary colour.
    func primaryTimelineSurface(_ emphasis: EditorTimelineClipEmphasis) -> Color {
        EditorTheme.chrome(emphasis.primaryNeutralFillOpacity)
    }
}

extension View {
    /// `tint` is the track colour: a soft same-hue outline at rest and a
    /// solid 1.5pt ring when selected. Without a tint (the neutral recording
    /// clip) the rest outline is a graphite hairline and `selectionRing`
    /// colours only the selected ring. No glow or drawing outside the clip.
    func editorTimelineClipChrome(
        cornerRadius: CGFloat,
        emphasis: EditorTimelineClipEmphasis,
        tint: Color? = nil,
        selectionRing: Color? = nil
    ) -> some View {
        let ring = tint ?? selectionRing ?? EditorTheme.selectionTint
        let active = emphasis == .selected || emphasis == .editing
        let restOpacity = tint == nil
            ? (emphasis == .hovered ? 0.2 : 0.1)
            : (emphasis == .hovered ? 0.7 : 0.45)
        return overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    active ? ring : (tint ?? EditorTheme.chrome()),
                    lineWidth: active ? 1.5 : 0.75
                )
                .opacity(active ? 1 : restOpacity)
                .animation(.easeOut(duration: 0.14), value: active)
                .animation(.easeOut(duration: 0.14), value: restOpacity)
                .allowsHitTesting(false)
        }
    }
}
