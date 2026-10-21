import Foundation
import RecorderCore
import Testing
@testable import DogSCApp

struct EditorPrimaryTimelinePresentationTests {
    @Test("Moving B after C does not turn B into a restorable gap")
    func movedMaterialIsNotARestorableGap() throws {
        let a = RecordingSegment(sourceStart: 0, sourceDuration: 2)
        let b = RecordingSegment(sourceStart: 2, sourceDuration: 2)
        let c = RecordingSegment(sourceStart: 4, sourceDuration: 2)
        let timeline = try ProjectTimelineEditing.movePrimarySegment(
            in: ProjectTimeline(sourceSequence: .edited([a, b, c])),
            segmentID: b.id,
            toIndex: 2,
            fullSourceDuration: 6
        )
        let map = try TimelineMap(
            sourceSequence: timeline.sourceSequence,
            fullSourceDuration: 6
        )

        #expect(EditorPrimaryTimelinePresentation.segmentJunctions(from: map).isEmpty)
    }

    @Test("A partially retained source gap cannot be restored as one interval")
    func partiallyRetainedGapIsNotRestorable() throws {
        let segments = [
            RecordingSegment(sourceStart: 0, sourceDuration: 2),
            RecordingSegment(sourceStart: 6, sourceDuration: 2),
            RecordingSegment(sourceStart: 3, sourceDuration: 1),
        ]
        let map = try TimelineMap(sourceSequence: .edited(segments), fullSourceDuration: 8)

        #expect(EditorPrimaryTimelinePresentation.segmentJunctions(from: map).isEmpty)
    }

    @Test("Every displayed gap remains restorable after reordering", arguments: [false, true])
    func genuinelyDeletedGapRemainsRestorable(reordered: Bool) throws {
        let a = RecordingSegment(sourceStart: 0, sourceDuration: 2)
        let c = RecordingSegment(sourceStart: 4, sourceDuration: 2)
        let d = RecordingSegment(sourceStart: 6, sourceDuration: 2)
        let timeline = ProjectTimeline(sourceSequence: .edited(reordered ? [d, a, c] : [a, c, d]))
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: 8)
        let junctions = EditorPrimaryTimelinePresentation.segmentJunctions(from: map)
        let gap = try #require(junctions.first { $0.hasRemovedSourceGap })

        #expect(gap.previousSegmentID == a.id)
        #expect(gap.nextSegmentID == c.id)
        #expect(gap.removedSourceStart == 2)
        #expect(gap.removedDuration == 2)
        let restored = try ProjectTimelineEditing.restorePrimaryGap(
            in: timeline,
            previousSegmentID: gap.previousSegmentID,
            nextSegmentID: gap.nextSegmentID,
            restoredSegmentID: UUID(),
            fullSourceDuration: 8
        )
        let restoredMap = try TimelineMap(sourceSequence: restored.sourceSequence, fullSourceDuration: 8)
        #expect(restoredMap.outputDuration == 8)
    }

    @Test("Touching source segments still offer a merge")
    func touchingSegmentsRemainMergeable() throws {
        let a = RecordingSegment(sourceStart: 0, sourceDuration: 2)
        let b = RecordingSegment(sourceStart: 2, sourceDuration: 2)
        let map = try TimelineMap(sourceSequence: .edited([a, b]), fullSourceDuration: 4)
        let junctions = EditorPrimaryTimelinePresentation.segmentJunctions(from: map)
        #expect(junctions.count == 1)
        let junction = try #require(junctions.first)
        #expect(!junction.hasRemovedSourceGap)
        #expect(junction.outputTime == 2)
    }

    @Test("A single segment has no junction actions")
    func singleSegmentHasNoJunctions() throws {
        let map = try TimelineMap(sourceSequence: .fullRecording, fullSourceDuration: 6)
        #expect(EditorPrimaryTimelinePresentation.segmentJunctions(from: map).isEmpty)
    }
}
