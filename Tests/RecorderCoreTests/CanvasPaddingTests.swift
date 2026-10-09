import XCTest
@testable import RecorderCore

final class CanvasPaddingTests: XCTestCase {
    func testModeChangesAndLinkedEdits() {
        var padding = CanvasPadding(top: 10, right: 20, bottom: 30, left: 40)
        padding.setMode(.axes)
        XCTAssertEqual(padding.top, 20)
        XCTAssertEqual(padding.bottom, 20)
        XCTAssertEqual(padding.left, 30)
        XCTAssertEqual(padding.right, 30)
        padding.setValue(60, for: \.right)
        XCTAssertEqual(padding.left, 60)
        XCTAssertEqual(padding.top, 20)
        padding.setValue(80, for: \.bottom)
        XCTAssertEqual(padding.top, 80)
        padding.setMode(.uniform)
        XCTAssertEqual(padding, CanvasPadding(uniform: 70))
        padding.setValue(15, for: \.left)
        XCTAssertEqual(padding, CanvasPadding(uniform: 15))
        padding.setMode(.independent)
        padding.setValue(90, for: \.top)
        XCTAssertEqual(padding.top, 90)
        XCTAssertEqual(padding.right, 15)
        XCTAssertEqual(padding.bottom, 15)
        XCTAssertEqual(padding.left, 15)
    }

    func testCanvasPaddingRoundTripAndPreviousUniformValue() throws {
        for mode in CanvasPaddingMode.allCases {
            var padding = CanvasPadding(top: 10, right: 20, bottom: 30, left: 40)
            padding.setMode(mode)
            let canvas = CanvasStyle(paddingInsets: padding)
            let data = try JSONEncoder().encode(canvas)
            let decoded = try JSONDecoder().decode(CanvasStyle.self, from: data)
            XCTAssertEqual(decoded, canvas)
            try ProjectValidator.validate(decoded)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(fields["padding"])
        }
        let previous = try JSONDecoder().decode(CanvasStyle.self, from: Data(#"{"padding":10}"#.utf8))
        XCTAssertEqual(previous.paddingInsets, CanvasPadding(uniform: 10))
    }

    func testRejectsInvalidEdgesAndContradictoryLinkage() {
        for value in [-1.0, 1001, .infinity, .nan] {
            let canvas = CanvasStyle(paddingInsets: CanvasPadding(
                top: 10, right: value, bottom: 20, left: 30
            ))
            XCTAssertThrowsError(try ProjectValidator.validate(canvas))
        }
        let canvas = CanvasStyle(paddingInsets: CanvasPadding(
            top: 10, right: 20, bottom: 30, left: 40, mode: .axes
        ))
        XCTAssertThrowsError(try ProjectValidator.validate(canvas))
    }
}
