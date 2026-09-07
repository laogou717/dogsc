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
        layer?.cornerRadius = 10
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
        updateAppearance()
    }

    private func updateAppearance() {
        let tint = captureSelectionInkNSColor.withAlphaComponent(selectedState ? 1 : 0.65)
        symbolView.contentTintColor = tint
        captionLabel.textColor = tint
        layer?.backgroundColor = selectedState ? NSColor(calibratedRed: 0.86, green: 0.96, blue: 0.91, alpha: 1).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selectedState ? 0.75 : 0
        layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = selectedState ? 0.12 : 0
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    override func captureInteractionDidChange(hovering: Bool, pressed: Bool) {
        updateAppearance()
    }

    func updateScale(_ scale: CGFloat) {
        layoutScale = scale
        captionLabel.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        symbolView.image = NSImage(
            systemSymbolName: areaSymbolName,
            accessibilityDescription: captionLabel.stringValue
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: 21 * scale,
            weight: .regular
        ))
        layer?.cornerRadius = 10 * scale
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let scale = layoutScale
        let iconSize = 22 * scale
        symbolView.frame = CGRect(
            x: bounds.midX - iconSize / 2,
            y: bounds.height - 30 * scale,
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
    private let shortcutLabel = MousePassthroughLabel("")
    private let buttonShortcut: String?
    private let primary: Bool
    private var layoutScale: CGFloat = 1

    init(
        title: String,
        shortcut: String?,
        primary: Bool,
        target: AnyObject?,
        action: Selector?
    ) {
        buttonShortcut = shortcut
        self.primary = primary
        super.init(frame: .zero)
        super.title = ""
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = primary
            ? captureSelectionPlatinumNSColor.cgColor
            : captureSelectionRaisedNSColor.cgColor
        layer?.borderWidth = primary ? 0 : 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        setAccessibilityLabel(title)

        buttonTitleLabel.stringValue = title
        buttonTitleLabel.alignment = .center
        buttonTitleLabel.textColor = primary
            ? NSColor.white
            : captureSelectionInkNSColor
        addSubview(buttonTitleLabel)

        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.alignment = .center
        shortcutLabel.textColor = primary
            ? NSColor.white.withAlphaComponent(0.65)
            : captureSelectionInkNSColor.withAlphaComponent(0.6)
        shortcutLabel.isHidden = shortcut == nil
        addSubview(shortcutLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateScale(_ scale: CGFloat) {
        layoutScale = scale
        buttonTitleLabel.font = .systemFont(ofSize: 12 * scale, weight: .medium)
        shortcutLabel.font = .systemFont(ofSize: 10.5 * scale, weight: .medium)
        layer?.cornerRadius = 10 * scale
        needsLayout = true
    }

    override func captureInteractionDidChange(hovering: Bool, pressed: Bool) {
        layer?.backgroundColor = primary
            ? captureSelectionPlatinumNSColor.withAlphaComponent(
                pressed ? 0.84 : hovering ? 0.92 : 1
            ).cgColor
            : NSColor(calibratedWhite: pressed ? 0.92 : hovering ? 0.97 : 0.995, alpha: 1).cgColor
    }

    override func layout() {
        super.layout()
        let scale = layoutScale
        if buttonShortcut == nil {
            buttonTitleLabel.frame = CGRect(
                x: 4 * scale,
                y: bounds.midY - 10 * scale,
                width: bounds.width - 8 * scale,
                height: 20 * scale
            )
            shortcutLabel.frame = .zero
        } else {
            buttonTitleLabel.frame = CGRect(
                x: 4 * scale,
                y: bounds.midY - 1 * scale,
                width: bounds.width - 8 * scale,
                height: 20 * scale
            )
            shortcutLabel.frame = CGRect(
                x: 4 * scale,
                y: bounds.midY - 18 * scale,
                width: bounds.width - 8 * scale,
                height: 16 * scale
            )
        }
    }

}

final class MousePassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MousePassthroughLabel: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
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
        setAccessibilityLabel("拖拽绘制录制区域，按 Esc 取消选择")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("拖拽绘制录制区域，按 Esc 取消选择")
    }

    func preferredWidth(for scale: CGFloat) -> CGFloat {
        let bodyFont = NSFont.systemFont(ofSize: 12.5 * scale, weight: .medium)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11.5 * scale, weight: .semibold)
        let prefix = makeLine("拖拽绘制录制区域 · 按", font: bodyFont, color: .white)
        let suffix = makeLine("取消选择", font: bodyFont, color: .white)
        let key = makeLine("Esc", font: keyFont, color: .white)
        let contentWidth = lineMetrics(prefix).width
            + 8 * scale
            + max(46 * scale, lineMetrics(key).width + 18 * scale)
            + 8 * scale
            + lineMetrics(suffix).width
        return ceil(contentWidth + 28 * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = interfaceScale
        let bodyFont = NSFont.systemFont(ofSize: 12.5 * scale, weight: .medium)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11.5 * scale, weight: .semibold)
        let bodyColor = captureSelectionInkNSColor.withAlphaComponent(0.78)
        let keyColor = captureSelectionInkNSColor.withAlphaComponent(0.86)

        let prefix = makeLine("拖拽绘制录制区域 · 按", font: bodyFont, color: bodyColor)
        let key = makeLine("Esc", font: keyFont, color: keyColor)
        let suffix = makeLine("取消选择", font: bodyFont, color: bodyColor)
        let prefixWidth = lineMetrics(prefix).width
        let suffixWidth = lineMetrics(suffix).width
        let keyWidth = 46 * scale
        let keyHeight = 28 * scale
        let spacing = 8 * scale
        let totalWidth = prefixWidth + spacing + keyWidth + spacing + suffixWidth
        var x = floor((bounds.width - totalWidth) / 2)

        drawLine(prefix, centeredIn: CGRect(
            x: x,
            y: 0,
            width: prefixWidth,
            height: bounds.height
        ), context: context)
        x += prefixWidth + spacing

        let keyRect = CGRect(
            x: x,
            y: floor((bounds.height - keyHeight) / 2),
            width: keyWidth,
            height: keyHeight
        )
        NSColor.black.withAlphaComponent(0.055).setFill()
        NSBezierPath(
            roundedRect: keyRect,
            xRadius: 6 * scale,
            yRadius: 6 * scale
        ).fill()
        drawLine(key, centeredIn: keyRect, context: context)
        x += keyWidth + spacing

        drawLine(suffix, centeredIn: CGRect(
            x: x,
            y: 0,
            width: suffixWidth,
            height: bounds.height
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
