import XCTest
@testable import RecorderCore

final class CanvasPaddingGeometryTests: XCTestCase {
    private let margins = [
        CanvasPadding(top: 10, right: 20, bottom: 80, left: 160),
        CanvasPadding(top: 360, right: 0, bottom: 360, left: 0),
        CanvasPadding(top: 0, right: 360, bottom: 0, left: 360),
        CanvasPadding(top: 40, right: 120, bottom: 40, left: 120, mode: .axes)
    ]

    func testAdaptivePreviewRespectsEachEdgeIncludingOrientationChanges() {
        for sourceAspect in [16.0 / 9, 9.0 / 16, 1, 1.2, 0.8] {
            for padding in margins {
                let canvas = CanvasStyle(paddingInsets: padding)
                let aspect = canvas.resolvedAspectRatio(sourceAspectRatio: sourceAspect)
                assertMargins(canvas: canvas, sourceAspect: sourceAspect,
                              width: aspect * 1080, height: 1080, accuracy: 0.000_001)
            }
        }
    }

    func testCroppedExportRespectsEachEdgeAtEveryResolution() {
        for source in [CanvasDimensions(width: 1920, height: 1080),
                       CanvasDimensions(width: 1080, height: 1920)] {
            for padding in margins {
                let canvas = CanvasStyle(paddingInsets: padding,
                                         crop: NormalizedCrop(width: 0.6, height: 0.8))
                let sourceAspect = Double(source.width) / Double(source.height)
                let croppedAspect = sourceAspect * canvas.crop.width / canvas.crop.height
                for resolution in CanvasResolution.allCases {
                    let size = canvas.pixelDimensions(resolution: resolution,
                                                     sourceAspectRatio: croppedAspect,
                                                     sourcePixelSize: source)
                    assertMargins(canvas: canvas, sourceAspect: sourceAspect,
                                  width: Double(size.width), height: Double(size.height), accuracy: 2)
                }
            }
        }
    }

    func testPlacementKeepsEdgesAndAuthoredPaddingCentre() {
        var canvas = CanvasStyle(paddingInsets: margins[0], borderWidth: 3)
        let aspect = canvas.resolvedAspectRatio(sourceAspectRatio: 16.0 / 9)
        let width = aspect * 1080
        for position in [0.0, 0.5, 1] {
            canvas.contentPosition = NormalizedPoint(x: position, y: position)
            let scene = evaluate(canvas: canvas, sourceAspect: 16.0 / 9, width: width, height: 1080)
            let rect = scene.screen.baseRect
            switch position {
            case 0:
                XCTAssertEqual(rect.x, 3, accuracy: 0.000_001)
                XCTAssertEqual(rect.y, 3, accuracy: 0.000_001)
            case 1:
                XCTAssertEqual(rect.x + rect.width, width - 3, accuracy: 0.000_001)
                XCTAssertEqual(rect.y + rect.height, 1077, accuracy: 0.000_001)
            default:
                XCTAssertEqual(rect.midX, scene.screen.fittedRect.midX, accuracy: 0.000_001)
                XCTAssertEqual(rect.midY, scene.screen.fittedRect.midY, accuracy: 0.000_001)
            }
        }
    }

    func testFixedCanvasRespectsMinimumMarginsAndKeepsItsRatio() {
        let canvas = CanvasStyle(aspectRatio: .landscape, paddingInsets: margins[0])
        XCTAssertEqual(canvas.resolvedAspectRatio(sourceAspectRatio: 1), 16.0 / 9)
        let scene = evaluate(canvas: canvas, sourceAspect: 1, width: 1920, height: 1080)
        let rect = scene.screen.baseRect
        XCTAssertGreaterThanOrEqual(rect.x, 160)
        XCTAssertGreaterThanOrEqual(1920 - rect.x - rect.width, 20)
        XCTAssertGreaterThanOrEqual(rect.y, 10)
        XCTAssertGreaterThanOrEqual(1080 - rect.y - rect.height, 80)
    }

    private func assertMargins(canvas: CanvasStyle, sourceAspect: Double,
                               width: Double, height: Double, accuracy: Double,
                               file: StaticString = #filePath, line: UInt = #line) {
        let scene = evaluate(canvas: canvas, sourceAspect: sourceAspect, width: width, height: height)
        let rect = scene.screen.baseRect
        let expected = canvas.paddingInsets.scaled(
            by: min(width, height) / 1080, maximum: min(width, height) * 0.42
        )
        XCTAssertEqual(rect.x, expected.left, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.y, expected.top, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(width - rect.x - rect.width, expected.right,
                       accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(height - rect.y - rect.height, expected.bottom,
                       accuracy: accuracy, file: file, line: line)
    }

    private func evaluate(canvas: CanvasStyle, sourceAspect: Double,
                          width: Double, height: Double) -> CompositionSceneEvaluation {
        CompositionSceneEvaluator.evaluate(
            project: RecorderProject(canvas: canvas), time: 0,
            canvasWidth: width, canvasHeight: height, sourceAspectRatio: sourceAspect,
            styleScale: CompositionSceneEvaluator.canonicalStyleScale(
                canvasWidth: width, canvasHeight: height
            )
        )
    }
}
