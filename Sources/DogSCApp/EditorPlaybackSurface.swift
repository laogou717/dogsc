import AppKit
import QuartzCore
import SwiftUI

// MARK: - Native timeline playback indicators

/// A tiny AppKit label fed by the canvas's one transport sample. Updating one
/// string does not invalidate the inspector, wallpaper grid or timeline lanes.
struct NativePlaybackTimeView: NSViewRepresentable {
    let playbackController: EditorPlaybackController

    func makeNSView(context: Context) -> NativePlaybackTimeNSView {
        let view = NativePlaybackTimeNSView()
        view.configure(playbackController)
        return view
    }

    func updateNSView(_ view: NativePlaybackTimeNSView, context: Context) {
        view.configure(playbackController)
    }

    static func dismantleNSView(_ view: NativePlaybackTimeNSView, coordinator: Void) {
        view.invalidate()
    }
}

@MainActor
final class NativePlaybackTimeNSView: NSView {
    private weak var playbackController: EditorPlaybackController?
    private let textField = NSTextField(labelWithString: "00:00.00")
    private var lastDisplayedCentiseconds: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        textField.textColor = .labelColor
        textField.alignment = .right
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        addSubview(textField)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // An NSTextField label aligns its glyphs near the top when stretched
        // to the full 28-point transport slot. The duration on the other side
        // is a vertically centred SwiftUI Text, which made the two clocks look
        // like different rows. Lay out the native label at its intrinsic
        // height and centre that rect instead.
        let intrinsicHeight = min(
            ceil(textField.intrinsicContentSize.height),
            bounds.height
        )
        textField.frame = CGRect(
            x: 0,
            y: floor((bounds.height - intrinsicHeight) / 2),
            width: bounds.width,
            height: intrinsicHeight
        )
    }

    func configure(_ playbackController: EditorPlaybackController) {
        if self.playbackController !== playbackController {
            self.playbackController?.removeNativeTimelineObserver(self)
            playbackController.addNativeTimelineObserver(self)
        }
        self.playbackController = playbackController
    }

    func invalidate() {
        playbackController?.removeNativeTimelineObserver(self)
        playbackController = nil
    }

    private func updateText(_ snapshot: EditorPlaybackTimelineSnapshot) {
        // Use the same clamped, floor-to-centisecond representation as the
        // ruler and duration label. `String(format: "%.2f")` rounded the
        // exact final media time up while the duration label rounded down, so
        // the current time could visually read 13.58 / 13.57 at the endpoint
        // even though both clocks were already clamped to the same instant.
        let total = EditorPlaybackClockPolicy.clampedTime(
            snapshot.outputTime,
            duration: snapshot.duration
        )
        let centiseconds = max(Int((total * 100).rounded(.down)), 0)
        // Consume every distinct time from the existing display-link sample.
        // A five-centisecond gate made the label step at an uneven ~20 Hz even
        // while the playhead was moving at the display cadence.
        guard centiseconds != lastDisplayedCentiseconds else { return }
        lastDisplayedCentiseconds = centiseconds
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textField.stringValue = String(
            format: "%02d:%02d.%02d",
            minutes,
            seconds,
            fraction
        )
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NativePlaybackTimeNSView: EditorPlaybackTimelineObserver {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot) {
        updateText(snapshot)
    }
}

enum NativeTimelinePlayheadPart {
    case line
    case knob
}

/// The line stays inside the scrolling canvas; the knob is drawn above the
/// viewport so its center can reach the left endpoint without clipping it.
struct NativeTimelinePlayheadView: NSViewRepresentable {
    let playbackController: EditorPlaybackController
    let duration: TimeInterval
    let part: NativeTimelinePlayheadPart
    var scrollView: NSScrollView? = nil
    var leadingInset: CGFloat = 0
    var documentWidth: CGFloat? = nil

    func makeNSView(context: Context) -> NativeTimelinePlayheadNSView {
        let view = NativeTimelinePlayheadNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NativeTimelinePlayheadNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NativeTimelinePlayheadNSView) {
        view.configure(
            playbackController, duration: duration, part: part,
            scrollView: scrollView, leadingInset: leadingInset,
            documentWidth: documentWidth
        )
    }

    static func dismantleNSView(_ view: NativeTimelinePlayheadNSView, coordinator: Void) {
        view.invalidate()
    }
}

@MainActor
final class NativeTimelinePlayheadNSView: NSView {
    private weak var playbackController: EditorPlaybackController?
    private var duration: TimeInterval = 0
    private let lineLayer = CALayer()
    private let knobLayer = CAShapeLayer()
    private var part: NativeTimelinePlayheadPart = .line
    private weak var trackedScrollView: NSScrollView?
    private var scrollObservations: [NSObjectProtocol] = []
    private var leadingInset: CGFloat = 0
    private var documentWidth: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        knobLayer.lineWidth = 1
        knobLayer.path = CGPath(
            ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10),
            transform: nil
        )
        layer?.addSublayer(lineLayer)
        layer?.addSublayer(knobLayer)
        updateAppearanceColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            lineLayer.backgroundColor = NSColor.labelColor.cgColor
            knobLayer.fillColor = NSColor.labelColor.cgColor
            knobLayer.strokeColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.85)
                .cgColor
        }
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    func configure(
        _ playbackController: EditorPlaybackController,
        duration: TimeInterval,
        part: NativeTimelinePlayheadPart,
        scrollView: NSScrollView?,
        leadingInset: CGFloat,
        documentWidth: CGFloat?
    ) {
        if self.playbackController !== playbackController {
            self.playbackController?.removeNativeTimelineObserver(self)
            playbackController.addNativeTimelineObserver(self)
        }
        self.playbackController = playbackController
        self.duration = max(duration, 0)
        self.part = part
        self.leadingInset = leadingInset
        self.documentWidth = documentWidth
        if trackedScrollView !== scrollView {
            scrollObservations.forEach(NotificationCenter.default.removeObserver)
            scrollObservations.removeAll(keepingCapacity: true)
            trackedScrollView = scrollView
            if let clipView = scrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                scrollObservations.append(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateLayers() }
                })
            }
            if let documentView = scrollView?.documentView {
                documentView.postsFrameChangedNotifications = true
                scrollObservations.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateLayers() }
                })
            }
        }
        updateLayers()
    }

    func invalidate() {
        playbackController?.removeNativeTimelineObserver(self)
        playbackController = nil
        scrollObservations.forEach(NotificationCenter.default.removeObserver)
        scrollObservations.removeAll(keepingCapacity: false)
        trackedScrollView = nil
    }

    private func updateLayers(time: TimeInterval? = nil) {
        let time = time ?? playbackController?.outputTime ?? 0
        let contentWidth = part == .line ? bounds.width : max(
            trackedScrollView?.documentView?.bounds.width ?? documentWidth ?? 0,
            0
        )
        let fraction = min(max(time / max(duration, 0.001), 0), 1)
        let lineX = contentWidth * CGFloat(fraction)
        let visible = trackedScrollView?.documentVisibleRect
        let knobX = leadingInset + lineX - (visible?.minX ?? 0)
        let viewportWidth = visible?.width ?? max(bounds.width - leadingInset, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.isHidden = part != .line
        // An offscreen playhead must disappear, never stick to a viewport edge.
        knobLayer.isHidden = part != .knob || knobX < leadingInset
            || knobX > leadingInset + viewportWidth
        lineLayer.frame = CGRect(x: lineX - 1, y: 0, width: 2, height: bounds.height)
        knobLayer.frame = CGRect(x: knobX - 5, y: bounds.height - 12, width: 10, height: 10)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NativeTimelinePlayheadNSView: EditorPlaybackTimelineObserver {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot) {
        duration = max(snapshot.duration, 0)
        updateLayers(time: snapshot.outputTime)
    }
}

/// A full-duration map that observes AppKit's clip view directly. Scrolling
/// updates two CALayers without rebuilding clips, waveforms or motion lanes.
/// Clicking or dragging the map also seeks and centres the detailed timeline,
/// so high zoom never traps the user in a context-free viewport.
struct NativeTimelineOverviewView: NSViewRepresentable {
    let scrollView: NSScrollView?
    let playbackController: EditorPlaybackController
    let duration: TimeInterval

    func makeNSView(context: Context) -> NativeTimelineOverviewNSView {
        let view = NativeTimelineOverviewNSView()
        view.configure(scrollView: scrollView, playbackController: playbackController, duration: duration)
        return view
    }

    func updateNSView(_ view: NativeTimelineOverviewNSView, context: Context) {
        view.configure(scrollView: scrollView, playbackController: playbackController, duration: duration)
    }

    static func dismantleNSView(_ view: NativeTimelineOverviewNSView, coordinator: Void) {
        view.invalidate()
    }
}

@MainActor
final class NativeTimelineOverviewNSView: NSView {
    private weak var trackedScrollView: NSScrollView?
    private weak var playbackController: EditorPlaybackController?
    private var duration: TimeInterval = 0
    private var lastDisplayedOutputTime: TimeInterval?
    private var observationTokens: [NSObjectProtocol] = []
    private let trackLayer = CALayer()
    private let viewportLayer = CALayer()
    private let playheadLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPointerDown = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        trackLayer.borderWidth = 0
        trackLayer.cornerRadius = 2.5
        viewportLayer.borderWidth = 0
        viewportLayer.cornerRadius = 2.5
        playheadLayer.backgroundColor = NSColor(
            calibratedRed: 0.90,
            green: 0.67,
            blue: 0.36,
            alpha: 1
        ).cgColor
        playheadLayer.cornerRadius = 1
        playheadLayer.shadowColor = NSColor.black.cgColor
        playheadLayer.shadowOpacity = 0
        playheadLayer.shadowRadius = 2
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(viewportLayer)
        layer?.addSublayer(playheadLayer)
        updateInteractionAppearance(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateInteractionAppearance(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    func invalidate() {
        observationTokens.forEach(NotificationCenter.default.removeObserver)
        observationTokens.removeAll(keepingCapacity: false)
        playbackController?.removeNativeTimelineObserver(self)
        trackedScrollView = nil
        playbackController = nil
    }

    func configure(
        scrollView: NSScrollView?,
        playbackController: EditorPlaybackController,
        duration: TimeInterval
    ) {
        if self.playbackController !== playbackController {
            self.playbackController?.removeNativeTimelineObserver(self)
            playbackController.addNativeTimelineObserver(self)
        }
        self.playbackController = playbackController
        self.duration = max(duration, 0)
        if trackedScrollView !== scrollView { observe(scrollView) }
        updateLayers()
    }

    private func observe(_ scrollView: NSScrollView?) {
        observationTokens.forEach(NotificationCenter.default.removeObserver)
        observationTokens.removeAll(keepingCapacity: true)
        trackedScrollView = scrollView
        guard let scrollView else { return }

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        observationTokens.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLayers() }
        })
        if let documentView = scrollView.documentView {
            documentView.postsFrameChangedNotifications = true
            observationTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLayers() }
            })
        }
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    private func updateLayers() {
        // Share the detailed timeline's horizontal endpoints; a decorative
        // inset would put the overview's zero marker on a different axis.
        let track = CGRect(
            x: 0,
            y: max((bounds.height - 5) / 2, 0),
            width: max(bounds.width, 1),
            height: 5
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = track
        guard let scrollView = trackedScrollView else {
            viewportLayer.frame = track
            CATransaction.commit()
            updatePlayhead()
            return
        }
        let documentWidth = max(scrollView.documentView?.bounds.width ?? 1, 1)
        let visible = scrollView.documentVisibleRect
        let startFraction = min(max(visible.minX / documentWidth, 0), 1)
        let widthFraction = min(max(visible.width / documentWidth, 0), 1)
        let viewportWidth = max(track.width * widthFraction, 8)
        let viewportX = min(track.minX + track.width * startFraction, track.maxX - viewportWidth)
        viewportLayer.frame = CGRect(
            x: max(viewportX, track.minX), y: track.minY,
            width: min(viewportWidth, track.width), height: track.height
        )
        CATransaction.commit()
        updatePlayhead()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateInteractionAppearance(animated: true)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateInteractionAppearance(animated: true)
        window?.invalidateCursorRects(for: self)
    }

    private func updatePlayhead(time: TimeInterval? = nil, isPlaying: Bool = false) {
        let track = trackLayer.frame
        let time = time ?? playbackController?.outputTime ?? 0
        if isPlaying,
           let lastDisplayedOutputTime,
           abs(time - lastDisplayedOutputTime) < (1.0 / 30.0 - 0.000_1) {
            return
        }
        lastDisplayedOutputTime = time
        let fraction = min(max(time / max(duration, 0.001), 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(
            x: track.minX + track.width * CGFloat(fraction) - 0.75,
            y: max(track.minY - 2, 0), width: 1.5, height: track.height + 4
        )
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        isPointerDown = true
        updateInteractionAppearance(animated: true)
        window?.invalidateCursorRects(for: self)
        playbackController?.beginScrubbing()
        updateScrubbing(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateScrubbing(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateScrubbing(with: event)
        playbackController?.endScrubbing()
        isPointerDown = false
        updateInteractionAppearance(animated: true)
        window?.invalidateCursorRects(for: self)
    }

    private func updateInteractionAppearance(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let chrome = NSColor.labelColor
            trackLayer.backgroundColor = chrome.withAlphaComponent(
                isPointerInside ? 0.065 : 0.035
            ).cgColor
            trackLayer.borderColor = chrome.withAlphaComponent(0.06).cgColor
            viewportLayer.backgroundColor = chrome.withAlphaComponent(
                isPointerDown ? 0.24 : isPointerInside ? 0.18 : 0.11
            ).cgColor
            viewportLayer.borderColor = chrome.withAlphaComponent(
                isPointerDown ? 0.82 : isPointerInside ? 0.64 : 0.48
            ).cgColor
        }
        CATransaction.commit()
    }

    private func updateScrubbing(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let track = trackLayer.frame
        guard track.width > 0 else { return }
        let fraction = min(max((local.x - track.minX) / track.width, 0), 1)
        playbackController?.updateScrubbing(to: duration * TimeInterval(fraction))

        guard let scrollView = trackedScrollView else { return }
        let documentWidth = max(scrollView.documentView?.bounds.width ?? 1, 1)
        let viewportWidth = max(scrollView.contentView.bounds.width, 1)
        let maximumOffset = max(documentWidth - viewportWidth, 0)
        let targetOffset = min(
            max(documentWidth * fraction - viewportWidth / 2, 0),
            maximumOffset
        )
        scrollView.contentView.scroll(
            to: NSPoint(x: targetOffset, y: scrollView.documentVisibleRect.origin.y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isPointerDown ? .closedHand : .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

extension NativeTimelineOverviewNSView: EditorPlaybackTimelineObserver {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot) {
        duration = max(snapshot.duration, 0)
        updatePlayhead(time: snapshot.outputTime, isPlaying: snapshot.isPlaying)
    }
}
