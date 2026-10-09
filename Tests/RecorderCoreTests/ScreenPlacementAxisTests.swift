import XCTest
@testable import RecorderCore

final class ScreenPlacementAxisTests: XCTestCase {
    func testDragMappingRoundTripsAcrossCentreAndAtLargeScales() {
        for scale in [0.5, 1, 1.2, 2] {
            let axis = ScreenPlacementAxis(canvasLength: 1080, contentLength: 800 * scale,
                                           fittedCenter: 620, leadingInset: 0, trailingInset: 0)
            for position in [0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1] {
                let center = axis.center(at: position)
                let restored = axis.position(for: center)
                XCTAssertEqual(axis.center(at: restored), center, accuracy: 0.000_001)
            }
            let start = axis.center(at: 0.4)
            let moved = axis.position(for: start + 20)
            XCTAssertEqual(axis.center(at: moved), start + 20, accuracy: 0.000_001)
        }
    }

    func testSymmetricPlacementRetainsOriginalLinearMapping() {
        let axis = ScreenPlacementAxis(canvasLength: 1080, contentLength: 800,
                                       fittedCenter: 540, leadingInset: 4, trailingInset: 4)
        for position in [0.0, 0.2, 0.5, 0.8, 1] {
            XCTAssertEqual(axis.center(at: position), 404 + position * 272, accuracy: 0.000_001)
        }
    }
}
