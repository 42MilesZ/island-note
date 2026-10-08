import AppKit
import XCTest
@testable import IslandNote

final class PanelResizeMotionTests: XCTestCase {
    func testGentleStartSoftLandingAndFrameRateIndependence() {
        let original = NSRect(x: 200, y: 200, width: 420, height: 460)
        var motion = PanelResizeMotion(rect: original)
        motion.target = NSRect(x: 179, y: 177, width: 462, height: 506)
        motion.advance(by: 0.05)
        let first = motion.rect.width - original.width
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 42 * 0.2)
        let a = motion.rect.width
        motion.advance(by: 0.05)
        XCTAssertGreaterThan(motion.rect.width - a, first)
        XCTAssertEqual(motion.rect.midX, original.midX, accuracy: 0.001)
        XCTAssertEqual(motion.rect.midY, original.midY, accuracy: 0.001)
        for _ in 0..<100 {
            motion.advance(by: 1 / 120)
            XCTAssertLessThanOrEqual(motion.rect.width, motion.target.width)
        }
        XCTAssertTrue(motion.isSettled)
        var sixty = PanelResizeMotion(rect: original), oneTwenty = sixty
        sixty.target = motion.target; oneTwenty.target = motion.target
        for _ in 0..<24 { sixty.advance(by: 1 / 60) }
        for _ in 0..<48 { oneTwenty.advance(by: 1 / 120) }
        XCTAssertEqual(sixty.rect.width, oneTwenty.rect.width, accuracy: 0.000001)
    }

    func testRetargetPreservesPositionAndVelocityAndSettlesInReverse() {
        var motion = PanelResizeMotion(rect: NSRect(x: 200, y: 200, width: 420, height: 460))
        motion.target = NSRect(x: 179, y: 177, width: 462, height: 506)
        motion.advance(by: 0.1)
        let before = motion.rect
        motion.target = NSRect(x: 210, y: 211, width: 400, height: 438)
        XCTAssertEqual(motion.rect, before)
        motion.advance(by: 0.001)
        // Retargeting decelerates the current movement instead of resetting it.
        XCTAssertGreaterThan(motion.rect.width, before.width)
        motion.advance(by: 0.3)
        XCTAssertLessThan(motion.rect.width, before.width)
        motion.advance(by: 1)
        XCTAssertTrue(motion.isSettled)
        XCTAssertEqual(motion.rect.width, 400, accuracy: 0.01)
    }
}
