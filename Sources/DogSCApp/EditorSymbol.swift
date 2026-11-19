import AppKit
import SwiftUI

/// The editor draws its own line glyphs (AppLineIcon, the 20-unit grid of
/// the EDT-078 icon set) instead of mixing in system symbols. Call sites keep the familiar
/// symbol names; a name without a drawn glyph still renders the system one.
enum EditorSymbolCatalog {
    static func kind(for systemName: String) -> AppLineIcon.Kind? {
        switch systemName {
        case "arrow.uturn.backward", "arrow.uturn.left": .undo
        case "arrow.uturn.forward", "arrow.uturn.right": .redo
        case "gearshape", "gearshape.fill": .settings
        case "plus", "plus.circle", "plus.circle.fill": .plus
        case "minus", "minus.circle": .minus
        case "slider.horizontal.3": .sliders
        case "moon.stars.fill", "moon.fill", "moon": .moon
        case "sun.max.fill", "sun.max": .sun
        case "trash", "trash.fill": .trash
        case "folder": .folder
        case "square.3.layers.3d", "square.stack.3d.up", "square.stack", "rectangle.stack": .layers
        case "rectangle.inset.filled", "square.on.square", "rectangle.on.rectangle": .layout
        case "macwindow": .window
        case "photo", "photo.on.rectangle.angled": .scene
        case "grid": .grid
        case "waveform", "waveform.path", "waveform.path.ecg", "waveform.path.ecg.rectangle": .waveform
        case "film", "film.stack", "film.stack.fill", "timeline.selection": .film
        case "crop": .crop
        case "scissors": .scissors
        case "viewfinder": .zoom
        case "scope": .target
        case "sparkles.rectangle.stack": .opening
        case "sparkles", "sparkle": .sparkle
        case "speaker.wave.2", "speaker.wave.2.fill": .speaker
        case "speaker.slash", "speaker.slash.fill": .speakerOff
        case "mic", "mic.fill": .microphone
        case "video", "video.fill", "video.badge.ellipsis": .camera
        case "video.slash", "video.slash.fill": .cameraOff
        case "display": .display
        case "pencil": .pencil
        case "magnet": .magnet
        case "eye", "eye.fill": .eye
        case "eye.slash", "eye.slash.fill": .eyeOff
        case "clock", "clock.badge.checkmark": .clock
        case "cube", "cube.transparent", "move.3d": .cube
        case "link": .link
        case "photo.badge.plus": .photoAdd
        case "doc.on.clipboard": .paste
        case "arrow.up.left.and.arrow.down.right": .expand
        case "aspectratio": .aspect
        case "hand.draw": .move
        case "arrow.triangle.2.circlepath", "arrow.clockwise", "arrow.counterclockwise", "rotate.right": .refresh
        case "mappin.and.ellipse": .pin
        case "speedometer": .speed
        case "drop.halffull": .drop
        case "circle.lefthalf.filled": .halfCircle
        case "bookmark", "bookmark.fill": .bookmark
        case "arrow.left.and.right": .swap
        case "magnifyingglass", "plus.magnifyingglass": .search
        case "slash.circle": .noSymbol
        case "chevron.left": .chevronLeft
        case "chevron.up": .chevronUp
        case "chevron.right": .chevron
        case "chevron.down": .chevronDown
        case "xmark": .close
        case "checkmark": .check
        case "checkmark.circle", "checkmark.circle.fill": .checkCircle
        case "exclamationmark.triangle", "exclamationmark.triangle.fill": .warning
        case "info", "info.circle": .info
        case "play.fill", "play": .play
        case "rectangle.slash": .noFrame
        case "rectangle": .shapeWide
        case "rectangle.portrait": .portrait
        case "arrow.left": .arrowLeft
        case "arrow.right": .arrowRight
        case "square.and.arrow.down": .download
        case "cursorarrow.motionlines": .cursorMotion
        case "cursorarrow": .cursor
        case "person", "person.fill": .person
        case "link.badge.plus": .link
        case "arrow.up.left": .arrowUpLeft
        case "arrow.down.right": .arrowDownRight
        case "delete.left": .deleteLeft
        case "delete.right": .deleteRight
        case "list.number", "list.bullet": .list
        case "rectangle.3.group": .presets
        case "circle": .shapeCircle
        case "rectangle.fill": .shapeWide
        case "square", "square.fill": .shapeRounded
        case "arrow.up.forward.app": .external
        case "circle.dotted": .shapeCircle
        case "clock.arrow.circlepath": .clock
        case "dock.rectangle", "menubar.dock.rectangle": .display
        case "exclamationmark.circle": .info
        case "folder.fill": .folder
        case "lock.shield": .shield
        case "mic.slash", "mic.slash.fill": .microphone
        case "music.note": .waveform
        case "photo.on.rectangle", "photo.stack": .image
        case "play.rectangle", "play.rectangle.fill": .opening
        case "square.grid.2x2", "square.grid.2x2.fill": .presets
        case "text.alignleft": .list
        case "textformat.size.larger", "textformat.size.smaller": .text
        case "tray.full", "tray": .box
        case "power": .close
        case "record.circle", "record.circle.fill": .record
        case "square.2.layers.3d.bottom.filled", "square.3.layers.3d.bottom.filled",
             "square.2.layers.3d.top.filled": .layers
        case "ellipsis", "ellipsis.circle": .ellipsis
        case "sidebar.left", "sidebar.right": .sidebar
        case "star": .star
        case "star.fill": .starFilled
        case "square.and.arrow.up": .export
        case "wand.and.stars", "wand.and.rays": .wand
        case "xmark.circle", "xmark.circle.fill": .clear
        case "sparkles.tv": .opening
        case "textformat", "character.cursor.ibeam", "text.cursor": .text
        case "captions.bubble", "captions.bubble.fill": .subtitle
        case "note.text": .note
        case "eyedropper", "eyedropper.halffull": .eyedropper
        case "camera.metering.spot": .spotlight
        case "keyboard": .keyboard
        case "stop.fill", "stop": .stop
        case "pause.fill", "pause": .pause
        case "film.fill": .film
        case "photo.fill": .image
        case "square.on.square.dashed", "plus.square.on.square": .duplicate
        case "ipad", "ipad.landscape", "iphone": .portrait
        case "arrow.up.square", "square.3.layers.3d.top.filled": .layers
        // Layer order keeps the system glyphs: their front/back distinction
        // has no drawn equivalent yet.
        default: nil
        }
    }
}

/// A drawn glyph for a symbol name. Without a drawn version the system
/// symbol is used, honouring the surrounding font exactly as before.
struct EditorSymbol: View {
    let systemName: String
    var size: CGFloat

    /// The editor's glyph sizes: 10 (tags), 12 (inline, badges), 14 (rows,
    /// buttons), 16 (toolbars, tiles), 18 (large tiles), 20 (empty states).
    static let scale: [CGFloat] = [10, 12, 14, 16, 18, 20, 24, 28]

    init(_ systemName: String, size: CGFloat = 14) {
        self.systemName = systemName
        self.size = Self.scale.min { abs($0 - size) < abs($1 - size) } ?? size
    }

    var body: some View {
        if let kind = EditorSymbolCatalog.kind(for: systemName) {
            AppLineIcon(kind: kind, size: size)
        } else {
            Image(systemName: systemName)
        }
    }
}

/// `Label` with a drawn glyph; label styles (icon only, title only) still
/// apply because this is a real Label.
struct EditorSymbolLabel: View {
    private let title: Text
    private let systemImage: String
    private let size: CGFloat

    init(_ titleKey: LocalizedStringKey, systemImage: String, size: CGFloat = 14) {
        title = Text(titleKey)
        self.systemImage = systemImage
        self.size = size
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String, size: CGFloat = 14) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.size = size
    }

    var body: some View {
        Label { title } icon: { EditorSymbol(systemImage, size: size) }
    }
}

/// The same drawn glyph as an AppKit image (menus, capture overlays, status
/// item). A template image, so AppKit tints it like any symbol. Names
/// without a drawn glyph fall back to the system symbol.
enum EditorSymbolImage {
    @MainActor
    static func image(_ systemName: String, size: CGFloat = 16, description: String? = nil) -> NSImage? {
        guard let kind = EditorSymbolCatalog.kind(for: systemName) else {
            return NSImage(systemSymbolName: systemName, accessibilityDescription: description)
        }
        return image(kind, size: size, description: description)
    }

    @MainActor
    static func image(_ kind: AppLineIcon.Kind, size: CGFloat = 16, description: String? = nil) -> NSImage? {
        let renderer = ImageRenderer(content: AppLineIcon(kind: kind, size: size).foregroundStyle(.black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
