import XCTest
import AppKit
@testable import IslandNote

final class PanelPinchTests: XCTestCase {
    func testDimensions() {
        XCTAssertEqual(PanelSize.large.dimensions.width / PanelSize.standard.dimensions.width, 1.5)
        XCTAssertEqual(PanelSize.large.dimensions.height / PanelSize.standard.dimensions.height, 2)
    }

    func testSmallDeltasAccumulateAndCommitOnlyOnce() {
        var pinch = PanelPinch()
        XCTAssertNil(pinch.update(delta: 0.03, phase: .began, size: .standard))
        XCTAssertNil(pinch.update(delta: 0.03, phase: .changed, size: .standard))
        XCTAssertEqual(pinch.update(delta: 0.03, phase: .changed, size: .standard), .large)
        XCTAssertNil(pinch.update(delta: -0.5, phase: .changed, size: .large))
        XCTAssertNil(pinch.update(delta: 0, phase: .ended, size: .large))
        XCTAssertFalse(pinch.isActive)
        XCTAssertEqual(pinch.update(delta: -0.1, phase: .began, size: .large), .standard)
    }

    func testEndpointDoesNotRepeatOrReverseWithinOneGesture() {
        var pinch = PanelPinch()
        XCTAssertNil(pinch.update(delta: 0.2, phase: .began, size: .large))
        XCTAssertNil(pinch.update(delta: -0.5, phase: .changed, size: .large))
        XCTAssertNil(pinch.update(delta: 0, phase: .ended, size: .large))
        XCTAssertEqual(pinch.update(delta: -0.09, phase: .began, size: .large), .standard)
    }

    func testCancellationAndNewGestureDiscardUncommittedDeltas() {
        var pinch = PanelPinch()
        XCTAssertNil(pinch.update(delta: 0.06, phase: .began, size: .standard))
        XCTAssertNil(pinch.update(delta: 0.1, phase: .cancelled, size: .standard))
        XCTAssertFalse(pinch.isActive)
        XCTAssertNil(pinch.update(delta: 0.03, phase: .began, size: .standard))
        XCTAssertNil(pinch.update(delta: 0.06, phase: .began, size: .standard))
    }

    func testEndedDeltaCanCommitAndNoiseDoesNotLeakToNextGesture() {
        var pinch = PanelPinch()
        XCTAssertNil(pinch.update(delta: 0.05, phase: .began, size: .standard))
        XCTAssertEqual(pinch.update(delta: 0.04, phase: .ended, size: .standard), .large)
        XCTAssertFalse(pinch.isActive)
        XCTAssertNil(pinch.update(delta: -0.03, phase: .began, size: .large))
        XCTAssertNil(pinch.update(delta: 0, phase: .ended, size: .large))
        XCTAssertNil(pinch.update(delta: -0.06, phase: .began, size: .large))
    }
}
