import AppKit
import AVFoundation
import CoreMedia

enum RecordingCameraPreviewScalePolicy {
    /// Some external cameras expose their landscape image inside a portrait
    /// pixel buffer. `resizeAspectFill` only sees that outer portrait buffer,
    /// so without this correction it faithfully preserves the embedded top
    /// and bottom bars. Restore the proven centre-band correction, but drive it
    /// from the pixels actually delivered instead of a possibly stale device
    /// format descriptor.
    static func correctionScale(sourceWidth: Int, sourceHeight: Int) -> CGFloat {
        guard sourceWidth > 0, sourceHeight > 0, sourceHeight > sourceWidth else {
            return 1
        }
        return CGFloat(sourceHeight) / CGFloat(sourceWidth) * 1.04
    }
}

/// Thread-safe bridge from AVCaptureVideoDataOutput to the recording-page
/// preview. Apple documents `sampleBufferRenderer` as safe to enqueue from a
/// background thread. `DisplayImmediately` replaces any pending image instead
/// of presenting an increasingly stale timestamp queue.
final class ImmediateCameraPreviewFrameSink: @unchecked Sendable {
    private struct PendingFrame: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
    }

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(
        label: "cn.laogou.dogsc.camera-preview-renderer",
        qos: .userInteractive
    )
    private var renderer: AVSampleBufferVideoRenderer?
    private var pendingFrame: PendingFrame?
    private var drainIsScheduled = false

    func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        lock.lock()
        self.renderer = renderer
        if renderer == nil {
            // Do not let a hidden/released preview keep the newest camera
            // IOSurface alive until a queued render block happens to run.
            pendingFrame = nil
        }
        lock.unlock()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        var shouldScheduleDrain = false
        lock.lock()
        if renderer != nil {
            // A real-time preview needs the newest image, never an ordered
            // backlog. Replacing this one retained sample also bounds the
            // preview's IOSurface ownership independently of renderer speed.
            pendingFrame = PendingFrame(sampleBuffer: sampleBuffer)
            if !drainIsScheduled {
                drainIsScheduled = true
                shouldScheduleDrain = true
            }
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        renderQueue.async { [weak self] in
            self?.drainNewestFrames()
        }
    }

    private func drainNewestFrames() {
        while true {
            lock.lock()
            guard let renderer, let pendingFrame else {
                self.pendingFrame = nil
                drainIsScheduled = false
                lock.unlock()
                return
            }
            self.pendingFrame = nil
            lock.unlock()

            autoreleasepool {
                display(pendingFrame.sampleBuffer, using: renderer)
            }
        }
    }

    private func display(
        _ sampleBuffer: CMSampleBuffer,
        using renderer: AVSampleBufferVideoRenderer
    ) {
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            return
        }
        // This is a real-time source, not an offline producer that can pause
        // until the renderer drains. Apple's AVQueuedSampleBufferRendering
        // contract explicitly permits enqueueing while `isReady` is false;
        // DisplayImmediately makes this newest image replace every previously
        // enqueued image. Dropping the newest frame here retained an older
        // pending frame and made the live camera preview visibly lag behind.
        // The recording writer may still be consuming the capture sample on
        // its own queue. Sample attachment dictionaries are mutable, so never
        // add a renderer-only flag to that shared object concurrently. A
        // CMSampleBuffer shallow copy owns a separate attachment dictionary
        // while retaining the same CVPixelBuffer; this isolates metadata
        // without copying the camera image.
        guard let displaySample = Self.displaySampleBuffer(copying: sampleBuffer) else {
            return
        }
        renderer.enqueue(displaySample)
    }

    static func displaySampleBuffer(
        copying sampleBuffer: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        ) == noErr,
        let copy else { return nil }
        markForImmediateDisplay(copy)
        return copy
    }

    private static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }
        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(rawDictionary, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

@MainActor
final class CameraPreviewWindowController {
    private let session: AVCaptureSession
    let frameSink = ImmediateCameraPreviewFrameSink()
    private var panel: CameraPreviewPanel?
    private var presentationGeneration = 0
    private var hasPositionedPanel = false
    private var mirrored = UserDefaults.standard.object(forKey: "recording.camera-mirrored") as? Bool ?? true
    func setMirrored(_ value: Bool) {
        mirrored = value
        (panel?.contentView as? CameraPreviewSurface)?.mirrored = value
        panel?.contentView?.needsLayout = true
    }
    private var sourceAspectRatio: CGFloat?
    private var sourcePixelSize: CGSize?
    private var shapeObserver: NSObjectProtocol?

    init(session: AVCaptureSession) {
        self.session = session
        shapeObserver = NotificationCenter.default.addObserver(
            forName: .recordingCameraPreviewShapeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPreferredShapeToPanel()
            }
        }
    }

    func showConnecting(deviceName: String) {
        presentationGeneration += 1
        let panel = preparedPanel()
        (panel.contentView as? CameraPreviewSurface)?.showConnecting(
            deviceName: deviceName
        )
        present(panel)
    }

    func showPreview() {
        presentationGeneration += 1
        let panel = preparedPanel()
        (panel.contentView as? CameraPreviewSurface)?.showPreview()
        present(panel)
    }

    func showDisconnected(deviceName: String) {
        presentationGeneration += 1
        let generation = presentationGeneration
        let panel = preparedPanel()
        (panel.contentView as? CameraPreviewSurface)?.showDisconnected(
            deviceName: deviceName
        )
        present(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.hide()
        }
    }

    func hide() {
        presentationGeneration += 1
        panel?.orderOut(nil)
    }

    func updateSourceSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        sourcePixelSize = CGSize(width: width, height: height)
        sourceAspectRatio = CGFloat(width) / CGFloat(height)
        (panel?.contentView as? CameraPreviewSurface)?.updateSourceSize(
            width: width,
            height: height
        )
        applyPreferredShapeToPanel()
    }

    /// Leaving the live-capture surface must release more than window
    /// visibility. AVSampleBufferDisplayLayer retains its renderer and last
    /// IOSurface even after the panel is ordered out, which keeps unnecessary
    /// CoreMedia/VideoToolbox state alive throughout an editor session.
    func releaseResources() {
        presentationGeneration += 1
        guard let panel else {
            frameSink.attach(nil)
            return
        }
        (panel.contentView as? CameraPreviewSurface)?.releaseResources()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        hasPositionedPanel = false
        frameSink.attach(nil)
    }

    private func preparedPanel() -> CameraPreviewPanel {
        let panel = panel ?? makePanel()
        self.panel = panel
        applyPreferredShape(to: panel)
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    private func present(_ panel: CameraPreviewPanel) {
        if !hasPositionedPanel {
            position(panel)
            hasPositionedPanel = true
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> CameraPreviewPanel {
        let size = CGSize(width: 240, height: 240)
        let panel = CameraPreviewPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.identifier = cameraPreviewWindowIdentifier
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.isMovableByWindowBackground = true
        let surface = CameraPreviewSurface(
            frame: CGRect(origin: .zero, size: size),
            session: session,
            frameSink: frameSink
        )
        surface.mirrored = mirrored
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        return panel
    }

    private func applyPreferredShapeToPanel() {
        guard let panel else { return }
        let previousCentre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        applyPreferredShape(to: panel)
        var frame = panel.frame
        frame.origin = CGPoint(
            x: previousCentre.x - frame.width / 2,
            y: previousCentre.y - frame.height / 2
        )
        panel.setFrame(frame, display: true)
    }

    private func applyPreferredShape(to panel: CameraPreviewPanel) {
        let shape = AppPreferences.recordingCameraPreviewShape
        let bubble: CGSize
        switch shape {
        case .circle, .roundedSquare:
            bubble = CGSize(width: 240, height: 240)
        case .sourceAspect:
            let longEdge: CGFloat = 288
            let aspect = max(sourceAspectRatio ?? 16 / 9, 0.01)
            bubble = aspect >= 1
                ? CGSize(width: longEdge, height: longEdge / aspect)
                : CGSize(width: longEdge * aspect, height: longEdge)
        }
        let margin = CameraPreviewSurface.margin
        let size = CGSize(width: bubble.width + margin * 2, height: bubble.height + margin * 2)
        if abs(panel.frame.width - size.width) > 0.5
            || abs(panel.frame.height - size.height) > 0.5 {
            panel.setContentSize(size)
        }
        if let surface = panel.contentView as? CameraPreviewSurface {
            // `setContentSize` does not guarantee that an existing custom
            // content view has completed its resize before this layout pass.
            // A stale rectangular surface is exactly what flattens the top and
            // bottom of a requested circle, so establish the aperture here.
            surface.frame = CGRect(origin: .zero, size: size)
            if let sourcePixelSize {
                surface.updateSourceSize(
                    width: Int(sourcePixelSize.width),
                    height: Int(sourcePixelSize.height)
                )
            }
            surface.apply(shape: shape)
            surface.layoutSubtreeIfNeeded()
        }
    }

    private func position(_ panel: NSPanel) {
        let recorderScreen = NSApplication.shared.windows.first(where: {
            $0.identifier == recorderMainWindowIdentifier
        })?.screen
        guard let visibleFrame = recorderScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        else { return }
        var frame = panel.frame
        frame.origin = CGPoint(
            x: visibleFrame.maxX - frame.width - 24,
            y: visibleFrame.midY - frame.height / 2
        )
        panel.setFrame(frame, display: false)
    }
}

private final class CameraPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CameraPreviewSurface: NSView {
    var mirrored = true
    private let session: AVCaptureSession
    private let frameSink: ImmediateCameraPreviewFrameSink
    private let previewLayer: AVSampleBufferDisplayLayer
    private let statusView = NSView()
    private let statusSpinner = NSProgressIndicator()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDeviceName = NSTextField(labelWithString: "")
    private var previewShape = AppPreferences.recordingCameraPreviewShape
    private var sourceSize: CGSize?
    private let apertureMaskLayer = CAShapeLayer()
    private let apertureBorderLayer = CAShapeLayer()
    /// The compositor draws video outside an arbitrary path mask, which left a
    /// circular bubble with four flat sides. A corner radius on the video's
    /// own container is honoured exactly.
    private let videoClipLayer = CALayer()
    /// Clear space the window keeps around the bubble on every side.
    static let margin: CGFloat = 12

    init(
        frame frameRect: NSRect,
        session: AVCaptureSession,
        frameSink: ImmediateCameraPreviewFrameSink
    ) {
        self.session = session
        self.frameSink = frameSink
        previewLayer = AVSampleBufferDisplayLayer()
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        // Opaque inside the aperture: wherever the picture does not reach, the
        // bubble is still a whole shape instead of a clipped one.
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = apertureMaskLayer
        apertureMaskLayer.fillColor = NSColor.black.cgColor
        apertureBorderLayer.fillColor = NSColor.clear.cgColor
        apertureBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        apertureBorderLayer.lineWidth = 1
        layer?.addSublayer(apertureBorderLayer)
        previewLayer.videoGravity = .resizeAspectFill
        frameSink.attach(previewLayer.sampleBufferRenderer)
        videoClipLayer.masksToBounds = true
        videoClipLayer.cornerCurve = .circular
        videoClipLayer.addSublayer(previewLayer)
        layer?.insertSublayer(videoClipLayer, below: apertureBorderLayer)

        statusView.wantsLayer = true
        statusView.layer?.backgroundColor = RecorderStyle.baseNSColor.withAlphaComponent(0.94).cgColor
        statusView.isHidden = true
        addSubview(statusView)

        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.appearance = nil
        statusView.addSubview(statusSpinner)

        statusTitle.alignment = .center
        statusTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        statusTitle.textColor = RecorderStyle.inkNSColor
        statusView.addSubview(statusTitle)

        statusDeviceName.alignment = .center
        statusDeviceName.font = .systemFont(ofSize: 11, weight: .medium)
        statusDeviceName.textColor = RecorderStyle.inkNSColor.withAlphaComponent(0.58)
        statusDeviceName.lineBreakMode = .byTruncatingMiddle
        statusView.addSubview(statusDeviceName)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            statusView.layer?.backgroundColor = RecorderStyle.baseNSColor.withAlphaComponent(0.94).cgColor
            CATransaction.commit()
        }
    }

    func releaseResources() {
        statusSpinner.stopAnimation(nil)
        previewLayer.stopRequestingMediaData()
        previewLayer.flushAndRemoveImage()
        previewLayer.removeFromSuperlayer()
        frameSink.attach(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    func showConnecting(deviceName: String) {
        previewLayer.flushAndRemoveImage()
        statusTitle.stringValue = "正在连接"
        statusDeviceName.stringValue = deviceName
        statusSpinner.isHidden = false
        statusSpinner.startAnimation(nil)
        statusView.isHidden = false
        needsLayout = true
    }

    func showDisconnected(deviceName: String) {
        statusTitle.stringValue = "设备已断开"
        statusDeviceName.stringValue = deviceName
        statusSpinner.stopAnimation(nil)
        statusSpinner.isHidden = true
        statusView.isHidden = false
        needsLayout = true
    }

    func showPreview() {
        statusSpinner.stopAnimation(nil)
        statusView.isHidden = true
        needsLayout = true
    }

    func apply(shape: RecordingCameraPreviewShape) {
        previewShape = shape
        needsLayout = true
    }

    func updateSourceSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        sourceSize = CGSize(width: width, height: height)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The window carries a clear margin around the bubble, so the shape
        // is never drawn against the window's own edge.
        let aperture = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let aperturePath = Self.aperturePath(
            shape: previewShape,
            bounds: aperture
        )
        // The picture overscans the aperture. A camera that delivers a frame
        // slightly short of its buffer otherwise leaves the circle with flat,
        // empty edges.
        let viewport = CGRect(origin: .zero, size: aperture.size)
        let overscan: CGFloat = 1.1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apertureMaskLayer.frame = bounds
        apertureMaskLayer.path = aperturePath
        apertureBorderLayer.frame = bounds
        apertureBorderLayer.path = Self.aperturePath(
            shape: previewShape,
            bounds: aperture.insetBy(dx: 0.5, dy: 0.5)
        )
        videoClipLayer.frame = aperture
        switch previewShape {
        case .circle: videoClipLayer.cornerRadius = min(aperture.width, aperture.height) / 2
        case .roundedSquare: videoClipLayer.cornerRadius = 42
        case .sourceAspect: videoClipLayer.cornerRadius = min(28, min(aperture.width, aperture.height) * 0.16)
        }
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.bounds = CGRect(origin: .zero, size: viewport.size)
        previewLayer.position = CGPoint(x: viewport.midX, y: viewport.midY)
        let sourceWidth = Int(sourceSize?.width ?? 0)
        let sourceHeight = Int(sourceSize?.height ?? 0)
        let fillScale = RecordingCameraPreviewScalePolicy.correctionScale(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        previewLayer.setAffineTransform(
            CGAffineTransform(scaleX: (mirrored ? -fillScale : fillScale) * overscan, y: fillScale * overscan)
        )
        CATransaction.commit()

        statusView.frame = aperture
        statusView.layer?.cornerRadius = 0
        let centerY = aperture.height / 2
        if statusSpinner.isHidden {
            statusTitle.frame = CGRect(
                x: 22,
                y: centerY - 4,
                width: aperture.width - 44,
                height: 22
            )
        } else {
            statusSpinner.frame = CGRect(
                x: aperture.width / 2 - 9,
                y: centerY + 24,
                width: 18,
                height: 18
            )
            statusTitle.frame = CGRect(
                x: 22,
                y: centerY - 8,
                width: aperture.width - 44,
                height: 22
            )
        }
        statusDeviceName.frame = CGRect(
            x: 30,
            y: centerY - 31,
            width: aperture.width - 60,
            height: 18
        )
    }

    private static func aperturePath(
        shape: RecordingCameraPreviewShape,
        bounds: CGRect
    ) -> CGPath {
        switch shape {
        case .circle:
            // An explicit ellipse path is immune to stale corner-radius and
            // backing-layer bounds, and produces a true round aperture when the
            // requested surface is square.
            return CGPath(ellipseIn: bounds, transform: nil)
        case .roundedSquare:
            return CGPath(
                roundedRect: bounds,
                cornerWidth: 42,
                cornerHeight: 42,
                transform: nil
            )
        case .sourceAspect:
            let radius = min(28, min(bounds.width, bounds.height) * 0.16)
            return CGPath(
                roundedRect: bounds,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        }
    }
}
