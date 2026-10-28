import AppKit
import AVFoundation
import CoreImage
import Foundation
import ScreenCaptureKit
import SwiftUI

// MARK: - SwiftUI onChange Compatibility

public struct OnChangeCompatibilityModifier<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void

    @State private var previousValue: V?

    public init(value: V, initial: Bool, action: @escaping (V, V) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
    }

    public func body(content: Content) -> some View {
        content
            .onAppear {
                if initial {
                    action(value, value)
                }
                previousValue = value
            }
            .onChange(of: value) { newValue in
                let old = previousValue ?? newValue
                previousValue = newValue
                action(old, newValue)
            }
    }
}

public extension View {
    @ViewBuilder
    func onChange<V: Equatable>(
        of value: V,
        initial: Bool,
        _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void
    ) -> some View {
        self.modifier(OnChangeCompatibilityModifier(value: value, initial: initial, action: action))
    }

    @ViewBuilder
    func onChange<V: Equatable>(
        of value: V,
        _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void
    ) -> some View {
        self.modifier(OnChangeCompatibilityModifier(value: value, initial: false, action: action))
    }
}

// MARK: - SwiftUI onKeyPress Compatibility

public extension KeyEquivalent {
    static let leftArrow = KeyEquivalent(Character(UnicodeScalar(0xF702)!))
    static let rightArrow = KeyEquivalent(Character(UnicodeScalar(0xF703)!))
    static let upArrow = KeyEquivalent(Character(UnicodeScalar(0xF700)!))
    static let downArrow = KeyEquivalent(Character(UnicodeScalar(0xF701)!))
}

public struct KeyPressPhasesCompatibility: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let down = KeyPressPhasesCompatibility(rawValue: 1 << 0)
    public static let up = KeyPressPhasesCompatibility(rawValue: 1 << 1)
    public static let `repeat` = KeyPressPhasesCompatibility(rawValue: 1 << 2)
    public static let all: KeyPressPhasesCompatibility = [.down, .up, .repeat]
}

public struct KeyPressCompatibility {
    public var key: KeyEquivalent = .return
    public var modifiers: EventModifiers = []
    public enum Result {
        case handled
        case ignored
    }
}

public extension View {
    @ViewBuilder
    func onKeyPress(
        keys: [KeyEquivalent],
        phases: KeyPressPhasesCompatibility = .all,
        action: @escaping (KeyPressCompatibility) -> KeyPressCompatibility.Result
    ) -> some View {
        self
    }

    @ViewBuilder
    func onKeyPress(
        _ key: KeyEquivalent,
        action: @escaping () -> KeyPressCompatibility.Result
    ) -> some View {
        self
    }

    @ViewBuilder
    func focusEffectDisabled(_ disabled: Bool = true) -> some View {
        self
    }
}

// MARK: - SwiftUI onGeometryChange Compatibility

private struct GeometryChangePreferenceKey<T: Equatable>: PreferenceKey {
    static var defaultValue: T? { nil }
    static func reduce(value: inout T?, nextValue: () -> T?) {
        if let next = nextValue() {
            value = next
        }
    }
}

public extension View {
    @ViewBuilder
    func onGeometryChange<T: Equatable>(
        for type: T.Type,
        of transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: GeometryChangePreferenceKey<T>.self,
                    value: transform(proxy)
                )
            }
        )
        .onPreferenceChange(GeometryChangePreferenceKey<T>.self) { newValue in
            if let newValue = newValue {
                action(newValue)
            }
        }
    }
}

// MARK: - SwiftUI ContentTransition SymbolEffect Compatibility

public struct SymbolEffectReplaceCompatibility {
    public static let replace = SymbolEffectReplaceCompatibility()
}

public extension ContentTransition {
    static func symbolEffect(_ effect: SymbolEffectReplaceCompatibility) -> ContentTransition {
        .identity
    }
}

// MARK: - SwiftUI WindowDragGesture Compatibility

public typealias WindowDragGesture = TapGesture

// MARK: - SwiftUI Scene Launch & Restoration Behavior Compatibility

public enum DefaultLaunchBehaviorCompatibility {
    case suppressed
    case presented
}

public enum RestorationBehaviorCompatibility {
    case disabled
    case enabled
}

public extension Scene {
    func defaultLaunchBehavior(_ behavior: DefaultLaunchBehaviorCompatibility) -> some Scene {
        self
    }

    func restorationBehavior(_ behavior: RestorationBehaviorCompatibility) -> some Scene {
        self
    }
}

// MARK: - Spring Model Compatibility

public struct Spring: Sendable, Equatable {
    public var response: Double
    public var dampingRatio: Double

    public init(response: Double = 0.5, dampingRatio: Double = 0.82) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    public init(duration: Double, bounce: Double = 0.0) {
        self.response = duration
        self.dampingRatio = 1.0 - bounce
    }

    public var settlingDuration: Double {
        max(response * 1.5, 0.25)
    }

    public func value(target: Double, initialVelocity: Double, time: Double) -> Double {
        guard time > 0 else { return 0 }
        let progress = min(time / max(settlingDuration, 0.001), 1.0)
        let t = 1.0 - pow(1.0 - progress, 3)
        return target * t
    }

    public func velocity(target: Double, initialVelocity: Double, time: Double) -> Double {
        let progress = min(time / max(settlingDuration, 0.001), 1.0)
        let v = 3.0 * (1.0 - progress) * (1.0 - progress) / max(settlingDuration, 0.001)
        return target * v
    }

    public func value(target: CGFloat, initialVelocity: CGFloat, time: TimeInterval) -> CGFloat {
        CGFloat(value(target: Double(target), initialVelocity: Double(initialVelocity), time: time))
    }

    public func velocity(target: CGFloat, initialVelocity: CGFloat, time: TimeInterval) -> CGFloat {
        CGFloat(velocity(target: Double(target), initialVelocity: Double(initialVelocity), time: time))
    }
}

// MARK: - SwiftUI withAnimation Completion Compatibility

public enum AnimationCompletionCriteriaCompatibility {
    case removed
    case logicallyComplete
    case logisticallyComplete
}

public func withAnimation<Result>(
    _ animation: Animation? = .default,
    completionCriteria: AnimationCompletionCriteriaCompatibility = .removed,
    _ body: () throws -> Result,
    completion: @escaping () -> Void
) rethrows -> Result {
    let result = try withAnimation(animation, body)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        completion()
    }
    return result
}

// MARK: - MainActor Compatibility

public extension MainActor {
    static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        typealias NonIsolatedOp = () throws -> T
        return try withoutActuallyEscaping(operation) { fn in
            let nonIsolated = unsafeBitCast(fn, to: NonIsolatedOp.self)
            return try nonIsolated()
        }
    }
}

// MARK: - CADisplayLink macOS 13 Compatibility

open class CADisplayLink: NSObject {
    private var timer: Timer?
    private weak var target: AnyObject?
    private let selector: Selector

    public var timestamp: CFTimeInterval { CACurrentMediaTime() }
    public var targetTimestamp: CFTimeInterval { CACurrentMediaTime() + 1.0 / 60.0 }
    public var isPaused: Bool = false {
        didSet {
            if isPaused {
                timer?.fireDate = Date.distantFuture
            } else {
                timer?.fireDate = Date()
            }
        }
    }
    public var preferredFrameRateRange: Any? = nil

    public init(target: AnyObject, selector: Selector) {
        self.target = target
        self.selector = selector
        super.init()
    }

    public func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        self.timer = t
        runLoop.add(t, forMode: mode)
    }

    @objc private func timerFired() {
        guard !isPaused, let target = target else {
            if target == nil { invalidate() }
            return
        }
        _ = target.perform(selector, with: self)
    }

    public func invalidate() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}

public extension NSWindow {
    func displayLink(target: AnyObject, selector: Selector) -> CADisplayLink {
        CADisplayLink(target: target, selector: selector)
    }
}

public extension NSScreen {
    func displayLink(target: AnyObject, selector: Selector) -> CADisplayLink {
        CADisplayLink(target: target, selector: selector)
    }
}

public extension NSView {
    func displayLink(target: AnyObject, selector: Selector) -> CADisplayLink {
        CADisplayLink(target: target, selector: selector)
    }
}

// MARK: - AVCaptureDevice Compatibility

public extension AVCaptureDevice.DeviceType {
    static let external = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternal")
    static let microphone = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeMicrophone")
    static let continuityCamera = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeContinuityCamera")
}

public extension AVCaptureDevice {
    static let wasConnectedNotification = NSNotification.Name.AVCaptureDeviceWasConnected
    static let wasDisconnectedNotification = NSNotification.Name.AVCaptureDeviceWasDisconnected
}

public extension AVCaptureSession {
    static let runtimeErrorNotification = NSNotification.Name("AVCaptureSessionRuntimeErrorNotification")
    static let wasInterruptedNotification = NSNotification.Name("AVCaptureSessionWasInterruptedNotification")
    static let interruptionEndedNotification = NSNotification.Name("AVCaptureSessionInterruptionEndedNotification")
}

public extension AVCaptureDeviceInput {
    var isLockedVideoFrameDurationSupported: Bool { false }
    var activeLockedVideoFrameDuration: CMTime {
        get { .invalid }
        set { }
    }
}

// MARK: - AVSampleBufferVideoRenderer Compatibility

public typealias AVSampleBufferVideoRenderer = AVSampleBufferDisplayLayer

public extension AVSampleBufferDisplayLayer {
    var sampleBufferRenderer: AVSampleBufferDisplayLayer { self }

    func flush(removingDisplayedImage: Bool, completionHandler: (() -> Void)?) {
        self.flush()
        completionHandler?()
    }
}

// MARK: - ScreenCaptureKit macOS 14/15 Compatibility Stubs

public enum SCCaptureResolutionType: Int, Sendable {
    case automatic = 0
    case best = 1
    case nominal = 2
}

public enum SCCaptureDynamicRange: Int, Sendable {
    case SDR = 0
    case HDR = 1
}

public extension SCStreamConfiguration {
    var captureResolution: SCCaptureResolutionType {
        get { .automatic }
        set { }
    }

    var captureDynamicRange: SCCaptureDynamicRange {
        get { .SDR }
        set { }
    }

    var preservesAspectRatio: Bool {
        get { true }
        set { }
    }
}

public extension SCContentFilter {
    var pointPixelScale: Float {
        get { Float(NSScreen.main?.backingScaleFactor ?? 2.0) }
        set { }
    }

    var contentRect: CGRect {
        get { .zero }
        set { }
    }
}

public extension AVAssetWriter {
    var initialMovieFragmentInterval: CMTime {
        get { self.movieFragmentInterval }
        set { self.movieFragmentInterval = newValue }
    }
}

// MARK: - AVAssetExportSession Compatibility

public extension AVAssetExportSession {
    func export(to outputURL: URL, as outputFileType: AVFileType) async throws {
        self.outputURL = outputURL
        self.outputFileType = outputFileType
        await self.export()
        if let error = self.error {
            throw error
        }
        if self.status != .completed {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

open class SCRecordingOutputConfiguration: NSObject {
    public var outputURL: URL?
    public var outputFileType: AVFileType?
    public var videoCodecType: AVVideoCodecType?

    public static var availableVideoCodecTypes: [AVVideoCodecType] {
        [.h264, .hevc]
    }
}

open class SCRecordingOutput: NSObject {
    public init(configuration: SCRecordingOutputConfiguration, delegate: Any) {
        super.init()
    }

    public var recordedDuration: CMTime { .zero }
}

@objc public protocol SCRecordingOutputDelegate: NSObjectProtocol {
    @objc optional func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error)
    @objc optional func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput)
    @objc optional func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput)
}

public extension SCStream {
    func addRecordingOutput(_ recordingOutput: Any) throws {}
    func removeRecordingOutput(_ recordingOutput: Any) throws {}
}

open class SCScreenshotManager: NSObject {
    public static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let context = CGContext(
            data: nil,
            width: max(configuration.width, 1),
            height: max(configuration.height, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let img = context.makeImage() {
            return img
        }
        throw CocoaError(.featureUnsupported)
    }

    public static func captureSampleBuffer(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CMSampleBuffer {
        throw CocoaError(.featureUnsupported)
    }
}

// MARK: - CoreImage CIRenderInfo Compatibility

public extension CIRenderInfo {
    var kernelCompileTime: TimeInterval { 0 }
}

// MARK: - AccessibilityTraits isToggle Compatibility

public extension AccessibilityTraits {
    static let isToggle = AccessibilityTraits()
}

// MARK: - ButtonRepeatBehavior Compatibility

public enum ButtonRepeatBehaviorCompatibility {
    case enabled
    case disabled
}

public extension View {
    @ViewBuilder
    func buttonRepeatBehavior(_ behavior: ButtonRepeatBehaviorCompatibility) -> some View {
        self
    }
}

// MARK: - UnevenRoundedRectangle Compatibility

public struct RectangleCornerRadii: Equatable, Sendable {
    public var topLeading: CGFloat
    public var bottomLeading: CGFloat
    public var bottomTrailing: CGFloat
    public var topTrailing: CGFloat

    public init(
        topLeading: CGFloat = 0,
        bottomLeading: CGFloat = 0,
        bottomTrailing: CGFloat = 0,
        topTrailing: CGFloat = 0
    ) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }
}

public struct UnevenRoundedRectangle: Shape {
    public var cornerRadii: RectangleCornerRadii
    public var style: RoundedCornerStyle

    public init(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) {
        self.cornerRadii = cornerRadii
        self.style = style
    }

    public init(
        topLeadingRadius: CGFloat = 0,
        bottomLeadingRadius: CGFloat = 0,
        bottomTrailingRadius: CGFloat = 0,
        topTrailingRadius: CGFloat = 0,
        style: RoundedCornerStyle = .continuous
    ) {
        self.cornerRadii = RectangleCornerRadii(
            topLeading: topLeadingRadius,
            bottomLeading: bottomLeadingRadius,
            bottomTrailing: bottomTrailingRadius,
            topTrailing: topTrailingRadius
        )
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = min(min(cornerRadii.topLeading, rect.width / 2), rect.height / 2)
        let tr = min(min(cornerRadii.topTrailing, rect.width / 2), rect.height / 2)
        let br = min(min(cornerRadii.bottomTrailing, rect.width / 2), rect.height / 2)
        let bl = min(min(cornerRadii.bottomLeading, rect.width / 2), rect.height / 2)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - KeyEquivalent Equatable
extension KeyEquivalent: Equatable {
    public static func == (lhs: KeyEquivalent, rhs: KeyEquivalent) -> Bool {
        lhs.character == rhs.character
    }
}

// MARK: - View Compatibility Extensions
public struct FocusInteractionsCompatibility: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let edit = FocusInteractionsCompatibility(rawValue: 1 << 0)
    public static let activate = FocusInteractionsCompatibility(rawValue: 1 << 1)
}

public extension View {
    @ViewBuilder
    func presentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        self
    }

    @ViewBuilder
    func focusable(_ isFocusable: Bool = true, interactions: FocusInteractionsCompatibility) -> some View {
        self.focusable(isFocusable)
    }

    @ViewBuilder
    func animation<V: View>(_ animation: Animation?, @ViewBuilder body: (Self) -> V) -> some View {
        body(self)
    }
}
