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
        case .idle: 0.14
        case .hovered: 0.38
        case .selected: 0.90
        case .editing: 1
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .idle: 0.65
        case .hovered: 0.9
        case .selected: 1.45
        case .editing: 2
        }
    }

    var handleOpacity: Double {
        switch self {
        case .idle: 0
        case .hovered: 0.58
        case .selected: 0.88
        case .editing: 1
        }
    }

    var showsHandles: Bool { self != .idle }

    var shadowOpacity: Double {
        switch self {
        case .idle, .hovered: 0
        case .selected: 0.28
        case .editing: 0.46
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .idle, .hovered: 0
        case .selected: 3
        case .editing: 6
        }
    }
}

extension View {
    func editorTimelineClipChrome(
        cornerRadius: CGFloat,
        emphasis: EditorTimelineClipEmphasis
    ) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(emphasis.strokeOpacity),
                    lineWidth: emphasis.strokeWidth
                )
                .allowsHitTesting(false)
        }
        .shadow(
            color: Color.black.opacity(emphasis.shadowOpacity),
            radius: emphasis.shadowRadius,
            y: emphasis == .editing ? 2 : 1
        )
        .animation(SpringMotion.interactive, value: emphasis)
    }
}
