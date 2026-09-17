import Foundation

/// Reusable appearance and transition settings, independent of clip placement,
/// identity and linked-camera groups.
public struct ScreenMotionCreationStyle: Codable, Equatable, Sendable {
    public var target: ScreenMotionState
    public var focusEffect: FocusEffect?
    public var easing: ZoomEasingPreset
    public var customCurve: ZoomBezierCurve
    public var leadInDuration: TimeInterval
    public var returnDuration: TimeInterval

    public init(clip: ScreenMotionClip) {
        target = clip.target
        focusEffect = clip.focusEffect
        easing = clip.timing.easing
        customCurve = clip.timing.customCurve
        leadInDuration = clip.timing.requestedLeadInDuration
        returnDuration = clip.timing.requestedReturnDuration()
    }

    public var isValid: Bool {
        let values = [target.position.x, target.position.y, target.scale,
                      target.rotationX, target.rotationY, target.rotationZ,
                      target.perspective, leadInDuration, returnDuration,
                      customCurve.x1, customCurve.y1, customCurve.x2, customCurve.y2]
        return values.allSatisfy(\.isFinite) && (0...1).contains(target.position.x)
            && (0...1).contains(target.position.y) && target.scale > 0
            && target.perspective >= 0 && (0...5).contains(leadInDuration)
            && (0...5).contains(returnDuration) && (focusEffect?.isValid ?? true)
    }

    public func clip(timing: TransitionTiming) -> ScreenMotionClip {
        var timing = timing
        timing.easing = easing
        timing.customCurve = customCurve
        timing.preferredLeadInDuration = leadInDuration
        timing.preferredReturnDuration = returnDuration
        timing.leadInDuration = min(leadInDuration, timing.duration)
        timing.returnDuration = min(returnDuration, timing.returnDuration)
        timing.leadInProgressOffset = 0
        timing.returnProgressOffset = 0
        return ScreenMotionClip(timing: timing, target: target, focusEffect: focusEffect)
    }
}
