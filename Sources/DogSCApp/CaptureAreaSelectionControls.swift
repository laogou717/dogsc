import AppKit
import CoreText

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
        layer?.backgroundColor = selectedState
            ? NSColor(calibratedRed: 0.86, green: 0.96, blue: 0.91, alpha: 1).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = selectedState ? 0.75 * layoutScale : 0
        layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
    }

    override func captureInteractionDidChange(hovering: Bool, pressed: Bool) {
        updateAppearance()
    }

    func updateScale(_ scale: CGFloat) {
        layoutScale = scale
        captureKeyboardFocusLineWidth = 1.5 * scale
        captionLabel.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        symbolView.image = NSImage(
            systemSymbolName: areaSymbolName,
            accessibilityDescription: captionLabel.stringValue
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: 21 * scale,
            weight: .regular
        ))
        layer?.cornerRadius = 14 * scale
        updateAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else {
            symbolView.frame = .zero
            captionLabel.frame = .zero
            return
        }
        let scale = layoutScale
        let iconSize = 22 * scale
        symbolView.frame = CGRect(
            x: bounds.midX - iconSize / 2,
            y: bounds.height - 33 * scale,
            width: iconSize,
            height: iconSize
        )
        captionLabel.frame = CGRect(
            x: 2 * scale,
            y: 5 * scale,
            width: bounds.width - 4 * scale,
            height: 17 * scale
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
        layer?.borderColor = primary
            ? NSColor.white.withAlphaComponent(0.18).cgColor
            : captureSelectionInkNSColor.withAlphaComponent(0.18).cgColor
        captureKeyboardFocusColor = primary ? NSColor.white.withAlphaComponent(0.65) : NSColor.black.withAlphaComponent(0.40)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = plain ? 0 : 0.06
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
        buttonTitleLabel.font = .systemFont(ofSize: (plain ? 12.5 : 14) * scale, weight: .semibold)
        layer?.cornerRadius = 10 * scale
        layer?.borderWidth = plain ? 0 : 0.75 * scale
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
                ? NSColor(calibratedWhite: pressed ? 0.20 : hovering ? 0.22 : 0.24, alpha: 1).cgColor
                : NSColor(calibratedWhite: pressed ? 0.92 : hovering ? 0.97 : 0.995, alpha: 1).cgColor
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
            ? captureSelectionAccentNSColor
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

    func preferredWidth(for scale: CGFloat) -> CGFloat {
        let title = makeLine(
            "拖动选择录制区域",
            font: .systemFont(ofSize: 16 * scale, weight: .medium),
            color: .white
        )
        return ceil(max(280 * scale, lineMetrics(title).width + 48 * scale))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = interfaceScale
        let titleFont = NSFont.systemFont(ofSize: 16 * scale, weight: .medium)
        let bodyFont = NSFont.systemFont(ofSize: 11.5 * scale, weight: .medium)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11.5 * scale, weight: .semibold)
        let bodyColor = NSColor.white.withAlphaComponent(0.72)
        let keyColor = NSColor.white.withAlphaComponent(0.86)

        let title = makeLine("拖动选择录制区域", font: titleFont, color: .white)
        let key = makeLine("Esc", font: keyFont, color: keyColor)
        let suffix = makeLine("取消", font: bodyFont, color: bodyColor)
        let suffixWidth = lineMetrics(suffix).width
        let keyWidth = 34 * scale
        let keyHeight = 22 * scale
        let spacing = 8 * scale
        let totalWidth = keyWidth + spacing + suffixWidth
        var x = floor((bounds.width - totalWidth) / 2)

        drawLine(title, centeredIn: CGRect(
            x: 12 * scale,
            y: 46 * scale,
            width: bounds.width - 24 * scale,
            height: 24 * scale
        ), context: context)

        let keyRect = CGRect(
            x: x,
            y: 18 * scale,
            width: keyWidth,
            height: keyHeight
        )
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(
            roundedRect: keyRect,
            xRadius: 5 * scale,
            yRadius: 5 * scale
        ).fill()
        drawLine(key, centeredIn: keyRect, context: context)
        x += keyWidth + spacing

        drawLine(suffix, centeredIn: CGRect(
            x: x,
            y: keyRect.minY,
            width: suffixWidth,
            height: keyHeight
        ), context: context)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
