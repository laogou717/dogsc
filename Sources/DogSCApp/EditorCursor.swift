import AppKit
import QuartzCore
import SwiftUI

/// The pointer says what a drag will do: resize arrows over edges and
/// bars, an open hand over things that move. Pushed on entry, popped on
/// exit or when the view goes away, so the stack never leaks.
private struct EditorCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    cursor.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func editorCursor(_ cursor: NSCursor) -> some View {
        modifier(EditorCursorModifier(cursor: cursor))
    }
}

/// A small inlaid trim grip. Hover changes its ink, never its dimensions;
/// the wider invisible hit target keeps the endpoint easy to grab.
struct EditorTrimGrip: View {
    let color: Color
    let height: CGFloat
    @State private var hovered = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: 2, height: height)
            .animation(.easeOut(duration: 0.12)) { grip in
                grip.opacity(hovered ? 1 : 0.75)
            }
            .padding(1)
            .background(EditorTheme.panelRaised, in: Capsule())
            .frame(width: 12)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .editorCursor(.resizeLeftRight)
    }
}

/// The one handle every canvas object uses: a white square with the
/// selection accent as its rim. Its size never changes, so the point being
/// dragged stays exactly under the pointer; hover and drag fill it.
struct EditorCanvasHandle: View {
    private let color = EditorTheme.selectionTint
    var active = false
    var size: CGFloat = 10
    @State private var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(active || hovered ? color : .white)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(active || hovered ? .white : color, lineWidth: 1.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .animation(SpringMotion.micro, value: hovered)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .editorCursor(.crosshair)
    }
}

// MARK: - Clip motion on the timeline

extension View {
    /// Visual edges must remain at the authored times during move/snap/trim.
    /// Fade only the ink: a centre-anchored scale moves both endpoints away
    /// from the snapping guide and a drag shadow spills into the next lane.
    func editorClipDragFeedback(_ dragged: Bool) -> some View {
        opacity(dragged ? 0.9 : 1)
    }

    /// Add, split, delete and undo update at the authored positions. Do not
    /// inherit an ancestor's layout animation into clip bounds or offsets;
    /// local ink/hover and film/waveform animations can still run separately.
    func editorTimelineEdits() -> some View {
        transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - Drag updates at the display rate

/// Pointer drags can deliver 120–1000 events a second, and each one used to
/// rebuild the editor's view graph (measured: ~65% of the main thread while
/// dragging a clip). Only the newest drag position matters for a frame, so
/// drag handlers submit their work here and it runs once per display refresh.
/// `onEnded` flushes first, so the last position is always applied before
/// the gesture finishes.
@MainActor
final class EditorDragFrameCoalescer: NSObject {
    static let shared = EditorDragFrameCoalescer()

    /// One pending update per call site: two gestures that are active at the
    /// same time (a drag and a simultaneous gesture) never overwrite each other.
    private var pending: [String: () -> Void] = [:]
    private var order: [String] = []
    private var link: CADisplayLink?
    private weak var linkedScreen: NSScreen?

    func submit(file: String = #fileID, line: Int = #line, _ work: @escaping () -> Void) {
        let key = "\(file):\(line)"
        if pending.updateValue(work, forKey: key) == nil { order.append(key) }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else {
            flush()
            return
        }
        if let link, linkedScreen === screen { link.isPaused = false; return }
        link?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        let rate = Float(max(screen.maximumFramesPerSecond, 1))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        linkedScreen = screen
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        flush()
    }

    func flush() {
        link?.isPaused = true
        let keys = order
        let works = pending
        order.removeAll()
        pending.removeAll()
        for key in keys { works[key]?() }
    }
}
