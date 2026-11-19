import AppKit
import SwiftUI

/// Timeline lane hues from the design mockup (`--t-*` tokens): one lightness,
/// low chroma, so the lanes read as a family. Clips are light tints of their
/// lane hue (mixed into the panel), with a deeper same-hue ink for text. Only
/// the selected clip carries the accent frame and handles.
enum EditorTimelineHue: Equatable {
    case subtitle, overlay, zoom, motion3D, cameraMotion, region, audio

    private var hex: UInt32 {
        switch self {
        // Every lane reads as its own colour. 摄像运动 used to share 3D 运镜's
        // amber and 柔化 sat next to it in tan, so three neighbouring lanes
        // looked like one.
        case .subtitle: 0x7E8798   // blue-grey
        case .overlay: 0x9488B5    // violet
        case .zoom: 0x7E9A63       // green
        case .motion3D: 0xB38D52   // amber
        case .cameraMotion: 0xB0758A // rose
        case .region: 0x5E9A96     // teal
        case .audio: 0x6B8FB8      // blue
        }
    }

    private var base: NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // The same panel and ink the editor uses (mockup --panel / --ink).
    private static let lightPanel = NSColor(srgbRed: 0.984, green: 0.980, blue: 0.969, alpha: 1)
    private static let darkPanel = NSColor(srgbRed: 0.133, green: 0.129, blue: 0.122, alpha: 1)
    private static let lightInk = NSColor(srgbRed: 0.118, green: 0.114, blue: 0.102, alpha: 1)
    private static let darkInk = NSColor(srgbRed: 0.929, green: 0.922, blue: 0.898, alpha: 1)

    /// `color-mix(in srgb, hue fraction, other)`, resolved per appearance.
    private func mix(_ fraction: CGFloat, light: NSColor, dark: NSColor) -> Color {
        let hue = base
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let other = isDark ? dark : light
            return other.blended(withFraction: fraction, of: hue) ?? hue
        })
    }

    /// The lane hue itself (create "+" disc, collapsed occupancy bands).
    var solid: Color { Color(nsColor: base) }

    /// Clip ground at rest / hovered / selected (15% / 24% / 26%).
    func clipFill(_ emphasis: EditorTimelineClipEmphasis) -> Color {
        let fraction: CGFloat = switch emphasis {
        case .idle: 0.15
        case .hovered: 0.24
        case .selected, .editing: 0.26
        }
        return mix(fraction, light: Self.lightPanel, dark: Self.darkPanel)
    }

    /// Clip text: the hue deepened toward ink (72% hue).
    var clipInk: Color { mix(0.72, light: Self.lightInk, dark: Self.darkInk) }

    /// A collapsed group's band: the hue at 40% over the lane.
    var occupancy: Color { solid.opacity(0.4) }
}

extension EditorTimelineHue {
    static func forKind(_ kind: EditorOverlayTimelineKind) -> EditorTimelineHue {
        switch kind {
        case .subtitle: .subtitle
        case .video, .sticker, .animation: .overlay
        case .mosaic: .region
        case .audio: .audio
        }
    }

    static func forLane(_ lane: TimelineLane) -> EditorTimelineHue {
        switch lane {
        case .subtitles: .subtitle
        case .layer, .moreLayers: .overlay
        case .effects: .region
        case let .groupHeader(group): group == .effects ? .region : .overlay
        case .audio: .audio
        }
    }
}

/// The two timeline tools: Select (A) and Cut (B).
enum EditorTimelineTool: Equatable {
    case select
    case cut
}

@MainActor
enum EditorTimelineScissorsCursor {
    /// The pointer turns into scissors while the Cut tool is active.
    static let cursor: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .crosshair }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            // Match the editor's selection and cut-guide accent.
            let inset = rect.insetBy(dx: 3, dy: 3)
            for offset in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
                Self.tinted(symbol, .white).draw(in: inset.offsetBy(dx: offset.x, dy: offset.y))
            }
            Self.tinted(symbol, NSColor(EditorTheme.accent)).draw(in: inset)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
    }()

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }
}

/// The selected-clip treatment from the mockup: an inset 1.5pt accent frame
/// and two 3pt accent handles inside both ends. Hover only brightens.
struct EditorTimelineClipSelectionChrome: View {
    let cornerRadius: CGFloat
    let emphasis: EditorTimelineClipEmphasis
    let width: CGFloat
    /// A lane wears its own hue when selected. One accent for every track made
    /// a green zoom clip light up terracotta, which says nothing about what was
    /// selected. The neutral recording clip has no hue, so it keeps the accent.
    var tint: Color = EditorTheme.accent

    var body: some View {
        let active = emphasis == .selected || emphasis == .editing
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint, lineWidth: 1.5)
            if width >= 18 {
                HStack(spacing: 0) {
                    handle
                    Spacer(minLength: 0)
                    handle
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 6)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: active)
        .allowsHitTesting(false)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(tint)
            .frame(width: 3)
    }
}

extension View {
    /// A light tint of the lane hue, with the selection frame in that same hue.
    func editorTimelineHueClip(
        _ hue: EditorTimelineHue,
        emphasis: EditorTimelineClipEmphasis,
        width: CGFloat,
        cornerRadius: CGFloat = 6
    ) -> some View {
        background(
            hue.clipFill(emphasis),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            EditorTimelineClipSelectionChrome(cornerRadius: cornerRadius, emphasis: emphasis,
                                              width: width, tint: hue.solid)
        }
    }
}
