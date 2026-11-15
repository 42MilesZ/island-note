import AppKit
import XCTest
@testable import IslandNote

/// Docked-island behaviour on screens without a camera housing, independent of the test machine.
@MainActor
final class DockRevealTests: XCTestCase {
    private let none = NotchMetrics(screenWidth: 1920, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil)

    private func settle(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func withController(_ body: (IslandNoteController, IslandPanel, CAShapeLayer, NSRect) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-reveal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("fixture.md")
        try "# Note\n".write(to: note, atomically: true, encoding: .utf8)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let notch = none
        let controller = IslandNoteController(store: NoteStore(fileURL: note, configurationDirectory: directory), enableSync: false,
            diagnostics: InteractionDiagnostics(defaults: nil, enabled: false), notchMetrics: { _ in notch })
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? IslandPanel }.first { !existing.contains(ObjectIdentifier($0)) })
        defer { panel.close() }
        let island = try XCTUnwrap(panel.contentView?.subviews.first)
        let mask = try XCTUnwrap(island.layer?.mask as? CAShapeLayer)
        let editor = try XCTUnwrap(island.subviews.first { $0 is NoteEditorView })
        try body(controller, panel, mask, editor.frame)
    }

    private func move(_ controller: IslandNoteController, _ panel: NSWindow, to point: NSPoint) throws {
        controller.handleHover(try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
    }

    func testRestingIslandIsHiddenAndPassesClicksThrough() throws {
        try withController { controller, _, mask, _ in
            XCTAssertFalse(controller.hasNotch)
            XCTAssertEqual(controller.mode, .rest)
            // A fully transparent window passes clicks to the menu bar beneath it.
            XCTAssertEqual(try XCTUnwrap(mask.path).boundingBoxOfPath.height, 0, accuracy: 0.001)
        }
    }

    func testApproachPeeksAndRestingInMenuBarOpens() throws {
        try withController { controller, panel, mask, viewport in
            let top = viewport.maxY
            let outside = NSPoint(x: viewport.midX, y: top - 200)
            // Derive points from the live layout: the menu bar height depends on the machine.
            let layout = try XCTUnwrap(controller.dockLayout)
            let approaching = NSPoint(x: viewport.midX, y: layout.peekZone.minY + 2)
            XCTAssertFalse(layout.openZone.contains(approaching))
            let inMenuBar = NSPoint(x: viewport.midX, y: top - 5)

            try move(controller, panel, to: approaching)
            XCTAssertEqual(controller.mode, .hover, "Approaching below the menu bar already peeks")
            XCTAssertEqual(try XCTUnwrap(mask.path).boundingBoxOfPath.height, DockBarLayout.peekHeight, accuracy: 0.5)
            settle(0.4)
            XCTAssertEqual(controller.mode, .hover, "Below the menu bar the peek never opens by itself")

            try move(controller, panel, to: outside)
            XCTAssertEqual(controller.mode, .rest, "Leaving the zone retracts the peek")
            let retract = try XCTUnwrap(mask.animation(forKey: "path") as? CABasicAnimation)
            let target = try XCTUnwrap(retract.toValue as! CGPath?)
            XCTAssertGreaterThan(target.boundingBoxOfPath.minY, top, "The rounded peek slides beyond the top edge")

            try move(controller, panel, to: inMenuBar); settle(0.5)
            XCTAssertEqual(controller.mode, .expanded, "Resting in the menu bar opens the note")
        }
    }

    func testTopEdgeOpensImmediatelyAndCollapseKeepsCorners() throws {
        try withController { controller, panel, mask, viewport in
            try move(controller, panel, to: NSPoint(x: viewport.midX, y: viewport.maxY - 1))
            XCTAssertEqual(controller.mode, .expanded)
            settle(0.8)
            try move(controller, panel, to: NSPoint(x: viewport.midX, y: viewport.maxY - 400))
            controller.collapse(); settle(0.05)
            XCTAssertEqual(controller.mode, .rest)
            let retract = try XCTUnwrap(mask.animation(forKey: "path") as? CABasicAnimation)
            let target = try XCTUnwrap(retract.toValue as! CGPath?)
            XCTAssertGreaterThan(target.boundingBoxOfPath.minY, viewport.maxY, "The capsule leaves through the top edge")
            XCTAssertGreaterThan(target.boundingBoxOfPath.height, 20, "It keeps its rounded body instead of flattening")
            XCTAssertEqual(try XCTUnwrap(mask.path).boundingBoxOfPath.height, 0, accuracy: 0.001)
        }
    }

    func testMenuBarClickSuppressesPeekUntilPointerLeaves() throws {
        try withController { controller, panel, _, viewport in
            // Beside the peek: an ordinary menu bar item under the open zone.
            let layout = try XCTUnwrap(controller.dockLayout)
            let inMenuBar = NSPoint(x: layout.hover.maxX + 12, y: viewport.maxY - 5)
            XCTAssertTrue(layout.openZone.contains(inMenuBar))
            try move(controller, panel, to: inMenuBar)
            XCTAssertEqual(controller.mode, .hover)
            controller.handleClick(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: inMenuBar,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            XCTAssertEqual(controller.mode, .rest)
            try move(controller, panel, to: inMenuBar); settle(0.4)
            XCTAssertEqual(controller.mode, .rest, "Using a menu bar item there does not open the note")
            try move(controller, panel, to: NSPoint(x: viewport.midX, y: viewport.maxY - 200))
            try move(controller, panel, to: inMenuBar)
            XCTAssertEqual(controller.mode, .hover, "Coming back re-arms the peek")
        }
    }

    func testClickingThePeekOpensTheNote() throws {
        try withController { controller, panel, _, viewport in
            let layout = try XCTUnwrap(controller.dockLayout)
            try move(controller, panel, to: NSPoint(x: viewport.midX, y: layout.peekZone.minY + 2))
            XCTAssertEqual(controller.mode, .hover)
            let onPeek = NSPoint(x: layout.hover.midX, y: layout.hover.midY)
            controller.handleClick(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: onPeek,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            XCTAssertEqual(controller.mode, .expanded, "The visible peek is the island's own surface")
        }
    }

    func testDraggingAcrossTheMenuBarDoesNotReveal() throws {
        try withController { controller, panel, _, viewport in
            for point in [NSPoint(x: viewport.midX, y: viewport.maxY - 5), NSPoint(x: viewport.midX, y: viewport.maxY - 1)] {
                controller.handleHover(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            settle(0.4)
            XCTAssertEqual(controller.mode, .rest, "Moving windows or files past the top edge leaves the note closed")
        }
    }

    func testMenuBarIconStillOpensTheNote() throws {
        try withController { controller, _, _, _ in
            controller.openFromStatusMenu(); settle(0.3)
            XCTAssertEqual(controller.mode, .expanded)
        }
    }
}
