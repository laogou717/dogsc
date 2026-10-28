import SwiftUI

/// The editor draws its own line glyphs (AppLineIcon, the recorder's 18 pt
/// grid) instead of mixing in system symbols. Call sites keep the familiar
/// symbol names; a name without a drawn glyph still renders the system one.
enum EditorSymbolCatalog {
    static func kind(for systemName: String) -> AppLineIcon.Kind? {
        switch systemName {
        case "arrow.uturn.backward", "arrow.uturn.left": return .undo
        case "arrow.uturn.forward", "arrow.uturn.right": return .redo
        case "gearshape", "gearshape.fill": return .settings
        case "plus", "plus.circle", "plus.circle.fill": return .plus
        case "minus", "minus.circle": return .minus
        case "slider.horizontal.3": return .sliders
        case "moon.stars.fill", "moon.fill": return .moon
        case "sun.max.fill", "sun.max": return .sun
        case "trash", "trash.fill": return .trash
        case "folder": return .folder
        case "square.3.layers.3d", "square.stack.3d.up", "square.stack", "rectangle.stack": return .layers
        case "rectangle.inset.filled", "square.on.square", "rectangle.on.rectangle": return .layout
        case "macwindow": return .window
        case "photo", "photo.on.rectangle.angled": return .scene
        case "grid": return .grid
        case "waveform", "waveform.path", "waveform.path.ecg", "waveform.path.ecg.rectangle": return .waveform
        case "film", "film.stack", "film.stack.fill", "timeline.selection": return .film
        case "crop": return .crop
        case "scissors": return .scissors
        case "viewfinder": return .zoom
        case "scope": return .target
        case "sparkles.rectangle.stack": return .opening
        case "sparkles", "sparkle": return .sparkle
        case "speaker.wave.2", "speaker.wave.2.fill": return .speaker
        case "speaker.slash", "speaker.slash.fill": return .speakerOff
        case "mic", "mic.fill": return .microphone
        case "video", "video.fill", "video.badge.ellipsis": return .camera
        case "video.slash", "video.slash.fill": return .cameraOff
        case "display": return .display
        case "pencil": return .pencil
        case "magnet": return .magnet
        case "eye", "eye.fill": return .eye
        case "eye.slash", "eye.slash.fill": return .eyeOff
        case "clock", "clock.badge.checkmark": return .clock
        case "cube", "cube.transparent", "move.3d": return .cube
        case "link": return .link
        case "photo.badge.plus": return .photoAdd
        case "doc.on.clipboard": return .paste
        case "arrow.up.left.and.arrow.down.right": return .expand
        case "aspectratio": return .aspect
        case "hand.draw": return .move
        case "arrow.triangle.2.circlepath", "arrow.clockwise", "arrow.counterclockwise", "rotate.right": return .refresh
        case "mappin.and.ellipse": return .pin
        case "speedometer": return .speed
        case "drop.halffull": return .drop
        case "circle.lefthalf.filled": return .halfCircle
        case "bookmark", "bookmark.fill": return .bookmark
        case "arrow.left.and.right": return .swap
        case "magnifyingglass", "plus.magnifyingglass": return .search
        case "slash.circle": return .noSymbol
        case "chevron.left": return .chevronLeft
        case "chevron.up": return .chevronUp
        case "chevron.right": return .chevron
        case "chevron.down": return .chevronDown
        case "xmark": return .close
        case "checkmark": return .check
        case "checkmark.circle", "checkmark.circle.fill": return .checkCircle
        case "exclamationmark.triangle", "exclamationmark.triangle.fill": return .warning
        case "info", "info.circle": return .info
        case "play.fill", "play": return .play
        case "rectangle.slash": return .noFrame
        case "rectangle": return .shapeWide
        case "rectangle.portrait": return .portrait
        case "arrow.left": return .arrowLeft
        case "arrow.right": return .arrowRight
        case "square.and.arrow.down": return .download
        case "cursorarrow.motionlines": return .cursorMotion
        case "cursorarrow": return .cursor
        case "person", "person.fill": return .person
        case "link.badge.plus": return .link
        case "arrow.up.left": return .arrowUpLeft
        case "arrow.down.right": return .arrowDownRight
        case "delete.left": return .deleteLeft
        case "delete.right": return .deleteRight
        case "list.number", "list.bullet": return .list
        case "rectangle.3.group": return .presets
        case "circle": return .shapeCircle
        case "rectangle.fill": return .shapeWide
        case "square", "square.fill": return .shapeRounded
        // Layer order keeps the system glyphs: their front/back distinction
        // has no drawn equivalent yet.
        default: return nil
        }
    }
}

/// A drawn glyph for a symbol name. Without a drawn version the system
/// symbol is used, honouring the surrounding font exactly as before.
struct EditorSymbol: View {
    let systemName: String
    var size: CGFloat

    /// The editor's glyph sizes: 12 (inline, badges), 14 (rows, buttons),
    /// 16 (toolbars, tiles), 18 (large tiles), 20 (empty states).
    static let scale: [CGFloat] = [12, 14, 16, 18, 20]

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
