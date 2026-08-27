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
    private let textField = NSTextField(labelWithString: "0:00.00")
    private var lastDisplayedCentiseconds: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textField.textColor = .secondaryLabelColor
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
        textField.frame = bounds
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
        if snapshot.isPlaying,
           let lastDisplayedCentiseconds,
           abs(centiseconds - lastDisplayedCentiseconds) < 5 {
            return
        }
        lastDisplayedCentiseconds = centiseconds
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        textField.stringValue = String(
            format: "%d:%02d.%02d",
            minutes,
            seconds,
            fraction
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NativePlaybackTimeNSView: EditorPlaybackTimelineObserver {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot) {
        updateText(snapshot)
    }
}

/// The playhead is two CALayers driven by the canvas's transport sample.
struct NativeTimelinePlayheadView: NSViewRepresentable {
    let playbackController: EditorPlaybackController
    let duration: TimeInterval

    func makeNSView(context: Context) -> NativeTimelinePlayheadNSView {
        let view = NativeTimelinePlayheadNSView()
        view.configure(playbackController, duration: duration)
        return view
    }

    func updateNSView(_ view: NativeTimelinePlayheadNSView, context: Context) {
        view.configure(playbackController, duration: duration)
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
    // 雾白极简：播放头是界面 chrome 而非内容，用米白而不是紫色。
    private let accentColor = NSColor(
        calibratedWhite: 0.92,
        alpha: 1
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        lineLayer.backgroundColor = accentColor.cgColor
        knobLayer.fillColor = accentColor.cgColor
        knobLayer.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        knobLayer.lineWidth = 1
        knobLayer.path = CGPath(
            ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10),
            transform: nil
        )
        layer?.addSublayer(lineLayer)
        layer?.addSublayer(knobLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateLayers()
    }

    func configure(
        _ playbackController: EditorPlaybackController,
        duration: TimeInterval
    ) {
        if self.playbackController !== playbackController {
            self.playbackController?.removeNativeTimelineObserver(self)
            playbackController.addNativeTimelineObserver(self)
        }
        self.playbackController = playbackController
        self.duration = max(duration, 0)
    }

    func invalidate() {
        playbackController?.removeNativeTimelineObserver(self)
        playbackController = nil
    }

    private func updateLayers(time: TimeInterval? = nil) {
        let time = time ?? playbackController?.outputTime ?? 0
        let rawX = bounds.width * CGFloat(time / max(duration, 0.001))
        let lineX = min(max(rawX, 0), max(bounds.width, 0))
        let knobX = min(max(rawX, 5), max(bounds.width - 5, 5))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        trackLayer.cornerRadius = 3
        viewportLayer.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        viewportLayer.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        viewportLayer.borderWidth = 1
        viewportLayer.cornerRadius = 3
        playheadLayer.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        playheadLayer.cornerRadius = 0.75
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(viewportLayer)
        layer?.addSublayer(playheadLayer)
    }

    required init?(coder: NSCoder) { nil }

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
        let inset: CGFloat = 7
        let track = CGRect(
            x: inset,
            y: max((bounds.height - 6) / 2, 0),
            width: max(bounds.width - inset * 2, 1),
            height: 6
        )
        trackLayer.frame = track
        guard let scrollView = trackedScrollView else {
            viewportLayer.frame = track
            updatePlayhead()
            return
        }
        let documentWidth = max(scrollView.documentView?.bounds.width ?? 1, 1)
        let visible = scrollView.documentVisibleRect
        let startFraction = min(max(visible.minX / documentWidth, 0), 1)
        let widthFraction = min(max(visible.width / documentWidth, 0), 1)
        let viewportWidth = max(track.width * widthFraction, 5)
        let viewportX = min(track.minX + track.width * startFraction, track.maxX - viewportWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.frame = CGRect(
            x: max(viewportX, track.minX), y: track.minY,
            width: min(viewportWidth, track.width), height: track.height
        )
        CATransaction.commit()
        updatePlayhead()
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
            y: max(track.minY - 3, 0), width: 1.5, height: track.height + 6
        )
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        playbackController?.beginScrubbing()
        updateScrubbing(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateScrubbing(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateScrubbing(with: event)
        playbackController?.endScrubbing()
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
        addCursorRect(bounds, cursor: .pointingHand)
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
