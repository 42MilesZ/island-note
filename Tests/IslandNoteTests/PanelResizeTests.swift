import AppKit
import XCTest
@testable import IslandNote

final class PanelResizeTests: XCTestCase {
    private let screen = NSRect(x: -1000, y: -900, width: 1000, height: 900)
    private let original = NSRect(x: -650, y: -600, width: 420, height: 460)

    func testEdgesKeepTheirOppositeSideFixed() {
        let delta = NSPoint(x: -80, y: 90)
        let left = FloatingPanelLayout.resized(original, edges: .left, delta: delta, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertEqual(left.width, 500)
        XCTAssertEqual(left.maxX, original.maxX)
        XCTAssertEqual(left.minY, original.minY)
        let top = FloatingPanelLayout.resized(original, edges: .top, delta: delta, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertEqual(top.height, 550)
        XCTAssertEqual(top.minY, original.minY)
        XCTAssertEqual(top.minX, original.minX)
        let corner = FloatingPanelLayout.resized(original, edges: [.left, .top], delta: delta, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertEqual(corner.maxX, original.maxX)
        XCTAssertEqual(corner.minY, original.minY)
        XCTAssertEqual(corner.size, NSSize(width: 500, height: 550))
    }

    func testMinimumMaximumAndDisplayEdges() {
        let small = FloatingPanelLayout.resized(original, edges: [.right, .bottom], delta: NSPoint(x: -2000, y: 2000), maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertEqual(small.size, FloatingPanelLayout.minimum)
        XCTAssertEqual(small.minX, original.minX)
        XCTAssertEqual(small.maxY, original.maxY)
        let large = FloatingPanelLayout.resized(original, edges: [.right, .bottom], delta: NSPoint(x: 2000, y: -2000), maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertEqual(large.maxX, screen.maxX)
        XCTAssertEqual(large.minY, screen.minY)
        let capped = FloatingPanelLayout.resized(original, edges: [.right, .top], delta: NSPoint(x: 2000, y: 2000), maximum: NSSize(width: 500, height: 500), screen: screen)
        XCTAssertEqual(capped.size, NSSize(width: 500, height: 500))
    }

    func testMagnificationIsProportionalCenteredAndImmediatelyReversibleAtLimits() {
        let first = FloatingPanelLayout.magnified(original, delta: 0.01, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertEqual(first.rect.width, 424.2, accuracy: 0.001)
        XCTAssertEqual(first.rect.height, 464.6, accuracy: 0.001)
        XCTAssertEqual(first.rect.midX, original.midX, accuracy: 0.001)
        XCTAssertEqual(first.rect.midY, original.midY, accuracy: 0.001)
        XCTAssertFalse(first.limited)
        let largest = FloatingPanelLayout.magnified(first.rect, delta: 100, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertTrue(largest.limited)
        XCTAssertTrue(screen.contains(largest.rect))
        XCTAssertEqual(largest.rect.width / largest.rect.height, original.width / original.height, accuracy: 0.0001)
        let reverse = FloatingPanelLayout.magnified(largest.rect, delta: -0.01, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertLessThan(reverse.rect.width, largest.rect.width)
        XCTAssertLessThan(reverse.rect.height, largest.rect.height)
        XCTAssertFalse(reverse.limited)
        let smallest = FloatingPanelLayout.magnified(reverse.rect, delta: -100, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertTrue(smallest.limited)
        XCTAssertEqual(smallest.rect.width, 320, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(smallest.rect.height, 280)
        let expand = FloatingPanelLayout.magnified(smallest.rect, delta: 0.01, maximum: FloatingPanelLayout.maximum, screen: screen)
        XCTAssertGreaterThan(expand.rect.width, smallest.rect.width)
        XCTAssertFalse(expand.limited)
        XCTAssertEqual(FloatingPanelLayout.magnified(original, delta: .nan, maximum: FloatingPanelLayout.maximum, screen: screen).rect, original)
    }

    @MainActor
    func testOnlyEdgesAndCornersInterceptInput() {
        _ = NSApplication.shared
        let view = PanelResizeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        view.panelRect = NSRect(x: 100, y: 100, width: 420, height: 460)
        view.isEnabled = true
        let r = view.panelRect
        for point in [NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY),
                      NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.midX, y: r.maxY),
                      NSPoint(x: r.minX + 12, y: r.minY + 12), NSPoint(x: r.maxX - 12, y: r.maxY - 12)] {
            XCTAssertNotNil(view.hitTest(point))
        }
        XCTAssertNil(view.hitTest(NSPoint(x: r.midX, y: r.midY)))
        XCTAssertNil(view.hitTest(NSPoint(x: r.midX, y: r.maxY - 19)))
        XCTAssertNil(view.hitTest(NSPoint(x: r.maxX - 27, y: r.maxY - 19)))
        XCTAssertNil(view.hitTest(NSPoint(x: r.maxX - 16, y: r.maxY - 8)))
        XCTAssertNil(view.hitTest(NSPoint(x: r.maxX - 16, y: r.maxY - 23)))
        view.isEnabled = false
        XCTAssertNil(view.hitTest(NSPoint(x: r.minX, y: r.midY)))
    }
}
