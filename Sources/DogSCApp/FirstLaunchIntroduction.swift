import AppKit
import CoreImage
import CoreText
import QuartzCore
import SwiftUI

/// What the live permission page shows beneath the opening title.
enum PermissionIntroStage: Int, Comparable {
    /// The window is an empty sheet; its controls wait out of sight.
    case blank
    /// The brand is docking into the header and the controls rise into place.
    case settling
    case settled

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
final class PermissionOnboardingPresentation: ObservableObject {
    @Published var isIntroAnimating = false
    @Published var isTourReady = false
    @Published var introStage: PermissionIntroStage = .settled
    /// Read while a stage change is being rendered. Resetting, skipping and
    /// cancelling jump straight to their state instead of animating toward it.
    var animatesIntro = true
}

/// The opening title: one take on a darkened, defocused desktop.
///
/// The icon pulls into focus, a hairline ring records one revolution around
/// it, and the wordmark rises from its baseline. The stage then clears while
/// the brand docks into the real permission window. Everything is finite
/// compositor animation scheduled once: no screenshot, display timer, media
/// decoder or per-frame layout, and no second set of controls.
@MainActor
final class FirstLaunchIntroduction {
    static let seenKey = "permissions.soft-light-introduction-seen"
    /// Matches the first-use tour's shade so one hands over to the other.
    private static let tourDim = NSColor(white: 0.04, alpha: 0.48)
    private static let ink = RecorderStyle.inkNSColor
    private static let recording = NSColor(red: 1.0, green: 0.31, blue: 0.29, alpha: 1)

    private var glassPanel: NSPanel?
    private var brandPanel: IntroductionPanel?
    private var dimPanel: NSPanel?
    private var sequence: Task<Void, Never>?
    private var resignationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private weak var destinationWindow: NSWindow?
    private var completion: (() -> Void)?
    private let presentation: PermissionOnboardingPresentation

    init(presentation: PermissionOnboardingPresentation) {
        self.presentation = presentation
    }

    private(set) var isPresenting = false

    /// - Parameter leadsIntoTour: the step-by-step guide follows immediately,
    ///   so the stage settles into the guide's dimmer instead of a bare desktop.
    func play(over destination: NSWindow, leadsIntoTour: Bool, completion: @escaping () -> Void) {
        guard !isPresenting else { return }
        closeDim()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screen = destination.screen ?? NSScreen.main else {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
            destination.makeKeyAndOrderFront(nil)
            completion()
            return
        }

        isPresenting = true
        destinationWindow = destination
        self.completion = completion
        presentation.animatesIntro = false
        presentation.introStage = .blank
        presentation.isIntroAnimating = true

        let screenFrame = screen.frame
        let bounds = NSRect(origin: .zero, size: screenFrame.size)
        let backing = screen.backingScaleFactor
        let target = destination.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let stageLevel = NSWindow.Level.mainMenu.rawValue + 1

        // Defocused desktop. The system material is live, so nothing is captured.
        let glass = Self.stagePanel(frame: screenFrame, level: stageLevel)
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        let veil = NSView(frame: bounds)
        veil.wantsLayer = true
        let tint = CALayer()
        tint.frame = bounds
        tint.backgroundColor = NSColor(white: 0.02, alpha: 0.38).cgColor
        veil.layer?.addSublayer(tint)
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.frame = bounds
        vignette.colors = [NSColor.clear.cgColor, NSColor(white: 0, alpha: 0.46).cgColor]
        vignette.locations = [0.3, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.08, y: 1.08)
        veil.layer?.addSublayer(vignette)
        effect.addSubview(veil)
        glass.contentView = effect
        glass.alphaValue = 0
        glassPanel = glass

        let brand = IntroductionPanel(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        Self.configure(brand, level: stageLevel + 1)
        brand.setAccessibilityLabel(appLocalized("DogSC 启动动画，按 Esc 跳过"))
        brand.onSkip = { [weak self] in self?.finish(activateDestination: true) }
        let root = CALayer()
        root.frame = bounds
        root.contentsScale = backing
        let view = NSView(frame: bounds)
        view.layer = root
        view.wantsLayer = true
        brand.contentView = view
        brandPanel = brand

        // MARK: Composition

        let scale = min(max(bounds.height / 1000, 0.86), 1.3)
        let iconSize = 132 * scale
        let wordSize = 58 * scale
        let centre = CGPoint(x: bounds.midX, y: bounds.midY + 26 * scale)
        let iconCentre = CGPoint(x: centre.x, y: centre.y + 64 * scale)
        let ringRadius = iconSize * 0.75

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.bounds = CGRect(x: 0, y: 0, width: 820 * scale, height: 820 * scale)
        glow.position = CGPoint(x: centre.x, y: centre.y + 20 * scale)
        glow.colors = [NSColor(red: 0.86, green: 0.92, blue: 1, alpha: 0.16).cgColor,
                       NSColor(red: 0.86, green: 0.92, blue: 1, alpha: 0.045).cgColor,
                       NSColor.clear.cgColor]
        glow.locations = [0, 0.42, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.opacity = 0
        root.addSublayer(glow)

        let ringSide = ringRadius * 2 + 8 * scale
        let ringPath = CGMutablePath()
        ringPath.addArc(center: CGPoint(x: ringSide / 2, y: ringSide / 2), radius: ringRadius,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        ring.position = iconCentre
        ring.path = ringPath
        ring.fillColor = nil
        ring.strokeColor = NSColor(white: 1, alpha: 0.36).cgColor
        ring.lineWidth = max(1, 1.25 * scale)
        ring.lineCap = .round
        ring.strokeEnd = 0
        root.addSublayer(ring)

        // Blurred and sharp copies cross-fade: a focus pull without a live filter.
        let pixels = max(256, (iconSize * backing).rounded(.up))
        var proposed = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        let iconImage = NSApplication.shared.applicationIconImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        icon.position = iconCentre
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.42
        icon.shadowRadius = 30 * scale
        icon.shadowOffset = CGSize(width: 0, height: -16 * scale)
        icon.opacity = 0
        let soft = CALayer()
        let sharp = CALayer()
        for (layer, image) in [(soft, iconImage.flatMap { Self.defocused($0) } ?? iconImage), (sharp, iconImage)] {
            layer.frame = icon.bounds
            layer.contents = image
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = backing
            icon.addSublayer(layer)
        }
        sharp.opacity = 0
        root.addSublayer(icon)

        // The stroke's leading point: the one colour on the stage.
        let headSize = 7 * scale
        let head = CALayer()
        head.bounds = CGRect(x: 0, y: 0, width: headSize, height: headSize)
        head.cornerRadius = headSize / 2
        head.backgroundColor = Self.recording.cgColor
        head.shadowColor = Self.recording.cgColor
        head.shadowOpacity = 0.95
        head.shadowRadius = 9 * scale
        head.shadowOffset = .zero
        head.position = CGPoint(x: iconCentre.x, y: iconCentre.y + ringRadius)
        head.opacity = 0
        root.addSublayer(head)
        let orbit = CGMutablePath()
        orbit.addArc(center: iconCentre, radius: ringRadius,
                     startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        let pulseSide = headSize * 2.2
        let pulse = CAShapeLayer()
        pulse.bounds = CGRect(x: 0, y: 0, width: pulseSide, height: pulseSide)
        pulse.position = head.position
        pulse.path = CGPath(ellipseIn: pulse.bounds, transform: nil)
        pulse.fillColor = nil
        pulse.strokeColor = Self.recording.cgColor
        pulse.lineWidth = max(1, 1.25 * scale)
        pulse.opacity = 0
        root.addSublayer(pulse)

        let word = Self.wordmark("DogSC", size: wordSize, backing: backing)
        word.container.position = CGPoint(x: centre.x, y: centre.y - 62 * scale)
        root.addSublayer(word.container)

        let subtitleText = appLocalized("丝滑录屏")
        let isWideScript = subtitleText.unicodeScalars.contains { $0.value >= 0x2E80 }
        let subtitle = Self.textLayer(subtitleText, size: 17 * scale, kern: (isWideScript ? 7 : 0.6) * scale,
                                      color: NSColor(white: 1, alpha: 0.6), backing: backing)
        let subtitleRest = CGPoint(x: centre.x, y: centre.y - 112 * scale)
        subtitle.position = subtitleRest
        subtitle.opacity = 0
        root.addSublayer(subtitle)

        let skip = Self.textLayer(appLocalized("按 Esc 跳过"), size: 12, kern: 0.4,
                                  color: NSColor(white: 1, alpha: 0.4), backing: backing)
        skip.position = CGPoint(x: bounds.midX, y: max(40, bounds.height * 0.06))
        skip.opacity = 0
        root.addSublayer(skip)

        // MARK: Timeline

        let start = CACurrentMediaTime() + 0.08
        let arrive = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        let sweep = CAMediaTimingFunction(controlPoints: 0.62, 0, 0.3, 1)
        let dock = CAMediaTimingFunction(controlPoints: 0.34, 0, 0.1, 1)

        Self.animate(glow, "opacity", from: 0, to: 1, at: start + 0.1, duration: 1.1)

        Self.animate(icon, "opacity", from: 0, to: 1, at: start + 0.15, duration: 0.4)
        Self.animate(icon, "transform.scale", from: 1.2, to: 1, at: start + 0.15, duration: 1.0, timing: arrive)
        Self.animate(sharp, "opacity", from: 0, to: 1, at: start + 0.36, duration: 0.5)
        Self.animate(soft, "opacity", from: 1, to: 0, at: start + 0.56, duration: 0.42)

        let ringStart = start + 0.4, ringDuration = 0.86
        Self.animate(ring, "strokeEnd", from: 0, to: 1, at: ringStart, duration: ringDuration, timing: sweep)
        Self.animate(head, "opacity", from: 0, to: 1, at: ringStart, duration: 0.16)
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = orbit
        travel.calculationMode = .paced
        travel.beginTime = ringStart
        travel.duration = ringDuration
        travel.timingFunction = sweep
        travel.fillMode = .both
        travel.isRemovedOnCompletion = false
        head.add(travel, forKey: "orbit")

        // One revolution completes: the point rings out and the title takes over.
        let closed = ringStart + ringDuration
        Self.animate(pulse, "opacity", from: 0.8, to: 0, at: closed, duration: 0.6, key: "pulse.fade")
        Self.animate(pulse, "transform.scale", from: 1, to: 4.2, at: closed, duration: 0.6, timing: arrive, key: "pulse.grow")
        Self.animate(head, "opacity", from: 1, to: 0, at: closed + 0.08, duration: 0.36, key: "head.exit")
        Self.animate(ring, "opacity", from: 1, to: 0, at: closed + 0.04, duration: 0.62, key: "ring.exit")
        Self.animate(ring, "transform.scale", from: 1, to: 1.08, at: closed + 0.04, duration: 0.62, timing: arrive, key: "ring.grow")

        let lineHeight = word.container.bounds.height
        for (index, letter) in word.letters.enumerated() {
            let rest = letter.position
            Self.animate(letter, "position", from: NSValue(point: CGPoint(x: rest.x, y: rest.y - lineHeight)),
                         to: NSValue(point: rest), at: start + 0.92 + Double(index) * 0.055, duration: 0.7, timing: arrive)
        }
        Self.animate(subtitle, "opacity", from: 0, to: 1, at: start + 1.36, duration: 0.5)
        Self.animate(subtitle, "position", from: NSValue(point: CGPoint(x: subtitleRest.x, y: subtitleRest.y - 9 * scale)),
                     to: NSValue(point: subtitleRest), at: start + 1.36, duration: 0.7, timing: arrive)
        Self.animate(skip, "opacity", from: 0, to: 1, at: start + 0.7, duration: 0.4)

        // Hand-off: the brand docks where the live header will draw it.
        let settle = start + 2.3
        let brandSize = PermissionOnboardingStyle.brandSize
        let brandCentre = CGPoint(x: target.minX + PermissionOnboardingStyle.brandInset.x + brandSize / 2,
                                  y: target.maxY - PermissionOnboardingStyle.brandInset.y - brandSize / 2)
        let wordScale = 15 / wordSize
        let wordCentre = CGPoint(x: target.minX + PermissionOnboardingStyle.brandInset.x + brandSize + 9
                                    + word.width * wordScale / 2,
                                 y: brandCentre.y)
        Self.animate(glow, "opacity", from: 1, to: 0, at: settle, duration: 0.5, key: "glow.exit")
        Self.animate(subtitle, "opacity", from: 1, to: 0, at: settle, duration: 0.22, key: "subtitle.exit")
        Self.animate(skip, "opacity", from: 1, to: 0, at: settle, duration: 0.2, key: "skip.exit")
        Self.animate(icon, "position", from: NSValue(point: icon.position), to: NSValue(point: brandCentre),
                     at: settle, duration: 0.9, timing: dock)
        Self.animate(icon, "transform.scale", from: 1, to: brandSize / iconSize, at: settle, duration: 0.9, timing: dock, key: "icon.dock")
        Self.animate(icon, "shadowOpacity", from: 0.42, to: 0, at: settle, duration: 0.45)
        Self.animate(word.container, "position", from: NSValue(point: word.container.position), to: NSValue(point: wordCentre),
                     at: settle + 0.03, duration: 0.9, timing: dock)
        Self.animate(word.container, "transform.scale", from: 1, to: wordScale, at: settle + 0.03, duration: 0.9, timing: dock)
        for letter in word.letters {
            Self.animate(letter, "foregroundColor", from: NSColor.white.cgColor, to: Self.ink.cgColor,
                         at: settle + 0.22, duration: 0.5)
        }

        // MARK: Presentation

        NSApp.activate(ignoringOtherApps: true)
        // Lay out the real page once; it stays invisible until the hand-off.
        destination.alphaValue = 0
        destination.orderFront(nil)
        destination.contentView?.layoutSubtreeIfNeeded()
        destination.contentView?.displayIfNeeded()
        glass.orderFront(nil)
        brand.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glass.animator().alphaValue = 1
        }

        // No input monitor survives the stage. App switches, display changes
        // and Esc all remove it and restore the live window.
        resignationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(activateDestination: false) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !NSScreen.screens.contains(where: { $0.frame == screenFrame }) else { return }
                self?.finish(activateDestination: false)
            }
        }
        sequence = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(2380))
                self?.beginHandOff(leadsIntoTour: leadsIntoTour)
                try await Task.sleep(for: .milliseconds(260))
                self?.revealPage()
                try await Task.sleep(for: .milliseconds(740))
            } catch { return }
            self?.finish(activateDestination: true, natural: true)
        }
    }

    func cancel() {
        if isPresenting { finish(activateDestination: false) }
        else { closeDim() }
    }

    private func beginHandOff(leadsIntoTour: Bool) {
        guard isPresenting, let destination = destinationWindow else { return }
        if leadsIntoTour {
            // A plain dimmer rises beneath the window as the glass clears, so
            // the guide's own shade can take over without the desktop flashing.
            let dim = Self.stagePanel(frame: glassPanel?.frame ?? destination.frame, level: destination.level.rawValue)
            dim.ignoresMouseEvents = true
            dim.backgroundColor = Self.tourDim
            dim.alphaValue = 0
            dim.order(.below, relativeTo: destination.windowNumber)
            dimPanel = dim
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.78
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glassPanel?.animator().alphaValue = 0
            dimPanel?.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            destination.animator().alphaValue = 1
        }
    }

    private func revealPage() {
        guard isPresenting else { return }
        presentation.animatesIntro = true
        presentation.introStage = .settling
    }

    private func finish(activateDestination: Bool, natural: Bool = false) {
        guard isPresenting else { return }
        isPresenting = false
        sequence?.cancel()
        sequence = nil
        if let resignationObserver { NotificationCenter.default.removeObserver(resignationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        resignationObserver = nil
        screenObserver = nil
        let destination = destinationWindow
        destinationWindow = nil
        destination?.alphaValue = 1
        UserDefaults.standard.set(true, forKey: Self.seenKey)

        presentation.animatesIntro = false
        presentation.introStage = .settled
        presentation.isIntroAnimating = false

        let brand = brandPanel, glass = glassPanel
        brandPanel = nil
        glassPanel = nil
        brand?.onSkip = nil
        let closePanels: @MainActor @Sendable () -> Void = {
            for panel in [brand, glass] {
                panel?.orderOut(nil)
                panel?.contentView = nil
                panel?.close()
            }
        }
        if natural {
            // Let the live header repaint beneath its docked copy first.
            destination?.contentView?.layoutSubtreeIfNeeded()
            destination?.contentView?.displayIfNeeded()
            // Fade out the docked brandPanel smoothly so the live SwiftUI header
            // seamlessly takes over beneath it without any single-frame gap.
            glass?.orderOut(nil)
            glass?.contentView = nil
            glass?.close()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                brand?.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    brand?.orderOut(nil)
                    brand?.contentView = nil
                    brand?.close()
                }
            }
        } else {
            closePanels()
        }
        if activateDestination, NSApp.isActive, destination?.isVisible == true {
            destination?.makeKeyAndOrderFront(nil)
        }

        let callback = completion
        completion = nil
        callback?()
        closeDim()
    }

    private func closeDim() {
        dimPanel?.orderOut(nil)
        dimPanel?.close()
        dimPanel = nil
    }

    // MARK: - Building blocks

    private static func stagePanel(frame: NSRect, level: Int) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(panel, level: level)
        return panel
    }

    private static func configure(_ panel: NSPanel, level: Int) {
        panel.level = NSWindow.Level(rawValue: level)
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
    }

    private static func defocused(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(image.width) * 0.05)
            .cropped(to: source.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: source.extent)
    }

    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // Registers the bundled faces before AppKit looks them up by name.
        _ = Font.appUI(size: size, weight: .semibold)
        let face = weight == .semibold ? "75_SemiBold" : "55_Regular"
        return NSFont(name: "AlibabaPuHuiTi_3_\(face)", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Each glyph is its own layer at the position Core Text gives it in the
    /// whole word, inside a clipping line box it can rise into.
    private static func wordmark(_ text: String, size: CGFloat, backing: CGFloat)
        -> (container: CALayer, letters: [CATextLayer], width: CGFloat) {
        let font = font(size: size, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: ceil(measured.width), height: ceil(measured.height))
        container.masksToBounds = true
        var letters: [CATextLayer] = []
        let units = Array(text.utf16)
        for index in units.indices {
            let glyph = String(utf16CodeUnits: [units[index]], count: 1)
            let layer = CATextLayer()
            layer.string = glyph
            layer.font = font
            layer.fontSize = size
            layer.foregroundColor = NSColor.white.cgColor
            layer.contentsScale = backing
            layer.alignmentMode = .left
            layer.anchorPoint = .zero
            layer.bounds = CGRect(x: 0, y: 0,
                                  width: ceil((glyph as NSString).size(withAttributes: attributes).width) + 2,
                                  height: container.bounds.height)
            layer.position = CGPoint(x: CTLineGetOffsetForStringIndex(line, index, nil), y: 0)
            container.addSublayer(layer)
            letters.append(layer)
        }
        return (container, letters, measured.width)
    }

    private static func textLayer(_ text: String, size: CGFloat, kern: CGFloat, color: NSColor, backing: CGFloat) -> CATextLayer {
        let font = font(size: size, weight: .regular)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let layer = CATextLayer()
        layer.string = attributed
        // Kerning trails the last glyph too; trimming it keeps the word centred.
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(attributed.size().width - kern) + 2,
                              height: ceil(attributed.size().height) + 2)
        layer.alignmentMode = .left
        layer.contentsScale = backing
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
        // A property's first animation also holds its starting value; later
        // ones on the same property only take over once they begin.
        animation.fillMode = key == nil ? .both : .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key ?? path)
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
