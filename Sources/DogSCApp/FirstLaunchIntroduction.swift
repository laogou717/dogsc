import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PermissionOnboardingPresentation: ObservableObject {
    @Published var isIntroAnimating = false
    @Published var isTourReady = false
}

/// A short-lived compositor surface above the real permission window. Only
/// layer transforms and opacity animate; no full-screen blur pass,
/// screenshot, per-frame SwiftUI layout, display timer or new desktop Space.
@MainActor
final class FirstLaunchIntroduction {
    static let seenKey = "permissions.soft-light-introduction-seen"
    private var panel: IntroductionPanel?
    private var completionTask: Task<Void, Never>?
    private var resignationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private weak var destinationWindow: NSWindow?
    private var completion: (() -> Void)?
    private var isFinishing = false
    private let presentation: PermissionOnboardingPresentation

    init(presentation: PermissionOnboardingPresentation) {
        self.presentation = presentation
    }

    var isPresenting: Bool { panel != nil }

    func play(over destination: NSWindow, completion: @escaping () -> Void) {
        guard panel == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screen = destination.screen ?? NSScreen.main else {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
            destination.makeKeyAndOrderFront(nil)
            completion()
            return
        }

        let screenFrame = screen.frame
        let bounds = NSRect(origin: .zero, size: screenFrame.size)
        let target = destination.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let panel = IntroductionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setAccessibilityLabel(appLocalized("DogSC 启动动画，按 Esc 跳过"))
        panel.onSkip = { [weak self] in self?.finish(activateDestination: true, destination: destination) }

        let view = NSView(frame: bounds)
        view.wantsLayer = true
        let root = CALayer()
        root.frame = bounds
        root.contentsScale = screen.backingScaleFactor
        view.layer = root
        panel.contentView = view
        self.panel = panel
        self.destinationWindow = destination
        self.completion = completion
        presentation.isIntroAnimating = true

        let surface = CALayer()
        surface.frame = bounds
        surface.backgroundColor = NSColor(white: 0.04, alpha: 0.56).cgColor
        root.addSublayer(surface)

        let scale = min(max(bounds.height / 1000, 0.8), 1.35)
        let iconSize = 116 * scale
        let center = CGPoint(x: bounds.midX, y: bounds.midY + 44 * scale)
        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        icon.position = CGPoint(x: center.x, y: center.y + 48 * scale)
        icon.contents = NSApplication.shared.applicationIconImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = screen.backingScaleFactor
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.10
        icon.shadowRadius = 16 * scale
        icon.shadowOffset = CGSize(width: 0, height: -8 * scale)
        root.addSublayer(icon)

        _ = Font.appUI(size: 15, weight: .semibold)
        let titleSize = 54 * scale
        let title = Self.textLayer("DogSC", size: titleSize, weight: .semibold, color: .white, scale: screen.backingScaleFactor)
        title.position = CGPoint(x: center.x, y: center.y - 48 * scale)
        root.addSublayer(title)
        let subtitle = Self.textLayer(appLocalized("丝滑录屏"), size: 20 * scale, weight: .regular, color: .init(white: 0.87, alpha: 1), scale: screen.backingScaleFactor)
        subtitle.position = CGPoint(x: center.x, y: center.y - 94 * scale)
        root.addSublayer(subtitle)

        let start = CACurrentMediaTime() + 0.06
        let ease = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1)
        Self.animate(surface, "opacity", from: 0, to: 1, at: start, duration: 0.38)
        Self.addSilverParticles(to: root, center: center, scale: scale, at: start, backingScale: screen.backingScaleFactor)
        let skip = Self.textLayer(appLocalized("按 Esc 跳过"), size: 12, weight: .regular,
                                  color: NSColor(white: 0.9, alpha: 0.65), scale: screen.backingScaleFactor)
        skip.position = CGPoint(x: bounds.midX, y: max(40, bounds.height * 0.07))
        root.addSublayer(skip)
        Self.animate(skip, "opacity", from: 0, to: 1, at: start + 0.45, duration: 0.3)
        Self.animate(icon, "opacity", from: 0, to: 1, at: start + 0.55, duration: 0.48)
        Self.animate(title, "opacity", from: 0, to: 1, at: start + 0.72, duration: 0.42)
        Self.animate(subtitle, "opacity", from: 0, to: 1, at: start + 0.88, duration: 0.4)

        let settle = start + 1.62
        Self.animate(surface, "opacity", from: 1, to: 0, at: settle + 0.22, duration: 0.7, key: "dim.exit")
        Self.animate(skip, "opacity", from: 1, to: 0, at: settle, duration: 0.2, key: "skip.exit")
        Self.animate(title, "foregroundColor", from: NSColor.white.cgColor,
                     to: NSColor(red: 0.16, green: 0.18, blue: 0.19, alpha: 1).cgColor,
                     at: settle + 0.25, duration: 0.65)
        let brandCenter = CGPoint(x: target.minX + PermissionOnboardingStyle.brandInset.x + 16,
                                  y: target.maxY - PermissionOnboardingStyle.brandInset.y - 16)
        Self.animate(icon, "position", from: NSValue(point: icon.position), to: NSValue(point: brandCenter), at: settle, duration: 0.96, timing: ease)
        Self.animate(icon, "transform.scale", from: 1, to: PermissionOnboardingStyle.brandSize / iconSize, at: settle, duration: 0.96, timing: ease)
        Self.animate(icon, "shadowOpacity", from: 0.10, to: 0, at: settle, duration: 0.5)
        let wordWidth = Self.font(size: 15, weight: .semibold).width(of: "DogSC")
        let wordCenter = CGPoint(x: target.minX + PermissionOnboardingStyle.brandInset.x + 32 + 9 + wordWidth / 2,
                                 y: brandCenter.y)
        Self.animate(title, "position", from: NSValue(point: title.position), to: NSValue(point: wordCenter), at: settle, duration: 0.96, timing: ease)
        Self.animate(title, "transform.scale", from: 1, to: 15 / titleSize, at: settle, duration: 0.96, timing: ease)
        Self.animate(subtitle, "opacity", from: 1, to: 0, at: settle, duration: 0.25, key: "subtitle.exit")

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Lay out the real permission page once; reveal it only at the handoff.
        // The desktop behind the transparent dimmer stays live throughout.
        destination.alphaValue = 0
        destination.order(.below, relativeTo: panel.windowNumber)
        destination.contentView?.layoutSubtreeIfNeeded()
        destination.contentView?.displayIfNeeded()

        // No input monitor survives the temporary panel. App switches, display
        // changes and Esc all remove the overlay and restore the live window.
        resignationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self, weak destination] _ in
            MainActor.assumeIsolated { self?.finish(activateDestination: false, destination: destination) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self, weak destination] _ in
            MainActor.assumeIsolated {
                guard !NSScreen.screens.contains(where: { $0.frame == screenFrame }) else { return }
                self?.finish(activateDestination: false, destination: destination)
            }
        }
        completionTask = Task { @MainActor [weak self, weak destination] in
            do {
                try await Task.sleep(for: .seconds(1.85))
                guard !Task.isCancelled else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.55
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    destination?.animator().alphaValue = 1
                }, completionHandler: nil)
                try await Task.sleep(for: .seconds(0.93))
            } catch { return }
            self?.finish(activateDestination: true, destination: destination)
        }
    }

    func cancel() { finish(activateDestination: false, destination: destinationWindow) }

    private func finish(activateDestination: Bool, destination: NSWindow?) {
        guard let panel, !isFinishing else { return }
        isFinishing = true
        completionTask?.cancel()
        completionTask = nil
        if let resignationObserver { NotificationCenter.default.removeObserver(resignationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        resignationObserver = nil
        screenObserver = nil
        destination?.alphaValue = 1
        presentation.isIntroAnimating = false
        panel.onSkip = nil
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        let dismiss: @MainActor @Sendable () -> Void = { [weak self, weak destination] in
            guard let self else { return }
            destination?.contentView?.layoutSubtreeIfNeeded()
            destination?.contentView?.displayIfNeeded()
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            self.panel = nil
            self.destinationWindow = nil
            self.isFinishing = false
            let callback = self.completion
            self.completion = nil
            callback?()
            if activateDestination, NSApp.isActive, destination?.isVisible == true {
                destination?.makeKeyAndOrderFront(nil)
            }
        }
        // Let the live brand repaint beneath its settled compositor copy.
        // Cancellation removes the input surface immediately instead.
        if activateDestination { DispatchQueue.main.async(execute: dismiss) }
        else { dismiss() }
    }

    /// Deterministic, finite compositor paths: silver dust converges around the
    /// brand while the user's live desktop remains visible through the dimmer.
    /// No screenshot, frame timer, media decoder or persistent emitter is used.
    private static func addSilverParticles(to root: CALayer, center: CGPoint, scale: CGFloat,
                                            at start: CFTimeInterval, backingScale: CGFloat) {
        let cloud = CALayer()
        cloud.frame = root.bounds
        root.addSublayer(cloud)
        var seed: UInt64 = 0xD065C
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt64.max >> 33)
        }
        for index in 0..<760 {
            let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            let spread = random()
            let band = random() - 0.5
            let x = (130 + spread * 500) * scale * side
            let y = sin(spread * .pi * 2 + side * 0.7) * 60 * scale + band * 92 * scale
            let end = CGPoint(x: center.x + x * 0.72, y: center.y - 38 * scale + y)
            let initial = CGPoint(x: center.x + x * 1.8, y: center.y + y * 2.0)
            let radius = (index < 28 ? 3 + random() * 3 : 0.6 + random() * 1.2) * scale
            let particle = CALayer()
            particle.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            particle.position = end
            particle.cornerRadius = radius
            particle.backgroundColor = NSColor(white: 0.9 + random() * 0.1, alpha: 1).cgColor
            particle.contentsScale = backingScale
            particle.opacity = 0
            cloud.addSublayer(particle)
            let delay = random() * 0.32
            let path = CGMutablePath()
            path.move(to: initial)
            path.addCurve(to: end,
                          control1: CGPoint(x: initial.x * 0.6 + end.x * 0.4, y: initial.y + side * 100 * scale),
                          control2: CGPoint(x: end.x + side * 80 * scale, y: end.y - side * 32 * scale))
            let movement = CAKeyframeAnimation(keyPath: "position")
            movement.path = path
            movement.beginTime = start + delay
            movement.duration = 1.65
            movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.58, 0.24, 1)
            movement.fillMode = .both
            movement.isRemovedOnCompletion = false
            particle.add(movement, forKey: "gather")
            let visibility = CAKeyframeAnimation(keyPath: "opacity")
            let peak = index < 28 ? 0.12 : 0.2 + random() * 0.55
            visibility.values = [0, peak, peak * 0.8, 0]
            visibility.keyTimes = [0, 0.25, 0.67, 1]
            visibility.beginTime = start + delay
            visibility.duration = 2.05
            visibility.fillMode = .both
            visibility.isRemovedOnCompletion = false
            particle.add(visibility, forKey: "dust")
        }
    }

    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let face = weight == .semibold ? "75_SemiBold" : "55_Regular"
        return NSFont(name: "AlibabaPuHuiTi_3_\(face)", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func textLayer(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, scale: CGFloat) -> CATextLayer {
        let font = font(size: size, weight: weight)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let layer = CATextLayer()
        layer.string = text
        layer.font = font
        layer.fontSize = size
        layer.foregroundColor = color.cgColor
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(attributed.size().width) + 2, height: ceil(attributed.size().height) + 2)
        layer.alignmentMode = .center
        layer.contentsScale = scale
        return layer
    }

    private static func animate(_ layer: CALayer, _ path: String, from: Any, to: Any, at time: CFTimeInterval, duration: CFTimeInterval,
                                timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut), key: String? = nil) {
        let animation = CABasicAnimation(keyPath: path)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = time
        animation.duration = duration
        animation.timingFunction = timing
        animation.fillMode = key == nil ? .both : .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key ?? path)
    }
}

private extension NSFont {
    func width(of string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: self]).width
    }
}

@MainActor
private final class IntroductionPanel: NSPanel {
    var onSkip: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSkip?() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onSkip?() }
}
