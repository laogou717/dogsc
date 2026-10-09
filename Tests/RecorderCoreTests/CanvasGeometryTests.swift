import XCTest
@testable import RecorderCore

final class CanvasGeometryTests: XCTestCase {
    func testAdaptivePreviewHasEqualMarginsAcrossOrientationsAndCrops() {
        for sourceAspect in [16.0 / 9, 9.0 / 16, 1, 2.39, 1.0 / 2.39] {
            for crop in [NormalizedCrop.full, NormalizedCrop(width: 0.6, height: 0.8)] {
                for padding in [0.0, 10, 100, 360, 1_000] {
                    let canvas = CanvasStyle(padding: padding, crop: crop)
                    let aspect = canvas.resolvedAspectRatio(
                        sourceAspectRatio: sourceAspect * crop.width / crop.height
                    )
                    assertEqualMargins(canvas: canvas, sourceAspect: sourceAspect,
                                       width: 720 * aspect, height: 720, accuracy: 0.000_001)
                }
            }
        }
    }

    func testAdaptiveExportHasEqualMarginsAtEveryResolution() {
        for source in [CanvasDimensions(width: 1920, height: 1080),
                       CanvasDimensions(width: 1080, height: 1920),
                       CanvasDimensions(width: 1400, height: 1400)] {
            for crop in [NormalizedCrop.full, NormalizedCrop(width: 0.6, height: 0.8)] {
                for padding in [0.0, 10, 100, 360] {
                    let canvas = CanvasStyle(padding: padding, crop: crop)
                    let sourceAspect = Double(source.width) / Double(source.height)
                    for resolution in CanvasResolution.allCases {
                        let size = canvas.pixelDimensions(
                            resolution: resolution,
                            sourceAspectRatio: sourceAspect * crop.width / crop.height,
                            sourcePixelSize: source
                        )
                        XCTAssertEqual(size.width % 2, 0)
                        XCTAssertEqual(size.height % 2, 0)
                        // Encoded dimensions are rounded to even pixels.
                        assertEqualMargins(canvas: canvas, sourceAspect: sourceAspect,
                                           width: Double(size.width), height: Double(size.height),
                                           accuracy: 2)
                    }
                }
            }
        }
    }

    func testNativeAdaptiveCanvasPreservesSourceContentSize() {
        let canvas = CanvasStyle(padding: 100)
        let source = CanvasDimensions(width: 1920, height: 1080)
        let size = canvas.pixelDimensions(resolution: .source, sourcePixelSize: source)
        let scene = CompositionSceneEvaluator.evaluate(
            project: RecorderProject(canvas: canvas), time: 0,
            canvasWidth: Double(size.width), canvasHeight: Double(size.height),
            sourceAspectRatio: 16.0 / 9,
            styleScale: CompositionSceneEvaluator.canonicalStyleScale(
                canvasWidth: Double(size.width), canvasHeight: Double(size.height)
            )
        )
        XCTAssertEqual(scene.screen.fittedRect.width, 1920, accuracy: 2)
        XCTAssertEqual(scene.screen.fittedRect.height, 1080, accuracy: 2)
    }

    func testFixedRatiosDoNotChangeWithPadding() {
        for ratio in CanvasAspectRatio.allCases where ratio != .adaptive {
            let unpadded = CanvasStyle(aspectRatio: ratio, padding: 0)
            let padded = CanvasStyle(aspectRatio: ratio, padding: 100)
            XCTAssertEqual(unpadded.resolvedAspectRatio(sourceAspectRatio: 16.0 / 9),
                           padded.resolvedAspectRatio(sourceAspectRatio: 16.0 / 9))
            for resolution in CanvasResolution.allCases {
                XCTAssertEqual(unpadded.pixelDimensions(resolution: resolution),
                               padded.pixelDimensions(resolution: resolution))
            }
        }
    }

    private func assertEqualMargins(
        canvas: CanvasStyle, sourceAspect: Double,
        width: Double, height: Double, accuracy: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let scene = CompositionSceneEvaluator.evaluate(
            project: RecorderProject(canvas: canvas), time: 0,
            canvasWidth: width, canvasHeight: height, sourceAspectRatio: sourceAspect,
            styleScale: CompositionSceneEvaluator.canonicalStyleScale(
                canvasWidth: width, canvasHeight: height
            )
        )
        let rect = scene.screen.fittedRect
        XCTAssertEqual(rect.x, rect.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.x, width - rect.x - rect.width,
                       accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.y, height - rect.y - rect.height,
                       accuracy: accuracy, file: file, line: line)
        let expected = min(max(canvas.paddingInsets.top / 1080, 0), 0.42) * min(width, height)
        XCTAssertEqual(rect.x, expected, accuracy: accuracy, file: file, line: line)
    }
}
