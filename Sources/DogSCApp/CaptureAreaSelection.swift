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
    private let transition = CaptureSelectionTransition()
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
        hideRecordingOverlay()
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
        // Screen-relative NSWindow initialization can offset secondary displays.
        // Anchor both the window and its drawing canvas in the resolved screen.
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.level = CaptureWindowLevelPolicy.level(for: .selectionOverlay)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .readOnly
        self.escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.complete(with: nil, token: token)
            return nil
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        selectionWindow = window
        transition.present(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func cancel(preservingRetiringPanels: Bool = false) {
        if let activeToken { complete(with: nil, token: activeToken, animated: false) }
        if !preservingRetiringPanels { transition.finishImmediately() }
    }

    /// Keeps a valid selection's existing mask as the recording guide, without
    /// emitting a cancellation callback or waiting for the controls to fade.
    func dismissWithoutCompleting() {
        if !adoptSelectionForRecording() { closeSelection(animated: false) }
        transition.finishImmediately()
    }

    private func takeSelectionWindow() -> NSWindow? {
        activeToken = nil
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
        let retiringWindow = selectionWindow
        selectionWindow = nil
        completion = nil
        activeDisplay = nil
        return retiringWindow
    }

    private func closeSelection(animated: Bool) {
        guard let retiringWindow = takeSelectionWindow() else { return }
        (retiringWindow.contentView as? CaptureAreaSelectionView)?.prepareForRetirement()
        (retiringWindow as? CaptureAreaSelectionWindow)?.retiring = true
        transition.retire([retiringWindow], animated: animated)
    }

    private func adoptSelectionForRecording() -> Bool {
        guard let window = selectionWindow,
              let view = window.contentView as? CaptureAreaSelectionView,
              view.hasValidSelection else { return false }
        _ = takeSelectionWindow()
        (window as? CaptureAreaSelectionWindow)?.retiring = true
        window.ignoresMouseEvents = true
        window.makeFirstResponder(nil)
        window.resignKey()
        window.resignMain()
        transition.settlePresentation([window])
        window.level = CaptureWindowLevelPolicy.level(for: .recordingGuideOverlay)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none
        _ = view.beginRecordingHighlight()
        hideRecordingOverlay()
        recordingOverlayWindow = window
        return true
    }

    func showRecordingOverlay(selection: NormalizedRect, on displayID: UInt32?) {
        guard let screen = AppKitCaptureDisplayResolver.resolveScreen(requestedID: displayID) else {
            hideRecordingOverlay()
            return
        }
        if let window = recordingOverlayWindow,
           window.frame == screen.frame,
           let view = window.contentView as? CaptureAreaSelectionView,
           view.beginRecordingHighlight(selection: selection.constrained()) {
            window.orderFrontRegardless()
            return
        }
        hideRecordingOverlay()

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
        // Screen-relative NSWindow initialization can offset secondary displays.
        // Anchor both the window and its drawing canvas in the resolved screen.
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false
        view.autoresizingMask = [.width, .height]
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
        (recordingOverlayWindow?.contentView as? CaptureAreaSelectionView)?.prepareForRetirement()
        recordingOverlayWindow?.orderOut(nil)
        recordingOverlayWindow?.close()
        recordingOverlayWindow = nil
    }

    private func complete(
        with selection: NormalizedRect?,
        token: CaptureSelectionToken,
        animated: Bool = true
    ) {
        guard activeToken == token else { return }
        let completion = completion
        let display = activeDisplay
        if selection != nil, display != nil {
            if !adoptSelectionForRecording() { closeSelection(animated: false) }
        } else {
            closeSelection(animated: animated)
        }
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
    var retiring = false
    override var canBecomeKey: Bool { !retiring }
    override var canBecomeMain: Bool { !retiring }
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
    /// Publishes a valid region as soon as the drag settles, while the
    /// selection's own toolbar remains responsible for starting capture.
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

    private let controlCard = NSView()
    private let escapeHintCard = NSView()
    private let escapeHintContent = EscapeHintContentView()
    private let controlDividers = (0..<3).map { _ in NSView() }
    private let widthCaption = NSTextField(labelWithString: "宽")
    private let heightCaption = NSTextField(labelWithString: "高")
    private let widthField = VerticallyCenteredTextField()
    private let heightField = VerticallyCenteredTextField()
    private lazy var dimensionLinkButton = AreaDimensionLinkButton(
        target: self,
        action: #selector(toggleDimensionLink(_:))
    )
    private lazy var applySizeButton = AreaActionButton(
        title: "应用尺寸",
        primary: false,
        plain: true,
        target: self,
        action: #selector(applyManualSize(_:))
    )
    private lazy var cancelButton = AreaActionButton(
        title: "取消",
        primary: false,
        target: self,
        action: #selector(cancelSelection(_:))
    )
    private lazy var confirmButton = AreaActionButton(
        title: "开始录制",
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

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
        if !controlCard.isHidden {
            addCursorRect(controlCard.frame, cursor: .arrow)
        }
    }

    private var selectedPreset: AspectPreset = .free
    private var dimensionLinkEnabled = false
    private var dragOperation: DragOperation?
    private var selectionRect: CGRect?
    private var acceptsSelectionInput = true
    private var recordingHighlight = false
    private let controlCardTransition = CaptureSelectionCardTransition()

    var hasValidSelection: Bool {
        selectionRect.map { $0.width >= 24 && $0.height >= 24 } ?? false
    }

    private var isCreatingSelection: Bool {
        guard let dragOperation else { return false }
        if case .create = dragOperation { return true }
        return false
    }

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
            card.appearance = NSAppearance(named: .aqua)
            card.wantsLayer = true
            card.layer?.cornerRadius = 18
            card.layer?.backgroundColor = captureSelectionSurfaceNSColor.cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = captureSelectionInkNSColor.withAlphaComponent(0.08).cgColor
            card.layer?.shadowColor = NSColor.black.cgColor
            card.layer?.shadowOpacity = 0.12
            card.layer?.shadowRadius = 18
            card.layer?.shadowOffset = CGSize(width: 0, height: -6)
            addSubview(card)
        }
        escapeHintCard.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.64).cgColor
        escapeHintCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // The first screen is only the dimmed desktop and its central hint.
        // The toolbar becomes available after the user draws a valid region.
        controlCard.isHidden = true
        controlCard.alphaValue = 0
        controlDividers.forEach { divider in
            divider.wantsLayer = true
            divider.layer?.backgroundColor = captureSelectionInkNSColor.withAlphaComponent(0.08).cgColor
            controlCard.addSubview(divider)
        }

        presetButtons.forEach(controlCard.addSubview)
        updatePresetButtons()

        [widthCaption, heightCaption].forEach { caption in
            caption.font = .systemFont(ofSize: 11.5, weight: .medium)
            caption.textColor = captureSelectionInkNSColor.withAlphaComponent(0.65)
            caption.alignment = .center
            caption.drawsBackground = false
            caption.backgroundColor = .clear
            controlCard.addSubview(caption)
        }

        [widthField, heightField].forEach { field in
            field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            field.alignment = .center
            field.textColor = captureSelectionInkNSColor
            field.backgroundColor = NSColor(calibratedWhite: 0.945, alpha: 1)
            field.isBezeled = false
            field.drawsBackground = true
            field.wantsLayer = true
            field.layer?.cornerRadius = 8
            field.layer?.borderWidth = 1
            field.layer?.borderColor = captureSelectionInkNSColor.withAlphaComponent(0.08).cgColor
            field.focusRingType = .none
            field.target = self
            field.action = #selector(applyManualSize(_:))
            controlCard.addSubview(field)
        }
        widthField.placeholderString = "宽度"
        heightField.placeholderString = "高度"
        widthField.setAccessibilityLabel("录制区域宽度（像素）")
        heightField.setAccessibilityLabel("录制区域高度（像素）")

        controlCard.addSubview(dimensionLinkButton)
        updateDimensionLink()

        confirmButton.keyEquivalent = "\r"
        confirmButton.isEnabled = false
        cancelButton.setAccessibilityHelp("按 Esc 取消区域选择")
        confirmButton.setAccessibilityHelp("按 Return 开始录制")
        [applySizeButton, cancelButton, confirmButton].forEach(controlCard.addSubview)

        configureEscapeHint()
    }

    private func configureEscapeHint() {
        escapeHintCard.addSubview(escapeHintContent)
    }

    func prepareForRetirement() {
        acceptsSelectionInput = false
        onComplete = nil
        onSelectionChanged = nil
        dragOperation = nil
        controlCardTransition.stop()
        presetButtons.forEach { $0.isEnabled = false }
        [applySizeButton, cancelButton, confirmButton, dimensionLinkButton].forEach {
            $0.isEnabled = false
        }
        widthField.isEditable = false
        heightField.isEditable = false
    }

    func beginRecordingHighlight(selection: NormalizedRect? = nil) -> Bool {
        if let selection {
            selectionRect = CGRect(
                x: bounds.width * selection.x,
                y: bounds.height * (1 - selection.y - selection.height),
                width: bounds.width * selection.width,
                height: bounds.height * selection.height
            ).integral
        }
        guard let selectionRect, selectionRect.width >= 24, selectionRect.height >= 24 else {
            return false
        }
        if !recordingHighlight {
            prepareForRetirement()
            recordingHighlight = true
            escapeHintCard.isHidden = true
            if !controlCard.isHidden {
                controlCardTransition.show(controlCard, at: controlCard.frame)
                controlCardTransition.hide(controlCard)
            }
        }
        needsDisplay = true
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsSelectionInput else { return nil }
        let visibleFrame = controlCardTransition.visibleFrame(of: controlCard)
        if !controlCard.isHidden, visibleFrame.contains(point) {
            return controlCard.hitTest(CGPoint(
                x: point.x - visibleFrame.minX + controlCard.frame.minX,
                y: point.y - visibleFrame.minY + controlCard.frame.minY
            )) ?? self
        }
        // The initial hint is informational; drawing can begin through it.
        return self
    }

    override func layout() {
        super.layout()
        guard !recordingHighlight else { return }
        layoutControlCard(scale: controlCardScale)
        layoutEscapeHint(scale: interfaceScale)
    }

    /// The toolbar exists only for a valid, settled region. Its geometry is
    /// anchored directly to that region; showing it never animates a journey
    /// from an unrelated position on the screen.
    private func layoutControlCard(scale: CGFloat) {
        guard hasValidSelection, !isCreatingSelection, let selectionRect else {
            controlCardTransition.hide(controlCard, animated: false)
            controlCard.isHidden = true
            return
        }

        let cardHeight: CGFloat = 76 * scale
        let cardWidth: CGFloat = 830 * scale
        let edgeInset: CGFloat = 12 * scale
        let gap: CGFloat = 16 * scale
        let below = selectionRect.minY - cardHeight - gap
        let above = selectionRect.maxY + gap
        let y: CGFloat
        if below >= bounds.minY + edgeInset {
            y = below
        } else if above + cardHeight <= bounds.maxY - edgeInset {
            y = above
        } else {
            y = min(
                max(below, bounds.minY + edgeInset),
                bounds.maxY - cardHeight - edgeInset
            )
        }
        let x = min(
            max(selectionRect.midX - cardWidth / 2, bounds.minX + edgeInset),
            bounds.maxX - cardWidth - edgeInset
        )
        let target = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)

        // The approved reference keeps all groups on one row. Presets retain
        // the icon-over-caption shape; only Cancel and Start share the large
        // action surface, with a single centered Chinese title.
        let presetOrigins: [CGFloat] = [16, 78, 132, 186, 240]
        for (button, origin) in zip(presetButtons, presetOrigins) {
            button.frame = CGRect(
                x: origin * scale,
                y: 8 * scale,
                width: 54 * scale,
                height: 60 * scale
            )
            button.updateScale(scale)
        }
        for (divider, origin) in zip(controlDividers, [CGFloat(302), 506, 598]) {
            divider.frame = CGRect(x: origin * scale, y: 14 * scale, width: 1 * scale, height: 48 * scale)
        }
        widthCaption.frame = CGRect(x: 318 * scale, y: 49 * scale, width: 66 * scale, height: 15 * scale)
        widthField.frame = CGRect(x: 318 * scale, y: 13 * scale, width: 66 * scale, height: 32 * scale)
        dimensionLinkButton.frame = CGRect(x: 393 * scale, y: 13 * scale, width: 26 * scale, height: 32 * scale)
        heightCaption.frame = CGRect(x: 425 * scale, y: 49 * scale, width: 66 * scale, height: 15 * scale)
        heightField.frame = CGRect(x: 425 * scale, y: 13 * scale, width: 66 * scale, height: 32 * scale)
        applySizeButton.frame = CGRect(x: 518 * scale, y: 13 * scale, width: 68 * scale, height: 50 * scale)
        cancelButton.frame = CGRect(x: 616 * scale, y: 13 * scale, width: 72 * scale, height: 50 * scale)
        confirmButton.frame = CGRect(x: 696 * scale, y: 13 * scale, width: 120 * scale, height: 50 * scale)

        controlCard.layer?.cornerRadius = 18 * scale
        controlCard.layer?.borderWidth = scale
        controlCard.layer?.shadowRadius = 18 * scale
        controlCard.layer?.shadowOffset = CGSize(width: 0, height: -6 * scale)
        widthCaption.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        heightCaption.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        widthField.font = .monospacedDigitSystemFont(ofSize: 14 * scale, weight: .semibold)
        heightField.font = .monospacedDigitSystemFont(ofSize: 14 * scale, weight: .semibold)
        widthField.layer?.cornerRadius = 8 * scale
        heightField.layer?.cornerRadius = 8 * scale
        widthField.layer?.borderWidth = scale
        heightField.layer?.borderWidth = scale
        [applySizeButton, cancelButton, confirmButton].forEach {
            $0.updateScale(scale)
        }
        dimensionLinkButton.updateScale(scale)
        controlCardTransition.show(controlCard, at: target)
        window?.invalidateCursorRects(for: self)
    }

    private func layoutEscapeHint(scale: CGFloat) {
        escapeHintCard.isHidden = selectionRect != nil || dragOperation != nil
        let escapeHintWidth = escapeHintContent.preferredWidth(for: scale)
        let hintHeight: CGFloat = 88 * scale
        escapeHintCard.frame = CGRect(
            x: bounds.midX - escapeHintWidth / 2,
            y: bounds.midY - hintHeight / 2,
            width: escapeHintWidth,
            height: hintHeight
        )
        escapeHintCard.layer?.cornerRadius = 16 * scale
        escapeHintContent.frame = escapeHintCard.bounds
        escapeHintContent.interfaceScale = scale
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsSelectionInput else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard controlCard.isHidden || !controlCardTransition.visibleFrame(of: controlCard).contains(point) else { return }

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
        }
        updateSelectionUI()
        layoutSubtreeIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsSelectionInput, let dragOperation else { return }
        let point = convert(event.locationInWindow, from: nil)
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
        layoutSubtreeIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsSelectionInput else { return }
        dragOperation = nil
        guard let rect = selectionRect, rect.width >= 24, rect.height >= 24 else {
            selectionRect = nil
            updateSelectionUI()
            layoutSubtreeIfNeeded()
            NSSound.beep()
            return
        }
        updateSelectionUI()
        layoutSubtreeIfNeeded()
        guard bounds.width > 0, bounds.height > 0 else { return }
        onSelectionChanged?(NormalizedRect(
            x: rect.minX / bounds.width,
            y: 1 - rect.maxY / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        ))
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsSelectionInput else { return }
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
        bounds.insetBy(dx: 24 * interfaceScale, dy: 24 * interfaceScale)
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
        dimensionLinkButton.setLinked(dimensionLinkEnabled)
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

        confirmButton.isEnabled = selectionRect.map {
            $0.width >= 24 && $0.height >= 24
        } ?? false
        confirmButton.alphaValue = confirmButton.isEnabled ? 1 : 0.46
        // Visibility is derived in one place. A new drag keeps the controls
        // hidden; moving/resizing a settled region updates their anchor now.
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if recordingHighlight {
            drawRecordingHighlight(in: context)
            return
        }
        context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        context.fill(bounds)

        guard let selectionRect else { return }
        context.clear(selectionRect)

        let scale = interfaceScale
        let borderRect = selectionRect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale)
        context.saveGState()
        context.setStrokeColor(captureSelectionAccentNSColor.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(3 * scale)
        context.stroke(borderRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.44).cgColor)
        context.setLineWidth(max(scale, 1))
        context.stroke(borderRect.insetBy(dx: 2 * scale, dy: 2 * scale))
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

    private func drawRecordingHighlight(in context: CGContext) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.fill(bounds)
        guard let selectionRect else { return }
        context.clear(selectionRect)
        let borderRect = selectionRect.insetBy(dx: 1.5, dy: 1.5)
        context.setStrokeColor(captureSelectionAccentNSColor.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(3)
        context.stroke(borderRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [7, 7])
        context.stroke(borderRect)
    }

    // Compact only the toolbar; region geometry and drag handles retain their
    // existing screen scale, independent of the toolbar's visual size.
    private var controlCardScale: CGFloat {
        min(0.85, interfaceScale)
    }

    private var interfaceScale: CGFloat {
        min(1, max(0.1, min((bounds.width - 24) / 830, (bounds.height - 24) / 76)))
    }
}
