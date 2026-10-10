import RecorderCore
import Testing

struct MediaTimelinePlacementTests {
    @Test(arguments: [
        (1.0, 3.0),
        (2.0, 2.0),
        (0.5, 5.0),
        (1.05, 2.9047619047619047),
    ])
    func missingSourceLeadUsesPrimaryClock(scale: Double, expectedStart: Double) {
        let placement = MediaTimelinePlacement(
            reference: ProjectMediaReference(
                relativePath: "media/camera.mov",
                startOffset: 1,
                sourceStartTime: 1,
                sourceTimeScale: scale
            ),
            sourceAvailableStart: 3,
            sourceAvailableDuration: 10,
            timelineDuration: 12
        )

        #expect(abs(placement.timelineStart - expectedStart) < 0.000_001)
        #expect(placement.sourceTime(at: expectedStart) == 3)
        #expect(placement.sourceTime(at: expectedStart - 0.01) == nil)
        #expect(abs((placement.timelineTime(forSourceTime: 3) ?? -1) - expectedStart) < 0.000_001)
    }

    @Test
    func legacyReferenceKeepsUnitRate() {
        let placement = MediaTimelinePlacement(
            reference: ProjectMediaReference(
                relativePath: "media/camera.mov",
                startOffset: 1,
                sourceStartTime: 1
            ),
            sourceAvailableStart: 3,
            sourceAvailableDuration: 10,
            timelineDuration: 12
        )

        #expect(placement.timelineStart == 3)
        #expect(placement.sourceTimeScale == 1)
        #expect(placement.sourceTime(at: 3) == 3)
    }

    @Test
    func availableRequestedStartDoesNotAddAGap() {
        let placement = MediaTimelinePlacement(
            reference: ProjectMediaReference(
                relativePath: "media/camera.mov",
                startOffset: 1,
                sourceStartTime: 4,
                sourceTimeScale: 2
            ),
            sourceAvailableStart: 3,
            sourceAvailableDuration: 10,
            timelineDuration: 12
        )

        #expect(placement.timelineStart == 1)
        #expect(placement.sourceTime(at: 1) == 4)
        #expect(placement.playableDuration == 4.5)
    }

    @Test
    func unavailableLeadBeyondProjectHasNoPlayableMedia() {
        let placement = MediaTimelinePlacement(
            reference: ProjectMediaReference(
                relativePath: "media/camera.mov",
                startOffset: 2,
                sourceStartTime: 1,
                sourceTimeScale: 2
            ),
            sourceAvailableStart: 3,
            sourceAvailableDuration: 10,
            timelineDuration: 1
        )

        #expect(placement.timelineStart == 1)
        #expect(placement.playableDuration == 0)
        #expect(placement.sourceTime(at: 1) == nil)
    }

    @Test
    func cameraAndMicrophonePlansStartAtTheFirstAvailableFrame() throws {
        let reference = ProjectMediaReference(
            relativePath: "media/camera.mov",
            startOffset: 1,
            sourceStartTime: 1,
            sourceTimeScale: 2
        )
        let primaryRange = try #require(MediaTimeRange(start: 0, duration: 12))
        let auxiliaryRange = try #require(MediaTimeRange(start: 3, duration: 10))
        let plan = try ProjectTimelineMediaPlan(
            sourceSequence: .fullRecording,
            mediaManifest: ProjectMediaManifest(
                screen: ProjectMediaReference(relativePath: "media/screen.mov"),
                camera: reference,
                microphone: reference
            ),
            primaryVideoRange: primaryRange,
            cameraRange: auxiliaryRange,
            microphoneRange: auxiliaryRange
        )

        for mediaPlan in [plan.camera, plan.microphone] {
            let slice = try #require(mediaPlan?.slices.first)
            #expect(slice.outputStart == 2)
            #expect(slice.sourceTime(atOutputTime: 2) == 3)
            #expect(slice.duration == 5)
        }
    }
}
