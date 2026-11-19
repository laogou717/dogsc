import SwiftUI

/// Context menus retain their actions while the grid is rebuilt. All actions
/// read the same live selection instead of a card's earlier value snapshot.
@MainActor
final class EditorMediaSelection: ObservableObject {
    @Published var ids: Set<UUID> = []

    func targets(for id: UUID) -> Set<UUID> { ids.contains(id) ? ids : [id] }
}

struct EditorMediaItemFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct EditorMediaContentTop: PreferenceKey {
    static let defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// Only the box observes pointer movement; media tiles update on selection changes.
@MainActor
final class EditorMediaMarquee: ObservableObject {
    @Published private(set) var rect: CGRect?
    var isActive: Bool { rect != nil }
    private var start = CGPoint.zero
    private var base: Set<UUID> = []
    private var frames: [UUID: CGRect] = [:]

    func begin(at start: CGPoint, base: Set<UUID>, frames: [UUID: CGRect]) {
        self.start = start; self.base = base; self.frames = frames
        rect = CGRect(origin: start, size: .zero)
    }

    func update(to point: CGPoint) -> Set<UUID> {
        let box = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                         width: abs(point.x - start.x), height: abs(point.y - start.y))
        rect = box
        return base.union(frames.compactMap { box.intersects($0.value) ? $0.key : nil })
    }

    func end() { rect = nil; frames = [:]; base = [] }
}

struct EditorMediaMarqueeOverlay: View {
    @ObservedObject var marquee: EditorMediaMarquee
    var body: some View {
        if let rect = marquee.rect {
            RoundedRectangle(cornerRadius: 4)
                .fill(EditorTheme.selectionWash)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(EditorTheme.accent, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}
