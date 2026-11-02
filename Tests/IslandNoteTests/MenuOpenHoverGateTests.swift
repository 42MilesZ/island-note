import AppKit
import XCTest
@testable import IslandNote

final class MenuOpenHoverGateTests: XCTestCase {
    func testBufferedMovementFromBeforeCompletionIsIgnored() {
        var gate = MenuOpenHoverGate()
        gate.begin()
        gate.openingFinished(at: .zero, timestamp: 100)
        let outside = NSPoint(x: 200, y: 100)
        XCTAssertFalse(gate.allowsHover(at: outside, isMovement: true, timestamp: 99))
        XCTAssertFalse(gate.allowsHover(at: outside, isMovement: true, timestamp: 100))
        XCTAssertTrue(gate.allowsHover(at: outside, isMovement: true, timestamp: 101))
    }

    func testOpeningIgnoresMovementAndStartsFromCompletionPosition() {
        var gate = MenuOpenHoverGate()
        gate.begin()
        XCTAssertFalse(gate.allowsHover(at: NSPoint(x: 100, y: 100), isMovement: true))
        gate.openingFinished(at: NSPoint(x: 200, y: 100))
        XCTAssertFalse(gate.allowsHover(at: NSPoint(x: 200, y: 100), isMovement: true))
        XCTAssertFalse(gate.allowsHover(at: NSPoint(x: 220, y: 100), isMovement: false))
        XCTAssertTrue(gate.allowsHover(at: NSPoint(x: 220, y: 100), isMovement: true))
        XCTAssertFalse(gate.allowsHover(at: NSPoint(x: 220, y: 100), isMovement: true))
    }

    func testReopeningWaitsAgainAndResetPreservesOrdinaryHover() {
        var gate = MenuOpenHoverGate()
        gate.begin()
        gate.openingFinished(at: .zero)
        XCTAssertTrue(gate.allowsHover(at: NSPoint(x: 1, y: 0), isMovement: true))
        gate.begin()
        XCTAssertFalse(gate.allowsHover(at: NSPoint(x: 2, y: 0), isMovement: true))
        gate.reset()
        gate.openingFinished(at: .zero)
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.allowsHover(at: .zero, isMovement: false))
    }
}
