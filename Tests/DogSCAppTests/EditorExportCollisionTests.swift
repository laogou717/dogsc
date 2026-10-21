import AVFoundation
import Foundation
import RecorderCore
import Testing
@testable import DogSCApp

struct EditorExportCollisionTests {
    enum MicrophoneState: CaseIterable {
        case audible, muted, zeroVolume, segmentMuted
    }

    @Test("Original microphone media cannot be an audio export destination",
          arguments: MicrophoneState.allCases)
    func protectsMicrophone(state: MicrophoneState) throws {
        let fixture = try Fixture(state: state)
        defer { fixture.remove() }
        #expect(throws: EditorExportRequestError.outputCollidesWithInput(fixture.microphoneURL.path)) {
            _ = try fixture.request(outputURL: fixture.microphoneURL)
        }
    }

    @Test("A symlink to muted media is also protected")
    func protectsSymlinkToMutedMicrophone() throws {
        let fixture = try Fixture(state: .muted)
        defer { fixture.remove() }
        let alias = fixture.directory.appendingPathComponent("alias.m4a")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.microphoneURL)
        #expect(throws: EditorExportRequestError.outputCollidesWithInput(alias.path)) {
            _ = try fixture.request(outputURL: alias)
        }
    }

    @Test("An unrelated audio destination remains valid", arguments: [false, true])
    func allowsUnrelatedDestination(missingMutedMicrophone: Bool) throws {
        let fixture = try Fixture(state: .muted)
        defer { fixture.remove() }
        if missingMutedMicrophone {
            try FileManager.default.removeItem(at: fixture.microphoneURL)
        }
        let output = fixture.directory.appendingPathComponent("export.m4a")
        let request = try fixture.request(outputURL: output)
        #expect(request.outputURL == output)
        #expect(request.assets.microphone == nil)
    }

    private struct Fixture {
        let directory: URL
        let microphoneURL: URL
        let project: RecorderProject
        let prepared: EditorPreparedMedia

        init(state: MicrophoneState) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dogsc-export-collision-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("screen.mov")
            microphoneURL = directory.appendingPathComponent("microphone.m4a")
            // Request construction inspects file identity and prepared metadata;
            // it does not decode media. No recording devices are needed here.
            try Data("screen fixture".utf8).write(to: sourceURL)
            try Data("original microphone fixture".utf8).write(to: microphoneURL)
            var project = RecorderProject()
            project.media = ProjectMediaManifest(
                screen: ProjectMediaReference(relativePath: "screen.mov"),
                microphone: ProjectMediaReference(relativePath: "microphone.m4a")
            )
            switch state {
            case .audible: break
            case .muted: project.audio.isMicrophoneMuted = true
            case .zeroVolume: project.audio.microphoneVolume = 0
            case .segmentMuted:
                project.timeline.primarySegmentAudioOverrides[TimelineMap.fullRecordingSegmentID] =
                    PrimarySegmentAudioOverrides(isMicrophoneMuted: true)
            }
            self.project = project
            let range = try #require(MediaTimeRange(start: 0, duration: 10))
            let plan = try ProjectTimelineMediaPlan(
                project: project,
                primaryVideoRange: range,
                systemAudioRange: range,
                microphoneRange: range
            )
            let composition = AVMutableComposition()
            let track = try #require(composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            let bundle = TimelineCompositionBundle(
                plan: plan, primaryComposition: composition,
                primaryVideoTrack: track, primaryVideoTracks: [track],
                primaryVideoComposition: nil, systemAudioTrack: nil,
                microphoneAudioTrack: nil, cameraComposition: nil, cameraVideoTrack: nil
            )
            let request = EditorMediaRequest(
                editorSessionID: EditorSessionID(), sourceURL: sourceURL,
                cameraURL: nil, microphoneURL: microphoneURL,
                sourceSequence: project.timeline.sourceSequence,
                mediaManifest: project.media, pointerEvents: []
            )
            let inventories = EditorMediaInventories(
                source: MediaAssetInventory(duration: 10, videoWidth: 1920, videoHeight: 1080,
                                           videoTimeRange: range, audioTimeRange: range),
                camera: .empty,
                microphone: MediaAssetInventory(duration: 10, videoWidth: nil, videoHeight: nil,
                                               videoTimeRange: nil, audioTimeRange: range)
            )
            prepared = EditorPreparedMedia(
                generation: 1, request: request,
                payload: EditorPreparedMediaPayload(
                    composition: bundle, inventories: inventories,
                    sourceDisplaySize: CGSize(width: 1920, height: 1080),
                    cameraDisplaySize: nil, cameraContentCrop: nil, cameraSource: nil
                )
            )
        }

        func request(outputURL: URL) throws -> EditorExportRequest {
            try EditorExportRequestBuilder.make(
                editorSessionID: prepared.request.editorSessionID,
                mediaGeneration: prepared.generation, project: project,
                preparedMedia: prepared, wallpaperURL: nil,
                outputURL: outputURL, outputKind: .audio
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
