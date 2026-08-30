import Foundation

/// Stable domain errors produced by ``ProjectValidator``.
///
/// The editor maps these errors to command-specific failures, while project
/// loading, persistence and future import paths can use the same validation
/// rules without depending on the app target.
public enum ProjectValidationError: Error, Equatable, Sendable {
    case invalidCanvas(reason: String)
    case invalidCamera(reason: String)
    case invalidAudio(reason: String)
    case invalidCursor(reason: String)
    case invalidMotion(reason: String)
    case invalidOpening(reason: String)
    case invalidZoom(UUID, reason: String)
    case duplicateZoomID(UUID)
    case overlappingZoom(UUID, UUID)
    case invalidTimeline(reason: String)
}

extension ProjectValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidCanvas(reason):
            return "画布参数无效：\(reason)"
        case let .invalidCamera(reason):
            return "摄像头参数无效：\(reason)"
        case let .invalidAudio(reason):
            return "音频参数无效：\(reason)"
        case let .invalidCursor(reason):
            return "光标参数无效：\(reason)"
        case let .invalidMotion(reason):
            return "动画参数无效：\(reason)"
        case let .invalidOpening(reason):
            return "开场编排参数无效：\(reason)"
        case let .invalidZoom(_, reason):
            return "缩放片段无效：\(reason)"
        case .duplicateZoomID:
            return "缩放轨道中存在重复片段。"
        case .overlappingZoom:
            return "缩放片段的生效区间发生重叠。"
        case let .invalidTimeline(reason):
            return "时间线无效：\(reason)"
        }
    }
}

/// The single validation boundary for persisted project-domain values.
///
/// This type deliberately owns validation only. It never repairs or clamps a
/// project, so callers cannot accidentally persist a value different from the
/// value the user authored.
public enum ProjectValidator {
    public static func validate(_ style: CanvasStyle) throws {
        guard finite(style.padding, in: 0...1_000),
              finite(style.contentScale, in: 0.05...8),
              finite(style.contentPosition.x, in: 0...1),
              finite(style.contentPosition.y, in: 0...1),
              finite(style.cornerRadius, in: 0...500),
              finite(style.borderWidth, in: 0...60),
              finite(style.shadowStrength, in: 0...1),
              finite(style.backgroundBlur, in: 0...96),
              finite(style.insetOpacity, in: 0...1),
              finite(style.screenFrameScale, in: 0.6...1.6),
              style.crop == style.crop.clamped()
        else {
            throw ProjectValidationError.invalidCanvas(
                reason: "包含越界、非有限或无效裁切值。"
            )
        }
    }

    public static func validate(_ style: CameraStyle) throws {
        guard finite(style.position.x, in: 0...1),
              finite(style.position.y, in: 0...1),
              finite(style.size, in: 0.01...1),
              finite(style.borderWidth, in: 0...18),
              finite(style.shadowStrength, in: 0...1),
              finite(style.roundness, in: 0...1),
              finite(style.scaleDuringZoom, in: 0.1...2),
              finite(style.contentPosition.x, in: 0...1),
              finite(style.contentPosition.y, in: 0...1),
              finite(style.contentScale, in: 1...4)
        else {
            throw ProjectValidationError.invalidCamera(
                reason: "位置、大小或外观值超出可渲染范围。"
            )
        }
    }

    public static func validate(_ style: AudioStyle) throws {
        guard finite(style.systemVolume, in: 0...1),
              finite(style.microphoneVolume, in: 0...1)
        else {
            throw ProjectValidationError.invalidAudio(
                reason: "音量必须位于 0 到 1。"
            )
        }
    }

    public static func validate(_ style: CursorStyle) throws {
        guard !style.assetID.rawValue.isEmpty,
              finite(style.size, in: 0.25...6),
              finite(style.idleDelay, in: 0.2...8),
              finite(style.motionTiltStrength, in: 0...2)
        else {
            throw ProjectValidationError.invalidCursor(
                reason: "尺寸、静止延迟或摆动强度超出支持范围。"
            )
        }
    }

    public static func validate(_ style: MotionStyle) throws {
        guard finite(style.motionBlur, in: 0...1),
              finite(style.frameMotionBlur.strength, in: 0...1),
              finite(style.screenSpringMass, in: 0.01...20),
              finite(style.screenSpringStiffness, in: 1...5_000),
              finite(style.screenSpringDamping, in: 0.1...1_000),
              finite(style.cursorSpringMass, in: 0.01...20),
              finite(style.cursorSpringStiffness, in: 1...5_000),
              finite(style.cursorSpringDamping, in: 0.1...1_000),
              finite(style.defaultZoomTransitionDuration, in: 0.05...5)
        else {
            throw ProjectValidationError.invalidMotion(
                reason: "弹簧、运动模糊或默认过渡参数无法稳定求值。"
            )
        }
    }

    public static func validate(_ clip: ZoomAnimationClip) throws {
        do {
            // ProjectTimelineEditing is the canonical owner of typed timeline
            // invariants, including custom bezier-curve validity. Wrapping one
            // clip keeps this entry point and whole-timeline validation exact.
            try ProjectTimelineEditing.validate(ProjectTimeline(zoomClips: [clip]))
        } catch {
            throw ProjectValidationError.invalidZoom(
                clip.id,
                reason: error.localizedDescription
            )
        }
    }

    public static func validate(_ timeline: ProjectTimeline) throws {
        do {
            try ProjectTimelineEditing.validate(timeline)
        } catch let error as ProjectTimelineEditingError {
            switch error {
            case let .duplicateClipID(track: .zoom, id):
                throw ProjectValidationError.duplicateZoomID(id)
            case let .overlappingClips(track: .zoom, first, second):
                throw ProjectValidationError.overlappingZoom(first, second)
            default:
                throw ProjectValidationError.invalidTimeline(
                    reason: error.localizedDescription
                )
            }
        } catch {
            throw ProjectValidationError.invalidTimeline(
                reason: error.localizedDescription
            )
        }
    }

    /// Validates every persisted editing domain of a complete project.
    public static func validate(_ project: RecorderProject) throws {
        try validate(project.canvas)
        try validate(project.camera)
        try validate(project.audio)
        try validate(project.cursorStyle)
        try validate(project.motion)
        guard finite(project.openingSequence.duration, in: 0.4...8),
              finite(project.openingSequence.stagger, in: 0...1.2),
              project.openingSequence.stagger
                <= project.openingSequence.maximumStagger(
                    for: project.openingSequence.includedElements.count
                ) + 0.000_001,
              Set(project.openingSequence.includedElements).count
                == project.openingSequence.includedElements.count,
              Set(project.openingSequence.elementOrder)
                == Set(OpeningSequenceElement.allCases),
              project.openingSequence.elementOrder.count
                == OpeningSequenceElement.allCases.count else {
            throw ProjectValidationError.invalidOpening(
                reason: "时长、间隔或元素顺序无效。"
            )
        }
        try validate(project.timeline)
    }

    private static func finite(
        _ value: Double,
        in range: ClosedRange<Double>
    ) -> Bool {
        value.isFinite && range.contains(value)
    }
}
