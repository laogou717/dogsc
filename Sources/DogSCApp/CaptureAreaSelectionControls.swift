import AppKit
import CoreText
import QuartzCore

/// One selection pill travels between ratios, just like the recorder's
/// continuous surface. The native buttons keep their own hover and focus.
final class AreaPresetSelectionView: NSView {
    private let selectionLayer = CALayer()
    private var targetFrame: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectionLayer.backgroundColor = RecorderStyle.selectionNSColor.cgColor
        selectionLayer.cornerCurve = .continuous
        layer?.addSublayer(selectionLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionLayer.backgroundColor = RecorderStyle.selectionNSColor.cgColor
            CATransaction.commit()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func move(to frame: CGRect, animated: Bool) {
        guard targetFrame != frame else { return }
        let previous = selectionLayer.presentation()?.frame ?? targetFrame
        targetFrame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = frame
        selectionLayer.cornerRadius = frame.height / 2
        selectionLayer.removeAllAnimations()
        CATransaction.commit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let previous else { return }
        let motion = CABasicAnimation(keyPath: "position")
        motion.fromValue = NSValue(point: NSPoint(x: previous.midX, y: previous.midY))
        motion.toValue = NSValue(point: NSPoint(x: frame.midX, y: frame.midY))
        motion.duration = 0.26
        motion.timingFunction = CAMediaTimingFunction(name: .easeOut)
        selectionLayer.add(motion, forKey: "area-preset-selection")
    }
}

final class AreaPresetButton: CaptureSelectionNativeButton {
    private let areaSymbolName: String
    private let symbolView = MousePassthroughImageView()
    private let captionLabel = MousePassthroughLabel("")
    private var layoutScale: CGFloat = 1
    private var selectedState = false

    init(title: String, symbolName: String) {
        areaSymbolName = symbolName
        super.init(frame: .zero)
        super.title = ""
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 14
        setAccessibilityLabel(title)

        symbolView.imageAlignment = .alignCenter
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        addSubview(symbolView)

        captionLabel.stringValue = title
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byClipping
        captionLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        addSubview(captionLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        selectedState = selected
        setAccessibilityValue(selected ? "已选择" : "未选择")
        updateAppearance()
    }

    private func updateAppearance() {
        let tint = captureSelectionInkNSColor.withAlphaComponent(selectedState ? 1 : 0.65)
        symbolView.contentTintColor = tint
        captionLabel.textColor = tint
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
    }

    override func captureInteractionDidChange(hovering: Bool, pressed: Bool) {
        updateAppearance()
    }

    func updateScale(_ scale: CGFloat) {
        layoutScale = scale
        captureKeyboardFocusLineWidth = 1.5 * scale
        // A ratio is its own name; the pill needs no pictogram beside it.
        captionLabel.font = .systemFont(ofSize: 12 * scale, weight: .semibold)
        symbolView.image = nil
        symbolView.isHidden = true
        layer?.cornerCurve = .continuous
        updateAppearance()
        needsLayout = true
    }

    override func layout() {
        layer?.cornerRadius = bounds.height / 2
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else {
            symbolView.frame = .zero
            captionLabel.frame = .zero
            return
        }
        let scale = layoutScale
        layer?.cornerRadius = bounds.height / 2
        symbolView.frame = .zero
        let lineHeight = 16 * scale
        captionLabel.frame = CGRect(
            x: 2 * scale,
            y: (bounds.height - lineHeight) / 2,
            width: bounds.width - 4 * scale,
            height: lineHeight
        )
    }

}

final class AreaActionButton: CaptureSelectionNativeButton {
    private let buttonTitleLabel = MousePassthroughLabel("")
    private let primary: Bool
    private let plain: Bool
    private var layoutScale: CGFloat = 1

    init(
        title: String,
        primary: Bool,
        plain: Bool = false,
        target: AnyObject?,
        action: Selector?
    ) {
        self.primary = primary
        self.plain = plain
        super.init(frame: .zero)
        super.title = ""
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = plain ? 0 : 0.75
        layer?.borderColor = NSColor.clear.cgColor
        captureKeyboardFocusColor = RecorderStyle.chromeNSColor.withAlphaComponent(0.65)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        setAccessibilityLabel(title)

        buttonTitleLabel.stringValue = title
        buttonTitleLabel.alignment = .center
        buttonTitleLabel.textColor = primary
            ? NSColor.white
            : captureSelectionInkNSColor
        addSubview(buttonTitleLabel)
        updateAppearance(hovering: false, pressed: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateScale(_ scale: CGFloat) {
        layoutScale = scale
        captureKeyboardFocusLineWidth = 1.5 * scale
        buttonTitleLabel.font = .systemFont(ofSize: (plain ? 12 : 13) * scale, weight: .semibold)
        layer?.cornerRadius = 22 * scale
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0
        layer?.shadowRadius = 2 * scale
        layer?.shadowOffset = CGSize(width: 0, height: -scale)
        needsLayout = true
    }

    override func captureInteractionDidChange(hovering: Bool, pressed: Bool) {
        updateAppearance(hovering: hovering, pressed: pressed)
    }

    private func updateAppearance(hovering: Bool, pressed: Bool) {
        if plain {
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            layer?.backgroundColor = primary
                ? captureSelectionPlatinumNSColor.withAlphaComponent(pressed ? 0.78 : hovering ? 0.92 : 1).cgColor
                : RecorderStyle.chromeNSColor.withAlphaComponent(pressed ? 0.14 : hovering ? 0.09 : 0).cgColor
        }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else {
            buttonTitleLabel.frame = .zero
            return
        }
        let scale = layoutScale
        // Allocate the full safe label width, and use the native cell's
        // height. Glyph measurements do not include NSTextField padding.
        let cellSize = buttonTitleLabel.cell?.cellSize ?? buttonTitleLabel.intrinsicContentSize
        let labelHeight = min(max(0, bounds.height - 8 * scale), ceil(cellSize.height))
        let preferredInset: CGFloat = (plain ? 4 : 8) * scale
        let fittingInset = max(0, (bounds.width - ceil(cellSize.width)) / 2)
        let horizontalInset = min(preferredInset, fittingInset)
        buttonTitleLabel.frame = CGRect(
            x: horizontalInset,
            y: floor(bounds.midY - labelHeight / 2),
            width: max(0, bounds.width - horizontalInset * 2),
            height: labelHeight
        )
    }

}

/// The dimension lock remains an unobtrusive link icon while retaining the
/// same native press feedback as the toolbar's other buttons.
final class AreaDimensionLinkButton: CaptureSelectionNativeButton {
    private var linked = false

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("锁定宽高比例")
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLinked(_ linked: Bool) {
        self.linked = linked
        setAccessibilityValue(linked ? "已锁定" : "未锁定")
        updateAppearance()
    }

    func updateScale(_ scale: CGFloat) {
        captureKeyboardFocusLineWidth = 1.5 * scale
        image = NSImage(systemSymbolName: "link", accessibilityDescription: "锁定宽高比例")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16 * scale, weight: .medium))
        layer?.cornerRadius = 8 * scale
    }

    override func captureInteractionDidChange(hovering: Bool, pressed: Bool) {
        updateAppearance()
    }

    private func updateAppearance() {
        contentTintColor = linked
            ? captureSelectionInkNSColor
            : captureSelectionInkNSColor.withAlphaComponent(0.55)
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class MousePassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MousePassthroughLabel: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        configureLabel()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLabel()
    }

    private func configureLabel() {
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        maximumNumberOfLines = 1
        lineBreakMode = .byClipping
        cell?.wraps = false
        cell?.isScrollable = false
        cell?.usesSingleLineMode = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class EscapeHintContentView: NSView {
    var interfaceScale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("拖动选择录制区域，按 Esc 取消")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("拖动选择录制区域，按 Esc 取消")
    }

    private func lines(for scale: CGFloat) -> (title: CTLine, key: CTLine) {
        (makeLine("拖动选择录制区域", font: .systemFont(ofSize: 13 * scale, weight: .semibold), color: captureSelectionInkNSColor),
         makeLine("esc", font: .systemFont(ofSize: 11 * scale, weight: .semibold),
                  color: captureSelectionInkNSColor.withAlphaComponent(0.56)))
    }

    func preferredWidth(for scale: CGFloat) -> CGFloat {
        let content = lines(for: scale)
        return ceil(lineMetrics(content.title).width + lineMetrics(content.key).width + (12 + 44) * scale)
    }

    /// One line on a pill: what to do, and the key that backs out.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = interfaceScale
        let content = lines(for: scale)
        let titleWidth = lineMetrics(content.title).width
        let keyWidth = lineMetrics(content.key).width
        let gap = 12 * scale
        let x = floor((bounds.width - (titleWidth + gap + keyWidth)) / 2)
        drawLine(content.title, centeredIn: CGRect(x: x, y: 0, width: titleWidth, height: bounds.height), context: context)
        drawLine(content.key, centeredIn: CGRect(x: x + titleWidth + gap, y: 0, width: keyWidth, height: bounds.height),
                 context: context)
    }

    private func makeLine(_ string: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        ))
    }

    private func lineMetrics(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            &leading
        ))
        return (width, ascent, descent)
    }

    private func drawLine(_ line: CTLine, centeredIn rect: CGRect, context: CGContext) {
        let metrics = lineMetrics(line)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: floor(rect.midX - metrics.width / 2),
            y: floor(rect.midY - (metrics.ascent + metrics.descent) / 2 + metrics.descent)
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        guard let font else { return drawingRect }

        let lineHeight = ceil(font.boundingRectForFont.height)
        let availableHeight = drawingRect.height
        guard availableHeight > lineHeight else { return drawingRect }

        drawingRect.origin.y += floor((availableHeight - lineHeight) / 2) - 1.5
        drawingRect.size.height = lineHeight + 1
        return drawingRect
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

final class VerticallyCenteredTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = VerticallyCenteredTextFieldCell(textCell: "")
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = VerticallyCenteredTextFieldCell(textCell: "")
        configureInteraction()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    private func configureInteraction() {
        isEditable = true
        isSelectable = true
        isEnabled = true
        refusesFirstResponder = false
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
