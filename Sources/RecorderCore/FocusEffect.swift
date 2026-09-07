import Foundation

public enum FocusEffectTarget: String, Codable, CaseIterable, Sendable {
    case animation, pointer, fixed
}

public enum FocusEffectShape: String, Codable, Sendable { case radial, linear }

/// Optional per-animation spatial focus. A missing value means no work, not
/// a hidden default effect. All coordinates remain in source-screen space.
public struct FocusEffect: Codable, Equatable, Sendable {
    public var shape: FocusEffectShape?
    public var angleDegrees: Double?
    public var target: FocusEffectTarget = .animation
    public var center = NormalizedPoint(x: 0.5, y: 0.5)
    public var size: Double = 0.45
    public var blur: Double = 0.35
    public var softness: Double = 0.5
    public var dimming: Double = 0.18

    public init(linear: Bool = false) {
        if linear {
            shape = .linear
            angleDegrees = 0
            target = .fixed
            size = 0.32
            dimming = 0
        }
    }

    public static func normalizedAngle(_ degrees: Double) -> Double {
        let result = degrees.truncatingRemainder(dividingBy: 360)
        return result < 0 ? result + 360 : result
    }

    public func clearHalfWidth(shortEdge: Double) -> Double { shortEdge * size / 2 }
    public func featherWidth(shortEdge: Double) -> Double { max(shortEdge * softness * 0.4, 1) }

    public var isValid: Bool {
        [center.x, center.y, blur, softness, dimming].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        } && (angleDegrees == nil || (angleDegrees!.isFinite && (0...360).contains(angleDegrees!)))
        && size.isFinite && (0.1...1).contains(size)
    }
}

public struct FrameFocusScene: Equatable, Sendable {
    public var effect: FocusEffect
    public var center: NormalizedPoint
    public var progress: Double
}

public enum FocusEffectEvaluator {
    public static func scene(
        zoom: ZoomAnimationClip?, screen: ScreenMotionClip?,
        zoomFocus: NormalizedPoint, crop: NormalizedCrop,
        pointer: NormalizedPoint?, time: TimeInterval, motion: MotionStyle
    ) -> FrameFocusScene? {
        let effect: FocusEffect
        let anchor: NormalizedPoint
        let timing: TransitionTiming
        let holds: Bool
        // An explicitly enabled 3D focus owns the single effect when both
        // tracks overlap. Never stack two full-frame blurs accidentally.
        if let screen, let selected = screen.focusEffect {
            var linear = selected
            if linear.shape == nil {
                linear.shape = .linear
                linear.target = .fixed
                linear.dimming = 0
            }
            effect = linear
            anchor = NormalizedPoint(x: crop.x + screen.target.position.x * crop.width,
                                     y: crop.y + screen.target.position.y * crop.height)
            timing = screen.timing
            holds = timing.returnDuration == 0
        } else if let zoom, let selected = zoom.focusEffect {
            effect = selected
            anchor = zoomFocus
            timing = TransitionTiming(startTime: zoom.startTime, duration: zoom.duration,
                                      leadInDuration: zoom.enterDuration, easing: zoom.easing,
                                      customCurve: zoom.customCurve, returnDuration: zoom.exitDuration,
                                      leadInProgressOffset: zoom.enterProgressOffset,
                                      returnProgressOffset: zoom.exitProgressOffset)
            holds = false
        } else { return nil }
        guard effect.isValid, effect.blur > 0 || effect.dimming > 0 else { return nil }
        let amount = progress(timing: timing, at: time, holds: holds, motion: motion)
        guard amount > 0 else { return nil }
        let center: NormalizedPoint = switch effect.target {
        case .animation: anchor
        case .pointer: pointer ?? anchor
        case .fixed: effect.center
        }
        return FrameFocusScene(effect: effect, center: center.constrained(to: 0), progress: amount)
    }

    private static func progress(timing: TransitionTiming, at time: Double,
                                 holds: Bool, motion: MotionStyle) -> Double {
        guard time >= timing.startTime else { return 0 }
        let enter = min(timing.leadInDuration, timing.duration)
        let linear: Double
        let exiting: Bool
        if enter > 0, time < timing.startTime + enter {
            linear = timing.leadInProgressOffset + (1 - timing.leadInProgressOffset)
                * (time - timing.startTime) / enter
            exiting = false
        } else if time < timing.endTime { return 1 }
        else if timing.returnDuration > 0 {
            linear = timing.returnProgressOffset + (1 - timing.returnProgressOffset)
                * (time - timing.endTime) / timing.returnDuration
            exiting = true
        } else { return holds ? 1 : 0 }
        let eased = ZoomInterpolator.easedProgress(min(max(linear, 0), 1),
            preset: timing.easing, customCurve: timing.customCurve, motion: motion)
        return min(max(exiting ? 1 - eased : eased, 0), 1)
    }
}
