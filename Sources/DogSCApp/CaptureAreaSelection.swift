import AppKit
import CoreText
import RecorderCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CaptureAreaSelector {
    private var selectionWindow: NSWindow?
    private var recordingOverlayWindow: NSWindow?
    private var activeToken: CaptureSelectionToken?
    private var completion: ((CaptureSelectionToken, CaptureAreaSelectionOutcome) -> Void)?
    private var escapeKeyMonitor: Any?
    private var activeDisplay: CaptureDisplayIdentity?
    /// Set by the presenter; forwarded to the selection view so a settled
    /// drag publishes the area immediately.
    var onSelectionChanged: ((NormalizedRect) -> Void)?

    func start(
        on displayID: UInt32?,
        token: CaptureSelectionToken,
        completion: @escaping (CaptureSelectionToken, CaptureAreaSelectionOutcome) -> Void,
        onSelectionChanged: ((NormalizedRect) -> Void)? = nil
    ) {
        cancel()
        guard let screen = AppKitCaptureDisplayResolver.resolveScreen(requestedID: displayID),
              let resolvedDisplay = AppKitCaptureDisplayResolver.identity(for: screen) else {
            completion(token, .displayUnavailable(requestedID: displayID))
            return
        }

        activeToken = token
        self.completion = completion
        activeDisplay = resolvedDisplay

        let view = CaptureAreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] selection in
            self?.complete(with: selection, token: token)
        }
        view.onSelectionChanged = onSelectionChanged ?? self.onSelectionChanged

        let window = CaptureAreaSelectionWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        let isDesignReview = CommandLine.arguments.contains("--design-review")
            || Bundle.main.bundleIdentifier?.hasSuffix(".design-review") == true
        window.level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = isDesignReview ? .readOnly : .none
        self.escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.complete(with: nil, token: token)
            return nil
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        selectionWindow = window
    }

    func cancel() {
        guard let activeToken else { return }
        complete(with: nil, token: activeToken)
    }

    /// Closes the selection window without emitting a completion callback.
    /// Used when recording starts from the selector's own 开始录制 button:
    /// the recording overlay takes over the visible selection, and the
    /// cancelled callback must not clear the just-confirmed area.
    func dismissWithoutCompleting() {
        guard activeToken != nil else { return }
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        activeToken = nil
        completion = nil
        activeDisplay = nil
    }

    func showRecordingOverlay(selection: NormalizedRect, on displayID: UInt32?) {
        hideRecordingOverlay()
        guard let screen = AppKitCaptureDisplayResolver.resolveScreen(requestedID: displayID) else { return }

        let view = CaptureAreaRecordingOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            selection: selection.constrained()
        )
        let window = CaptureAreaRecordingOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.level = CaptureWindowLevelPolicy.level(for: .recordingGuideOverlay)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none
        window.orderFrontRegardless()
        recordingOverlayWindow = window
    }

    func hideRecordingOverlay() {
        recordingOverlayWindow?.orderOut(nil)
        recordingOverlayWindow = nil
    }

    private func complete(
        with selection: NormalizedRect?,
        token: CaptureSelectionToken
    ) {
        guard activeToken == token else { return }
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        let completion = completion
        let display = activeDisplay
        self.completion = nil
        activeDisplay = nil
        activeToken = nil
        if let selection, let display {
            let result = CaptureAreaSelectionResult(
                display: display,
                rect: selection.constrained()
            )
            completion?(token, .selected(result))
        } else {
            completion?(token, .cancelled)
        }
    }
}

private final class CaptureAreaSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class CaptureAreaRecordingOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaptureAreaRecordingOverlayView: NSView {
    private let selection: NormalizedRect

    init(frame frameRect: NSRect, selection: NormalizedRect) {
        self.selection = selection
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let selectedRect = CGRect(
            x: bounds.width * selection.x,
            y: bounds.height * (1 - selection.y - selection.height),
            width: bounds.width * selection.width,
            height: bounds.height * selection.height
        ).integral

        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.fill(bounds)
        context.clear(selectedRect)

        let borderRect = selectedRect.insetBy(dx: 1.5, dy: 1.5)
        context.setStrokeColor(captureSelectionAccentNSColor.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(3)
        context.stroke(borderRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [7, 7])
        context.stroke(borderRect)
    }
}

private final class CaptureAreaSelectionView: NSView {
    var onComplete: ((NormalizedRect?) -> Void)?
    /// Fired as soon as a valid drag selection settles (mouse up). Lets the
    /// setup controller publish the area immediately so the recorder bar's
    /// start button is already live before the explicit 开始录制 confirm —
    /// selecting a region should not require a separate confirmation step.
    var onSelectionChanged: ((NormalizedRect) -> Void)?

    private enum AspectPreset: Int, CaseIterable {
        case free
        case landscape16x9
        case landscape4x3
        case square
        case portrait9x16

        var title: String {
            switch self {
            case .free: "自由"
            case .landscape16x9: "16:9"
            case .landscape4x3: "4:3"
            case .square: "1:1"
            case .portrait9x16: "9:16"
            }
        }

        var symbolName: String {
            switch self {
            case .free: "viewfinder"
            case .landscape16x9: "rectangle"
            case .landscape4x3: "rectangle.inset.filled"
            case .square: "square"
            case .portrait9x16: "rectangle.portrait"
            }
        }

        var ratio: CGFloat? {
            switch self {
            case .free: nil
            case .landscape16x9: 16 / 9
            case .landscape4x3: 4 / 3
            case .square: 1
            case .portrait9x16: 9 / 16
            }
        }
    }

    private enum ResizeHandle: CaseIterable {
        case bottomLeft
        case bottom
        case bottomRight
        case left
        case right
        case topLeft
        case top
        case topRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .bottom: CGPoint(x: rect.midX, y: rect.minY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .top: CGPoint(x: rect.midX, y: rect.maxY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        var isCorner: Bool {
            switch self {
            case .bottomLeft, .bottomRight, .topLeft, .topRight: true
            case .bottom, .left, .right, .top: false
            }
        }
    }

    private enum DragOperation {
        case create(anchor: CGPoint)
        case move(offset: CGPoint)
        case resize(handle: ResizeHandle, original: CGRect)
    }

    private let controlCard = NSVisualEffectView()
    private let escapeHintCard = NSVisualEffectView()
    private let escapeHintContent = EscapeHintContentView()
    private let dividerView = NSView()
    private let widthCaption = NSTextField(labelWithString: "宽")
    private let heightCaption = NSTextField(labelWithString: "高")
    private let widthField = VerticallyCenteredTextField()
    private let heightField = VerticallyCenteredTextField()
    private let dimensionReadout = CenteredDrawingLabel("— × —")
    private lazy var dimensionLinkButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(
            systemSymbolName: "link",
            accessibilityDescription: "锁定宽高比例"
        )
        button.target = self
        button.action = #selector(toggleDimensionLink(_:))
        button.isBordered = false
        button.focusRingType = .none
        return button
    }()
    private lazy var applySizeButton = AreaActionButton(
        title: "应用尺寸",
        shortcut: nil,
        primary: false,
        target: self,
        action: #selector(applyManualSize(_:))
    )
    private lazy var cancelButton = AreaActionButton(
        title: "取消",
        shortcut: "Esc",
        primary: false,
        target: self,
        action: #selector(cancelSelection(_:))
    )
    private lazy var confirmButton = AreaActionButton(
        title: "开始录制",
        shortcut: "Return",
        primary: true,
        target: self,
        action: #selector(confirmSelection(_:))
    )
    private lazy var presetButtons: [AreaPresetButton] = AspectPreset.allCases.map { preset in
        let button = AreaPresetButton(title: preset.title, symbolName: preset.symbolName)
        button.tag = preset.rawValue
        button.target = self
        button.action = #selector(changeAspectPreset(_:))
        return button
    }

    private var selectedPreset: AspectPreset = .free
    private var dimensionLinkEnabled = false
    private var dragOperation: DragOperation?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureControls()
    }

    private func configureControls() {
        wantsLayer = true

        [controlCard, escapeHintCard].forEach { card in
            card.appearance = NSAppearance(named: .darkAqua)
            card.material = .hudWindow
            card.blendingMode = .withinWindow
            card.state = .active
            card.wantsLayer = true
            card.layer?.cornerRadius = 18
            card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
            card.layer?.shadowColor = NSColor.black.cgColor
            card.layer?.shadowOpacity = 0.34
            card.layer?.shadowRadius = 18
            card.layer?.shadowOffset = CGSize(width: 0, height: -6)
            addSubview(card)
        }

        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        controlCard.addSubview(dividerView)

        presetButtons.forEach(controlCard.addSubview)
        updatePresetButtons()

        [widthCaption, heightCaption].forEach { caption in
            caption.font = .systemFont(ofSize: 11.5, weight: .medium)
            caption.textColor = NSColor.white.withAlphaComponent(0.58)
            caption.alignment = .center
            caption.drawsBackground = false
            caption.backgroundColor = .clear
            controlCard.addSubview(caption)
        }

        [widthField, heightField].forEach { field in
            field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            field.alignment = .center
            field.textColor = .white
            field.backgroundColor = .clear
            field.isBezeled = false
            field.drawsBackground = false
            field.wantsLayer = true
            field.layer?.cornerRadius = 8
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            field.focusRingType = .none
            field.target = self
            field.action = #selector(applyManualSize(_:))
            controlCard.addSubview(field)
        }
        widthField.placeholderString = "宽度"
        heightField.placeholderString = "高度"

        dimensionReadout.font = .monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold)
        dimensionReadout.textColor = captureSelectionAccentNSColor.blended(
            withFraction: 0.28,
            of: .white
        ) ?? captureSelectionAccentNSColor
        dimensionReadout.wantsLayer = true
        dimensionReadout.layer?.cornerRadius = 9
        dimensionReadout.layer?.borderWidth = 1
        dimensionReadout.layer?.borderColor = captureSelectionAccentNSColor
            .withAlphaComponent(0.36).cgColor
        dimensionReadout.layer?.backgroundColor = NSColor.clear.cgColor
        controlCard.addSubview(dimensionReadout)

        dimensionLinkButton.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        dimensionLinkButton.imagePosition = .imageOnly
        dimensionLinkButton.imageScaling = .scaleProportionallyDown
        controlCard.addSubview(dimensionLinkButton)

        confirmButton.keyEquivalent = "\r"
        confirmButton.isEnabled = false
        [applySizeButton, cancelButton, confirmButton].forEach(controlCard.addSubview)

        configureEscapeHint()
    }

    private func configureEscapeHint() {
        escapeHintCard.addSubview(escapeHintContent)
    }

    override func layout() {
        super.layout()
        let scale = interfaceScale
        layoutControlCard(scale: scale)
        layoutEscapeHint(scale: scale)
    }

    /// One full-featured toolbar in two positions. Without a selection it
    /// sits at the top of the screen; once a region is drawn it moves right
    /// under the selection — keeping every control (ratio presets, exact
    /// width/height, apply, readout, cancel, 开始录制) so the aspect ratio can
    /// still be changed after drawing.
    private func layoutControlCard(scale: CGFloat) {
        let cardHeight: CGFloat = 100 * scale
        let hasSelection = selectionRect != nil
        escapeHintCard.isHidden = hasSelection

        let cardWidth = 1160 * scale
        if hasSelection {
            // Follow the selection: centered under it, flipped above when the
            // selection sits too low on the screen.
            guard let selectionRect else {
                controlCard.isHidden = true
                return
            }
            controlCard.isHidden = false
            let below = selectionRect.minY - cardHeight - 24 * scale
            let above = selectionRect.maxY + 24 * scale
            let y: CGFloat
            if below >= bounds.minY + 12 * scale {
                y = below
            } else if above + cardHeight <= bounds.maxY - 12 * scale {
                y = above
            } else {
                y = max(
                    bounds.minY + 12 * scale,
                    min(below, bounds.maxY - cardHeight - 12 * scale)
                )
            }
            let x = min(
                max(selectionRect.midX - cardWidth / 2, bounds.minX + 12 * scale),
                bounds.maxX - cardWidth - 12 * scale
            )
            controlCard.frame = CGRect(
                x: x,
                y: y,
                width: cardWidth,
                height: cardHeight
            )
        } else {
            controlCard.isHidden = false
            controlCard.frame = CGRect(
                x: bounds.midX - cardWidth / 2,
                y: bounds.maxY - cardHeight - 56 * scale,
                width: cardWidth,
                height: cardHeight
            )
        }

        var x: CGFloat = 18 * scale
        for button in presetButtons {
            button.frame = CGRect(
                x: x,
                y: 12 * scale,
                width: 60 * scale,
                height: 76 * scale
            )
            button.updateScale(scale)
            x += 68 * scale
        }
        dividerView.frame = CGRect(
            x: x + 4 * scale,
            y: 18 * scale,
            width: max(scale, 1),
            height: 64 * scale
        )

        let dimensionStart = x + 28 * scale
        widthCaption.frame = CGRect(
            x: dimensionStart,
            y: 70 * scale,
            width: 82 * scale,
            height: 16 * scale
        )
        widthField.frame = CGRect(
            x: dimensionStart,
            y: 25 * scale,
            width: 82 * scale,
            height: 38 * scale
        )
        dimensionLinkButton.frame = CGRect(
            x: dimensionStart + 88 * scale,
            y: 29 * scale,
            width: 32 * scale,
            height: 32 * scale
        )
        heightCaption.frame = CGRect(
            x: dimensionStart + 126 * scale,
            y: 70 * scale,
            width: 82 * scale,
            height: 16 * scale
        )
        heightField.frame = CGRect(
            x: dimensionStart + 126 * scale,
            y: 25 * scale,
            width: 82 * scale,
            height: 38 * scale
        )
        applySizeButton.frame = CGRect(
            x: dimensionStart + 226 * scale,
            y: 24 * scale,
            width: 106 * scale,
            height: 42 * scale
        )
        dimensionReadout.frame = CGRect(
            x: dimensionStart + 348 * scale,
            y: 28 * scale,
            width: 136 * scale,
            height: 34 * scale
        )

        confirmButton.frame = CGRect(
            x: cardWidth - 116 * scale,
            y: 14 * scale,
            width: 98 * scale,
            height: 72 * scale
        )
        cancelButton.frame = CGRect(
            x: cardWidth - 216 * scale,
            y: 14 * scale,
            width: 86 * scale,
            height: 72 * scale
        )

        controlCard.layer?.cornerRadius = 18 * scale
        widthCaption.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        heightCaption.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        widthField.font = .monospacedDigitSystemFont(ofSize: 14 * scale, weight: .medium)
        heightField.font = .monospacedDigitSystemFont(ofSize: 14 * scale, weight: .medium)
        widthField.layer?.cornerRadius = 8 * scale
        heightField.layer?.cornerRadius = 8 * scale
        dimensionReadout.font = .monospacedDigitSystemFont(ofSize: 13.5 * scale, weight: .semibold)
        dimensionReadout.layer?.cornerRadius = 9 * scale
        [applySizeButton, cancelButton, confirmButton].forEach {
            $0.updateScale(scale)
        }
    }

    private func layoutEscapeHint(scale: CGFloat) {
        let escapeHintWidth = escapeHintContent.preferredWidth(for: scale)
        escapeHintCard.frame = CGRect(
            x: bounds.midX - escapeHintWidth / 2,
            y: 42 * scale,
            width: escapeHintWidth,
            height: 52 * scale
        )
        escapeHintCard.layer?.cornerRadius = 13 * scale
        escapeHintContent.frame = escapeHintCard.bounds
        escapeHintContent.interfaceScale = scale
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !controlCard.frame.contains(point),
              !escapeHintCard.frame.contains(point) else { return }

        window?.makeFirstResponder(self)

        if let selectionRect,
           let handle = resizeHandle(near: point, rect: selectionRect) {
            dragOperation = .resize(handle: handle, original: selectionRect)
        } else if let selectionRect, selectionRect.contains(point) {
            dragOperation = .move(offset: CGPoint(
                x: point.x - selectionRect.minX,
                y: point.y - selectionRect.minY
            ))
        } else {
            selectionRect = nil
            dragOperation = .create(anchor: point)
            updateSelectionUI()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOperation else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 拖动/调整选区期间隐藏上下文工具条，避免它跟随选区跳动遮挡视线。
        controlCard.isHidden = true
        switch dragOperation {
        case .create(let anchor):
            selectionRect = selectionRect(
                from: anchor,
                to: point,
                constrainedAspect: selectedAspectRatio
            )
        case .move(let offset):
            guard let selectionRect else { return }
            let origin = CGPoint(
                x: min(max(point.x - offset.x, bounds.minX), bounds.maxX - selectionRect.width),
                y: min(max(point.y - offset.y, bounds.minY), bounds.maxY - selectionRect.height)
            )
            self.selectionRect = CGRect(origin: origin, size: selectionRect.size)
        case .resize(let handle, let original):
            selectionRect = resizedRect(original, handle: handle, to: point)
        }
        updateSelectionUI()
    }

    override func mouseUp(with event: NSEvent) {
        dragOperation = nil
        guard let rect = selectionRect, rect.width >= 24, rect.height >= 24 else {
            selectionRect = nil
            updateSelectionUI()
            NSSound.beep()
            return
        }
        // 松开：重新显示上下文工具条并贴到新选区下方。
        controlCard.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateSelectionUI()
        guard bounds.width > 0, bounds.height > 0 else { return }
        onSelectionChanged?(NormalizedRect(
            x: rect.minX / bounds.width,
            y: 1 - rect.maxY / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        ))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onComplete?(nil)
        } else if event.keyCode == 36 {
            confirmSelection(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func changeAspectPreset(_ sender: AreaPresetButton) {
        guard let preset = AspectPreset(rawValue: sender.tag) else { return }
        selectedPreset = preset
        dimensionLinkEnabled = preset.ratio != nil
        updatePresetButtons()
        updateDimensionLink()
        if let aspect = preset.ratio {
            // 已有选区时保持其中心只改比例，避免整个选区跳走；
            // 还没有选区时按可用区域中心生成一个。
            selectionRect = selectionRect.map { existing in
                aspectRect(aspect, preservingCenter: existing)
            } ?? centeredSelectionRect(aspect: aspect)
            updateSelectionUI()
        }
    }

    /// Rebuilds the selection at the requested aspect ratio while keeping the
    /// current selection's center fixed (area preserved, then clamped to the
    /// screen bounds). Clamping uses the full bounds — not the "usable" area,
    /// which depends on the toolbar position that itself follows the selection.
    private func aspectRect(_ aspect: CGFloat, preservingCenter selection: CGRect) -> CGRect {
        let center = CGPoint(x: selection.midX, y: selection.midY)
        var width = sqrt(selection.width * selection.height * aspect)
        var height = width / aspect
        let maxWidth = bounds.width - 16
        let maxHeight = bounds.height - 16
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGRect(
            x: min(max(center.x - width / 2, bounds.minX + 8), bounds.maxX - width - 8),
            y: min(max(center.y - height / 2, bounds.minY + 8), bounds.maxY - height - 8),
            width: width,
            height: height
        ).integral
    }

    @objc private func toggleDimensionLink(_ sender: Any?) {
        dimensionLinkEnabled.toggle()
        updateDimensionLink()
    }

    @objc private func applyManualSize(_ sender: Any?) {
        guard let typedWidth = Int(widthField.stringValue),
              let typedHeight = Int(heightField.stringValue),
              typedWidth >= 64,
              typedHeight >= 64 else {
            NSSound.beep()
            return
        }

        var pixelWidth = typedWidth
        var pixelHeight = typedHeight
        if dimensionLinkEnabled, let aspect = selectedAspectRatio {
            pixelHeight = max(Int((CGFloat(pixelWidth) / aspect).rounded()), 64)
            heightField.stringValue = String(pixelHeight)
        } else {
            selectedPreset = .free
            updatePresetButtons()
        }

        pixelWidth = max(pixelWidth / 2 * 2, 64)
        pixelHeight = max(pixelHeight / 2 * 2, 64)
        let scale = max(window?.backingScaleFactor ?? 1, 1)
        let size = CGSize(
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )
        guard size.width <= bounds.width, size.height <= bounds.height else {
            NSSound.beep()
            return
        }

        let preferredCenter = selectionRect.map {
            CGPoint(x: $0.midX, y: $0.midY)
        } ?? usableSelectionBounds.center
        let origin = CGPoint(
            x: min(max(preferredCenter.x - size.width / 2, bounds.minX), bounds.maxX - size.width),
            y: min(max(preferredCenter.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        )
        selectionRect = CGRect(origin: origin, size: size)
        updateSelectionUI(updateFields: false)
    }

    @objc private func confirmSelection(_ sender: Any?) {
        guard let rect = selectionRect,
              rect.width >= 24,
              rect.height >= 24,
              bounds.width > 0,
              bounds.height > 0 else {
            NSSound.beep()
            return
        }
        onComplete?(NormalizedRect(
            x: rect.minX / bounds.width,
            y: 1 - rect.maxY / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        ))
    }

    @objc private func cancelSelection(_ sender: Any?) {
        onComplete?(nil)
    }

    private var selectedAspectRatio: CGFloat? { selectedPreset.ratio }

    private var usableSelectionBounds: CGRect {
        let bottom = escapeHintCard.frame.maxY + 28
        let top = max(controlCard.frame.minY - 30, bottom + 120)
        return CGRect(
            x: bounds.minX + 54,
            y: bottom,
            width: max(bounds.width - 108, 120),
            height: max(top - bottom, 120)
        )
    }

    private func centeredSelectionRect(aspect: CGFloat) -> CGRect {
        let usable = usableSelectionBounds
        var width = usable.width * 0.72
        var height = width / aspect
        if height > usable.height * 0.78 {
            height = usable.height * 0.78
            width = height * aspect
        }
        return CGRect(
            x: usable.midX - width / 2,
            y: usable.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    private func selectionRect(
        from anchor: CGPoint,
        to point: CGPoint,
        constrainedAspect: CGFloat?
    ) -> CGRect {
        let horizontalDirection: CGFloat = point.x >= anchor.x ? 1 : -1
        let verticalDirection: CGFloat = point.y >= anchor.y ? 1 : -1
        let maximumWidth = horizontalDirection > 0
            ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let maximumHeight = verticalDirection > 0
            ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        var width = min(abs(point.x - anchor.x), maximumWidth)
        var height = min(abs(point.y - anchor.y), maximumHeight)

        if let aspect = constrainedAspect, width > 0, height > 0 {
            if width / height > aspect {
                height = width / aspect
            } else {
                width = height * aspect
            }
            if width > maximumWidth {
                width = maximumWidth
                height = width / aspect
            }
            if height > maximumHeight {
                height = maximumHeight
                width = height * aspect
            }
        }

        return CGRect(
            x: horizontalDirection > 0 ? anchor.x : anchor.x - width,
            y: verticalDirection > 0 ? anchor.y : anchor.y - height,
            width: width,
            height: height
        ).integral
    }

    private func resizeHandle(near point: CGPoint, rect: CGRect) -> ResizeHandle? {
        let radius: CGFloat = 16 * interfaceScale
        return ResizeHandle.allCases.first(where: { handle in
            let location = handle.point(in: rect)
            return hypot(point.x - location.x, point.y - location.y) <= radius
        })
    }

    private func resizedRect(
        _ original: CGRect,
        handle: ResizeHandle,
        to point: CGPoint
    ) -> CGRect {
        if handle.isCorner {
            let anchor: CGPoint
            switch handle {
            case .bottomLeft: anchor = CGPoint(x: original.maxX, y: original.maxY)
            case .bottomRight: anchor = CGPoint(x: original.minX, y: original.maxY)
            case .topLeft: anchor = CGPoint(x: original.maxX, y: original.minY)
            case .topRight: anchor = CGPoint(x: original.minX, y: original.minY)
            default: return original
            }
            // 角手柄的比例约束跟随当前预设：预设模式保持比例（拖角等比），
            // “自由”模式自由缩放（不受原选区比例限制）。
            return selectionRect(
                from: anchor,
                to: point,
                constrainedAspect: selectedPreset.ratio
            )
        }

        var result = original
        switch handle {
        case .left:
            let newMinX = min(max(point.x, bounds.minX), original.maxX - 24)
            result.origin.x = newMinX
            result.size.width = original.maxX - newMinX
        case .right:
            result.size.width = min(max(point.x - original.minX, 24), bounds.maxX - original.minX)
        case .bottom:
            let newMinY = min(max(point.y, bounds.minY), original.maxY - 24)
            result.origin.y = newMinY
            result.size.height = original.maxY - newMinY
        case .top:
            result.size.height = min(max(point.y - original.minY, 24), bounds.maxY - original.minY)
        default:
            break
        }
        return result.integral
    }

    private func updatePresetButtons() {
        presetButtons.forEach { button in
            button.setSelected(button.tag == selectedPreset.rawValue)
        }
    }

    private func updateDimensionLink() {
        dimensionLinkButton.contentTintColor = dimensionLinkEnabled
            ? captureSelectionAccentNSColor.blended(withFraction: 0.2, of: .white)
            : NSColor.white.withAlphaComponent(0.38)
        dimensionLinkButton.toolTip = dimensionLinkEnabled ? "宽高比例已锁定" : "宽高比例未锁定"
    }

    private func updateSelectionUI(updateFields: Bool = true) {
        if updateFields {
            if let selectionRect {
                let scale = max(window?.backingScaleFactor ?? 1, 1)
                widthField.stringValue = String(Int((selectionRect.width * scale).rounded()))
                heightField.stringValue = String(Int((selectionRect.height * scale).rounded()))
            } else {
                widthField.stringValue = ""
                heightField.stringValue = ""
            }
        }

        let sizeText: String
        if let selectionRect {
            let scale = max(window?.backingScaleFactor ?? 1, 1)
            sizeText = "\(Int((selectionRect.width * scale).rounded())) × "
                + "\(Int((selectionRect.height * scale).rounded()))"
        } else {
            sizeText = "— × —"
        }
        dimensionReadout.stringValue = sizeText

        confirmButton.isEnabled = selectionRect.map {
            $0.width >= 24 && $0.height >= 24
        } ?? false
        confirmButton.alphaValue = confirmButton.isEnabled ? 1 : 0.46
        let hasSelection = selectionRect != nil
        if hasSelection != lastHadSelection {
            // 选区存在性切换：顶部完整工具栏 ⇄ 选区下方紧凑工具条。
            lastHadSelection = hasSelection
            needsLayout = true
        }
        needsDisplay = true
    }

    private var lastHadSelection = false

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.57).cgColor)
        context.fill(bounds)

        guard let selectionRect else { return }
        context.clear(selectionRect)

        let scale = interfaceScale
        let borderRect = selectionRect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale)
        context.saveGState()
        context.setStrokeColor(captureSelectionAccentNSColor.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(4 * scale)
        context.stroke(borderRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.94).cgColor)
        context.setLineWidth(2 * scale)
        context.setLineDash(phase: 0, lengths: [7 * scale, 7 * scale])
        context.stroke(borderRect)
        context.restoreGState()

        for handle in ResizeHandle.allCases {
            let point = handle.point(in: selectionRect)
            context.setFillColor(captureSelectionAccentNSColor.withAlphaComponent(0.98).cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - 8 * scale,
                y: point.y - 8 * scale,
                width: 16 * scale,
                height: 16 * scale
            ))
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - 5 * scale,
                y: point.y - 5 * scale,
                width: 10 * scale,
                height: 10 * scale
            ))
        }

        let backingScale = max(window?.backingScaleFactor ?? 1, 1)
        let sizeText = "\(Int((selectionRect.width * backingScale).rounded())) × "
            + "\(Int((selectionRect.height * backingScale).rounded()))"
        let string = NSAttributedString(
            string: sizeText,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5 * scale, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        let textSize = string.size()
        let badge = CGRect(
            x: selectionRect.midX - textSize.width / 2 - 14 * scale,
            y: selectionRect.midY - 16 * scale,
            width: textSize.width + 28 * scale,
            height: 32 * scale
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 9 * scale, yRadius: 9 * scale).fill()
        string.draw(at: CGPoint(
            x: badge.midX - textSize.width / 2,
            y: badge.midY - textSize.height / 2
        ))
    }

    private var interfaceScale: CGFloat {
        min(0.78, max(0.52, (bounds.width - 40) / 1160))
    }
}
