import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class PanelHeaderTests: XCTestCase {
    func testDoubleClickIsNotTreatedAsADrag() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let header = PanelDragView(frame: NSRect(x: 0, y: 0, width: 200, height: PanelDragView.headerHeight))
        window.contentView?.addSubview(header)
        var log: [String] = []
        header.onBegin = { _ in log.append("begin") }
        header.onMove = { _ in log.append("move") }
        header.onEnd = { _ in log.append("end") }
        header.onDoubleClick = { log.append("double") }

        func send(_ type: NSEvent.EventType, clicks: Int, at location: NSPoint = NSPoint(x: 50, y: 10)) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        header.mouseDown(with: try send(.leftMouseDown, clicks: 1))
        header.mouseUp(with: try send(.leftMouseUp, clicks: 1))
        header.mouseDown(with: try send(.leftMouseDown, clicks: 2))
        header.mouseUp(with: try send(.leftMouseUp, clicks: 2))
        XCTAssertEqual(log, ["begin", "end", "begin", "end", "double"])

        // Re-grabbing quickly and dragging away stays a drag.
        log.removeAll()
        header.mouseDown(with: try send(.leftMouseDown, clicks: 2))
        header.mouseDragged(with: try send(.leftMouseDragged, clicks: 2, at: NSPoint(x: 90, y: 10)))
        header.mouseUp(with: try send(.leftMouseUp, clicks: 2, at: NSPoint(x: 90, y: 10)))
        XCTAssertEqual(log, ["begin", "move", "end"])
    }
}
