import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class StatusIndicatorTrackingTests: XCTestCase {
    func testHoverUsesExpandedParentAreaAndLeavesClicksNative() throws {
        _ = NSApplication.shared
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let button = StatusIndicatorButton(frame: NSRect(x: 120, y: 20, width: 24, height: 24))
        parent.addSubview(button)
        button.updateTrackingAreas()
        let area = try XCTUnwrap(parent.trackingAreas.first { ($0.owner as? StatusIndicatorButton) === button })
        XCTAssertEqual(area.rect, NSRect(x: 114, y: 14, width: 36, height: 36))
        button.updateTrackingAreas()
        XCTAssertTrue(parent.trackingAreas.first { ($0.owner as? StatusIndicatorButton) === button } === area)
        XCTAssertFalse(area.options.contains(.inVisibleRect))
        XCTAssertEqual(button.frame.size, NSSize(width: 24, height: 24))
        let paddingPoint = NSPoint(x: 132, y: 48)
        XCTAssertTrue(area.rect.contains(paddingPoint))
        XCTAssertFalse(parent.hitTest(paddingPoint) === button)

        button.frame.size.width = 100
        button.updateTrackingAreas()
        let expanded = try XCTUnwrap(parent.trackingAreas.first { ($0.owner as? StatusIndicatorButton) === button })
        XCTAssertEqual(expanded.rect.width, 112)
        XCTAssertEqual(parent.trackingAreas.filter { ($0.owner as? StatusIndicatorButton) === button }.count, 1)
        button.removeFromSuperview()
        XCTAssertFalse(parent.trackingAreas.contains { ($0.owner as? StatusIndicatorButton) === button })
    }
}
