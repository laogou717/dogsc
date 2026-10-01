import AppKit
import QuartzCore
import SwiftUI

/// A passive guide above clips and below the real playhead. Mouse movement
/// updates this view directly without rebuilding the timeline's SwiftUI tree.
struct NativeTimelineHoverGuideView: NSViewRepresentable {
    let location: EditorTimelineHoverLocation
    let scrollView: NSScrollView?
    let duration: TimeInterval
    let canvasHeight: CGFloat
    let badgeY: CGFloat
    let isEnabled: Bool

    func makeNSView(context: Context) -> NativeTimelineHoverGuideNSView {
        let view = NativeTimelineHoverGuideNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NativeTimelineHoverGuideNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NativeTimelineHoverGuideNSView) {
        view.configure(location: location, scrollView: scrollView, duration: duration,
                       canvasHeight: canvasHeight, badgeY: badgeY, isEnabled: isEnabled)
    }

    static func dismantleNSView(_ view: NativeTimelineHoverGuideNSView, coordinator: Void) {
        view.invalidate()
    }
}

@MainActor
final class NativeTimelineHoverGuideNSView: NSView, EditorTimelineHoverLocationObserver {
    private weak var location: EditorTimelineHoverLocation?
    private weak var trackedScrollView: NSScrollView?
    private var scrollObservation: NSObjectProtocol?
    private var duration: TimeInterval = 0
    private var canvasHeight: CGFloat = 0
    private var badgeY: CGFloat = 0
    private var isEnabled = false
    private let guideLayer = CAShapeLayer()
    private let badge = NSView()
    private let badgeBackground = CAGradientLayer()
    private let label = NSTextField(labelWithString: "0:00.00")
    private var lastCentiseconds: Int?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guideLayer.lineWidth = 1
        guideLayer.lineDashPattern = [3, 4]
        layer?.addSublayer(guideLayer)
        badge.wantsLayer = true
        badgeBackground.frame = CGRect(x: 0, y: 0, width: 62, height: 18)
        badgeBackground.cornerRadius = 9
        badgeBackground.borderWidth = 0.75
        badgeBackground.shadowColor = NSColor.black.cgColor
        badgeBackground.shadowOpacity = 0.34
        badgeBackground.shadowRadius = 4
        badgeBackground.shadowOffset = CGSize(width: 0, height: 2)
        badgeBackground.shadowPath = CGPath(
            roundedRect: badgeBackground.bounds, cornerWidth: 9, cornerHeight: 9, transform: nil
        )
        badge.layer?.addSublayer(badgeBackground)
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: floor((18 - labelHeight) / 2), width: 62, height: labelHeight)
        badge.addSubview(label)
        addSubview(badge)
        updateColors()
        updatePosition()
    }

    required init?(coder: NSCoder) { nil }

    func configure(location: EditorTimelineHoverLocation, scrollView: NSScrollView?,
                   duration: TimeInterval, canvasHeight: CGFloat, badgeY: CGFloat,
                   isEnabled: Bool) {
        if self.location !== location {
            if self.location?.observer === self { self.location?.observer = nil }
            self.location = location
            location.observer = self
        }
        self.duration = max(duration, 0)
        self.badgeY = badgeY
        self.isEnabled = isEnabled
        if self.canvasHeight != canvasHeight {
            self.canvasHeight = canvasHeight
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0.5, y: 0))
            path.addLine(to: CGPoint(x: 0.5, y: canvasHeight))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            guideLayer.path = path
            CATransaction.commit()
        }
        if trackedScrollView !== scrollView {
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
            scrollObservation = nil
            trackedScrollView = scrollView
            if let clipView = scrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                scrollObservation = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePosition() }
                }
            }
        }
        updatePosition()
    }

    func invalidate() {
        if location?.observer === self { location?.observer = nil }
        location = nil
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        scrollObservation = nil
        trackedScrollView = nil
    }

    override func layout() {
        super.layout()
        updatePosition()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guideLayer.contentsScale = scale
        badgeBackground.contentsScale = scale
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func timelineHoverLocationDidChange() {
        updatePosition()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guideLayer.strokeColor = NSColor.labelColor.withAlphaComponent(0.34).cgColor
            badgeBackground.colors = [NSColor(EditorTheme.cardElevated).cgColor,
                                      NSColor(EditorTheme.panelRaised).cgColor]
            badgeBackground.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
            label.textColor = NSColor.labelColor.withAlphaComponent(0.92)
        }
        CATransaction.commit()
    }

    private func updatePosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isEnabled, let point = location?.viewportPoint, bounds.width > 0 else {
            guideLayer.isHidden = true
            badge.isHidden = true
            return
        }
        let visible = trackedScrollView?.documentVisibleRect ?? bounds
        let x = min(max(point.x + visible.minX, 0), bounds.width)
        guideLayer.isHidden = false
        badge.isHidden = false
        guideLayer.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: canvasHeight)
        let badgeMinX = max(visible.minX, 0) + 3
        let badgeMaxX = max(min(visible.maxX, bounds.width) - 65, badgeMinX)
        badge.frame = CGRect(x: min(max(x - 31, badgeMinX), badgeMaxX),
                             y: badgeY, width: 62, height: 18)
        let centiseconds = max(Int((Double(x / bounds.width) * duration * 100).rounded(.down)), 0)
        if centiseconds != lastCentiseconds {
            lastCentiseconds = centiseconds
            label.stringValue = String(format: "%d:%02d.%02d", centiseconds / 6_000,
                                       (centiseconds / 100) % 60, centiseconds % 100)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
