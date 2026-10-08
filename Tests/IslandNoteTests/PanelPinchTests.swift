import XCTest
import AppKit
@testable import IslandNote

final class PanelPinchTests: XCTestCase {
    private let screen = NSRect(x: -500, y: 60, width: 1200, height: 840)
    private var initial: NSRect { NSRect(x: -130, y: 625, width: 460, height: 275) }
    private func magnify(_ rect: NSRect, _ delta: CGFloat) -> (rect: NSRect, limited: Bool) {
        FloatingPanelLayout.magnified(rect, delta: delta, maximum: screen.size, screen: screen,
            minimum: NSSize(width: 320, height: 190), anchoredToTop: true)
    }

    func testSmallDeltasRemainContinuousAndTopAnchoredOnOffsetScreen() {
        var rect = initial, factor: CGFloat = 1
        for delta: CGFloat in [0.01, 0.02, -0.015, 0.03] {
            factor *= 1 + delta
            let result = magnify(rect, delta)
            XCTAssertFalse(result.limited)
            rect = result.rect
            XCTAssertEqual(rect.width, initial.width * factor, accuracy: 0.00001)
            XCTAssertEqual(rect.height, initial.height * factor, accuracy: 0.00001)
            XCTAssertEqual(rect.midX, initial.midX, accuracy: 0.00001)
            XCTAssertEqual(rect.maxY, initial.maxY, accuracy: 0.00001)
        }
    }

    func testBothLimitsPreserveAnchorAndReverseWithoutOvershoot() {
        let large = magnify(initial, 100)
        XCTAssertTrue(large.limited)
        XCTAssertEqual(large.rect.width, 1200, accuracy: 0.00001)
        XCTAssertEqual(large.rect.maxY, initial.maxY, accuracy: 0.00001)
        XCTAssertEqual(magnify(large.rect, -0.01).rect.width, 1188, accuracy: 0.00001)
        let small = magnify(initial, -100)
        XCTAssertTrue(small.limited)
        XCTAssertEqual(small.rect.width, 320, accuracy: 0.00001)
        XCTAssertEqual(small.rect.maxY, initial.maxY, accuracy: 0.00001)
        XCTAssertEqual(magnify(small.rect, 0.01).rect.width, 323.2, accuracy: 0.00001)
    }

    func testScreenSmallerThanMinimumAndNonFiniteDeltas() {
        let tiny = NSRect(x: 900, y: -200, width: 250, height: 150)
        let rect = NSRect(x: 925, y: -150, width: 200, height: 100)
        let result = FloatingPanelLayout.magnified(rect, delta: 100, maximum: tiny.size, screen: tiny,
            minimum: NSSize(width: 320, height: 190), anchoredToTop: true)
        XCTAssertEqual(result.rect.size, NSSize(width: 250, height: 125))
        XCTAssertEqual(result.rect.maxY, tiny.maxY)
        XCTAssertEqual(magnify(initial, .nan).rect, initial)
        XCTAssertEqual(magnify(initial, .infinity).rect, initial)
    }
}
