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

    @MainActor
    func testExpandedCornerHoverUsesResizeCursorWithoutClickingAndPreservesControls() throws {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: NSRect(x: 100, y: 100, width: 800, height: 800),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let previousCursor = NSCursor.current
        defer { panel.close(); previousCursor.set() }
        let root = IslandView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        let view = PanelResizeView(frame: root.bounds)
        view.panelRect = NSRect(x: 100, y: 100, width: 420, height: 460)
        view.isEnabled = true
        root.hitRect = view.panelRect.insetBy(dx: -PanelResizeView.outsideReach, dy: -PanelResizeView.outsideReach)
        root.addSubview(view)
        panel.contentView = root
        panel.resizeCursorAtPoint = { view.resizeCursor(at: $0) }
        XCTAssertFalse(panel.isKeyWindow)
        let r = view.panelRect
        let corners: [(NSPoint, PanelResizeEdges)] = [
            (NSPoint(x: r.minX + 32, y: r.minY + 32), [.left, .bottom]),
            (NSPoint(x: r.maxX - 32, y: r.minY + 32), [.right, .bottom]),
            (NSPoint(x: r.minX + 32, y: r.maxY - 32), [.left, .top]),
            (NSPoint(x: r.maxX - 32, y: r.maxY - 33), [.right, .top]),
            (NSPoint(x: r.minX - 12, y: r.minY - 12), [.left, .bottom]),
            (NSPoint(x: r.maxX + 12, y: r.minY - 12), [.right, .bottom]),
            (NSPoint(x: r.minX - 12, y: r.maxY + 12), [.left, .top]),
            (NSPoint(x: r.maxX + 12, y: r.maxY + 12), [.right, .top])]
        for (point, edges) in corners {
            let handle = try XCTUnwrap(root.hitTest(point) as? PanelResizeHandle)
            XCTAssertEqual(handle.edges, edges)
            XCTAssertNotNil(view.resizeCursor(at: point))
            XCTAssertTrue(handle.trackingAreas.contains { $0.options.contains([.mouseMoved, .activeAlways]) })
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            NSCursor.iBeam.set()
            handle.mouseEntered(with: event)
            XCTAssertFalse(NSCursor.current === NSCursor.iBeam)
            NSCursor.iBeam.set()
            handle.cursorUpdate(with: event)
            XCTAssertFalse(NSCursor.current === NSCursor.iBeam)
            NSCursor.iBeam.set()
            panel.sendEvent(event)
            XCTAssertFalse(NSCursor.current === NSCursor.iBeam)
            var receivedEdges: PanelResizeEdges?
            view.onBegin = { receivedEdges = $0; _ = $1 }
            handle.mouseDown(with: event)
            XCTAssertEqual(receivedEdges, edges)
        }
        for point in [NSPoint(x: r.maxX - 16, y: r.maxY - 8), NSPoint(x: r.maxX - 27, y: r.maxY - 19),
                      NSPoint(x: r.midX, y: r.maxY - 19), NSPoint(x: r.midX, y: r.midY)] {
            XCTAssertNil(view.resizeCursor(at: point))
            for handle in view.subviews {
                let local = view.convert(point, to: handle)
                XCTAssertFalse(handle.trackingAreas.contains { $0.rect.contains(local) })
            }
        }
        view.isEnabled = false
        XCTAssertNil(view.resizeCursor(at: corners[0].0))
    }
}
