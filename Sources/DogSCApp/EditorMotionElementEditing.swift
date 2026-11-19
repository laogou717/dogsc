import AppKit
import RecorderCore
import SwiftUI

/// EDT-073: hands-on editing of the elements inside an HTML motion — pick,
/// move (alone, with ⇧, or by marquee), hide, retext, restore. The edits live
/// on the clip (overlay or main-track segment); the design file is untouched.
enum MotionElementTarget: Equatable, Hashable, Sendable {
    case overlay(UUID)
    case mainTrack(UUID)

    var selection: EditorSelection {
        switch self {
        case let .overlay(id): .animation(id)
        case let .mainTrack(id): .primarySegment(id)
        }
    }
}

extension ProjectTimeline {
    func motionElementEdits(_ target: MotionElementTarget) -> [String: MotionElementEdit] {
        switch target {
        case let .overlay(id):
            return animationClips.first { $0.id == id }?.elementEdits ?? [:]
        case let .mainTrack(id):
            guard case let .edited(segments) = sourceSequence else { return [:] }
            return segments.first { $0.id == id }?.media?.elementEdits ?? [:]
        }
    }

    mutating func setMotionElementEdits(_ target: MotionElementTarget, _ edits: [String: MotionElementEdit]) {
        let cleaned = edits.filter { !$0.value.isEmpty }
        switch target {
        case let .overlay(id):
            guard let i = animationClips.firstIndex(where: { $0.id == id }) else { return }
            animationClips[i].elementEdits = cleaned
        case let .mainTrack(id):
            guard case var .edited(segments) = sourceSequence,
                  let i = segments.firstIndex(where: { $0.id == id }), segments[i].media != nil else { return }
            segments[i].media?.elementEdits = cleaned
            sourceSequence = .edited(segments)
        }
    }
}

extension EditorStore {
    /// One undo step for any change to a clip's element edits.
    func changeMotionElementEdits(_ target: MotionElementTarget, actionName: String,
                                  _ change: (inout [String: MotionElementEdit]) -> Void) {
        var edits = project.timeline.motionElementEdits(target)
        change(&edits)
        let next = edits
        commitTimelineEdit(self, action: actionName) { $0.setMotionElementEdits(target, next) }
    }
}

/// The element-editing state of the canvas: which clip, which elements are
/// selected, and the live boxes of the page's elements.
@MainActor
final class MotionElementEditor: ObservableObject {
    static let shared = MotionElementEditor()

    @Published var target: MotionElementTarget?
    @Published var selected: Set<String> = [] {
        didSet {
            if let id = textEditingElementID, !selected.contains(id) { textEditingElementID = nil }
        }
    }
    @Published var textEditingElementID: String?
    /// EDT-076: a drag in progress — which elements and how far, in page
    /// CSS px. The preview renders the real page with this offset at
    /// pointer rate (one frame in flight, latest wins), without routing each
    /// mouse move through the editor's state; release writes the edit once.
    struct LiveDrag: Equatable, Sendable {
        var target: MotionElementTarget
        var ids: Set<String>
        var offset: CGSize
    }
    nonisolated(unsafe) static var liveDrag: LiveDrag?
    nonisolated(unsafe) static var onLiveDragChange: (() -> Void)?

    /// `edits` with the live drag applied (rounded like the committed edit,
    /// so the last live frame is exactly the committed picture).
    static func applyingLiveDrag(_ edits: [String: MotionElementEdit], for target: MotionElementTarget) -> [String: MotionElementEdit] {
        guard let drag = liveDrag, drag.target == target else { return edits }
        var result = edits
        for id in drag.ids {
            var edit = result[id] ?? MotionElementEdit()
            edit.dx = (edit.dx + Double(drag.offset.width)).rounded()
            edit.dy = (edit.dy + Double(drag.offset.height)).rounded()
            result[id] = edit
        }
        return result
    }
    @Published private(set) var elements: [MotionElement] = []
    /// The edits the element boxes were measured with.
    private(set) var measuredEdits: [String: MotionElementEdit] = [:]
    private var refreshKey = ""
    private var refreshTask: Task<Void, Never>?

    var isActive: Bool { target != nil }

    func begin(_ target: MotionElementTarget) {
        guard self.target != target else { return }
        textEditingElementID = nil
        selected = []
        elements = []
        refreshKey = ""
        self.target = target
    }

    func end() {
        target = nil
        textEditingElementID = nil
        selected = []
        elements = []
        refreshKey = ""
        refreshTask?.cancel()
    }

    /// Reads the page's element boxes at `time` (after the current edits).
    func refresh(path: String, properties: [String: AnimationPropertyValue], time: Double, canvas: CGSize,
                 edits: [String: MotionElementEdit]) {
        let key = "\(path)|\((time * 30).rounded())|\(Int(canvas.width))x\(Int(canvas.height))|"
            + String(describing: properties.sorted { $0.key < $1.key }) + String(describing: edits.sorted { $0.key < $1.key })
        guard key != refreshKey else { return }
        refreshKey = key
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            let list = await HTMLMotion.elements(path: ProjectFiles.resolve(path), properties: properties, time: time,
                                                 canvas: canvas, edits: edits)
            guard let self, !Task.isCancelled, self.refreshKey == key else { return }
            self.elements = list
            self.measuredEdits = edits
            self.selected = self.selected.filter { id in list.contains { $0.id == id } || edits[id]?.hidden == true }
        }
    }
}

/// Where a motion clip's page sits on the canvas, in canvas points, and the
/// page's own CSS viewport — to map element boxes and drags between them.
struct MotionElementPlacement: Equatable {
    let target: MotionElementTarget
    let path: String
    let properties: [String: AnimationPropertyValue]
    let edits: [String: MotionElementEdit]
    let localTime: Double
    /// The page's rectangle on the canvas.
    let rect: CGRect
    /// The pixel size the page is drawn at (sets its CSS viewport).
    let drawSize: CGSize

    var viewport: CGSize { HTMLMotionRenderer.viewport(for: drawSize) }
    /// Canvas points per CSS px.
    var scale: CGFloat { rect.width / max(viewport.width, 1) }

    /// The element's box now: as measured, shifted by any change to its
    /// offset since (a drag in progress moves boxes without a re-measure).
    func canvasRect(_ element: MotionElement, measured: [String: MotionElementEdit] = [:]) -> CGRect {
        let now = edits[element.id] ?? MotionElementEdit(), then = measured[element.id] ?? MotionElementEdit()
        return CGRect(x: rect.minX + (element.frame.minX + now.dx - then.dx) * scale,
                      y: rect.minY + (element.frame.minY + now.dy - then.dy) * scale,
                      width: element.frame.width * scale, height: element.frame.height * scale)
    }

    /// The clip being edited, read from the scene shown on the canvas.
    static func resolve(_ target: MotionElementTarget, scene: FrameScene, canvasSize: CGSize) -> MotionElementPlacement? {
        let sx = canvasSize.width / max(scene.canvasSize.width, 1)
        let sy = canvasSize.height / max(scene.canvasSize.height, 1)
        switch target {
        case let .overlay(id):
            guard let animation = scene.animations.first(where: { $0.id == id }),
                  HTMLMotion.isHTMLMotion(animation.sourcePath) else { return nil }
            let width = canvasSize.width * animation.width
            let height = width * canvasSize.height / max(canvasSize.width, 1)
            let center = CGPoint(x: canvasSize.width * animation.position.x, y: canvasSize.height * animation.position.y)
            return MotionElementPlacement(
                target: target, path: animation.sourcePath, properties: animation.properties, edits: animation.elementEdits,
                localTime: animation.localTime,
                rect: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                drawSize: CGSize(width: max(scene.canvasSize.width * animation.width, 2),
                                 height: max(scene.canvasSize.width * animation.width * scene.canvasSize.height
                                             / max(scene.canvasSize.width, 1), 2)))
        case .mainTrack:
            guard let motion = scene.insertedMotion else { return nil }
            let r = scene.screen.finalRect
            let rect = r.width > 2
                ? CGRect(x: r.x * sx, y: r.y * sy, width: r.width * sx, height: r.height * sy)
                : CGRect(origin: .zero, size: canvasSize)
            return MotionElementPlacement(
                target: target, path: motion.sourcePath, properties: motion.properties, edits: motion.elementEdits,
                localTime: motion.localTime, rect: rect, drawSize: HTMLMotion.insertedPixelSize(scene))
        }
    }
}

/// The canvas layer for a motion's elements. One hit surface decides what
/// is under the pointer from the current element boxes (the smallest box
/// containing the point wins, so a title is never shadowed by a larger
/// neighbour); outlines are drawn separately and never take clicks.
/// Click / ⇧-click select, drag moves the selection (snapping to the page's
/// centre lines), drag from empty space on a full-screen motion is a
/// marquee, arrows nudge, Delete hides, Esc clears.
struct MotionElementEditingLayer: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var editor: MotionElementEditor
    let placement: MotionElementPlacement
    let canvasSize: CGSize
    let accent: Color

    @State private var hovered: String?
    /// The current drag, in canvas points, while one is in progress.
    @State private var drag: CGSize?
    @State private var pressed: String?
    @State private var pressedSelected = false
    @State private var pressedClickCount = 1
    @State private var marquee: CGRect?
    @State private var snapX = false
    @State private var snapY = false
    @State private var keyMonitor: Any?
    @State private var dragBase: [String: MotionElementEdit] = [:]

    private static let space = "editor.canvas.motion-elements"

    /// Hidden elements are not on the canvas to pick (the inspector list
    /// shows them again).
    private var elements: [MotionElement] {
        editor.elements.filter { $0.kind != "background" && placement.edits[$0.id]?.hidden != true }
    }

    var body: some View {
        ZStack {
            hitSurface
            ForEach(elements) { element in
                let rect = box(element).insetBy(dx: -6, dy: -4)
                let selected = editor.selected.contains(element.id)
                let hovering = hovered == element.id
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? accent : Color.white.opacity(hovering ? 0.92 : 0),
                                  style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [5, 3]))
                    // A faint shadow keeps the hover outline readable on light pages.
                    .shadow(color: .black.opacity(hovering && !selected ? 0.25 : 0), radius: 1)
                    .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                    .overlay(alignment: .topLeading) {
                        // The name tag of what is selected, like the mockup.
                        if selected, editor.selected.count == 1 {
                            Text(element.name)
                                .font(.appUI(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent))
                                .offset(x: -1, y: -22)
                                .fixedSize()
                        }
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .animation(.easeOut(duration: 0.12), value: selected)
                    .allowsHitTesting(false)
            }
            if let marquee {
                Rectangle()
                    .fill(accent.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(accent.opacity(0.8), lineWidth: 1))
                    .frame(width: marquee.width, height: marquee.height)
                    .position(x: marquee.midX, y: marquee.midY)
                    .allowsHitTesting(false)
            }
            if drag != nil {
                if snapX {
                    Rectangle().fill(accent).frame(width: 1, height: placement.rect.height)
                        .position(x: placement.rect.midX, y: placement.rect.midY).allowsHitTesting(false)
                }
                if snapY {
                    Rectangle().fill(accent).frame(width: placement.rect.width, height: 1)
                        .position(x: placement.rect.midX, y: placement.rect.midY).allowsHitTesting(false)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .coordinateSpace(.named(Self.space))
        .onAppear(perform: refresh)
        // Re-measure only between gestures: a measure during a drag would
        // queue behind (and slow) the page's own redraws.
        .onChange(of: placement) { _, _ in if drag == nil { refresh() } }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    /// The whole motion on the main track (empty space starts a marquee);
    /// only the element boxes on an overlay, so its empty space still moves
    /// the clip underneath.
    private var hitSurface: some View {
        let shape: Path = {
            if case .mainTrack = placement.target { return Path(placement.rect) }
            var path = Path()
            for element in elements { path.addRect(box(element).insetBy(dx: -3, dy: -3)) }
            return path
        }()
        return Color.black.opacity(0.001)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .contentShape(shape)
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                switch phase {
                case let .active(point): hovered = drag == nil ? hit(point) : hovered
                case .ended: hovered = nil
                }
            }
            .gesture(pointerGesture)
    }

    /// The element under `point`: the smallest box that contains it.
    private func hit(_ point: CGPoint) -> String? {
        elements
            .map { ($0.id, box($0).insetBy(dx: -3, dy: -3)) }
            .filter { $0.1.contains(point) }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    private func box(_ element: MotionElement) -> CGRect {
        var rect = placement.canvasRect(element, measured: editor.measuredEdits)
        // A drag moves the outline with the pointer at once; the page's own
        // picture follows as its frames land.
        if let drag, editor.selected.contains(element.id) {
            let committed = dragBase[element.id] ?? MotionElementEdit()
            let now = placement.edits[element.id] ?? MotionElementEdit()
            rect = rect.offsetBy(dx: drag.width - (now.dx - committed.dx) * placement.scale,
                                 dy: drag.height - (now.dy - committed.dy) * placement.scale)
        }
        return rect
    }

    private func refresh() {
        editor.refresh(path: placement.path, properties: placement.properties, time: placement.localTime,
                       canvas: placement.drawSize, edits: placement.edits)
    }

    private var pointerGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil, marquee == nil, pressed == nil {
                    begin(at: value.startLocation)
                }
                let moved = hypot(value.translation.width, value.translation.height) >= 2
                if pressed == nil {
                    // Empty space: a marquee on the main track.
                    guard moved, case .mainTrack = placement.target else { return }
                    let a = value.startLocation, b = value.location
                    marquee = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    return
                }
                guard moved else { return }
                if drag == nil {
                    drag = .zero
                    dragBase = placement.edits
                    editorStore.beginInteraction(tool: .select, selection: placement.target.selection)
                }
                let t = snapped(value.translation)
                drag = t
                let offset = CGSize(width: t.width / placement.scale, height: t.height / placement.scale)
                MotionElementEditor.liveDrag = .init(target: placement.target, ids: editor.selected, offset: offset)
                MotionElementEditor.onLiveDragChange?()
            }
            .onEnded { value in
                EditorDragFrameCoalescer.shared.flush()
                defer {
                    drag = nil; pressed = nil; snapX = false; snapY = false
                    refresh()
                }
                if let box = marquee {
                    marquee = nil
                    let hits = Set(elements.filter { box.intersects(self.box($0)) }.map(\.id))
                    editor.selected = NSEvent.modifierFlags.contains(.shift) ? editor.selected.union(hits) : hits
                    return
                }
                guard let id = pressed else {
                    // A click on empty space: the clip itself, no element.
                    if !NSEvent.modifierFlags.contains(.shift) { editor.selected = [] }
                    return
                }
                if drag == nil {
                    if pressedClickCount == 2, let element = elements.first(where: { $0.id == id }), element.text != nil {
                        editor.selected = [id]
                        editor.textEditingElementID = id
                        return
                    }
                    // ⇧-click on an element that was already selected takes it out.
                    if NSEvent.modifierFlags.contains(.shift), pressedSelected, editor.selected.count > 1 {
                        editor.selected.remove(id)
                    }
                    return
                }
                let final = drag ?? .zero
                let ids = editor.selected, base = dragBase, target = placement.target
                let dx = Double(final.width / placement.scale), dy = Double(final.height / placement.scale)
                editorStore.updateInteraction { project in
                    var edits = base
                    for id in ids {
                        var edit = edits[id] ?? MotionElementEdit()
                        edit.dx = (edit.dx + dx).rounded()
                        edit.dy = (edit.dy + dy).rounded()
                        edits[id] = edit
                    }
                    project.timeline.setMotionElementEdits(target, edits)
                }
                do { _ = try editorStore.commitInteraction(actionName: "移动动效元素") }
                catch { editorStore.cancelInteraction() }
                MotionElementEditor.liveDrag = nil
            }
    }

    private func begin(at point: CGPoint) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp {
            pressedClickCount = event.clickCount
        } else { pressedClickCount = 1 }
        if editorStore.selection != placement.target.selection {
            editorStore.selection = placement.target.selection
        }
        pressed = hit(point)
        guard let id = pressed else { return }
        pressedSelected = editor.selected.contains(id)
        if NSEvent.modifierFlags.contains(.shift) {
            editor.selected.insert(id)
        } else if !pressedSelected {
            editor.selected = [id]
        }
    }

    /// Snaps the selection's centre to the page's centre lines.
    private func snapped(_ translation: CGSize) -> CGSize {
        // Boxes as they were when the drag began.
        let boxes = elements.filter { editor.selected.contains($0.id) }.map {
            placement.canvasRect($0, measured: editor.measuredEdits).offsetBy(
                dx: -((placement.edits[$0.id]?.dx ?? 0) - (dragBase[$0.id]?.dx ?? 0)) * placement.scale,
                dy: -((placement.edits[$0.id]?.dy ?? 0) - (dragBase[$0.id]?.dy ?? 0)) * placement.scale)
        }
        guard let first = boxes.first else { return translation }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        var t = translation
        let threshold: CGFloat = 5
        let dx = placement.rect.midX - (union.midX + t.width)
        let dy = placement.rect.midY - (union.midY + t.height)
        snapX = abs(dx) < threshold
        snapY = abs(dy) < threshold
        if snapX { t.width += dx }
        if snapY { t.height += dy }
        return t
    }

    private func commitMove(by delta: CGSize, actionName: String) {
        let ids = editor.selected
        guard !ids.isEmpty, delta != .zero else { return }
        let dx = Double(delta.width / placement.scale), dy = Double(delta.height / placement.scale)
        editorStore.changeMotionElementEdits(placement.target, actionName: actionName) { edits in
            for id in ids {
                var edit = edits[id] ?? MotionElementEdit()
                edit.dx = (edit.dx + dx).rounded()
                edit.dy = (edit.dy + dy).rounded()
                edits[id] = edit
            }
        }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard editor.isActive, !event.targetsPresentedContent else { return event }
            if let text = event.window?.firstResponder as? NSTextView, text.isEditable { return event }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 53: // Esc
                guard !editor.selected.isEmpty else { return event }
                editor.selected = []
                return nil
            case 51, 117: // Delete, Forward Delete
                guard !editor.selected.isEmpty else { return event }
                let ids = editor.selected
                editorStore.changeMotionElementEdits(placement.target, actionName: "隐藏动效元素") { edits in
                    for id in ids { var e = edits[id] ?? MotionElementEdit(); e.hidden = true; edits[id] = e }
                }
                editor.selected = []
                return nil
            case 123, 124, 125, 126: // ← → ↓ ↑
                guard !editor.selected.isEmpty else { return event }
                let delta: CGSize = switch event.keyCode {
                case 123: CGSize(width: -step, height: 0)
                case 124: CGSize(width: step, height: 0)
                case 125: CGSize(width: 0, height: step)
                default: CGSize(width: 0, height: -step)
                }
                // Arrow steps are page pixels, not canvas points.
                commitMove(by: CGSize(width: delta.width * placement.scale, height: delta.height * placement.scale),
                           actionName: "移动动效元素")
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Inspector section while editing a motion's elements: the elements by
/// name (click selects, a hidden one can be shown again), the text of the
/// selected element, and restore.
struct MotionElementInspector: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var editor: MotionElementEditor
    let target: MotionElementTarget
    @State private var rowHovered: String?
    @State private var dropRow: String?

    private var edits: [String: MotionElementEdit] { editorStore.project.timeline.motionElementEdits(target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.selected.count == 1, let id = editor.selected.first,
               let element = editor.elements.first(where: { $0.id == id }) {
                MotionElementDetail(editorStore: editorStore, target: target, element: element,
                                    edit: edits[id] ?? MotionElementEdit())
                    .id(id)
            } else if editor.selected.count > 1 {
                MotionElementGroupSize(editorStore: editorStore, target: target, ids: editor.selected)
            }
            // EDT-079: the selected element's properties come first; the
            // layer list sits below them.
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized("图层"))
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(EditorTheme.tertiaryText)
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        elementRow(row)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(appLocalized("还原所选")) {
                    let ids = editor.selected
                    editorStore.changeMotionElementEdits(target, actionName: "还原动效元素") { edits in
                        for id in ids { edits[id] = nil }
                    }
                }
                .disabled(editor.selected.allSatisfy { edits[$0] == nil })
                Button(appLocalized("全部还原")) {
                    editorStore.changeMotionElementEdits(target, actionName: "还原动效元素") { $0 = [:] }
                }
                .disabled(edits.isEmpty)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private struct Row { let id: String; let name: String; let hidden: Bool; var kind = "box" }

    /// Visible elements in page order, then hidden ones (which the page no
    /// longer reports) by key.
    private var rows: [Row] {
        var result = editor.elements.map { Row(id: $0.id, name: $0.name, hidden: edits[$0.id]?.hidden == true, kind: $0.kind) }
        let listed = Set(result.map(\.id))
        for (id, edit) in edits.sorted(by: { $0.key < $1.key }) where edit.hidden && !listed.contains(id) {
            result.append(Row(id: id, name: Self.displayName(id), hidden: true))
        }
        return result
    }

    static func displayName(_ key: String) -> String {
        if key.hasPrefix("#") { return String(key.dropFirst()) }
        if let r = key.range(of: ":"), !key.hasPrefix("path:") { return String(key[r.upperBound...]) }
        return appLocalized("元素")
    }

    private func elementRow(_ row: Row) -> some View {
        let selected = editor.selected.contains(row.id)
        return Button {
            if NSEvent.modifierFlags.contains(.shift) {
                if selected { editor.selected.remove(row.id) } else { editor.selected.insert(row.id) }
            } else {
                editor.selected = [row.id]
            }
        } label: {
            HStack(spacing: 10) {
                AppLineIcon(kind: Self.icon(row.kind), size: 13)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .frame(width: 16)
                Text(row.name)
                    .font(.appUI(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(row.hidden ? EditorTheme.tertiaryText : EditorTheme.primaryText)
                    .strikethrough(row.hidden, color: EditorTheme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if row.hidden {
                    Button {
                        editorStore.changeMotionElementEdits(target, actionName: "显示动效元素") { edits in
                            edits[row.id]?.hidden = false
                        }
                    } label: {
                        AppLineIcon(kind: .eyeOff, size: 13).foregroundStyle(EditorTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help(appLocalized("显示这个元素"))
                } else if edits[row.id] != nil {
                    Circle().fill(EditorTheme.accent).frame(width: 5, height: 5)
                        .help(appLocalized("已调整"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? EditorTheme.controlWell : EditorTheme.controlWell.opacity(rowHovered == row.id ? 0.55 : 0)))
            .contentShape(Rectangle())
            .onHover { rowHovered = $0 ? row.id : (rowHovered == row.id ? nil : rowHovered) }
            .animation(.easeOut(duration: 0.12), value: rowHovered)
        }
        .buttonStyle(.plain)
        // Like a library well: drop an image on an image (or the background)
        // row to put it there.
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { dropRow == row.id },
            set: { inside in dropRow = inside && (row.kind == "image" || row.kind == "background") ? row.id : (dropRow == row.id ? nil : dropRow) }
        )) { providers in
            guard row.kind == "image" || row.kind == "background", let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard let path = MotionElementImages.keep(url) else { return }
                    editorStore.changeMotionElementEdits(target, actionName: "替换图片") { edits in
                        var e = edits[row.id] ?? MotionElementEdit(); e.image = path; edits[row.id] = e
                    }
                    editor.selected = [row.id]
                }
            }
            return true
        }
        .overlay {
            if dropRow == row.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(EditorTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .allowsHitTesting(false)
            }
        }
    }

    static func icon(_ kind: String) -> AppLineIcon.Kind {
        switch kind {
        case "text": .list
        case "image": .photoAdd
        case "background": .layers
        case "shape": .sparkle
        default: .grid
        }
    }
}

/// Images the user puts into a motion are copied into the library, so the
/// project keeps them if the original moves.
enum MotionElementImages {
    static let extensions = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "svg"]

    @MainActor
    static func keep(_ url: URL) -> String? {
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let folder = AssetLibrary.shared.folder(for: .image)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: url, to: copy)
        }
        return FileManager.default.fileExists(atPath: copy.path) ? copy.path : url.path
    }
}

/// Everything about one element: its text and text colour, its fill, its
/// picture (drop a file or choose one) and its size.
private struct MotionElementDetail: View {
    @ObservedObject var editorStore: EditorStore
    let target: MotionElementTarget
    let element: MotionElement
    let edit: MotionElementEdit
    @State private var dropping = false

    private func change(_ action: String, _ body: @escaping (inout MotionElementEdit) -> Void) {
        let id = element.id
        editorStore.changeMotionElementEdits(target, actionName: action) { edits in
            var e = edits[id] ?? MotionElementEdit()
            body(&e)
            edits[id] = e
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if element.kind == "image" || element.kind == "background" {
                imageWell
            }
            if element.text != nil {
                EditorCommittingTextField(
                    title: appLocalized("文字"),
                    text: edit.text ?? element.text ?? "",
                    onCommit: { value in change("修改动效文字") { $0.text = value.isEmpty ? nil : value } }
                )
                colorRow(appLocalized("文字颜色"), current: edit.color ?? element.color) { hex in
                    change("修改动效颜色") { $0.color = hex }
                }
                HStack {
                    Text(appLocalized("字体")).font(.appUI(size: 12)).foregroundStyle(EditorTheme.secondaryText)
                    Spacer()
                    EditorMotionTypographyControls(element: element, edit: edit) { family in
                        change("修改动效字体") { $0.fontFamily = family }
                    } onWeight: { weight in
                        change("切换动效粗体") { $0.fontWeight = weight }
                    }
                }
            }
            if element.kind != "image", element.text == nil || element.fill != nil {
                colorRow(appLocalized(element.kind == "background" ? "背景颜色" : "填充颜色"),
                         current: edit.fill ?? element.fill) { hex in
                    change("修改动效颜色") { $0.fill = hex }
                }
            }
            if element.kind != "background" {
                MotionElementSizeSlider(value: edit.scale) { scale, final in
                    if final { change("调整动效元素大小") { $0.scale = scale } }
                }
                MotionElementSlider(title: "旋转", value: edit.rotation, range: -180...180, unit: "°") { v in
                    change("旋转动效元素") { $0.rotation = (abs(v) < 0.5 ? 0 : v.rounded()) }
                }
                MotionElementSlider(title: "不透明度", value: edit.opacity * 100, range: 0...100, unit: "%") { v in
                    change("调整动效元素不透明度") { $0.opacity = v.rounded() / 100 }
                }
                if element.text == nil {
                    MotionElementSlider(title: "圆角", value: edit.radius ?? 0, range: 0...200, unit: "") { v in
                        change("调整动效元素圆角") { $0.radius = v < 0.5 ? nil : v.rounded() }
                    }
                    MotionElementSlider(title: "描边", value: edit.strokeWidth ?? 0, range: 0...24, unit: "") { v in
                        change("调整动效元素描边") { $0.strokeWidth = v < 0.5 ? nil : v.rounded() }
                    }
                    if (edit.strokeWidth ?? 0) > 0 {
                        colorRow(appLocalized("描边颜色"), current: edit.strokeColor ?? "#FFFFFF") { hex in
                            change("修改动效描边颜色") { $0.strokeColor = hex }
                        }
                    }
                }
            }
        }
    }

    /// The picture: click to choose, or drop an image here.
    private var imageWell: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                AppLineIcon(kind: .photoAdd, size: 16).foregroundStyle(EditorTheme.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appLocalized(edit.image == nil ? "替换图片" : "已替换图片"))
                        .font(.appUI(size: 13, weight: .medium)).foregroundStyle(EditorTheme.primaryText)
                    Text(edit.image.map { URL(fileURLWithPath: $0).lastPathComponent } ?? appLocalized("点选或拖入一张图片"))
                        .font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if edit.image != nil {
                    Button { change("还原图片") { $0.image = nil } } label: {
                        AppLineIcon(kind: .refresh, size: 12).foregroundStyle(EditorTheme.tertiaryText)
                    }
                    .buttonStyle(.plain).help(appLocalized("还原原图"))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dropping ? EditorTheme.selectionWash : EditorTheme.controlWell))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(dropping ? EditorTheme.accent : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, MotionElementImages.extensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in use(url) }
            }
            return true
        }
    }

    private func choose() {
        AppFilePanel.open(configure: { panel in
            panel.allowedContentTypes = [.image]
        }) { urls in
            if let url = urls?.first { use(url) }
        }
    }

    private func use(_ url: URL) {
        guard let path = MotionElementImages.keep(url) else { return }
        change("替换图片") { $0.image = path }
    }

    /// The colour panel reports every movement of its wheel; only the value
    /// it rests on becomes one undo step.
    @State private var colorCommit: Task<Void, Never>?

    private func colorRow(_ title: String, current: String?, set apply: @escaping (String?) -> Void) -> some View {
        let set: (String?) -> Void = { value in
            colorCommit?.cancel()
            colorCommit = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                apply(value)
            }
        }
        return colorPicker(title, current: current, set: set)
    }

    private func colorPicker(_ title: String, current: String?, set: @escaping (String?) -> Void) -> some View {
        HStack(spacing: EditorPropertyRowMetrics.gap) {
            Text(title).font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
                .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
            EditorColorWell(title: title, value: current.flatMap { HexColor($0) } ?? HexColor(rgb24: 0xFFFFFF)) {
                set($0.hexString)
            }
        }
    }
}

/// Size of one element, 25–300 %, previewed while dragging and written on
/// release.
private struct MotionElementSizeSlider: View {
    let value: Double
    let onChange: (Double, Bool) -> Void

    var body: some View {
        MotionElementSlider(title: "大小", value: value * 100, range: 25...300, unit: "%") { v in
            onChange(v.rounded() / 100, true)
        }
    }
}

/// One property row in the EDT-079 grammar — label, track, number — that
/// previews nothing itself and writes one undo step on release.
private struct MotionElementSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    let onCommit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        EditorSliderRowLayout {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(Int((draft ?? value).rounded()))\(unit)")
                .font(.appUI(size: 12.5).monospacedDigit())
                .foregroundStyle(EditorTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            EditorSlider(
                value: Binding(get: { draft ?? value }, set: { draft = $0 }),
                range: range,
                showsFloatingValue: false,
                onEditingChanged: { editing in
                    if !editing, let draft { onCommit(draft); self.draft = nil }
                }
            )
        }
    }
}

/// Several elements selected: one size for all of them.
private struct MotionElementGroupSize: View {
    @ObservedObject var editorStore: EditorStore
    let target: MotionElementTarget
    let ids: Set<String>

    var body: some View {
        let edits = editorStore.project.timeline.motionElementEdits(target)
        let common = ids.compactMap { edits[$0]?.scale }.first ?? 1
        MotionElementSizeSlider(value: common) { scale, final in
            guard final else { return }
            editorStore.changeMotionElementEdits(target, actionName: "调整动效元素大小") { all in
                for id in ids { var e = all[id] ?? MotionElementEdit(); e.scale = scale; all[id] = e }
            }
        }
    }
}
