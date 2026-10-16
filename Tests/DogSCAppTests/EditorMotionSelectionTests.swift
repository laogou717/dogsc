import AppKit
import RecorderCore
import Testing
@testable import DogSCApp

@MainActor
struct EditorMotionSelectionTests {
    private func fixture() -> (EditorStore, [EditorSelection]) {
        let clips = (0..<5).map { ZoomAnimationClip(startTime: Double($0 * 3), endTime: Double($0 * 3 + 2)) }
        return (EditorStore(project: RecorderProject(zoomAnimations: Array(clips.reversed()))), clips.map { .zoom($0.id) })
    }

    @Test func shiftSelectsChronologicalRangeInBothDirections() {
        let (store, items) = fixture()
        store.selectTimelineMotion(items[3])
        store.selectTimelineMotion(items[1], modifiers: .shift)
        #expect(store.motionSelections == Set(items[1...3]))
        store.selectTimelineMotion(items[4], modifiers: .shift)
        #expect(store.motionSelections == Set(items[3...4]))
    }

    @Test func commandTogglesAndCommandShiftExtendsRange() {
        let (store, items) = fixture()
        store.selectTimelineMotion(items[0])
        store.selectTimelineMotion(items[2], modifiers: .command)
        store.selectTimelineMotion(items[4], modifiers: [.command, .shift])
        #expect(store.motionSelections == Set([items[0], items[2], items[3], items[4]]))
        store.selectTimelineMotion(items[3], modifiers: .command)
        #expect(!store.motionSelections.contains(items[3]))
        #expect(store.selection != items[3])
    }

    @Test func commandCanDeselectLastClipAndPlainClickReplacesRange() {
        let (store, items) = fixture()
        store.selectTimelineMotion(items[0])
        store.selectTimelineMotion(items[0], modifiers: .command)
        #expect(store.selection == nil)
        #expect(store.motionSelections.isEmpty)
        store.selectTimelineMotion(items[0])
        store.selectTimelineMotion(items[4], modifiers: .shift)
        store.selectTimelineMotion(items[2])
        #expect(store.motionSelections == [items[2]])
    }

    @Test func switchingTracksOrInspectorClearsOldBatch() throws {
        let (store, items) = fixture()
        let screen = ScreenMotionClip(timing: TransitionTiming(startTime: 0), target: ScreenMotionState())
        try store.insertScreenMotion(screen)
        store.selectTimelineMotion(items[0])
        store.selectTimelineMotion(items[4], modifiers: .shift)
        store.selectTimelineMotion(.screenMotion(screen.id), modifiers: .command)
        #expect(store.motionSelections == [.screenMotion(screen.id)])
        store.selection = .canvas
        #expect(store.motionSelections.isEmpty)
        #expect(store.motionSelectionAnchor == nil)
    }

    @Test func batchDeletePreservesUnselectedClipsAndUndoRestoresSelection() throws {
        let (store, items) = fixture()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.attachUndoManager(undo)
        let original = store.project
        store.selectTimelineMotion(items[1])
        store.selectTimelineMotion(items[3], modifiers: .shift)
        undo.beginUndoGrouping()
        try store.removeSelectedMotions()
        undo.endUndoGrouping()
        #expect(Set(store.project.zoomAnimations.map { EditorSelection.zoom($0.id) }) == [items[0], items[4]])
        #expect(store.motionSelections.isEmpty)
        undo.undo()
        #expect(store.project == original)
        #expect(store.motionSelections == Set(items[1...3]))
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project.zoomAnimations.count == 2)
        #expect(store.motionSelections.isEmpty)
    }

    @Test func directRemovalPrunesStaleBatchMembers() throws {
        let (store, items) = fixture()
        store.selectTimelineMotion(items[0])
        store.selectTimelineMotion(items[4], modifiers: .shift)
        if case let .zoom(id) = items[2] { try store.removeZoom(id: id) }
        #expect(!store.motionSelections.contains(items[2]))
        #expect(store.motionSelections.count == 4)
    }

    @Test func deletingJoinedZoomsRepairsPredecessorExit() throws {
        let clips = (0..<4).map { ZoomAnimationClip(startTime: Double($0 * 2), endTime: Double($0 * 2 + 2), exitDuration: 0) }
        let store = EditorStore(project: RecorderProject(zoomAnimations: clips))
        store.selectTimelineMotion(.zoom(clips[1].id))
        store.selectTimelineMotion(.zoom(clips[2].id), modifiers: .shift)
        try store.removeSelectedMotions()
        #expect(store.project.zoomAnimations[0].exitDuration == store.project.motion.defaultZoomTransitionDuration)
        #expect(store.project.zoomAnimations[1] == clips[3])
    }

    @Test(arguments: [true, false]) func screenAndCameraBatchesUseSameSelectionRules(screen: Bool) throws {
        var project = RecorderProject()
        let times = (0..<4).map { TransitionTiming(startTime: Double($0 * 2), duration: 2, leadInDuration: 0.5) }
        let items: [EditorSelection]
        if screen {
            project.timeline.screenMotionClips = times.map { ScreenMotionClip(timing: $0, target: ScreenMotionState()) }
            items = project.timeline.screenMotionClips.map { .screenMotion($0.id) }
        } else {
            project.timeline.cameraMotionClips = times.map { CameraMotionClip(timing: $0, target: CameraMotionState()) }
            items = project.timeline.cameraMotionClips.map { .cameraMotion($0.id) }
        }
        let store = EditorStore(project: project)
        store.selectTimelineMotion(items[1])
        store.selectTimelineMotion(items[2], modifiers: .shift)
        try store.removeSelectedMotions()
        #expect(store.orderedMotionSelections(for: items[0]) == [items[0], items[3]])
        if screen {
            #expect(store.project.timeline.screenMotionClips[0].timing.returnDuration > 0)
        } else {
            #expect(store.project.timeline.cameraMotionClips[0].timing.returnDuration > 0)
        }
    }
}
