import XCTest
@testable import RecorderCore

final class CameraCanvasGeometryTests: XCTestCase {
    func testCameraSplitSamplingMatchesRenderedCanvasWithCropAndMargins() throws {
        let clip = CameraMotionClip(
            timing: TransitionTiming(startTime: 0, duration: 2, leadInDuration: 1),
            target: CameraMotionState(layout: .fullscreen,
                                      position: NormalizedPoint(x: 0.5, y: 0.5), size: 0.8)
        )
        for ratio in [CanvasAspectRatio.adaptive, .portrait, .custom] {
            let canvas = CanvasStyle(
                aspectRatio: ratio,
                customAspectRatio: CanvasCustomAspectRatio(width: 3, height: 2),
                paddingInsets: CanvasPadding(top: 20, right: 60, bottom: 120, left: 160),
                crop: NormalizedCrop(width: 0.6, height: 0.8)
            )
            var project = RecorderProject(canvas: canvas)
            project.timeline.cameraMotionClips = [clip]
            let sourceAspect = 16.0 / 9
            let canvasAspect = canvas.resolvedAspectRatio(
                sourceAspectRatio: sourceAspect * canvas.crop.width / canvas.crop.height
            )
            let time = 0.5
            let sample = CameraMotionTrack([clip]).sample(
                at: time,
                base: CameraMotionState(layout: .shape(project.camera.shape),
                                        position: project.camera.position, size: project.camera.size,
                                        roundness: project.camera.roundness),
                cameraAspectRatio: 4.0 / 3, canvasAspectRatio: canvasAspect,
                motion: project.motion
            )
            let expected = CompositionSceneEvaluator.evaluateCamera(
                style: project.camera, motion: sample, screenZoomScale: 1,
                canvasWidth: canvasAspect * 1080, canvasHeight: 1080
            )
            let rendered = CompositionSceneEvaluator.evaluate(
                project: project, time: time,
                canvasWidth: canvasAspect * 1080, canvasHeight: 1080,
                sourceAspectRatio: sourceAspect, cameraAspectRatio: 4.0 / 3
            )
            let camera = try XCTUnwrap(rendered.camera)
            XCTAssertEqual(camera.rect, expected.rect)
            XCTAssertNotEqual(canvasAspect, sourceAspect)
        }
    }

    func testAsymmetricMarginsKeepScreenMotionEntryAndReturnContinuous() {
        let canvas = CanvasStyle(paddingInsets: CanvasPadding(
            top: 10, right: 20, bottom: 80, left: 160
        ))
        var project = RecorderProject(canvas: canvas)
        project.timeline.screenMotionClips = [ScreenMotionClip(
            timing: TransitionTiming(startTime: 0, duration: 1, leadInDuration: 1, returnDuration: 1),
            target: ScreenMotionState(position: NormalizedPoint(x: 0.5, y: 0.5),
                                      scale: 2, rotationX: 25)
        )]
        let width = canvas.resolvedAspectRatio(sourceAspectRatio: 16.0 / 9) * 1080
        func screen(_ time: Double) -> ScreenSceneEvaluation {
            CompositionSceneEvaluator.evaluate(
                project: project, time: time, canvasWidth: width, canvasHeight: 1080,
                sourceAspectRatio: 16.0 / 9
            ).screen
        }
        let start = screen(0)
        let focused = screen(1)
        let returned = screen(2)
        XCTAssertEqual(start.baseRect.midX, start.fittedRect.midX, accuracy: 0.000_001)
        XCTAssertEqual(focused.baseRect.midX, width / 2, accuracy: 0.000_001)
        XCTAssertEqual(focused.baseRect.midY, 540, accuracy: 0.000_001)
        XCTAssertEqual(returned.baseRect.midX, start.baseRect.midX, accuracy: 0.000_001)
        XCTAssertEqual(returned.baseRect.midY, start.baseRect.midY, accuracy: 0.000_001)
        XCTAssertEqual(screen(1 - 0.000_001).baseRect.midX, focused.baseRect.midX, accuracy: 0.01)
        XCTAssertEqual(screen(2 - 0.000_001).baseRect.midX, returned.baseRect.midX, accuracy: 0.01)
    }
}
